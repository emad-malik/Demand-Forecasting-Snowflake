USE DATABASE m5_forecasting;

-- Quick data check to ensure dimensions match fact rows perfectly
SELECT 
    (SELECT COUNT(*) FROM analytics.dim_calendar) AS total_calendar_days,
    (SELECT COUNT(*) FROM analytics.dim_items) AS total_unique_items,
    (SELECT COUNT(*) FROM analytics.dim_stores) AS total_stores,
    (SELECT COUNT(*) FROM analytics.fact_sales) AS total_fact_sales_rows;
