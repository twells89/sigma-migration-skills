# cognos / acme-warehouse-fm

A synthetic IBM Cognos **Framework Manager** project XML (BMT model specification) from
the cognos-to-sigma plugin fixtures (referenced, not duplicated). FM is Cognos's legacy
semantic layer — the desktop modeller that Data Modules replaced — and it is a completely
different format from the `*.module.json` covered by the sibling
`great-outdoors-module` case.

The fixture is hand-authored (invented company, schema, tables and columns) and kept
small deliberately, but it exercises every FM construct the ingest handles.

## Converter

The **in-repo converter** (not MCP), from the plugin's converter/ dir. An FM model is far
too large to convert whole, so conversion is scoped to one presentation subject area:

```
cd plugins/cognos-to-sigma/skills/cognos-to-sigma/converter
npm install            # once (tsx + fast-xml-parser)
npm run --silent convert ../fixtures/acme-warehouse.fm.xml -- --list
npm run --silent convert ../fixtures/acme-warehouse.fm.xml -- --subject-area "Sales Analysis" > model.json
```

Stats + warnings print to stderr; the golden wraps them with the payload as
`{sigmaDataModel, stats, warnings}` to mirror the other converters' shape.

## Features exercised

- **Four-layer model** — Database / Logical / Presentation / Dimension. Folders are
  path-transparent (a `refobj` skips them), so the index must not include them.
- **Shortcut resolution** — presentation `shortcut` → logical `querySubject` →
  `refobjViaShortcut` → database `querySubject` → `dbQuery` SQL → warehouse table.
- **Role-playing dimension aliases** — one physical `DATE_DIM` exposed as both
  `SALES_ORDER_DATE` and `SALES_SHIP_DATE`. These MUST stay two Sigma elements
  (`Order Date`, `Ship Date`); collapsing them joins the fact at the wrong grain.
- **Data-source resolution** — `[AcmeWarehouse].SALES_FACT` + the `dataSources` entry
  becomes the warehouse path `ACME_ANALYTICS / DW / SALES_FACT`.
- **Custom SQL** → a `sql` source (see the sibling `Customer Entitlement` subject area),
  with `[datasource].TABLE` rewritten to a fully-qualified warehouse name and columns
  prefixed `[Custom SQL/…]`.
- **Facts with a `regularAggregate`** → metrics; identifiers/attributes → columns, with
  the Logical Layer's business label preserved as the column `name`.
- **Cardinality** — `one:one → one:many` puts the relationship on the fact (many) side.
- **Calculations** — arithmetic, a searched `CASE` → nested `If()`, and XML entity
  decoding (`&lt;` → `<`; `stopNodes` hands back raw XML, and an undecoded entity
  compiles to type `error`).
- **Window / scoped aggregates** — `running-total(...)` → the Sigma-native
  `CumulativeSum(...)`; `total(... for ...)` degrades to `Sum(...)` with the dropped
  partition flagged. The `*Over` family is never emitted (it 400s a DM-spec POST).

## Flagged, never faked (the 5 expected warnings)

1. embedded Framework Manager filter not applied to the Sigma model
2. parameter map (`_env`) — session-parameter substitution not translated
3. DMR dimension (hierarchy/levels) not converted
4. `total( … for …)` scoped aggregate — partition dropped
5. security views detected but not ported (the RLS flow applies them)

The `Customer Entitlement` subject area additionally flags the Cognos runtime macro
`#sq($account.personalInfo.email)#`, which is passed through verbatim and must be
replaced (e.g. with `CurrentUserEmail()`) before posting.

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/cognos-to-sigma/skills/cognos-to-sigma/fixtures/acme-warehouse.fm.xml", "format": "xml"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 6,
      "columns": 47,
      "metrics": 4,
      "relationships": 4,
      "warnings": 5
    }
  }
}
```
