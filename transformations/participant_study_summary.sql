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

CREATE OR REFRESH MATERIALIZED VIEW ${schema_prefix}_gold.participant_study_summary
COMMENT 'One row per participant summarizing the full 28-day study window -- the table chronotype cohort comparison (e.g. chronotype A vs B) reads from. Grain: participant_id, 50 rows always. Reshaped directly from participant_day.'
AS
SELECT
  participant_id,
  MAX(chronotype) AS chronotype,
  MAX(age) AS age,
  MAX(gender) AS gender,
  AVG(asleep_min) AS avg_asleep_min,
  -- Circular mean -- see participant_week.sql and the design spec doc
  -- for the full explanation and the empirical evidence (7 of 50
  -- participants) motivating it.
  MOD(
    DEGREES(ATAN2(
      AVG(SIN(RADIANS(midsleep_hour * 15))),
      AVG(COS(RADIANS(midsleep_hour * 15)))
    )) + 360,
    360
  ) / 15 AS avg_midsleep_hour,
  AVG(sleep_efficiency_pct) AS avg_sleep_efficiency_pct,
  AVG(restlessness) AS avg_restlessness,
  AVG(total_steps) AS avg_daily_steps,
  MOD(
    DEGREES(ATAN2(
      AVG(SIN(RADIANS(activity_centroid_hour * 15))),
      AVG(COS(RADIANS(activity_centroid_hour * 15)))
    )) + 360,
    360
  ) / 15 AS avg_activity_centroid_hour,
  AVG(avg_heart_rate_bpm) AS avg_heart_rate_bpm,
  MIN(min_heart_rate_bpm) AS min_heart_rate_bpm,
  MAX(max_heart_rate_bpm) AS max_heart_rate_bpm,
  SUM(heart_rate_reading_count) AS total_heart_rate_reading_count,
  SUM(heart_rate_reading_count) < 0.80 * 28 * 1440 AS is_provisional,
  AVG(fatigue_score) AS avg_fatigue_score,
  AVG(stress_score) AS avg_stress_score,
  AVG(readiness_score) AS avg_readiness_score,
  AVG(sleep_quality_score) AS avg_sleep_quality_score
FROM ${schema_prefix}_gold.participant_day
GROUP BY participant_id;
