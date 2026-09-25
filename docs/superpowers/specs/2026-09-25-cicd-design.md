# CI/CD — Design

This is the second half of the original two-part deploy-layer request
(`docs/superpowers/specs/2026-09-24-pipeline-split-design.md`'s intro:
"the second, a CI/CD pipeline for auto-redeploy on merge to main, is
a separate, independent subsystem and gets its own brainstorm → spec
→ plan cycle"). The pipeline split (PR #6) is merged; this covers the
CI/CD piece that was deliberately deferred out of it.

Scope, confirmed directly with the user across four questions this
session:

1. On merge to `main`, re-deploy the Job + both Pipelines
   (`databricks bundle deploy`) so they stay in sync with
   `deploy/resources/*.yml` and `transformations/**`. This does **not**
   run the data pipelines themselves (`databricks bundle run`) — deploy
   only, matching the user's own framing ("re-deploy everything to keep
   the pipelines/jobs updated").
2. Run tests to catch breakage. The only test surface that exists is
   `deploy/scripts/`'s pytest suite (`CLAUDE.md`); `databricks bundle
   validate` (read-only, per `deploy/README.md` step 2) is added
   alongside it as a second, equally cheap check.
3. Tests gate pull requests ("for PR we test, if ok we proceed to
   merge"); deploy happens after merge, re-running the same tests first
   as a safety gate rather than trusting the PR check alone.
4. The deploy trigger is path-filtered to `deploy/**` and
   `transformations/**` — a merge that touches neither doesn't deploy.

Grounded directly against the real repo this session: `deploy/databricks.yml`
(no `workspace.host` under `targets.dev` — auth is local-CLI-profile-based
today, no default `warehouse_id`), `deploy/scripts/requirements.txt` (no
Python version pinned anywhere in the repo), `deploy/README.md`'s exact
deploy commands, and `docs/deployment-strategy.md`'s Platform Constraints
and Deferred/open sections (both contain notes this design makes stale —
see "Doc updates this closes out" below).

## Design

### Platform: GitHub Actions

Uncontested — the repo is already hosted and worked on GitHub (`gh` CLI
used for PRs #3–#6), so this needs no separate evaluation against other
CI platforms.

### Trigger model: PR-gated tests, path-filtered deploy-on-merge

Two trigger points, not one:

- **`pull_request` targeting `main`** — runs tests on every PR,
  regardless of what files it touches. This is the merge gate: red
  here should block merging (see "Branch protection" below for what
  actually enforces that).
- **`push` to `main`, filtered to `deploy/**` and `transformations/**`**
  — re-runs the same tests, then deploys. A merge that touches neither
  path (e.g. a `data/data_dictionary.md` fix) triggers nothing.

Re-running tests on the deploy trigger is intentionally redundant with
the PR gate. The cost is negligible — the pytest suite is small and
fully mocked, no workspace contact — and it buys a real guarantee:
nothing reaches `bundle deploy` without a green test run at the exact
commit being deployed, regardless of whether that commit arrived via a
reviewed PR, a direct push, or a squash-merge combining several PRs.

### Avoiding duplication: a reusable workflow

Writing the same steps (checkout, install, pytest, validate) twice
across two workflow files is the kind of duplication this project's own
planning conventions rule out (`writing-plans`'s DRY principle). GitHub
Actions' `workflow_call` trigger exists for exactly this: one workflow
file holds the test steps, two thin trigger files call it.

### File layout

```
.github/workflows/
  run-tests.yml    # reusable (workflow_call) — pytest + bundle validate
  pr-checks.yml    # on: pull_request → calls run-tests.yml
  deploy.yml       # on: push (path-filtered) + workflow_dispatch → calls
                    # run-tests.yml, then deploys
```

**`run-tests.yml`** (`on: workflow_call`): checkout → `actions/setup-python@v5`
pinned to `3.11` (nothing in the repo pins a Python version today; 3.11
is a plain, current, widely-available default, picked rather than
discovered — flagged here as an arbitrary but reasonable choice, not a
finding) → `pip install -r deploy/scripts/requirements.txt` → `pytest -v`
run from `deploy/scripts/` → `databricks/setup-cli@main` (the CLI
install action published by Databricks; matches this repo's existing
"don't pin tightly" style — `requirements.txt` itself uses `>=`, not
`==`) → `databricks bundle validate -t dev
--var="warehouse_id=${{ vars.DATABRICKS_WAREHOUSE_ID }}"` run from
`deploy/`, with `DATABRICKS_HOST`/`DATABRICKS_TOKEN` set as step-level
env vars.

**`pr-checks.yml`**: `on: pull_request, branches: [main]`. One job,
`uses: ./.github/workflows/run-tests.yml`.

**`deploy.yml`**: `on: push, branches: [main], paths: [deploy/**,
transformations/**]`, plus `workflow_dispatch` (manual re-run without
needing a dummy commit — cheap to add, useful when a deploy fails for a
transient reason and needs retrying without new changes). Job 1 (`test`)
calls `run-tests.yml`. Job 2 (`deploy`, `needs: test`): checkout,
`databricks/setup-cli@main`, `databricks bundle deploy -t dev
--var="warehouse_id=..."` from `deploy/`, same `DATABRICKS_HOST`/
`DATABRICKS_TOKEN` env vars.

### Authentication: PAT via GitHub Actions secrets

Confirmed directly with the user (first clarifying question, two
options presented — PAT vs. OIDC/service-principal). PAT wins: it's the
same credential type `deploy/README.md` already has the user generate
and use locally (`databricks configure` + a personal access token), so
CI reuses a concept that already exists in this project rather than
introducing OIDC federation for a single-developer repo.

Mechanically, the Databricks CLI and `bundle` commands read
`DATABRICKS_HOST`/`DATABRICKS_TOKEN` from the environment directly —
this needs no `databricks configure` step and no change to
`databricks.yml` (whose `targets.dev` deliberately has no
`workspace.host`, per its own comment, so that local `databricks
configure` keeps working unchanged; the CI path adds a second,
independent way to authenticate the same target without touching that
file).

**Required GitHub repo configuration (user-provisioned — this is a live
credential, so it isn't something to hand over in chat or for me to set
via API):**

| Name | Kind | Value |
|---|---|---|
| `DATABRICKS_HOST` | secret | same value used in local `databricks configure` |
| `DATABRICKS_TOKEN` | secret | a personal access token for the workspace |
| `DATABRICKS_WAREHOUSE_ID` | variable (not secret — `deploy/README.md` already shows this value in plaintext example output) | from `databricks warehouses list` |

Set via GitHub's UI (Settings → Secrets and variables → Actions) or
`gh secret set` / `gh variable set` run by the user directly.

**Flagged, not assumed:** `docs/deployment-strategy.md`'s Platform
Constraints section notes CLI auth on Free Edition "only reliably works
from a local machine" — but that note is specifically about the
workspace's own built-in browser terminal, a different context from a
GitHub-hosted runner authenticating via `DATABRICKS_HOST`/
`DATABRICKS_TOKEN` env vars (the standard non-interactive method
Databricks documents generally for CI). Very likely fine, but Free
Edition has already surprised this project once on exactly this kind of
assumption, so this is verify-on-first-real-run, not guessed at — same
treatment as the Bronze `timestamp` physical-type risk and the Gold
column-`COMMENT` syntax risk in earlier specs.

### Operational behavior

- **No auto-rollback.** A failed test, validate, or deploy step just
  shows red in the Actions tab. Recovery is fixing forward — the next
  successful merge (or a manual `workflow_dispatch` re-run) corrects
  state. This matches "simple," and the project has no staging
  environment to roll back through regardless (`deploy/README.md`:
  "Only one bundle target exists, `dev`").
- **Branch protection is a separate, manual step, not part of these
  files.** `pr-checks.yml` reports a status check; it doesn't by itself
  block a merge. Turning it into a real gate means enabling "Require
  status checks to pass before merging" on `main` in the repo's branch
  protection settings. **Check name caveat:** for a job that calls a
  reusable workflow, GitHub names the resulting check
  `<caller-job-id> / <called-job-id>`, not the called workflow's
  filename — here that's predicted to be `test / test`
  (`pr-checks.yml`'s job id calling `run-tests.yml`'s job id, neither
  given an explicit `name:`), not `run-tests`. Read the actual name off
  the first real PR run before creating the branch-protection rule
  rather than trusting this prediction — same unverified-until-live-run
  treatment as the Bronze `timestamp` physical-type risk and the Gold
  column-`COMMENT` syntax risk in earlier specs. Recommended, but it's a
  GitHub repo setting outside what a workflow file can configure — it's
  flagged here rather than silently assumed enabled, and not applied
  automatically as part of this design (an outward-facing, persistent
  change to how every future merge behaves, worth the user's explicit
  say-so rather than a side effect of a CI file's existence).

### Doc updates this closes out

`docs/deployment-strategy.md` has two spots that go stale once this
ships:

- **"Deferred / open"** currently reads: "Git/CI — this workflow is
  entirely CLI-driven and doesn't depend on git existing (the repo
  currently isn't a git repo). Revisit if that changes." This was
  already noted as stale in the pipeline-split spec (the repo's been a
  git repo since PR #1) and explicitly deferred to this design. Once
  CI/CD ships, the workflow is no longer entirely CLI-driven — the
  bullet should be removed and, if useful, replaced with a one-line
  pointer at this doc/spec instead.
- **Platform Constraints' CLI-auth bullet** should gain a note that
  GitHub Actions authenticates via `DATABRICKS_HOST`/`DATABRICKS_TOKEN`
  env vars rather than a local CLI profile, and (once verified per the
  flag above) whether that path works cleanly on Free Edition.

## What's deliberately out of scope

- **Running the data pipelines from CI** (`databricks bundle run`) —
  explicitly excluded per the user's own framing; this design redeploys
  resource *definitions*, not data.
- **A staging/second bundle target or environment promotion** — only
  `dev` exists (`deploy/databricks.yml`); introducing a second target
  is a bigger, unrequested design question, not a natural extension of
  "redeploy on merge."
- **Automating `bundle destroy`/teardown in CI** — teardown in this
  project is a deliberate, manual, occasional action
  (`deploy/scripts/teardown_environment.py`), not something that should
  ever fire from a merge.
- **Configuring branch protection itself** — see "Operational behavior"
  above; recommended, not included as an automated step.
- **Notifications (Slack/email) on failure** — not requested; GitHub's
  own Actions UI/email-on-failure defaults are sufficient for a
  solo/small-team repo. YAGNI.

## Known, flagged limitations

- **Free Edition CI auth is unverified until the first real workflow
  run** — see "Authentication" above. If it turns out `DATABRICKS_HOST`/
  `DATABRICKS_TOKEN` env-var auth doesn't work cleanly on Free Edition
  from a hosted runner, the fallback is investigating whatever
  Databricks' current recommended non-interactive auth path is at that
  time — not guessed at now.
- **Test duplication between the PR check and the deploy check is
  accepted, not eliminated.** The reusable workflow removes *file*
  duplication (the steps are written once); it doesn't remove the
  *execution* duplication (a deploy-triggering merge runs the test job
  twice — once via each trigger's own `run-tests.yml` call). This is a
  deliberate tradeoff (see "Trigger model" above), not an oversight.
- **The PR gate is advisory without branch protection.** Until that
  repo setting is turned on, `pr-checks.yml` going red is visible but
  doesn't stop a merge.
