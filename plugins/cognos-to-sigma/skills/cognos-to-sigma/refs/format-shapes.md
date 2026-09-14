# Cognos source-format shapes (as observed on real CA 11.x / 12.x samples)

What the converter actually parses. Verified 2026 against IBM sample content on CA on Cloud.

## CA REST endpoints

| Need | Endpoint | Notes |
|---|---|---|
| List a folder | `GET /bi/v1/objects/{id}/items?fields=defaultName,type,id` | `data[]` of `{id,type,defaultName}`; `type` ∈ folder/module/report/exploration/reportView/dataSet2 |
| **Data Module JSON** | `GET /bi/v1/metadata/modules/{id}` | the spec. `/modules/{id}` returns EMPTY — wrong one. |
| **Report-spec XML** | `GET /bi/v1/objects/{id}?fields=specification` | `data[0].specification` is the report XML string (schema 17.x) |
| Data server connections | Manage → Data server connections | relational sources (e.g. GOSALES); warehouse-backed modules build on these |

Auth: session cookie + `X-XSRF-Token`. Base path is **instance-dependent** — prefer the
durable **`/api/v1`** API-key surface (`scripts/cognos-apikey-session.sh`; module spec at
`/api/v1/modules/{id}/metadata`, folder at `/api/v1/content/{id}/items`), and fall back to the
**`/bi/v1`** session-replay surface above only if `/api/v1` content calls 441/403 (Akamai-walled
tenant). See `refs/design-notes.md → API access` for the full endpoint mapping.

## Data Module JSON (`metadata/modules/{id}`)

```jsonc
{
  "version": "24.0", "identifier": "…", "label": "…",
  "useSpec": [ { "identifier": "M1", "type": "file"|"dataSource", "searchPath": "…", … } ],
  "querySubject": [
    {
      "identifier": "Sales", "label": "Sales",
      "ref": ["M1.Sales"],                       // physical source: useSpec M1, table/sheet "Sales"
      "item": [
        { "queryItem": { "identifier": "Quantity", "label": "Quantity",
                         "expression": "Quantity",        // BARE identifier = plain column
                         "usage": "fact", "regularAggregate": "total",  // fact + agg → metric
                         "datatype": "…", "format": "{…}" } },
        { "queryItem": { "identifier": "Margin", "expression": "[Sales].[Revenue]-[Sales].[Cost]", … } }  // calc
      ]
    }
  ],
  "relationship": [
    { "left":  { "ref": "Sales", "mincard": "one", "maxcard": "many" },
      "right": { "ref": "Product", "mincard": "one", "maxcard": "one" },
      "link":  [ { "leftRef": "Product_key", "rightRef": "Product_key", "comparisonOperator": "equalTo" } ] }
  ],
  "calculation": [ … ],   // model-level calcs (separate from per-subject items)
  "filter": [ … ]
}
```

Key facts the converter relies on:
- **Table source = `querySubject.ref` tail** (`"M1.Sales"` → `Sales`), NOT `definition.dbQuery` (that's an older/authored shape — also supported as a fallback). `useSpec` resolves M1 to a DB source or an uploaded file.
- **Plain column** = a **bare-identifier** expression (`"Quantity"`) or a self-subject ref (`[Sales].[Quantity]`). Anything else = a calculation.
- **Measure** = `usage:"fact"`/`"measure"` + a `regularAggregate` other than `none`.
- **Relationship join columns** come directly from `link[].leftRef`/`rightRef` (+ `mincard/maxcard`) — no expression to parse. Source element = the **`many`** side.
- **File-backed** modules (`useSpec.type:"file"`, an uploaded `.xlsx`) ⇒ land the data in the warehouse first; the original file is NOT re-downloadable via REST (stored copies are proprietary `.pq`).
- Layered modules expose **base + presentation** query subjects; both convert (a dedupe-to-physical-table pass is a roadmap refinement).

## Report-spec XML (`objects/{id}?fields=specification`)

```xml
<report xmlns="http://developer.cognos.com/schemas/report/17.5/">
  <queries><query name="qMain"><source><model/></source>
    <selection>
      <dataItem name="Country"><expression>[C].[Module].[sheet1].[Country]</expression></dataItem>
      <dataItem name="Swap Measure"><expression># prompt('pColumn','token','[…].[Revenue]') #</expression></dataItem>
      <dataItem name="YtY Revenue"><expression>(([CYQRev]-[PYQRev])/abs([PYQRev]))</expression></dataItem>
    </selection>
    <detailFilters><detailFilter><filterExpression>[Year]=2023</filterExpression></detailFilter></detailFilters>
  </query></queries>
  <layouts><layout><reportPages><page name="Page1"><pageBody><contents>
    <list refQuery="qMain"><listColumns><listColumn>
      <listColumnBody><contents><textItem><dataSource><dataItemValue refDataItem="Country"/></dataSource></textItem></contents></listColumnBody>
    </listColumn>…</listColumns></list>
  </contents></pageBody></page></reportPages></layout></layouts>
</report>
```

Key facts:
- Each `<query>` holds `<dataItem name expression>`; the dominant model **subject** is parsed from a `[C].[Module].[Subject].[Col]` ref → used as the Sigma table-element source name.
- Each `<list refQuery=Q>` → a Sigma `table` element; its columns are the `dataItemValue@refDataItem`s.
- `Summary(x)` / `Total(x)` list columns = layout aggregate footers → `Sum([x])` etc.
- `prompt('p')` in any expression → a Sigma control; `#…#` macros → flagged (see `expression-dsl.md`).
- Filters are surfaced as warnings to re-create.
- **Crosstabs (`<crosstab>`) → Sigma pivot-table** (supported, live-validated): `<crosstabRows>`/`<crosstabColumns>` → `crosstabNodeMember@refDataItem` give the row/column edge dims (skip `Total(...)` grand-total nodes); the measure is `<crosstabCorner><dataItemLabel@refDataItem>`. Maps to `rowsBy:[{id}]` · `columnsBy:[{id}]` · `values:[<colId string>]` (note: **values are bare id strings, rowsBy/columnsBy are `{id}` objects**; measure column formula = `Sum(<ref>)`).
- **Charts (RAVE2 `<vizControl type="com.ibm.vis.*">`) → Sigma chart elements** (supported, live-validated). They live in the report layout (NOT only dashboards). Shape:
  ```xml
  <reportDataStores><reportDataStore name="dsChart"><dsSource><dsV5ListQuery refQuery="qChart"/></dsSource></reportDataStore></reportDataStores>
  <vizControl name="Revenue by channel" type="com.ibm.vis.clusteredColumn">
    <vcDataSets><vcDataSet refDataStore="dsChart"><vcSlots>
      <vcSlotData idSlot="categories"><vcSlotDsColumns><vcSlotDsColumn refDsColumn="Order Channel"/></vcSlotDsColumns></vcSlotData>
      <vcSlotData idSlot="series"/>
      <vcSlotData idSlot="values"><vcSlotDsColumns><vcSlotDsColumn refDsColumn="Net Revenue" rollupMethod="total"/></vcSlotDsColumns></vcSlotData>
    </vcSlots></vcDataSet></vcDataSets>
  </vizControl>
  ```
  - `vcDataSet@refDataStore` → `<reportDataStore name>` → `<dsV5ListQuery@refQuery>` resolves the backing query; `vcSlotDsColumn@refDsColumn` is a dataItem name in that query.
  - **Slot → axis:** `categories`→`xAxis.columnId` (first; extra levels kept as columns + flag), `values`/`size`→`yAxis.columnIds` (aggregated by `rollupMethod`: total→Sum, average→Avg, …), `series`/`color`→`color {by:category, column}`. Pie/donut use `value{id}`+`color{id}`; scatter uses `x`/`y` slots.
  - **Type map:** clusteredBar/stackedBar→bar (horizontal), clusteredColumn/stackedColumn→bar (vertical, `stacking` from `stacked*`), line/spline→line, area→area, pie→pie, donut→donut, clusteredCombination→combo, bubble/scatter→scatter.
  - **Maps** (`com.ibm.vis.tiledmap`) → Sigma map elements: lat/long slots (`latlongLocations.latitude`/`.longitude` + `latlongSize`/`latlongColor`) → **point-map** (`latitude{id}`/`longitude{id}`/`size{id}`/`color`); named-location slots (`locations` + `locationColor`) → **region-map** (`region{id, regionType}` — defaults to `country` + a flag to set the right `regionType`: country / us-state / us-county / us-zipcode / us-cbsa / us-postal-place / ca-province; `color` = the measure). Rendering needs genuinely geographic columns.
  - **No native Sigma element** (`network`, `wordcloud`, `packedbubble`, `treemap`) → emitted as a **flagged table** (data preserved; re-pick an element in the workbook).

## Framework Manager project XML (`model.xml`)

Cognos's **legacy** semantic layer (the desktop modeller Data Modules replaced). A customer
hands over a project directory, not an API response:

| File | Use |
|---|---|
| `<Project>.cpf` | Workspace pointer only — names the model segment. **Not the model.** |
| `model.xml` | **The whole model.** This is the input. |
| `IDlog.xml`, `log.xml`, `session-log.xml`, `archive-log.xml` | Edit history. **Ignore** — `IDlog.xml` alone can be hundreds of MB. |

Root element is `<project queryMode="dynamic" xmlns="http://www.developer.cognos.com/schemas/bmt/60/12">`
— that namespace is the sniff that distinguishes an FM model from a report spec (both `.xml`).

### Layers

A conventional model nests four layer namespaces under one root namespace:

```xml
<project xmlns="http://www.developer.cognos.com/schemas/bmt/60/12">
  <namespace><name>MyModel</name>
    <namespace><name>Database Layer</name>     <!-- physical tables + joins -->
      <folder><name>SALES</name>
        <querySubject><name>SALES_FACT</name>
          <definition><dbQuery>
            <sources><dataSourceRef>[].[dataSources].[MyWarehouse]</dataSourceRef></sources>
            <sql type="cognos">Select * From [MyWarehouse].SALES_FACT as SALES_FACT</sql>
            <tableType>table</tableType>
          </dbQuery></definition>
          <queryItem><name>NET_AMOUNT</name><externalName>NET_AMOUNT</externalName>
            <usage>fact</usage><datatype>decimal</datatype><regularAggregate>sum</regularAggregate></queryItem>
        </querySubject>
        <shortcut><name>SALES_ORDER_DATE</name><refobj>[Database Layer].[DATE_DIM]</refobj>
          <targetType>querySubject</targetType><treatAs>alias</treatAs></shortcut>
      </folder>
    </namespace>
    <namespace><name>Logical Layer</name>      <!-- business names + calcs -->
      <querySubject><name>Sales Fact</name>
        <definition><modelQuery><sql type="cognos">Select <column>*</column>from<table /></sql></modelQuery></definition>
        <queryItem><name>Net Amount</name>
          <expression><refobj>[Database Layer].[SALES_FACT].[NET_AMOUNT]</refobj></expression>
          <usage>fact</usage><regularAggregate>sum</regularAggregate></queryItem>
      </querySubject>
    </namespace>
    <namespace><name>Presentation Layer</name> <!-- SUBJECT AREAS -->
      <namespace><name>Sales Analysis</name>
        <shortcut><name>Sales Fact</name><refobj>[Logical Layer].[Sales Fact]</refobj>
          <targetType>querySubject</targetType><treatAs>alias</treatAs></shortcut>
      </namespace>
    </namespace>
    <namespace><name>Dimension Layer</name></namespace>  <!-- DMR, flagged not converted -->
  </namespace>
  <dataSources>…</dataSources> <parameterMaps>…</parameterMaps>
  <securityViews>…</securityViews> <packages>…</packages>
</project>
```

### Two rules that govern every lookup

1. **Folders are path-transparent.** A `refobj` like `[Database Layer].[DATE_DIM].[ID]` skips
   every `<folder>` / `<queryItemFolder>` in between. Only `namespace`, `querySubject` and
   `queryItem` contribute an identifier segment. Index them the same way or nothing resolves.
2. **`refobjViaShortcut` is a 2-tuple** — `(alias-shortcut, physical-item)`:
   ```xml
   <expression><refobjViaShortcut>
     <refobj>[Database Layer].[SALES_ORDER_DATE]</refobj>     <!-- the ALIAS (role) -->
     <refobj>[Database Layer].[DATE_DIM].[CALENDAR_DATE]</refobj>  <!-- the real item -->
   </refobjViaShortcut></expression>
   ```
   The alias is how FM models **role-playing dimensions**: one physical `DATE_DIM` exposed as
   order-date, ship-date, … Each alias must become its **own** Sigma element, or the roles
   collapse and the fact joins at the wrong grain.

### Other key facts

- **Resolution chain:** presentation `shortcut` → logical `querySubject` → item `expression`
  → database `querySubject` → `dbQuery/sql` → `[datasource].TABLE` → the `<dataSource>`
  entry's `<catalog>`/`<schema>` gives the fully-qualified warehouse path.
- **Most expressions are nothing but a reference.** On real enterprise models ~95% of
  `<expression>` bodies are a bare `refobj` / `refobjViaShortcut` with no operators — a plain
  column, no translation required. Only the remainder are genuine Cognos expressions.
- **`stopNodes` / raw XML:** `<expression>` and `<sql>` are mixed content (text interleaved
  with `<refobj>`), so they must be read as raw XML and **entity-decoded** — an undecoded
  `&lt;` produces the literal formula `If([x] &lt; 100, …)`, which Sigma compiles to type
  `error`.
- `<relationship>` carries `<left>`/`<right>` `refobj` + `<mincard>`/`<maxcard>`; the
  `<expression>` holds the join conditions (several `and`-joined = a composite key).
- `<determinant>` declares grain/uniqueness — no Sigma equivalent; flagged.
- `<securityView>` = package-scoped include/exclude/hide over model objects (**object**
  security, → Sigma permissions/CLS). Row-level security is usually a runtime macro in
  query-subject SQL: `#sq($account.personalInfo.email)#` joined to a permissions table.
- `<parameterMap>` = session-parameter substitution; not translated.
