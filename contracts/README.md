# Data contracts

One YAML file per Bronze source. Each contract is the single declared
definition of that source — where it lands, what its schema and natural
key are, and what "valid" means for it. Bronze ingestion (`COPY INTO`) and
Silver quality checks are both meant to be driven from these files rather
than duplicating the same facts in pipeline code and in prose docs.

See `docs/pipeline-architecture.md` for how contracts fit into the
pipeline, and `docs/validation-rules.md` for what each `quality[].on_fail`
value means.

## Format

```yaml
name:                 # source name, matches the contract filename
description:          # one line, what this data is
grain:                # what one row represents
owner:                # team/person responsible — TBD until teams are assigned

source:
  format: csv | json
  path: ...            # exact file path, or glob for per-participant files
  read_options: {}     # format-specific read options (header, multiLine, ...)

bronze:
  table: meridian_bronze.<name>
  load_pattern: copy_into

natural_key: [...]     # column(s) that uniquely identify a row

schema:
  - name:
    type:
    nullable:
    description:

quality:                # rules checked in Silver; see docs/validation-rules.md
  - id:
    rule:                # SQL boolean expression
    on_fail: fix | flag | quarantine | fail
    note:                # optional, why this rule/behavior

freshness:
  cadence: static | daily | weekly
  notes:
```

`schema` and `quality` describe the *Bronze→Silver* contract — Bronze
itself stays close to raw (see `docs/pipeline-architecture.md`).
