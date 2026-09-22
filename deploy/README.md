# Deploy

How to actually run the DAB bundle and the two schema-lifecycle scripts in
this directory, end to end. For *why* it's split this way — DAB owns the
Job and Pipeline, plain scripts own the schemas — see
`docs/deployment-strategy.md`; this file is only the *how*.

Every command below assumes your shell's current directory is `deploy/`
(where `databricks.yml` lives) unless stated otherwise.

## Current status

Everything below has been run end to end against a real Free Edition
workspace and confirmed working, as of 2026-09-22 — except Silver/Gold:
`transformations/` is still empty (see `transformations/README.md`), so
the pipeline has no source to build from yet. What that means for Step 3
is called out inline below.

## Prerequisites

- **Python, with `deploy/scripts/requirements.txt` installed in a virtual
  environment** (created here in `deploy/`, so it stays scoped to this
  directory — already covered by `.gitignore`):
  ```bash
  python -m venv .venv

  # macOS/Linux
  source .venv/bin/activate
  # Windows (PowerShell)
  .venv\Scripts\Activate.ps1
  # Windows (Git Bash)
  source .venv/Scripts/activate

  pip install -r scripts/requirements.txt
  ```
  Re-activate this `.venv` (the `source`/`Activate.ps1` line above) in
  every new shell session before running any command below that invokes
  `python` or `pytest`.
- **The Databricks CLI** — the standalone `databricks` binary, separate
  from the `databricks-sdk` Python package the scripts import:
  ```bash
  # macOS/Linux
  curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh
  # Windows
  winget install Databricks.DatabricksCLI
  ```
  Verify with `databricks --version`.
- **An authenticated CLI profile.** Generate a personal access token in
  the workspace (user icon → Settings → Developer → Access tokens), then:
  ```bash
  databricks configure --host <your-workspace-url>
  ```
  and paste the token when prompted. Using a non-`DEFAULT` profile name?
  Add `--profile <name>` to every command below. Per
  `docs/deployment-strategy.md`'s platform-constraints note: on Free
  Edition, do this from a local machine — CLI auth from inside the
  workspace UI's built-in terminal has open reports of failing.
- **A SQL warehouse ID** — the ingest tasks and `teardown_environment.py`
  both run statements against one:
  ```bash
  databricks warehouses list
  ```
  Use the `ID` column from that output. **Common mistake:** that ID is
  not the fragment in your workspace hostname
  (`dbc-<that-part>.cloud.databricks.com`) — that's the workspace
  instance, a different object, and using it fails deploy with
  `<value> is not a valid endpoint id`. A real warehouse ID looks like
  `7652b86e2ae2901c`. If `warehouses list` comes back empty, create one
  first: workspace UI → SQL Warehouses → Create SQL warehouse → type
  **Serverless**.

  Commands below use `<warehouse-id>` as a placeholder for it. To avoid
  retyping `--var="warehouse_id=<warehouse-id>"` on every command, either
  add it under `targets.dev.variables` in `databricks.yml`, or export it
  once per shell session: `export BUNDLE_VAR_warehouse_id=<warehouse-id>`.

## 1. Run the unit tests

Mocked — no workspace contact, safe to run anytime:

```bash
cd scripts && pytest -v && cd ..
```

## 2. Validate the bundle

Read-only — checks `databricks.yml` and `resources/*.yml` parse and
resolve, creates nothing:

```bash
databricks bundle validate -t dev --var="warehouse_id=<warehouse-id>"
```

## 3. Stand up the environment

```bash
# 1. Schemas (idempotent — safe to re-run)
python scripts/setup_environment.py

# 2. Job + Pipeline
databricks bundle deploy -t dev --var="warehouse_id=<warehouse-id>"

# 3. Trigger a run: ingest tasks (Bronze COPY INTO), then the pipeline
#    update (Silver/Gold materialized views)
databricks bundle run meridian_pipeline_job -t dev
```

Watch progress with `databricks bundle summary -t dev`, which prints
links to the Job and Pipeline in the workspace UI, or check the UI
directly. The job also runs on its own daily schedule (see
`resources/jobs.yml`) — the manual `run` above is only for an immediate
first run or an ad hoc re-run.

Two things to expect here, neither is a bug:

- **Resource names in the UI are prefixed `[dev <your-username>]`** —
  e.g. `[dev leandro_lf_frazao2] meridian_pipeline_job`. That's
  `databricks.yml`'s `targets.dev.mode: development` automatically
  namespacing deployed resources so they don't collide with anyone
  else's dev deployment in a shared workspace.
- **The `transform` task currently fails or no-ops.** It's the task that
  triggers the pipeline; the pipeline has no Silver/Gold source files
  yet (see "Current status" above), so there's nothing for it to build.
  The 6 ingest tasks ahead of it still run and populate Bronze normally.

## 4. Tear it down

Compute/orchestration first, then schemas — reverse of setup, so nothing
trips over an already-dropped schema mid-cleanup:

```bash
# 1. Job + Pipeline (Silver/Gold materialized views go with the Pipeline)
databricks bundle destroy -t dev --var="warehouse_id=<warehouse-id>"

# 2. Schemas — drops meridian_bronze/silver/gold, CASCADE
python scripts/teardown_environment.py --warehouse-id <warehouse-id>
```

`teardown_environment.py` is a soft delete: Unity Catalog keeps dropped
schemas recoverable for 7 days, then purges them permanently within 48
hours.

**Optional: confirm it actually worked.** Read-only, makes no changes:
```bash
python scripts/verify_teardown.py
```
Prints the status of all three schemas plus the job and pipeline, and
exits non-zero if anything's still hanging around.

## Script flags

Both scripts default to `--prefix meridian --catalog workspace`, matching
`databricks.yml`'s `schema_prefix` variable and every `contracts/*.yml`
file — leave both unset unless you're standing up a differently-prefixed
copy of the environment.

| Script | Required | Optional |
|---|---|---|
| `setup_environment.py` | — | `--prefix`, `--catalog` |
| `teardown_environment.py` | `--warehouse-id` | `--prefix`, `--catalog` |
| `verify_teardown.py` | — | `--prefix`, `--catalog`, `--job-name`, `--pipeline-name` |

## Notes

- Only one bundle target exists (`dev`), and it's the bundle's default,
  so `-t dev` above can be omitted — included here for clarity.
- Neither script nor any bundle resource ever touches the raw-data Volume
  (`/Volumes/workspace/default/raw/data/`); it's uploaded manually and
  out of scope for both.
- Full design rationale and decision log: `docs/deployment-strategy.md`.
