# Runtime verification — evidence beyond a successful POST

Use this after any non-trivial workbook build, especially joins, unions,
controls, input tables, actions, agents, or dynamic text.

A successful verify, POST, and readback proves only that the server accepted
the representation. It does not prove that:

- formulas compile or render;
- a join has the intended cardinality;
- a control preserves required descendant rows;
- linked input-table keys correlate to one parent row;
- actions update only the intended rows;
- users can edit the published workbook;
- charts and KPIs tell the numeric truth.

Treat verification as an evidence loop:

```text
spec verify → write → readback diff → compile → render → export
→ cardinality and semantic assertions → published interaction → evidence
```

## 1. Structural gates

```bash
ruby scripts/wb-rep.rb verify workbook.yaml
ruby scripts/wb-rep.rb push <rep-dir>
ruby scripts/wb-rep.rb pull <workbook-id> <readback-dir>
./scripts/verify-workbook.sh <workbook-id>
```

Compare submitted and readback documents:

- no field silently disappeared;
- future writes use server-generated source/formula prefixes;
- every element has exactly one layout placement;
- agents, overlays, controls, actions, and theme survived;
- no input-table key changed.

Do not normalize away a meaningful dropped field.

## 2. Render every affected page

```bash
ruby scripts/wb-rep.rb render <rep-dir>
ruby scripts/wb-rep.rb render <rep-dir> --page "Workspace"
```

Inspect the PNG for:

- `Invalid Query`, unknown-column, or invalid-argument messages;
- clipped titles, controls, legends, columns, and buttons;
- empty visuals that should have rows;
- misleading scales, totals, stacking, or waterfall semantics;
- unexpected font fallback;
- a KPI that changed after adding a view-only filter.

Dynamic text can POST and compile while rendering an error string.

## 3. Export data-bearing elements

```http
POST /v2/workbooks/{workbookId}/export
Content-Type: application/json

{
  "elementId": "<element-id>",
  "format": { "type": "csv" }
}
```

Poll the returned query ID:

```http
GET /v2/query/{queryId}/download
```

Export every governed base table, transformed table whose grain matters,
editable input table after real rows exist, selected ledger, all-scope
comparison source, and KPI/pivot used in a numeric claim.

PNG answers what rendered. CSV answers which rows and values fed it. Both are
required.

## 4. Cardinality and uniqueness

Re-run the grain assertion established **before drafting** in
[`discover.md`](discover.md#verify-the-composed-source-grain-before-drafting).
The post-build export must agree with that recorded source evidence; do not
invent an expected count after seeing the result.

Write expected row counts before testing:

```text
union rows = source A rows + source B rows
scenario matrix = scenarios × baseline rows
selected scenario = one scenario × baseline rows
```

Export parent and child at the same instant. If an expected 180-row descendant
has 60 rows, inspect upstream control filters before rewriting joins or charts.
Filters propagate through every descendant.

Also assert uniqueness at the declared grain:

```text
CountDistinct(Scenario, Period, Planning Line) = row count
```

Duplicates usually indicate a join-key problem. Missing rows usually indicate
a filter or inner-join problem.

## 5. Numeric oracle

Choose source facts covering every major measure, period boundaries, subtotal
and margin formulas, positive and negative values, and at least one manual and
one driver-derived value.

Diff source and Sigma at native precision and report:

```text
checked N cells, mismatches M
```

Two rounded KPI cards displaying the same value are not parity evidence.

## 6. Writeback semantics

Run tests in the published view, not only draft.

### Published permission

Set each input table manually:

```text
element kebab → Set data entry permission → Only in published version
```

Publish and type into a real cell. This setting is absent from Code Rep.

### Linked-row correlation

After real rows exist, query/export the linked table. Confirm every inherited
key resolves to exactly one parent row; structural readback cannot detect
“multiple values” at runtime.

### Scenario isolation

1. Edit scenario A and record baseline, plan, and impact.
2. Switch to B; the same grain should remain baseline.
3. Switch back; A's edit should persist.

### Approval scope

Approve one entity/scenario. Confirm its status changes and an audit row
appears, while a second entity remains unchanged.

## 7. Control-scope assertions

For each control, write:

```text
what should change
what must not change
```

Then test both. If an active-scenario control also removes scenarios from an
all-scenario comparison, it filters a shared ancestor. Use formula scoping or
an independent all-scope lineage.

## 8. Agent verification

Ask a question whose answer is known from entered data. Verify the scenario or
entity, period, baseline, override, and signed impact. The agent must not claim
an action ran unless the user approved it.

If the agent has an action tool:

1. capture the authoritative target/log row count;
2. trigger the tool and **decline** approval — re-query and require delta `0`;
3. trigger it once and **approve** — re-query and require delta `1`;
4. verify the exact key, values, and attributed user on the new row/status.

The write target or its audit/read path must be in the agent's `dataSources`
so the agent can ground its own post-action response. A tool-success card and
conversation history prove neither row count nor persisted state. If the agent
claims a different count from the queried log, fail the agent test even when
the write itself behaved correctly.

## 9. Record evidence

Keep a small artifact beside the build:

```json
{
  "schemaVersion": 1,
  "workbookId": "…",
  "verifiedAt": "…",
  "structural": { "spec": "pass", "compile": "pass" },
  "renders": [
    { "page": "Workspace", "path": "renders/workspace.png", "verdict": "pass" }
  ],
  "cardinality": [
    { "element": "Plan Matrix", "expected": 180, "actual": 180, "verdict": "pass" }
  ],
  "numericOracle": { "checked": 48, "mismatches": 0 },
  "writeback": {
    "publishedEdit": "pass",
    "linkedCorrelation": "pass",
    "isolation": "pass",
    "approvalScope": "pass"
  },
  "agent": { "verdict": "pass", "question": "…" },
  "openIssues": []
}
```

Do not mark a gate `pass` without the actual observation: file, row count,
values, or UI result.
