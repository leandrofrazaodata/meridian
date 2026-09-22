# Silver Transformations Design

`transformations/README.md` named two blockers before any `.sql` file
could land there: the `participant_week` Gold schema ("TBD together" —
still open, Gold is separate future work) and the `stuck_sensor`
run-length threshold in `contracts/heart_rate.yml`. This doc records how
the second blocker got resolved, and the design that applies uniformly
across all six Silver tables now built from it. It's documentation of
decisions already made during this session's investigation, not new
design work — written up so the `.sql` files can reference it instead of
re-explaining the architecture inline.

Scope is Silver only. Gold (`participant_day`, `participant_week`,
`participant_study_summary`) is untouched.

## Mapping the contract's `on_fail` vocabulary onto Lakeflow

`docs/validation-rules.md` defines four `on_fail` behaviors: `fix`,
`flag`, `quarantine`, `fail`. Lakeflow Declarative Pipelines' native
`CONSTRAINT ... EXPECT (...)` only has two modes: metrics-only (bare
`EXPECT`, rows always pass through, pass/fail just gets logged), or
`ON VIOLATION {FAIL UPDATE | DROP ROW}`. Neither native mode can express
`quarantine` — "keep the row, but route it to a companion table with a
reason" isn't a `DROP ROW` (which discards the row entirely, no
companion table) or a bare `EXPECT` (which never removes anything).

Each entity resolves this with a shared three-view split:

1. **`<entity>_prepared`** — a materialized view that reads Bronze,
   applies any `fix`-level correction inline (no reason code — a fix
   isn't a failure), dedups on the natural key, and computes two
   `ARRAY<STRING>` columns by hand: `_suspect_reasons` (one entry per
   failed `flag`-level rule) and `_quarantine_reasons` (one entry per
   failed `quarantine`-level rule, plus `'dedup_conflict'` for
   natural-key collisions with disagreeing values). Each entry is built
   with
   `filter(array(CASE WHEN NOT (<rule expression>) THEN '<rule id>' END, ...), x -> x IS NOT NULL)`
   — the rule expression is copied verbatim from the contract's `rule:`
   field, so the array can't drift from what the contract actually says.
   `fail`-level rules skip the array entirely and become a native
   `CONSTRAINT <rule id> EXPECT (<rule expression>) ON VIOLATION FAIL UPDATE`
   declared directly on `_prepared` — whichever downstream view would
   trip it, `FAIL UPDATE` aborts the whole pipeline update regardless, so
   putting it on `_prepared` just fails fastest.
2. **`<entity>`** (main) — `SELECT <business columns>, _suspect_reasons
   FROM <entity>_prepared WHERE size(_quarantine_reasons) = 0`. Carries
   one bare `EXPECT` per `flag`-level rule,
   `CONSTRAINT <rule id> EXPECT (NOT array_contains(_suspect_reasons, '<rule id>'))`
   — no `ON VIOLATION` clause, so it never drops a row. This is free
   observability in the Lakeflow UI's per-constraint pass/fail metrics,
   checked against the same precomputed array a reader would query
   directly — the metric and the queryable column can't disagree with
   each other, because one is defined in terms of the other.
3. **`quarantine_<entity>`** — same filter inverted
   (`size(_quarantine_reasons) > 0`), column list adds
   `_quarantine_reasons` itself. No constraints — a table that's 100%
   reasons by definition has nothing meaningful to track a pass rate for.

`sleep` adds a fourth view, `sleep_stages`, at a different grain (one row
per stage, not per session) — see "Naming" below.

**Natural-key dedup**, concretely, is the same idiom in every
`_prepared` view: `MIN`/`MAX` of a content fingerprint (`hash()` across
every non-key column, or the single other column directly when there's
only one) windowed `PARTITION BY <natural key>`. Exact duplicates
(`MIN = MAX`) collapse to one row silently via `ROW_NUMBER() = 1` — a
`fix`, not a failure. Conflicting duplicates (`MIN <> MAX`) keep every
copy and all of them get `'dedup_conflict'` in `_quarantine_reasons` — a
natural-key collision is a grain violation, not attribute noise, so it
quarantines even on the two high-frequency tables that otherwise flag
identity-shaped problems instead of quarantining them (the
`docs/validation-rules.md` high-frequency override applies to per-row
attribute checks like `pid_matches_path`, not to the key itself).

## Naming

Table names follow the *conformed entity*, not always the contract
filename (`docs/conventions.md`): `wellness_survey.yml` → Silver table
`wellness` / `quarantine_wellness`; `sleep.yml` → `sleep_sessions` +
`sleep_stages` (different grains — one row per night vs. one row per
stage, both derived from the same `sleep_prepared` view); every other
contract keeps its own name. The **file** stays named after the
contract regardless (`transformations/wellness_survey.sql`), matching
`deploy/resources/sql/ingest_wellness_survey.sql` on the Bronze side —
one file per contract, flat under `transformations/`, picked up by
`deploy/resources/pipelines.yml`'s recursive `libraries.glob.include`.

Every cross-schema reference — every Bronze read, every Silver-to-Silver
FK check — is `${schema_prefix}`-templated
(`${schema_prefix}_bronze.<table>`, `${schema_prefix}_silver.<table>`),
never a hardcoded `meridian_*`, matching
`deploy/resources/pipelines.yml`'s `configuration.schema_prefix:
${var.schema_prefix}`.

Every main/quarantine view keeps Bronze's `_source_file` and
`_ingested_at` lineage columns. `_pid_from_path` (JSON sources only) is
dropped after the `pid_matches_path` check consumes it in `_prepared` —
it did its one job.

## Resolved decisions

### `stuck_sensor` threshold: 15 minutes

`contracts/heart_rate.yml` left this as an open question. Resolved
empirically by computing actual identical-value run lengths across every
real `heart_rate.json` record — all 50 participants, 2,014,950 rows
total. Every organic run tops out at 8 minutes; the only runs longer than
that are two genuine stuck-sensor events (P003 at 60bpm, P042 at 73bpm,
both running 180 minutes straight). 15 minutes sits cleanly in the gap
between the two, with no real data anywhere near that boundary in either
direction.

### Natural-key dedup scope: all six Silver tables

`docs/validation-rules.md`'s natural-key uniqueness rule (exact duplicate
→ `fix`, conflicting duplicate → `quarantine`) applies uniformly across
every Silver table, not selectively. Checked all six raw Bronze-bound
sources directly: `participants`, `device_metadata`, `wellness_survey`,
and `sleep` have zero duplicate-key rows in the real dataset.
`heart_rate` and `steps` don't — 5,767 duplicate-key groups each, spread
across 8 of the 50 participants, 4 of whom have an entire calendar day
double-logged with genuinely conflicting values (confirmed by hand on
P010's data). The dedup logic is written into all six files regardless of
whether current data exercises it, since the contract's uniqueness
guarantee isn't conditional on today's data being clean.

### Bronze `timestamp` physical type: deferred, not fixed here

`heart_rate.json` timestamps are almost always naive local
(`UTC-05:00`), occasionally `Z`-suffixed UTC
(`data/data_dictionary.md`). Spark's default JSON schema inference could
plausibly parse both shapes into one native `TIMESTAMP` column during
Bronze's `COPY INTO` (the offset component of the pattern is optional),
which would silently lose the `Z` marker and mean naive timestamps got
parsed using the session default timezone instead of the intended
UTC-05:00 — before Silver ever sees the raw text.
`deploy/resources/sql/ingest_heart_rate.sql` does `CREATE TABLE IF NOT
EXISTS` with no explicit column list, so which way this actually landed
is genuinely undetermined without a live workspace. `transformations/heart_rate.sql`'s
timestamp-normalization branch is written assuming Bronze preserved the
raw text (castable to `STRING` with the `Z` intact) — flagged inline in
that file. Verify against a real `DESCRIBE TABLE
${schema_prefix}_bronze.heart_rate` next time there's a live deploy; fix
Bronze only if the risk turns out to be real.

## Known contract gaps (flagged, not fixed here)

Found while re-reading every contract in full. Neither blocks
implementation; both are called out inline as a comment in the relevant
`.sql` file rather than silently patched, since the contract is meant to
be the single declared source of truth and neither is part of what this
pass was asked to do:

- `contracts/wellness_survey.yml` and `contracts/sleep.yml` declare no
  `fail`-level null-check on their natural-key columns, unlike
  `contracts/participants.yml`'s `pid_not_null` and
  `contracts/device_metadata.yml`'s `device_id_not_null`.
  `wellness_survey`'s `participant_id` is incidentally covered by
  `participant_exists`'s NULL-is-a-violation semantics, but its `date`
  column, and both of `sleep`'s natural-key columns, have no rule that
  would catch a null. Worth adding an explicit rule to those two
  contracts later.
