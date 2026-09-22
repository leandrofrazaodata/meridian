-- Bronze ingest for contracts/sleep.yml.
-- _pid_from_path is extracted via regex, not trusted from the row's own
-- participant_id column -- Unity Catalog volumes don't support
-- input_file_name(), and Silver cross-checks the two against each other
-- (docs/conventions.md "Ingestion metadata columns"). sleep.yml has no
-- pid_matches_path rule of its own, but the column is added uniformly
-- across all three per-participant JSON sources for consistency.
--
-- Parameters (supplied by deploy/resources/jobs.yml's sql_task.parameters):
--   :target_table  -- "workspace.<schema_prefix>_bronze.sleep"
--   :ingested_at   -- job parameter, never CURRENT_DATE() (docs/conventions.md)
COPY INTO IDENTIFIER(:target_table)
FROM (
  SELECT
    *,
    _metadata.file_path AS _source_file,
    CAST(:ingested_at AS DATE) AS _ingested_at,
    regexp_extract(_metadata.file_path, 'wearable_events/([^/]+)/', 1) AS _pid_from_path
  FROM '/Volumes/workspace/default/raw/data/wearable_events/*/sleep.json'
)
FILEFORMAT = JSON
FORMAT_OPTIONS ('multiLine' = 'true')
COPY_OPTIONS ('mergeSchema' = 'true');
