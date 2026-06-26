import os
from pathlib import Path

import great_expectations as gx
from snowflake.connector import connect


def load_env_file(env_path):
    if not env_path.exists():
        return

    for line in env_path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue

        key, value = stripped.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


BASE_DIR = Path(__file__).resolve().parents[1]
load_env_file(BASE_DIR / ".env")

SNOWFLAKE_USER = os.environ["SNOWFLAKE_USER"]
SNOWFLAKE_PASSWORD = os.environ["SNOWFLAKE_PASSWORD"]
SNOWFLAKE_ACCOUNT = os.environ["SNOWFLAKE_ACCOUNT"]
SNOWFLAKE_WAREHOUSE = os.environ.get("SNOWFLAKE_WAREHOUSE", "M5_DE_WH")
SNOWFLAKE_DATABASE = os.environ.get("SNOWFLAKE_DATABASE", "M5_FORECASTING")
SNOWFLAKE_SCHEMA = os.environ.get("SNOWFLAKE_SCHEMA", "RAW")

# 1. Clear staging data via a clean initialization sweep
conn = connect(
    user=SNOWFLAKE_USER,
    password=SNOWFLAKE_PASSWORD,
    account=SNOWFLAKE_ACCOUNT,
    warehouse=SNOWFLAKE_WAREHOUSE,
    database=SNOWFLAKE_DATABASE,
    schema=SNOWFLAKE_SCHEMA,
)
cursor = conn.cursor()
cursor.execute("TRUNCATE TABLE raw_calendar_landing;")
cursor.execute("TRUNCATE TABLE raw_prices_landing;")
cursor.execute("COPY INTO raw_calendar_landing FROM @m5_uploads/calendar.csv;")
cursor.execute("COPY INTO raw_prices_landing FROM @m5_uploads/sell_prices.csv;")
cursor.close()

# 2. Initialize the Great Expectations Context
context = gx.get_context()

# 3. Connect to your active Snowflake data source asset layer
datasource = context.sources.add_sql(
    name="snowflake_m5_warehouse",
    connection_string=(
        "snowflake://"
        f"{SNOWFLAKE_USER}:{SNOWFLAKE_PASSWORD}@{SNOWFLAKE_ACCOUNT}/"
        f"{SNOWFLAKE_DATABASE}/{SNOWFLAKE_SCHEMA}?warehouse={SNOWFLAKE_WAREHOUSE}"
    )
)

calendar_asset = datasource.add_table_asset(name="calendar_landing_asset", table_name="RAW_CALENDAR_LANDING")
suite = context.add_expectation_suite(expectation_suite_name="m5_raw_validation_suite")

# Data Quality Rules: Validate strict calendar dimensions and prevent identity structural nulls
suite.add_expectation(gx.expectations.ExpectTableRowCountToEqual(value=1969))
suite.add_expectation(gx.expectations.ExpectColumnValuesToNotBeNull(column="d"))
suite.add_expectation(gx.expectations.ExpectColumnValuesToNotBeNull(column="date"))

# 4. Evaluate Checkpoint Loop
checkpoint = context.add_checkpoint(
    name="m5_raw_checkpoint",
    uncommitted_validations=[{
        "batch_request": calendar_asset.build_batch_request(),
        "expectation_suite_name": "m5_raw_validation_suite"
    }]
)

result = checkpoint.run()
print(f"Data Quality Pass Status: {result.was_successful}")