-- Silver transformation for contracts/device_metadata.yml.
-- See docs/superpowers/specs/2026-09-22-silver-transformations-design.md.

CREATE OR REFRESH MATERIALIZED VIEW device_metadata_prepared (
  CONSTRAINT device_id_not_null EXPECT (device_id IS NOT NULL) ON VIOLATION FAIL UPDATE
)
AS
WITH source AS (
  SELECT
    participant_id,
    device_id,
    wear_site,
    calibration_date,
    -- firmware_backfilled (fix, no reason code): firmware_version is blank
    -- for 15 of 50 real rows -- device_label always carries the true value
    -- (contracts/device_metadata.yml). Regex verified against all 50 real
    -- device_label values: 0 unmatched, and on the 35 rows where
    -- firmware_version is already populated, the regex-extracted value
    -- matches it exactly in all 35 -- safe to trust on the 15 blank rows.
    COALESCE(firmware_version, regexp_extract(device_label, 'fw([0-9.]+)', 1)) AS firmware_version,
    device_label,
    _source_file,
    _ingested_at
  FROM ${schema_prefix}_bronze.device_metadata
),
keyed AS (
  SELECT
    *,
    MIN(hash(participant_id, wear_site, calibration_date, firmware_version, device_label))
      OVER (PARTITION BY device_id) AS _min_hash,
    MAX(hash(participant_id, wear_site, calibration_date, firmware_version, device_label))
      OVER (PARTITION BY device_id) AS _max_hash,
    ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY participant_id) AS _row_num
  FROM source
),
deduped AS (
  SELECT * FROM keyed
  WHERE _row_num = 1 OR _min_hash <> _max_hash
),
-- participant_exists needs its own step, not an inline IN (SELECT ...)
-- the way it originally read: Spark disallows subquery expressions
-- anywhere inside a higher-order function call (filter/transform/
-- aggregate/...), including in a non-lambda argument like the array()
-- below -- UNSUPPORTED_SUBQUERY_EXPRESSION_CATEGORY.HIGHER_ORDER_FUNCTION
-- (SQLSTATE 0A000), confirmed against a live pipeline run on 2026-09-23.
-- Computed here as a plain boolean column so `reasoned` below only ever
-- references a column inside filter(), never a subquery.
with_participant_check AS (
  SELECT
    *,
    EXISTS (
      SELECT 1 FROM ${schema_prefix}_silver.participants p
      WHERE p.participant_id = deduped.participant_id
    ) AS _participant_exists
  FROM deduped
),
reasoned AS (
  SELECT
    participant_id, device_id, wear_site, calibration_date, firmware_version, device_label,
    _source_file, _ingested_at,
    filter(array(
      CASE WHEN NOT (wear_site IN ('wrist_dominant', 'wrist_nondominant')) THEN 'wear_site_known' END
    ), x -> x IS NOT NULL) AS _suspect_reasons,
    filter(array(
      CASE WHEN NOT (participant_id IS NOT NULL) THEN 'participant_id_not_null' END,
      -- NULL-guarded to match the original `IN (SELECT ...)`'s
      -- short-circuit: NULL IN (...) is NULL, so CASE WHEN NOT (NULL)
      -- never fired -- a null participant_id was already fully covered
      -- by participant_id_not_null above and shouldn't double up here.
      CASE WHEN participant_id IS NOT NULL AND NOT _participant_exists THEN 'participant_exists' END,
      CASE WHEN _min_hash <> _max_hash THEN 'dedup_conflict' END
    ), x -> x IS NOT NULL) AS _quarantine_reasons
  FROM with_participant_check
)
SELECT * FROM reasoned;

CREATE OR REFRESH MATERIALIZED VIEW device_metadata (
  CONSTRAINT wear_site_known EXPECT (NOT array_contains(_suspect_reasons, 'wear_site_known'))
)
AS SELECT
  participant_id, device_id, wear_site, calibration_date, firmware_version, device_label,
  _source_file, _ingested_at, _suspect_reasons
FROM device_metadata_prepared
WHERE size(_quarantine_reasons) = 0;

CREATE OR REFRESH MATERIALIZED VIEW quarantine_device_metadata
AS SELECT
  participant_id, device_id, wear_site, calibration_date, firmware_version, device_label,
  _source_file, _ingested_at, _suspect_reasons, _quarantine_reasons
FROM device_metadata_prepared
WHERE size(_quarantine_reasons) > 0;
