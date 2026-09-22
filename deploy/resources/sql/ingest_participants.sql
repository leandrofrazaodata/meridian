-- Bronze ingest for contracts/participants.yml.
-- COPY INTO tracks which files it has already loaded, so rerunning this
-- task for a date already ingested is a no-op, not a duplicate load
-- (docs/pipeline-architecture.md "Idempotency & reproducibility").
--
-- Parameters (supplied by deploy/resources/jobs.yml's sql_task.parameters):
--   :target_table  -- "workspace.<schema_prefix>_bronze.participants"
--   :ingested_at   -- job parameter, never CURRENT_DATE() (docs/conventions.md)
COPY INTO IDENTIFIER(:target_table)
FROM (
  SELECT
    *,
    _metadata.file_path AS _source_file,
    CAST(:ingested_at AS DATE) AS _ingested_at
  FROM '/Volumes/workspace/default/raw/data/participants/participants.csv'
)
FILEFORMAT = CSV
FORMAT_OPTIONS ('header' = 'true', 'inferSchema' = 'true')
COPY_OPTIONS ('mergeSchema' = 'true');
