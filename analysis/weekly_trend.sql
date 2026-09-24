-- Analytical query: cohort-wide trend across the 4-week study.
-- Averages every metric across all 50 participants per study_week, to
-- see whether sleep quality, readiness, or activity drift as the study
-- progresses (e.g. fatigue accumulating, engagement dropping off).
-- Grain: one row per study_week (4 rows).

SELECT
  study_week,
  ROUND(AVG(avg_sleep_efficiency_pct), 1) AS avg_sleep_efficiency_pct,
  ROUND(AVG(avg_readiness_score), 2) AS avg_readiness_score,
  ROUND(AVG(avg_fatigue_score), 2) AS avg_fatigue_score,
  ROUND(AVG(avg_daily_steps), 0) AS avg_daily_steps
FROM workspace.meridian_gold.participant_week
GROUP BY study_week
ORDER BY study_week;
