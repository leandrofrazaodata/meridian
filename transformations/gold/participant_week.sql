-- Gold transformation: participant_week.
-- See docs/superpowers/specs/2026-09-23-gold-transformations-design.md.
--
-- Grain: participant_id x study_week (1-4). Reshaped directly from
-- participant_day -- not recomputed from Silver, and not chained
-- through participant_study_summary or vice versa. study_week is
-- study-relative, not calendar: the study starts on a Thursday
-- (2026-01-08), so calendar weeks would produce uneven boundary weeks.
-- The anchor date is read from participant_day's own MIN(date) rather
-- than a second hardcoded copy of the study start date, so the two
-- tables can't drift out of sync with each other.
--
-- Column set is intentionally identical to participant_study_summary.sql
-- minus study_week -- change both together.

CREATE OR REFRESH MATERIALIZED VIEW participant_week
COMMENT 'Weekly reshape of participant_day for the biostatistics team''s weekly batch cadence. Grain: participant_id x study_week (1-4), 200 rows always. Every metric is a straight reshape of participant_day -- nothing here is recomputed from Silver.'
AS
WITH with_week AS (
  SELECT
    *,
    FLOOR(DATEDIFF(date, MIN(date) OVER ()) / 7) + 1 AS study_week
  FROM ${schema_prefix}_gold.participant_day
)
SELECT
  participant_id,
  study_week,
  MAX(chronotype) AS chronotype,
  MAX(age) AS age,
  MAX(gender) AS gender,
  CAST(AVG(asleep_min) AS DECIMAL(18,2)) AS avg_asleep_min,
  -- Circular mean, not a plain AVG: midsleep_hour is a clock time, and a
  -- naive average breaks whenever a participant's nights straddle
  -- midnight (e.g. one night at 23.8, another at 0.7, naive AVG ~12.2 --
  -- nowhere near the true ~0.25). Confirmed against real data: 7 of 50
  -- participants have this in their actual sleep sessions (see spec
  -- doc). Convert each night's hour to a point on the 24h clock, average
  -- the unit vectors, convert back; normalize the result to [0, 24).
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
  -- Same circular-mean treatment as avg_midsleep_hour, applied
  -- proactively -- an hour-of-day column has the identical wraparound
  -- exposure even though this one hasn't been independently re-verified
  -- against real data the way midsleep_hour was.
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
  SUM(heart_rate_reading_count) < 0.80 * 7 * 1440 AS is_provisional,
  CAST(AVG(fatigue_score) AS DECIMAL(18,2)) AS avg_fatigue_score,
  CAST(AVG(stress_score) AS DECIMAL(18,2)) AS avg_stress_score,
  CAST(AVG(readiness_score) AS DECIMAL(18,2)) AS avg_readiness_score,
  CAST(AVG(sleep_quality_score) AS DECIMAL(18,2)) AS avg_sleep_quality_score
FROM with_week
GROUP BY participant_id, study_week;
