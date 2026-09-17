# domo / orders-presentation

Synthetic Domo discovery + card-data snapshot (no live Domo instance, no
customer data): six cards on one `Order Fact` DataSet — a currency KPI, a
percent KPI, a bar chart with a source Summary Number + categorical axis, a
month line chart, and a detail table with an Analyzer Quick Filter.
Regression-pins the **presentation automation**
(`derive-presentation-overrides.rb`) and the table Quick Filter control/source
contract that make the gold path reproducible for every customer instead of
relying on hand-authored sidecars.

## The gap this closes

The gold acceptance run reached Domo-faithful styling — compact `$146.7K`
KPIs, source summary values above each chart, compact currency axes, Domo
category order — through sidecars an operator wrote by hand. That is not
transferable: a new customer's run would not get them. `derive-presentation-
overrides.rb` derives the SAME four sidecars from discovery metadata + an
early Domo card-data snapshot (`parity-expected.json`), which the orchestrator
now collects and runs automatically before `build-workbook.rb`.

## Artifacts

| File | What it is |
|---|---|
| `fixtures/cards.json` | 6 cards: currency KPI, percent KPI, bar+summary+categorical, two line charts, detail table + Quick Filter |
| `fixtures/parity-expected.json` | Domo card-data snapshot (summary values + rows) the derivation reads |
| `checks.sh` | Executable expectations, run by `run-corpus.sh --check` |

## Expected behaviors (encoded in checks.sh)

1. **Currency KPI** → `kpi-format-overrides.json` compacts to `scale:1000,
   suffix:"K", prefix:"$"` + a display font size.
2. **Percent KPI** → font size only; never a bogus currency scale.
3. **Cartesian chart with a currency measure** → a compact currency axis lands
   in `chart-axis-overrides.json`; a table/KPI never gets one.
4. **Categorical (bar) chart** → `category-order-overrides.json` preserves the
   Domo row order (`In-Store, Online, App`); a date/line axis and a table are
   never treated as categories.
5. **Layout-safe only** → no `card-header-overrides.json` is auto-emitted (it
   would add `header-*` elements the automated layout can't place; the source
   Summary Number is already surfaced by the companion-KPI mechanism).
6. `presentation-overrides.json` records provenance + counts (never silently
   absent).
7. The detail table's Quick Filter becomes a card-scoped Sigma list control,
   populated from and filtering a hidden table source recorded in
   `control-scope.json`.

## Converter

No golden data model — this case pins the presentation-derivation contract,
not the MCP converter output. Reproduce the sidecars with:

```
ruby plugins/domo-to-sigma/skills/domo-to-sigma/scripts/derive-presentation-overrides.rb \
  --workdir <tmp> --discovery <tmp>/discovery --force
```

## Expectations

```json
{
  "artifacts": [
    {"path": "fixtures/cards.json", "format": "json"},
    {"path": "fixtures/parity-expected.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
