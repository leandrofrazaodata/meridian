# Deploy Bundle and Lifecycle Scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the deployment machinery described in `docs/deployment-strategy.md` — the DAB bundle (Job + Lakeflow Pipeline resources) and the two Unity Catalog schema-lifecycle scripts — as real, committed files, without running any of it against Databricks.

**Architecture:** A DAB bundle under `deploy/` declares one Job (six per-contract `COPY INTO` SQL tasks, one per `contracts/*.yml` source, plus a task that triggers the Lakeflow pipeline) and one Lakeflow Pipeline resource. The pipeline resource is a real, deployable shell — catalog/schema/serverless config — pointing at a `transformations/` source directory that intentionally holds only a README for now; the actual Silver/Gold materialized-view SQL is a separate, not-yet-designed body of work (see "Deferred / not in this plan"). Two standalone Python scripts (`deploy/scripts/{setup,teardown}_environment.py`), independent of the bundle, own Unity Catalog schema create/drop via the Databricks SDK.

**Tech Stack:** Databricks Asset Bundles (YAML), Databricks SQL (`COPY INTO`), Python 3, `databricks-sdk`, `pytest` + `unittest.mock` for script tests.

**Spec:** `docs/deployment-strategy.md` (also draws on `docs/pipeline-architecture.md` for what the tables mean, `docs/conventions.md` for naming, `docs/validation-rules.md` for the on_fail model, and all six `contracts/*.yml` files for the exact source paths/formats/schemas that drive the ingest SQL)

## Global Constraints

- Single bundle target `dev` — Free Edition is one workspace (`docs/deployment-strategy.md`).
- Bundle variable `schema_prefix`, default `meridian` — every schema/table reference in bundle resources and both scripts derives from it, never a hardcoded name (`docs/deployment-strategy.md` "Schema prefix").
- Serverless-only compute — no cluster config anywhere; SQL tasks reference a SQL warehouse by ID, the Lakeflow pipeline sets `serverless: true` (`docs/pipeline-architecture.md` "Platform constraints").
- Single catalog `workspace` — no catalog-level object anywhere in this design (`docs/pipeline-architecture.md`).
- `_ingested_at` must be wired as a real job parameter, never `current_date()`/`CURRENT_DATE()` (`docs/conventions.md` "Ingestion metadata columns").
- **Nothing in this plan runs against Databricks.** No `databricks bundle validate/deploy/destroy`, no executing either Python script for real, no auth against any workspace. Every verification step below is either a local YAML-syntax/structure check or a `pytest` run against a fully mocked SDK client. Do not run any `databricks` CLI command or a real `WorkspaceClient()` against a live workspace while executing this plan — stop and ask first if a task seems to need that.
- Silver/Gold transformation SQL (the actual Lakeflow pipeline source) is **not** part of this plan — see "Deferred / not in this plan" at the end.
- All DAB resource field names below (`schema` vs. the deprecated `target`, `sql_task.file.path`, `pipeline_task.pipeline_id`, `glob.include`, job `parameters`/`schedule`/`depends_on` shapes) were checked against the Databricks CLI v1.17.0's own `databricks bundle schema` output, not recalled from memory — see this plan's authoring notes if a future Databricks CLI version changes them.

---

## Task 1: Bundle root config

**Files:**
- Create: `deploy/databricks.yml`

**Interfaces:**
- Produces: bundle variables `${var.schema_prefix}` (default `"meridian"`) and `${var.warehouse_id}` (no default — required at deploy time) that Tasks 2–4 consume. Target `dev` (default target).

- [ ] **Step 1: Write `deploy/databricks.yml`**

```yaml
# DAB bundle root. See docs/deployment-strategy.md for the design this
# implements — why DAB owns only the Job + Pipeline, not schemas.
bundle:
  name: meridian

include:
  - resources/*.yml

variables:
  schema_prefix:
    description: >-
      Prefix for the three medallion schemas (bronze/silver/gold). Every
      bundle resource and both deploy/scripts/*.py scripts read this same
      variable/default rather than hardcoding the name a second time —
      see docs/deployment-strategy.md "Schema prefix". Matches the names
      already used throughout contracts/*.yml and docs/conventions.md.
    default: meridian
  warehouse_id:
    description: >-
      Serverless SQL warehouse ID the Job's COPY INTO tasks run against
      (docs/pipeline-architecture.md "Platform constraints" — serverless-
      only compute, no clusters). No default: every workspace has a
      different warehouse ID. Find yours with `databricks warehouses
      list`, then supply it with --var="warehouse_id=<id>" at deploy
      time, or add it under targets.dev.variables below once known.

targets:
  dev:
    mode: development
    default: true
    # No workspace.host here deliberately: auth comes from the local
    # Databricks CLI profile (`databricks configure`), per
    # docs/deployment-strategy.md's Platform constraints note that Free
    # Edition CLI auth only reliably works from a local machine. Use
    # `--profile <name>` at deploy time for a non-default profile.
```

- [ ] **Step 2: Verify it parses and has the expected shape**

Run:
```bash
python -c "
import yaml
doc = yaml.safe_load(open('deploy/databricks.yml'))
assert doc['bundle']['name'] == 'meridian'
assert doc['variables']['schema_prefix']['default'] == 'meridian'
assert 'default' not in doc['variables']['warehouse_id']
assert doc['targets']['dev']['default'] is True
print('OK')
"
```
Expected: `OK` (requires `pyyaml`; `pip install pyyaml` first if not already present).

- [ ] **Step 3: Commit**

```bash
git add deploy/databricks.yml
git commit -m "deploy: add DAB bundle root config"
```

---

## Task 2: Pipeline resource + transformations stub

**Files:**
- Create: `deploy/resources/pipelines.yml`
- Create: `transformations/README.md`

**Interfaces:**
- Consumes: `${var.schema_prefix}` (Task 1).
- Produces: bundle resource `resources.pipelines.meridian_pipeline`, referenced by Task 4 as `${resources.pipelines.meridian_pipeline.id}`.

- [ ] **Step 1: Write `deploy/resources/pipelines.yml`**

```yaml
resources:
  pipelines:
    meridian_pipeline:
      name: meridian_pipeline
      catalog: workspace
      # `schema` (not the deprecated `target`) is the current field for a
      # pipeline's default schema — confirmed against `databricks bundle
      # schema` output. Gold materialized views still land in
      # <prefix>_gold by fully-qualifying their names inside the pipeline
      # source, spanning both schemas from one pipeline (see
      # docs/pipeline-architecture.md's Gold section).
      schema: ${var.schema_prefix}_silver
      serverless: true
      channel: CURRENT
      continuous: false
      development: false
      configuration:
        # Lets future transformation SQL reference ${schema_prefix}
        # instead of a hardcoded prefix — same one-source-of-truth
        # property as the bundle variable it mirrors.
        schema_prefix: ${var.schema_prefix}
      libraries:
        - glob:
            include: ../../transformations/**
```

- [ ] **Step 2: Write `transformations/README.md`**

```markdown
# Transformations

This directory will hold the Lakeflow Declarative Pipeline source (SQL
files, one materialized view per Silver/Gold table) that
`deploy/resources/pipelines.yml`'s `meridian_pipeline` resource points
at via `libraries.glob.include`.

It's intentionally empty except for this file. Writing the actual
Silver/Gold transformation logic is a separate, not-yet-designed piece
of work from the deployment machinery in `deploy/` — see
`docs/superpowers/plans/2026-09-22-deploy-bundle-and-lifecycle-scripts.md`'s
"Deferred / not in this plan" section for why, and
`docs/pipeline-architecture.md` for what these tables are meant to
contain. Two concrete open questions block a complete first pass:

- `participant_week`'s exact Gold schema — marked "TBD together" in
  `docs/pipeline-architecture.md`.
- The `stuck_sensor` run-length threshold in `contracts/heart_rate.yml`
  — deliberately left open there.

Needs its own brainstorm → spec → plan cycle before any `.sql` file
lands here.
```

- [ ] **Step 3: Verify `pipelines.yml` parses and has the expected shape**

Run:
```bash
python -c "
import yaml
doc = yaml.safe_load(open('deploy/resources/pipelines.yml'))
p = doc['resources']['pipelines']['meridian_pipeline']
assert p['catalog'] == 'workspace'
assert p['schema'] == '\${var.schema_prefix}_silver'
assert p['serverless'] is True
assert p['libraries'][0]['glob']['include'] == '../../transformations/**'
print('OK')
"
```
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add deploy/resources/pipelines.yml transformations/README.md
git commit -m "deploy: add Lakeflow pipeline resource and transformations stub"
```

---

## Task 3: Bronze ingest SQL (all six contracts)

**Files:**
- Create: `deploy/resources/sql/ingest_participants.sql`
- Create: `deploy/resources/sql/ingest_device_metadata.sql`
- Create: `deploy/resources/sql/ingest_wellness_survey.sql`
- Create: `deploy/resources/sql/ingest_heart_rate.sql`
- Create: `deploy/resources/sql/ingest_steps.sql`
- Create: `deploy/resources/sql/ingest_sleep.sql`

**Interfaces:**
- Produces: six `.sql` files under `deploy/resources/sql/`, each a `COPY INTO IDENTIFIER(:target_table) ...` statement expecting two SQL parameters supplied externally: `:target_table` (a fully-qualified table name string) and `:ingested_at` (a date string). Task 4's `sql_task.parameters` blocks supply both — file paths and parameter names must match exactly.
- One task per contract (not one parameterized task looping all six) — deployment-strategy.md left this as a task-authoring decision; six fixed, readable files beat a shared template given how much format/path/column shape already differs contract-to-contract (CSV vs. JSON, `_pid_from_path` needed on three sources but not the other three).

- [ ] **Step 1: Write `deploy/resources/sql/ingest_participants.sql`**

```sql
-- Bronze ingest for contracts/participants.yml.
-- COPY INTO tracks which files it has already loaded, so rerunning this
-- task for a date already ingested is a no-op, not a duplicate load
-- (docs/pipeline-architecture.md "Idempotency & reproducibility").
--
-- Parameters (supplied by deploy/resources/jobs.yml's sql_task.parameters):
--   :target_table  -- "workspace.<schema_prefix>_bronze.participants"
--   :ingested_at   -- job parameter, never CURRENT_DATE() (docs/conventions.md)
COPY INTO IDENTIFIER(:target_table)
FROM (
  SELECT
    *,
    _metadata.file_path AS _source_file,
    CAST(:ingested_at AS DATE) AS _ingested_at
  FROM '/Volumes/workspace/default/raw/data/participants/participants.csv'
)
FILEFORMAT = CSV
FORMAT_OPTIONS ('header' = 'true', 'inferSchema' = 'true')
COPY_OPTIONS ('mergeSchema' = 'true');
```

- [ ] **Step 2: Write `deploy/resources/sql/ingest_device_metadata.sql`**

```sql
-- Bronze ingest for contracts/device_metadata.yml.
-- COPY INTO tracks which files it has already loaded, so rerunning this
-- task for a date already ingested is a no-op, not a duplicate load
-- (docs/pipeline-architecture.md "Idempotency & reproducibility").
--
-- Parameters (supplied by deploy/resources/jobs.yml's sql_task.parameters):
--   :target_table  -- "workspace.<schema_prefix>_bronze.device_metadata"
--   :ingested_at   -- job parameter, never CURRENT_DATE() (docs/conventions.md)
COPY INTO IDENTIFIER(:target_table)
FROM (
  SELECT
    *,
    _metadata.file_path AS _source_file,
    CAST(:ingested_at AS DATE) AS _ingested_at
  FROM '/Volumes/workspace/default/raw/data/health_summaries/device_metadata.csv'
)
FILEFORMAT = CSV
FORMAT_OPTIONS ('header' = 'true', 'inferSchema' = 'true')
COPY_OPTIONS ('mergeSchema' = 'true');
```

- [ ] **Step 3: Write `deploy/resources/sql/ingest_wellness_survey.sql`**

```sql
-- Bronze ingest for contracts/wellness_survey.yml.
-- COPY INTO tracks which files it has already loaded, so rerunning this
-- task for a date already ingested is a no-op, not a duplicate load
-- (docs/pipeline-architecture.md "Idempotency & reproducibility").
--
-- Parameters (supplied by deploy/resources/jobs.yml's sql_task.parameters):
--   :target_table  -- "workspace.<schema_prefix>_bronze.wellness_survey"
--   :ingested_at   -- job parameter, never CURRENT_DATE() (docs/conventions.md)
COPY INTO IDENTIFIER(:target_table)
FROM (
  SELECT
    *,
    _metadata.file_path AS _source_file,
    CAST(:ingested_at AS DATE) AS _ingested_at
  FROM '/Volumes/workspace/default/raw/data/health_summaries/wellness_survey.csv'
)
FILEFORMAT = CSV
FORMAT_OPTIONS ('header' = 'true', 'inferSchema' = 'true')
COPY_OPTIONS ('mergeSchema' = 'true');
```

- [ ] **Step 4: Write `deploy/resources/sql/ingest_heart_rate.sql`**

```sql
-- Bronze ingest for contracts/heart_rate.yml.
-- _pid_from_path is extracted via regex, not trusted from the row's own
-- participant_id column -- Unity Catalog volumes don't support
-- input_file_name(), and Silver cross-checks the two against each other
-- (contracts/heart_rate.yml's pid_matches_path rule; see
-- docs/conventions.md "Ingestion metadata columns").
--
-- Parameters (supplied by deploy/resources/jobs.yml's sql_task.parameters):
--   :target_table  -- "workspace.<schema_prefix>_bronze.heart_rate"
--   :ingested_at   -- job parameter, never CURRENT_DATE() (docs/conventions.md)
COPY INTO IDENTIFIER(:target_table)
FROM (
  SELECT
    *,
    _metadata.file_path AS _source_file,
    CAST(:ingested_at AS DATE) AS _ingested_at,
    regexp_extract(_metadata.file_path, 'wearable_events/([^/]+)/', 1) AS _pid_from_path
  FROM '/Volumes/workspace/default/raw/data/wearable_events/*/heart_rate.json'
)
FILEFORMAT = JSON
FORMAT_OPTIONS ('multiLine' = 'true')
COPY_OPTIONS ('mergeSchema' = 'true');
```

- [ ] **Step 5: Write `deploy/resources/sql/ingest_steps.sql`**

```sql
-- Bronze ingest for contracts/steps.yml.
-- _pid_from_path is extracted via regex, not trusted from the row's own
-- participant_id column -- Unity Catalog volumes don't support
-- input_file_name(), and Silver cross-checks the two against each other
-- (contracts/steps.yml's pid_matches_path rule; see
-- docs/conventions.md "Ingestion metadata columns").
--
-- Parameters (supplied by deploy/resources/jobs.yml's sql_task.parameters):
--   :target_table  -- "workspace.<schema_prefix>_bronze.steps"
--   :ingested_at   -- job parameter, never CURRENT_DATE() (docs/conventions.md)
COPY INTO IDENTIFIER(:target_table)
FROM (
  SELECT
    *,
    _metadata.file_path AS _source_file,
    CAST(:ingested_at AS DATE) AS _ingested_at,
    regexp_extract(_metadata.file_path, 'wearable_events/([^/]+)/', 1) AS _pid_from_path
  FROM '/Volumes/workspace/default/raw/data/wearable_events/*/steps.json'
)
FILEFORMAT = JSON
FORMAT_OPTIONS ('multiLine' = 'true')
COPY_OPTIONS ('mergeSchema' = 'true');
```

- [ ] **Step 6: Write `deploy/resources/sql/ingest_sleep.sql`**

```sql
-- Bronze ingest for contracts/sleep.yml.
-- _pid_from_path is extracted via regex, not trusted from the row's own
-- participant_id column -- Unity Catalog volumes don't support
-- input_file_name(), and Silver cross-checks the two against each other
-- (docs/conventions.md "Ingestion metadata columns"). sleep.yml has no
-- pid_matches_path rule of its own, but the column is added uniformly
-- across all three per-participant JSON sources for consistency.
--
-- Parameters (supplied by deploy/resources/jobs.yml's sql_task.parameters):
--   :target_table  -- "workspace.<schema_prefix>_bronze.sleep"
--   :ingested_at   -- job parameter, never CURRENT_DATE() (docs/conventions.md)
COPY INTO IDENTIFIER(:target_table)
FROM (
  SELECT
    *,
    _metadata.file_path AS _source_file,
    CAST(:ingested_at AS DATE) AS _ingested_at,
    regexp_extract(_metadata.file_path, 'wearable_events/([^/]+)/', 1) AS _pid_from_path
  FROM '/Volumes/workspace/default/raw/data/wearable_events/*/sleep.json'
)
FILEFORMAT = JSON
FORMAT_OPTIONS ('multiLine' = 'true')
COPY_OPTIONS ('mergeSchema' = 'true');
```

- [ ] **Step 7: Verify all six files exist and are non-empty**

Run:
```bash
ls -la deploy/resources/sql/
wc -l deploy/resources/sql/*.sql
```
Expected: 6 files listed, each with a non-zero line count.

- [ ] **Step 8: Commit**

```bash
git add deploy/resources/sql/
git commit -m "deploy: add per-contract Bronze COPY INTO SQL"
```

---

## Task 4: Job resource

**Files:**
- Create: `deploy/resources/jobs.yml`

**Interfaces:**
- Consumes: `${var.schema_prefix}` / `${var.warehouse_id}` (Task 1), `${resources.pipelines.meridian_pipeline.id}` (Task 2), all six SQL file paths (Task 3, referenced as `sql/ingest_<name>.sql` — relative to this file's own directory, `deploy/resources/`, per DAB's path-resolution rule of "relative to the file that declares the path," not the bundle root).
- Produces: bundle resource `resources.jobs.meridian_pipeline_job`.

- [ ] **Step 1: Write `deploy/resources/jobs.yml`**

```yaml
resources:
  jobs:
    meridian_pipeline_job:
      name: meridian_pipeline_job
      parameters:
        - name: ingested_at
          # Dynamic value reference resolved at run time to the job's
          # scheduled/trigger date -- deterministic per run, never
          # CURRENT_DATE() (docs/conventions.md "Ingestion metadata
          # columns"). Override per manual run if backfilling a date.
          default: "{{job.trigger.time.iso_date}}"
      schedule:
        # Adjust the hour/timezone to taste -- nothing in the docs pins a
        # specific time, only "scheduled daily"
        # (docs/pipeline-architecture.md "Orchestration").
        quartz_cron_expression: "0 0 6 * * ?"
        timezone_id: "UTC"
        pause_status: UNPAUSED
      tasks:
        - task_key: ingest_participants
          sql_task:
            warehouse_id: ${var.warehouse_id}
            file:
              path: sql/ingest_participants.sql
            parameters:
              target_table: "workspace.${var.schema_prefix}_bronze.participants"
              ingested_at: "{{job.parameters.ingested_at}}"
        - task_key: ingest_device_metadata
          sql_task:
            warehouse_id: ${var.warehouse_id}
            file:
              path: sql/ingest_device_metadata.sql
            parameters:
              target_table: "workspace.${var.schema_prefix}_bronze.device_metadata"
              ingested_at: "{{job.parameters.ingested_at}}"
        - task_key: ingest_wellness_survey
          sql_task:
            warehouse_id: ${var.warehouse_id}
            file:
              path: sql/ingest_wellness_survey.sql
            parameters:
              target_table: "workspace.${var.schema_prefix}_bronze.wellness_survey"
              ingested_at: "{{job.parameters.ingested_at}}"
        - task_key: ingest_heart_rate
          sql_task:
            warehouse_id: ${var.warehouse_id}
            file:
              path: sql/ingest_heart_rate.sql
            parameters:
              target_table: "workspace.${var.schema_prefix}_bronze.heart_rate"
              ingested_at: "{{job.parameters.ingested_at}}"
        - task_key: ingest_steps
          sql_task:
            warehouse_id: ${var.warehouse_id}
            file:
              path: sql/ingest_steps.sql
            parameters:
              target_table: "workspace.${var.schema_prefix}_bronze.steps"
              ingested_at: "{{job.parameters.ingested_at}}"
        - task_key: ingest_sleep
          sql_task:
            warehouse_id: ${var.warehouse_id}
            file:
              path: sql/ingest_sleep.sql
            parameters:
              target_table: "workspace.${var.schema_prefix}_bronze.sleep"
              ingested_at: "{{job.parameters.ingested_at}}"
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

- [ ] **Step 2: Verify it parses and has the expected shape**

Run:
```bash
python -c "
import yaml
doc = yaml.safe_load(open('deploy/resources/jobs.yml'))
job = doc['resources']['jobs']['meridian_pipeline_job']
task_keys = [t['task_key'] for t in job['tasks']]
assert task_keys == ['ingest_participants', 'ingest_device_metadata', 'ingest_wellness_survey', 'ingest_heart_rate', 'ingest_steps', 'ingest_sleep', 'transform']
ingest_tasks = [t for t in job['tasks'] if t['task_key'] != 'transform']
assert all('sql_task' in t for t in ingest_tasks)
assert all(t['sql_task']['parameters']['ingested_at'] == '{{job.parameters.ingested_at}}' for t in ingest_tasks)
transform = job['tasks'][-1]
assert transform['pipeline_task']['pipeline_id'] == '\${resources.pipelines.meridian_pipeline.id}'
assert len(transform['depends_on']) == 6
print('OK')
"
```
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add deploy/resources/jobs.yml
git commit -m "deploy: add orchestration job (six ingest tasks + pipeline trigger)"
```

---

## Task 5: `setup_environment.py`

**Files:**
- Create: `deploy/scripts/setup_environment.py`
- Create: `deploy/scripts/test_setup_environment.py`
- Create: `deploy/scripts/requirements.txt`

**Interfaces:**
- Produces: `ensure_schema(client, catalog: str, schema_name: str) -> bool`, `main(argv: list[str] | None = None, client: WorkspaceClient | None = None) -> None`, `LAYERS = ("bronze", "silver", "gold")`, `PREFIX_DEFAULT = "meridian"`, `CATALOG_DEFAULT = "workspace"`. `main`'s `client` parameter is the seam tests use to avoid a real `WorkspaceClient()` — Task 6 mirrors this exact pattern independently (no import between the two scripts).
- Verified prior to this plan being written: the exact `databricks-sdk` calls below (`WorkspaceClient().schemas.create(name=, catalog_name=)`, `.schemas.get(full_name)`, `databricks.sdk.errors.NotFound`) were checked against the installed package's real signatures, and this file's test suite was run for real (`pytest`, all passing, fully mocked — no workspace contact).

- [ ] **Step 1: Write `deploy/scripts/requirements.txt`**

```
databricks-sdk>=0.30.0
```

- [ ] **Step 2: Write the failing test file `deploy/scripts/test_setup_environment.py`**

```python
from unittest.mock import MagicMock, call

from databricks.sdk.errors import NotFound

from setup_environment import LAYERS, ensure_schema, main


def test_ensure_schema_creates_when_missing():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")

    created = ensure_schema(client, "workspace", "meridian_bronze")

    assert created is True
    client.schemas.get.assert_called_once_with("workspace.meridian_bronze")
    client.schemas.create.assert_called_once_with(name="meridian_bronze", catalog_name="workspace")


def test_ensure_schema_skips_when_present():
    client = MagicMock()
    client.schemas.get.return_value = object()  # any truthy SchemaInfo-like value

    created = ensure_schema(client, "workspace", "meridian_bronze")

    assert created is False
    client.schemas.create.assert_not_called()


def test_main_creates_all_three_layers_with_default_prefix():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")

    main([], client=client)

    expected = [call(name=f"meridian_{layer}", catalog_name="workspace") for layer in LAYERS]
    assert client.schemas.create.call_args_list == expected


def test_main_honors_custom_prefix_and_catalog():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")

    main(["--prefix", "meridian_dev", "--catalog", "sandbox"], client=client)

    expected = [call(name=f"meridian_dev_{layer}", catalog_name="sandbox") for layer in LAYERS]
    assert client.schemas.create.call_args_list == expected
```

- [ ] **Step 3: Run it and confirm it fails (module doesn't exist yet)**

Run: `cd deploy/scripts && pip install -r requirements.txt pytest -q && pytest test_setup_environment.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'setup_environment'`.

- [ ] **Step 4: Write `deploy/scripts/setup_environment.py`**

```python
"""Create the Meridian medallion schemas (bronze/silver/gold) in Unity Catalog.

Idempotent -- safe to re-run; schemas that already exist are left alone.
Owned by this script, not the DAB bundle in deploy/ -- see
docs/deployment-strategy.md for why.

Usage:
    python deploy/scripts/setup_environment.py [--prefix meridian] [--catalog workspace]

The --prefix default matches deploy/databricks.yml's schema_prefix bundle
variable default, so an unmodified run of each tool reaches the same
schemas -- see docs/deployment-strategy.md's "Schema prefix" section.
"""
from __future__ import annotations

import argparse

from databricks.sdk import WorkspaceClient
from databricks.sdk.errors import NotFound

CATALOG_DEFAULT = "workspace"
PREFIX_DEFAULT = "meridian"
LAYERS = ("bronze", "silver", "gold")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", default=PREFIX_DEFAULT, help="Schema prefix (default: %(default)s)")
    parser.add_argument("--catalog", default=CATALOG_DEFAULT, help="Unity Catalog catalog name (default: %(default)s)")
    return parser.parse_args(argv)


def ensure_schema(client: WorkspaceClient, catalog: str, schema_name: str) -> bool:
    """Create catalog.schema_name if it doesn't exist yet.

    Returns True if it was created, False if it already existed.
    """
    full_name = f"{catalog}.{schema_name}"
    try:
        client.schemas.get(full_name)
        return False
    except NotFound:
        client.schemas.create(name=schema_name, catalog_name=catalog)
        return True


def main(argv: list[str] | None = None, client: WorkspaceClient | None = None) -> None:
    args = parse_args(argv)
    client = client or WorkspaceClient()
    for layer in LAYERS:
        schema_name = f"{args.prefix}_{layer}"
        created = ensure_schema(client, args.catalog, schema_name)
        status = "created" if created else "already exists"
        print(f"{args.catalog}.{schema_name}: {status}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: Run the tests again and confirm they pass**

Run: `cd deploy/scripts && pytest test_setup_environment.py -v`
Expected: 4 passed.

- [ ] **Step 6: Commit**

```bash
git add deploy/scripts/setup_environment.py deploy/scripts/test_setup_environment.py deploy/scripts/requirements.txt
git commit -m "deploy: add setup_environment.py (idempotent schema creation)"
```

---

## Task 6: `teardown_environment.py`

**Files:**
- Create: `deploy/scripts/teardown_environment.py`
- Create: `deploy/scripts/test_teardown_environment.py`
- Modify: `CLAUDE.md` (repository contents note)

**Interfaces:**
- Consumes: nothing from Task 5 by import — independent script, deliberately mirroring `setup_environment.py`'s CLI/testing shape rather than sharing code, per `docs/deployment-strategy.md`'s framing of the two scripts as separate tools.
- Produces: `drop_schema_cascade(client, warehouse_id: str, catalog: str, schema_name: str) -> None`, `main(argv: list[str] | None = None, client: WorkspaceClient | None = None) -> None`, `LAYERS = ("gold", "silver", "bronze")`.
- Verified prior to this plan being written: `client.statement_execution.execute_statement(warehouse_id=, statement=, wait_timeout=)` and `StatementResponse.status.{state,error}` were checked against the installed `databricks-sdk` package's real signatures, and this file's test suite was run for real (`pytest`, all passing, fully mocked — no workspace/warehouse contact).

- [ ] **Step 1: Write the failing test file `deploy/scripts/test_teardown_environment.py`**

```python
from unittest.mock import MagicMock

import pytest
from databricks.sdk.service.sql import StatementState

from teardown_environment import LAYERS, drop_schema_cascade, main


def _response(state):
    response = MagicMock()
    response.status.state = state
    response.status.error = None
    return response


def test_drop_schema_cascade_succeeds_silently_on_success():
    client = MagicMock()
    client.statement_execution.execute_statement.return_value = _response(StatementState.SUCCEEDED)

    drop_schema_cascade(client, "wh-123", "workspace", "meridian_bronze")

    client.statement_execution.execute_statement.assert_called_once_with(
        warehouse_id="wh-123",
        statement="DROP SCHEMA IF EXISTS workspace.meridian_bronze CASCADE",
        wait_timeout="30s",
    )


def test_drop_schema_cascade_raises_on_failure():
    client = MagicMock()
    client.statement_execution.execute_statement.return_value = _response(StatementState.FAILED)

    with pytest.raises(RuntimeError, match="meridian_bronze"):
        drop_schema_cascade(client, "wh-123", "workspace", "meridian_bronze")


def test_main_drops_all_three_layers_gold_first():
    client = MagicMock()
    client.statement_execution.execute_statement.return_value = _response(StatementState.SUCCEEDED)

    main(["--warehouse-id", "wh-123"], client=client)

    statements = [c.kwargs["statement"] for c in client.statement_execution.execute_statement.call_args_list]
    assert statements == [
        "DROP SCHEMA IF EXISTS workspace.meridian_gold CASCADE",
        "DROP SCHEMA IF EXISTS workspace.meridian_silver CASCADE",
        "DROP SCHEMA IF EXISTS workspace.meridian_bronze CASCADE",
    ]


def test_main_requires_warehouse_id():
    with pytest.raises(SystemExit):
        main([])
```

- [ ] **Step 2: Run it and confirm it fails (module doesn't exist yet)**

Run: `cd deploy/scripts && pytest test_teardown_environment.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'teardown_environment'`.

- [ ] **Step 3: Write `deploy/scripts/teardown_environment.py`**

```python
"""Drop the Meridian medallion schemas (bronze/silver/gold), cascading.

Soft delete: Unity Catalog keeps dropped schemas recoverable for 7 days,
purged permanently within 48 hours after that -- see
docs/deployment-strategy.md's "What the scripts own" section for why this
runs raw SQL instead of the SDK's schemas.delete() (no CASCADE option
there). Never touches the raw-data Volume.

Usage:
    python deploy/scripts/teardown_environment.py --warehouse-id <id> \
        [--prefix meridian] [--catalog workspace]
"""
from __future__ import annotations

import argparse

from databricks.sdk import WorkspaceClient
from databricks.sdk.service.sql import StatementState

CATALOG_DEFAULT = "workspace"
PREFIX_DEFAULT = "meridian"
# Drop in the reverse of setup_environment.py's creation order -- no
# dependency between the three schemas requires this, but it keeps
# teardown a deliberate mirror of setup rather than an arbitrary order.
LAYERS = ("gold", "silver", "bronze")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--warehouse-id", required=True, help="SQL warehouse ID to run the DROP statements on")
    parser.add_argument("--prefix", default=PREFIX_DEFAULT, help="Schema prefix (default: %(default)s)")
    parser.add_argument("--catalog", default=CATALOG_DEFAULT, help="Unity Catalog catalog name (default: %(default)s)")
    return parser.parse_args(argv)


def drop_schema_cascade(client: WorkspaceClient, warehouse_id: str, catalog: str, schema_name: str) -> None:
    statement = f"DROP SCHEMA IF EXISTS {catalog}.{schema_name} CASCADE"
    response = client.statement_execution.execute_statement(
        warehouse_id=warehouse_id,
        statement=statement,
        wait_timeout="30s",
    )
    state = response.status.state
    if state != StatementState.SUCCEEDED:
        error = getattr(response.status, "error", None)
        raise RuntimeError(f"{statement} did not succeed (state={state}): {error}")


def main(argv: list[str] | None = None, client: WorkspaceClient | None = None) -> None:
    args = parse_args(argv)
    client = client or WorkspaceClient()
    for layer in LAYERS:
        schema_name = f"{args.prefix}_{layer}"
        drop_schema_cascade(client, args.warehouse_id, args.catalog, schema_name)
        print(f"{args.catalog}.{schema_name}: dropped (cascade)")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the tests again and confirm they pass**

Run: `cd deploy/scripts && pytest test_teardown_environment.py -v`
Expected: 4 passed.

- [ ] **Step 5: Run the full `deploy/scripts` test suite together**

Run: `cd deploy/scripts && pytest -v`
Expected: 8 passed (4 from Task 5 + 4 from this task).

- [ ] **Step 6: Update `CLAUDE.md`'s tooling note**

In `CLAUDE.md`, under "Repository contents", replace:
```markdown
This repo is becoming a data engineering pipeline built on top of a raw
synthetic health/wearables dataset (`data/`). There is no build/lint/test
tooling yet — it will be added as the pipeline takes shape.
```
with:
```markdown
This repo is becoming a data engineering pipeline built on top of a raw
synthetic health/wearables dataset (`data/`). `deploy/scripts/` (the
Unity Catalog schema-lifecycle scripts) has a `pytest` suite — run it
from `deploy/scripts/` with `pytest`. No build/lint/test tooling exists
yet for the rest of the repo — it will be added as the pipeline takes
shape.
```

- [ ] **Step 7: Commit**

```bash
git add deploy/scripts/teardown_environment.py deploy/scripts/test_teardown_environment.py CLAUDE.md
git commit -m "deploy: add teardown_environment.py (cascading schema drop)"
```

---

## Deferred / not in this plan

- **Silver/Gold transformation SQL** (the actual Lakeflow Declarative Pipeline source under `transformations/`) — a separate, not-yet-designed body of work. Two concrete open questions block it: `participant_week`'s exact Gold schema ("TBD together" in `docs/pipeline-architecture.md`) and the `stuck_sensor` run-length threshold (`contracts/heart_rate.yml`). Needs its own brainstorm → spec → plan cycle.
- **Running any of this** — `databricks bundle validate`/`deploy`/`destroy`, or either script against a real workspace — stays blocked on the standing project rule: nothing gets built or executed in Databricks until the user explicitly says go. This plan only produces files.
- **`warehouse_id`'s real value** — environment-specific, not knowable from the repo; whoever runs `bundle deploy` first needs to supply it.
- A convenience wrapper chaining `setup → deploy` and `destroy → teardown` — `docs/deployment-strategy.md` already flags this as nice-to-have, not required.
