<!--
Auto-generated from SKILL.md by tools/gen-agent-variants.rb.
Do not edit by hand — edit SKILL.md and re-run: ruby tools/gen-agent-variants.rb --all
-->

> Scan Sigma workbooks for custom SQL elements, dedupe across workbooks, build or reuse Sigma data models, then repoint the workbooks via the v3alpha `:swapSources` endpoint. Use when you want to find ad-hoc SQL in workbooks and promote it to one reusable data model per unique query.

# Custom SQL → Data Model

End-to-end flow:

1. Scan workbooks for `source.kind: "sql"` elements (Phase 1).
2. Scan data models to index every existing SQL or warehouse-table source (Phase 1.5).
3. Group manifest entries by normalized SQL; for each group, decide **reuse**
   an existing DM element or **build** a new one (Phase 1.5 → plan).
4. Build DMs only for the to-build groups (Phase 2 / 3 / 4).
5. Drive `:swapSources` from the plan, one workbook at a time (Phase 5).
6. Audit and repair residual `[Prefix/SNAKE_CASE]` formulas left behind by
   Sigma's auto-match (Phase 6).

The key win versus the legacy GET/mutate/PUT approach: one workbook with N
SQL elements is one API call with N entries in `sourceMapping`, and the
auto-match handles formula rewrites — except for the rough edges Phase 6
catches.

---

## Prerequisites

Required env vars: `SIGMA_BASE_URL`, `SIGMA_CLIENT_ID`, `SIGMA_CLIENT_SECRET`

Always chain the token eval with `&&` so the token is live for all subsequent
commands in the same block:

```bash
eval "$(bash scripts/get-token.sh)"
```

> Tokens expire after ~1 hour. **The Ruby scripts in this skill now auto-refresh on 401** via `scripts/lib/sigma_rest.rb` — full-site scans on large orgs (hundreds of workbooks, sometimes >1 hour total) no longer fail mid-run. If you still see `Token missing or malformed` after a refresh, re-run `eval "$(bash scripts/get-token.sh)"` manually.

---

## Phase 1 — Scan workbooks for custom SQL

```bash
eval "$(bash scripts/get-token.sh)" && ruby scripts/scan-workbooks.rb
```

Reads every workbook spec in the org, finds all elements where
`source.kind == "sql"`, and writes `/tmp/custom-sql-manifest.json`.

Each entry:

```json
{
  "workbook_id":   "25e21c63-...",
  "workbook_name": "Custom Sql Test",
  "folder_id":     "57e59735-...",
  "element_id":    "6YSI-SjSmz",
  "element_name":  "Customer Dim SQL",
  "connection_id": "cb2f5180-...",
  "sql":           "select * from CSA.TJ.CUSTOMER_DIM",
  "column_count":  18
}
```

`element_id` is the same value as the `customSqlId` consumed by `:swapSources`
in Phase 5 — no extra lookup needed.

Review the findings and confirm with the user which workbooks to convert.

---

## Phase 1.5 — Index existing DMs and plan dedup

### Scan DMs

```bash
eval "$(bash scripts/get-token.sh)" && ruby scripts/scan-data-models.rb
```

Writes `/tmp/dm-sql-index.json`. The scanner emits one entry per existing DM
element of either kind:

- `kind: "sql"` — indexed by normalized SQL text
- `kind: "warehouse-table"` — indexed by a synthetic `select * from <path>`
  string, so trivial `SELECT *` custom-SQL maps to the right table-backed DM

Each entry also tracks `dmElementCount` (total elements in that DM) so the
planner can prefer focused DMs over kitchen-sink ones.

### Build the swap plan

```bash
ruby scripts/plan-dedup.rb
```

Writes `/tmp/swap-plan.json`. The planner:

1. Groups manifest entries by normalized SQL (whitespace/case-collapsed, but
   no semantic reformatting — copy/paste duplicates collapse, semantically-
   equivalent rewrites do not).
2. For each group, looks up the DM index. If a candidate exists, marks the
   group `status: "existing"` and picks the best target (same connection,
   fewest DM elements, stable tiebreak). Otherwise marks it `to-build`.
3. Prints a human-readable summary:

```
[REUSE] group 1: 3 occurrence(s)
  SQL: select * from csa.tj.customer_dim
    - Custom Sql Test / Custom Sql Test SQL (6YSI-SjSmz)
    - Dedup Test Alpha / Customer Source  (el-customers)
    - Dedup Test Beta  / Customer Source  (el-customers-dup)
  -> Customer Dim / Customer Dim  (54d1f450-... / ROZzp25zn9)

[BUILD] group 2: 1 occurrence(s)
  SQL: with monthly as ( select employee_id, date_trunc('month', date) as month, …
    - Dedup Test Alpha / OT Summary (el-ot-summary)
  -> needs new DM (connection cb2f5180-..., folder 57e59735-...)

Summary: 3 unique SQL strings → 1 reuse, 2 build. 5 total swap actions.
```

Confirm with the user before continuing — a `[REUSE]` decision is only as
good as the picked candidate. If the heuristic picked the wrong DM, edit
`/tmp/swap-plan.json` to point `target.dataModelId` / `target.elementId` at
the preferred DM before Phase 5.

---

## Phase 2 — Build the data models for to-build groups

Build one DM per `to-build` group in the plan. Phases 1.5 → 2 → 3 → 4 — only
the to-build groups need this; reuse groups skip straight to Phase 5.

### One DM per to-build group

A group is "one unique SQL across N workbook occurrences" — build a single
DM with one element wrapping that SQL, then the same DM/element pair gets
referenced by every occurrence in the swap call. Do not build per-workbook.

### Try the converter first

For each to-build group:

```
mcp__sigma-data-model__convert_sql_to_sigma
  statements    = [{"name": "<group label>", "sql": "<representative sql>"}]
  connection_id = "<connection_id from manifest>"
  database      = ""
  schema        = ""
```

`database` / `schema` are inferred from the SQL.

### What the converter produces

| SQL type | Converter output | Action |
|---|---|---|
| `SELECT *` / `SELECT cols` from one table | Single `warehouse-table` element, no columns | Fetch columns — see below |
| `SELECT` with JOINs | Multiple `warehouse-table` elements + relationships | Use as-is |
| `SELECT` with aggregates (GROUP BY) | Elements + `metrics` array | Check child usage — see note below |
| CTEs (`WITH ...`) | Element with `path: ["CTE_NAME"]` — fake table | Discard — build manually |
| Subqueries / implicit joins | `Custom SQL` element | Use as-is |

> **Aggregated SQL with GROUP BY**: The warehouse-table + metrics shape only
> exposes GROUP BY dimensions as direct columns; aggregates land in `metrics`.
> If child workbook elements reference aggregate columns as direct columns,
> the DM page must use a `sql` source instead — build manually with the full
> SQL and enumerate all output columns.

### Column display names — matter for Phases 5 + 6

The swap auto-matches columns between source and target by **display name**,
case- and punctuation-insensitive (`CUSTOMER_KEY` ↔ `Customer Key`). Most
columns match cleanly. **The auto-match has known silent misses** — see
Phase 6 — but those are post-swap-repairable, so don't over-engineer at
build time. Just ensure the DM column `name` fields are reasonable display
names ("Total Hours", "OT Hours", …), not SQL aliases.

### Column formula rules (for the DM itself)

| Source kind | Formula inside the DM element | Formula in workbook referencing the DM |
|---|---|---|
| `warehouse-table` | `[TABLE_NAME/Column Name]` | `[DM Element Name/Column Name]` |
| `sql` | `[Custom SQL/SQL_ALIAS]` | `[DM Element Name/Column Display Name]` |

**Key rules:**
- Inside a `sql` DM element, the formula prefix is always the literal string `Custom SQL` —
  never the element's own `name` field.
- Workbook formulas reference DM columns by **display name** (the column's `name` field),
  not by server-assigned column `id`. Display names are stable across DM PUTs;
  column IDs are reassigned every PUT.

```python
def col(sql_alias, display=None):
    title = display or sql_alias.replace("_", " ").title()
    return {"id": sql_alias, "name": title, "formula": f"[Custom SQL/{sql_alias}]"}
```

### SELECT * — converter produces no columns

When the converter returns a `warehouse-table` element with no columns:

1. `mcp__sigma-mcp-v2__search query="<TABLE_NAME>" entityTypes=["table"]` → inodeId
2. `mcp__sigma-mcp-v2__describe object={"type":"table","inodeId":"<inodeId>"}` → column names
3. Build columns with `formula: [TABLE/<col>]`, `name: "<Title Case>"`.

### CTEs — discard converter output, build manually

When the converter returns `path: ["CTE_NAME"]`, that CTE name is being used
as a fake warehouse table path. Discard the converter output and build a
`sql` element by hand with the full CTE in `source.statement`. Enumerate the
output columns from the final `SELECT`.

### Set folderId

Always set `folderId` from the plan's `representative.folder_id` (taken
from the source workbook's own folder — guaranteed real).

---

## Phase 3 — POST the data model

```bash
eval "$(bash scripts/get-token.sh)" && \
curl -s -X POST \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/<name>-datamodel-spec.json \
  "$SIGMA_BASE_URL/v2/dataModels/spec" \
  | ruby -r yaml -r json -r date -e "
    d = YAML.safe_load(STDIN.read, permitted_classes: [Date, Time])
    if d['dataModelId']
      puts 'SUCCESS  dataModelId: ' + d['dataModelId'].to_s
    else
      puts 'ERROR: ' + d.inspect
    end
  "
```

> Response is YAML — never pipe to `jq`.

After POST, fetch the spec back with `Accept: application/json` to learn the
server-assigned element IDs:

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" -H "Accept: application/json" \
  "$SIGMA_BASE_URL/v2/dataModels/<dataModelId>/spec" \
  | jq '.pages[].elements[] | {id, name}'
```

Update the plan: fill in `target.dataModelId` / `target.elementId` on every
`to-build` entry with the new IDs.

---

## Phase 4 — Validate the new DMs with MCP

For each newly-built DM:

```
mcp__sigma-mcp-v2__describe
  object = {"type": "datamodel", "dataModelId": "<dmId>"}
```

Then for each element listed:

```
mcp__sigma-mcp-v2__describe
  object = {"type": "datamodel-element", "dataModelId": "<dmId>", "elementId": "<elId>"}
```

```
mcp__sigma-mcp-v2__query
  query = { "type": "datamodel", "dataModelId": "<dmId>",
            "sql": "SELECT * FROM \"datamodel\".\"<elId>\" LIMIT 3" }
```

Column identifiers in the SQL are the server-assigned IDs from the
`describe` DDL, not display names.

If anything fails, fix and re-PUT before Phase 5.

---

## Phase 5 — Repoint workbooks via `:swapSources`

Endpoint: `POST /v3alpha/workbooks/{workbookId}:swapSources`.

The call atomically:

- flips `source.kind: "sql"` → `"data-model"` on each root SQL element,
- rewrites root column formulas from `[Custom SQL/SQL_ALIAS]` to
  `[DM Element Name/Display Name]`,
- rewrites child element formulas that referenced the root by name.

### Step 1 — Name unnamed root SQL elements first (CRITICAL)

If a root SQL element has `name: null` (or empty string), child elements
that referenced it used the implicit prefix `"Custom SQL"`. The swap rewrites
the root's own formulas correctly but **breaks child formulas to
`[Missing node/...]`** — and **reversing the swap does not fix them**; the
"Missing node" placeholder is sticky and requires a manual spec edit to
recover.

**Always set a real name on each unnamed root SQL element before swapping**,
and update any child formulas that used the `Custom SQL` prefix to use the
new name. Then the swap auto-rewrites cleanly.

```ruby
require 'json'
WB = '<workbookId>'
raw = `curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" -H "Accept: application/json" "$SIGMA_BASE_URL/v2/workbooks/#{WB}/spec"`
spec = JSON.parse(raw)

manifest = JSON.parse(File.read('/tmp/custom-sql-manifest.json'))
new_names = manifest
  .select { |m| m['workbook_id'] == WB }
  .to_h    { |m| [m['element_id'], m['element_name']] }

# Children that referenced a root we're renaming
child_parent = {}
spec['pages'].each do |page|
  page['elements'].each do |el|
    parent = el.dig('source', 'elementId')
    child_parent[el['id']] = parent if parent && new_names.key?(parent)
  end
end

spec['pages'].each do |page|
  page['elements'].each do |el|
    if new_names.key?(el['id'])
      el['name'] = new_names[el['id']] if el['name'].to_s.strip.empty?
    elsif (parent = child_parent[el['id']])
      new_prefix = new_names[parent]
      (el['columns'] || []).each do |col|
        col['formula'] = col['formula']&.gsub('[Custom SQL/', "[#{new_prefix}/")
      end
    end
  end
end

%w[workbookId url ownerId createdBy updatedBy createdAt updatedAt latestDocumentVersion documentVersion].each { |k| spec.delete(k) }
File.write('/tmp/wb-pre-swap.json', JSON.pretty_generate(spec))
```

```bash
curl -s -X PUT \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d @/tmp/wb-pre-swap.json \
  "$SIGMA_BASE_URL/v2/workbooks/<workbookId>/spec"
```

> Skip this step only if every root SQL element already has a non-empty
> `name` AND no child formula references `[Custom SQL/...]`.

### Step 2 — Call `:swapSources` per workbook, batched

For each workbook in the plan, batch all of that workbook's swaps into a
single call. The example below assumes the plan groups Alpha's two SQL
elements together; the planner output gives you the mapping.

```bash
WB="<workbookId>"
curl -s -X POST \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{
    "sourceMapping": [
      { "from": { "type": "custom-sql", "customSqlId": "<element_id 1>" },
        "to":   { "type": "data-model", "dataModelId": "<dmId 1>", "elementId": "<elId 1>" } },
      { "from": { "type": "custom-sql", "customSqlId": "<element_id 2>" },
        "to":   { "type": "data-model", "dataModelId": "<dmId 2>", "elementId": "<elId 2>" } }
    ]
  }' \
  "${SIGMA_BASE_URL}/v3alpha/workbooks/${WB}:swapSources"
```

> **Shell gotcha**: the URL contains a `:` which collides with parameter
> expansion in zsh/bash. Always wrap the variable in braces:
> `${WB}:swapSources`, not `$WB:swapSources` (`bad substitution` error).

A successful response is HTTP 200 with body `{}`.

### Step 3 — Verify the swap had effect

The endpoint has two specific behaviors to guard against:

| Behavior | Symptom | Mitigation |
|---|---|---|
| Bogus `from.customSqlId` (typo or stale) | HTTP 200, `{}` — silent no-op | Re-list `/v2/workbooks/{id}/sources` and assert no `custom-sql` entries remain |
| Bogus `to` (e.g. wrong DM `elementId`) | HTTP 400 `"Element X not found in data model"` | Match each plan entry's `target` against the Phase 3 readback |

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "${SIGMA_BASE_URL}/v2/workbooks/${WB}/sources" | jq '[.[] | .type] | unique'
# expect: ["data-model"] (or empty / no custom-sql)
```

### Column name misalignment — `columnMapping` override (proactive)

The swap auto-matches columns by display name, case- and punctuation-
insensitive. If you know in advance that some DM column display names won't
match the custom-SQL aliases (and won't auto-resolve), pass `columnMapping`
in the same request:

```json
{
  "sourceMapping": [
    {
      "from": { "type": "custom-sql", "customSqlId": "..." },
      "to":   { "type": "data-model", "dataModelId": "...", "elementId": "..." },
      "columnMapping": [
        { "fromColumn": ["C_KEY"],     "toColumn": ["customer_key"] },
        { "fromColumn": ["TOTAL_REV"], "toColumn": ["lifetime_revenue"] }
      ]
    }
  ]
}
```

For cases you didn't anticipate, Phase 6 cleans up after the fact.

---

## Phase 6 — Audit and repair residual SNAKE_CASE formulas

The auto-match has documented silent misses: short uppercase aliases and
some token patterns survive the swap as `[Prefix/SNAKE_CASE]` even though
the DM element's column display name is something like `OT Hours`. The
broken formula:

- Does **not** error at PUT time.
- Surfaces at query time as a value-cell error: `Column "[OT Summary/OT_HOURS]" does not exist`.
- Cascades into child elements that referenced the workbook column by its
  display name (`[OT Summary/OT Flag]`) — the child returns the same error
  string as a data value, not a query failure.

The audit script walks each workbook's elements, finds formulas of the form
`[Prefix/UPPERCASE_TOKEN]` where the local sibling column's `id` matches
the token but its display `name` differs, and rewrites the suffix to the
display name. Warehouse-table prefixes are left alone.

```bash
# audit specific workbooks
ruby scripts/audit-formulas.rb <workbookId> [<workbookId> ...]

# or audit every workbook touched by the current plan
ruby scripts/audit-formulas.rb --from-plan
```

The script reports `N formula(s) repaired` per workbook. Idempotent — safe
to re-run.

After audit, re-validate with MCP to confirm the cells now return data, not
error strings:

```
mcp__sigma-mcp-v2__query
  query = {"type": "workbook", "workbookId": "<wb>",
           "sql": "SELECT <cols> FROM \"workbook\".\"<elementId>\" LIMIT 3"}
```

---

## Manual fallback (legacy, no `:swapSources`)

If `:swapSources` doesn't fit (e.g., a partial swap, or a column remap that's
easier as a spec edit), the older GET/mutate/PUT approach still works. The
cost: you keep prefix/display-name rewrite logic in sync with the DM, you
must strip response-only fields, and layout edits may get rebuilt server-
side. Prefer `:swapSources` whenever it works.

```ruby
require 'yaml'; require 'json'; require 'date'
spec = YAML.safe_load(File.read('/tmp/wb-spec.yaml'), permitted_classes: [Date, Time])

conversions = {
  '<root_element_id>' => {
    dataModelId: '<dataModelId>',
    elementId:   '<server-assigned-element-id>',
    elementName: '<DM element name, e.g. Customer Dim>'
  }
}

root_ids = conversions.keys.to_set
child_parent = {}
spec['pages'].each do |page|
  page['elements'].each do |el|
    parent = el.dig('source', 'elementId')
    child_parent[el['id']] = parent if parent && root_ids.include?(parent)
  end
end

spec['pages'].each do |page|
  page['elements'].each do |el|
    if (conv = conversions[el['id']])
      el['name']   = conv[:elementName]
      el['source'] = { 'kind' => 'data-model', 'dataModelId' => conv[:dataModelId], 'elementId' => conv[:elementId] }
      (el['columns'] || []).each do |col|
        display = col['id'].split('_').map(&:capitalize).join(' ')
        col['formula'] = "[#{conv[:elementName]}/#{display}]"
      end
    elsif (parent = child_parent[el['id']])
      new_prefix = conversions[parent][:elementName]
      (el['columns'] || []).each { |c| c['formula'] = c['formula']&.gsub('[Custom SQL/', "[#{new_prefix}/") }
    end
  end
end

%w[workbookId url ownerId createdBy updatedBy createdAt updatedAt latestDocumentVersion].each { |k| spec.delete(k) }
File.write('/tmp/wb-updated.json', JSON.pretty_generate(spec))
```

```bash
curl -s -X PUT \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/wb-updated.json \
  "$SIGMA_BASE_URL/v2/workbooks/<workbookId>/spec"
```

---

## Data model swap-sources

The same v3alpha shape works for DMs:

```
POST /v3alpha/dataModels/{dataModelId}:swapSources
```

Use this when a DM itself contains a custom-SQL element you want to promote.
Same `sourceMapping[].from` / `.to` shape; same silent-no-op gotcha for
bogus `from.customSqlId`. Not part of the standard Phase 1–6 flow — included
for completeness.

---

## Troubleshooting

| Error / symptom | Cause | Fix |
|---|---|---|
| `Token missing or malformed` | Token expired between commands | Re-run `eval "$(bash scripts/get-token.sh)"` — chain with `&&` |
| `:swapSources` returns HTTP 200 `{}` but nothing changed | `from.customSqlId` doesn't match a real element (typo or already swapped) | Re-list `/v2/workbooks/{id}/sources`; assert no `custom-sql` entries remain |
| `Element X not found in data model` (400) on `:swapSources` | `to.elementId` doesn't exist in the DM | Use the server-assigned ID from Phase 3, not your authoring ID |
| `bad substitution` on the curl URL | Shell expanded `$WB:swapSources` as a parameter modifier | Wrap in braces: `${WB}:swapSources` |
| Child element formulas show `[Missing node/...]` after swap | Root SQL element was unnamed; the implicit "Custom SQL" prefix lost its referent | **Sticky** — must be fixed manually. Pre-swap: name the root element AND rewrite child formulas to use that name |
| Query returns an error string inside a data cell, e.g. `Column "[OT Summary/OT_HOURS]" does not exist` | Auto-match silently missed a SNAKE_CASE column alias; formula points at a column ID the DM doesn't expose | Run `scripts/audit-formulas.rb --from-plan` (Phase 6). For repeat offenders, pass `columnMapping` in the swap call proactively |
| `service_error` 500 on a swap whose `to.definition` contains SQL with single quotes | Heredoc / shell expansion mangled the SQL string | Use a JSON file with `-d @<file>` instead of inline `-d '...'`, or escape carefully |
| Plan picked the wrong reuse target | The DM with the lowest `dmElementCount` and matching connection was not the most appropriate | Edit `/tmp/swap-plan.json` to point `target.dataModelId` / `target.elementId` at the preferred DM before Phase 5 |
| `Invalid array: ...columns, got undefined` | Converter returned no columns (SELECT * case) | Fetch columns via `mcp__sigma-mcp-v2__describe` and add them manually |
| `formula: Invalid string: undefined` | Column missing `formula` field | Every column needs `formula` — `[Custom SQL/SQL_ALIAS]` for sql, `[TABLE/COL]` for warehouse-table |
| `Circular column reference` | Formula used the column's own display name with no prefix | Use `[Custom SQL/SQL_ALIAS]` — bare `[Display Name]` self-references |
| `Unknown column '[ALIAS]'` | Bare alias with no prefix | Add the `Custom SQL` prefix: `[Custom SQL/ALIAS]` |
| `dependency not found: formula reference 'element name/col'` | Used element's own name as formula prefix inside the element | Inside a sql element, always use `[Custom SQL/...]`, never `[ElementName/...]` |
| `document parent must be a folder` | `folderId` points to a workbook or DM, not a folder | Use `folder_id` from the manifest — taken from the workbook's own folder, always a real folder |
| Converter returns `path: ["CTE_NAME"]` | Converter treated CTE name as a warehouse table path | Discard converter output; build a `source.kind: "sql"` element manually |
| `Column '[Element/id]' does not exist` after DM PUT | DM PUT reassigned column IDs — old IDs are stale | Workbook formulas must use display names not IDs: `[Element Name/Column Display Name]` |
| `dataModelId` missing from response | POST failed silently | Check the full response for a `message` field |
| Metric columns missing on child elements referencing aggregated SQL | warehouse-table + metrics approach; child references aggregate as a direct column | Rebuild the DM page as a `sql` source with all output columns enumerated explicitly |
