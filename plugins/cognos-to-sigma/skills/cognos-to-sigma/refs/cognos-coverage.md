# Cognos → Sigma — dashboard/report classifier coverage matrix

> **Grounding note (beads-sigma-kvza).** Unlike the other migration skills (whose
> classifiers LOAD JSON catalogs via `coverage_catalog.{py,rb}`), cognos-to-sigma's
> classifier is **TypeScript bundled to `converter/cli.mjs`** (from `converter/cognos-report.ts`).
> There is no TS catalog loader, so cognos's maps are grounded as **cited constants in
> the TS source** with a **loud fallback** on anything unmapped — and documented here.
> A machine-loaded TS catalog would be the same shape and belongs with the converter
> (lanq) track. Every mapped Sigma target is a real, current Sigma construct.

Cognos was already the most loud of the classifiers (an unknown visual degrades to a
**warned table**, never a silent chart; number formats are read from the report's
`currencyFormat`/`percentFormat`/`numberFormat` nodes, never guessed from a column
name). This pass closed the one remaining silent default: an **unmapped Cognos
aggregate / rollup no longer silently becomes `Sum`** — it warns first.

## Visualization / chart kind
Source: `cognos-report.ts` `VIZ_KIND` (+ `VIZ_NOANALOG`). Cognos `com.ibm.vis.*` → Sigma element kind.
Authoritative source: <https://www.ibm.com/docs/en/cognos-analytics> (visualization types).

| Cognos vizType | Sigma target | on-unmapped |
|---|---|---|
| `com.ibm.vis.clusteredbar` / `stackedbar` / `clusteredcolumn` / `stackedcolumn` | `bar-chart` | — |
| `com.ibm.vis.line` / `spline` | `line-chart` | — |
| `com.ibm.vis.area` / `stackedarea` | `area-chart` | — |
| `com.ibm.vis.pie` | `pie-chart` | — |
| `com.ibm.vis.donut` | `donut-chart` | — |
| `com.ibm.vis.clusteredcombination` / `stackedcombination` | `combo-chart` | — |
| `com.ibm.vis.bubble` / `scatter` | `scatter-chart` | — |
| _unknown vizType_ | — (no native equivalent) | **loud warn + emit the data as a `table`** (`cognos-report.ts` `if (!kind)`) — never a silent concrete chart |

## Aggregation
Source: `cognos-report.ts` `AGG` (list footer/dataItem) + `ROLLUP_AGG` (chart rollup). Cognos aggregate/rollup → Sigma aggregate function.
Authoritative source: IBM Cognos regularAggregate / rollup; Sigma <https://help.sigmacomputing.com/docs/aggregate-functions>.

| Cognos aggregate/rollup | Sigma target | on-unmapped |
|---|---|---|
| `total` / `summary` / `aggregate` / `calculated` / `sum` | `Sum` | — |
| `average` / `avg` | `Avg` | — |
| `count` | `Count` | — |
| `countdistinct` | `CountDistinct` | — |
| `maximum` | `Max` | — |
| `minimum` | `Min` | — |
| _unmapped aggregate/rollup_ | `Sum` (degraded) | **loud warn** ("unmapped Cognos aggregate/rollup '…' — defaulted to Sum (degraded); verify parity") — was a silent `\|\| 'Sum'` before this pass |

## Number format
Source: `cognos-report.ts` `formatFromNode` — reads the report's `currencyFormat` / `percentFormat` / `numberFormat` nodes (decimals from `@_decimalSize`, SI scaling from `@_scale`/`K`/`M`/`B`). Currency `$,.Nf` / `$,.Ns`, percent `,.N%`, number `,.Nf`.
| Cognos format node | Sigma target | on-unmapped |
|---|---|---|
| `currencyFormat` | `$,.<dec>f` (or `$,.<dec>s` scaled) | — |
| `percentFormat` | `,.<dec>%` | — |
| `numberFormat` | `,.<dec>f` (or `$,.<dec>s` scaled) | — |
| _no format node_ | `undefined` (Sigma type default) | benign — **no name-substring currency guessing** (contrast the other tools' disease) |

## Control / filter
Source: `cognos-report.ts` — Cognos `prompt('p',…)` → Sigma `segmented` control; detail filters → element `filters` (list, include/exclude); a macro measure-swap prompt → control + `Switch(...)`.
| Cognos construct | Sigma target | on-unmapped |
|---|---|---|
| `prompt(...)` parameter | `segmented` control (values from `<selectValue>`) | empty options → **warn** ("no `<selectValue>` options — emitted an empty segmented control; add values in Sigma") |
| detail filter (`= value`) | element `filters` (kind `list`, mode include/exclude) | — |
| `?prompt?` comparison | segmented control + boolean match column + list filter on `[true]` | — |

---
_The Cognos expression translator (`translateCognosExpr`), the crosstab/list grouping
logic, and the band layout are compositional and stay as cited code — this matrix
covers the enumerable maps. Re-bundle `converter/cli.mjs` from `converter/cognos-report.ts`
after any map change (esbuild; see `tools/vendor-converters.sh` cognos case)._
