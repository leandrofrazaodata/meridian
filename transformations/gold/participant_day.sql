-- Gold transformation: participant_day.
-- See docs/superpowers/specs/2026-09-23-gold-transformations-design.md
-- for the spine/reshape/circular-mean design this and the other two Gold
-- files follow.
--
-- Grain: participant_id x date (one row per participant per study day,
-- 50 x 28 = 1400 rows always, by construction of the spine below).
-- Daily fact table every other Gold table and every dashboard reads
-- from. The only Gold table that reads Silver directly.

CREATE OR REFRESH MATERIALIZED VIEW participant_day
COMMENT 'Daily snapshot per participant -- the single daily fact table every dashboard, report, and other Gold table reads from. Grain: participant_id x date, always exactly 1,400 rows (50 participants x 28 study days) regardless of source completeness.'
AS
WITH spine AS (
  -- Fixed 28-day study window (CLAUDE.md), hardcoded the same way the
  -- rest of this repo hardcodes this one synthetic study's fixed facts
  -- (P001-P050, the 40-200bpm plausibility window, etc). CROSS JOIN +
  -- LEFT JOINs below guarantee every (participant, date) pair exists
  -- regardless of any source's completeness for that day.
  SELECT p.participant_id, p.chronotype, p.age, p.gender, d.date
  FROM ${schema_prefix}_silver.participants p
  CROSS JOIN (
    SELECT explode(sequence(DATE'2026-01-08', DATE'2026-02-04')) AS date
  ) d
),
daily_steps AS (
  SELECT
    participant_id,
    DATE(timestamp) AS date,
    SUM(steps) AS total_steps,
    -- activity_centroid_hour: step-weighted mean hour of activity --
    -- reused verbatim from the prototype (pipeline-architecture.md).
    -- NULLIF guards the all-zero-step day: the centroid is undefined
    -- there, not zero.
    SUM((HOUR(timestamp) + MINUTE(timestamp) / 60.0) * steps)
      / NULLIF(SUM(steps), 0) AS activity_centroid_hour
  FROM ${schema_prefix}_silver.steps
  GROUP BY participant_id, DATE(timestamp)
),
daily_heart_rate AS (
  SELECT
    participant_id,
    DATE(timestamp) AS date,
    -- avg/min/max exclude suspect readings (stuck sensor, implausible
    -- bpm, pid mismatch) -- a flagged run (e.g. a 180-minute stuck-sensor
    -- event) shouldn't drag a whole day's vitals toward one repeated
    -- value. CASE returns NULL for suspect rows; AVG/MIN/MAX skip NULLs.
    AVG(CASE WHEN size(_suspect_reasons) = 0 THEN heart_rate_bpm END) AS avg_heart_rate_bpm,
    MIN(CASE WHEN size(_suspect_reasons) = 0 THEN heart_rate_bpm END) AS min_heart_rate_bpm,
    MAX(CASE WHEN size(_suspect_reasons) = 0 THEN heart_rate_bpm END) AS max_heart_rate_bpm,
    -- Coverage count includes every reading regardless of suspect status
    -- -- the sensor did respond, so it counts toward coverage even if the
    -- value itself isn't trusted for the vitals above.
    COUNT(*) AS heart_rate_reading_count
  FROM ${schema_prefix}_silver.heart_rate
  GROUP BY participant_id, DATE(timestamp)
)
SELECT
  spine.participant_id,
  spine.date,
  spine.chronotype,
  spine.age,
  spine.gender,
  ss.asleep_min,
  CAST(ss.midsleep_hour AS DECIMAL(18,2)) AS midsleep_hour,
  CAST(ss.efficiency_pct_derived AS DECIMAL(18,2)) AS sleep_efficiency_pct,
  CAST(ss.restlessness AS DECIMAL(18,2)) AS restlessness,
  COALESCE(st.total_steps, 0) AS total_steps,
  CAST(st.activity_centroid_hour AS DECIMAL(18,2)) AS activity_centroid_hour,
  CAST(hr.avg_heart_rate_bpm AS DECIMAL(18,2)) AS avg_heart_rate_bpm,
  hr.min_heart_rate_bpm,
  hr.max_heart_rate_bpm,
  COALESCE(hr.heart_rate_reading_count, 0) AS heart_rate_reading_count,
  COALESCE(hr.heart_rate_reading_count, 0) < 0.80 * 1440 AS is_provisional,
  w.fatigue_score,
  w.stress_score,
  w.readiness_score,
  w.sleep_quality_score
FROM spine
LEFT JOIN ${schema_prefix}_silver.sleep_sessions ss
  ON ss.participant_id = spine.participant_id AND ss.date = spine.date
LEFT JOIN daily_steps st
  ON st.participant_id = spine.participant_id AND st.date = spine.date
LEFT JOIN daily_heart_rate hr
  ON hr.participant_id = spine.participant_id AND hr.date = spine.date
LEFT JOIN ${schema_prefix}_silver.wellness w
  ON w.participant_id = spine.participant_id AND w.date = spine.date;
