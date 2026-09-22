# Transformations

This directory holds the Lakeflow Declarative Pipeline source (SQL
files, one materialized view per Silver/Gold table) that
`deploy/resources/pipelines.yml`'s `meridian_pipeline` resource points
at via `libraries.glob.include`.

## Current status

**Silver is done.** One `.sql` file per `contracts/*.yml` source —
`participants`, `heart_rate`, `device_metadata`, `wellness_survey`,
`steps`, `sleep` — each defining a `<entity>_prepared` / `<entity>` /
`quarantine_<entity>` set of materialized views (`sleep` adds a fourth,
`sleep_stages`, at a different grain — one row per stage, not per
night). Design rationale, the resolved `stuck_sensor` run-length
threshold (15 minutes), and the mapping from the contracts' `on_fail`
vocabulary onto Lakeflow's native `EXPECT` constraints are all written up
in `docs/superpowers/specs/2026-09-22-silver-transformations-design.md`
— read that before changing any file here. Nothing has been deployed or
run against a live workspace yet (see `deploy/README.md`'s "Current
status") — these files are written and committed, not executed.

**Gold is not started.** `participant_day`, `participant_week`, and
`participant_study_summary` (`docs/pipeline-architecture.md`) still need
their own brainstorm → spec → plan cycle, same as Silver went through.
`participant_week`'s exact schema remains an open "TBD together"
question, not resolved by this pass.
