-- Analytical query: heart-rate data-quality coverage.
-- is_provisional flags a participant-day where under 80% of the
-- expected 1,440 per-minute heart-rate readings came through -- a
-- pipeline-native data-quality signal (docs/gold-layer.md), not a
-- health metric. Reported overall and by chronotype, to check sensor
-- dropout isn't lopsided across cohorts.
-- Grain: one row overall + one row per chronotype (3 rows).

SELECT
  'overall' AS cohort,
  COUNT(*) AS participant_days,
  SUM(CAST(is_provisional AS INT)) AS provisional_days,
  ROUND(100.0 * SUM(CAST(is_provisional AS INT)) / COUNT(*), 1) AS provisional_pct
FROM workspace.meridian_gold.participant_day
UNION ALL
SELECT
  chronotype AS cohort,
  COUNT(*) AS participant_days,
  SUM(CAST(is_provisional AS INT)) AS provisional_days,
  ROUND(100.0 * SUM(CAST(is_provisional AS INT)) / COUNT(*), 1) AS provisional_pct
FROM workspace.meridian_gold.participant_day
GROUP BY chronotype
ORDER BY cohort;
