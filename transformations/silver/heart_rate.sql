-- Silver transformation for contracts/heart_rate.yml.
-- See docs/superpowers/specs/2026-09-22-silver-transformations-design.md.

CREATE OR REFRESH MATERIALIZED VIEW heart_rate_prepared (
  CONSTRAINT ts_not_null EXPECT (timestamp IS NOT NULL) ON VIOLATION FAIL UPDATE
)
AS
WITH source AS (
  SELECT
    -- contracts/heart_rate.yml: mostly naive local (UTC-05:00), occasionally
    -- Z-suffixed UTC -- normalize explicitly. ASSUMES Bronze's `timestamp`
    -- column survived COPY INTO's schema inference as text (castable to
    -- STRING with the original 'Z' intact), per the design spec doc's
    -- "Bronze timestamp physical type" risk -- unverified without a live
    -- workspace. If a live `DESCRIBE TABLE ${schema_prefix}_bronze.heart_rate`
    -- ever shows this column already parsed to native TIMESTAMP, this
    -- branch needs rework (the 'Z' marker is unrecoverable once collapsed
    -- into a single TIMESTAMP without extra bookkeeping upstream in Bronze).
    -- Z-suffixed rows carry a real UTC offset: stripping the 'Z' and
    -- re-parsing recovers the true-UTC digits (e.g. '14:16:00'), so shift
    -- -5h to land on the same UTC-05:00 local digits ('09:16:00') every
    -- naive row already carries natively -- the naive branch needs no
    -- shift at all, it's already in the target convention.
    CASE
      WHEN CAST(timestamp AS STRING) RLIKE 'Z$'
        THEN to_timestamp(regexp_replace(CAST(timestamp AS STRING), 'Z$', '')) - INTERVAL 5 HOURS
      ELSE CAST(timestamp AS TIMESTAMP)
    END AS timestamp,
    heart_rate_bpm,
    participant_id,
    _pid_from_path,
    _source_file,
    _ingested_at
  FROM ${schema_prefix}_bronze.heart_rate
),
keyed AS (
  SELECT
    *,
    MIN(heart_rate_bpm) OVER (PARTITION BY participant_id, timestamp) AS _min_bpm,
    MAX(heart_rate_bpm) OVER (PARTITION BY participant_id, timestamp) AS _max_bpm,
    ROW_NUMBER() OVER (PARTITION BY participant_id, timestamp ORDER BY heart_rate_bpm) AS _row_num
  FROM source
),
deduped AS (
  SELECT * FROM keyed
  WHERE _row_num = 1 OR _min_bpm <> _max_bpm
),
-- Run-length ordering excludes conflicting-dup rows -- they're quarantined
-- outright below, not meaningfully orderable into the series.
ordered AS (
  SELECT
    *,
    LAG(heart_rate_bpm) OVER (PARTITION BY participant_id ORDER BY timestamp) AS _prev_bpm,
    LAG(timestamp) OVER (PARTITION BY participant_id ORDER BY timestamp) AS _prev_ts
  FROM deduped
  WHERE _min_bpm = _max_bpm
),
run_marked AS (
  SELECT
    *,
    CASE
      WHEN _prev_ts IS NULL THEN 1
      WHEN heart_rate_bpm <> _prev_bpm THEN 1
      WHEN timestamp > _prev_ts + INTERVAL 2 MINUTES THEN 1
      ELSE 0
    END AS _is_new_run
  FROM ordered
),
run_grouped AS (
  SELECT
    *,
    SUM(_is_new_run) OVER (
      PARTITION BY participant_id ORDER BY timestamp
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS _run_id
  FROM run_marked
),
run_lengths AS (
  SELECT *, COUNT(*) OVER (PARTITION BY participant_id, _run_id) AS _run_length
  FROM run_grouped
),
reasoned AS (
  SELECT
    timestamp, heart_rate_bpm, participant_id, _source_file, _ingested_at,
    filter(array(
      CASE WHEN NOT (heart_rate_bpm BETWEEN 40 AND 200) THEN 'hr_plausible' END,
      CASE WHEN NOT (participant_id = _pid_from_path) THEN 'pid_matches_path' END,
      -- 15-minute threshold: empirically derived (see design spec doc) --
      -- organic runs top out at 8 minutes; the only real stuck-sensor events
      -- in the current dataset run 180 minutes. 15 sits cleanly in the gap.
      CASE WHEN _run_length >= 15 THEN 'stuck_sensor' END
    ), x -> x IS NOT NULL) AS _suspect_reasons,
    CAST(array() AS ARRAY<STRING>) AS _quarantine_reasons
  FROM run_lengths
  UNION ALL
  SELECT
    timestamp, heart_rate_bpm, participant_id, _source_file, _ingested_at,
    CAST(array() AS ARRAY<STRING>) AS _suspect_reasons,
    array('dedup_conflict') AS _quarantine_reasons
  FROM deduped
  WHERE _min_bpm <> _max_bpm
)
SELECT * FROM reasoned;

CREATE OR REFRESH MATERIALIZED VIEW heart_rate (
  CONSTRAINT hr_plausible EXPECT (NOT array_contains(_suspect_reasons, 'hr_plausible')),
  CONSTRAINT pid_matches_path EXPECT (NOT array_contains(_suspect_reasons, 'pid_matches_path')),
  CONSTRAINT stuck_sensor EXPECT (NOT array_contains(_suspect_reasons, 'stuck_sensor'))
)
AS SELECT
  timestamp, heart_rate_bpm, participant_id, _source_file, _ingested_at, _suspect_reasons
FROM heart_rate_prepared
WHERE size(_quarantine_reasons) = 0;

CREATE OR REFRESH MATERIALIZED VIEW quarantine_heart_rate
AS SELECT
  timestamp, heart_rate_bpm, participant_id, _source_file, _ingested_at,
  _suspect_reasons, _quarantine_reasons
FROM heart_rate_prepared
WHERE size(_quarantine_reasons) > 0;
