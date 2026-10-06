# Planning apps — scenario-grain writeback pattern

Entered via [`generate-apps.md`](generate-apps.md) when the user asked to generate an app.

Use this pattern when a workbook is a model rather than only a report: actual
periods followed by forecast periods, assumption tables, budget/scenario
vocabulary, manual forecast cells, or review and approval.

Do not turn every dashboard into a planning app. Establish the requested mode:

1. **One working plan** — one editable forecast, no scenario comparison.
2. **Scenario planning** — isolated scenario copies, comparison, and status.
3. **Variance workflow** — actual-vs-plan annotations and approvals, without
   editable forecast values.
4. **Parity only** — preserve the verified analytical workbook.

The architecture below is for scenario planning. The fixture is a **studio
shell**: Workspace, Scenarios, Build the Plan, Review & Approve, plus a
hidden Data page and a New Scenario overlay. Do not flatten that back to
one page.

| Page | Job |
|---|---|
| Workspace | Active scenario, a few plan measures, trend and impact-by-section. Not a status-count strip. |
| Scenarios | Directory of directions. Create via the overlay (`insert-rows` into the scenarios input). |
| Build the Plan | The linked grid is the work surface. |
| Review & Approve | Submit / Approve / Request changes write the log and update only that scenario's status. Agent rail is composed here if intake said yes. |
| Data (hidden) | Actuals, plan base, matrix, ledger plumbing. |

If the org has a data model for actuals and baseline, rebind `source-actual`
and `source-base` to `kind: data-model`. Otherwise keep the warehouse-table
placeholders. Union actuals + plan lines into a named ledger (`Ledger Union`
in the fixture) so KPIs can distinguish `(actual)` from the selected plan.
After POST, GET the ledger formulas: Sigma may drop `source.name` and rewrite
the prefix to `Union of 2 Sources`. Later PUTs must use the readback prefix.

The active-scenario control filters the plan grid (Option B). Ledger and
Workspace KPIs must still include actuals with formulas, not as descendants
of the filtered grid alone. When the scenario control is empty, Workspace
goes actuals-only with a `null` profit-impact KPI. Create one scenario
before the PNG pass, or add a boolean on the ledger
(`[ledger/scenario-name] = Coalesce([scenario], "Board Plan")`) and scope
KPIs/charts with `If([Active Flag], …)`. Do not splice `Coalesce([scenario],
…)` into an existing `If(...)` via string replace — extra commas become
new `If` arguments (`formulas.md`). A list-control `values: ["Board Plan"]`
does not stick when the bound column is still empty (`controls.md`).

## Non-negotiable grain

The editable table must have one row per:

```text
Scenario × Period × Planning Line
```

For an FP&A P&L this is usually:

```text
Scenario × Month × Line Item
```

A scenario metadata table alone is not scenario planning. If scenarios share
one plan grid, switching the selector changes only a label; every scenario
still edits the same values.

Write and later verify:

```text
expected rows = scenarios × forecast periods × planning lines
```

## Four-layer architecture

### 1. Governed baseline

Create a read-only table at forecast grain with stable context and the source
model's governed baseline:

```yaml
name: Plan Base
columns:
  - { id: pb-period,  formula: "[Source/Month]",     name: Month }
  - { id: pb-line,    formula: "[Source/Line Item]", name: Line Item }
  - { id: pb-section, formula: "[Source/Section]",   name: Section }
  - { id: pb-base,    formula: "<driver formula>",   name: Baseline }
  - { id: pb-key,     formula: "1",                  name: Join Key }
```

Preserve the source semantics: compounding drivers compound, manual lines stay
manual, and flat lines stay flat. Prove baseline parity before writeback.

### 2. Scenario directory

Use an empty input table for scenario metadata:

```yaml
id: scenarios
kind: input-table
inputMode: view
name: Scenarios
source: { kind: empty, connectionId: <write connection> }
columns:
  - { id: ID }
  - { id: sc-name,   type: text, name: Scenario Name }
  - { id: sc-status, type: text, name: Status,
      values: [Draft, In Review, Approved], pills: color-by-option }
  - { id: sc-owner,  type: text, name: Owner }
  - { id: sc-notes,  type: text, name: Notes }
```

Creating one scenario is an appropriate `insert-rows` action (the fixture's
New Scenario overlay). Creating every scenario-period-line row through
actions is not. The spec cannot seed an empty input table, so **Build the
Plan is 0 rows until at least one scenario exists**. Create one (overlay, or
a SQL default directory the matrix joins — do not union an empty input table
with that SQL as the first attempt) before the PNG pass. `expected rows =
scenarios × forecast periods × planning lines` is 0 when scenarios is 0.

Scenario strategy is descriptive unless explicit formulas implement it. Never
give scenarios different labels but identical math and imply the labels changed
the forecast.

### 3. Scenario matrix

Cross-join scenario rows to baseline rows with a constant key:

```yaml
name: Plan Matrix
source:
  kind: join
  name: Plan Matrix
  primarySource: { kind: table, elementId: scenario-directory }
  joins:
    - name: Base
      joinType: inner
      left:  { kind: table, elementId: scenario-directory }
      right: { kind: table, elementId: plan-base }
      columns:
        - { left: "[Join Key]", right: "[Join Key]" }
```

The join composes the required row grain; it does not populate the input table.
Verify:

```text
matrix rows = scenarios × baseline rows
```

If empty, inspect formula prefixes and ensure both constant keys share a type.

### 4. Linked plan grid

Link editable fields to the scenario matrix:

```yaml
id: plan-grid
kind: input-table
inputMode: view
name: Plan Grid
source:
  kind: linked
  from: plan-matrix
  connectionId: <write connection>
columns:
  - { id: pg-scenario, key: mx-scenario, name: Scenario }
  - { id: pg-period,   key: mx-period,   name: Period }
  - { id: pg-line,     key: mx-line,     name: Line Item }
  - { id: pg-section,  key: mx-section,  name: Section }
  - { id: pg-baseline, key: mx-baseline, name: Baseline }
  - { id: pg-method, type: text, name: Method,
      values: ["Grow %", "Adjust $", "Set amount"] }
  - { id: pg-percent, type: number, name: Pct Change }
  - { id: pg-dollars, type: number, name: Dollar Change }
  - { id: pg-new,     type: number, name: New Amount }
  - { id: pg-plan,   formula: "<method switch>", name: Plan Amount }
  - { id: pg-delta,  formula: "[Plan Amount] - [Baseline]", name: Plan Delta }
  - { id: pg-impact, formula: "<signed delta>", name: Profit Impact }
  - { id: pg-note, type: text, name: Rationale }
```

Bind inherited context as `{id, key}` columns. Cross-element formula columns
can render “multiple values” even after a successful POST/readback. Query rows
after data lands and prove each key resolves to one parent row.

Keys are immutable once the linked table exists. Key only deterministic, stable
context:

- good: scenario, period, line item, section, governed baseline;
- bad: status, owner, current user, `Now()`, volatile lookup, approval state.

## Override semantics

Use labels that match the math. A row-level:

```text
Baseline × (1 + 10%)
```

is a 10% uplift to that row, not a monthly growth rate that compounds into
future periods.

```text
If Method = "Grow %":
  Baseline × (1 + Pct Change)
Else if Method = "Adjust $":
  Baseline + Dollar Change
Else if Method = "Set amount":
  New Amount
Else:
  Baseline
```

Blank method means governed baseline. Do not pre-populate fake methods merely
to make the grid look active.

## Financial sign

P&L expense rows commonly store positive magnitudes, so raw delta is not
favorability:

```text
Plan Delta = Plan Amount - Baseline

Profit Impact =
  If Section = "Revenue":
    Plan Delta
  Else:
    -Plan Delta
```

Revenue +10 is favorable; expense +10 is unfavorable. Color Profit Impact,
not Plan Delta. If a conditional format that references its own formula column
silently no-ops, repeat the underlying expression in the condition and render
both positive and negative fixtures.

## Scenario selection and filter propagation

Any control filter attached to the plan grid propagates to all descendants.
Choose one design explicitly:

### Option A — complete grid, formula-scoped analytics

Do not target the grid with the scenario control. Sort by scenario and scope
selected analytics with formulas:

```text
Sum(If([Scenario] = [scenarioControl], [Amount], 0))
```

All-scenario comparisons remain intact, but the editable grid shows all
scenarios.

### Option B — filtered grid, independent all-scenario read path

Filter the grid to the active scenario. This improves editing but every
descendant loses unselected rows. Formula-scoped KPIs remain correct; a chart
intended to compare every scenario collapses to one.

Put all-scenario visuals on a lineage that does not descend from the filtered
grid, such as a supported warehouse view/read path, or replace them with an
active-scenario comparison. Never leave a one-bar “all scenarios” chart.

## Approval and audit

Generate-apps Step B asks whether this workflow needs approvals. If they
declined, keep the plan grid and omit the submit / status-update path
below.

Approval requires two writes:

1. append an immutable decision row;
2. update only the selected scenario's status.

Use the stable scenario key in `whichRows`, and prove another scenario remains
unchanged. Reset modal controls with ordered `set-control-value` effects after
the insert; see `actions.md`.

## Agent contract

Generate-apps Step B offers this agent and pre-fills the recommended
purpose; skip this section if they declined.

Give the agent the selected plan ledger, all-scenario comparison, plan grid,
scenario directory, and decision log. Instruct it to:

- distinguish actual, baseline, and selected plan;
- compare only scenario-keyed rows;
- use Profit Impact rather than raw Plan Delta for favorability;
- never claim a write occurred unless the user approved the action.

Validate with a question whose answer is known from an entered override.

## Manual published-view gate

Code Rep cannot enable published data entry. For every input table:

```text
element kebab → Set data entry permission → Only in published version
```

Publish and type in a real cell. The setting is absent from `GET /spec`.

## Required verification

POST/readback proves structure only. Before handoff, capture:

| Gate | Evidence |
|---|---|
| Baseline parity | source-vs-Sigma periods and totals |
| Matrix cardinality | scenarios × baseline rows |
| Key correlation | one parent row per linked row |
| Scenario isolation | edit A; B stays baseline; A persists |
| Financial sign | revenue increase positive; expense increase negative |
| Selected KPI scope | active scenario changes; unselected edits excluded |
| Grid scope | matches declared Option A or B |
| All-scenario scope | every scenario remains where comparison is promised |
| Approval scope | selected status changes; another does not |
| Audit | time, user, scenario, decision, and comment persist |
| Published writeback | real edit succeeds outside draft |
| Visual | rendered pages contain no errors or misleading totals |

Load `runtime-verification.md` for the full evidence loop.
