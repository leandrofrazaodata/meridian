# Conventions

## Unity Catalog naming

Single catalog (`workspace` — the only one Free Edition provides), three
schemas, one per medallion layer:

- `workspace.meridian_bronze`
- `workspace.meridian_silver`
- `workspace.meridian_gold`

## Table naming

The schema already conveys the layer, so table names don't repeat it —
`meridian_bronze.participants`, not `meridian_bronze.bronze_participants`.

- **Bronze**: one table per source contract, named after the source
  (`participants`, `device_metadata`, `wellness_survey`, `heart_rate`,
  `steps`, `sleep`).
- **Silver**: named after the conformed entity, not necessarily 1:1 with
  Bronze (e.g. `sleep.json` → both `sleep_sessions` and `sleep_stages` in
  Silver, since they're different grains — one row per night vs. one row
  per stage).
- **Quarantine tables** live in `meridian_silver`, next to the table they
  quarantine from, named `quarantine_<entity>` (e.g. `quarantine_wellness`)
  — see `validation-rules.md` for when a rule quarantines vs. flags.
- **Gold**: named after grain + subject (`participant_day`,
  `participant_week`, `participant_study_summary`), not after the
  consuming team — Gold is grain-oriented, not team-oriented, even though
  specific tables happen to primarily serve one team.

## Ingestion metadata columns

Every Bronze table carries:

- `_source_file` — path of the file the row came from
- `_ingested_at` — the pipeline run date, taken from a **job parameter**,
  never `current_date()`. Reprocessing a given date must be deterministic.
- `_pid_from_path` — for per-participant JSON sources, the participant ID
  extracted via regex from the file path (Unity Catalog doesn't support
  `input_file_name()`). Silver checks this against the row's own
  `participant_id` field rather than trusting either alone.

## Data contracts

One YAML file per source under `contracts/`, named after the source
(`contracts/participants.yml`, `contracts/heart_rate.yml`, ...). Format
documented in `contracts/README.md`. The contract is the source of truth
for a source's schema, natural key, and quality rules — don't duplicate
those specifics in prose docs; link to the contract instead.

## Documentation

Written in English, regardless of the language pipeline code comments end
up in — keeps it consistent with the rest of the repo (`CLAUDE.md`,
`data/data_dictionary.md`).
