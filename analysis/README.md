# Analysis

Standalone analytical SQL queries against the Gold layer
(`workspace.meridian_gold`) — the "analytical query output" deliverable,
distinct from `transformations/`. These aren't pipeline source: nothing
here is picked up by `deploy/resources/pipelines.yml`'s
`libraries.glob.include`, so table references are hardcoded to
`workspace.meridian_gold.<table>` rather than `${schema_prefix}`-templated
like `transformations/*.sql`. Run them directly against a deployed
workspace (SQL editor, `databricks sql query`, etc.) once the Gold tables
are populated — see `deploy/README.md`.

Each file is a single, self-contained query answering one question, with
a header comment stating the question, which Gold table(s) it reads, and
its result grain. Column names and semantics come from `docs/gold-layer.md`
— read that first if a query's choice of column looks unfamiliar.

| File | Question | Reads | Grain |
|---|---|---|---|
| `chronotype_comparison.sql` | How do chronotype A and B cohorts compare across sleep, wellness, activity, and heart-rate metrics? | `participant_study_summary` | 1 row per chronotype (2 rows) |
| `weekly_trend.sql` | Do sleep quality, readiness, fatigue, or activity drift over the 4-week study? | `participant_week` | 1 row per study week (4 rows) |
| `activity_sleep_relationship.sql` | Does a day's activity level relate to that night's sleep efficiency and next-day readiness? | `participant_day` | 1 row per activity tercile (3 rows) |
| `data_quality_coverage.sql` | How much heart-rate coverage does the pipeline actually have, and is it lopsided across chronotypes? | `participant_day` | 1 overall row + 1 row per chronotype (3 rows) |

## Why these four

Picked to demonstrate range, not just repeat the same shape three times:
`chronotype_comparison` and `weekly_trend` are straight reshapes of an
already-aggregated Gold table (`participant_study_summary` /
`participant_week`) — the simplest kind of consumer query. `activity_sleep_relationship`
is a cross-metric question (activity vs. sleep vs. next-day readiness) that
needs bucketing (`NTILE`) rather than a plain `GROUP BY` on an existing
column. `data_quality_coverage` queries `is_provisional` itself — a
pipeline-native data-quality signal, not a health metric — as a reminder
that Gold's own quality signals are queryable the same way as any other
column, per `docs/gold-layer.md`.
