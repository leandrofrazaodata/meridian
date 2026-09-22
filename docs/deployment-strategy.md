# Deployment Strategy

How Meridian's Databricks objects — schemas, the ingestion/transform job, the
Lakeflow pipeline — get created and torn down. Two tools split the work:
**Databricks Asset Bundles (DAB)** for the job and pipeline, and two small
**Python scripts** for the schemas, because tables aren't a uniformly
DAB-owned resource in this architecture (see below).

See `pipeline-architecture.md` for what these resources actually do,
`conventions.md` for naming.

## Why not DAB for everything

| Object | Created by | Destroyed by | DAB-visible? |
|---|---|---|---|
| Silver/Gold tables (materialized views) | Lakeflow pipeline's first run | `databricks bundle destroy` (deleting the pipeline currently drops its managed materialized views — today's Databricks behavior, not guaranteed to stay this way) | Yes — defined inside the pipeline resource |
| Bronze tables | `COPY INTO`, run imperatively inside a job task | Nothing, unless something else drops them | No — created as a side effect of a task running, never declared as a resource |
| Schemas (`meridian_bronze/silver/gold`) | `setup_environment.py` | `teardown_environment.py` | Technically possible as a native `schemas:` bundle resource now, deliberately not used here (see below) |
| Volume (`/Volumes/workspace/default/raw/data/`) | Uploaded manually, out of scope | Never — no tool in this design touches it | N/A |

Two things pushed schema and Bronze-table cleanup out of DAB and into scripts:

1. **Bronze tables have no DAB resource type to attach to.** `COPY INTO`
   creates them procedurally; `bundle destroy` has no record of them
   existing at all.
2. **Native schema-as-resource support is new enough to distrust on Free
   Edition without verifying it live** — it needs a very recent CLI version
   plus the "direct deployment engine." Even where it's mature, it's common
   practice to keep schema/catalog governance out of a bundle's
   deploy/destroy cycle deliberately: a schema is a more durable object than
   a job or pipeline and shouldn't share their lifecycle by default.

A Terraform-based alternative (the `databricks` provider handles this
natively) was considered and rejected — a second IaC toolchain is
disproportionate for two `CREATE SCHEMA`/`DROP SCHEMA CASCADE` statements.

## What DAB owns

Single target, `dev` — Free Edition is one personal workspace, so multiple
targets would be complexity pointed at nothing. Trivial to add a second
target later if a real second workspace shows up.

- **Job** — the daily-scheduled orchestration job from
  `pipeline-architecture.md`: ingest task(s) running each contract's
  `COPY INTO`, then a pipeline task triggering the Lakeflow pipeline update.
  `_ingested_at` must be wired in as a real job parameter, never
  `current_date()` (per `conventions.md`). Exact ingest-task breakdown (one
  task per contract vs. one parameterized task looping contracts) is
  deferred to the implementation plan — a task-authoring decision, not an
  architectural one.
- **Pipeline** — the single Lakeflow Declarative Pipeline defining Silver
  and Gold as materialized views, spanning both schemas via fully-qualified
  names for the Gold layer (already the documented design, not new here).
  `serverless: true`, no cluster config anywhere — Free Edition has no
  classic clusters.

## What the scripts own

- **`setup_environment.py`** — creates `<prefix>_bronze`, `<prefix>_silver`,
  `<prefix>_gold` via the Databricks SDK's
  `WorkspaceClient().schemas.create(...)`, idempotent. Nothing else —
  Silver/Gold tables self-create on the pipeline's first successful run,
  and Bronze tables get a one-time `CREATE TABLE IF NOT EXISTS` from each
  `deploy/resources/sql/ingest_*.sql` file before its `COPY INTO` (owned
  by those SQL files, not this script), so there's nothing more for this
  script to do.
- **`teardown_environment.py`** — the SDK's `schemas.delete()` has no
  cascade option, so this runs raw SQL through the SDK's Statement
  Execution API against the project's SQL Warehouse instead:
  ```sql
  DROP SCHEMA IF EXISTS <prefix>_bronze CASCADE;
  DROP SCHEMA IF EXISTS <prefix>_silver CASCADE;
  DROP SCHEMA IF EXISTS <prefix>_gold CASCADE;
  ```
  `CASCADE` catches every table in each schema regardless of what created
  it — Bronze tables DAB never saw, quarantine tables, anything left
  behind. It's a soft delete: 7-day recovery window, permanent purge within
  48 hours after that — not instantly irreversible.

Neither script ever touches the raw-data Volume.

## Schema prefix

One bundle variable, `schema_prefix`, default `meridian` — reproduces the
schema names already committed in `conventions.md` and every
`contracts/*.yml` file exactly, so **nothing about the existing contracts
changes**. Both the bundle resources and the two scripts read the same
variable/default, so there's one source of truth rather than two
independently-maintained copies of the same name. The only reason this
exists is so a differently-prefixed copy of the whole environment could be
stood up later without editing code — not a need that exists today.

## Full lifecycle

```
python setup_environment.py          # schemas exist
databricks bundle deploy -t dev      # job + pipeline created
                                      # (job runs — Bronze/Silver/Gold populate)
...
databricks bundle destroy -t dev     # job + pipeline gone; Silver/Gold tables dropped with them
python teardown_environment.py --warehouse-id <id>  # schemas + remaining Bronze tables gone (soft-deleted)
```

Destroy order matters: compute/orchestration first, then schemas — avoids
the pipeline resource tripping over a target schema that's already gone
mid-cleanup.

## Directory layout

```
deploy/
  databricks.yml
  resources/
    jobs.yml
    pipelines.yml
  scripts/
    setup_environment.py
    teardown_environment.py
```
Kept separate from `contracts/`/`docs/`/`data/` — a deployment concern, not
a data-contract one.

## Platform constraints affecting this design

From `pipeline-architecture.md`'s Free Edition constraints, the parts that
specifically affect deployment:

- **CLI auth on Free Edition only reliably works from a local machine**
  (PAT via `databricks configure`) — deploying from inside the workspace UI
  has open reports of failing. Verify directly against the workspace before
  relying on either path, the same rule the rest of the Platform
  Constraints section already follows.
- **Serverless-only compute** — every resource here (`COPY INTO` task,
  pipeline task, the Lakeflow pipeline itself) must avoid declaring any
  cluster config.
- **Single catalog** (`workspace`) — both scripts and all bundle resources
  target schemas within it; there's no catalog-level object in scope
  anywhere in this design.

## Deferred / open

- Exact ingest-task breakdown inside the Job (per-contract tasks vs. one
  parameterized task) — implementation-plan-level, decided when the bundle
  resources are actually authored.
- A convenience wrapper chaining `setup → deploy` and `destroy → teardown`
  into one command — nice-to-have, not required for the design to work.
- Git/CI — this workflow is entirely CLI-driven and doesn't depend on git
  existing (the repo currently isn't a git repo). Revisit if that changes.

## Decision log

- **DAB-native `schemas:` resource** — considered, not used.
  CLI-version/Free-Edition-reliability risk, and a deliberate preference
  for keeping schema lifecycle decoupled from job/pipeline lifecycle.
  Revisit if the project ever moves off Free Edition.
- **Terraform** — considered, rejected as disproportionate tooling for two
  DDL statements.
- **Superseded manual prototype** (`meridian_daily` pipeline,
  `Migration_bronze` pipeline, flat `default` schema, referenced in
  `pipeline-architecture.md`'s own decision log) — already deleted from the
  workspace; not a migration concern for this design.
