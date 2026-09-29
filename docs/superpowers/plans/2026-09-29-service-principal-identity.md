# Service-Principal Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `meridian-pipeline-runner` service principal the single identity that deploys, runs, and owns the Meridian Job, pipelines, schemas, and tables. This covers local deploys and CI.

**Architecture:**
- The bundle pins `run_as` to the SP.
- `setup_environment.py` gains an optional `--grant-read-to` flag so humans keep query access to SP-owned schemas.
- CI switches from a PAT to OAuth M2M (`DATABRICKS_CLIENT_ID`/`DATABRICKS_CLIENT_SECRET`).
- A scheduled workflow warns before the SP's short-lived secret expires.
- Existing objects are migrated by tearing down and rebuilding them under the SP.

**Tech Stack:** Databricks Asset Bundles (CLI v1.17.0), Databricks Python SDK, pytest, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-29-service-principal-identity-design.md`

## Global Constraints

- Service principal application ID: `d2a8bef0-ed6e-4a46-9dd1-84a527c9eade` (an identifier, safe to commit). Display name: `meridian-pipeline-runner`.
- Local CLI profile name: `meridian-sp`. Scripts select it through `DATABRICKS_CONFIG_PROFILE=meridian-sp`; CLI commands use `--profile meridian-sp`.
- Never read, print, paste, or commit a client secret or PAT value. The user enters these themselves.
- Read-access principal in the docs: `account users`.
- Expiry alarm threshold: fail when the expiry date is **7 days away or less**. Repo variable name: `DATABRICKS_SP_SECRET_EXPIRES`, ISO `YYYY-MM-DD`.
- Only one bundle target (`dev`), still `mode: development`. Serverless only, with no cluster config.
- Run pytest from `deploy/scripts/` using `deploy/.venv`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. `--grant-read-to` is given but empty (`""`). The script should reject it and create nothing, not send a grant to principal `""`.
2. `--grant-read-to` on a re-run where the schemas already exist. The grant should still be applied, since existing schemas may lack it. Test: grants happen even when `schemas.get` succeeds.
3. `DATABRICKS_SP_SECRET_EXPIRES` is unset or malformed. The expiry workflow should fail loudly, not pass silently.
4. The expiry date is exactly 7 days out, or already past. The workflow should fail in both cases (the boundary is inclusive).
5. A human deploys with their own profile by mistake. `run_as` should still make the Job and pipelines run as the SP. Verified through `bundle validate` output in Task 2.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `deploy/scripts/setup_environment.py` | Modify | Adds `--grant-read-to` and a `grant_read` helper |
| `deploy/scripts/test_setup_environment.py` | Modify | Tests for the above |
| `deploy/databricks.yml` | Modify | `service_principal_id` variable plus `run_as` under `targets.dev` |
| `.github/workflows/run-tests.yml` | Modify | OAuth M2M env for `bundle validate` |
| `.github/workflows/deploy.yml` | Modify | OAuth M2M env for `bundle deploy` |
| `.github/workflows/sp-secret-expiry.yml` | Create | Daily expiry alarm |
| `docs/deployment-strategy.md` | Modify | New Identity section; CI auth constraint update |
| `deploy/README.md` | Modify | SP profile prerequisite, `--profile` on commands, rotation runbook |

---

### Task 1: `--grant-read-to` in `setup_environment.py`

**Files:**
- Modify: `deploy/scripts/setup_environment.py`
- Test: `deploy/scripts/test_setup_environment.py`

**Interfaces:**
- Produces: `grant_read(client: WorkspaceClient, catalog: str, schema_name: str, principal: str) -> None`, and the CLI flag `--grant-read-to PRINCIPAL` (default `None`).
- SDK call used: `client.grants.update("schema", "<catalog>.<schema>", changes=[PermissionsChange(principal=..., add=[Privilege.USE_SCHEMA, Privilege.SELECT])])`. The `grants.update` add operation is additive, so re-running it is idempotent.

- [ ] **Step 1: Write the failing tests.** Append to `deploy/scripts/test_setup_environment.py`, and extend the import line to `from setup_environment import LAYERS, ensure_schema, grant_read, main`. Add `import pytest` and `from databricks.sdk.service.catalog import PermissionsChange, Privilege` at the top.

```python
def test_grant_read_adds_use_schema_and_select():
    client = MagicMock()

    grant_read(client, "workspace", "meridian_gold", "account users")

    client.grants.update.assert_called_once_with(
        "schema",
        "workspace.meridian_gold",
        changes=[PermissionsChange(principal="account users", add=[Privilege.USE_SCHEMA, Privilege.SELECT])],
    )


def test_main_grants_read_on_all_layers_when_flag_set():
    client = MagicMock()
    client.schemas.get.return_value = object()  # schemas already exist -- grants must still apply

    main(["--grant-read-to", "account users"], client=client)

    granted = [c.args[1] for c in client.grants.update.call_args_list]
    assert granted == [f"workspace.meridian_{layer}" for layer in LAYERS]


def test_main_skips_grants_by_default():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")

    main([], client=client)

    client.grants.update.assert_not_called()


def test_main_rejects_empty_grant_principal():
    client = MagicMock()

    with pytest.raises(SystemExit):
        main(["--grant-read-to", ""], client=client)

    client.schemas.create.assert_not_called()
    client.grants.update.assert_not_called()
```

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `cd deploy/scripts && ../.venv/Scripts/python -m pytest test_setup_environment.py -v`
Expected: ImportError on `grant_read` (collection error).

- [ ] **Step 3: Implement.** In `setup_environment.py`:
  - Add `from databricks.sdk.service.catalog import PermissionsChange, Privilege`.
  - Add the flag in `parse_args`:

```python
    parser.add_argument(
        "--grant-read-to",
        metavar="PRINCIPAL",
        help="Also grant USE SCHEMA + SELECT on every schema to this principal "
        "(user, group, or SP application ID) -- e.g. 'account users'",
    )
    args = parser.parse_args(argv)
    if args.grant_read_to is not None and not args.grant_read_to.strip():
        parser.error("--grant-read-to must not be empty")
    return args
```

  (Replace the existing `return parser.parse_args(argv)` line.)

  - Add after `ensure_schema`:

```python
def grant_read(client: WorkspaceClient, catalog: str, schema_name: str, principal: str) -> None:
    """Grant USE SCHEMA + SELECT on catalog.schema_name to principal. Additive, so re-running is harmless."""
    client.grants.update(
        "schema",
        f"{catalog}.{schema_name}",
        changes=[PermissionsChange(principal=principal, add=[Privilege.USE_SCHEMA, Privilege.SELECT])],
    )
```

  - In `main`, inside the loop after the `print`:

```python
        if args.grant_read_to:
            grant_read(client, args.catalog, schema_name, args.grant_read_to)
            print(f"{args.catalog}.{schema_name}: read granted to {args.grant_read_to}")
```

  - Update the module docstring's Usage line to include `[--grant-read-to PRINCIPAL]`, and add one sentence: schemas are owned by whoever runs the script (run it as the service principal, see `docs/deployment-strategy.md` "Identity"), so `--grant-read-to` keeps humans able to query them.

- [ ] **Step 4: Run the full suite and confirm it passes.**

Run: `cd deploy/scripts && ../.venv/Scripts/python -m pytest -v`
Expected: all tests pass (the previous count plus 4).

- [ ] **Step 5: Commit.**

```bash
git add deploy/scripts/setup_environment.py deploy/scripts/test_setup_environment.py
git commit -m "setup_environment: add --grant-read-to for SP-owned schemas"
```

---

### Task 2: Bundle `run_as` pinned to the SP

**Files:**
- Modify: `deploy/databricks.yml`

**Interfaces:**
- Produces: the bundle variable `service_principal_id` (default `d2a8bef0-ed6e-4a46-9dd1-84a527c9eade`). The dev target runs as it.

- [ ] **Step 1: Add the variable** under `variables:`, after `warehouse_id`:

```yaml
  service_principal_id:
    description: >-
      Application ID of the service principal every Job/Pipeline runs as,
      and the only identity that deploys this bundle (locally via the
      `meridian-sp` CLI profile, and in CI). An identifier, not a
      credential. See docs/deployment-strategy.md "Identity".
    default: d2a8bef0-ed6e-4a46-9dd1-84a527c9eade
```

- [ ] **Step 2: Add `run_as`** under `targets.dev`, after the existing comment block:

```yaml
    # Job and both pipelines always execute as the service principal,
    # even if a human ever deploys by mistake -- docs/deployment-strategy.md
    # "Identity".
    run_as:
      service_principal_name: ${var.service_principal_id}
```

- [ ] **Step 3: Validate (read-only)** with the user's DEFAULT profile, since the SP profile may not exist yet:

Run: `cd deploy && databricks bundle validate -t dev --var="warehouse_id=7652b86e2ae2901c" -o json | grep -A1 '"run_as"'`
Expected: 4 occurrences, each followed by `"service_principal_name": "d2a8bef0-ed6e-4a46-9dd1-84a527c9eade"` (bundle-level, the job, and both pipelines). No `Error:` lines. This also covers Review Focus #5.

- [ ] **Step 4: Commit.**

```bash
git add deploy/databricks.yml
git commit -m "bundle: run Job and pipelines as the meridian-pipeline-runner SP"
```

---

### Task 3: CI auth to OAuth M2M, plus the secret-expiry alarm

**Files:**
- Modify: `.github/workflows/run-tests.yml`, `.github/workflows/deploy.yml`
- Create: `.github/workflows/sp-secret-expiry.yml`

**Interfaces:**
- Consumes: the GitHub secrets `DATABRICKS_HOST`, `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET` (all already exist), and the repo variable `DATABRICKS_SP_SECRET_EXPIRES` (created in Step 4).

- [ ] **Step 1: Swap auth env vars.** In both `run-tests.yml` ("Validate bundle" step) and `deploy.yml` ("Deploy bundle" step), replace

```yaml
          DATABRICKS_TOKEN: ${{ secrets.DATABRICKS_TOKEN }}
```

with

```yaml
          # OAuth M2M as the meridian-pipeline-runner service principal --
          # see docs/deployment-strategy.md "Identity".
          DATABRICKS_CLIENT_ID: ${{ secrets.DATABRICKS_CLIENT_ID }}
          DATABRICKS_CLIENT_SECRET: ${{ secrets.DATABRICKS_CLIENT_SECRET }}
```

- [ ] **Step 2: Create `.github/workflows/sp-secret-expiry.yml`:**

```yaml
# Fails 7 days (or fewer) before the service principal's OAuth secret
# expires, so a failed scheduled run is the rotation reminder. Reads the
# expiry from a repo variable rather than querying Databricks, so it
# needs no Databricks credentials at all -- see
# docs/superpowers/specs/2026-09-29-service-principal-identity-design.md.
# Rotation steps: deploy/README.md "Rotating the service-principal secret".
name: SP secret expiry

on:
  schedule:
    - cron: "0 7 * * *"
  workflow_dispatch:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - name: Check DATABRICKS_SP_SECRET_EXPIRES
        env:
          EXPIRES: ${{ vars.DATABRICKS_SP_SECRET_EXPIRES }}
          WARN_DAYS: 7
        run: |
          if ! [[ "$EXPIRES" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! expires_s=$(date -u -d "$EXPIRES" +%s 2>/dev/null); then
            echo "::error::DATABRICKS_SP_SECRET_EXPIRES is missing or not a YYYY-MM-DD date: '$EXPIRES'"
            exit 1
          fi
          today_s=$(date -u -d "$(date -u +%F)" +%s)
          days_left=$(( (expires_s - today_s) / 86400 ))
          if (( days_left <= WARN_DAYS )); then
            echo "::error::Service-principal OAuth secret expires $EXPIRES ($days_left days left). Rotate it: deploy/README.md 'Rotating the service-principal secret'."
            exit 1
          fi
          echo "Secret expires $EXPIRES ($days_left days left)."
```

- [ ] **Step 3: Test the check script locally** (Git Bash has GNU `date`). This covers Review Focus #3 and #4. Save the `run:` body to `$SCRATCH/check.sh` and run:

```bash
for e in "" "garbage" "2026-13-45" "$(date -u -d '+7 days' +%F)" "$(date -u -d '-1 day' +%F)" "$(date -u -d '+8 days' +%F)"; do
  EXPIRES="$e" WARN_DAYS=7 bash $SCRATCH/check.sh >/dev/null 2>&1; echo "'$e' -> exit $?"
done
```

Expected: exit 1 for all except the `+8 days` case, which exits 0.

- [ ] **Step 4: Ask the user to set the repo variable.** It's a date, not a secret, but it's a change to their repo settings: `gh variable set DATABRICKS_SP_SECRET_EXPIRES --body 2026-10-13`. Confirm with `gh variable list`.

- [ ] **Step 5: Commit.**

```bash
git add .github/workflows/
git commit -m "ci: authenticate as the SP via OAuth M2M; add secret-expiry alarm"
```

---

### Task 4: Documentation

**Files:**
- Modify: `docs/deployment-strategy.md`, `deploy/README.md`

- [ ] **Step 1: Update `docs/deployment-strategy.md`.**
  - Insert a new `## Identity` section directly before `## CI/CD`. It contains:
    - one paragraph: SP `meridian-pipeline-runner` (application ID in `databricks.yml`'s `service_principal_id`) is the only identity that deploys (local `meridian-sp` profile, and CI via OAuth M2M) and the only one that runs things (`run_as` on `targets.dev`);
    - the ownership table from the spec's "Ownership model" section;
    - one paragraph on why: creator-becomes-owner, so no manual transfers are needed; nothing depends on a personal PAT; a single bundle state under `/Users/<sp>/.bundle/`;
    - one paragraph on human access: admins inherit `CAN_MANAGE` on the Job and pipelines, and `setup_environment.py --grant-read-to "account users"` grants `USE SCHEMA` + `SELECT`;
    - one paragraph on secret lifetime: short-lived OAuth secrets, the `sp-secret-expiry.yml` alarm, and the runbook location.
  - In "Platform constraints", rewrite the **CI auth** bullet: GitHub Actions authenticates as the SP through `DATABRICKS_HOST`/`DATABRICKS_CLIENT_ID`/`DATABRICKS_CLIENT_SECRET` (OAuth M2M), not a PAT. Point to the Identity section.
  - In the "CLI auth" bullet, note that local deploys use the `meridian-sp` OAuth profile.
  - Add a Decision log row dated 2026-09-29: "Service principal owns and runs everything; migrated by teardown + rebuild", linking the spec.
  - In "Full lifecycle", add `--profile meridian-sp` to the `databricks bundle` lines and prefix every `python` line (setup and teardown alike — the SP owns the schemas) with `DATABRICKS_CONFIG_PROFILE=meridian-sp`.

- [ ] **Step 2: Update `deploy/README.md`.**
  - Replace the "An authenticated CLI profile" prerequisite (the PAT / `databricks configure` text, around lines 48–54) with a `meridian-sp` profile prerequisite. Tell the user to add this to `~/.databrickscfg` themselves:

```ini
[meridian-sp]
host          = https://<workspace>.cloud.databricks.com
client_id     = <service principal application ID>
client_secret = <OAuth secret -- never commit or paste into chat>
```

    Verify it with `databricks current-user me --profile meridian-sp`. It should print `meridian-pipeline-runner`.
  - Add `--profile meridian-sp` to every `databricks bundle …` command in sections 2–4.
  - Prefix every `python scripts/…` command with `DATABRICKS_CONFIG_PROFILE=meridian-sp `. Add a PowerShell equivalent once: `$env:DATABRICKS_CONFIG_PROFILE="meridian-sp"`.
  - Change Step 3's schema line to `python scripts/setup_environment.py --grant-read-to "account users"`.
  - In "Script flags", add `--grant-read-to` to `setup_environment.py`'s Optional column.
  - Change the note on the `[dev <your-username>]` name prefix to `[dev meridian_pipeline_runner]`.
  - Add a new section before "Script flags", `## Rotating the service-principal secret`, with the five steps from the spec's Documentation section. Use exact commands where they exist:
    - `databricks service-principal-secrets-proxy create <sp-numeric-id>` (the user runs this and copies the secret straight into GitHub and `~/.databrickscfg`)
    - `gh variable set DATABRICKS_SP_SECRET_EXPIRES --body <new-expiry>`
    - `gh workflow run deploy.yml`
    - `databricks service-principal-secrets-proxy delete <sp-numeric-id> <old-secret-id>`

- [ ] **Step 3: Check for stale PAT references.**

Run: `grep -rnE "DATABRICKS_TOKEN|personal access token|databricks configure" docs/deployment-strategy.md deploy/README.md .github/`
Expected: no matches. The only exception is an intentional historical mention in a Decision log row.

- [ ] **Step 4: Commit.**

```bash
git add docs/deployment-strategy.md deploy/README.md
git commit -m "docs: service-principal identity, SP CLI profile, secret rotation runbook"
```

---

### Task 5: Push, PR, CI proof

- [ ] **Step 1:** `git push -u origin service-principal-identity`
- [ ] **Step 2:** Open a PR against `main` with a summary, the migration checklist (spec "One-time migration"), and a note that merging must wait for the migration.
- [ ] **Step 3:** Watch `PR checks`: `gh pr checks --watch`. Expected: `test / test` passes. That proves `bundle validate` authenticates through OAuth M2M as the SP. If you get a 401, stop and report it; don't change the secrets.

---

### Task 6: One-time migration (live workspace — confirm with the user before running steps 2–5)

Each step's identity comes from the spec's table. Commands run from `deploy/`.

- [ ] **Step 0: Prerequisite.** The user has created the `meridian-sp` profile. Check with `databricks current-user me --profile meridian-sp -o json | grep displayName`, which should show `meridian-pipeline-runner`.
- [ ] **Step 1 (user identity):** grant schema creation. Run the statement through the SQL Statement Execution API:
  `databricks api post /api/2.0/sql/statements --json '{"warehouse_id":"7652b86e2ae2901c","statement":"GRANT CREATE SCHEMA ON CATALOG workspace TO `d2a8bef0-ed6e-4a46-9dd1-84a527c9eade`","wait_timeout":"30s"}'`
  Verify with `databricks grants get catalog workspace`. It should show `CREATE_SCHEMA` for the SP.
- [ ] **Step 2 (SP):** `databricks bundle destroy -t dev --profile meridian-sp --var="warehouse_id=7652b86e2ae2901c" --auto-approve`
- [ ] **Step 3 (user):** `MSYS_NO_PATHCONV=1 databricks workspace delete --recursive /Users/leandro.lf.frazao2@hotmail.com/.bundle/meridian`
- [ ] **Step 4 (user):** `python scripts/teardown_environment.py --warehouse-id 7652b86e2ae2901c`, then `python scripts/verify_teardown.py`, which should exit 0.
- [ ] **Step 5 (SP):**

```bash
DATABRICKS_CONFIG_PROFILE=meridian-sp python scripts/setup_environment.py --grant-read-to "account users"
databricks bundle deploy -t dev --profile meridian-sp --var="warehouse_id=7652b86e2ae2901c"
databricks bundle run meridian_etl_orchestrator -t dev --profile meridian-sp
```

- [ ] **Step 6: Verify.** All of these should show the SP (`d2a8bef0-…`):
  - `databricks schemas get workspace.meridian_<layer>` → `owner`, for each layer
  - `databricks tables list workspace meridian_<layer>` → every table's `owner`
  - `databricks jobs get <id>` → `run_as_user_name`
  - `databricks permissions get jobs <id>` / `pipelines <id>` → `IS_OWNER`
  - `databricks pipelines get <id>` → `run_as_user_name`

  Then, as the user (DEFAULT profile), `SELECT COUNT(*) FROM workspace.meridian_gold.participant_day` through the statements API. Expected: a non-zero count, which proves the grant works.
- [ ] **Step 7:** Merge the PR after the user approves. Watch the Deploy run with `gh run watch`. Expected: green, with no resource changes.
- [ ] **Step 8 (user):** Delete the `DATABRICKS_TOKEN` GitHub secret (`gh secret delete DATABRICKS_TOKEN`) and revoke the PAT in the workspace UI. Confirm with the user before running the `gh` command.
