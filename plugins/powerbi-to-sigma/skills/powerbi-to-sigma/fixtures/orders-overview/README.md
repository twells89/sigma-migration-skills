# orders-overview — PowerBI → Sigma offline/LIVE dashboard fixture

A self-contained 3-visual PBIR dashboard (KPI + 2 bars) over `CSA.TJ.ORDER_FACT`,
used to exercise **and LIVE-verify** the grounded `build-workbook-from-pbir.rb`
classifier (beads-sigma-kvza). This is the PowerBI analogue of qlik's
`fixtures/retail-orders` and looker's `fixtures/skilltest-orders`.

Files:
- `signals.json` — the normalized PBIR signals (extract-pbir.py's output shape):
  one page with a `card` (→ kpi-chart), a `clusteredColumnChart` (→ vertical
  bar-chart), and a `clusteredBarChart` (→ horizontal bar-chart).
- `master-map.json` — maps each `Entity.Field` queryRef to a master column +
  aggregator. `data_model` / `element_id` are **placeholders** — fill them with
  a real DM (below) before a LIVE run.
- `dm-spec.json` — the DM to POST (`/v2/dataModels/spec`): a single SQL element
  over `CSA.TJ.ORDER_FACT` exposing `NET_REVENUE` / `ORDER_CHANNEL` / `SHIP_METHOD`.

## Offline (build the spec, no POST)
```
ruby scripts/build-workbook-from-pbir.rb \
  --signals fixtures/orders-overview/signals.json \
  --master-map fixtures/orders-overview/master-map.json \
  --out /tmp/wb-spec.json
```

## LIVE (against a warehouse, e.g. CSA.TJ)
1. POST `dm-spec.json` to `/v2/dataModels/spec`; note the returned `dataModelId`
   and the `Order Fact` element id from the readback.
2. Fill `master-map.json`'s `data_model` / `element_id` with those ids.
3. Build the workbook spec (above), set `folderId`, and POST via
   `scripts/post-and-readback.rb --type workbook --spec /tmp/wb-spec.json ...`.

**LIVE-verified 2026-07-13** against CSA.TJ (wb 9c3b5577, DM 4eca2915): workbook
POST clean, 0 `type=error` columns, render correct — Total Net Revenue
$127,513.88 = warehouse; the `clusteredColumnChart`→vertical and
`clusteredBarChart`→horizontal grounding mapping both render correctly.
