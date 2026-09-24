-- Analytical query: chronotype cohort comparison.
-- Compares chronotype A (morning type) vs B (evening type) across
-- sleep, wellness, activity, and heart-rate metrics in one pass --
-- participant_study_summary is the table docs/gold-layer.md names
-- specifically for this comparison (one row per participant, whole
-- 28-day study window, chronotype denormalized onto it already).
-- Grain: one row per chronotype (2 rows).

SELECT
  chronotype,
  COUNT(*) AS participant_count,
  ROUND(AVG(avg_sleep_efficiency_pct), 1) AS avg_sleep_efficiency_pct,
  ROUND(AVG(avg_asleep_min), 0) AS avg_asleep_min,
  ROUND(AVG(avg_readiness_score), 2) AS avg_readiness_score,
  ROUND(AVG(avg_stress_score), 2) AS avg_stress_score,
  ROUND(AVG(avg_daily_steps), 0) AS avg_daily_steps,
  ROUND(AVG(avg_heart_rate_bpm), 1) AS avg_heart_rate_bpm
FROM workspace.meridian_gold.participant_study_summary
GROUP BY chronotype
ORDER BY chronotype;
