-- Gold transformation: participant_study_summary.
-- See docs/superpowers/specs/2026-09-23-gold-transformations-design.md.
--
-- Grain: participant_id (one row per participant, 50 rows), the whole
-- 28-day study window. Reshaped directly from participant_day, like
-- participant_week -- NOT chained through participant_week. Chaining
-- would be exact for AVG/MIN/MAX/SUM (every week has the same 7-day
-- count), but not for the circular-mean columns: a week's circular mean
-- keeps only the resulting angle, not the underlying dispersion, so
-- re-averaging 4 already-collapsed angles isn't guaranteed to equal the
-- circular mean of all 28 raw nights. Reshaping both Gold tables
-- directly from participant_day sidesteps the question.
--
-- Column set is intentionally identical to participant_week.sql plus
-- study_week -- change both together.

CREATE OR REFRESH MATERIALIZED VIEW participant_study_summary
COMMENT 'One row per participant summarizing the full 28-day study window -- the table chronotype cohort comparison (e.g. chronotype A vs B) reads from. Grain: participant_id, 50 rows always. Reshaped directly from participant_day.'
AS
SELECT
  participant_id,
  MAX(chronotype) AS chronotype,
  MAX(age) AS age,
  MAX(gender) AS gender,
  CAST(AVG(asleep_min) AS DECIMAL(18,2)) AS avg_asleep_min,
  -- Circular mean -- see participant_week.sql and the design spec doc
  -- for the full explanation and the empirical evidence (7 of 50
  -- participants) motivating it.
  CAST(MOD(
    DEGREES(ATAN2(
      AVG(SIN(RADIANS(midsleep_hour * 15))),
      AVG(COS(RADIANS(midsleep_hour * 15)))
    )) + 360,
    360
  ) / 15 AS DECIMAL(18,2)) AS avg_midsleep_hour,
  CAST(AVG(sleep_efficiency_pct) AS DECIMAL(18,2)) AS avg_sleep_efficiency_pct,
  CAST(AVG(restlessness) AS DECIMAL(18,2)) AS avg_restlessness,
  CAST(AVG(total_steps) AS DECIMAL(18,2)) AS avg_daily_steps,
  CAST(MOD(
    DEGREES(ATAN2(
      AVG(SIN(RADIANS(activity_centroid_hour * 15))),
      AVG(COS(RADIANS(activity_centroid_hour * 15)))
    )) + 360,
    360
  ) / 15 AS DECIMAL(18,2)) AS avg_activity_centroid_hour,
  CAST(AVG(avg_heart_rate_bpm) AS DECIMAL(18,2)) AS avg_heart_rate_bpm,
  MIN(min_heart_rate_bpm) AS min_heart_rate_bpm,
  MAX(max_heart_rate_bpm) AS max_heart_rate_bpm,
  SUM(heart_rate_reading_count) AS total_heart_rate_reading_count,
  SUM(heart_rate_reading_count) < 0.80 * 28 * 1440 AS is_provisional,
  CAST(AVG(fatigue_score) AS DECIMAL(18,2)) AS avg_fatigue_score,
  CAST(AVG(stress_score) AS DECIMAL(18,2)) AS avg_stress_score,
  CAST(AVG(readiness_score) AS DECIMAL(18,2)) AS avg_readiness_score,
  CAST(AVG(sleep_quality_score) AS DECIMAL(18,2)) AS avg_sleep_quality_score
FROM ${schema_prefix}_gold.participant_day
GROUP BY participant_id;
