# Supported Streamlit patterns

Foundation coverage is conservative. “Detected” does not imply “automatically
converted”; unresolved lineage always becomes a gap.

## Elements

| Streamlit | Sigma | Status |
|---|---|---|
| title/header/subheader/markdown/caption | text | direct |
| metric | KPI | direct when value lineage resolves |
| dataframe/table | table | direct |
| line/bar/area chart | native chart | direct when x/y resolve |
| scatter chart | native scatter | restructure; point identity required |
| Plotly/Altair line/bar/scatter config | native chart | literal config only |
| divider | divider | direct |
| progress | progress | direct for resolvable/static value |
| columns | proportional grid | direct |
| horizontal container | equal-width element row | direct |
| tabs | tabbed container | direct |
| navigation/pages | page metadata plus vertical navigation element | direct |
| popover/expander/status | popover overlay | mechanical |
| button | button | direct visually; classify action host as spec-native or manual-ui-finish |
| link button / page link | button + `open-url` / `navigate` | direct for static destinations |
| button + `st.switch_page` | button + `navigate` | direct when the target page is discovered |
| download button over displayed data | browser export action | direct when target element and format resolve |
| static form fields | native form | capability-gated; submit/reset effects must be bounded |
| data editor | input table + row actions | warehouse-backed when schema, connection, keys, and writes are proven |
| chat input/message and true agent runtime | workbook agent + chat | workbook-agent-candidate |
| `SNOWFLAKE.CORTEX.COMPLETE` chat | workbook agent redesign or plain completion | never classify as Cortex Agent automatically |

## Controls

| Streamlit | Sigma |
|---|---|
| selectbox | single list when dataframe column lineage resolves |
| multiselect | multiple list when dataframe column lineage resolves |
| radio | segmented when dataframe column lineage resolves |
| date-input tuple | detected; predicate/column binding still requires review |
| slider/range slider | detected; bounds and predicate binding not yet lowered |
| number input | detected; comparator/predicate binding not yet lowered |
| checkbox/toggle | detected; boolean predicate binding not yet lowered |
| text input/area | detected; match mode/predicate binding not yet lowered |

The analyzer must prove the source dataframe and target column. Otherwise the
control is omitted with `control-lineage-unresolved`.

## Pandas lineage

Recognized operations:

```text
column selection/assignment
boolean mask / isin
groupby / agg
sum / mean / min / max / count / nunique
reset_index / sort_values / head
merge
cumsum
to_period / astype
drop_duplicates / dropna / unique / value_counts
```

The current formula translator covers common aggregate/arithmetic/conditional
KPI expressions and simple group-by chart intent. `merge`, `pivot_table`,
`cumsum`, `head`, `drop_duplicates`, `to_period`, `value_counts`, and
source-specific sorting remain loud `dataframe-restructure-required` gaps. It
does not execute Pandas or infer arbitrary Python.

Local Python transforms are `python-element-candidate` only when the target
workspace and connection pass the code/code-output probes in
[`live-api-capabilities.md`](live-api-capabilities.md). Detection never executes
source code.

## Wrapper/config expansion

Literal module-level lists/dictionaries named like `KPI_CONFIG`, `CHART_CONFIG`,
or `CHART_TABS` are expanded. Runtime loops over query results produce a
`dynamic-loop` review gap.

## Explicit gaps

| Code | Meaning |
|---|---|
| `dynamic-sql` | SQL contains runtime interpolation |
| `session-state` | cross-rerun state machine |
| `deferred-form-state` | use a native form or staged/applied controls; arbitrary callbacks remain redesign |
| `custom-component` | native mapping or plugin decision required |
| `data-editor` | writeback architecture required |
| `unsupported-dataframe-operation` | lineage outside conservative subset |
| `dynamic-loop` | runtime-dependent element cardinality |
| `llm-complete-not-agent` | runtime uses Cortex Complete rather than an agent |
| `agent-runtime-mismatch` | setup defines an agent that the application never calls |

## Action and state architecture

Use this order for buttons, callbacks, forms, and session state:

1. Public-spec controls/actions/overlays/input tables (`spec-native`).
2. Warehouse tables, views, and procedures (`warehouse-backed`).
3. A named UI-only wiring step when GET omits the action or POST/PUT rejects the
   UI-supported host (`manual-ui-finish`).
4. Plugin or redesign only when the first three cannot express the behavior.

Never infer public-spec support from the Sigma editor alone. Verify the literal
shape through POST/PUT and GET readback. If no literal action survives readback,
do not invent one.

Current selected-row action values use `columnId`, `minColumnId`, and
`maxColumnId`; Run Python uses `codeElementId`. Use the live-verified builders in
`converter/api_capabilities.py`.

Those builders also cover native forms, input-table row writes, current-workbook
navigation, external links, tab selection, and chat reset. Treat writeback as
complete only after an authenticated click changes the intended sandbox row and
readback confirms the result.

A literal sort selector over known table columns maps to `custom-sort` effects.
Use `elementId` for the target and a table-level sort object:
`{type: level, columns: [{columnId, direction, nulls}]}`. Branch with `if-else`
when different options require different directions.

## Plugin candidates

Custom charts, maps, cards, gauges, and client-side components may hand off to
`sigma-plugin-authoring`. Python-backed callbacks, auth, and general
bidirectional state are not automatically portable.
