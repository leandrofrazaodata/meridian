# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository contents

This repo is becoming a data engineering pipeline built on top of a raw
synthetic health/wearables dataset (`data/`). `deploy/scripts/` (the
Unity Catalog schema-lifecycle scripts) has a `pytest` suite — run it
from `deploy/scripts/` with `pytest`. No build/lint/test tooling exists
yet for the rest of the repo — it will be added as the pipeline takes
shape.

## Documentation map

Detail docs are kept separate from this file and filled in incrementally —
read the relevant one before working in that area rather than expecting
everything here:

- `docs/pipeline-architecture.md` — stages, data flow, storage layers, how components connect
- `docs/gold-layer.md` — Gold table purpose, grain, and consumption guidance for dashboards/reports
- `docs/validation-rules.md` — what "valid" means per dataset/stage
- `docs/conventions.md` — naming, coding patterns, style rules
- `docs/deployment-strategy.md` — how Databricks objects (schemas, job, pipeline) get created and destroyed; step-by-step run commands are in `deploy/README.md`
- `contracts/*.yml` — per-source data contracts (schema, natural key, quality rules); see `contracts/README.md`
- `data/data_dictionary.md` — source dataset schema (see below)

## Dataset overview

Synthetic PMData-style study: 50 participants (`P001`–`P050`) wearing a Fitbit
for 28 days (`2026-01-08` → `2026-02-04`). Full schema is in
`data/data_dictionary.md` — read it before writing analysis code, since several
fields require cross-referencing multiple files (see gotchas below).

```
data/
  participants/participants.csv       # 50 rows: demographics, device_id, max_heart_rate
  health_summaries/
    device_metadata.csv               # 50 rows: per-device calibration/firmware info
    wellness_survey.csv               # ~1400 rows: daily self-reported fatigue/stress/readiness/sleep scores
  wearable_events/{participant_id}/
    sleep.json                        # 28 nightly sessions/participant, with per-stage breakdown
    steps.json                        # ~40,320 per-minute records/participant
    heart_rate.json                   # ~40,320 per-minute records/participant
```

`participant_id` and `device_id` are the join keys across every file.

## Working with the data

- `wearable_events/` is **~387 MB total** (`heart_rate.json`/`steps.json` are
  ~200K lines each per participant). Never `Read` these files whole — use
  `jq`, `pandas.read_json`, or streaming parsers, and filter/aggregate before
  inspecting output.
- `sleep.json`, `steps.json`, and `heart_rate.json` have **no pre-computed
  summary fields**. Metrics like `total_sleep_min`, `deep_sleep_pct`, or daily
  step/HR aggregates must be derived from the raw per-minute/per-stage records.

## Known data-quality gotchas (from data_dictionary.md)

These are intentional, non-obvious quirks in the synthetic data — account for
them in any analysis rather than assuming clean input:

- **Timestamps are mixed-format.** Almost all timestamps across the dataset
  are naive local time (`UTC-05:00`, no offset), but `heart_rate.json` can
  occasionally emit `Z`-suffixed UTC timestamps instead. Don't assume a single
  format without checking each record.
- **`device_metadata.csv.firmware_version` can be blank**, but the true
  firmware version is always embedded in `device_label` (e.g.
  `Fitbit Charge 5 · fw2.2.1 · SN:FBT-0004-DE56B823`) and must be regex-parsed
  out when `firmware_version` is empty.
- **Heart-rate sensor dropout:** optical HR sensors can get "stuck," repeating
  the last reading for hours at a stretch. An in-range `heart_rate_bpm` value
  isn't necessarily a trustworthy one — check for abnormally long runs of an
  identical value before treating a series as clean.
- Sleep stage order within a session is always
  `light → deep → rem → light → awake`, and each stage's `end_time` equals the
  next stage's `start_time`.
