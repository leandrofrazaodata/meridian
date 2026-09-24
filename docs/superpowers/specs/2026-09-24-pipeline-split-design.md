# Pipeline Split & Orchestrator Rename — Design

The user asked for two improvements to the deploy layer; this spec covers
the first (the second, a CI/CD pipeline for auto-redeploy on merge to
main, is a separate, independent subsystem and gets its own brainstorm
→ spec → plan cycle):

1. Split the single Lakeflow pipeline so Bronze/Silver/Gold are
   individually identifiable when looking at the pipelines, instead of
   one undifferentiated `meridian_pipeline`.
2. Rename the orchestrating job to something like `ETL_orchestrator`.

Everything below is grounded directly against the real repo this
session: `deploy/resources/pipelines.yml` and `jobs.yml` for the current
single-pipeline/single-job structure, `docs/deployment-strategy.md` and
`docs/pipeline-architecture.md` for the architectural reasoning already
on record, the real `transformations/*.sql` files for exact
schema-qualification style, and the `[[pipeline-e2e-verified]]` memory
(real row counts from the 2026-09-23 live run) for what's already proven
to work versus what's new here.

## Design

### Scope boundary: Bronze stays out of Lakeflow

Confirmed directly with the user (first clarifying question, two options
presented). Bronze remains six `COPY INTO` `sql_task`s living in the job
— it does **not** become a third Lakeflow pipeline resource.

`docs/deployment-strategy.md`'s "Why not DAB for everything" section
already reasoned through this and deliberately gave Bronze no DAB
pipeline resource: `COPY INTO` creates tables procedurally as a side
effect of a task running, with nothing for a Lakeflow pipeline to
declare. Converting Bronze to a real pipeline would reopen that already-
made decision — out of scope for this pass. So "split into
bronze/silver/gold" concretely means: two real Lakeflow pipeline
resources (Silver, Gold), with Bronze staying exactly as it is today,
just feeding into a renamed job.

### Naming

Confirmed directly with the user. `docs/conventions.md` only governs
Unity Catalog/table naming, not DAB resource names, so this was an open
choice — resolved to match the existing flat, lowercase `meridian_<thing>`
resource-key pattern already used by `meridian_pipeline` /
`meridian_pipeline_job`:

| Resource | Old name | New name |
|---|---|---|
| Job | `meridian_pipeline_job` | `meridian_etl_orchestrator` |
| Pipeline (Silver) | *(part of `meridian_pipeline`)* | `meridian_silver_pipeline` |
| Pipeline (Gold) | *(part of `meridian_pipeline`)* | `meridian_gold_pipeline` |
| Job task (Silver transform) | `transform` | `transform_silver` |
| Job task (Gold transform) | *(new)* | `transform_gold` |

The six `ingest_*` task keys (Bronze) are unchanged — not part of the
user's naming request, and already clear.

### Pipeline resource split

`deploy/resources/pipelines.yml` currently defines one pipeline whose
default `schema` is `${var.schema_prefix}_silver`, covering all of
`transformations/**` — which is exactly why the existing file's own
comment says Gold "spans both schemas from one pipeline" and needs full
qualification on every Gold object. That reason disappears once each
layer gets its own pipeline with its own default schema:

```yaml
resources:
  pipelines:
    meridian_silver_pipeline:
      name: meridian_silver_pipeline
      catalog: workspace
      schema: ${var.schema_prefix}_silver
      serverless: true
      channel: CURRENT
      continuous: false
      development: false
      configuration:
        schema_prefix: ${var.schema_prefix}
      libraries:
        - glob:
            include: ../../transformations/silver/**
    meridian_gold_pipeline:
      name: meridian_gold_pipeline
      catalog: workspace
      schema: ${var.schema_prefix}_gold
      serverless: true
      channel: CURRENT
      continuous: false
      development: false
      configuration:
        schema_prefix: ${var.schema_prefix}
      libraries:
        - glob:
            include: ../../transformations/gold/**
```

The narrowed `libraries.glob.include` (`transformations/silver/**` /
`transformations/gold/**` instead of `transformations/**`) is what makes
the folder split below load-bearing rather than cosmetic: without it,
Silver's pipeline would also try to build Gold's materialized views
(landing them in the wrong schema by default) and vice versa.

### `transformations/` reorganization

Two subfolders, populated by `git mv` (history-preserving):

- `transformations/silver/` — the six existing Silver files, moved
  verbatim, zero content change: `participants.sql`,
  `device_metadata.sql`, `heart_rate.sql`, `steps.sql`, `sleep.sql`,
  `wellness_survey.sql`.
- `transformations/gold/` — the three existing Gold files, moved plus
  one line each edited (next section): `participant_day.sql`,
  `participant_week.sql`, `participant_study_summary.sql`.

### Gold `CREATE` line qualification (confirmed with user, option a)

`docs/superpowers/specs/2026-09-22-silver-transformations-design.md`
already documents the established convention: "every cross-schema
reference — every Bronze read, every Silver-to-Silver FK check — is
`${schema_prefix}`-templated." This isn't just a cross-schema rule in
practice — it's applied even to same-schema references. Confirmed
directly against real files: `transformations/device_metadata.sql` and
`transformations/wellness_survey.sql` both run an `EXISTS`-based FK
check against `${schema_prefix}_silver.participants`, fully qualified,
despite `participants` living in the same `_silver` schema those files'
own views land in by default.

Gold currently fully-qualifies *everything*, including each file's own
`CREATE OR REFRESH MATERIALIZED VIEW` line
(`${schema_prefix}_gold.participant_day`) — but that's forced by the
single pipeline's `_silver` default schema (an unqualified `CREATE`
would've silently landed in `_silver`), not a style choice. Once Gold
has its own pipeline with default schema `_gold`, that forcing reason
goes away specifically for the three `CREATE` lines. Bringing those in
line with the precedent Silver's own `CREATE` lines already set (bare,
relying on the pipeline's default schema) — while leaving every
*reference to another view* exactly as fully-qualified as the
established convention already requires — is a 3-line, zero-logic-change
edit:

- `participant_day.sql`: `CREATE OR REFRESH MATERIALIZED VIEW
  ${schema_prefix}_gold.participant_day` → `CREATE OR REFRESH
  MATERIALIZED VIEW participant_day`.
- `participant_week.sql`: same pattern for its own `CREATE` line. Its
  `FROM ${schema_prefix}_gold.participant_day` reference is **unchanged**
  — matches the "always qualify references to other views" convention.
- `participant_study_summary.sql`: same pattern; its `FROM
  ${schema_prefix}_gold.participant_day` reference is also **unchanged**.

No other line in any of the nine transformation files changes.

### Job task graph

`deploy/resources/jobs.yml`'s single `transform` task (depended on by
nothing downstream, itself depending on all six ingest tasks) becomes
two sequential tasks:

```yaml
        - task_key: transform_silver
          depends_on:
            - task_key: ingest_participants
            - task_key: ingest_device_metadata
            - task_key: ingest_wellness_survey
            - task_key: ingest_heart_rate
            - task_key: ingest_steps
            - task_key: ingest_sleep
          pipeline_task:
            pipeline_id: ${resources.pipelines.meridian_silver_pipeline.id}
        - task_key: transform_gold
          depends_on:
            - task_key: transform_silver
          pipeline_task:
            pipeline_id: ${resources.pipelines.meridian_gold_pipeline.id}
```

The job resource key and `name:` field both change to
`meridian_etl_orchestrator`; its `parameters`/`schedule` blocks are
untouched.

### Cross-pipeline reference: what's proven versus newly unverified

`docs/superpowers/specs/2026-09-23-gold-transformations-design.md`
flagged an unverified risk: whether Lakeflow correctly infers a
dependency edge when `participant_week`/`participant_study_summary`
reference `${schema_prefix}_gold.participant_day` — a cross-schema
reference to a sibling table *within the same pipeline*. The
`[[pipeline-e2e-verified]]` memory confirms this was checked live on
2026-09-23 and worked correctly — real row counts came back exact
(`participant_day`: 1400, `participant_week`: 200,
`participant_study_summary`: 50).

Splitting the pipeline introduces a related but different situation:
`meridian_gold_pipeline`'s `participant_day.sql` reads
`${schema_prefix}_silver.*` tables that now belong to a completely
separate pipeline (`meridian_silver_pipeline`), not a same-pipeline
sibling. This is no longer a Lakeflow-internal DAG-inference question —
it's Gold's pipeline reading an already-materialized, externally-owned
table via ordinary batch SQL, which is standard Unity Catalog behavior
regardless of which pipeline produced the table. Correct ordering is
guaranteed by the job (`transform_gold` depends on `transform_silver`),
not by Lakeflow inferring anything across pipelines. This is a lower-risk
situation than the one already proven live — but it's still new, so it's
flagged the same way this project has consistently flagged this class of
risk (see: the Bronze `timestamp` physical-type risk in the Silver spec,
the cross-schema dependency-inference risk in the Gold spec): confident,
not guessed at, verify at next live deploy rather than assume.

One simplification worth noting, not a risk: because each pipeline now
owns only its own layer's materialized views, `bundle destroy` deleting
`meridian_silver_pipeline` and `meridian_gold_pipeline` has no ordering
dependency between the two pipeline resources themselves (unlike the Job
→ schemas destroy order, which still matters) — each pipeline's deletion
only drops the materialized views *it* owns.

### Downstream documentation and script updates

Grepped across the whole repo (excluding historical `docs/superpowers/plans/`
and `docs/superpowers/specs/` entries, which are point-in-time snapshots
and aren't retroactively edited — matching how this project has already
treated past design specs):

- `docs/deployment-strategy.md` — "What DAB owns" Pipeline bullet
  (currently describes "the single Lakeflow Declarative Pipeline"
  singular) becomes two bullets; the Orchestration paragraph's "a
  pipeline task triggering the Lakeflow pipeline update" becomes two
  tasks; the Silver/Gold-tables table row can now correctly say each
  layer's own pipeline owns only its own tables (a clarity improvement,
  not just a rename) instead of "the pipeline" generically; a couple of
  plural touch-ups (the Platform Constraints bullet listing "the
  Lakeflow pipeline itself" as needing serverless-only compute).
- `docs/pipeline-architecture.md`'s Orchestration section — "2.
  **Transform task** — trigger an update of the Lakeflow Declarative
  Pipeline (DLT) that defines Silver and Gold as materialized views"
  becomes two numbered steps (transform Silver, then transform Gold),
  each naming its own pipeline.
- `deploy/README.md` — the run command
  (`databricks bundle run meridian_pipeline_job`) updates to the new job
  name; the troubleshooting note about "the `transform` task" currently
  no-oping (from when `transformations/` was empty) is stale in a
  different way now and should reference `transform_silver`/
  `transform_gold`.
- `transformations/README.md` — describe the new `silver/`/`gold/`
  subfolder structure in place of the current flat listing.
- `deploy/scripts/verify_teardown.py` and
  `deploy/scripts/test_verify_teardown.py` — `JOB_NAME_DEFAULT` updates
  to `"meridian_etl_orchestrator"`. `PIPELINE_NAME_DEFAULT` (currently
  one substring-matched name) becomes two checks, one per pipeline
  (`"meridian_silver_pipeline"`, `"meridian_gold_pipeline"`) — the
  existing `pipeline_exists()` helper already takes a single name and
  doesn't need to change shape, it just gets called twice from `main()`;
  `main()`'s `clean` accumulation and printed output extend to cover
  both. Tests updated to match (fixture names, new default constants,
  an added assertion pair for the second pipeline check).
- `docs/gold-layer.md`'s "Refresh: daily, along with every other table
  in the pipeline" line — optional, low-priority wording tightening
  (still technically accurate either way, since refresh cadence is
  unchanged); left to the implementation plan's discretion.

### What's deliberately out of scope

- **Converting Bronze into a real Lakeflow pipeline** — see "Scope
  boundary" above; reopens an already-made, already-documented decision.
- **CI/CD** (auto-redeploy on merge to main) — the second half of the
  user's original request. Independent subsystem, separate brainstorm →
  spec → plan cycle, not part of this design.
- **Renaming the six `ingest_*` task keys** — not requested, already
  clear, left alone.
- **`docs/deployment-strategy.md`'s "Deferred / open" Git/CI note**
  ("this workflow is entirely CLI-driven and doesn't depend on git
  existing... Revisit if that changes") — genuinely stale already (the
  repo has been a git repo since before PR #1), but touching it belongs
  to the upcoming CI/CD design, not this one.

## Known, flagged limitations

- **Cross-pipeline Gold→Silver table read is unverified live** (see
  "Cross-pipeline reference" above) — expected to work (ordinary Unity
  Catalog table read, gated by job task ordering, not a Lakeflow
  DAG-inference dependency), but not yet confirmed against a real
  workspace. Verify at next live deploy: confirm `transform_silver`
  completes and populates `_silver` tables before `transform_gold`
  starts, and confirm `meridian_gold_pipeline`'s update succeeds reading
  them.
- **`verify_teardown.py`'s substring-matching approach** was already
  approximate before this change (a pipeline whose name merely contains
  the search substring would count as a match); splitting into two
  explicit name checks doesn't fix that underlying fuzziness, just keeps
  it consistent with the existing design rather than introducing new
  fuzziness.
