# CI/CD (GitHub Actions) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub Actions workflows that gate pull requests with the
existing test suite plus a bundle validate, and automatically redeploy
the Job and both Pipelines on merge to `main` when deploy-relevant files
changed — without ever running the data pipelines themselves.

**Architecture:** Three workflow files under `.github/workflows/`: one
reusable (`run-tests.yml` — pytest + `bundle validate`), called by both a
PR-triggered wrapper (`pr-checks.yml`) and a main-push-triggered wrapper
that also deploys (`deploy.yml`). Two doc updates close out a stale
cross-reference and point readers at the new automation.

**Tech Stack:** GitHub Actions (`workflow_call` reusable workflows,
`actions/checkout@v4`, `actions/setup-python@v5`,
`databricks/setup-cli@main`), the existing `deploy/scripts` pytest suite,
Databricks CLI (`bundle validate` / `bundle deploy`).

**Spec:** `docs/superpowers/specs/2026-09-25-cicd-design.md`

## Global Constraints

- No real GitHub Actions execution as part of this plan — writing and
  committing the workflow YAML and doc files is in scope; actually
  opening a PR or merging to trigger them for real happens only when the
  user explicitly says go, per this project's standing rule for anything
  that touches the live Databricks workspace or its CI.
- Python version for CI is `3.11`, pinned identically in every
  `setup-python` step — nothing in the repo pins a version today, so
  this is one deliberate, consistent choice, not a per-file guess.
- Every `databricks` CLI invocation (`validate`/`deploy`) runs with
  `working-directory: deploy` and passes
  `--var="warehouse_id=${{ vars.DATABRICKS_WAREHOUSE_ID }}"` —
  `deploy/databricks.yml`'s `warehouse_id` variable has no default.
- Every step needing Databricks auth sets `DATABRICKS_HOST` /
  `DATABRICKS_TOKEN` from `secrets.*` at that step's `env:` — never
  `databricks configure`, never a token committed anywhere.
- Reusable-workflow calls use `secrets: inherit` (not per-secret
  mapping) — confirmed this makes the caller's secrets available inside
  the called workflow without listing them in `run-tests.yml`'s own
  `on.workflow_call` block; repo variables (`vars.*`) are available the
  same way, with no passing needed at all.
- **YAML gotcha to know before writing any verification command below:**
  PyYAML (and YAML 1.1 generally) parses a bare `on:` key as the
  *boolean* `True`, not the string `"on"` — every verification snippet
  below checks `d.get('on', d.get(True))` to handle this.

---

### Task 1: `run-tests.yml` (reusable test workflow)

**Files:**
- Create: `.github/workflows/run-tests.yml`

**Interfaces:**
- Produces: a `workflow_call`-triggered workflow with one job named
  `test`. Tasks 2 and 3 reference it as
  `uses: ./.github/workflows/run-tests.yml` with `secrets: inherit`.

- [ ] **Step 1: Write the workflow file**

```yaml
# Reusable workflow: pytest (deploy/scripts) + a read-only bundle
# validate. Called by pr-checks.yml (every PR) and deploy.yml (re-run
# as a safety gate immediately before deploying). See
# docs/superpowers/specs/2026-09-25-cicd-design.md for the design.
name: Run tests

on:
  workflow_call:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Install test dependencies
        run: pip install -r deploy/scripts/requirements.txt

      - name: Run pytest
        working-directory: deploy/scripts
        run: pytest -v

      - uses: databricks/setup-cli@main

      - name: Validate bundle
        working-directory: deploy
        env:
          DATABRICKS_HOST: ${{ secrets.DATABRICKS_HOST }}
          DATABRICKS_TOKEN: ${{ secrets.DATABRICKS_TOKEN }}
        run: databricks bundle validate -t dev --var="warehouse_id=${{ vars.DATABRICKS_WAREHOUSE_ID }}"
```

- [ ] **Step 2: Verify it's valid YAML**

Run (installs a throwaway local dependency for this check only — not
added to `deploy/scripts/requirements.txt`, since no project code
imports `yaml`):

```bash
pip install pyyaml -q
python -c "
import yaml
d = yaml.safe_load(open('.github/workflows/run-tests.yml'))
print('OK: parses as valid YAML')
"
```

Expected: `OK: parses as valid YAML`.

- [ ] **Step 3: Verify the trigger shape mechanically**

```bash
python -c "
import yaml
d = yaml.safe_load(open('.github/workflows/run-tests.yml'))
triggers = d.get('on', d.get(True))
assert triggers is not None, 'no trigger key found'
assert 'workflow_call' in triggers, 'missing workflow_call trigger'
assert 'push' not in triggers and 'pull_request' not in triggers, \
    'run-tests.yml must only be callable, never trigger directly'
assert 'test' in d['jobs'], 'missing test job'
print('OK: workflow_call-only trigger, test job present')
"
```

Expected: `OK: workflow_call-only trigger, test job present`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/run-tests.yml
git commit -m "ci: add reusable test workflow (pytest + bundle validate)"
```

---

### Task 2: `pr-checks.yml`

**Files:**
- Create: `.github/workflows/pr-checks.yml`

**Interfaces:**
- Consumes: `.github/workflows/run-tests.yml` (Task 1), called by
  relative path.

- [ ] **Step 1: Write the workflow file**

```yaml
# Gates pull requests targeting main with the reusable test workflow.
# Only a merge-blocker if branch protection on main requires this
# check to pass — see docs/superpowers/specs/2026-09-25-cicd-design.md
# "Operational behavior".
name: PR checks

on:
  pull_request:
    branches: [main]

jobs:
  test:
    uses: ./.github/workflows/run-tests.yml
    secrets: inherit
```

- [ ] **Step 2: Verify it's valid YAML**

```bash
python -c "
import yaml
d = yaml.safe_load(open('.github/workflows/pr-checks.yml'))
print('OK: parses as valid YAML')
"
```

Expected: `OK: parses as valid YAML`.

- [ ] **Step 3: Verify trigger and reusable-call shape**

```bash
python -c "
import yaml
d = yaml.safe_load(open('.github/workflows/pr-checks.yml'))
triggers = d.get('on', d.get(True))
assert triggers['pull_request']['branches'] == ['main']
job = d['jobs']['test']
assert job['uses'] == './.github/workflows/run-tests.yml'
assert job['secrets'] == 'inherit'
print('OK: pull_request->main trigger, calls run-tests.yml with secrets: inherit')
"
```

Expected: `OK: pull_request->main trigger, calls run-tests.yml with secrets: inherit`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/pr-checks.yml
git commit -m "ci: add PR checks workflow"
```

---

### Task 3: `deploy.yml`

**Files:**
- Create: `.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: `.github/workflows/run-tests.yml` (Task 1), called by
  relative path.

- [ ] **Step 1: Write the workflow file**

```yaml
# Redeploys the Job + both Pipelines on merge to main, when
# deploy-relevant files changed. Re-runs the reusable test workflow
# first as a safety gate, even though the merging PR already ran it —
# see docs/superpowers/specs/2026-09-25-cicd-design.md "Trigger model"
# for why that redundancy is deliberate. Never runs the data pipelines
# themselves (no `databricks bundle run` anywhere in this file).
name: Deploy

on:
  push:
    branches: [main]
    paths:
      - 'deploy/**'
      - 'transformations/**'
  workflow_dispatch:

jobs:
  test:
    uses: ./.github/workflows/run-tests.yml
    secrets: inherit

  deploy:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: databricks/setup-cli@main

      - name: Deploy bundle
        working-directory: deploy
        env:
          DATABRICKS_HOST: ${{ secrets.DATABRICKS_HOST }}
          DATABRICKS_TOKEN: ${{ secrets.DATABRICKS_TOKEN }}
        run: databricks bundle deploy -t dev --var="warehouse_id=${{ vars.DATABRICKS_WAREHOUSE_ID }}"
```

- [ ] **Step 2: Verify it's valid YAML**

```bash
python -c "
import yaml
d = yaml.safe_load(open('.github/workflows/deploy.yml'))
print('OK: parses as valid YAML')
"
```

Expected: `OK: parses as valid YAML`.

- [ ] **Step 3: Verify trigger, path filter, and job graph**

```bash
python -c "
import yaml
d = yaml.safe_load(open('.github/workflows/deploy.yml'))
triggers = d.get('on', d.get(True))
assert triggers['push']['branches'] == ['main']
assert set(triggers['push']['paths']) == {'deploy/**', 'transformations/**'}
assert 'workflow_dispatch' in triggers
test_job = d['jobs']['test']
assert test_job['uses'] == './.github/workflows/run-tests.yml'
assert test_job['secrets'] == 'inherit'
deploy_job = d['jobs']['deploy']
assert deploy_job['needs'] == 'test'
run_step = [s for s in deploy_job['steps'] if 'run' in s]
assert any('databricks bundle deploy' in s['run'] for s in run_step)
assert 'bundle run' not in str(deploy_job), 'must never run the data pipelines'
print('OK: push->main path-filtered + workflow_dispatch, test->deploy job graph, no bundle run')
"
```

Expected: `OK: push->main path-filtered + workflow_dispatch, test->deploy job graph, no bundle run`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "ci: add deploy workflow (path-filtered, redeploy-on-merge)"
```

---

### Task 4: Doc updates

**Files:**
- Modify: `docs/deployment-strategy.md`
- Modify: `deploy/README.md`

**Interfaces:**
- Consumes: file paths from Tasks 1–3 (`.github/workflows/*.yml`) and
  `docs/superpowers/specs/2026-09-25-cicd-design.md`, referenced by path
  in the doc text below — no code interface.

- [ ] **Step 1: Add a `## CI/CD` section to `docs/deployment-strategy.md`**

Insert a new section after `## Directory layout` (i.e. immediately
before the existing `## Platform constraints affecting this design`
heading):

```markdown
## CI/CD

GitHub Actions keeps the Job/Pipelines in sync with `deploy/` and
`transformations/` automatically — every pull request runs the
`deploy/scripts` pytest suite plus a read-only `bundle validate`; every
merge to `main` that touches `deploy/**` or `transformations/**`
re-runs both, then `databricks bundle deploy`. It never runs the data
pipelines themselves (`bundle run`) and never touches schemas —
`setup_environment.py`/`teardown_environment.py` stay manual, same as
today. Full design: `docs/superpowers/specs/2026-09-25-cicd-design.md`;
workflow files: `.github/workflows/`.

```

- [ ] **Step 2: Extend the Platform Constraints CLI-auth bullet**

In `## Platform constraints affecting this design`, the existing first
bullet is:

```markdown
- **CLI auth on Free Edition only reliably works from a local machine**
  (PAT via `databricks configure`) — deploying from inside the workspace UI
  has open reports of failing. Verify directly against the workspace before
  relying on either path, the same rule the rest of the Platform
  Constraints section already follows.
```

Add a new bullet directly after it:

```markdown
- **CI auth is a third, separate path from both of the above** —
  GitHub Actions authenticates via `DATABRICKS_HOST`/`DATABRICKS_TOKEN`
  environment variables (no `databricks configure`, no browser terminal
  involved), which is Databricks' standard non-interactive method
  generally, but hasn't been confirmed working specifically on Free
  Edition from a hosted runner yet. Unverified until the first real CI
  run — see `docs/superpowers/specs/2026-09-25-cicd-design.md`.
```

- [ ] **Step 3: Remove the stale Git/CI bullet from `## Deferred / open`**

Delete this bullet (now stale — the repo has been a git repo since PR
#1, and CI/CD is no longer undecided as of this plan):

```markdown
- Git/CI — this workflow is entirely CLI-driven and doesn't depend on git
  existing (the repo currently isn't a git repo). Revisit if that changes.
```

Leave the other two bullets in that section untouched.

- [ ] **Step 4: Add one bullet to `deploy/README.md`'s `## Notes` section**

Append after the existing "Full design rationale and decision log"
bullet:

```markdown
- Merges to `main` that touch `deploy/**` or `transformations/**` also
  trigger an automatic `bundle deploy` via GitHub Actions
  (`.github/workflows/deploy.yml`) — the manual Step 3 commands above
  still work the same way for a first-time or ad hoc deploy; the
  automation just keeps things in sync afterward. See
  `docs/superpowers/specs/2026-09-25-cicd-design.md`.
```

- [ ] **Step 5: Verify the stale reference is gone and the new content is present**

```bash
grep -n "isn't a git repo" docs/deployment-strategy.md; echo "exit: $?"
grep -n "CI/CD" docs/deployment-strategy.md
grep -n "workflows/deploy.yml" deploy/README.md
```

Expected: the first command prints nothing and `exit: 1` (no match —
confirms the stale line is gone); the second and third each print at
least one matching line.

- [ ] **Step 6: Commit**

```bash
git add docs/deployment-strategy.md deploy/README.md
git commit -m "docs: document CI/CD in deployment-strategy and deploy README"
```

---

## Verification

No GitHub Actions runtime to execute these workflows against locally,
and per this plan's Global Constraints nothing gets pushed/PR'd for
real as part of this plan — so verification here is the YAML-parses-
and-shape-matches-spec discipline used in each task's own steps, plus:

1. **Cross-file consistency check** — confirm all three workflow files
   agree on secret/variable names (`DATABRICKS_HOST`, `DATABRICKS_TOKEN`,
   `DATABRICKS_WAREHOUSE_ID`) and the Python version (`3.11`); nothing
   enforces this mechanically across files, so it's a by-eye check once
   all three exist.
2. **Spec coverage** — every decision in
   `docs/superpowers/specs/2026-09-25-cicd-design.md`'s Design section
   (platform, trigger model, auth, file layout/reusable workflow,
   secrets/variables, operational behavior, doc updates) is reflected in
   Tasks 1–4.
3. **Real end-to-end verification is explicitly deferred**, not part of
   this plan's execution — next time the user says go:
   - Set the three GitHub secrets/variables (`DATABRICKS_HOST`,
     `DATABRICKS_TOKEN` as secrets; `DATABRICKS_WAREHOUSE_ID` as a
     variable) — user-provisioned, not something this plan can do.
   - Open a real PR touching `deploy/` or `transformations/` and confirm
     `pr-checks.yml` runs and goes green.
   - Merge it and confirm `deploy.yml` triggers, re-runs tests, and
     `bundle deploy` succeeds — this is also the first real test of
     whether Free Edition accepts `DATABRICKS_HOST`/`DATABRICKS_TOKEN`
     env-var auth from a GitHub-hosted runner (flagged unverified in the
     spec).
   - Separately, and not part of any workflow file: turn on branch
     protection on `main` requiring the reusable-workflow check GitHub
     actually reports — predicted `test / test`
     (`<caller-job-id> / <called-job-id>`, not the literal name
     `run-tests`), but verify against the first real PR run before
     creating the rule rather than trusting this prediction — if the PR
     gate should actually block merges rather than just report status
     (spec's "Operational behavior" section — a manual repo setting,
     deliberately not automated here).
