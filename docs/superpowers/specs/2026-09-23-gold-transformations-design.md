# Gold Transformations Design

`docs/pipeline-architecture.md`'s Gold section sketches the three tables
this layer needs — `participant_day`, `participant_week`,
`participant_study_summary` — and already establishes that
`participant_week` derives from `participant_day`, but leaves
`participant_week`'s exact schema "TBD together" and doesn't say whether
`participant_study_summary` derives from `participant_day` directly or
chains through `participant_week`. This doc records how those questions got
resolved, along with the rest of the shared design that applies across all
three Gold materialized views. It's documentation of decisions already
made, not new design work — written up so the `.sql` files (Tasks 2–4) can
reference it instead of re-explaining the architecture inline.

Scope is Gold only. Silver is done and merged; this layer reads from it but
does not modify it.

## Design — shared architecture

### Audience shapes Gold away from Silver's engineering-facing style

Confirmed directly with the user. Three consequences:

- **Denormalize.** `participant_day` carries `chronotype`/`age`/`gender`
  from `participants` directly — a dashboard or BI tool shouldn't need a
  join for basic cohort filtering.
- **Business-friendly naming over Silver's internal names where they
  differ** — e.g. `sleep_efficiency_pct` (Gold) vs. Silver's
  `efficiency_pct_derived`: Gold doesn't need to carry the
  source-vs-derived distinction Silver's reconciliation needed.
- **Documentation is a first-class deliverable** — `docs/gold-layer.md`
  (business purpose, grain, consumption guidance per table) plus
  table-level `COMMENT`s in the SQL, so Catalog Explorer/BI tools/AI
  tools querying `information_schema` see table purpose without opening
  a doc.

### `participant_day` is the only Gold table that reads Silver

Per `docs/pipeline-architecture.md`'s Gold section: one daily-grain fact
table, everything else derived from it, not parallel pipelines per
consuming team. `participant_week` and `participant_study_summary` both
read `participant_day` only — neither touches Silver, and **neither
chains through the other** (both reshape `participant_day`
independently — see "Why `participant_study_summary` doesn't chain
through `participant_week`" below).

No Silver-style `_prepared`/`quarantine_<entity>` three-view split, and
no `CONSTRAINT ... EXPECT` constraints, anywhere in Gold. That pattern
exists in Silver specifically to implement `contracts/*.yml`'s `on_fail`
vocabulary; nothing governs Gold with an equivalent contract. Inventing
quality rules here would mean second-guessing checks Silver already owns
by the time data reaches Gold — out of scope for this pass.

### `participant_day`: spine, and the two reused prototype formulas

**Spine:** `CROSS JOIN participants × sequence(DATE'2026-01-08',
DATE'2026-02-04')`, `LEFT JOIN` every metric source onto it. Guarantees
exactly 1,400 rows (50 × 28) regardless of source completeness — a day
with a missing sleep session or survey response still gets a row (NULLs
in that source's columns) instead of vanishing from a dashboard's date
axis. The fixed date range is hardcoded as a literal, matching how the
rest of the repo already hardcodes this one fixed synthetic study's
facts (the P001–P050 range, the 40–200bpm plausibility window, etc.) —
`CLAUDE.md` documents this same 2026-01-08 → 2026-02-04 range as a fixed
fact, not a parameter a general pipeline would need to vary.

**Reused verbatim from the superseded prototype**
(`docs/pipeline-architecture.md`: "both reused in the rebuild"):
- `activity_centroid_hour` — step-weighted mean hour of activity,
  `SUM(fractional_hour * steps) / NULLIF(SUM(steps), 0)`. `NULLIF`
  makes an all-zero-step day NULL (undefined centroid), not a false
  zero. Carries a known wraparound limitation — see "Known, flagged
  limitations" below.
- `is_provisional` — `heart_rate_reading_count < 0.80 * 1440`.

**Suspect heart-rate rows: counted for coverage, excluded from vitals.**
`heart_rate_reading_count` counts every Silver `heart_rate` row for the
day, suspect-flagged or not — the sensor did respond, so it counts
toward coverage. `avg_heart_rate_bpm`/`min_heart_rate_bpm`/
`max_heart_rate_bpm` exclude rows with any `_suspect_reasons` entry — a
180-minute stuck-sensor run (the real cases in this dataset, per the
Silver design spec) shouldn't drag a whole day's average toward one
repeated value.

### Circular mean for `midsleep_hour` and `activity_centroid_hour`

Both are clock times. A plain `AVG()` across multiple days breaks
whenever the underlying values straddle midnight — e.g. one night at
23.8 and another at 0.7 average to ~12.2, nowhere near the true ~0.25.

Checked against all 1,400 real sleep sessions this session, not
assumed: computed `midsleep_hour` for every session across all 50
participants directly from `data/wearable_events/*/sleep.json`. **7 of
50 participants** (P003, P011, P017, P018, P019, P025, P038) have at
least one night ≥22h and another <2h in their real data — e.g. P003 has
nights at 23.5/23.77 and others at 0.73–1.82. A naive weekly `AVG` on
that participant's data would be badly wrong. `activity_centroid_hour`
gets the same treatment proactively — identical wraparound exposure in
principle, not independently re-verified against the (much larger)
`steps.json` data since the fix is identical and cheap regardless.

Both weekly and study-window averages of these two columns use a
circular mean instead of `AVG()`:

```sql
MOD(
  DEGREES(ATAN2(AVG(SIN(RADIANS(hour_col * 15))), AVG(COS(RADIANS(hour_col * 15)))))
  + 360,
  360
) / 15
```

`* 15` converts hour-of-day to degrees (360/24 = 15). `+ 360` before the
final `MOD` guards against `ATAN2`'s `[-180, 180]` range producing a
negative angle, so the value entering `MOD` is always non-negative and
the result lands cleanly in `[0, 360)`. `AVG()`'s standard NULL-skipping
(a day with no sleep session has NULL `midsleep_hour`) applies the same
way inside `SIN`/`COS` — a missing day is excluded from both the plain
and circular averages identically, no special-casing needed.

### `study_week` definition

Study-relative, not calendar: 2026-01-08 is a Thursday, so calendar
weeks (Mon–Sun or ISO) would split the 28-day study unevenly at both
ends. Study-relative weeks divide it into exactly four clean 7-day
blocks:

```sql
FLOOR(DATEDIFF(date, MIN(date) OVER ()) / 7) + 1
```

`MIN(date) OVER ()` (unpartitioned — the global minimum across all of
`participant_day`) reads the study's actual start date from
`participant_day`'s own data rather than hardcoding `2026-01-08` a
second time — keeps the anchor single-sourced in `participant_day`'s
spine instead of risking drift between two copies of the same constant.

### Why `participant_study_summary` doesn't chain through `participant_week`

Chaining would be exact for `AVG`/`MIN`/`MAX`/`SUM` (every week has the
same 7-day count, so an average of 4 equal-size group averages equals
the direct 28-value average). It would **not** be exact for the
circular-mean columns: a week's circular mean keeps only the resulting
angle, discarding the underlying resultant-vector length (dispersion)
that produced it. Re-averaging 4 already-collapsed angles with equal
weight isn't guaranteed to equal the circular mean of all 28 raw nights
— a tightly-clustered week and a widely-spread week would get equal say
despite representing very different amounts of evidence. Reshaping both
Gold tables directly from `participant_day` sidesteps the question
entirely rather than reasoning through it column-by-column.

### Unity Catalog schema qualification (verified against `pipelines.yml`)

`deploy/resources/pipelines.yml` sets the pipeline's default `schema` to
`${schema_prefix}_silver` — confirmed directly in the file, not assumed.
Silver's own materialized views rely on this default and reference each
other with bare names. **Gold objects need `${schema_prefix}_gold.`
explicit qualification on both the `CREATE OR REFRESH MATERIALIZED VIEW`
name itself and every reference to another Gold table**
(`participant_week`/`participant_study_summary` referencing
`participant_day`) — neither is the pipeline's default schema, so an
unqualified name would silently resolve to `_silver` instead. References
to Silver tables from Gold use `${schema_prefix}_silver.`, matching the
convention Silver's own FK checks already established.

### Documentation approach

- **Table-level `COMMENT '...'`** directly in each `CREATE OR REFRESH
  MATERIALIZED VIEW` statement — standard, high-confidence Databricks
  SQL DDL syntax.
- **Column-level `COMMENT`s are not attempted in the `CREATE`
  statement.** Whether Lakeflow's materialized-view grammar supports a
  named-or-typed column list with per-column `COMMENT`s mixed into the
  same parenthesized block Silver uses for `CONSTRAINT` clauses is
  unverified against a live workspace — see "Known, flagged
  limitations" below.
- **`docs/gold-layer.md`** is the authoritative column-level
  documentation in the meantime.

## Known, flagged limitations

- **`activity_centroid_hour`'s within-day wraparound exposure.**
  `activity_centroid_hour` has the same theoretical midnight-wraparound
  exposure as `midsleep_hour` (see "Circular mean for `midsleep_hour`
  and `activity_centroid_hour`" above), but *within* a single day's
  per-minute readings rather than across days — the same
  straddle-midnight failure mode the circular-mean fix addresses for
  multi-day averaging could, in principle, also distort a single day's
  step-weighted centroid if that day's activity clusters on both sides
  of midnight. Not fixed here — it's the established, reused prototype
  formula (`docs/pipeline-architecture.md`: "both reused in the
  rebuild"), and redesigning already-approved work wasn't part of this
  pass. Flagged in `docs/gold-layer.md`, not silently patched.
- **Unverified column-level `COMMENT` syntax.** Whether Lakeflow's
  materialized-view grammar supports a named-or-typed column list with
  per-column `COMMENT`s mixed into the same parenthesized block Silver
  uses for `CONSTRAINT` clauses hasn't been checked against a live
  workspace — same treatment as the Bronze `timestamp` physical-type
  risk flagged in the Silver design spec: flagged for verification at
  next live deploy rather than guessed at and possibly shipped broken.
  `docs/gold-layer.md` carries the authoritative column-level
  documentation until this is verified.
