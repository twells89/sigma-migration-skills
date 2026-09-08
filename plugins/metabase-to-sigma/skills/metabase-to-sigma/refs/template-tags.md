# Template tags → Sigma controls

Native-SQL template tags are the single most common Metabase feature in the
wild: **45% of cards** on the reference production estate (7,023 cards,
Metabase Cloud v1.61) carry at least one tag. Tag-type distribution observed
there: text 5,629 · date 2,364 · dimension (field filter) 1,914 · number 1,002 ·
card 384 · boolean 47.

> ## ⚠️ 2026-06-15 — PREFER native-model remodel; custom-SQL control binding is INERT
>
> **Live-disproven (a validation org):** a *workbook* control bound only to a DM
> custom-SQL `{{param}}` does NOT filter — a text grain control is ignored and a
> numeric one mis-substitutes and breaks the query (0 rows). So the
> `{{tag}}`-kept-verbatim path below only works when the user manually wires the
> control to the DM parameter in the Sigma UI. Two consequences in the converter:
>
> 1. **Simple native SQL is auto-remodeled to a NATIVE Sigma data model** — a
>    card that is a single `SELECT` over warehouse table(s) (no CTE / subquery /
>    CASE / window / set-op, only field-filter tags, real WHERE only on those
>    tags) is re-expressed as a structured query and built as a table/join model
>    (no custom SQL). Its columns are exposed, so field filters reproduce as REAL
>    Sigma controls + element filters that actually filter — verified live (a
>    `last_name` control flips a chart 5→1 rows). This is the path to working
>    filters; **the mapping table below is the FALLBACK for SQL too complex to
>    remodel.**
> 2. **No dead furniture:** a control whose only wiring would be a DM-SQL
>    `{{param}}` (or a field-filter column missing from the result set) is NOT
>    emitted — it goes into the result's `unreproducibleFilters` report
>    (controlId / name / reason / hint) so the migration surfaces exactly what
>    still needs a manual remodel. See design-notes.md "native-model remodel".

The fact behind the fallback path: **Sigma custom SQL uses the same
`{{control-id}}` parameter syntax as Metabase**, so a plain variable tag's SQL
needs NO rewrite — but per the warning above, that control must be wired to the
DM parameter in the UI to actually filter.

## Mapping table

| Tag type | Converter behavior | Sigma artifact |
|---|---|---|
| `text` | `{{tag}}` kept **verbatim** in the SQL | `controlType: text` control, `controlId` = tag name, `value` = tag default |
| `number` | verbatim | `controlType: number` control (verify on first live POST — `number-range` is the spec-verified shape; single-value number is doc-derived) |
| `date` | verbatim | `controlType: date` control |
| `boolean` | verbatim | `controlType: switch` control |
| `dimension` (**field filter**) | `{{tag}}` replaced with `1=1 /* … */` + loud warning | control + element filter on the mapped column, recreated on the **consuming workbook element** |
| `card` (`{{#N-…}}`) | inlined as `( <card N SQL> )` when card N is in the input set, native, and tag-free; otherwise flagged | — |
| `snippet` | flagged — inline `GET /api/native-query-snippet` by hand | — |

Controls are emitted as `kind: control` elements on the data-model page (the
custom SQL lives in the DM, so the `{{tag}}` reference must resolve there).
The tag's `display-name` becomes the control name; `default` becomes `value`.
A `required: true` tag with no default is warned about — the element errors
until the control has a value.

## Field filters (`type: dimension`) — why `1=1`

A Metabase field filter does **not** substitute a scalar: at runtime it expands
to a **whole SQL predicate** on the mapped column (`WHERE {{order_date}}` →
`WHERE ORDER_DATE BETWEEN … AND …`), driven by the widget type. There is no
Sigma equivalent inside custom SQL, so the converter:

1. Replaces `{{tag}}` with `1=1 /* Metabase field filter {{tag}} → filter [Col]
   on the consuming Sigma element */` — semantically the "no value selected"
   state, and always safe because a dimension tag can only legally appear in
   boolean-predicate position.
2. Resolves the tag's `dimension` field ref to the column (metadata →
   result_metadata → `GET /api/field/{id}`) and tells you (warning + the
   dashboard converter's `parameterWiring`) to recreate it as a Sigma control +
   element filter on that column.
3. If the mapped column is **not** in the card's SELECT output, the filter
   cannot be recreated on the element — flagged as ambiguous; add the column to
   the SQL first.

## Optional `[[ … ]]` blocks

Metabase includes an optional block only when its tag has a value (24% of the
reference estate's cards use them). Sigma has no optional-clause syntax:

- every tag in the block is a **field filter** → block kept active (they
  neutralize to `1=1`, so always-on is harmless);
- every variable tag in the block **has a default** → block kept active
  (matches Metabase's default state) + warning;
- otherwise → block **dropped** (matches Metabase's empty-value behavior) +
  loud warning listing the dropped clause.

## Dashboard parameters driving tags

On production estates, dashboard `parameter_mappings` overwhelmingly target
template tags, not columns (13,474 `["variable",["template-tag",…]]` +
1,057 dimension targets of 14,600 mappings observed). The dashboard converter
records these in the result's `parameterWiring` array and emits ONE aggregated
warning per parameter. Consolidation is manual today: either keep the DM
control as the single source of truth, or sync the workbook control to it.

`["dimension",["template-tag",…]]` targets (a parameter driving a field-filter
tag) are auto-wired to a hidden boolean + include-`[true]` element filter when
the tag's column is in the card's result set.

## SQL dialect passthrough

The statement (after tag handling) is emitted **verbatim** into the Sigma
custom-SQL element — the dialect passes straight through to the warehouse. A
same-warehouse migration (e.g. BigQuery→BigQuery: `project.dataset.table` refs,
trailing-comma SELECTs) is near-verbatim; cross-warehouse migrations need a SQL
transpile pass first.
