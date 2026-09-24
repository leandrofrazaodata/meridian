-- Analytical query: does daily activity relate to that night's sleep?
-- Buckets every participant-day into activity terciles (low/med/high
-- total_steps) and compares avg sleep_efficiency_pct and
-- avg readiness_score per bucket -- a cross-metric relationship
-- question, not a straight reshape of one Gold column. total_steps is
-- never NULL in participant_day (0 on a genuine zero-step day, per
-- docs/gold-layer.md), so every row buckets cleanly.
-- Grain: one row per activity tercile (3 rows).

WITH buckets AS (
  SELECT
    *,
    NTILE(3) OVER (ORDER BY total_steps) AS activity_tercile
  FROM workspace.meridian_gold.participant_day
)
SELECT
  CASE activity_tercile
    WHEN 1 THEN 'low activity'
    WHEN 2 THEN 'medium activity'
    WHEN 3 THEN 'high activity'
  END AS activity_level,
  COUNT(*) AS participant_days,
  MIN(total_steps) AS min_steps_in_bucket,
  MAX(total_steps) AS max_steps_in_bucket,
  ROUND(AVG(sleep_efficiency_pct), 1) AS avg_sleep_efficiency_pct,
  ROUND(AVG(readiness_score), 2) AS avg_readiness_score
FROM buckets
GROUP BY activity_tercile
ORDER BY activity_tercile;
