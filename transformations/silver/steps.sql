-- Silver transformation for contracts/steps.yml.
-- See docs/superpowers/specs/2026-09-22-silver-transformations-design.md.
-- Mirrors heart_rate.sql's dedup shape, minus the timestamp-normalization
-- branch and the stuck_sensor run-length logic -- contracts/steps.yml
-- declares neither (its timestamps have no documented Z-suffix quirk,
-- unlike heart_rate.json).

CREATE OR REFRESH MATERIALIZED VIEW steps_prepared (
  CONSTRAINT ts_not_null EXPECT (timestamp IS NOT NULL) ON VIOLATION FAIL UPDATE
)
AS
WITH normalized AS (
  -- Some source files (P005, P033, P038) record steps per HOUR, tagged
  -- per record with _unit = 'steps_per_hour'; untagged records are per
  -- minute. Convert before dedup so two copies of the same minute
  -- compare in the same unit. Every tagged value in this dataset is an
  -- exact multiple of 60 (checked 2026-10-01), so DIV loses nothing.
  -- An unrecognized _unit is left unconverted and flagged unit_known.
  SELECT
    * EXCEPT (steps),
    steps AS _steps_source,
    CASE WHEN _unit = 'steps_per_hour' THEN steps DIV 60 ELSE steps END AS steps
  FROM ${schema_prefix}_bronze.steps
),
keyed AS (
  SELECT
    *,
    MIN(steps) OVER (PARTITION BY participant_id, timestamp) AS _min_steps,
    MAX(steps) OVER (PARTITION BY participant_id, timestamp) AS _max_steps,
    ROW_NUMBER() OVER (PARTITION BY participant_id, timestamp ORDER BY steps) AS _row_num
  FROM normalized
),
deduped AS (
  SELECT * FROM keyed
  WHERE _row_num = 1 OR _min_steps <> _max_steps
),
reasoned AS (
  SELECT
    timestamp, steps, _steps_source, _unit, participant_id, _source_file, _ingested_at,
    filter(array(
      CASE WHEN NOT (steps >= 0) THEN 'steps_non_negative' END,
      CASE WHEN NOT (steps <= 250) THEN 'steps_plausible' END,
      CASE WHEN NOT (participant_id = _pid_from_path) THEN 'pid_matches_path' END,
      CASE WHEN NOT (_unit IS NULL OR _unit = 'steps_per_hour') THEN 'unit_known' END
    ), x -> x IS NOT NULL) AS _suspect_reasons,
    filter(array(
      CASE WHEN _min_steps <> _max_steps THEN 'dedup_conflict' END
    ), x -> x IS NOT NULL) AS _quarantine_reasons
  FROM deduped
)
SELECT * FROM reasoned;

CREATE OR REFRESH MATERIALIZED VIEW steps (
  CONSTRAINT steps_non_negative EXPECT (NOT array_contains(_suspect_reasons, 'steps_non_negative')),
  CONSTRAINT steps_plausible EXPECT (NOT array_contains(_suspect_reasons, 'steps_plausible')),
  CONSTRAINT pid_matches_path EXPECT (NOT array_contains(_suspect_reasons, 'pid_matches_path')),
  CONSTRAINT unit_known EXPECT (NOT array_contains(_suspect_reasons, 'unit_known'))
)
AS SELECT
  timestamp, steps, _steps_source, _unit, participant_id, _source_file, _ingested_at, _suspect_reasons
FROM steps_prepared
WHERE size(_quarantine_reasons) = 0;

CREATE OR REFRESH MATERIALIZED VIEW quarantine_steps
AS SELECT
  timestamp, steps, _steps_source, _unit, participant_id, _source_file, _ingested_at,
  _suspect_reasons, _quarantine_reasons
FROM steps_prepared
WHERE size(_quarantine_reasons) > 0;
