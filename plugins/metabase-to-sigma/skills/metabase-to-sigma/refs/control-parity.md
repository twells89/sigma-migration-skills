# Control parity — lint, flip test, and the MCP/export answer

SHARED ref, vendored byte-identical into every covered plugin's `refs/`
(md5 discipline). Companion to `scripts/lib/control_lint.rb` (gate 7 /
post-and-readback control lint) and `scripts/probe-controls.rb` (flip test).

## Why this exists

A migrated workbook can pass data parity, the column-type guard, and the
layout lint and still ship **broken interactivity**. The 2026-06 estate audit
of a validation org found 86 controls across 36 kept workbooks: 8 DEAD (no
filter target, no formula reference — pure furniture), 18 PARTIAL (same-page
charts outside the control's reach; 8 of them bugs), and the Qlik class
(source dashboards full of listboxes migrated with zero controls). None of
the existing gates noticed, because every existing gate evaluates elements in
their default state.

## The three layers

1. **Control lint** (`scripts/lib/control_lint.rb`) — static spec analysis:
   dead controls, ghost filter targets, source-closure reach vs same-page
   queryable elements, and source-signal coverage via the
   `control-scope.json` sidecar. Runs automatically in
   `post-and-readback.mjs --type workbook` (exit 4) and as
   `assert-phase6-ran.rb` **gate 7** (exit 9, `--skip-control-lint` escape).
2. **control-scope.json contract** — emitted by the builder next to the
   workbook spec. Carries (a) `sourceFilterSignals`: how many filter-like
   signals the SOURCE artifact had (Tableau quick filters + actions, PBI
   slicers, Qlik listboxes, QuickSight/Cognos parameters+prompts, Looker
   dashboard filters, TS Liveboard filters) — `>0` with zero spec controls
   FAILS the lint; (b) per-control intent: `scope: "page"` (default — the
   control must reach every same-page queryable element) or
   `scope: ["Element name or id", ...]` (the **single-chart-switcher
   allowlist** for intentional narrow controls like grain/geo-level toggles)
   plus optional `mustReach` hard assertions. Full schema in the
   `control_lint.rb` header CONTRACT block. The in-spec `controlScope` key on
   a control element means the same thing but does NOT survive Sigma
   readback — the sidecar is the durable form.
3. **Flip test** (`scripts/probe-controls.rb`) — OPTIONAL Phase-6 runtime
   evidence, not the mandatory inner loop. Exports one in-closure element CSV
   with and without `parameters:{<controlId>: <first non-default value>}` —
   they must differ; with `--check-out-of-closure`, an out-of-closure element
   must NOT differ. Use it after hand-wiring controls, after estate repairs,
   or when the lint's static reach needs runtime confirmation.

## The MCP question — definitive answer (verified 2026-06-12, a validation org)

Tested by setting a saved default (`values: ["West"]`) on a live workbook's
Region list control (PHASEE, `64e78398`), then querying/exporting the same
in-closure bar chart every way available:

| Path | Control defaults applied? | Can set a control value? |
|---|---|---|
| Sigma MCP workbook query | **YES** — returned only the default-filtered row | **NO** — the query path exposes no control-parameter override |
| REST export, no `parameters` | **YES** — only the West row | n/a |
| REST `POST /v2/workbooks/{id}/export` with `"parameters": {"<controlId>": "<value>"}` | starts from defaults | **YES** — and the parameter **REPLACES** the saved default (parameters `{"ctl-region":"South"}` over a West default returned only South — no intersection) |

Consequences:

- MCP is fine for **default-state parity** (Phase 6 uses exactly that), and
  default-state MCP rows DO move if you change a control's saved default.
- MCP can NOT exercise a non-default control value — flip testing MUST go
  through the export API's `parameters` map. That is why probe-controls.rb is
  built on export.
- A parameter value that matches no data row returns an EMPTY (header-only)
  CSV, not an error — pick flip values from the column's actual domain
  (probe-controls.rb auto-picks from the control's value-source column).

## Repair recipes (what the lint tells you to do)

- **dead control, column exists on a master** → add
  `filters: [{source: {kind: "table", elementId: "<master>"}, columnId: "<col>"}]`
  (and point the control's own `source` at the same column for its value
  list).
- **dead control, column does NOT exist anywhere** → REMOVE the control.
  Honest beats decorative; do not fake-wire to an unrelated column.
- **partial reach, multi-master page** → add one filter target per master the
  control should govern (the column must exist on each); elements sourcing
  from those masters inherit via the closure.
- **partial reach, chart bypasses the master** (sources the DM directly) →
  either re-source the chart from the master or re-root it through a hidden
  shared BASE TABLE (a `kind: table` element sourcing the same DM element,
  carrying passthrough columns; the chart re-sourced through it) and target
  the table. Control filter targets may only point at TABLE elements — a
  chart/KPI target is rejected at POST/PUT with 400 "Dependency not found"
  (live-verified 2026-06-12; the looker builder's listen-scope tables and
  enhance-apply's `ensure_base_table!` are the two automated forms of this
  pattern).
- **intentional narrow control** (grain switcher driving one chart by
  formula) → annotate `scope: [...]` in control-scope.json; don't fake-wire.

After any repair: flip-test the workbook
(`ruby scripts/probe-controls.rb --workbook-id <id> --check-out-of-closure`).

## Gotcha: list-control targets on NUMERIC columns are silently stripped
Same class as the datetime strip: a list control whose filter target column is
numeric returns PUT 200 but reads back `filters: null`. Fix: add a hidden
`Text()` cast column on the target element and point the control at the cast.
(Found live by gate 7 on the MicroStrategy retrofit, 2026-06-12.)
