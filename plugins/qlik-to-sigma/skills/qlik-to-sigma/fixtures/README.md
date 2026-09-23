# Fixtures — offline input sets

## retail-orders/
A complete Phase-1 discovery output for the **Retail Orders (Qlik)** demo app
(DEMO_DB.DEMO star schema, sanitized demo data), captured live 2026-06-10 with
`scripts/qlik-discover.py`. Includes `converter-out.json` (the
convert_qlik_to_sigma result) so the offline path needs neither qlik-cli, the
node converter build, nor network access.

| file | producer | consumed by |
|---|---|---|
| `script.qvs` | `qlik app script get` | reconcile-columns.py |
| `measures.json` / `dimensions.json` | Engine MeasureList/DimensionList | build-sigma-dm.py |
| `charts.json` | object properties (dims/measures/labels/formats/sort) | build-sigma-workbook.py |
| `layout.json` | per-sheet cell grids (col/row/colspan/rowspan) | build-sigma-workbook.py (layout) |
| `app-meta.json` | REST item record (lastReloadTime, Section Access, DirectQuery) | freshness preflight |
| `snapshot.json` | `qlik app eval` of every sheet KPI + Max(date) | freshness preflight |
| `converter-input.json` | discovery | convert_qlik_to_sigma |
| `converter-out.json` | convert_qlik_to_sigma | build-sigma-dm.py |

## Offline smoke (no Qlik tenant, no Sigma org, no network)

```bash
export SIGMA_OFFLINE_DRY_RUN=1
bash scripts/bootstrap.sh --runtime-profile python --workdir /tmp/qlik-smoke
python3 scripts/migrate-qlik.py \
  --from-discovery fixtures/retail-orders \
  --connection 00000000-0000-0000-0000-000000000000 \
  --dry-run --yes --out /tmp/qlik-smoke
```

Expected: all 6 phases run; `/tmp/qlik-smoke/` gains `dm-spec.json` (7 elements:
6 repointed star tables + denorm SQL element with 13 metrics), `wb-spec.json`
(6 pages, 62 elements, 15 KPIs, 3 controls), `layout.xml` (6 `<Page>` grids),
`element-map.json`, and `control-scope.json` (the gate-7 sidecar); exit code 0.
Nothing is POSTed.

### Filter-object fixtures (control-targeting wave)

`charts.json`/`layout.json` carry synthetic filter objects exercising every
control path in `build-sigma-workbook.py`:

| object | case | expected outcome |
|---|---|---|
| `fp-1` (children `lb-1`,`lb-2`) | filterpane | one control per child listbox |
| `lb-1` CUSTOMER_REGION | plain field | `list` control, wired to the master |
| `lb-2` CATEGORY, state `AltA` | alternate state | NOT emitted; `unbound` status `manual` |
| `lb-3` NO_SUCH_FIELD | unresolvable | NOT emitted (loud WARN); `unbound` |
| `lb-4` CATEGORY | standalone listbox | `list` control |
| `lb-5` CUSTOMER_REGION (2nd sheet) | duplicate field | deduped (`unbound` status `duplicate`) |
| `lb-6` FULL_DATE, qTags `$date` | date-typed field | **`date-range` control** (a `list` on a datetime column gets its targets silently stripped) |

`control-scope.json` must report `sourceFilterSignals: 5` and pass
`python3 scripts/control_lint.py /tmp/qlik-smoke/wb-spec.json /tmp/qlik-smoke/control-scope.json`.

## corectl-country-unbuild/

A synthetic standard `corectl unbuild` folder. It intentionally has empty
`measures.json` and `dimensions.json`; both authored visuals are nested under the
sheet's recursive `qChildren`. Its load script also defines
`If(Match(COUNTRY, ...)) AS REGION_GROUP`, proving calculated LOAD fields survive
on the denormalized SQL element.

```bash
export SIGMA_OFFLINE_DRY_RUN=1
bash scripts/bootstrap.sh --runtime-profile python --workdir /tmp/qlik-corectl-smoke
python3 scripts/migrate-qlik.py \
  --unbuild fixtures/corectl-country-unbuild \
  --connection 00000000-0000-0000-0000-000000000000 \
  --database ANALYTICS --schema PUBLIC --dry-run --yes --out /tmp/qlik-corectl-smoke
```

Expected: `workbook-coverage.json` reports 2/2 source visuals and the generated
SQL contains `CASE WHEN f.COUNTRY IN ('US', 'CA') ... AS REGION_GROUP`.
