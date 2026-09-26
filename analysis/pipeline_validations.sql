-- =============================================================================
-- Meridian Data Pipeline Validations
-- =============================================================================
-- Run after silver + gold pipeline refreshes to verify no data is silently
-- lost across the Bronze -> Silver -> Gold medallion layers.
--
-- Three validation groups:
--   1. Row Count Reconciliation  -- Bronze -> Silver -> Gold counts
--   2. Participant & Date Coverage -- all 50 participants, all 28 days
--   3. Quarantine Accountability  -- every dropped row has a reason
--
-- Each query returns a `status` column: 'PASS' or 'FAIL' for quick scanning.
-- Any FAIL row indicates data may have been silently lost or corrupted.
-- =============================================================================


-- =============================================================================
-- 1. ROW COUNT RECONCILIATION
-- =============================================================================
-- For each data source, compares row counts across layers and verifies that
-- any row loss is fully explained by quarantine + dedup. A row should never
-- silently disappear -- every loss must be accounted for.

-- 1a. Sleep: expected 1,400 rows throughout (50 participants x 28 nights)
SELECT 'sleep' AS data_source,
  (SELECT COUNT(*) FROM workspace.meridian_bronze.sleep)               AS bronze_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.sleep_prepared)     AS silver_prepared,
  (SELECT COUNT(*) FROM workspace.meridian_silver.sleep_sessions)     AS silver_main,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_sleep_sessions) AS silver_quarantine,
  (SELECT COUNT(*) FROM workspace.meridian_gold.participant_day)     AS gold_count,
  CASE
    WHEN (SELECT COUNT(*) FROM workspace.meridian_silver.sleep_prepared)
       = (SELECT COUNT(*) FROM workspace.meridian_silver.sleep_sessions)
       + (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_sleep_sessions)
     AND (SELECT COUNT(*) FROM workspace.meridian_gold.participant_day) = 1400
    THEN 'PASS' ELSE 'FAIL'
  END AS status;

-- 1b. Wellness: Bronze has 1,414 rows (includes test participant P999)
SELECT 'wellness' AS data_source,
  (SELECT COUNT(*) FROM workspace.meridian_bronze.wellness_survey)    AS bronze_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.wellness)           AS silver_main,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_wellness) AS silver_quarantine,
  (SELECT COUNT(*) FROM workspace.meridian_bronze.wellness_survey)
    - (SELECT COUNT(*) FROM workspace.meridian_silver.wellness)
    - (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_wellness) AS dedup_loss,
  CASE
    WHEN (SELECT COUNT(*) FROM workspace.meridian_bronze.wellness_survey)
       >= (SELECT COUNT(*) FROM workspace.meridian_silver.wellness)
       + (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_wellness)
    THEN 'PASS' ELSE 'FAIL'
  END AS status;

-- 1c. Steps: high-volume, suspect filtering expected
SELECT 'steps' AS data_source,
  (SELECT COUNT(*) FROM workspace.meridian_bronze.steps)              AS bronze_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.steps)             AS silver_main,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_steps)  AS silver_quarantine,
  (SELECT COUNT(*) FROM workspace.meridian_bronze.steps)
    - (SELECT COUNT(*) FROM workspace.meridian_silver.steps)
    - (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_steps) AS dedup_loss,
  CASE
    WHEN (SELECT COUNT(*) FROM workspace.meridian_bronze.steps)
       >= (SELECT COUNT(*) FROM workspace.meridian_silver.steps)
       + (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_steps)
    THEN 'PASS' ELSE 'FAIL'
  END AS status;

-- 1d. Heart Rate: high-volume, suspect filtering expected
SELECT 'heart_rate' AS data_source,
  (SELECT COUNT(*) FROM workspace.meridian_bronze.heart_rate)              AS bronze_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.heart_rate)            AS silver_main,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_heart_rate) AS silver_quarantine,
  (SELECT COUNT(*) FROM workspace.meridian_bronze.heart_rate)
    - (SELECT COUNT(*) FROM workspace.meridian_silver.heart_rate)
    - (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_heart_rate) AS dedup_loss,
  CASE
    WHEN (SELECT COUNT(*) FROM workspace.meridian_bronze.heart_rate)
       >= (SELECT COUNT(*) FROM workspace.meridian_silver.heart_rate)
       + (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_heart_rate)
    THEN 'PASS' ELSE 'FAIL'
  END AS status;

-- 1e. Participants & Device Metadata: small tables, no loss expected
SELECT 'participants' AS data_source,
  (SELECT COUNT(*) FROM workspace.meridian_bronze.participants)           AS bronze_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.participants)          AS silver_main,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_participants) AS silver_quarantine,
  (SELECT COUNT(*) FROM workspace.meridian_gold.participant_study_summary) AS gold_count,
  CASE
    WHEN (SELECT COUNT(*) FROM workspace.meridian_silver.participants) = 50
     AND (SELECT COUNT(*) FROM workspace.meridian_gold.participant_study_summary) = 50
    THEN 'PASS' ELSE 'FAIL'
  END AS status;

SELECT 'device_metadata' AS data_source,
  (SELECT COUNT(*) FROM workspace.meridian_bronze.device_metadata)           AS bronze_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.device_metadata)          AS silver_main,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_device_metadata) AS silver_quarantine,
  CASE
    WHEN (SELECT COUNT(*) FROM workspace.meridian_silver.device_metadata) = 50
    THEN 'PASS' ELSE 'FAIL'
  END AS status;


-- =============================================================================
-- 2. PARTICIPANT & DATE COVERAGE
-- =============================================================================
-- Verifies all 50 participants (P001-P050) and all 28 study days
-- (2026-01-08 to 2026-02-04) are present in every layer.

-- 2a. Participant coverage: every expected participant present in each table
SELECT 'participant_coverage' AS check_name,
  (SELECT COUNT(*) FROM workspace.meridian_silver.participants)                       AS expected_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.participants
   WHERE size(_suspect_reasons) > 0)                                                  AS suspect_count,
  (SELECT COUNT(DISTINCT participant_id) FROM workspace.meridian_silver.sleep_sessions)  AS in_silver_sleep,
  (SELECT COUNT(DISTINCT participant_id) FROM workspace.meridian_silver.wellness)       AS in_silver_wellness,
  (SELECT COUNT(DISTINCT participant_id) FROM workspace.meridian_silver.steps)         AS in_silver_steps,
  (SELECT COUNT(DISTINCT participant_id) FROM workspace.meridian_silver.heart_rate)    AS in_silver_hr,
  (SELECT COUNT(DISTINCT participant_id) FROM workspace.meridian_gold.participant_day) AS in_gold_day,
  (SELECT COUNT(DISTINCT participant_id) FROM workspace.meridian_gold.participant_study_summary) AS in_gold_summary,
  CASE
    WHEN (SELECT COUNT(DISTINCT participant_id) FROM workspace.meridian_silver.sleep_sessions)  = (SELECT COUNT(*) FROM workspace.meridian_silver.participants)
     AND (SELECT COUNT(DISTINCT participant_id) FROM workspace.meridian_gold.participant_day)   = (SELECT COUNT(*) FROM workspace.meridian_silver.participants)
     AND (SELECT COUNT(DISTINCT participant_id) FROM workspace.meridian_gold.participant_study_summary) = (SELECT COUNT(*) FROM workspace.meridian_silver.participants)
    THEN 'PASS' ELSE 'FAIL'
  END AS status;

-- 2b. Missing participants per table (returns rows only if there's a problem)
SELECT 'MISSING PARTICIPANT' AS issue, table_name, participant_id
FROM (
  SELECT 'silver_sleep_sessions' AS table_name, participant_id
  FROM workspace.meridian_silver.participants
  WHERE participant_id NOT IN (SELECT DISTINCT participant_id FROM workspace.meridian_silver.sleep_sessions)
  UNION ALL
  SELECT 'silver_wellness', participant_id
  FROM workspace.meridian_silver.participants
  WHERE participant_id NOT IN (SELECT DISTINCT participant_id FROM workspace.meridian_silver.wellness)
  UNION ALL
  SELECT 'silver_steps', participant_id
  FROM workspace.meridian_silver.participants
  WHERE participant_id NOT IN (SELECT DISTINCT participant_id FROM workspace.meridian_silver.steps)
  UNION ALL
  SELECT 'silver_heart_rate', participant_id
  FROM workspace.meridian_silver.participants
  WHERE participant_id NOT IN (SELECT DISTINCT participant_id FROM workspace.meridian_silver.heart_rate)
  UNION ALL
  SELECT 'gold_participant_day', participant_id
  FROM workspace.meridian_silver.participants
  WHERE participant_id NOT IN (SELECT DISTINCT participant_id FROM workspace.meridian_gold.participant_day)
  UNION ALL
  SELECT 'gold_participant_study_summary', participant_id
  FROM workspace.meridian_silver.participants
  WHERE participant_id NOT IN (SELECT DISTINCT participant_id FROM workspace.meridian_gold.participant_study_summary)
) missing
ORDER BY table_name, participant_id;

-- 2c. Date coverage in gold: all 28 study days present, all 50 participants
SELECT 'date_coverage' AS check_name,
  50 * 28 AS expected_rows,
  (SELECT COUNT(*) FROM workspace.meridian_gold.participant_day) AS actual_rows,
  (SELECT COUNT(DISTINCT date) FROM workspace.meridian_gold.participant_day) AS distinct_dates,
  (SELECT MIN(date) FROM workspace.meridian_gold.participant_day) AS first_date,
  (SELECT MAX(date) FROM workspace.meridian_gold.participant_day) AS last_date,
  CASE
    WHEN (SELECT COUNT(*) FROM workspace.meridian_gold.participant_day) = 1400
     AND (SELECT COUNT(DISTINCT date) FROM workspace.meridian_gold.participant_day) = 28
     AND (SELECT MIN(date) FROM workspace.meridian_gold.participant_day) = DATE'2026-01-08'
     AND (SELECT MAX(date) FROM workspace.meridian_gold.participant_day) = DATE'2026-02-04'
    THEN 'PASS' ELSE 'FAIL'
  END AS status;

-- 2d. Missing participant-day combinations in gold (should return zero rows)
WITH expected AS (
  SELECT p.participant_id, d.date
  FROM workspace.meridian_silver.participants p
  CROSS JOIN (SELECT explode(sequence(DATE'2026-01-08', DATE'2026-02-04')) AS date) d
)
SELECT 'MISSING PARTICIPANT-DAY' AS issue, e.participant_id, e.date
FROM expected e
LEFT JOIN workspace.meridian_gold.participant_day pd
  ON pd.participant_id = e.participant_id AND pd.date = e.date
WHERE pd.participant_id IS NULL
ORDER BY e.participant_id, e.date;

-- 2e. Gold coverage: NULLs in key columns (data that should be present but isn't)
SELECT 'gold_null_coverage' AS check_name,
  COUNT(*) AS total_rows,
  SUM(CASE WHEN asleep_min IS NULL THEN 1 ELSE 0 END)          AS null_sleep,
  SUM(CASE WHEN midsleep_hour IS NULL THEN 1 ELSE 0 END)      AS null_midsleep,
  SUM(CASE WHEN sleep_efficiency_pct IS NULL THEN 1 ELSE 0 END) AS null_efficiency,
  SUM(CASE WHEN avg_heart_rate_bpm IS NULL THEN 1 ELSE 0 END)  AS null_hr,
  SUM(CASE WHEN total_steps = 0 THEN 1 ELSE 0 END)            AS zero_steps,
  SUM(CASE WHEN fatigue_score IS NULL THEN 1 ELSE 0 END)      AS null_wellness,
  CASE
    WHEN SUM(CASE WHEN midsleep_hour IS NULL THEN 1 ELSE 0 END) = 0
     AND SUM(CASE WHEN sleep_efficiency_pct IS NULL THEN 1 ELSE 0 END) = 0
    THEN 'PASS' ELSE 'FAIL'
  END AS status
FROM workspace.meridian_gold.participant_day;


-- =============================================================================
-- 3. QUARANTINE ACCOUNTABILITY
-- =============================================================================
-- For every row that enters silver prepared but doesn't make it to the main
-- table, verify it appears in the quarantine table with a reason. No row
-- should silently disappear -- every loss must have an explanation.
--
-- Each query checks:
--   (a) prepared = main + quarantine  (the split is complete)
--   (b) every quarantined row has at least one reason (no unexplained drops)

-- 3a. Sleep
SELECT 'sleep' AS data_source,
  (SELECT COUNT(*) FROM workspace.meridian_silver.sleep_prepared)          AS prepared_total,
  (SELECT COUNT(*) FROM workspace.meridian_silver.sleep_sessions)         AS main_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_sleep_sessions) AS quarantine_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_sleep_sessions
   WHERE size(_quarantine_reasons) = 0) AS quarantine_without_reason,
  CASE
    WHEN (SELECT COUNT(*) FROM workspace.meridian_silver.sleep_prepared)
       = (SELECT COUNT(*) FROM workspace.meridian_silver.sleep_sessions)
       + (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_sleep_sessions)
     AND (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_sleep_sessions
          WHERE size(_quarantine_reasons) = 0) = 0
    THEN 'PASS' ELSE 'FAIL'
  END AS status;

-- 3b. Steps
SELECT 'steps' AS data_source,
  (SELECT COUNT(*) FROM workspace.meridian_silver.steps_prepared)          AS prepared_total,
  (SELECT COUNT(*) FROM workspace.meridian_silver.steps)                AS main_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_steps)      AS quarantine_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_steps
   WHERE size(_quarantine_reasons) = 0) AS quarantine_without_reason,
  CASE
    WHEN (SELECT COUNT(*) FROM workspace.meridian_silver.steps_prepared)
       = (SELECT COUNT(*) FROM workspace.meridian_silver.steps)
       + (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_steps)
     AND (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_steps
          WHERE size(_quarantine_reasons) = 0) = 0
    THEN 'PASS' ELSE 'FAIL'
  END AS status;

-- 3c. Heart Rate
SELECT 'heart_rate' AS data_source,
  (SELECT COUNT(*) FROM workspace.meridian_silver.heart_rate_prepared)          AS prepared_total,
  (SELECT COUNT(*) FROM workspace.meridian_silver.heart_rate)                  AS main_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_heart_rate)       AS quarantine_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_heart_rate
   WHERE size(_quarantine_reasons) = 0) AS quarantine_without_reason,
  CASE
    WHEN (SELECT COUNT(*) FROM workspace.meridian_silver.heart_rate_prepared)
       = (SELECT COUNT(*) FROM workspace.meridian_silver.heart_rate)
       + (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_heart_rate)
     AND (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_heart_rate
          WHERE size(_quarantine_reasons) = 0) = 0
    THEN 'PASS' ELSE 'FAIL'
  END AS status;

-- 3d. Wellness
SELECT 'wellness' AS data_source,
  (SELECT COUNT(*) FROM workspace.meridian_silver.wellness_prepared)          AS prepared_total,
  (SELECT COUNT(*) FROM workspace.meridian_silver.wellness)                 AS main_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_wellness)      AS quarantine_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_wellness
   WHERE size(_quarantine_reasons) = 0) AS quarantine_without_reason,
  CASE
    WHEN (SELECT COUNT(*) FROM workspace.meridian_silver.wellness_prepared)
       = (SELECT COUNT(*) FROM workspace.meridian_silver.wellness)
       + (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_wellness)
     AND (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_wellness
          WHERE size(_quarantine_reasons) = 0) = 0
    THEN 'PASS' ELSE 'FAIL'
  END AS status;

-- 3e. Participants
SELECT 'participants' AS data_source,
  (SELECT COUNT(*) FROM workspace.meridian_silver.participants_prepared)          AS prepared_total,
  (SELECT COUNT(*) FROM workspace.meridian_silver.participants)                   AS main_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_participants)        AS quarantine_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_participants
   WHERE size(_quarantine_reasons) = 0) AS quarantine_without_reason,
  CASE
    WHEN (SELECT COUNT(*) FROM workspace.meridian_silver.participants_prepared)
       = (SELECT COUNT(*) FROM workspace.meridian_silver.participants)
       + (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_participants)
     AND (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_participants
          WHERE size(_quarantine_reasons) = 0) = 0
    THEN 'PASS' ELSE 'FAIL'
  END AS status;

-- 3f. Device Metadata
SELECT 'device_metadata' AS data_source,
  (SELECT COUNT(*) FROM workspace.meridian_silver.device_metadata_prepared)          AS prepared_total,
  (SELECT COUNT(*) FROM workspace.meridian_silver.device_metadata)                   AS main_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_device_metadata)        AS quarantine_count,
  (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_device_metadata
   WHERE size(_quarantine_reasons) = 0) AS quarantine_without_reason,
  CASE
    WHEN (SELECT COUNT(*) FROM workspace.meridian_silver.device_metadata_prepared)
       = (SELECT COUNT(*) FROM workspace.meridian_silver.device_metadata)
       + (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_device_metadata)
     AND (SELECT COUNT(*) FROM workspace.meridian_silver.quarantine_device_metadata
          WHERE size(_quarantine_reasons) = 0) = 0
    THEN 'PASS' ELSE 'FAIL'
  END AS status;

-- 3g. Quarantine reason breakdown (what reasons are rows being quarantined for?)
SELECT 'quarantine_reasons' AS check_name,
       data_source, reason, cnt
FROM (
  SELECT 'steps' AS data_source, reason, COUNT(*) AS cnt
  FROM workspace.meridian_silver.quarantine_steps
  LATERAL VIEW explode(_quarantine_reasons) AS reason
  GROUP BY reason
  UNION ALL
  SELECT 'heart_rate', reason, COUNT(*)
  FROM workspace.meridian_silver.quarantine_heart_rate
  LATERAL VIEW explode(_quarantine_reasons) AS reason
  GROUP BY reason
  UNION ALL
  SELECT 'wellness', reason, COUNT(*)
  FROM workspace.meridian_silver.quarantine_wellness
  LATERAL VIEW explode(_quarantine_reasons) AS reason
  GROUP BY reason
) t
ORDER BY data_source, cnt DESC;
