# Transformations

This directory will hold the Lakeflow Declarative Pipeline source (SQL
files, one materialized view per Silver/Gold table) that
`deploy/resources/pipelines.yml`'s `meridian_pipeline` resource points
at via `libraries.glob.include`.

It's intentionally empty except for this file. Writing the actual
Silver/Gold transformation logic is a separate, not-yet-designed piece
of work from the deployment machinery in `deploy/` — see
`docs/superpowers/plans/2026-09-22-deploy-bundle-and-lifecycle-scripts.md`'s
"Deferred / not in this plan" section for why, and
`docs/pipeline-architecture.md` for what these tables are meant to
contain. Two concrete open questions block a complete first pass:

- `participant_week`'s exact Gold schema — marked "TBD together" in
  `docs/pipeline-architecture.md`.
- The `stuck_sensor` run-length threshold in `contracts/heart_rate.yml`
  — deliberately left open there.

Needs its own brainstorm → spec → plan cycle before any `.sql` file
lands here.
