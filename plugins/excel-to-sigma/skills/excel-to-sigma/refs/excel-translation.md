# Excel → Sigma translation surface & converter design

Condensed from the converter design notes + the 2026-06-03/06-08 validation spike
against a real customer forecast model (5-year BU budget, 13 sheets, 3,255
formulas, 37 external links). The design held, with refinements baked in below.

## Translation surface

| Excel concept | Sigma equivalent | Difficulty |
|---|---|---|
| Worksheet | Workbook page | trivial |
| Formal **Table** (named, structured) | DM element / input table | easy if data lands somewhere reachable |
| Arbitrary cell range with values | text element OR a landed warehouse table | fundamental impedance mismatch |
| Cell formula (`=A2*B2`) | calc column on the parent Table | hard at scale (cell-grid vs column-of-rows) |
| Named range | calc column or control | medium |
| PivotTable | `pivot-table` (`rowsBy`/`columnsBy`/`values`) | clean 1:1 — pivot cache has the metadata |
| Chart | chart element of matching `kind` | mostly 1:1; radar/waterfall need substitution |
| Conditional formatting | `conditionalFormats[]` | clean 1:1 |
| Slicer | `control` element | clean 1:1 |
| Data validation (dropdown) | input-table single/multi-select, or `control` | medium |
| External links (workbook→workbook) | DM relationship / joined element | the biggest robustness win |
| VBA / macros | out of scope | flag in Phase 0 |

`.xlsx` is OOXML (ZIP of XML). Key members: `xl/tables/*.xml` (formal Tables),
`xl/pivotTables/*` + `xl/pivotCache/*`, `xl/charts/*.xml`, `xl/styles.xml`
(number formats / conditional formats), `xl/sharedStrings.xml`. Parse with
`openpyxl` (mature formula tokenizer) or `Nokogiri`.

## The three structurally hard problems

1. **Cell-grid → column-of-rows.** Only translate cell formulas that live inside
   formal Tables. Everything else → "manual review". Report sheets are rebuilt by
   hand in any migration anyway.
2. **Where does the data live?** MVP assumes **inline values → Snowflake landing**
   (inline `VALUES` custom-SQL for ≤~1k rows, PUT-stage + COPY INTO for larger).
   Power Query / ODBC / SharePoint-Online are additive paths once inline works.
3. **Formula breadth.** Cover the common ~30 functions (IF/IFS/SWITCH/IFERROR,
   SUM/SUMIFS/COUNTIFS/AVERAGEIFS, VLOOKUP/XLOOKUP/INDEX+MATCH, LEFT/MID/CONCAT,
   YEAR/MONTH/EOMONTH/EDATE, ROUND/ABS/MOD). Fail-loud on volatile locators
   (`OFFSET`, `INDIRECT`) — they almost always mark a report layout that needs a
   manual rebuild. A `convert_excel_formula_to_sigma` MCP tool would mirror the
   existing `convert_tableau_formula_to_sigma` rules-table pattern.

## Validation findings (fold into the converter)

- **80/20 formula coverage is real.** Of 3,255 formulas, only `OFFSET` (2%) was
  genuinely untranslatable. The big `MATCH/INDEX/SUMIFS` counts were
  *wide→long reshaping*, not business logic — they **evaporate** when data lands
  at a tidy grain. **State this to users: most "formula translation" is grain
  selection.**
- **Formal-Table-only MVP rule is right.** The one normalized Table was the
  Rosetta Stone defining the canonical grain. Report sheets were rebuilt by hand.
- **External links → warehouse joins** collapsed 55% of formulas to a few DM
  relationships. Biggest robustness win.
- **Inline `VALUES` custom-SQL beats CSV-landing for the seed** at ≤~1k rows — no
  warehouse write, and the source-swap to the real table/view is a one-line spec
  change.
- **Cached values are a trap on formula-driven output sheets.** Detached
  INDEX/MATCH sources cache dimension keys to `0`. The discovery scanner must
  distinguish *typed* cells from *formula* cells and warn when an output table's
  keys are computed from now-missing externals.
- **Derive, don't port, decayed columns** — broken fiscal-month/year defaults,
  stale date-lookup spines that end before the forecast window. Generate forward.

## Pipeline reuse from `tableau-to-sigma` (~60–70%)

Sigma-side (DM POST, workbook POST, verify, visual gate) is identical. Only the
input parser, calc discovery, and formula translator differ.

| Phase | Tableau | Excel |
|---|---|---|
| 0 Gap/layout scan | `scan-workbook-gaps.rb` / `parse-twb-layout.rb` | `xlsx-discover.py` (this skill) |
| 1 Calc discovery | Metadata API → `.twb` fallback | OOXML XML walk only |
| 2 Data landing | VDS / custom-SQL probe | inline VALUES / PUT-stage + COPY INTO |
| 3 DM build | `build-dm.py` | `build-dm-on-view.py` (this skill) |
| 4 Workbook build | `build-charts-from-signals.rb` | `sigma-workbooks` recipes |
| 5 Verify | `verify-workbook.rb` | unchanged |

Everything from validate-spec onward is platform-agnostic.

## MVP scope

`.xlsx` only; formal Tables as sources; pivots/charts from formal Tables; top ~30
functions translated, rest flagged; inline-data → Snowflake landing; the
input-table data-entry path from `refs/input-tables.md`.
