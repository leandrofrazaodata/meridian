-- Silver transformation for contracts/wellness_survey.yml.
-- See docs/superpowers/specs/2026-09-22-silver-transformations-design.md.
-- Silver table is named `wellness` (not `wellness_survey`), per
-- docs/conventions.md's "named after the conformed entity" rule and the
-- contract's own participant_exists note ("orphans go to
-- quarantine_wellness").
--
-- contracts/wellness_survey.yml declares no fail-level null-check on its
-- natural-key columns (participant_id is incidentally covered by
-- participant_exists, but `date` has no rule that would catch a null) --
-- flagged in the design spec doc as a contract gap, not invented here.

CREATE OR REFRESH MATERIALIZED VIEW wellness_prepared
AS
WITH keyed AS (
  SELECT
    *,
    MIN(hash(fatigue_score, stress_score, readiness_score, sleep_quality_score))
      OVER (PARTITION BY participant_id, date) AS _min_hash,
    MAX(hash(fatigue_score, stress_score, readiness_score, sleep_quality_score))
      OVER (PARTITION BY participant_id, date) AS _max_hash,
    ROW_NUMBER() OVER (PARTITION BY participant_id, date ORDER BY fatigue_score) AS _row_num
  FROM ${schema_prefix}_bronze.wellness_survey
),
deduped AS (
  SELECT * FROM keyed
  WHERE _row_num = 1 OR _min_hash <> _max_hash
),
reasoned AS (
  SELECT
    participant_id, date, fatigue_score, stress_score, readiness_score, sleep_quality_score,
    _source_file, _ingested_at,
    filter(array(
      CASE WHEN NOT (fatigue_score BETWEEN 1 AND 5) THEN 'fatigue_in_range' END,
      CASE WHEN NOT (stress_score BETWEEN 1 AND 5) THEN 'stress_in_range' END,
      CASE WHEN NOT (readiness_score BETWEEN 0 AND 10) THEN 'readiness_in_range' END,
      CASE WHEN NOT (sleep_quality_score BETWEEN 1 AND 5) THEN 'sleep_quality_in_range' END
    ), x -> x IS NOT NULL) AS _suspect_reasons,
    filter(array(
      CASE WHEN NOT (participant_id IN (SELECT participant_id FROM ${schema_prefix}_silver.participants))
        THEN 'participant_exists' END,
      CASE WHEN _min_hash <> _max_hash THEN 'dedup_conflict' END
    ), x -> x IS NOT NULL) AS _quarantine_reasons
  FROM deduped
)
SELECT * FROM reasoned;

CREATE OR REFRESH MATERIALIZED VIEW wellness (
  CONSTRAINT fatigue_in_range EXPECT (NOT array_contains(_suspect_reasons, 'fatigue_in_range')),
  CONSTRAINT stress_in_range EXPECT (NOT array_contains(_suspect_reasons, 'stress_in_range')),
  CONSTRAINT readiness_in_range EXPECT (NOT array_contains(_suspect_reasons, 'readiness_in_range')),
  CONSTRAINT sleep_quality_in_range EXPECT (NOT array_contains(_suspect_reasons, 'sleep_quality_in_range'))
)
AS SELECT
  participant_id, date, fatigue_score, stress_score, readiness_score, sleep_quality_score,
  _source_file, _ingested_at, _suspect_reasons
FROM wellness_prepared
WHERE size(_quarantine_reasons) = 0;

CREATE OR REFRESH MATERIALIZED VIEW quarantine_wellness
AS SELECT
  participant_id, date, fatigue_score, stress_score, readiness_score, sleep_quality_score,
  _source_file, _ingested_at, _suspect_reasons, _quarantine_reasons
FROM wellness_prepared
WHERE size(_quarantine_reasons) > 0;
