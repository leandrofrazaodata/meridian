# Transformations

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

**Silver is done.** `transformations/silver/` has one `.sql` file per
`contracts/*.yml` source — `participants`, `heart_rate`,
`device_metadata`, `wellness_survey`, `steps`, `sleep` — each defining a
`<entity>_prepared` / `<entity>` / `quarantine_<entity>` set of
materialized views (`sleep` adds a fourth, `sleep_stages`, at a
different grain — one row per stage, not per night). Design rationale, the resolved `stuck_sensor` run-length
threshold (15 minutes), and the mapping from the contracts' `on_fail`
vocabulary onto Lakeflow's native `EXPECT` constraints are all written up
in `docs/superpowers/specs/2026-09-22-silver-transformations-design.md`
— read that before changing any file here. Nothing has been deployed or
run against a live workspace yet (see `deploy/README.md`'s "Current
status") — these files are written and committed, not executed.

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
