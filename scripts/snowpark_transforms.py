from snowflake.snowpark import Session
import snowflake.snowpark.functions as F

def standardize_m5_dimensions(session: Session):
    # Pull directly from the active change data capture stream target variable layer
    raw_prices_df = session.table("m5_forecasting.raw.raw_prices_landing")
    
    # Process Stores Dimension mapping logic natively via DataFrames
    dim_stores_df = raw_prices_df.select(
        F.col("STORE_ID"),
        F.substring(F.col("STORE_ID"), 1, 2).alias("STATE_ID")
    ).distinct()
    
    # Append the processed delta data straight to the data warehouse destination
    dim_stores_df.write.mode("append").save_as_table("m5_forecasting.analytics.dim_stores")
    
    return "Dimension Standardization Execution Successful."