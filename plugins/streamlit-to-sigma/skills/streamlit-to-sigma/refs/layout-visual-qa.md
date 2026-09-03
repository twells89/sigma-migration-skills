# Visual QA for Streamlit migrations

Static/data parity is insufficient. Streamlit is responsive and interaction
heavy; compare rendered states explicitly.

## Source evidence

Preferred evidence, in order:

1. Page screenshots at a known viewport.
2. PDF export covering every page/tab/state.
3. `EXPECTED.md` element and interaction inventory.
4. Source-code inventory when screenshots are impractical.

Record viewport size and which controls/tabs/popovers were active.

## Sigma renders

```bash
python3 scripts/sigma-export-png.py \
  --workbook <id> \
  --page <page-id> \
  --out /tmp/page.png \
  --w 1800 --h 1200
```

Render overlays by using the overlay id as `--page`. Render parameter states
with repeatable `--param ControlId=value`.

## Checklist

- Same visible element count and kinds
- Correct page/tab/overlay ownership
- KPI labels, values, deltas, and formats
- Chart axis titles/labels, aggregation, sorting, stacking, and colors
- Control type, default, scope, and reach
- Weighted control/chart columns preserve the source proportions
- Form boundaries, Apply/Reset placement, and button alignment match the source
- Column widths and row heights
- No dead space caused by fixed tab height
- Detail tables show enough rows
- Empty/error/default states match or are documented redesigns
- Navigation/action controls are present
- Modal footer CTAs are explicitly shown/hidden; no default Primary/Secondary
  buttons leak into the migration
- No `null`, “multiple values,” unknown-column text, or clipped labels

## Responsive differences

API PNG output can differ from a live browser viewport. Match the source width
first. When the browser is available, click-test:

- page navigation
- Apply/Load/refresh buttons
- selectors and multiselects
- tabs
- popovers/status/expanders
- drilldowns

Keep a visual-delta ledger. A redesign is not “100% parity”; classify and
explain it.

For UI-only action finishes, capture the exact manual step separately. A visual
button match does not prove that its action is present in the public workbook
spec or can be replayed through POST/PUT.
