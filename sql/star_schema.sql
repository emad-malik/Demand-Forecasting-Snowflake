USE SCHEMA m5_forecasting.analytics;

-- Calendar Dimension
CREATE OR REPLACE TABLE dim_calendar (
    date_id STRING PRIMARY KEY,
    calendar_date DATE,
    wm_yr_wk INT,
    weekday STRING,
    wday INT,
    month INT,
    year INT,
    event_name_1 STRING,
    event_type_1 STRING,
    event_name_2 STRING,
    event_type_2 STRING,
    snap_ca BOOLEAN,
    snap_tx BOOLEAN,
    snap_wi BOOLEAN
);

-- Items Dimension
CREATE OR REPLACE TABLE dim_items (
    item_id STRING PRIMARY KEY,
    dept_id STRING,
    cat_id STRING
);

-- Stores Dimension
CREATE OR REPLACE TABLE dim_stores (
    store_id STRING PRIMARY KEY,
    state_id STRING
);

-- Compressed Fact Sales Table
CREATE OR REPLACE TABLE fact_sales (
    sales_id STRING PRIMARY KEY,
    date_id STRING REFERENCES dim_calendar(date_id),
    store_id STRING REFERENCES dim_stores(store_id),
    item_id STRING REFERENCES dim_items(item_id),
    units_sold INT,
    sell_price FLOAT
);