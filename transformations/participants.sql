-- Silver transformation for contracts/participants.yml.
-- See docs/superpowers/specs/2026-09-22-silver-transformations-design.md
-- for the _prepared/main/quarantine pattern this and every other file here
-- follows.

CREATE OR REFRESH MATERIALIZED VIEW participants_prepared (
  CONSTRAINT pid_not_null EXPECT (participant_id IS NOT NULL) ON VIOLATION FAIL UPDATE
)
AS
WITH keyed AS (
  SELECT
    *,
    MIN(hash(device_id, age, height_cm, gender, chronotype, max_heart_rate))
      OVER (PARTITION BY participant_id) AS _min_hash,
    MAX(hash(device_id, age, height_cm, gender, chronotype, max_heart_rate))
      OVER (PARTITION BY participant_id) AS _max_hash,
    ROW_NUMBER() OVER (PARTITION BY participant_id ORDER BY device_id) AS _row_num
  FROM ${schema_prefix}_bronze.participants
),
-- Exact duplicates (_min_hash = _max_hash): keep row 1 only (fix, silent).
-- Conflicting duplicates (_min_hash <> _max_hash): keep every copy, all of
-- them flow to _quarantine_reasons below (grain violation, not attribute noise).
deduped AS (
  SELECT * FROM keyed
  WHERE _row_num = 1 OR _min_hash <> _max_hash
),
-- device_id_unique_to_participant needs visibility across the whole deduped
-- set (is this device_id used by more than one participant), not just
-- within one participant's own dup group -- separate CTE, one level up.
cross_checked AS (
  SELECT *, COUNT(*) OVER (PARTITION BY device_id) AS _device_count
  FROM deduped
),
reasoned AS (
  SELECT
    participant_id, device_id, age, height_cm, gender, chronotype, max_heart_rate,
    _source_file, _ingested_at,
    filter(array(
      CASE WHEN NOT (device_id IS NOT NULL) THEN 'device_id_not_null' END,
      CASE WHEN NOT (age BETWEEN 18 AND 90) THEN 'age_plausible' END,
      CASE WHEN NOT (height_cm BETWEEN 140 AND 210) THEN 'height_plausible' END,
      CASE WHEN NOT (gender IN ('male', 'female')) THEN 'gender_known' END,
      CASE WHEN NOT (chronotype IN ('A', 'B')) THEN 'chronotype_known' END,
      CASE WHEN NOT (ABS(max_heart_rate - (220 - age)) <= 30) THEN 'max_heart_rate_plausible' END
    ), x -> x IS NOT NULL) AS _suspect_reasons,
    filter(array(
      CASE WHEN NOT (CAST(SUBSTRING(participant_id, 2, 3) AS INT) BETWEEN 1 AND 50)
        THEN 'participant_number_valid' END,
      CASE WHEN NOT (_device_count = 1) THEN 'device_id_unique_to_participant' END,
      CASE WHEN _min_hash <> _max_hash THEN 'dedup_conflict' END
    ), x -> x IS NOT NULL) AS _quarantine_reasons
  FROM cross_checked
)
SELECT * FROM reasoned;

CREATE OR REFRESH MATERIALIZED VIEW participants (
  CONSTRAINT device_id_not_null EXPECT (NOT array_contains(_suspect_reasons, 'device_id_not_null')),
  CONSTRAINT age_plausible EXPECT (NOT array_contains(_suspect_reasons, 'age_plausible')),
  CONSTRAINT height_plausible EXPECT (NOT array_contains(_suspect_reasons, 'height_plausible')),
  CONSTRAINT gender_known EXPECT (NOT array_contains(_suspect_reasons, 'gender_known')),
  CONSTRAINT chronotype_known EXPECT (NOT array_contains(_suspect_reasons, 'chronotype_known')),
  CONSTRAINT max_heart_rate_plausible EXPECT (NOT array_contains(_suspect_reasons, 'max_heart_rate_plausible'))
)
AS SELECT
  participant_id, device_id, age, height_cm, gender, chronotype, max_heart_rate,
  _source_file, _ingested_at, _suspect_reasons
FROM participants_prepared
WHERE size(_quarantine_reasons) = 0;

CREATE OR REFRESH MATERIALIZED VIEW quarantine_participants
AS SELECT
  participant_id, device_id, age, height_cm, gender, chronotype, max_heart_rate,
  _source_file, _ingested_at, _suspect_reasons, _quarantine_reasons
FROM participants_prepared
WHERE size(_quarantine_reasons) > 0;
