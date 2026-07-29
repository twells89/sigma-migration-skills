# Input tables — operational guide

> **Spec shape lives in `tables.md`** (the "Input tables" section there covers
> `inputMode`, `source` kinds, and the four column shapes). This file is the
> operational supplement: what has to be true *around* the spec for an input
> table to actually work, and how to read the data back.

Input tables are workbook elements that support **structured data entry** —
forecasting, what-if, manual augmentation — and write the entered values back to
the warehouse. Use them when the user wants to *type or upload data*, not just
read it. Other elements (tables, charts, KPIs) can then source from the input
table, and a data model can read it through a warehouse view.

## Requirements & lifecycle

1. **Write-enabled connection required.** `source: { kind: empty, connectionId }`
   must point at a connection with `writeAccess: true` (`GET /v2/connections`).
   A non-write connection fails at POST. A linked table's `source` carries its
   **own** `connectionId` — see *Cross-connection linked tables* below; it is
   not always simply inherited from the parent element.
2. **`inputMode` is mandatory — omitting it masked-fails.** Every `input-table`
   element requires `inputMode: edit | explore | view` (see `tables.md`). Leave
   it out and the POST doesn't fail with a helpful "missing inputMode" — it
   fails with the generic **`Invalid kind: "input-table"`**, which reads like
   the element kind itself is rejected. If you hit that error on an
   input-table, check `inputMode` first before suspecting anything else about
   the shape.
3. **Data lands in `SIGDS_`-prefixed tables** in the connection's write schema.
   Don't query or modify those directly — see "Reading the data" below.
4. **Data is invisible until Publish.** A query of an input table before the
   workbook is published returns **0 rows** — the query layer reads the
   published version. Publish, then re-query.
5. **System columns take no `type`** (`ID`, `CREATED_AT`, `CREATED_BY`,
   `UPDATED_AT`, `UPDATED_BY`) — adding one breaks the column. They're also
   never included in an `insert-rows` action effect's `values` — Sigma
   auto-fills them at insert time (see `reference/workflows/actions.md`).

### Cross-connection linked tables (verified)

A **linked** input table's `source: { kind: linked, from: <parentElementId>,
connectionId: <connectionId> }` carries its own `connectionId` — and that
connection **can differ from the parent element's**. Verified live: a
write-back input table on a write-enabled connection, linked (`from`) to a
parent element (a pivot/table) sourced on a completely separate, **read-only**
connection — the linked table still pulled every key row from the parent
correctly. In other words, cross-connection linking (write-conn child, read-conn
parent) is a supported pattern, not just same-connection linking. This is a
narrower, more precise claim than "the connection is inherited" — the parent
supplies the *keys* (via `{ id, key }` columns), not the *connection*; the
linked table's own `connectionId` is what determines where its write-back rows
actually live, and it must be a write-enabled connection regardless of what the
parent uses.

## Three types

| Type | What it is | Source shape |
|---|---|---|
| **Empty** | Blank table; rows added/typed/pasted from scratch | `source: { kind: empty, connectionId }` |
| **CSV** | Pre-populated from a CSV upload, then editable | created from an upload (UI); element is otherwise an empty-style input table |
| **Linked** | Child of a parent element; key columns bind rows to the parent, entry/formula columns sit alongside | `source: { kind: linked, from: <parentElementId>, connectionId: <connectionId> }` + `{ id, key }` columns |

**Linked tables are spec-authorable as of the 2026-06-11 release** —
`source.kind: linked` + `from` + `{ id, key }` columns POST and round-trip
cleanly (verified 2026-06-11, including a cross-element formula column).
One caveat until proven otherwise: that verification was **structural** (POST +
readback). The pre-release API accepted the same shapes but broke the key
correlation at the *data* level — inherited columns showed "multiple values" —
so after the first real rows land, **query the table** (don't just inspect
`/elements`) to confirm inherited columns resolve per-row. On older orgs/API
versions linked tables were also dropped from `/spec` entirely; if inherited
columns misbehave, suspect an older org/API first.

**Column validation is now spec-authorable (2026-06-18 release)** — see the
"Editable data column" shapes in `tables.md`. Confirmed round-tripping live:
- **Single-select** dropdown — a scalar column (`type: text|number|datetime`) plus
  a fixed **`values: [ ... ]`** option list. (There is no `single-select` type
  token — `type: single-select` 400s; the `values` list is what makes it a
  dropdown.)
- **Multi-select** — `type: multi-select` + `values: [ ... ]`. Variant-backed:
  requires a connection whose warehouse supports variant columns (e.g. Snowflake).
- **Range bounds** — `range: { min, max }` on a `number` or `datetime` column.
- **Options from a sibling element** — `valuesFrom: { element: <elementId>, column: <columnId> }`
  (single- or multi-select). Note the keys are `element` / `column`, not
  `elementId` / `columnId`.
- **Pills** — render a select column as pills: `pills: single-color` or
  `pills: color-by-option` (an enum *string*; omit for plain text).
- **File-upload columns** — `type: file` + optional `maxFileNum`, `maxFileSizeMb`,
  `acceptedFileTypes: [ ... ]`. Variant-backed.

`values`, `valuesFrom`, and `range` share **one** validation slot — they're
mutually exclusive on a column (combining them 400s). Still UI-only: **column
protection** and **data-entry permissions**.

## Reading an input table's data & structure

`SIGDS_` write-back tables aren't directly queryable. To read the data, create a
**warehouse view** for the input table (UI: input-table element → *Warehouse
views → Create new*), then `SELECT … FROM <db>.<schema>.<view>`.

To inspect an input table's **structure regardless of `/spec`** (handy on older
orgs where linked tables are hidden from `/spec`, or for a quick column dump),
use the element endpoints (linked columns label as `Col (ParentName)`):

```bash
# list every element (incl. input tables hidden from /spec on older orgs)
GET /v2/workbooks/{workbookId}/elements
GET /v2/workbooks/{workbookId}/pages/{pageId}/elements
# column-level detail: labels, formulas (linked refs show as [Parent/Col]), types
GET /v2/workbooks/{workbookId}/elements/{elementId}/columns
```

## Migration pattern

For data-entry migrations (Excel/planning models) the end-to-end pattern is
input table → publish → warehouse view → data model `FROM` that view. The
`excel-to-sigma` skill covers it in depth.
