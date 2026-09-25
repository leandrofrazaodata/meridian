# meridian

A synthetic health/wearables data engineering pipeline built on
Databricks (Free Edition) — medallion architecture (Bronze → Silver →
Gold), deployed as a Databricks Asset Bundle, with GitHub Actions
handling tests and redeploys.

## What this is

50 synthetic participants (`P001`–`P050`) wear a Fitbit for a 28-day
study (`2026-01-08` → `2026-02-04`). Raw CSV/JSON lands in a Unity
Catalog volume and flows through Bronze (raw Delta tables) → Silver
(conformed, validated entities) → Gold (business-facing, denormalized
tables built for dashboards, reports, and ad hoc/AI-tool querying, not
just downstream engineering).

## Status

All three pipeline layers are live on `main`, along with a set of
analytical queries against Gold and a GitHub Actions CI/CD setup (tests
gate every PR, merges to `main` redeploy the Job + Pipelines). See each
area's own docs (below) for current detail — this file won't try to
stay in sync with them.

## Repository layout

```
data/                   Source dataset + data dictionary (see below)
contracts/               Per-source data contracts (schema, natural key, quality rules) — contracts/README.md
transformations/
  silver/                 Lakeflow pipeline source: Bronze -> Silver
  gold/                   Lakeflow pipeline source: Silver -> Gold
  README.md                Layout + current status of both
analysis/                Standalone analytical SQL against Gold — analysis/README.md
deploy/                   Databricks Asset Bundle + Unity Catalog lifecycle scripts — deploy/README.md
docs/                     Architecture, conventions, validation rules, deployment strategy (see below)
.github/workflows/        CI/CD — test gate on PRs, redeploy on merge to main
```

## Documentation map

| Doc | Covers |
|---|---|
| `docs/pipeline-architecture.md` | Stages, data flow, storage layers, how components connect |
| `docs/gold-layer.md` | Gold table purpose, grain, and consumption guidance for dashboards/reports |
| `docs/validation-rules.md` | What "valid" means per dataset/stage |
| `docs/conventions.md` | Naming, coding patterns, style rules |
| `docs/deployment-strategy.md` | How Databricks objects (schemas, job, pipeline) get created and destroyed |
| `contracts/README.md` | Data contract format, one YAML file per Bronze source |
| `data/data_dictionary.md` | Source dataset schema, join keys, known data-quality quirks |
| `transformations/README.md` | Silver/Gold pipeline source layout and status |
| `analysis/README.md` | What each analytical query answers and what it reads |
| `deploy/README.md` | Step-by-step: prerequisites, tests, validate, deploy, teardown |

## Running it

Full step-by-step (prerequisites, tests, `bundle validate`, standing
the environment up, tearing it down) lives in `deploy/README.md` — the
short version, run from `deploy/`:

```bash
cd scripts && pytest -v && cd ..                                            # unit tests (mocked)
databricks bundle validate -t dev --var="warehouse_id=<warehouse-id>"       # read-only check
python scripts/setup_environment.py                                        # create schemas
databricks bundle deploy -t dev --var="warehouse_id=<warehouse-id>"        # deploy Job + Pipelines
databricks bundle run meridian_etl_orchestrator -t dev                     # run it
```

## CI/CD

`.github/workflows/` runs the same test suite (`pytest` +
`databricks bundle validate`) on every pull request to `main`, and
again — then a real `databricks bundle deploy` — on every merge to
`main` that touches `deploy/**` or `transformations/**`. Design
rationale: `docs/superpowers/specs/2026-09-25-cicd-design.md`.

## AI Usage

This project was built through AI pair-programming with
[Claude Code](https://claude.com/claude-code) — every layer (deploy
scripts, Silver, Gold, the pipeline split, analysis queries, CI/CD)
went through a design → plan → implementation → review cycle before
merging, not just generated ad hoc.

- **Models:** primarily Claude Sonnet 5, with Claude Haiku 4.5 handling
  smaller, mechanical implementation tasks — both attributed via
  `Co-Authored-By` trailers throughout the commit history.
- **Where:** deploy bundle + Unity Catalog lifecycle scripts, Silver
  transformations, Gold transformations, a post-live-run Silver
  hotfix, analytics queries, the Silver/Gold pipeline split, and this
  CI/CD setup — 7 pull requests total.
- **Time:** ~4 active days (2026-09-22 → 2026-09-25), per commit
  history — not separately time-tracked beyond that.
