# Excel → Sigma

Migrate **Excel (`.xlsx`) planning / budget / forecast models** to Sigma —
preserving the part that matters most about a spreadsheet: **data entry**.

Part of the [`sigma-migration-skills`](https://github.com/twells89/sigma-migration-skills)
marketplace (`plugins/excel-to-sigma/`). Graduated from the staging repo
[`twells89/excel-to-sigma`](https://github.com/twells89/excel-to-sigma); see
[`SYNC.md`](SYNC.md).

## What it does

Excel planning models aren't dashboards — they're data-entry tools. The faithful
Sigma translation keeps forecasters typing numbers, which is what **input tables**
are for. The skill covers:

1. **Discovery** — inventory formal Excel Tables, pivots, charts, and a formula
   census (flagging the untranslatable).
2. **Read/output half** — formal Tables → Sigma data-model elements; the
   income-statement SUMIFS become grouped DM metrics + workbook charts.
3. **Data-entry half (validated)** — the formal Table forecasters edit becomes a
   Sigma **input table**; the data model re-points to read it through a
   **warehouse view**.

```
Excel formal Table → Sigma input table → (publish) → SIGDS_ writeback
   → warehouse view → data model (FROM view) → workbook charts/metrics
```

Workbook POSTs use the released **`code_rep` document wrapper** (same wire
contract as every sibling converter). Builders author nested drafts;
`skills/excel-to-sigma/scripts/lib/workbook_wire.py` assembles layout and wraps
at the POST boundary.

## Status

- ✅ **Input-table data-entry path: validated end-to-end** (2026-06-08) with exact
  parity on a 540-row forecast model.
- ✅ Read/output DM + workbook build: validated (2026-06-03).
- ✅ Workbook builders migrated to released document `code_rep` (2026-08).
- 🚧 Discovery + Excel-formula translation: spiked, not yet a one-shot converter.

See `skills/excel-to-sigma/SKILL.md` for the full workflow and `QUICKSTART.md` for
a runnable walkthrough on the bundled sample fixture.

## Requirements

- A Sigma `SIGMA_API_TOKEN` (creds in `~/.sigma-migration/env`).
- A **write-enabled** Sigma connection for the data-entry half (input tables write
  back to a `SIGDS_` schema).
- Python with `openpyxl` (+ `python-dateutil` for the fixture generator).

## License

MIT
