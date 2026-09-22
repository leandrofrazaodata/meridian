# Validation Rules

Per-field, per-source rules live in each source's [contract](../contracts/)
(`contracts/<source>.yml`) — this doc is the policy layer: what each
`on_fail` behavior means, and when to use which. Don't duplicate specific
thresholds here; link to the contract.

## The four `on_fail` behaviors

| Behavior | What happens | Use for |
|---|---|---|
| `fix` | Deterministic correction applied before any check runs — not a failure at all | Known, always-correctable issues: regex-backfilling `firmware_version` from `device_label`, normalizing mixed timestamp formats |
| `flag` | Row stays in Silver; a quality column marks it suspect | Anomalies where removing the row would do more harm than keeping it — see time-series guidance below |
| `quarantine` | Row is removed from the Silver table and written to a companion `quarantine_<entity>` table with a reason code, for human review | Structurally meaningful failures worth a person looking at — e.g. a survey response referencing a participant not in the roster |
| `fail` | The whole pipeline update aborts | Reserved for structural breaks, not per-row data issues — e.g. a source file that doesn't parse at all, a natural key column missing entirely |

`quarantine` was chosen over silent dropping deliberately: this is health
research data, and losing rows with no record of why is worse than keeping
a reviewable trail, even for data that shouldn't feed downstream analysis
as-is.

## Natural-key uniqueness (applies to every contract)

Every contract declares a `natural_key`, and that key is implicitly
required to be unique — stated once, here, rather than repeated as a rule
in all six YAML files:

- **Exact duplicates** (same key, identical values in every column) →
  `fix`: keep one copy, silently. No ambiguity, safe to automate.
- **Conflicting duplicates** (same key, different values across the
  duplicate rows) → `quarantine`: we can't know which row is correct
  without a person looking.

Detectable per-row via a window function, e.g.
`COUNT(*) OVER (PARTITION BY <natural_key columns>) = 1` — same
`rule:`-style expression as any other check, no special YAML shape needed.

## `flag` vs. `quarantine` — which one?

The sharpest way to decide: is this an **attribute** problem or an
**identity** problem?

- **Attribute plausibility** — the row's identity is sound, but one of
  its values looks unusual (age 95, height 250cm). The row is still
  safely usable and joinable; a reader just needs to know it's an
  outlier. → `flag`.
- **Identity/key integrity** — something about the row's own identifying
  fields is malformed, or it collides with another row's identity (a
  `participant_id` that doesn't fit the study's ID scheme, two
  participants sharing a `device_id`). Letting this ride silently risks
  corrupting joins or misattributing data to the wrong person — worse
  than losing the row. → `quarantine`.

One documented exception: **high-frequency time series** (`heart_rate`,
`steps` — ~40K rows per participant) override toward `flag` even for
identity-shaped problems (e.g. `pid_matches_path`), because quarantining
every offending per-minute row would fragment the series and produce a
quarantine table too large to meaningfully review. A stuck optical HR
sensor repeating a value for hours, for example, is flagged
(`is_suspect`-style column), not removed — the surrounding series is
still useful.

**Low-frequency, structural data** (`wellness_survey` rows, `sleep`
sessions, dimension tables) follows the identity/attribute split above
without the frequency override — these are rare enough to review
individually.

This is guidance, not a hard rule — the actual choice per field is
recorded in that source's contract.

## Known raw-data quirks and how they're handled

From `data/data_dictionary.md`, mapped to a handling strategy:

| Quirk | Handling |
|---|---|
| Timestamps mostly naive local (`UTC-05:00`), occasionally `Z`-suffixed UTC in `heart_rate.json` | `fix` — normalize explicitly in Silver, never assume a single format |
| `device_metadata.firmware_version` sometimes blank, true value embedded in `device_label` | `fix` — regex-extracted in Silver |
| Optical heart-rate sensor dropout: a stuck sensor repeats its last reading for hours | `flag` — long runs of an identical `heart_rate_bpm` value are marked suspect, not removed |
| Sleep stage order should always be `light → deep → rem → light → awake` | `flag` if violated — indicates a session worth a second look, but not necessarily unusable |

## Referential integrity

`wellness_survey` and `device_metadata` rows are both checked against the
Silver `participants` dimension before being accepted — an unmatched
`participant_id` is `quarantine`d rather than joined away silently, so
it's visible that a row exists for a participant the roster doesn't
recognize.
