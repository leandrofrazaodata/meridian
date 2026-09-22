-- Bronze ingest for contracts/device_metadata.yml.
-- COPY INTO tracks which files it has already loaded, so rerunning this
-- task for a date already ingested is a no-op, not a duplicate load
-- (docs/pipeline-architecture.md "Idempotency & reproducibility").
--
-- Parameters (supplied by deploy/resources/jobs.yml's sql_task.parameters):
--   :target_table  -- "workspace.<schema_prefix>_bronze.device_metadata"
--   :ingested_at   -- job parameter, never CURRENT_DATE() (docs/conventions.md)
-- COPY INTO requires its target table to already exist -- it does not
-- create one from nothing. CREATE TABLE IF NOT EXISTS with no column
-- list is idempotent and lets this first COPY INTO infer the full
-- schema via the FORMAT_OPTIONS/COPY_OPTIONS below (Databricks COPY
-- INTO docs' standard create-then-copy pattern).
CREATE TABLE IF NOT EXISTS IDENTIFIER(:target_table);

COPY INTO IDENTIFIER(:target_table)
FROM (
  SELECT
    *,
    _metadata.file_path AS _source_file,
    CAST(:ingested_at AS DATE) AS _ingested_at
  FROM '/Volumes/workspace/default/raw/data/health_summaries/device_metadata.csv'
)
FILEFORMAT = CSV
FORMAT_OPTIONS ('header' = 'true', 'inferSchema' = 'true')
COPY_OPTIONS ('mergeSchema' = 'true');
