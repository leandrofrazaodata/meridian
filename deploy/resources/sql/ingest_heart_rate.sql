-- Bronze ingest for contracts/heart_rate.yml.
-- _pid_from_path is extracted via regex, not trusted from the row's own
-- participant_id column -- Unity Catalog volumes don't support
-- input_file_name(), and Silver cross-checks the two against each other
-- (contracts/heart_rate.yml's pid_matches_path rule; see
-- docs/conventions.md "Ingestion metadata columns").
--
-- Parameters (supplied by deploy/resources/jobs.yml's sql_task.parameters):
--   :target_table  -- "workspace.<schema_prefix>_bronze.heart_rate"
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
    CAST(:ingested_at AS DATE) AS _ingested_at,
    regexp_extract(_metadata.file_path, 'wearable_events/([^/]+)/', 1) AS _pid_from_path
  FROM '/Volumes/workspace/default/raw/data/wearable_events/*/heart_rate.json'
)
FILEFORMAT = JSON
FORMAT_OPTIONS ('multiLine' = 'true')
COPY_OPTIONS ('mergeSchema' = 'true');
