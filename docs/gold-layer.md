# Gold Layer

Gold is the business-facing layer: dashboards, reports, and any other
downstream consumer (including AI tools querying the catalog) should
read from here, never from Silver directly. Three materialized views,
all under `workspace.meridian_gold`. Each view's own `CREATE OR REFRESH
MATERIALIZED VIEW` line is bare, relying on `meridian_gold_pipeline`'s
default `_gold` schema; every *reference* to another view or to a
Silver table stays `${schema_prefix}`-templated, like every other
cross-schema reference in this repo (`docs/conventions.md`).

## `participant_day`

**Purpose:** the single daily fact table everything else in Gold reads
from. Answers "how did this participant do on this day" across sleep,
activity, heart rate, and self-reported wellness.

**Grain:** `participant_id` x `date` — always exactly 1,400 rows (50
participants x 28 study days), regardless of source completeness. The
spine is a `participants` x date-sequence cross join, `LEFT JOIN`ed
against every metric source, so a day with a missing sleep session or
survey response still gets a row (with NULLs in that source's columns)
rather than disappearing from a dashboard's date axis.

**Refresh:** daily, along with every other Gold table, immediately
after Silver's own daily refresh completes
(`docs/pipeline-architecture.md`'s Orchestration section) — there's no
separate schedule per Gold table.

**Columns:**

| Column | Meaning |
|---|---|
| `participant_id`, `date` | grain |
| `chronotype`, `age`, `gender` | denormalized from `participants`, so cohort filtering needs no join |
| `asleep_min` | total minutes asleep, the session that woke up this date |
| `midsleep_hour` | clock-time midpoint of that session, fractional hour (3.5 = 3:30am) |
| `sleep_efficiency_pct` | the reconciled/derived efficiency value, not the raw self-reported one |
| `restlessness` | 0-1 scale |
| `total_steps` | sum of per-minute steps; 0 on a genuine zero-step day, but also 0 (not NULL) when there's no step data for the day at all — `activity_centroid_hour IS NULL` doesn't disambiguate the two, since it's also NULL on a genuine zero-step day |
| `activity_centroid_hour` | step-weighted mean hour of activity; NULL on a zero-step day |
| `avg_heart_rate_bpm`, `min_heart_rate_bpm`, `max_heart_rate_bpm` | exclude any reading Silver flagged suspect (stuck sensor, implausible value, participant-ID mismatch) |
| `heart_rate_reading_count` | count of ALL readings, suspect or not — a coverage signal, not a trust filter |
| `is_provisional` | TRUE when `heart_rate_reading_count` covers under 80% of the expected 1,440 per-minute readings — treat that day's heart-rate figures as low-confidence, don't silently drop the row |
| `fatigue_score`, `stress_score`, `readiness_score`, `sleep_quality_score` | self-reported, straight from `wellness` |

**Known limitation:** `activity_centroid_hour` is a plain step-weighted
average, reused as-is from the prototype
(`docs/pipeline-architecture.md`'s Gold section). Like `midsleep_hour`,
it's a clock-time value and has the same theoretical midnight-wraparound
exposure *within* a single day (heavy activity just before and just
after midnight would pull the centroid toward noon). Not fixed here —
this is the already-established prototype formula, not new work this
pass touched — flagged for awareness, not invented around.

**Suspect-row filtering applies to heart rate only.** Sleep, steps, and
wellness values are passed through unfiltered even when Silver flagged
them suspect — heart rate's per-minute grain affords row-level exclusion
without losing the day; a single daily sleep session, step total, or
survey response doesn't have that luxury without nulling out the row
entirely (see the design spec's "Suspect heart-rate rows" section).

## `participant_week`

**Purpose:** weekly batches for the biostatistics team.

**Grain:** `participant_id` x `study_week` (1-4) — 200 rows.
`study_week` is study-relative, not calendar: the study starts on a
Thursday (2026-01-08), so calendar weeks would split unevenly at the
boundaries. Week 1 is the first 7 days from the study's actual start
date (read from `participant_day` itself, not a second hardcoded
literal), week 4 the last 7.

**Derivation:** reshaped directly from `participant_day` — never
recomputed from Silver (`docs/pipeline-architecture.md`). Every column
is `participant_day`'s daily value aggregated across the week's 7 days,
using whichever aggregate matches its semantics (see table).

**Columns:**

| Column | Aggregation | Notes |
|---|---|---|
| `chronotype`, `age`, `gender` | pass-through | unchanged per participant |
| `avg_asleep_min`, `avg_sleep_efficiency_pct`, `avg_restlessness` | `AVG` | |
| `avg_midsleep_hour` | circular mean | see "Circular mean" below |
| `avg_daily_steps` | `AVG(total_steps)` | |
| `avg_activity_centroid_hour` | circular mean | same treatment, applied proactively |
| `avg_heart_rate_bpm` | `AVG` | mean of the 7 daily means, unweighted by each day's valid-reading count |
| `min_heart_rate_bpm` / `max_heart_rate_bpm` | `MIN`/`MAX` | the week's true low/high, not an average of daily extremes |
| `total_heart_rate_reading_count` | `SUM` | weekly total readings |
| `is_provisional` | derived | `total_heart_rate_reading_count / (7 x 1440) < 0.80` |
| `avg_fatigue_score`, `avg_stress_score`, `avg_readiness_score`, `avg_sleep_quality_score` | `AVG` | |

Every weekly column is prefixed `avg_`/`min_`/`max_`/`total_` even where
`participant_day`'s column would otherwise match by name — a business
user comparing the two tables needs "one night's total" vs. "a week's
average" to be visible in the column name itself.

### Circular mean

`midsleep_hour` and `activity_centroid_hour` are clock times, not plain
numbers — averaging them with `AVG()` breaks whenever the underlying
values straddle midnight (23.8 and 0.7 naively average to ~12.2, nowhere
near the true ~0.25). This isn't hypothetical: checked against all 1,400
real sleep sessions, 7 of 50 participants (P003, P011, P017, P018, P019,
P025, P038) have at least one night within 2 hours of midnight on both
sides. Both weekly/study-window averages use a proper circular mean
instead — convert each value to a point on the 24-hour clock, average
the unit vectors, convert back:

```sql
MOD(
  DEGREES(ATAN2(AVG(SIN(RADIANS(hour_col * 15))), AVG(COS(RADIANS(hour_col * 15)))))
  + 360,
  360
) / 15
```

## `participant_study_summary`

**Purpose:** the table chronotype cohort comparison reads from (e.g.
chronotype A vs. B) — one row per participant summarizing the whole
study.

**Grain:** `participant_id` — 50 rows.

**Derivation:** reshaped directly from `participant_day`, like
`participant_week` — **not** chained through `participant_week`. For
plain `AVG`/`MIN`/`MAX`/`SUM` this wouldn't matter (every week has the
same 7-day count), but a week's circular mean keeps only the resulting
angle, not the underlying dispersion — re-averaging 4 already-collapsed
angles isn't guaranteed to equal the circular mean of all 28 raw nights.
Reshaping both Gold tables directly from `participant_day` sidesteps the
question.

**Columns:** identical set and aggregation choices to `participant_week`,
minus the week bucketing — `GROUP BY participant_id` over all 28 days
instead of 7.

## What's deliberately not here

- **No `_prepared`/`quarantine_*` three-view split.** That pattern
  exists in Silver to implement `contracts/*.yml`'s `on_fail` vocabulary
  (fix/flag/quarantine/fail). Gold has no contract governing it — it's a
  pure reshape/aggregation layer over already-validated Silver data, so
  there's nothing to quarantine.
- **No `CONSTRAINT ... EXPECT` data-quality checks.** Same reason —
  nothing declares quality rules for Gold. Adding them here would mean
  inventing rules Silver doesn't already own, which risks
  double-guessing checks that happened one layer down. A future
  Gold-level SLA/monitoring need is a separate design question, not
  something to improvise into this pass.
- **Column-level `COMMENT`s in the `CREATE` statement.** Table-level
  `COMMENT` is used (confident, standard syntax). Whether Lakeflow's
  materialized-view grammar supports a typed-or-named column list with
  per-column `COMMENT`s mixed into the same parenthesized block as
  `CONSTRAINT` clauses is unverified against a live workspace — same
  treatment as the Bronze `timestamp` physical-type risk flagged in the
  Silver design spec: not guessed at, flagged for verification next live
  deploy. This doc is the authoritative column-level documentation until
  then.
