<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Phase 3 — build the data model spec -->

## Phase 3 — Build the data model spec

Write the spec to `<WORK>/dm-spec.json`. Full schema is in
`refs/data-model-spec.md`.

### Critical rules

1. **Endpoint**: `POST /v2/dataModels/spec` — NOT `/v2/workbooks/spec`.
2. **`folderId` is required.** Find it via `GET /v2/files?typeFilters=workbook` — `parentId` on any of your workbooks.
3. **Top-level shape uses `pages: [{elements: [...]}]`, NOT a bare `elements: [...]` at root.** The API rejects root-level `elements` with `pages: Invalid array: undefined`. Even if your DM only has one logical page (typical), still wrap the elements under a single page:
   ```json
   {
     "name": "Orders",
     "folderId": "<folder>",
     "schemaVersion": 1,
     "pages": [
       {
         "id": "p-data",
         "name": "Data",
         "elements": [ { /* warehouse-table or sql element */ } ]
       }
     ]
   }
   ```
   This is the same shape `refs/data-model-spec.md` documents; the abbreviated examples below show only the element body — wrap them in `pages: [{elements: [...]}]` before POSTing.
3. **Column name special characters** — read `refs/column-gotchas.md`. Rename any column whose `name` contains `/` ("Country/Region" → `"Country"`, "State/Province" → `"State"`).
4. **Element name = formula prefix**. The `name` field on a DM element (e.g. `"Orders"`) becomes the prefix in all workbook formulas that reference it: `[Orders/Sales]`. Choose clean, stable names.
5. **Relationships go on the source element**, not the target. See `refs/data-model-spec.md`.
6. **Column formulas use the warehouse table name as prefix**: path `["DEMO_DB", "Tableau Test", "ORDERS"]` → formula `"[ORDERS/Column Name]"`.
7. **Tables first; Custom SQL only with a reason.** A Tableau
   `<relation type="text">` proves that the source used SQL, but does not make
   embedded SQL the preferred Sigma model. When its tables, joins, filters,
   and scalar derivations can be represented exactly as `warehouse-table`
   elements + relationships/calc columns, use that maintainable model and
   record an equivalence proof in `semantic-edits.json`. Preserve
   `source.kind: "sql"` when decomposition would change grain, filtering,
   aggregation, window behavior, vendor-specific semantics, or cannot yet be
   proven. Never discard SQL clauses merely to get a table-shaped model.

### Pre-POST structural provenance gates

The orchestrator writes and strictly evaluates two Tableau-local artifacts
before posting a new or reused data model:

- `relationship-coverage.json` — every source object-graph relationship must
  be completely wired. `wired < serialized`, `derived_via:"unwired"`,
  `partial:true`, or any positive `dropped_conditions` is a hard stop. A
  physical subset is not “close enough”: dropping a computed predicate widens
  the join and can recreate the field-reported flattened/pre-aggregated model.
  The relationship/key count is checked again against the posted DM readback,
  so a local converter ledger cannot hide an API-dropped or manual-spec edge.
- `sql-provenance.json` — every `source.kind:"sql"` element is labeled as
  source Custom SQL or a generated LOD/Top-N/window/blend helper. An
  unattributed SQL element stops before POST. A manual entry in
  `sql-provenance-overrides.json` requires `element_id`/`element_name`,
  `origin_type`, a non-empty `reason`, and a `proof` JSON path whose document
  has `match:true`.

Both artifacts are re-derived during finalization; editing the artifact cannot
turn a blocker green.

### Data-model metrics in workbook formulas

Metrics defined in a data-model element's `metrics[]` **do flow into workbook
elements** that source that model element. Reference them through the reserved
namespace `[Metrics/<metric name>]` (name, not ID). `[Base/<metricName>]`,
`[Base/<metricId>]`, and `[<element name>/<metric name>]` are column lookups;
their `400 Dependency not found` response does not establish that metrics are
unavailable.

The orchestrator already writes the readback-confirmed metric census to
`<WORK>/metrics.json` and binds equivalent chart/KPI measures through
`[Metrics/<name>]`. If a metric has the exact same name as a column on its
element, Sigma can omit that element's metrics from readback; the binder
intentionally keeps those measures inline. Do not override that safeguard.

### When to use a Custom SQL element instead of a calc column

> **Custom-SQL operators are already sanitized by the converter — do NOT grep the `.twb` to "check" an operator.** Two independent Tableau serialization quirks corrupt custom-SQL comparison operators, and the converter fixes BOTH: (1) `WHERE`-clause operators stored XML-escaped (`&lt;=`), including double-escaped round-trips (`&amp;lt;=`) — decoded to a fixed point; (2) Tableau's `_.fcp.ObjectModelEncapsulateLegacy` wrapper **doubles** operators inside its CDATA (`<`→`<<`, `>=`→`>>=`; field-observed on a real customer calc, 5/5 doubled, zero entities) — collapsed back (`<<`→`<`, `>>=`→`>=`) with a loud verify warning. So the emitted `statement` always carries real operators. If you ever still see `&lt;`/`&gt;` or the human-eye artifacts **`<<` / `>>=`**, treat it as a stored serialization artifact — normalize in place and move on. Do NOT open the raw `.twb` to investigate; it is a 10-minute dead end (the converter handles it — see `converter/PROVENANCE.json`).

> **Sigma window functions silently fail in DM calc columns and in workbook master (grouping-table) calc columns** — `CumulativeSum`, `Rank`, `Lag`, etc. POST successfully but resolve as `error` on GET, and the `*Over` family (`SumOver`/`RankOver`/`MaxOver`/...) is `Unknown function` in every spec context. **But they are FIRST-CLASS as CHART-element viz formulas on the yAxis** (WINPROBE-validated 2026-06-12, 930/930 cells): `build-charts-from-signals.rb` auto-emits the whole mainstream window/table-calc family that way — `RUNNING_*`→`Cumulative*`, bounded `WINDOW_*`→`Moving*`, share→`PercentOfTotal(agg, "grand_total")`, pareto→`CumulativeSum(PercentOfTotal(...))`, `RANK*`→`Rank/RankDense/RankPercentile(agg, "desc")`, `INDEX()`→`RowNumber()`, `LOOKUP(±n)`→`Lag/Lead`, unbounded `WINDOW_MAX/MIN/SUM`/`TOTAL`→hidden two-level grouped helper. Cumulative/rank formulas follow the chart's `xAxis.sort` (Tableau `<computed-sort>` is carried via a hidden companion measure) and auto-partition by the chart color dim. **Full mapping table + the broadcast-down/week-anchor gotchas: `refs/window-functions.md`.** The design rule stands: never write window functions as DM or master calc columns.

> **`{FIXED ...}` LODs are AUTO-TRANSLATED — no Custom SQL needed.** When a
> `{FIXED [dims] : AGG([m])}` calc is plotted as a chart/KPI measure,
> `build-charts-from-signals.rb` emits a hidden TWO-LEVEL grouped helper
> element on the Data page (`visibleAsSource:false`; inner grouping = the
> FIXED dims computing the LOD aggregate, outer grouping = the chart's dims
> computing the 2nd-stage aggregate over the inner GROUP values) and the chart
> sources the helper, `Max()`-ing the outer calc (a chart re-aggregates a
> grouped source at BASE grain with group calcs replicated per row — Max over
> identical replicas is exact; verified live 2026-06-12). ⚠ Carried chart dims
> must be functionally dependent on the FIXED dims (e.g. Customer Segment per
> Customer Id) — the build emits a per-chart verify warning. The same helper
> machinery handles **grain-aware averages**: `Avg` of a dim-table column
> (Tableau relationship semantics evaluate it at the dim table's NATIVE grain,
> including entities with no fact rows) sources the DM dim element directly.
> NEVER write these as `SumOver`/`CountOver` master or DM calc columns — they
> silently error.

### LOD "refuse to guess" contract — gate-enforced (gate 17, exit 24; #423)

An `{FIXED/INCLUDE/EXCLUDE}` calc that the synthesis above does NOT catch
(cross-table grain, unresolved dims, no view context) must **never** be
name-matched to a look-alike raw column or dropped quietly — both produce
silently wrong dashboards (field failure: 5 of 12 `{FIXED entity:
COUNTD(...)}` measures aliased to unrelated raw flag columns, 7 dropped, zero
errors anywhere). The post-convert audit enforces this:

- `migrate-tableau.rb` derives `<workdir>/lod-audit.json`
  (`scripts/lib/lod_audit.rb`) after the wb-spec is built: one entry per
  source LOD calc, classified **lod-synth** / **manual-residue** /
  **reference-derived** (resolved) vs **suspect-alias** (an emitted column
  carries the calc's name but reads a base column NOT in the LOD expression's
  own reference set) or **silently-dropped** (no translation, no residue
  declaration). An empty ledger is still written — gate evidence the audit ran.
- `assert-phase6-ran.rb` **gate 17 (exit 24)** refuses GREEN while any entry
  is unresolved — and also when the ledger is missing but `calc-fields.json`
  censuses an LOD calc. No skip flag.
- Sanctioned resolutions: build the documented translation (helper element /
  grouped Custom SQL above) or declare the calc in `manual-residues.json`,
  then re-run `ruby scripts/audit-lod-calcs.rb --workdir <W>` (it
  re-classifies); a hand-authored or operator-accepted entry records its
  evidence in the ledger via
  `audit-lod-calcs.rb --resolve <i> --how <manual|waived> --reason "..."`
  (same pattern as `probe-join-keys.rb` / gate 16).

Any Tableau calc whose `requires_custom_sql: true` (from Phase 1e) — that is, a **manual window residue** (`WINDOW_MEDIAN/PERCENTILE/CORR/COVAR(P)/VAR(P)/STDEVP`, `PREVIOUS_VALUE`, `SIZE`, `FIRST`, `LAST`, `RANK_UNIQUE/MODIFIED`, or a compute-using/addressing variant beyond Table(Across)/simple partitions) or an `{INCLUDE/EXCLUDE}` LOD (those need the chart-grouping context) — must be implemented as a **Sigma Custom SQL data-model element**. (The mainstream `WINDOW_*`/`RUNNING_*`/`RANK*`/`INDEX`/`LOOKUP`/`TOTAL` family no longer routes here — it is auto-emitted as Sigma-native chart formulas, `refs/window-functions.md`.)

> **Tile binding is gate-enforced (G6).** Routing the calc here is only half the job — the residue must be BOUND to the tile that plots it. `<workdir>/manual-residues.json` (written by build-charts) lists each plotted residue with its Tableau formula + an `OVER()` SQL skeleton. For each entry: (1) add the Custom SQL element to the DM spec and PUT it (`post-and-readback.rb --type datamodel --update-id <dmId>`), (2) repoint the tile's measure column at the new element's output column (wb-spec PUT), (3) set `"status": "built"` on the ledger entry. The orchestrator blocks pass 1 (exit 16) and `assert-phase6-ran` refuses GREEN (gate 15, exit 22) while any entry is `"unbuilt"`.

```json
{
  "id": "el-orders-windowed",
  "kind": "table",
  "name": "Orders With Window Calcs",
  "source": {
    "connectionId": "<connection-id>",
    "kind": "sql",
    "statement": "SELECT o.ORDER_ID, o.REGION, o.SALES,\n  SUM(o.SALES) OVER (PARTITION BY o.REGION) AS REGION_TOTAL_SALES,\n  RANK() OVER (PARTITION BY o.REGION ORDER BY o.SALES DESC) AS SALES_RANK_IN_REGION,\n  SUM(o.SALES) OVER (ORDER BY o.ORDER_DATE ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RUNNING_SALES\nFROM ANALYTICS.PUBLIC.ORDERS o"
  },
  "columns": [
    { "id": "c-order-id",      "name": "Order Id",            "formula": "[Custom SQL/ORDER_ID]" },
    { "id": "c-region",        "name": "Region",              "formula": "[Custom SQL/REGION]" },
    { "id": "c-sales",         "name": "Sales",               "formula": "[Custom SQL/SALES]" },
    { "id": "c-region-total",  "name": "Region Total Sales",  "formula": "[Custom SQL/REGION_TOTAL_SALES]" },
    { "id": "c-sales-rank",    "name": "Sales Rank in Region","formula": "[Custom SQL/SALES_RANK_IN_REGION]" },
    { "id": "c-running-sales", "name": "Running Sales",       "formula": "[Custom SQL/RUNNING_SALES]" }
  ]
}
```

Key points:
- `source.kind` is `"sql"` (not `"warehouse-table"`).
- `source.statement` is the raw SQL text (the field name is `statement`, NOT `sql`). Use the warehouse dialect for the underlying connection (Snowflake, BigQuery, etc.).
- Column formula prefix is `[Custom SQL/<ALIAS_FROM_SELECT_LIST>]`. The alias is whatever you wrote in the `SELECT ... AS NAME` clause. **Use UPPERCASE aliases** (matches Snowflake's default identifier casing); Sigma's column lookup is case-sensitive against the SQL output.
- Every column you want to expose in the DM needs both a SELECT-list entry in the SQL AND a corresponding `columns[]` entry on the DM element.
- Translation hints from `extract-calc-fields.rb`:
  - `RUNNING_*` / bounded `WINDOW_*` / `RANK*` / `INDEX` / `LOOKUP` / `TOTAL` — **do NOT route here anymore**: auto-emitted as Sigma-native chart viz formulas (`refs/window-functions.md`). The ANSI `OVER(...)` forms below are the fallback ONLY for the manual residues (`WINDOW_MEDIAN`/`WINDOW_PERCENTILE`/`PREVIOUS_VALUE`/`SIZE`/non-default addressing): e.g. `WINDOW_MEDIAN(SUM([X]))` → `MEDIAN(X) OVER (<partition>)`, `PREVIOUS_VALUE` → recursive logic in SQL.
  - `{FIXED [Dim] : SUM([X])}` → `SUM(X) OVER (PARTITION BY Dim)` or a pre-aggregated subquery joined back — **fallback only**: when the LOD is plotted as a chart/KPI measure it is AUTO-TRANSLATED via the hidden two-level helper element (see the callout above), no Custom SQL needed
  - **Nested LODs** (`{FIXED A : AVG({FIXED A, B : SUM([X])})}`) → a helper-element CHAIN, not one formula: innermost LOD = helper element 1 (grouped by its dims, aggregate as `Value`), each outer level consumes `[LOD Helper k/Value]` via a relationship on the shared dims. `build-charts-from-signals.rb` decomposes these automatically into `<out>-lod-chains.json` (innermost first) — build one grouped element (or Custom SQL `GROUP BY` subquery) per level. **Each outer level's source MUST carry `groupingId` pointing at the inner element's grouping** — a plain `{kind: table, elementId}` source reads BASE-grain rows with the aggregate repeated per row, so outer Avg/Median/Count silently come out row-weighted (caught live: 969.82 row-weighted vs 687.81 correct on the demo ORDER_FACT). Live-verified pattern (exact parity vs warehouse SQL), 2026-06-11.

When a workbook mixes plain calcs with window calcs, you can have BOTH kinds of DM elements in the same data model: one `warehouse-table` element for everything plain, plus one or more `sql` elements for the window/LOD calcs, related by key. Charts source from whichever element has the columns they need.

> **DM PUT reassigns element IDs.** Combining a `warehouse-table` element with a `sql` element in the same DM works fine, but every PUT of the DM spec churns IDs — so plan to capture IDs once with `post-and-readback.rb`, build the workbook from those IDs, and avoid editing the DM in flight.

### Translate Tableau calc fields here

Each calc from `calc-fields.json` (Phase 1e) becomes a DM calc column (or a workbook-level
calc on the master table, depending on grain). For calc columns that wrap a NULLABLE source
in an IF/ELSEIF chain, **wrap with `Coalesce` to match Tableau's null-fallthrough behavior**.

Example — Tableau:

```
IF [Lifetime Revenue] >= 5000 THEN "Platinum" ELSEIF >= 2000 THEN "Gold" ELSEIF >= 500 THEN "Silver" ELSE "Bronze" END
```

Sigma DM calc column on Order Fact (since the bucket depends on a joined dim):

```
If(Coalesce(Lookup([Customer Dim/Lifetime Revenue], [Customer Key], [Customer Dim/Customer Key]), -1) >= 5000, "Platinum",
  If(Lookup([Customer Dim/Lifetime Revenue], [Customer Key], [Customer Dim/Customer Key]) >= 2000, "Gold",
    If(Lookup([Customer Dim/Lifetime Revenue], [Customer Key], [Customer Dim/Customer Key]) >= 500, "Silver", "Bronze")))
```

Without `Coalesce(-1)` orphan-joined rows produce a NULL bucket instead of falling into "Bronze"
the way Tableau's ELSE does — and parity will diverge.

### Join-cardinality ledger + probe (`join-plan.json`, gate 16 / exit 23)

**Sigma's `Lookup()` returns ONE ARBITRARY match per key.** Every `Coalesce(…,
Lookup([Target/X], [key], [Target/key]))` the converter synthesizes for a federated
join — and every federated join itself — silently assumes the target/right side is
**unique at the key grain**. When it isn't (field failure: target at
user×date×line-item grain, key at user×date), every aggregate over the looked-up
column undercounts with zero errors anywhere. The mirror risk: never delete a
"no-op" LEFT JOIN without the same proof — a non-unique right side means the join
was fanning out rows.

The orchestrator derives `<WORK>/join-plan.json` right after writing `dm-spec.json`
(`scripts/lib/join_plan.rb`): one entry per federated `.twb` join + per synthesized
Lookup, each `status: "unprobed"` with `grain_assumption: "right unique on keys"`.
An empty ledger is still written — its presence is the gate's evidence. Then prove
each assumption against the warehouse:

```bash
ruby scripts/probe-join-keys.rb --workdir <WORK> --connection-id <id>   # GROUP BY keys HAVING COUNT(*)>1 + totals
```

Entries become `unique` (done), `non-unique` (sample duplicate keys + counts
recorded; FATAL, exit 2), or `error`. A non-unique entry has exactly two sanctioned
resolutions, recorded as ledger evidence via
`probe-join-keys.rb --resolve <i> --how <preaggregated|waived> --reason "…"`:
**(a) pre-aggregate** — add a grouped helper element at the key grain and repoint the
Lookup at it; **(b) operator escalation** — a named human accepts the arbitrary-match
risk. The final gate (`assert-phase6-ran.rb` gate 16) exits 23 while any entry is
unproven or unresolved, and also when `join-plan.json` is missing on a run whose
`dm-spec.json` contains `Lookup(`. No skip flag — the recorded resolution is the
only escape.

### Equivalence probe for semantic edits (`semantic-edits.json`, gate 20 / exit 27)

**Any structural edit to source semantics — dropping a join, collapsing a table,
rewriting a filter — is forbidden without a recorded equivalence proof, BEFORE the
edit ships** (PLAN-v3 PR-8; the field case: a LEFT JOIN on a non-unique flag key
deleted as "provably no-op" with zero verification — the join was fanning out rows,
so the "no-op" changed every downstream count. Corpus twin:
`corpus/tableau/join-elision-fanout`). "Provably no-op" is proven by measurement,
never asserted:

```bash
ruby scripts/probe-equivalence.rb --workdir <WORK> \
  --edit "drop LEFT JOIN FACT->DIM (FLAG=FLAG)" \
  --claim "joined table contributes no shelf column; elision is a no-op" \
  --grain ORDER_ID --measures AMOUNT \
  --before-sql "<the statement WITH the join>" --after-sql "<without>" \
  --connection-id <id>            # or --fixture DIR offline
```

Both sides run ONE probe statement through the same warehouse seam as
`probe-join-keys.rb` / `run-ground-truth.rb`: `COUNT(*)` (fan-out/loss),
`COUNT(DISTINCT grain)` (declared-grain cardinality), and a `SUM` checksum per
numeric measure (value drift; element mode `--before-element`/`--after-element`
extracts the SQL and derives the `Sum([X])` measures from the spec). The result is
recorded in `<WORK>/semantic-edits.json`; a mismatch is FATAL (exit 2) with both
sides' numbers printed. The final gate (`assert-phase6-ran.rb` gate 20) exits 27
while any declared entry lacks a proof or its proof says `match:false`. No skip
flag and **no waiver path** — a mismatched edit never ships (revert or redesign; an
intentionally-different rewrite is a user-initiated scope change, not an
equivalence claim).

**Withdrawing a refuted edit that was NOT applied.** When the probe REFUTES the
claim and you therefore do not ship the edit, clear the blocking entry with

```bash
ruby scripts/probe-equivalence.rb --workdir <WORK> \
  --withdraw "<edit_description>" --reason "<why the refuted edit was not applied>"
```

The entry moves verbatim to the ledger's `withdrawn[]` array — its refuted proof
is preserved as evidence, plus `withdrawn_reason` + `withdrawn_at` — and gate 20
ignores it but reports it informationally ("N withdrawn edit(s) — refuted and not
applied"). Only a *refuted* entry is withdrawable: an unproven one must be
re-probed first (a claim is measured before it is withdrawn), and a proven one
doesn't block. Never hand-edit the ledger. Honest limit: withdrawal *attests* the
edit was not applied — whether its SQL nonetheless shipped is not mechanically
detectable; gates 16/18 remain the numeric net.

**Honest limit — declared edits only.** Nothing mechanical can see an edit nobody
recorded, so the gate enforces that *declared* edits are proven; the
operating-contract rule (`refs/operating-contract.md` §Structural edits) makes the
declaration itself mandatory. The net for an undeclared edit is gate 16 (the join
was on the ledger before anyone touched it) plus gate 18 (ground-truth SQL derives
from the `.twb` signals independently of the built spec — a silently dropped join
diverges there).

### Validate before posting

```bash
ruby scripts/validate-spec.rb --type datamodel <WORK>/dm-spec.json
```

Catches: formula prefix mismatches, bare refs not matching a sibling, `kpi`/`pie`/`donut` kind
mistakes, `rgb(...)` color strings (Cloudflare WAF blocks), missing yAxis on
bar/line/area/combo/scatter, missing color+value on pie/donut, donut `holeValue.id` matching
`value.id` (silent element drop), pivot-table missing rowsBy (single grand-total row), and
nested-If on date functions without IsNull guard.

Exit 0 = clean, exit 1 = errors printed to stdout.

---

