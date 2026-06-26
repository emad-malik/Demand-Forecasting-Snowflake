USE SCHEMA m5_forecasting.raw;

CREATE OR REPLACE TABLE raw_calendar_landing (
    date DATE, wm_yr_wk INT, weekday STRING, wday INT, month INT, year INT, d STRING,
    event_name_1 STRING, event_type_1 STRING, event_name_2 STRING, event_type_2 STRING,
    snap_CA INT, snap_TX INT, snap_WI INT
);

CREATE OR REPLACE TABLE raw_prices_landing (
    store_id STRING, item_id STRING, wm_yr_wk INT, sell_price FLOAT
);

-- Execute the data migration copy sweeps
COPY INTO raw_calendar_landing FROM @m5_uploads/calendar.csv;
COPY INTO raw_prices_landing FROM @m5_uploads/sell_prices.csv;

-- Populate Calendar Dimension
INSERT INTO m5_forecasting.analytics.dim_calendar
SELECT d, date, wm_yr_wk, weekday, wday, month, year, event_name_1, event_type_1, event_name_2, event_type_2,
       CAST(snap_CA AS BOOLEAN), CAST(snap_TX AS BOOLEAN), CAST(snap_WI AS BOOLEAN)
FROM raw_calendar_landing;

-- Populate Stores Dimension uniquely
INSERT INTO m5_forecasting.analytics.dim_stores (store_id, state_id)
SELECT DISTINCT store_id, SUBSTRING(store_id, 1, 2) FROM raw_prices_landing;

USE SCHEMA m5_forecasting.analytics;

-- Populate Items Dimension uniquely by extracting department and category from the item string
INSERT INTO dim_items (item_id, dept_id, cat_id)
SELECT DISTINCT 
    item_id,
    -- Extracts 'FOODS_1' from 'FOODS_1_001_CA_1'
    REGEXP_SUBSTR(item_id, '^[^_]+_[^_]+') AS dept_id,
    -- Extracts 'FOODS' from 'FOODS_1_001_CA_1'
    REGEXP_SUBSTR(item_id, '^[^_]+') AS cat_id
FROM m5_forecasting.raw.raw_prices_landing;

USE SCHEMA m5_forecasting.raw;

CREATE OR REPLACE TABLE raw_sales_wide
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(
      INFER_SCHEMA(
        LOCATION=>'@m5_uploads/sales_train_validation.csv',
        FILE_FORMAT=>'csv_infer_format'
      )
    )
  );

COPY INTO raw_sales_wide
FROM @m5_uploads/sales_train_validation.csv
FILE_FORMAT = csv_infer_format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

ALTER TABLE raw_sales_wide RENAME COLUMN "dept_id" TO "department";

USE DATABASE m5_forecasting;
USE SCHEMA analytics;
USE WAREHOUSE m5_de_wh;

-- -- Clear out any previous partial run metadata safely
-- TRUNCATE TABLE fact_sales;

-- INSERT INTO fact_sales (sales_id, date_id, store_id, item_id, units_sold, sell_price)
-- WITH src AS (
--     SELECT OBJECT_CONSTRUCT(*) AS obj FROM m5_forecasting.raw.raw_sales_wide
-- ),
-- unpivoted AS (
--     SELECT 
--         obj:"id"::STRING AS id,
--         obj:"item_id"::STRING AS item_id,
--         obj:"store_id"::STRING AS store_id,
--         F.key AS day_identifier,
--         F.value::INT AS units_sold
--     FROM src,
--     LATERAL FLATTEN(input => OBJECT_DELETE(obj, 'id','item_id','store_id','cat_id','dept_id','state_id')) F
-- )
-- SELECT 
--     UPV.id || '_' || UPV.day_identifier AS sales_id,
--     UPV.day_identifier AS date_id,
--     UPV.store_id,
--     UPV.item_id,
--     UPV.units_sold,
--     P.sell_price
-- FROM unpivoted UPV
-- LEFT JOIN m5_forecasting.analytics.dim_calendar C 
--     ON UPV.day_identifier = C.date_id
-- LEFT JOIN m5_forecasting.raw.raw_prices_landing P 
--     ON UPV.item_id = P.item_id 
--     AND UPV.store_id = P.store_id 
--     AND C.wm_yr_wk = P.wm_yr_wk;




TRUNCATE TABLE fact_sales;

-- 1. Create the robust execution procedure using an anonymous block
EXECUTE IMMEDIATE $$
DECLARE
    col_list STRING;
    cast_list STRING;
    sql_query STRING;
BEGIN
    -- Build the column list for UNPIVOT safely by matching ONLY actual day column strings (e.g., d_1 to d_1913)
    SELECT LISTAGG('"' || LOWER(column_name) || '"', ', ') WITHIN GROUP (ORDER BY ordinal_position)
    INTO :col_list
    FROM information_schema.columns
    WHERE table_catalog = 'M5_FORECASTING' 
      AND table_schema = 'RAW' 
      AND table_name = 'RAW_SALES_WIDE'
      AND REGEXP_LIKE(column_name, '^d_[0-9]+$', 'i'); -- Regex protection filter layer

    -- Build cast expressions to normalize all day columns to the same type safely
    SELECT LISTAGG('"' || LOWER(column_name) || '"::NUMBER(38,0) AS "' || LOWER(column_name) || '"', ', ') 
           WITHIN GROUP (ORDER BY ordinal_position)
    INTO :cast_list
    FROM information_schema.columns
    WHERE table_catalog = 'M5_FORECASTING' 
      AND table_schema = 'RAW' 
      AND table_name = 'RAW_SALES_WIDE'
      AND REGEXP_LIKE(column_name, '^d_[0-9]+$', 'i'); -- Regex protection filter layer

    -- Construct the unpivot query with a CTE that normalizes column types
    sql_query := 'INSERT INTO m5_forecasting.analytics.fact_sales (sales_id, date_id, store_id, item_id, units_sold, sell_price)
                  WITH normalized AS (
                      SELECT "id", "item_id", "store_id", ' || cast_list || '
                      FROM m5_forecasting.raw.raw_sales_wide
                  )
                  SELECT 
                      UPV."id" || ''_'' || UPV.day_identifier AS sales_id,
                      UPV.day_identifier AS date_id,
                      UPV."store_id" AS store_id,
                      UPV."item_id" AS item_id,
                      UPV.units_sold,
                      P.sell_price
                  FROM (
                      SELECT "id", "item_id", "store_id", day_identifier, units_sold
                      FROM normalized
                      UNPIVOT(units_sold FOR day_identifier IN (' || col_list || '))
                  ) UPV
                  LEFT JOIN m5_forecasting.analytics.dim_calendar C 
                      ON UPV.day_identifier = C.date_id
                  LEFT JOIN m5_forecasting.raw.raw_prices_landing P 
                      ON UPV."item_id" = P.item_id 
                      AND UPV."store_id" = P.store_id 
                      AND C.wm_yr_wk = P.wm_yr_wk';

    -- Execute the compiled statement sweep natively
    EXECUTE IMMEDIATE :sql_query;
    
    RETURN 'Success: fact_sales populated without any department string collisions.';
END;
$$;