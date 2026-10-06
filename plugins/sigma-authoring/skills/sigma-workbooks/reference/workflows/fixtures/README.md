# Operational app fixtures

Parameterized workbook specs for the four operational app types. Clone the
matching file when generating an app via [`../generate-apps.md`](../generate-apps.md).
Architecture details live in the sibling `*-apps.md` recipes; these files are
the starting specs.

## Rules

- Placeholders only. Replace `<FOLDER_ID>`, `<WRITE_CONNECTION_ID>`, and
  `<SOURCE_CONNECTION_ID>` (and `[Source/…]` column names) from live discovery
  before POST. Do not commit real org, user, folder, or workbook IDs.
- Every `input-table` has `inputMode: view`. Published data entry is UI-only
  (element kebab → Set data entry permission → Only in published version) and
  is absent from `GET /spec`.
- Entry `text` / `text-area` controls include `mode`, `case`, `includeNulls`,
  and `showOperators` (see `controls.md`). Omitting them POSTs as
  `Invalid kind: "control"`.
- `insert-rows` / `update-rows` / `delete-rows` take `tableElementId` (the
  input-table element's id). A stale `table:` key makes POST fail as
  `Invalid kind: "button"`.
- `clear-control` page scope takes `pageId` (the page's id). A stale `page:`
  key is dropped on GET and click fails with `No target page is selected`.
- Fixtures are architecture, not a visual system. Do not clone a navy hero
  + KPI-card stack onto every app; compose the look in `generate-apps.md`
  Step D.4 from `styling.md`. Fail that pass on invisible entry controls
  and Dark-by-default; do not copy a one-off app's look back into fixtures.
  Fixtures stay agent-free; compose `document.agents` / `chat` in
  generate-apps Step D.5 when intake says to include an agent.
- Key only deterministic, stable context — never status, owner, current user,
  `Now()`, or approval state.
- Hidden source page for warehouse / baseline / join plumbing. Planning is a
  multi-page studio (Workspace / Scenarios / Build / Review); the other
  types still put the editable grid, log, and actions on one visible page.
- Formulas that read another element use qualified `[SourceName/column]` refs.
- Planning may show a few **plan measures** on Workspace. Do not add a
  status-count KPI strip (SCENARIOS / IN REVIEW / APPROVED). Do not copy
  branded headers, logos, or a Guide page into the fixture.

## Files

| File | App type |
|---|---|
| `planning-app.yaml` | Planning Studio shell: Scenario × Period × Line Item, ledger, overlay, review writes |
| `allocation-app.yaml` | Period × Allocation Dimension writeback |
| `approval-app.yaml` | One editable row per entity key |
| `exception-app.yaml` | One editable row per operational entity |
