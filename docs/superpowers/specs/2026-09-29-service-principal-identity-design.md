# Service-principal identity — Design

Make the `meridian-pipeline-runner` service principal the single
identity that deploys, runs, and owns everything in the Meridian
pipeline: the Job, both Lakeflow pipelines, the three medallion schemas,
and every Bronze/Silver/Gold table — locally and in CI. Afterwards
nothing depends on the user's personal identity or personal access
token.

Scope was confirmed with the user in three questions this session:

1. **Who deploys:** the service principal, always — CI *and* local runs
   (a `meridian-sp` CLI profile), not "CI as SP, humans as themselves".
2. **Migration:** tear down and rebuild under the service principal,
   not in-place ownership transfer. Creator-becomes-owner gives correct
   ownership with no manual transfers, collapses the duplicate bundle
   state (below), and proves the full setup → deploy → run cycle works
   under the service principal.
3. **Secret lifetime:** keep short-lived OAuth secrets, with a written
   rotation runbook plus a scheduled GitHub Action that fails ahead of
   expiry.

## Starting state (checked against the live workspace, 2026-09-29)

Already in place (done 2026-09-28):

- Service principal `meridian-pipeline-runner`, application ID
  `d2a8bef0-ed6e-4a46-9dd1-84a527c9eade`; entitlements
  `workspace-access`, `databricks-sql-access`, `workspace-consume`.
- One active OAuth secret, created 2026-09-28, **expires 2026-10-13**.
- GitHub secrets `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` —
  set, but nothing references them yet.
- UC grants to the SP: `USE_CATALOG` on `workspace`; `ALL_PRIVILEGES`
  on `meridian_bronze/silver/gold`; `USE_SCHEMA` on `workspace.default`;
  `READ_VOLUME` on `workspace.default.raw`.
- `CAN_USE` on the Serverless Starter Warehouse; `CAN_MANAGE` on the Job
  and both pipelines.

Not yet done:

- Job and both pipelines: `run_as` and `IS_OWNER` are the user.
- All three schemas and their tables are owned by the user.
- Both workflows still authenticate with `DATABRICKS_TOKEN` (the
  user's PAT).
- **Two bundle states track the same resource IDs** — one under
  `/Users/<user>/.bundle/meridian/dev` (seq 12), one under
  `/Users/<sp>/.bundle/meridian/dev` (seq 14, the latest deploy). Either
  identity deploying would believe it owns the Job/pipelines.

The SP lacks `CREATE_SCHEMA` on the `workspace` catalog, which it needs
to create the schemas itself.

## Design

### Bundle: `run_as` pinned to the service principal

`deploy/databricks.yml` gains a `service_principal_id` variable
(default: the application ID above — an identifier, not a credential)
and, under `targets.dev`:

```yaml
run_as:
  service_principal_name: ${var.service_principal_id}
```

This makes the Job and both pipelines execute as the SP regardless of
who deploys — a safety net should a human ever deploy by mistake.
Verified this session: `bundle validate` accepts `run_as` together with
`mode: development` and propagates it to the Job and both pipelines.

No bundle `permissions:` block: the user is in the `admins` group, which
already inherits `CAN_MANAGE` on all jobs and pipelines, so UI
visibility and manual triggering are unaffected.

`root_path` stays at its per-user default. With only the SP deploying
there is exactly one state, `/Users/<sp>/.bundle/meridian/dev`.

`mode: development` stays, so deployed names keep the
`[dev meridian_pipeline_runner]` prefix. `verify_teardown.py` matches by
substring, so it needs no change.

### Ownership model

Every object is owned by whoever creates it, and the SP creates all of
them:

| Object | Created by | Owner after migration |
|---|---|---|
| Schemas | `setup_environment.py` under the SP profile | SP |
| Bronze tables | Job `COPY INTO` tasks (`run_as` SP) | SP |
| Silver/Gold materialized views | pipeline updates (`run_as` SP) | SP |
| Job, both pipelines | `bundle deploy` under the SP | SP (`IS_OWNER`) |

### Human read access: `--grant-read-to`

Once the SP owns the schemas, the user no longer has implicit access to
query them. `setup_environment.py` gains an optional
`--grant-read-to <principal>` flag. For each of the three schemas it
grants `USE_SCHEMA` and `SELECT` to that principal through the SDK's
`grants.update` (additive, so it is idempotent). The documented
invocation uses `account users`: the data is synthetic, and this keeps
personal email addresses out of the repo. The flag is left unset by
default, so the script's existing behavior doesn't change. Covered by
pytest, mocked like the rest of the suite.

The scripts pick their profile through the SDK's standard
`DATABRICKS_CONFIG_PROFILE` environment variable. No new `--profile`
flag is added.

### CI: OAuth M2M instead of PAT

In `run-tests.yml` (validate step) and `deploy.yml` (deploy step),
replace

```yaml
DATABRICKS_TOKEN: ${{ secrets.DATABRICKS_TOKEN }}
```

with

```yaml
DATABRICKS_CLIENT_ID: ${{ secrets.DATABRICKS_CLIENT_ID }}
DATABRICKS_CLIENT_SECRET: ${{ secrets.DATABRICKS_CLIENT_SECRET }}
```

The CLI detects OAuth machine-to-machine auth from these on its own.
`DATABRICKS_HOST` doesn't change.

### Secret-expiry alarm: `sp-secret-expiry.yml`

A new workflow that runs daily on a `schedule` and also supports
`workflow_dispatch`. It reads the repo variable
`DATABRICKS_SP_SECRET_EXPIRES` (ISO date, e.g. `2026-10-13`) and fails
if the expiry is **7 days away or less**, or if the variable is missing
or malformed. A failed scheduled run is GitHub's notification
mechanism. The job uses plain shell `date` arithmetic, with no Databricks
access and no secrets.

A repo variable was chosen over querying Databricks because it needs no
extra API permissions: the SP may not be allowed to list its own
secrets, and granting it that ability would widen its privileges just
to support a reminder. The rotation runbook keeps the variable current.

### Documentation

- `docs/deployment-strategy.md`: new **Identity** section (who deploys,
  who runs, who owns what, and why), and an update to the "CI auth" platform
  constraint (now OAuth M2M, not a PAT).
- `deploy/README.md`:
  - Prerequisites gain the `meridian-sp` profile in `~/.databrickscfg`
    (`host`, `client_id`, `client_secret`). The user enters these
    values; they are never pasted into chat or committed.
  - Every CLI command gains `--profile meridian-sp`, and script
    invocations are prefixed with `DATABRICKS_CONFIG_PROFILE=meridian-sp`.
  - Step 3 gains `--grant-read-to "account users"`.
  - New **Rotating the service-principal secret** runbook:
    1. Create a new secret for the SP.
    2. Update the `DATABRICKS_CLIENT_SECRET` GitHub secret and the local
       `meridian-sp` profile.
    3. Update `DATABRICKS_SP_SECRET_EXPIRES`.
    4. Re-run the Deploy workflow (`workflow_dispatch`) to confirm the
       new secret works.
    5. Delete the old secret.
- Root `README.md` CI/CD summary: mention the auth change if it
  references the PAT.

## One-time migration

Runs from the branch **after** its PR checks pass (proving OAuth M2M
works in CI) and **before** merging. Steps 2–5 delete and recreate live
data, and they will be confirmed with the user immediately before
running.

| # | Step | Identity |
|---|---|---|
| 1 | `GRANT CREATE SCHEMA ON CATALOG workspace TO <sp>` | user |
| 2 | `databricks bundle destroy -t dev` (live resources are in the SP's state) | SP |
| 3 | Delete the stale bundle root `/Users/<user>/.bundle/meridian` | user |
| 4 | `teardown_environment.py` (dropping a schema requires its current owner, the user) | user |
| 5 | `setup_environment.py --grant-read-to "account users"` → `bundle deploy` → `bundle run meridian_etl_orchestrator` | SP |
| 6 | Verify: schema/table owners, Job/pipeline `IS_OWNER` and `run_as`, row counts in Gold, the user can `SELECT` from Gold | — |
| 7 | Merge the PR; the triggered Deploy run should be a no-op | CI |
| 8 | Delete the `DATABRICKS_TOKEN` GitHub secret; revoke the PAT | user |

Prerequisite for step 2: the `meridian-sp` local profile exists and
`databricks current-user me --profile meridian-sp` returns the SP.

Step 8 comes only after merge. Until then, `main`'s workflows still use
`DATABRICKS_TOKEN`.

## Out of scope

- `mode: development` side effects (the `[dev …]` name prefix, the
  schedule being paused in development mode). These are unchanged by
  this work.
- A second target or workspace.
- Branch protection on `main` (still recommended, check name
  `test / test`).
- Removing the stale `.worktrees/` directories from earlier PRs.
