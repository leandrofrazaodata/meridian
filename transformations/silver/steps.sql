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
WITH keyed AS (
  SELECT
    *,
    MIN(steps) OVER (PARTITION BY participant_id, timestamp) AS _min_steps,
    MAX(steps) OVER (PARTITION BY participant_id, timestamp) AS _max_steps,
    ROW_NUMBER() OVER (PARTITION BY participant_id, timestamp ORDER BY steps) AS _row_num
  FROM ${schema_prefix}_bronze.steps
),
deduped AS (
  SELECT * FROM keyed
  WHERE _row_num = 1 OR _min_steps <> _max_steps
),
reasoned AS (
  SELECT
    timestamp, steps, participant_id, _source_file, _ingested_at,
    filter(array(
      CASE WHEN NOT (steps >= 0) THEN 'steps_non_negative' END,
      CASE WHEN NOT (steps <= 250) THEN 'steps_plausible' END,
      CASE WHEN NOT (participant_id = _pid_from_path) THEN 'pid_matches_path' END
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
  CONSTRAINT pid_matches_path EXPECT (NOT array_contains(_suspect_reasons, 'pid_matches_path'))
)
AS SELECT
  timestamp, steps, participant_id, _source_file, _ingested_at, _suspect_reasons
FROM steps_prepared
WHERE size(_quarantine_reasons) = 0;

CREATE OR REFRESH MATERIALIZED VIEW quarantine_steps
AS SELECT
  timestamp, steps, participant_id, _source_file, _ingested_at,
  _suspect_reasons, _quarantine_reasons
FROM steps_prepared
WHERE size(_quarantine_reasons) > 0;
