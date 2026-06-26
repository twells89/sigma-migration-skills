# Sigma Formula Reference

This is the highest-traffic reference file — Sigma's formula DSL is the largest source of spec errors and the OpenAPI doesn't fully describe its semantics. Treat this as the source of truth for the **formula language itself** (syntax, qualification, operator behavior). Field-level shape (where formulas appear in the spec) is in the OpenAPI per-element schemas.

## ⚠️ READ FIRST: The #1 Formula Mistake

When an element sources another element (e.g., a KPI or chart sourcing a table), **every column reference inside aggregations must include the source element's name as a prefix.** Forgetting the prefix is the single most common Sigma spec error.

**Wrong:**
```yaml
kind: kpi-chart
source: { kind: table, elementId: usage-table }
columns:
  - name: Total
    formula: Count([Question ID])
```

**Right:**
```yaml
kind: kpi-chart
source: { kind: table, elementId: usage-table }
columns:
  - name: Total
    formula: Count([AI Usage Data/Question ID])
```

**Why:** a bare `[column_name]` means *defined in THIS element's own `columns[]` array* — not *visible through the source*. SQL intuition leaks here: `Count([col])` feels local because the source "is" the table, but Sigma's formula language requires you to name the source explicitly.

**Rule of thumb:** if your element's `source` points at another element (or a warehouse table, or a join), 90%+ of your formulas will start with `[<SourceName>/...]`. Bare refs are only for columns you literally defined a line or two above in the same `columns[]` array.

> **`<SourceName>` is the element's `name`, not its `id`.** An element with `id: master` but `name: Orders` is referenced as `[Orders/Net Revenue]` — `[Master/Net Revenue]` resolves to nothing. The trap: **a wrong element-name prefix is NOT caught at POST** — the spec saves `200` and the error only appears in the rendered output as `Invalid Query: Unknown column`. So if you rename an element (or set `id` ≠ `name`), update every formula that references it, and **always render-check after POST** — a clean `200` is not proof the formulas resolve. (Live-verified 2026-06-26.)

Before publishing, run `./scripts/validate-spec.sh <spec.yaml>` — it catches the missing-prefix mistake (but not a wrong-name prefix; only a render does).

---

## ⚠️ READ THIRD: Every column needs a `formula`

On **any** element sourced from a data model, warehouse table, or another element, **each entry in `columns[]` must carry a `formula`.** A column with only `name` (display label) and/or `columnId` is rejected:

```
400  pages[0].elements[N].columns[0].formula: Invalid string: undefined
```

```yaml
# ✗ 400 — name/columnId alone is not a binding
columns:
  - { id: c1, name: Net Revenue }
  - { id: c2, columnId: Net Revenue }

# ✓ formula is the binding; name is just the display label
columns:
  - { id: c1, formula: "[Net Revenue]",            name: Net Revenue }
  - { id: c2, formula: "[Order Fact/Order Id]",    name: Order Id }
```

This bites when **hand-authoring from scratch** (vs. round-tripping a GET'd spec, where every column already carries its `formula`). When cloning an element from an existing workbook, keep the `formula` on each column — don't strip it down to `name`. (Live-verified 2026-06-26.)

---

## ⚠️ READ SECOND: Raw vs. Friendly Column Names

Sigma's formula DSL references columns by their **friendly name**, not their raw warehouse name. The two diverge in two ways:

1. **Special characters** — `/`, `-`, `.`, `[`, `]`, and leading/trailing whitespace are stripped or replaced.
2. **Casing and word boundaries** — `ALL_CAPS_WITH_UNDERSCORES` is title-cased and underscores become spaces; `camelCase` is split on case boundaries.

Examples observed on real Sigma instances:

| Raw warehouse name | Friendly name used in formulas |
|---|---|
| `DATE` | `Date` |
| `UNIT PRICE` | `Unit Price` |
| `ORDER_ID` | `Order ID` |
| `V userId` | `V User Id` |
| `Net/Gross` | `Net Gross` |

The trap: `GET /v2/connections/tables/{inodeId}/columns` returns **raw warehouse names** (`DATE`, `V userId`). Formulas written against those raw names will silently fail to resolve — Sigma is permissive at POST time and even auto-normalizes some simple cases (`[ORDERS/DATE]` → `[ORDERS/Date]`), but the auto-fix does **not** cover everything. The reliable workflow:

1. POST your spec using your best guess (often the raw name works for ALL_CAPS columns).
2. Run `./scripts/verify-workbook.sh <workbookId>` — if any element compiles to `'Unknown column "[X]"'` SQL, the friendly name doesn't match.
3. Fix the affected formulas in your spec. To learn the canonical friendly name, GET the workbook spec back (`GET /v2/workbooks/<id>/spec`) — Sigma's readback shows the names it actually resolved against. Use those for the PUT.

**Don't guess the normalization rules** — Sigma's are more aggressive than they look. When verify fails, ask the readback.

Wrong: `[ORDERS/Net/Gross Revenue]` (slash inside a column name; unparseable)
Wrong: `[ORDERS/Order-ID]` (raw warehouse name with a dash)
Wrong: `[ORDERS/ORDER_ID]` (raw underscore form; usually needs `Order ID`)
Right: `[ORDERS/Net Gross Revenue]` (friendly name)
Right: `[ORDERS/Order ID]` (friendly name)

---

## Column Reference Rules

Every column formula references either a column **outside** the element or a column **inside** the same element.

### Outside the element — use `[SourceName/column_name]`

The prefix depends on the source type:

- **Warehouse table**: `SourceName` = last segment of the `path` array.
  - Path `["DB", "SCHEMA", "ORDERS"]` → `[ORDERS/revenue]`
  - Path `["ANALYTICS", "PUBLIC", "USERS"]` → `[USERS/email]`

- **Another workbook element**: `SourceName` = that element's `name` field.
  - Element named "Sales Table" → `[Sales Table/Revenue]`

- **Join source**: `SourceName` = the `name` field on a specific join leg, or the top-level `name` on the join object (for the `primarySource` leg).
  - Join with `primarySource` implicitly tied to top-level `name: "Sales Star"` → `[Sales Star/Order Number]` for primary columns.
  - Join leg with `name: "Sales"` → `[Sales/Cust Key]` for that joined table's columns.
  - Warehouse path segments do **not** become the prefix inside a join — use the join leg's `name` instead.

- **Union source**: `SourceName` = the union's `name` field. References resolve against the union's `matches[].outputColumnName` values, not the underlying tables' columns.
  - Union with `name: "All Sales"` → `[All Sales/Order Number]`.
  - If you omit `name`, Sigma assigns `"Union of N Sources"`; **a bare reference like `[Order Number]` to a column the consuming element also defines named `Order Number` is a circular reference and the SQL won't compile.** Set the `name` explicitly to avoid this.

- Column names must match exactly what the describe endpoint returns. **Never invent column names.**

### Inside the same element — use `[column_name]` (no prefix)

References a column already defined in this element by its `name` field.

```
// Given columns: "Revenue" (formula: [ORDERS/revenue]), "Cost" (formula: [ORDERS/cost])
// A third column can reference them:
[Revenue] - [Cost]       // valid — references sibling columns by name
Sum([Revenue])           // valid — aggregation over a sibling column
```

**A column cannot reference itself** — that is a circular reference error. This trips up copy-paste: if a column's `name` field matches any bracketed reference inside its own `formula`, the server treats it as circular even when you meant to reference a different column. Rename one side to break the cycle.

### Common mistakes

| Wrong | Correct | Why |
|-------|---------|-----|
| `[revenue]` | `[ORDERS/revenue]` | Missing table prefix for warehouse column |
| `[ORDERS/Total Revenue]` | `[Total Revenue]` | "Total Revenue" is a sibling column, not a warehouse column |
| `[Revenue]` in the "Revenue" column | Rename one side | A column cannot reference itself |
| `Count([Question ID])` on a sourced element | `Count([AI Usage Data/Question ID])` | Aggregation argument needs the source prefix |

## Operators

### Arithmetic
`+`, `-`, `*`, `/`, `%` (modulo), `^` (power)

**Do not use** `Power()` or `Mod()` — use `^` and `%` instead.

### Boolean
`and`, `or`, `not` are **prefix/infix operators, not function calls** — always put a space before the operand.

```
Wrong: Not(Contains([Deployment], "staging"))       // parses, but every row is null
Right: Not (Contains([Deployment], "staging"))      // space after Not

Wrong: And([Active], [Paid])                         // not a function
Right: [Active] And [Paid]                           // infix

Wrong: Or([Trial], [Free])                           // not a function
Right: [Trial] Or [Free]                             // infix

Right: Not [Active]
Right: [A] And Not [B]
Right: ([Status] = "Active") And ([Plan] = "Pro")
```

The trap: `Not(...)` parses successfully (the parens become grouping), so the failure is silent — null rows, no error. Easy to get wrong by analogy with `Sum([X])` / `If(...)`.

### String concatenation
`&` (not `+`)

**Do not use** `Concat()` — use `&` instead.

## Aggregation Functions

| Function | Description |
|----------|-------------|
| `Sum([col])` | Sum of values |
| `Avg([col])` | Average of values |
| `Count([col])` | Count of non-null values |
| `CountDistinct([col])` | Count of distinct values |
| `Min([col])` | Minimum value |
| `Max([col])` | Maximum value |
| `Median([col])` | Median value |

## Date Functions

| Function | Example |
|----------|---------|
| `DateTrunc(<part>, <date>)` | `DateTrunc("month", [Date])` |
| `DateDiff(<part>, <start>, <end>)` | `DateDiff("day", [Start], [End])` |
| `DateAdd(<part>, <units>, <date>)` | `DateAdd("month", 3, [Date])` |
| `DateFormat(<date>, <fmt>)` | `DateFormat([Date], "%Y-%m-%d")` |

Date parts (must be quoted strings): `"year"`, `"quarter"`, `"month"`, `"week"`, `"day"`, `"hour"`, `"minute"`, `"second"`

## Conditional

```
If(<condition>, <then>, <else>)
```

Supports multiple conditions (chained):
```
If([Status] = "Active", "Active", [Status] = "Pending", "Pending", "Other")
```

**Do not use** `Case` — use `If` instead.

## Text Functions

| Function | Description |
|----------|-------------|
| `Contains(<text>, <search>)` | True if text contains search |
| `Left(<text>, <n>)` | First n characters |
| `Right(<text>, <n>)` | Last n characters |
| `Upper(<text>)` | Uppercase |
| `Lower(<text>)` | Lowercase |
| `Trim(<text>)` | Remove leading/trailing whitespace |
| `Length(<text>)` | Character count |
| `Replace(<text>, <old>, <new>)` | Replace occurrences |

## JSON / Struct Field Access

Columns containing JSON or struct data (common for event payload / metadata columns) support **field access via dot notation** on the bracketed column reference. The extracted value is untyped — wrap it in the appropriate type constructor (`Text`, `Number`, `Date`) to coerce before passing it to downstream functions.

```
Text([Langfuse Metadata].agentId)           // extracts agentId as text
Text([Event Payload].user.id)               // nested access
Number([Event Payload].latency_ms)          // numeric cast
Text([Organizations].users[0])              // array index — first element
Text([Organizations].users[0].email)        // index + nested field
```

Without the wrapping cast, comparisons (`=`, `<`), aggregations (`Count`, `CountDistinct`), and text ops (`Contains`, concatenation with `&`) will often behave unexpectedly or fail silently — the extracted value keeps its variant/untyped flavor. If a JSON-derived formula appears to return `null` or mismatched values for every row, check that it's wrapped in `Text()` / `Number()` first.

Dot notation goes directly on the `]` — no space: `[Col].field`, not `[Col] .field`.

## Other Functions

| Function | Description |
|----------|-------------|
| `Coalesce(<a>, <b>, ...)` | First non-null value |
| `In([col], "a", "b", "c")` | True if value is in the list |
| `IsNull([col])` | True if null |
| `Null` | Null literal |

## Window Functions

| Function | Description |
|----------|-------------|
| `Rank()` | Rank within partition |
| `RowNumber()` | Row number within partition |
| `Lead(<col>)` | Next row's value |
| `Lag(<col>)` | Previous row's value |
| `RunningSum(<col>)` | Cumulative sum |
| `RunningAvg(<col>)` | Cumulative average |
