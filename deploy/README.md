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
- **A `meridian-sp` CLI profile for the service principal.** Everything
  below deploys and runs as the `meridian-pipeline-runner` service
  principal, never as you (see `docs/deployment-strategy.md` "Identity").
  Add this to `~/.databrickscfg` yourself, with the SP's application ID
  and an OAuth secret (workspace UI → Settings → Identity and access →
  Service principals → `meridian-pipeline-runner` → Secrets):
  ```ini
  [meridian-sp]
  host          = https://<workspace>.cloud.databricks.com
  client_id     = <service principal application ID>
  client_secret = <OAuth secret — never commit it or paste it anywhere else>
  ```
  Verify with `databricks current-user me --profile meridian-sp` — it
  should print `meridian-pipeline-runner`. Every `databricks` command
  below takes `--profile meridian-sp`; every `python scripts/...` command
  picks the profile up from `DATABRICKS_CONFIG_PROFILE` (in PowerShell:
  `$env:DATABRICKS_CONFIG_PROFILE="meridian-sp"` once per session). Per
  `docs/deployment-strategy.md`'s platform-constraints note: on Free
  Edition, do this from a local machine — CLI auth from inside the
  workspace UI's built-in terminal has open reports of failing.
- **A SQL warehouse ID** — the ingest tasks and `teardown_environment.py`
  both run statements against one:
  ```bash
  databricks warehouses list --profile meridian-sp
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
databricks bundle validate -t dev --profile meridian-sp --var="warehouse_id=<warehouse-id>"
```

## 3. Stand up the environment

```bash
# 1. Schemas (idempotent — safe to re-run). Owned by the SP, so grant
#    humans read access explicitly
DATABRICKS_CONFIG_PROFILE=meridian-sp python scripts/setup_environment.py --grant-read-to "account users"

# 2. Job + Pipelines
databricks bundle deploy -t dev --profile meridian-sp --var="warehouse_id=<warehouse-id>"

# 3. Trigger a run: ingest tasks (Bronze COPY INTO), then the Silver and
#    Gold pipeline updates in sequence
databricks bundle run meridian_etl_orchestrator -t dev --profile meridian-sp --var="warehouse_id=<warehouse-id>"
```

Watch progress with `databricks bundle summary -t dev --profile meridian-sp --var="warehouse_id=<warehouse-id>"`, which prints
links to the Job and both Pipelines in the workspace UI, or check the
UI directly. The job also runs on its own daily schedule (see
`resources/jobs.yml`) — the manual `run` above is only for an immediate
first run or an ad hoc re-run.

Two things to expect here, neither is a bug:

- **Resource names in the UI are prefixed `[dev meridian_pipeline_runner]`**
  — the deploying identity, the service principal. That's
  `databricks.yml`'s `targets.dev.mode: development` automatically
  namespacing deployed resources so they don't collide with anyone
  else's dev deployment in a shared workspace.
- **The `transform_silver`/`transform_gold` tasks currently fail or
  no-op.** These are the tasks that trigger the Silver and Gold
  pipelines; if `transformations/` has no source files for a layer (see
  "Current status" above), there's nothing for that layer's pipeline to
  build. The 6 ingest tasks ahead of them still run and populate Bronze
  normally.

## 4. Tear it down

Compute/orchestration first, then schemas — reverse of setup, so nothing
trips over an already-dropped schema mid-cleanup:

```bash
# 1. Job + Pipelines (Silver/Gold materialized views go with their
#    respective Pipeline)
databricks bundle destroy -t dev --profile meridian-sp --var="warehouse_id=<warehouse-id>"

# 2. Schemas — drops meridian_bronze/silver/gold, CASCADE (only the
#    owner, the SP, can drop them)
DATABRICKS_CONFIG_PROFILE=meridian-sp python scripts/teardown_environment.py --warehouse-id <warehouse-id>
```

`teardown_environment.py` is a soft delete: Unity Catalog keeps dropped
schemas recoverable for 7 days, then purges them permanently within 48
hours.

**Optional: confirm it actually worked.** Read-only, makes no changes:
```bash
DATABRICKS_CONFIG_PROFILE=meridian-sp python scripts/verify_teardown.py
```
Prints the status of all three schemas plus the job and both pipelines,
and exits non-zero if anything's still hanging around.

## Rotating the service-principal secret

The SP's OAuth secrets are short-lived on purpose. The `SP secret expiry`
GitHub Actions workflow starts failing daily once expiry is 7 days away
or less — that's the signal to rotate. An expired secret breaks CI and
local deploys, not scheduled Job runs. Find the SP's numeric ID with
`databricks service-principals list`.

1. Create a new secret. The response contains the secret value and its
   `expire_time` — shown once only:
   ```bash
   databricks service-principal-secrets-proxy create <sp-numeric-id>
   ```
2. Paste the new value straight into the `DATABRICKS_CLIENT_SECRET`
   GitHub secret (repo Settings → Secrets and variables → Actions) and
   into `client_secret` under `[meridian-sp]` in `~/.databrickscfg`.
3. Record the new expiry date:
   ```bash
   gh variable set DATABRICKS_SP_SECRET_EXPIRES --body <YYYY-MM-DD>
   ```
4. Confirm the new secret works, locally and in CI:
   ```bash
   databricks current-user me --profile meridian-sp
   gh workflow run deploy.yml && gh run watch
   ```
5. Delete the old secret (its ID is in `list` output):
   ```bash
   databricks service-principal-secrets-proxy list <sp-numeric-id>
   databricks service-principal-secrets-proxy delete <sp-numeric-id> <old-secret-id>
   ```

## Script flags

Both scripts default to `--prefix meridian --catalog workspace`, matching
`databricks.yml`'s `schema_prefix` variable and every `contracts/*.yml`
file — leave both unset unless you're standing up a differently-prefixed
copy of the environment.

| Script | Required | Optional |
|---|---|---|
| `setup_environment.py` | — | `--prefix`, `--catalog`, `--grant-read-to` |
| `teardown_environment.py` | `--warehouse-id` | `--prefix`, `--catalog` |
| `verify_teardown.py` | — | `--prefix`, `--catalog`, `--job-name`, `--silver-pipeline-name`, `--gold-pipeline-name` |

## Notes

- Only one bundle target exists (`dev`), and it's the bundle's default,
  so `-t dev` above can be omitted — included here for clarity.
- Neither script nor any bundle resource ever touches the raw-data Volume
  (`/Volumes/workspace/default/raw/data/`); it's uploaded manually and
  out of scope for both.
- Full design rationale and decision log: `docs/deployment-strategy.md`.
- Merges to `main` that touch `deploy/**` or `transformations/**` also
  trigger an automatic `bundle deploy` via GitHub Actions
  (`.github/workflows/deploy.yml`) — the manual Step 3 commands above
  still work the same way for a first-time or ad hoc deploy; the
  automation just keeps things in sync afterward. See
  `docs/superpowers/specs/2026-09-25-cicd-design.md`.
