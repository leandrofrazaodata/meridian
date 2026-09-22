# Pipeline Architecture

Databricks-native medallion pipeline (Bronze → Silver → Gold) over a fixed
28-day synthetic wearable-health dataset. Built on **Databricks Free
Edition** — several decisions below are platform constraints, not just
simplicity preferences; see [Platform constraints](#platform-constraints).

## Layers

```
Volumes (source)  →  Bronze  →  Silver  →  Gold
  raw files          Delta      materialized  materialized
                      tables     views         views
```

### Source — Volumes

Raw CSV/JSON files land in a Unity Catalog volume, already uploaded at
`/Volumes/workspace/default/raw/data/` (mirrors the layout documented in
`data/data_dictionary.md`). Volumes are the landing zone only — nothing
reads directly from them past Bronze.

### Bronze — Delta tables via `COPY INTO`

Each source file is loaded into its own Bronze Delta table using
`COPY INTO`. Compared to Auto Loader/streaming tables (the other option we
considered): `COPY INTO` gives the same exactly-once, idempotent file
tracking — reruns don't reprocess a file already loaded — without needing
streaming infrastructure. That fits this dataset well: the source JSON
files are multi-line arrays, not NDJSON, so they aren't cleanly
incrementally splittable the way Auto Loader wants; and the data itself is
a bounded, mostly-static 28-day set rather than a continuously-arriving
stream. `COPY INTO` runs as a plain SQL/notebook task in a Databricks Job —
no pipeline machinery needed for this layer.

Bronze is intentionally raw: minimal transformation, column names
normalized, ingestion metadata added (`_source_file`, `_ingested_at`, and
for the per-participant JSON files, `_pid_from_path` extracted from the
file path since Unity Catalog doesn't support `input_file_name()`). No
business rules, no filtering — everything that arrives is kept.

One Bronze table per source, defined by a [data contract](#data-contracts):
`participants`, `device_metadata`, `wellness_survey`, `heart_rate`,
`steps`, `sleep`.

### Silver — materialized views over Bronze

Each Silver table is a materialized view reading from its Bronze
counterpart. This is where all business logic and data-quality handling
lives — see `validation-rules.md` for the rule model. Materialized views
recompute deterministically from their inputs, so reruns can't duplicate
or corrupt rows: the output is always a pure function of current Bronze
state, not an accumulating append.

Known per-source logic worth calling out (carried over from prototyping,
see [Decision log](#decision-log)):
- **Timestamps** are naive (no offset) and treated as the participant's
  local time; a small number of `heart_rate.json` records use `Z`-suffixed
  UTC instead — normalize explicitly, don't assume one format.
- **`firmware_version`** is backfilled via regex from `device_label` where
  blank (a `fix`, not a validation failure).
- **Sleep efficiency** as reported by the source doesn't always reconcile
  with the `stages` array; Silver keeps the original value, publishes a
  recalculated one, and measures the delta rather than trusting either
  blindly.
- **Sleep session date** is the wake-up date, as given by the source —
  assigning by sleep-onset date would bias evening chronotypes onto the
  wrong day.
- **`midsleep_hour`** (clock-time midpoint of the sleep session) is derived
  here — it's the canonical metric the chronotype cohort comparison
  (Gold) depends on.

### Gold — materialized views over Silver

Gold is where the daily/weekly dual-consumption requirement and the
chronotype cohort analysis get served. Single source of truth: one
daily-grain fact table, with everything else derived from it — not
parallel pipelines per consuming team.

| Table | Grain | Serves |
|---|---|---|
| `participant_day` | participant × date | Clinical analytics team, daily freshness |
| `participant_week` | participant × study-week | Biostatistics team, weekly batches. Derived from `participant_day` — reshaped to their schema, not recomputed independently. **Exact schema TBD together.** |
| `participant_study_summary` | participant (whole 28-day window) | Chronotype cohort comparison — one row per participant with chronotype + demographics + study-window aggregates (sleep, activity), for grouping analysis (e.g. chronotype A vs B) |

`participant_day` already exists in prototype form (`gold_participant_day`)
joining steps/heart-rate/sleep/wellness/participant dimension, with
`activity_centroid_hour` (step-weighted mean hour of activity) and
`is_provisional` (flags days with <80% heart-rate coverage) — both reused
in the rebuild.

## Data contracts

Each Bronze source is defined by a YAML contract under `contracts/` —
source location/format, target table, expected schema, natural key,
freshness, and the data-quality rules for that source (with their
`on_fail` behavior — see `validation-rules.md`). The contract is the single
declared definition of "what this source is"; Bronze ingestion and Silver
expectations are both driven from it rather than duplicating the same
facts in code and in docs. See `contracts/README.md` for the format.

## Orchestration

One Databricks Job, scheduled daily (satisfies the clinical team's
freshness need — the biostatistics team just queries `participant_week`
on their own weekly cadence, no separate schedule required):

1. **Ingest task(s)** — run the `COPY INTO` statements for each source
   contract into Bronze.
2. **Transform task** — trigger an update of the Lakeflow Declarative
   Pipeline (DLT) that defines Silver and Gold as materialized views.

## Idempotency & reproducibility

- **Bronze**: `COPY INTO` tracks which files it has already loaded;
  rerunning the job doesn't reprocess or duplicate them.
- **Silver/Gold**: materialized views are recomputed deterministically from
  their inputs on each run — not appended to — so a rerun converges to the
  same state rather than accumulating duplicates.
- A full backfill/correction is a **full refresh** of the affected
  materialized view(s), not a manual delete-and-reload.

## Platform constraints

Verified directly against this workspace (Databricks Free Edition), not
assumed from general docs — recheck if the workspace ever moves off Free
Edition:

- **Single catalog.** Only `workspace` exists; no ability to create
  additional catalogs was observed. All layer separation happens via
  schemas within it (see `conventions.md`).
- **Managed storage only.** No external storage credential or external
  location exists beyond the Databricks-managed one — S3/Azure Blob are
  not configurable here. This is a platform limitation, not just a
  simplicity choice.
- **Serverless-only compute.** No classic clusters are available; DLT
  pipelines and the SQL warehouse both run serverless. This works fine for
  everything in this design (COPY INTO, DLT, SQL warehouse consumption),
  it just means no cluster-sizing control.

## Scale & cost

Current scale is small (50 participants, 28 days, ~400K rows total) and
comfortably serverless. If this grows (more participants, longer study,
more source types), things to revisit: partitioning the per-minute Silver
tables by date, moving Bronze ingestion to Auto Loader if files start
arriving incrementally rather than as a fixed batch, and confirming
Free-Edition compute/storage limits aren't hit (not verified — check
current Databricks Free Edition limits before scaling up materially).

## Decision log

- **Superseded prototype**: an earlier exploration (`meridian_daily`
  pipeline, `Migration_bronze` pipeline) used a single flat `default`
  schema with layer-prefixed table names, and full-refresh batch reads for
  Bronze instead of `COPY INTO`. It's being rebuilt under this design
  (three schemas, `COPY INTO`, contracts) rather than extended — kept only
  as a reference for logic worth reusing (see Silver notes above).
- **Auto Loader/streaming tables rejected for now** — see Bronze section.
  Revisit if ingestion becomes genuinely incremental.
