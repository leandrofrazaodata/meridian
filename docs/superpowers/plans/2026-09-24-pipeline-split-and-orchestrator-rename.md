# Pipeline Split & Orchestrator Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the single `meridian_pipeline` Lakeflow pipeline into
`meridian_silver_pipeline` and `meridian_gold_pipeline`, rename the
orchestrating job to `meridian_etl_orchestrator`, and update every file
that names the old resources.

**Architecture:** Two Lakeflow Declarative Pipeline resources replace
one, each pointed at its own new `transformations/<layer>/` subfolder
via a narrowed `libraries.glob.include`. The job's single `transform`
task becomes two sequential tasks (`transform_silver` → `transform_gold`),
each triggering its own pipeline. Bronze stays exactly as-is (six
`ingest_*` `sql_task`s) — this plan does not touch Bronze or introduce
a third pipeline. Gold's own three `CREATE OR REFRESH MATERIALIZED VIEW`
lines become bare now that Gold has its own default schema; every
*reference* (Bronze→Silver, Silver-to-Silver FK checks, Gold-to-Gold,
Gold-to-Silver) stays `${schema_prefix}`-qualified exactly as before.

**Tech Stack:** Databricks Asset Bundles (YAML), Lakeflow Declarative
Pipelines (SQL), Python 3 + `databricks-sdk` + `pytest` (`deploy/scripts/`).

**Spec:** `docs/superpowers/specs/2026-09-24-pipeline-split-design.md`

## Global Constraints

- **No Databricks execution.** `bundle validate` / `bundle deploy` /
  `bundle destroy` / `bundle run` do not run as part of this plan —
  every verification step below is local (file content, `git status`,
  `python -c` YAML/logic checks, `pytest`). The spec's "Known, flagged
  limitations" section explicitly defers live confirmation of the
  cross-pipeline Gold→Silver table read to the next live deploy.
- **Naming (exact, from the spec's table — copy verbatim, do not
  improvise variants):**

  | Resource | Old name | New name |
  |---|---|---|
  | Job | `meridian_pipeline_job` | `meridian_etl_orchestrator` |
  | Pipeline (Silver) | *(part of `meridian_pipeline`)* | `meridian_silver_pipeline` |
  | Pipeline (Gold) | *(part of `meridian_pipeline`)* | `meridian_gold_pipeline` |
  | Job task (Silver transform) | `transform` | `transform_silver` |
  | Job task (Gold transform) | *(new)* | `transform_gold` |

  The six `ingest_*` task keys are unchanged.
- **Schema-qualification rule (unchanged convention, applied to new
  files too):** every reference to a table/view outside the *current
  file's own* default schema — and even some same-schema references,
  per the established Silver FK-check precedent — stays
  `${schema_prefix}`-qualified. The only things that become *bare* in
  this plan are the three Gold files' own `CREATE OR REFRESH
  MATERIALIZED VIEW <name>` lines, because `meridian_gold_pipeline`
  gives them a default schema for the first time. No other line in any
  of the nine transformation files changes.
- **`transformations/` reorganization uses `git mv`** (history-preserving)
  for all nine files. The six Silver files move with zero content
  change. The three Gold files move plus exactly one line each changed
  (their own `CREATE` line).
- **Bronze is out of scope.** It stays six `COPY INTO` `sql_task`s in
  the job; it does not become a third pipeline resource. Don't touch
  `deploy/resources/sql/ingest_*.sql` or the `ingest_*` task blocks in
  `jobs.yml` beyond what's needed to re-point `transform`'s downstream
  pipeline reference.
- **CI/CD is a separate subsystem**, explicitly out of scope per the
  spec — don't add any `.github/workflows/` or similar in this plan.
- **Historical spec/plan snapshots are never retroactively edited** —
  `docs/superpowers/specs/*.md` and other files under
  `docs/superpowers/plans/` are point-in-time and stay as originally
  written, even where they now describe a superseded state (e.g. the
  2026-09-22 Silver spec and 2026-09-23 Gold spec both still say "one
  pipeline").
- **Baseline:** `pytest` in `deploy/scripts/` is 18 passed, 0 failed
  before this plan's first task (confirmed 2026-09-24). Every task that
  touches `deploy/scripts/` must keep this suite fully green.

---

## Task 1: Reorganize `transformations/` into `silver/` and `gold/` subfolders

**Files:**
- Move (`git mv`, zero content change): `transformations/participants.sql` → `transformations/silver/participants.sql`
- Move (`git mv`, zero content change): `transformations/device_metadata.sql` → `transformations/silver/device_metadata.sql`
- Move (`git mv`, zero content change): `transformations/heart_rate.sql` → `transformations/silver/heart_rate.sql`
- Move (`git mv`, zero content change): `transformations/steps.sql` → `transformations/silver/steps.sql`
- Move (`git mv`, zero content change): `transformations/sleep.sql` → `transformations/silver/sleep.sql`
- Move (`git mv`, zero content change): `transformations/wellness_survey.sql` → `transformations/silver/wellness_survey.sql`
- Move + edit: `transformations/participant_day.sql` → `transformations/gold/participant_day.sql`
- Move + edit: `transformations/participant_week.sql` → `transformations/gold/participant_week.sql`
- Move + edit: `transformations/participant_study_summary.sql` → `transformations/gold/participant_study_summary.sql`

**Interfaces:**
- Consumes: nothing from another task — this is the first task.
- Produces: the directory paths `transformations/silver/**` and
  `transformations/gold/**` that Task 2's `pipelines.yml` rewrite points
  its two `libraries.glob.include` entries at. Produces the fact that
  each Gold file's own `CREATE OR REFRESH MATERIALIZED VIEW <name>` line
  is now bare (unqualified) — Task 5/6's doc updates describe this.

- [ ] **Step 1: Create the two subfolders and move all nine files**

```bash
cd transformations
mkdir -p silver gold
git mv participants.sql silver/participants.sql
git mv device_metadata.sql silver/device_metadata.sql
git mv heart_rate.sql silver/heart_rate.sql
git mv steps.sql silver/steps.sql
git mv sleep.sql silver/sleep.sql
git mv wellness_survey.sql silver/wellness_survey.sql
git mv participant_day.sql gold/participant_day.sql
git mv participant_week.sql gold/participant_week.sql
git mv participant_study_summary.sql gold/participant_study_summary.sql
cd ..
```

- [ ] **Step 2: Verify all nine moves staged as renames**

Run: `git status --short`
Expected: nine lines, each starting `R  ` (renamed, staged), e.g.
`R  transformations/participants.sql -> transformations/silver/participants.sql`.
No `D`/`A` pairs (which would mean git didn't detect the rename — content
is still byte-identical at this point so it always should).

- [ ] **Step 3: Edit `transformations/gold/participant_day.sql`'s `CREATE` line**

In `transformations/gold/participant_day.sql`, change:

```sql
CREATE OR REFRESH MATERIALIZED VIEW ${schema_prefix}_gold.participant_day
```

to:

```sql
CREATE OR REFRESH MATERIALIZED VIEW participant_day
```

No other line in this file changes — every `${schema_prefix}_silver.*`
reference inside it (in the `spine`, `daily_steps`, `daily_heart_rate`
CTEs and the final `FROM`/`LEFT JOIN`s) stays exactly as-is.

- [ ] **Step 4: Edit `transformations/gold/participant_week.sql`'s `CREATE` line**

Change:

```sql
CREATE OR REFRESH MATERIALIZED VIEW ${schema_prefix}_gold.participant_week
```

to:

```sql
CREATE OR REFRESH MATERIALIZED VIEW participant_week
```

Its `FROM ${schema_prefix}_gold.participant_day` reference (inside the
`with_week` CTE) is **unchanged** — it's a reference to another view, not
this view's own `CREATE` line, so the qualification convention still
applies.

- [ ] **Step 5: Edit `transformations/gold/participant_study_summary.sql`'s `CREATE` line**

Change:

```sql
CREATE OR REFRESH MATERIALIZED VIEW ${schema_prefix}_gold.participant_study_summary
```

to:

```sql
CREATE OR REFRESH MATERIALIZED VIEW participant_study_summary
```

Its `FROM ${schema_prefix}_gold.participant_day` reference is likewise
**unchanged**.

- [ ] **Step 6: Verify the edits**

Run (from repo root):

```bash
grep -rn 'CREATE OR REFRESH MATERIALIZED VIEW \${schema_prefix}_gold\.' transformations/gold/
grep -rn 'CREATE OR REFRESH MATERIALIZED VIEW [a-z_]*$' transformations/gold/
grep -c '\${schema_prefix}_gold\.participant_day' transformations/gold/participant_week.sql transformations/gold/participant_study_summary.sql
```

Expected: first command prints nothing (no qualified `CREATE` lines
remain); second command prints all three files, each ending in a bare
view name; third command prints `1` for each file (the `FROM` reference
is still there, still qualified).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "transformations: reorganize into silver/ and gold/ subfolders"
```

---

## Task 2: Split `deploy/resources/pipelines.yml` into `meridian_silver_pipeline` and `meridian_gold_pipeline`

**Files:**
- Modify (full rewrite): `deploy/resources/pipelines.yml`

**Interfaces:**
- Consumes: `transformations/silver/**` and `transformations/gold/**`
  (Task 1's output paths).
- Produces: resource keys `resources.pipelines.meridian_silver_pipeline`
  and `resources.pipelines.meridian_gold_pipeline` — Task 3's
  `jobs.yml` rewrite references
  `${resources.pipelines.meridian_silver_pipeline.id}` and
  `${resources.pipelines.meridian_gold_pipeline.id}`.

- [ ] **Step 1: Rewrite the file**

Replace the full contents of `deploy/resources/pipelines.yml` with:

```yaml
resources:
  pipelines:
    meridian_silver_pipeline:
      name: meridian_silver_pipeline
      catalog: workspace
      # `schema` (not the deprecated `target`) is the current field
      # name for a pipeline's default schema — confirmed against
      # `databricks bundle schema` output.
      schema: ${var.schema_prefix}_silver
      serverless: true
      channel: CURRENT
      continuous: false
      development: false
      configuration:
        # Lets transformation SQL reference ${schema_prefix} instead of
        # a hardcoded prefix — same one-source-of-truth property the
        # bundle mirrors.
        schema_prefix: ${var.schema_prefix}
      libraries:
        - glob:
            include: ../../transformations/silver/**
    meridian_gold_pipeline:
      name: meridian_gold_pipeline
      catalog: workspace
      # `schema` (not the deprecated `target`) is the current field
      # name for a pipeline's default schema — confirmed against
      # `databricks bundle schema` output. Gold's own CREATE lines rely
      # on this default; only references to Silver tables (a different
      # pipeline's schema) need `${schema_prefix}`-qualifying inside the
      # SQL itself (see docs/pipeline-architecture.md's Gold section).
      schema: ${var.schema_prefix}_gold
      serverless: true
      channel: CURRENT
      continuous: false
      development: false
      configuration:
        # Lets transformation SQL reference ${schema_prefix} instead of
        # a hardcoded prefix — same one-source-of-truth property the
        # bundle mirrors.
        schema_prefix: ${var.schema_prefix}
      libraries:
        - glob:
            include: ../../transformations/gold/**
```

- [ ] **Step 2: Verify structure and values**

Run:

```bash
python -c "
import yaml
with open('deploy/resources/pipelines.yml') as f:
    doc = yaml.safe_load(f)
pipelines = doc['resources']['pipelines']
assert set(pipelines) == {'meridian_silver_pipeline', 'meridian_gold_pipeline'}, pipelines.keys()
assert pipelines['meridian_silver_pipeline']['name'] == 'meridian_silver_pipeline'
assert pipelines['meridian_gold_pipeline']['name'] == 'meridian_gold_pipeline'
assert pipelines['meridian_silver_pipeline']['schema'] == '\${var.schema_prefix}_silver'
assert pipelines['meridian_gold_pipeline']['schema'] == '\${var.schema_prefix}_gold'
assert pipelines['meridian_silver_pipeline']['libraries'][0]['glob']['include'] == '../../transformations/silver/**'
assert pipelines['meridian_gold_pipeline']['libraries'][0]['glob']['include'] == '../../transformations/gold/**'
for key in ('meridian_silver_pipeline', 'meridian_gold_pipeline'):
    p = pipelines[key]
    assert p['catalog'] == 'workspace'
    assert p['serverless'] is True
    assert p['continuous'] is False
    assert p['configuration']['schema_prefix'] == '\${var.schema_prefix}'
print('OK')
"
```

Expected: `OK`, no assertion errors.

- [ ] **Step 3: Commit**

```bash
git add deploy/resources/pipelines.yml
git commit -m "deploy: split pipeline resource into silver and gold pipelines"
```

---

## Task 3: Rename job to `meridian_etl_orchestrator` and split `transform` into `transform_silver`/`transform_gold`

**Files:**
- Modify: `deploy/resources/jobs.yml`

**Interfaces:**
- Consumes: `resources.pipelines.meridian_silver_pipeline` and
  `resources.pipelines.meridian_gold_pipeline` (Task 2's output resource
  keys).
- Produces: job resource key and `name:` `meridian_etl_orchestrator`;
  task keys `transform_silver` and `transform_gold` — Task 4's
  `verify_teardown.py`/tests reference the job name, and Task 6's
  `deploy/README.md` run command and troubleshooting note reference the
  job name and both task keys.

- [ ] **Step 1: Rename the job resource key and `name:` field**

In `deploy/resources/jobs.yml`, change:

```yaml
resources:
  jobs:
    meridian_pipeline_job:
      name: meridian_pipeline_job
```

to:

```yaml
resources:
  jobs:
    meridian_etl_orchestrator:
      name: meridian_etl_orchestrator
```

The `parameters:` block (the `ingested_at` parameter and its
`default: "{{job.trigger.time.iso_date}}"`) and the `schedule:` block
directly below are untouched — this step only touches the two lines
shown above.

- [ ] **Step 2: Split the `transform` task into `transform_silver` and `transform_gold`**

The six `ingest_*` task blocks (`ingest_participants` through
`ingest_sleep`) are untouched. Immediately after them, change:

```yaml
        - task_key: transform
          depends_on:
            - task_key: ingest_participants
            - task_key: ingest_device_metadata
            - task_key: ingest_wellness_survey
            - task_key: ingest_heart_rate
            - task_key: ingest_steps
            - task_key: ingest_sleep
          pipeline_task:
            pipeline_id: ${resources.pipelines.meridian_pipeline.id}
```

to:

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

- [ ] **Step 3: Verify structure and values**

Run:

```bash
python -c "
import yaml
with open('deploy/resources/jobs.yml') as f:
    doc = yaml.safe_load(f)
jobs = doc['resources']['jobs']
assert set(jobs) == {'meridian_etl_orchestrator'}, jobs.keys()
job = jobs['meridian_etl_orchestrator']
assert job['name'] == 'meridian_etl_orchestrator'
assert job['parameters'][0]['name'] == 'ingested_at'
assert job['parameters'][0]['default'] == '{{job.trigger.time.iso_date}}'
assert job['schedule']['quartz_cron_expression'] == '0 0 6 * * ?'

task_keys = [t['task_key'] for t in job['tasks']]
assert task_keys == [
    'ingest_participants', 'ingest_device_metadata', 'ingest_wellness_survey',
    'ingest_heart_rate', 'ingest_steps', 'ingest_sleep',
    'transform_silver', 'transform_gold',
], task_keys

by_key = {t['task_key']: t for t in job['tasks']}
assert by_key['transform_silver']['pipeline_task']['pipeline_id'] == '\${resources.pipelines.meridian_silver_pipeline.id}'
assert by_key['transform_gold']['pipeline_task']['pipeline_id'] == '\${resources.pipelines.meridian_gold_pipeline.id}'
assert [d['task_key'] for d in by_key['transform_silver']['depends_on']] == [
    'ingest_participants', 'ingest_device_metadata', 'ingest_wellness_survey',
    'ingest_heart_rate', 'ingest_steps', 'ingest_sleep',
]
assert [d['task_key'] for d in by_key['transform_gold']['depends_on']] == ['transform_silver']
print('OK')
"
```

Expected: `OK`, no assertion errors.

- [ ] **Step 4: Commit**

```bash
git add deploy/resources/jobs.yml
git commit -m "deploy: rename orchestrator job and split transform task"
```

---

## Task 4: Update `verify_teardown.py` and its tests for the split pipelines

**Files:**
- Modify (full rewrite): `deploy/scripts/verify_teardown.py`
- Modify (full rewrite): `deploy/scripts/test_verify_teardown.py`

**Interfaces:**
- Consumes: the naming table in Global Constraints — `JOB_NAME_DEFAULT`
  must match the job name Task 3 chose
  (`"meridian_etl_orchestrator"`), and the two new pipeline-name
  defaults must match Task 2's pipeline names (`"meridian_silver_pipeline"`,
  `"meridian_gold_pipeline"`). These are independent string literals
  (this script doesn't parse `jobs.yml`/`pipelines.yml`), so nothing
  breaks mechanically if they drift — only this plan's own consistency
  keeps them aligned.
- Produces: nothing consumed by a later task — `verify_teardown.py` is a
  standalone operational script.

- [ ] **Step 1: Rewrite `verify_teardown.py`**

Replace the full contents of `deploy/scripts/verify_teardown.py` with:

```python
"""Check whether Meridian's deployed Databricks objects have been torn down.

Read-only -- makes no changes, only reports what it finds. Checks the three
medallion schemas (bronze/silver/gold), the orchestration job, and the two
Lakeflow pipelines (Silver, Gold): everything docs/deployment-strategy.md's
"Full lifecycle" destroys.

Job and pipeline names are matched by substring rather than exact name,
because the bundle's `dev` target uses `mode: development`
(deploy/databricks.yml), which prefixes deployed resource names with
`[dev <username>]` -- the workspace never has a job literally named
"meridian_etl_orchestrator", only one whose name contains that string.

Usage:
    python deploy/scripts/verify_teardown.py [--prefix meridian] [--catalog workspace]

Exit code is 0 if everything's gone, 1 if anything still exists.
"""

from __future__ import annotations

import argparse

from databricks.sdk import WorkspaceClient
from databricks.sdk.errors import NotFound

CATALOG_DEFAULT = "workspace"
PREFIX_DEFAULT = "meridian"
JOB_NAME_DEFAULT = "meridian_etl_orchestrator"
SILVER_PIPELINE_NAME_DEFAULT = "meridian_silver_pipeline"
GOLD_PIPELINE_NAME_DEFAULT = "meridian_gold_pipeline"
LAYERS = ("bronze", "silver", "gold")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", default=PREFIX_DEFAULT, help="Schema prefix (default: %(default)s)")
    parser.add_argument("--catalog", default=CATALOG_DEFAULT, help="Unity Catalog catalog name (default: %(default)s)")
    parser.add_argument("--job-name", default=JOB_NAME_DEFAULT, help="Job name substring to search for (default: %(default)s)")
    parser.add_argument(
        "--silver-pipeline-name",
        default=SILVER_PIPELINE_NAME_DEFAULT,
        help="Silver pipeline name substring to search for (default: %(default)s)",
    )
    parser.add_argument(
        "--gold-pipeline-name",
        default=GOLD_PIPELINE_NAME_DEFAULT,
        help="Gold pipeline name substring to search for (default: %(default)s)",
    )
    return parser.parse_args(argv)


def schema_exists(client: WorkspaceClient, catalog: str, schema_name: str) -> bool:
    """True if catalog.schema_name still exists."""
    try:
        client.schemas.get(f"{catalog}.{schema_name}")
        return True
    except NotFound:
        return False


def job_exists(client: WorkspaceClient, name_substring: str) -> bool:
    """True if any job's name contains name_substring."""
    return any(name_substring in (job.settings.name or "") for job in client.jobs.list(name=name_substring))


def pipeline_exists(client: WorkspaceClient, name_substring: str) -> bool:
    """True if any pipeline's name contains name_substring."""
    return any(name_substring in (pipeline.name or "") for pipeline in client.pipelines.list_pipelines())


def main(argv: list[str] | None = None, client: WorkspaceClient | None = None) -> int:
    args = parse_args(argv)
    client = client or WorkspaceClient()
    clean = True

    for layer in LAYERS:
        schema_name = f"{args.prefix}_{layer}"
        found = schema_exists(client, args.catalog, schema_name)
        print(f"schema {args.catalog}.{schema_name}: {'still exists' if found else 'gone'}")
        clean = clean and not found

    found = job_exists(client, args.job_name)
    print(f"job matching '{args.job_name}': {'still exists' if found else 'gone'}")
    clean = clean and not found

    found = pipeline_exists(client, args.silver_pipeline_name)
    print(f"pipeline matching '{args.silver_pipeline_name}': {'still exists' if found else 'gone'}")
    clean = clean and not found

    found = pipeline_exists(client, args.gold_pipeline_name)
    print(f"pipeline matching '{args.gold_pipeline_name}': {'still exists' if found else 'gone'}")
    clean = clean and not found

    print("Everything torn down." if clean else "Still cleaning up -- see above.")
    return 0 if clean else 1


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Rewrite `test_verify_teardown.py`**

Replace the full contents of `deploy/scripts/test_verify_teardown.py` with:

```python
from unittest.mock import MagicMock

from databricks.sdk.errors import NotFound

from verify_teardown import LAYERS, job_exists, main, pipeline_exists, schema_exists


def _job(name):
    job = MagicMock()
    job.settings.name = name
    return job


def _pipeline(name):
    pipeline = MagicMock()
    pipeline.name = name
    return pipeline


def test_schema_exists_true_when_found():
    client = MagicMock()
    client.schemas.get.return_value = object()  # any truthy SchemaInfo-like value

    assert schema_exists(client, "workspace", "meridian_bronze") is True


def test_schema_exists_false_when_not_found():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")

    assert schema_exists(client, "workspace", "meridian_bronze") is False


def test_job_exists_true_when_name_matches():
    client = MagicMock()
    client.jobs.list.return_value = [_job("[dev leandro] meridian_etl_orchestrator")]

    assert job_exists(client, "meridian_etl_orchestrator") is True


def test_job_exists_false_when_no_jobs():
    client = MagicMock()
    client.jobs.list.return_value = []

    assert job_exists(client, "meridian_etl_orchestrator") is False


def test_pipeline_exists_true_when_name_matches():
    client = MagicMock()
    client.pipelines.list_pipelines.return_value = [_pipeline("[dev leandro] meridian_silver_pipeline")]

    assert pipeline_exists(client, "meridian_silver_pipeline") is True


def test_pipeline_exists_false_when_no_pipelines():
    client = MagicMock()
    client.pipelines.list_pipelines.return_value = []

    assert pipeline_exists(client, "meridian_silver_pipeline") is False


def test_main_reports_clean_and_returns_zero():
    assert LAYERS == ("bronze", "silver", "gold")

    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")
    client.jobs.list.return_value = []
    client.pipelines.list_pipelines.return_value = []

    assert main([], client=client) == 0


def test_main_reports_dirty_and_returns_one_when_schema_remains():
    client = MagicMock()
    client.schemas.get.return_value = object()  # all three "exist"
    client.jobs.list.return_value = []
    client.pipelines.list_pipelines.return_value = []

    assert main([], client=client) == 1


def test_main_reports_dirty_when_job_remains():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")
    client.jobs.list.return_value = [_job("[dev leandro] meridian_etl_orchestrator")]
    client.pipelines.list_pipelines.return_value = []

    assert main([], client=client) == 1


def test_main_reports_dirty_when_only_silver_pipeline_remains():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")
    client.jobs.list.return_value = []
    client.pipelines.list_pipelines.return_value = [_pipeline("[dev leandro] meridian_silver_pipeline")]

    assert main([], client=client) == 1


def test_main_reports_dirty_when_only_gold_pipeline_remains():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")
    client.jobs.list.return_value = []
    client.pipelines.list_pipelines.return_value = [_pipeline("[dev leandro] meridian_gold_pipeline")]

    assert main([], client=client) == 1


def test_main_honors_custom_prefix_and_catalog():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")
    client.jobs.list.return_value = []
    client.pipelines.list_pipelines.return_value = []

    main(["--prefix", "meridian_dev", "--catalog", "sandbox"], client=client)

    client.schemas.get.assert_any_call("sandbox.meridian_dev_bronze")
    client.schemas.get.assert_any_call("sandbox.meridian_dev_silver")
    client.schemas.get.assert_any_call("sandbox.meridian_dev_gold")
```

Two tests were added relative to the original file
(`test_main_reports_dirty_when_only_silver_pipeline_remains` and
`test_main_reports_dirty_when_only_gold_pipeline_remains`) — the
original single `test_pipeline_exists_true_when_name_matches`-style
coverage doesn't distinguish "only one of the two pipelines is still
up," which is exactly the new failure mode this split introduces
(previously there was only one pipeline, so there was no "only one of
two" case).

- [ ] **Step 3: Run the test suite**

Run: `cd deploy/scripts && pytest -v`

Expected: all tests pass, including the two new ones
(`test_main_reports_dirty_when_only_silver_pipeline_remains`,
`test_main_reports_dirty_when_only_gold_pipeline_remains`). Total count
is 20: the original 18 plus these 2 additions, none removed.

- [ ] **Step 4: Commit**

```bash
cd ../..
git add deploy/scripts/verify_teardown.py deploy/scripts/test_verify_teardown.py
git commit -m "deploy: update verify_teardown for split pipelines"
```

---

## Task 5: Update `docs/deployment-strategy.md` and `docs/pipeline-architecture.md`

**Files:**
- Modify: `docs/deployment-strategy.md`
- Modify: `docs/pipeline-architecture.md`

**Interfaces:**
- Consumes: the naming table in Global Constraints (both docs describe
  the resources Tasks 2/3 created).
- Produces: nothing consumed by a later task — these are narrative docs.

- [ ] **Step 1: `docs/deployment-strategy.md` — "What DAB owns" bullets**

Change:

```markdown
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
```

to:

```markdown
- **Job** — the daily-scheduled orchestration job from
  `pipeline-architecture.md`: ingest task(s) running each contract's
  `COPY INTO`, then two pipeline tasks triggering the Silver and Gold
  Lakeflow pipeline updates in sequence. `_ingested_at` must be wired in
  as a real job parameter, never `current_date()` (per `conventions.md`).
  Exact ingest-task breakdown (one task per contract vs. one parameterized
  task looping contracts) is deferred to the implementation plan — a
  task-authoring decision, not an architectural one.
- **Silver pipeline** — the Lakeflow Declarative Pipeline defining Silver
  as materialized views over Bronze. `serverless: true`, no cluster config
  anywhere — Free Edition has no classic clusters.
- **Gold pipeline** — the Lakeflow Declarative Pipeline defining Gold as
  materialized views over Silver, reading Silver tables via
  fully-qualified names across the pipeline boundary. Same `serverless:
  true` constraint.
```

- [ ] **Step 2: `docs/deployment-strategy.md` — "Why not DAB for everything" table row**

Change:

```markdown
| Silver/Gold tables (materialized views) | Lakeflow pipeline's first run | `databricks bundle destroy` (deleting the pipeline currently drops its managed materialized views — today's Databricks behavior, not guaranteed to stay this way) | Yes — defined inside the pipeline resource |
```

to:

```markdown
| Silver tables (materialized views) | `meridian_silver_pipeline`'s first run | `databricks bundle destroy` (deleting the pipeline currently drops its managed materialized views — today's Databricks behavior, not guaranteed to stay this way) | Yes — defined inside the pipeline resource |
| Gold tables (materialized views) | `meridian_gold_pipeline`'s first run | `databricks bundle destroy` (deleting the pipeline currently drops its managed materialized views — today's Databricks behavior, not guaranteed to stay this way) | Yes — defined inside the pipeline resource |
```

- [ ] **Step 3: `docs/deployment-strategy.md` — "Full lifecycle" code block**

Change:

```
databricks bundle deploy -t dev      # job + pipeline created
                                      # (job runs — Bronze/Silver/Gold populate)
...
databricks bundle destroy -t dev     # job + pipeline gone; Silver/Gold tables dropped with them
```

to:

```
databricks bundle deploy -t dev      # job + pipelines created
                                      # (job runs — Bronze/Silver/Gold populate)
...
databricks bundle destroy -t dev     # job + pipelines gone; Silver/Gold tables dropped with them
```

- [ ] **Step 4: `docs/deployment-strategy.md` — destroy-order paragraph**

Change:

```markdown
Destroy order matters: compute/orchestration first, then schemas — avoids
the pipeline resource tripping over a target schema that's already gone
mid-cleanup.
```

to:

```markdown
Destroy order matters: compute/orchestration first, then schemas — avoids
the pipeline resources tripping over a target schema that's already gone
mid-cleanup. (The two pipeline resources have no ordering dependency on
each other — each owns and drops only its own layer's materialized
views.)
```

- [ ] **Step 5: `docs/deployment-strategy.md` — Platform constraints bullet**

Change:

```markdown
- **Serverless-only compute** — every resource here (`COPY INTO` task,
  pipeline task, the Lakeflow pipeline itself) must avoid declaring any
  cluster config.
```

to:

```markdown
- **Serverless-only compute** — every resource here (`COPY INTO` task,
  both pipeline tasks, both Lakeflow pipelines) must avoid declaring any
  cluster config.
```

- [ ] **Step 6: `docs/pipeline-architecture.md` — Orchestration section**

Change:

```markdown
1. **Ingest task(s)** — run the `COPY INTO` statements for each source
   contract into Bronze.
2. **Transform task** — trigger an update of the Lakeflow Declarative
   Pipeline (DLT) that defines Silver and Gold as materialized views.
```

to:

```markdown
1. **Ingest task(s)** — run the `COPY INTO` statements for each source
   contract into Bronze.
2. **Transform Silver task** — trigger an update of the Lakeflow
   Declarative Pipeline (DLT) that defines Silver as materialized views
   over Bronze.
3. **Transform Gold task** — trigger an update of the separate Lakeflow
   Declarative Pipeline (DLT) that defines Gold as materialized views
   over Silver, gated on step 2 completing so Gold always reads freshly
   populated Silver tables.
```

- [ ] **Step 7: Verify no stale singular references remain**

Run:

```bash
grep -n "the Lakeflow pipeline\|the single Lakeflow\|meridian_pipeline\b" docs/deployment-strategy.md docs/pipeline-architecture.md
```

Expected: no output (every remaining reference now names a specific
pipeline or uses the plural "pipelines"). If this prints a line, check
whether it's inside a historical quote (none expected in these two
files) before treating it as a miss.

- [ ] **Step 8: Commit**

```bash
git add docs/deployment-strategy.md docs/pipeline-architecture.md
git commit -m "docs: update deployment-strategy and pipeline-architecture for split pipelines"
```

---

## Task 6: Update `deploy/README.md`, `transformations/README.md`, and `docs/gold-layer.md`

**Files:**
- Modify: `deploy/README.md`
- Modify: `transformations/README.md`
- Modify: `docs/gold-layer.md`

**Interfaces:**
- Consumes: the naming table in Global Constraints, and Task 1's
  `transformations/silver/` + `transformations/gold/` layout.
- Produces: nothing consumed by a later task — this is the last task.

- [ ] **Step 1: `deploy/README.md` — run command**

Change:

```markdown
# 3. Trigger a run: ingest tasks (Bronze COPY INTO), then the pipeline
#    update (Silver/Gold materialized views)
databricks bundle run meridian_pipeline_job -t dev
```

to:

```markdown
# 3. Trigger a run: ingest tasks (Bronze COPY INTO), then the Silver and
#    Gold pipeline updates in sequence
databricks bundle run meridian_etl_orchestrator -t dev
```

- [ ] **Step 2: `deploy/README.md` — "Watch progress" paragraph**

Change:

```markdown
Watch progress with `databricks bundle summary -t dev`, which prints
links to the Job and Pipeline in the workspace UI, or check the UI
directly. The job also runs on its own daily schedule (see
`resources/jobs.yml`) — the manual `run` above is only for an immediate
first run or an ad hoc re-run.
```

to:

```markdown
Watch progress with `databricks bundle summary -t dev`, which prints
links to the Job and both Pipelines in the workspace UI, or check the
UI directly. The job also runs on its own daily schedule (see
`resources/jobs.yml`) — the manual `run` above is only for an immediate
first run or an ad hoc re-run.
```

- [ ] **Step 3: `deploy/README.md` — resource-names-prefixed bullet**

Change:

```markdown
- **Resource names in the UI are prefixed `[dev <your-username>]`** —
  e.g. `[dev leandro_lf_frazao2] meridian_pipeline_job`. That's
  `databricks.yml`'s `targets.dev.mode: development` automatically
  namespacing deployed resources so they don't collide with anyone
  else's dev deployment in a shared workspace.
```

to:

```markdown
- **Resource names in the UI are prefixed `[dev <your-username>]`** —
  e.g. `[dev leandro_lf_frazao2] meridian_etl_orchestrator`. That's
  `databricks.yml`'s `targets.dev.mode: development` automatically
  namespacing deployed resources so they don't collide with anyone
  else's dev deployment in a shared workspace.
```

- [ ] **Step 4: `deploy/README.md` — transform-task troubleshooting bullet**

Change:

```markdown
- **The `transform` task currently fails or no-ops.** It's the task that
  triggers the pipeline; the pipeline has no Silver/Gold source files
  yet (see "Current status" above), so there's nothing for it to build.
  The 6 ingest tasks ahead of it still run and populate Bronze normally.
```

to:

```markdown
- **The `transform_silver`/`transform_gold` tasks currently fail or
  no-op.** These are the tasks that trigger the Silver and Gold
  pipelines; if `transformations/` has no source files for a layer (see
  "Current status" above), there's nothing for that layer's pipeline to
  build. The 6 ingest tasks ahead of them still run and populate Bronze
  normally.
```

(This bullet's premise — that `transformations/` has no source files —
is already stale for different reasons predating this plan: Silver and
Gold are both fully populated. Leaving that pre-existing staleness alone
is a deliberate choice, not an oversight — see the note at the end of
this plan's Verification section.)

- [ ] **Step 5: `deploy/README.md` — "Tear it down" section**

Change:

```markdown
# 1. Job + Pipeline (Silver/Gold materialized views go with the Pipeline)
databricks bundle destroy -t dev --var="warehouse_id=<warehouse-id>"
```

to:

```markdown
# 1. Job + Pipelines (Silver/Gold materialized views go with their
#    respective Pipeline)
databricks bundle destroy -t dev --var="warehouse_id=<warehouse-id>"
```

- [ ] **Step 6: `deploy/README.md` — verify_teardown output description**

Change:

```markdown
Prints the status of all three schemas plus the job and pipeline, and
exits non-zero if anything's still hanging around.
```

to:

```markdown
Prints the status of all three schemas plus the job and both pipelines,
and exits non-zero if anything's still hanging around.
```

- [ ] **Step 7: `deploy/README.md` — Script flags table row**

Change:

```markdown
| `verify_teardown.py` | — | `--prefix`, `--catalog`, `--job-name`, `--pipeline-name` |
```

to:

```markdown
| `verify_teardown.py` | — | `--prefix`, `--catalog`, `--job-name`, `--silver-pipeline-name`, `--gold-pipeline-name` |
```

- [ ] **Step 8: `transformations/README.md` — intro paragraph + add Layout section**

Change:

```markdown
This directory holds the Lakeflow Declarative Pipeline source (SQL
files, one materialized view per Silver/Gold table) that
`deploy/resources/pipelines.yml`'s `meridian_pipeline` resource points
at via `libraries.glob.include`.

## Current status
```

to:

```markdown
This directory holds the Lakeflow Declarative Pipeline source (SQL
files, one materialized view per Silver/Gold table), split into two
subfolders that `deploy/resources/pipelines.yml`'s
`meridian_silver_pipeline` and `meridian_gold_pipeline` resources each
point at independently via their own `libraries.glob.include`.

## Layout

```
transformations/
  silver/   -- meridian_silver_pipeline's source
  gold/     -- meridian_gold_pipeline's source
```

## Current status
```

- [ ] **Step 9: `transformations/README.md` — Silver paragraph**

Change:

```markdown
**Silver is done.** One `.sql` file per `contracts/*.yml` source —
`participants`, `heart_rate`, `device_metadata`, `wellness_survey`,
`steps`, `sleep` — each defining a `<entity>_prepared` / `<entity>` /
`quarantine_<entity>` set of materialized views (`sleep` adds a fourth,
`sleep_stages`, at a different grain — one row per stage, not per
night).
```

to:

```markdown
**Silver is done.** `transformations/silver/` has one `.sql` file per
`contracts/*.yml` source — `participants`, `heart_rate`,
`device_metadata`, `wellness_survey`, `steps`, `sleep` — each defining a
`<entity>_prepared` / `<entity>` / `quarantine_<entity>` set of
materialized views (`sleep` adds a fourth, `sleep_stages`, at a
different grain — one row per stage, not per night).
```

- [ ] **Step 10: `transformations/README.md` — Gold paragraph**

Change:

```markdown
**Gold is done.** Three `.sql` files — `participant_day`, `participant_week`,
and `participant_study_summary` — each defining a materialized view at their
respective grain (day/week/study). Design rationale and the resolved
`participant_week` schema (previously an open "TBD together" question) are
documented in `docs/superpowers/specs/2026-09-23-gold-transformations-design.md`
and `docs/gold-layer.md` — read those before changing any file here. Nothing
has been deployed or run against a live workspace yet (see `deploy/README.md`'s
"Current status") — these files are written and committed, not executed.
```

to:

```markdown
**Gold is done.** `transformations/gold/` has three `.sql` files —
`participant_day`, `participant_week`, and `participant_study_summary`
— each defining a materialized view at their respective grain
(day/week/study). Each file's own `CREATE OR REFRESH MATERIALIZED
VIEW` line is bare (unqualified), relying on `meridian_gold_pipeline`'s
own default schema — only references *to another Gold view* and to
Silver tables stay `${schema_prefix}`-qualified. Design rationale and
the resolved `participant_week` schema (previously an open "TBD
together" question) are documented in
`docs/superpowers/specs/2026-09-23-gold-transformations-design.md` and
`docs/gold-layer.md` — read those before changing any file here.
Nothing has been deployed or run against a live workspace yet (see
`deploy/README.md`'s "Current status") — these files are written and
committed, not executed.
```

- [ ] **Step 11: `docs/gold-layer.md` — intro paragraph (fixes a claim Task 1 makes false)**

Task 1 made each Gold file's own `CREATE` line bare, so the claim below
that *all* Gold source is `${schema_prefix}`-templated is no longer
accurate — fix it here since it's directly caused by this plan's own
edits, even though it wasn't separately called out in the spec's
downstream-updates list. Change:

```markdown
Gold is the business-facing layer: dashboards, reports, and any other
downstream consumer (including AI tools querying the catalog) should
read from here, never from Silver directly. Three materialized views,
all under `workspace.meridian_gold`, all `${schema_prefix}`-templated in
source like every other cross-schema reference in this repo
(`docs/conventions.md`).
```

to:

```markdown
Gold is the business-facing layer: dashboards, reports, and any other
downstream consumer (including AI tools querying the catalog) should
read from here, never from Silver directly. Three materialized views,
all under `workspace.meridian_gold`. Each view's own `CREATE OR REFRESH
MATERIALIZED VIEW` line is bare, relying on `meridian_gold_pipeline`'s
default `_gold` schema; every *reference* to another view or to a
Silver table stays `${schema_prefix}`-templated, like every other
cross-schema reference in this repo (`docs/conventions.md`).
```

- [ ] **Step 12: `docs/gold-layer.md` — Refresh line (the spec's explicitly-called-out tweak)**

Change:

```markdown
**Refresh:** daily, along with every other table in the pipeline
(`docs/pipeline-architecture.md`'s Orchestration section) — there's no
separate schedule per Gold table.
```

to:

```markdown
**Refresh:** daily, along with every other Gold table, immediately
after Silver's own daily refresh completes
(`docs/pipeline-architecture.md`'s Orchestration section) — there's no
separate schedule per Gold table.
```

- [ ] **Step 13: Verify no stale singular/old-name references remain in these three files**

Run:

```bash
grep -n "meridian_pipeline\b\|meridian_pipeline_job\b" deploy/README.md transformations/README.md docs/gold-layer.md
```

Expected: no output.

- [ ] **Step 14: Commit**

```bash
git add deploy/README.md transformations/README.md docs/gold-layer.md
git commit -m "docs: update deploy and transformations READMEs for split pipelines"
```

---

## Verification

No Databricks execution happens as part of this plan (Global
Constraints) — verification here is local: file content, structural
YAML/logic checks, and the existing `pytest` suite, not a live
`bundle validate`/`deploy`.

1. **Full-repo consistency sweep.** From the repo root:

   ```bash
   grep -rn "meridian_pipeline\b" --include="*.yml" --include="*.py" --include="*.md" \
     --exclude-dir=".git" --exclude-dir="docs/superpowers" .
   ```

   Expected: no output. (`docs/superpowers/specs/` and
   `docs/superpowers/plans/` are excluded deliberately — those are
   historical snapshots per Global Constraints, and legitimately still
   say `meridian_pipeline`/`meridian_pipeline_job`/`transform` when
   describing the pre-split state.)

2. **`pytest` still green.** `cd deploy/scripts && pytest -v` — expect
   20 passed (18 original + 2 new from Task 4), 0 failed.

3. **`git log --oneline -6`** shows six new commits, one per task, in
   order, each with a clean tree (`git status --short` empty after the
   last one).

4. **Spec coverage check** — every "Downstream documentation and script
   updates" bullet in the spec has a corresponding step above:
   `deployment-strategy.md` (Task 5), `pipeline-architecture.md`
   (Task 5), `deploy/README.md` (Task 6), `transformations/README.md`
   (Task 6), `verify_teardown.py` + tests (Task 4), `gold-layer.md`'s
   Refresh line (Task 6, Step 12). The `gold-layer.md` intro-paragraph
   fix (Task 6, Step 11) goes beyond the spec's explicit list because
   Task 1 directly causes it — noted inline there.

5. **Real end-to-end verification is explicitly deferred**, not part of
   this plan's execution, matching the spec's "Known, flagged
   limitations": next time the user says go, `databricks bundle
   validate` / `deploy` / `run meridian_etl_orchestrator` will actually
   exercise the split pipelines against a live workspace. At that point,
   confirm: `transform_silver` completes and populates the `_silver`
   schema before `transform_gold` starts; `meridian_gold_pipeline`'s
   update succeeds reading `${schema_prefix}_silver.*` tables produced
   by a different pipeline (the spec's flagged cross-pipeline-read
   risk); and `bundle destroy` cleanly drops both pipelines' materialized
   views independently.

**Pre-existing staleness deliberately left untouched** (not caused by
this plan, out of scope per the spec's own scoping — flagged here so
it isn't mistaken for something this plan missed):

- `deploy/README.md`'s "Current status" section still says
  `transformations/` is empty — false since before this plan (Silver
  and Gold were both already done and committed).
- `transformations/README.md`'s Silver/Gold paragraphs still say
  "Nothing has been deployed or run against a live workspace yet" —
  contradicted by the 2026-09-23 live run recorded in
  `[[pipeline-e2e-verified]]`.
- `docs/pipeline-architecture.md`'s Gold table row still says
  "**Exact schema TBD together**" for `participant_week` — resolved
  back in the Gold design spec.

These would be reasonable small follow-up fixes but are unrelated to
the pipeline split and orchestrator rename this plan covers.
