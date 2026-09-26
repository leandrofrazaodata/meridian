-- Silver transformation for contracts/sleep.yml.
-- Produces two Silver entities at different grains from one Bronze source
-- (docs/conventions.md): sleep_sessions (one row per night) and
-- sleep_stages (one row per stage within a night), both derived from the
-- shared sleep_prepared view below.

CREATE OR REFRESH MATERIALIZED VIEW sleep_prepared
AS
WITH keyed AS (
  SELECT
    *,
    -- hash() over a nested array<struct<...>> column: Spark's hash()
    -- supports complex types directly. If this ever proves unreliable in
    -- practice, hash(to_json(stages)) is the fallback.
    MIN(hash(sleep_onset, sleep_end, efficiency_pct, restlessness, stages))
      OVER (PARTITION BY participant_id, date) AS _min_hash,
    MAX(hash(sleep_onset, sleep_end, efficiency_pct, restlessness, stages))
      OVER (PARTITION BY participant_id, date) AS _max_hash,
    ROW_NUMBER() OVER (PARTITION BY participant_id, date ORDER BY sleep_onset) AS _row_num
  FROM ${schema_prefix}_bronze.sleep
),
deduped AS (
  SELECT * FROM keyed
  WHERE _row_num = 1 OR _min_hash <> _max_hash
),
derived AS (
  SELECT
    *,
    -- asleep_min: total minutes across every non-'awake' stage. Start
    -- value is explicitly BIGINT: stages.duration_min is BIGINT, and
    -- Spark's aggregate() requires the zero/start value's type to match
    -- the merge lambda's return type exactly (no implicit widening) --
    -- a bare `0` infers INT and fails to resolve against live Spark with
    -- DATATYPE_MISMATCH.UNEXPECTED_INPUT_TYPE (SQLSTATE 42K09). Confirmed
    -- against a live pipeline run on 2026-09-23.
    aggregate(
      filter(stages, s -> s.stage != 'awake'), CAST(0 AS BIGINT), (acc, s) -> acc + s.duration_min
    ) AS asleep_min,
    -- Midpoint instant, as epoch seconds -- named here so midsleep_hour
    -- (next CTE) can derive HOUR/MINUTE/SECOND from one shared value
    -- instead of repeating this expression three times. unix_timestamp()
    -- interprets both ends in the same (session) timezone and the later
    -- HOUR/MINUTE/SECOND extraction reads back in that same timezone, so
    -- the round trip is correct regardless of what that timezone actually
    -- is -- it never needs to match true UTC.
    -- Format string is required: sleep_onset/sleep_end are STRING in ISO 8601
    -- ("2026-01-07T22:54:29.000"). The bare unix_timestamp() defaults to
    -- "yyyy-MM-dd HH:mm:ss" which cannot parse the T separator and silently
    -- returns NULL, which made midsleep_hour NULL for every row.
    (unix_timestamp(sleep_onset, "yyyy-MM-dd'T'HH:mm:ss.SSS") + unix_timestamp(sleep_end, "yyyy-MM-dd'T'HH:mm:ss.SSS")) / 2 AS _midsleep_epoch
  FROM deduped
),
with_midsleep AS (
  SELECT
    *,
    -- midsleep_hour: clock-time midpoint of the session, as a fractional
    -- hour (e.g. 3.5 = 3:30am) -- canonical chronotype-cohort metric,
    -- pipeline-architecture.md.
    HOUR(timestamp_seconds(_midsleep_epoch))
      + MINUTE(timestamp_seconds(_midsleep_epoch)) / 60.0
      + SECOND(timestamp_seconds(_midsleep_epoch)) / 3600.0
    AS midsleep_hour
  FROM derived
),
reconciled AS (
  SELECT
    *,
    efficiency_pct AS efficiency_pct_source,
    -- Guarded against sleep_onset >= sleep_end (session_valid violations,
    -- quarantined below anyway) to avoid a divide-by-zero/negative-duration
    -- computation on rows that will end up in quarantine regardless.
    CASE WHEN sleep_end > sleep_onset
      THEN 100.0 * asleep_min / ((unix_timestamp(sleep_end, "yyyy-MM-dd'T'HH:mm:ss.SSS") - unix_timestamp(sleep_onset, "yyyy-MM-dd'T'HH:mm:ss.SSS")) / 60.0)
      ELSE NULL
    END AS efficiency_pct_derived
  FROM with_midsleep
),
reasoned AS (
  SELECT
    participant_id, date, sleep_onset, sleep_end,
    efficiency_pct_source, efficiency_pct_derived, restlessness,
    stages, asleep_min, midsleep_hour, _source_file, _ingested_at,
    filter(array(
      -- Fixed 5-element expected shape (light/deep/rem/light/awake) --
      -- guaranteed by data_dictionary.md's documented stage-order gotcha.
      -- Array-length mismatches make this comparison false safely (not an
      -- error) -- unlike stage_contiguous below, which indexes
      -- positionally and needs an explicit length guard for the same case.
      CASE WHEN NOT (transform(stages, s -> s.stage) = array('light', 'deep', 'rem', 'light', 'awake'))
        THEN 'stage_order_expected' END,
      CASE WHEN NOT (asleep_min BETWEEN 120 AND 720) THEN 'duration_plausible' END,
      CASE WHEN NOT (efficiency_pct_derived IS NOT NULL
                     AND abs(efficiency_pct_derived - efficiency_pct_source) < 5)
        THEN 'efficiency_reconciles' END,
      -- Positional indexing below assumes exactly 5 stages -- guarded by a
      -- nested CASE (which short-circuits; a bare AND chain is not
      -- guaranteed to) so a malformed session with a different element
      -- count fails safely into the flag rather than throwing
      -- ArrayIndexOutOfBoundsException under Spark's ANSI mode. A session
      -- that fails this guard has already failed stage_order_expected too
      -- (that check is array-length-safe by construction, via equality
      -- rather than indexing) -- this isn't a silent miss.
      CASE WHEN NOT (
        CASE WHEN size(stages) = 5 THEN
          stages[0].end_time = stages[1].start_time AND
          stages[1].end_time = stages[2].start_time AND
          stages[2].end_time = stages[3].start_time AND
          stages[3].end_time = stages[4].start_time
        ELSE false END
      ) THEN 'stage_contiguous' END,
      CASE WHEN array_contains(
        transform(stages, s -> s.duration_min <> CAST((unix_timestamp(s.end_time, "yyyy-MM-dd'T'HH:mm:ss.SSS") - unix_timestamp(s.start_time, "yyyy-MM-dd'T'HH:mm:ss.SSS")) / 60 AS INT)),
        true
      ) THEN 'stage_duration_consistent' END,
      CASE WHEN NOT (restlessness IS NULL OR restlessness BETWEEN 0 AND 1)
        THEN 'restlessness_in_range' END
    ), x -> x IS NOT NULL) AS _suspect_reasons,
    filter(array(
      CASE WHEN NOT (sleep_onset < sleep_end) THEN 'session_valid' END,
      CASE WHEN _min_hash <> _max_hash THEN 'dedup_conflict' END
    ), x -> x IS NOT NULL) AS _quarantine_reasons
  FROM reconciled
)
SELECT * FROM reasoned;

CREATE OR REFRESH MATERIALIZED VIEW sleep_sessions (
  CONSTRAINT stage_order_expected EXPECT (NOT array_contains(_suspect_reasons, 'stage_order_expected')),
  CONSTRAINT duration_plausible EXPECT (NOT array_contains(_suspect_reasons, 'duration_plausible')),
  CONSTRAINT efficiency_reconciles EXPECT (NOT array_contains(_suspect_reasons, 'efficiency_reconciles')),
  CONSTRAINT stage_contiguous EXPECT (NOT array_contains(_suspect_reasons, 'stage_contiguous')),
  CONSTRAINT stage_duration_consistent EXPECT (NOT array_contains(_suspect_reasons, 'stage_duration_consistent')),
  CONSTRAINT restlessness_in_range EXPECT (NOT array_contains(_suspect_reasons, 'restlessness_in_range'))
)
AS SELECT
  participant_id, date, sleep_onset, sleep_end,
  efficiency_pct_source, efficiency_pct_derived, restlessness,
  asleep_min, midsleep_hour, _source_file, _ingested_at, _suspect_reasons
FROM sleep_prepared
WHERE size(_quarantine_reasons) = 0;

CREATE OR REFRESH MATERIALIZED VIEW quarantine_sleep_sessions
AS SELECT
  participant_id, date, sleep_onset, sleep_end,
  efficiency_pct_source, efficiency_pct_derived, restlessness,
  stages, asleep_min, midsleep_hour, _source_file, _ingested_at,
  _suspect_reasons, _quarantine_reasons
FROM sleep_prepared
WHERE size(_quarantine_reasons) > 0;

-- Different grain: one row per stage, not per session. Explodes from the
-- shared prepared view (still has `stages`), filtered to the same
-- non-quarantined sessions sleep_sessions uses -- a stage from a
-- quarantined session shouldn't appear here either.
CREATE OR REFRESH MATERIALIZED VIEW sleep_stages
AS
SELECT
  participant_id,
  date,
  pos AS stage_index,
  stage.stage AS stage,
  stage.start_time AS start_time,
  stage.end_time AS end_time,
  stage.duration_min AS duration_min,
  _source_file,
  _ingested_at
FROM sleep_prepared
LATERAL VIEW POSEXPLODE(stages) AS pos, stage
WHERE size(_quarantine_reasons) = 0;
