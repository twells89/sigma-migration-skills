# Source-value anchors — the measured value bar

## Why this exists

Two field migrations shipped dashboards whose **numbers were wrong** while every
judgment gate recorded "pass":

1. **The 10x/ranking failure.** A "top members" ranked panel showed *different
   members* with values ~10x off — the migrated dashboard rendered **"$1.2T"**
   where the source printed **"12,345B"** (≈ $12.3T). A multi-region YoY panel
   collapsed to **one bar where the source showed six**, and a trend line
   crashed to zero on a partial final period. The run followed the pipeline,
   executed a real 3-pass RCF loop *reading* the render PNGs — and still
   recorded `--verdict pass`.
2. **The waiver-stacking failure.** A second workbook "passed" by combining
   `--skip-parity-gate` with `--allow-missing-tiles 6`, discovered by grepping
   `--help` for skip flags. Nothing measured the values; every gate that could
   have was waived.

The lesson: **every judgment gate is an attestation, and lenient models attest
generously.** Visual verdicts, RCF scoring, and parity waivers are all places
where "looks right" substitutes for "is right." Anchors replace that judgment
with a **measurement**: printed values transcribed from the source image either
appear in the live workbook's exports at the printed precision, or they don't.

A printed source value that appears **nowhere** in the workbook exports is the
loudest possible signal the data is wrong — wrong unit (10x), wrong aggregate,
missing filter, collapsed buckets, or the wrong column entirely.

## The contract

### `source-anchors.json` — authored BY THE AGENT at Phase 1d

Written **while reading the source dashboard PNG** (the same read that produces
`png-read.json`). Never generated from CSVs — the whole point is transcribing
what the source *renders*.

```json
{
  "source_image": "views/<dashboardViewId>.png",
  "transcribed_at": "2026-07-08T12:00:00Z",
  "anchors": [
    { "id": "a1",
      "panel": "TOP ACCOUNTS",
      "label": "United Widgets revenue",
      "raw": "12,345B",
      "kind": "currency",
      "provenance": "view-csv",
      "sigma_element_hint": "Top Accounts" }
  ]
}
```

- `raw` — the value **EXACTLY as printed**. Keep the raw string: `"12,345B"`,
  never `12345`; `"(12.3%)"`, never `-0.123`; `"$733,215.26"` with the `$` and
  commas. The printed form *is* the precision contract.
- `provenance` — where the transcribed value CAME from (PR-6):
  `view-csv` (read off a Tableau view CSV export), `vds` (read off a VizQL
  Data Service query), or `png-eyeball` (eyeball-transcribed from the
  dashboard PNG). **Prefer `view-csv`/`vds` whenever the value is available
  there** — the field sessions mis-read rendered `##`/abbreviated values off
  PNGs. Provenance never changes whether an anchor MATCHES; it changes what
  the match is worth: a **VALUED** anchor (numeric + provenance
  `view-csv`|`vds`) can vouch numerically for a tile; `png-eyeball` and
  name-only (`text`/`roster`) anchors earn **no** tile-coverage credit —
  neither toward the G10 coverage floor nor toward gate 18's valued-anchors
  credit (legacy anchors without the field keep G10 credit but are never
  valued).
- `kind` — `currency` | `number` | `percent` | **`text`** (alias `roster`/`member`).
  A `text` anchor's `raw` is a **displayed LABEL** (case-insensitive cell match),
  not a value — use it for ranked/top-N tiles so a wrongly-selected or dropped
  member fails loudly (a top-15 materialized from the wrong rank, a renamed
  category, a missing path label). Scope: exports carry the element's full
  underlying data, so `text` anchors can't catch an UNFILTERED tile that merely
  windows the wrong first-N on screen — gate 9b (shape identity) owns that class.
- `sigma_element_hint` — optional; the Sigma element name the value should land
  in. When present it wins over fuzzy matching.
- **Minimum anchors (the gate requires ≥ 5):** every KPI value, the **top 3
  values of every ranked list/table**, **one representative bucket value
  per chart**, and — for every ranked/top-N tile — **2–3 `text` roster anchors**
  naming members the source actually displays (include at least one from the
  BOTTOM half of the list: top members often survive a wrong ranking, bottom
  members don't). Top-of-ranked-list anchors are what catch the
  different-members-with-different-values failure.
- **Coverage rule — anchor EVERY tile (G10, run-2 field failure).** An anchor
  only vouches for the tile it lands in: a run shipped 11 anchors that all sat
  in 3 of 9 tiles, and the anchors oracle "passed" while 6 tiles had ZERO
  anchors watching them. `verify-anchors.rb` measures per-displayed-tile
  coverage (an anchor covers a tile when it **matched in** it, or its
  `sigma_element_hint` token-matches the tile name) and writes
  `anchor_coverage {covered, displayed, uncovered:[names]}` into the verdict
  (WARN on uncovered). A tile that genuinely prints no anchorable value must be
  waived **here, at transcription time**:
  ```json
  "coverage_waivers": [ { "tile": "<tile display name>", "reason": "<why no anchorable value>" } ]
  ```
  (top-level key, next to `anchors`). On the all-embedded (`charts_total==0`)
  anchors-ORACLE path, `assert-phase6-ran` refuses the substitution unless
  `covered == displayed` or every uncovered tile is coverage-waived; on the
  normal parity path it is a WARN.

### `anchors-verdict.json` — written by `scripts/verify-anchors.rb`

```json
{ "checked": 9, "matched": 8,
  "missing": [ { "id": "a1", "label": "United Widgets revenue", "raw": "12,345B",
                 "best_candidate": { "value": 1.2e12, "element": "Top Accounts" } } ],
  "pass": false }
```

`verify-anchors.rb --workdir <W> --workbook-id <id>` pools the live workbook's
element CSV exports (the same export→poll→download flow
`collect-parity-actuals.rb` uses) and searches each anchor in the element whose
name best matches its label/panel (token overlap; the hint wins). A **hinted**
anchor — numeric (#414) or text/roster (PR-6) — searches ONLY hint-matched
elements: found-only-outside the asserted location is a MISS (the loophole that
silently passed 10x-unit/wrong-aggregate defects living in big detail tables).
Hint-less anchors keep the search-everywhere fallback; found-elsewhere still
matches and is noted. Every detail/missing row carries the anchor's `kind` +
`provenance` + `valued` so downstream consumers (G10 coverage,
`verify-ground-truth.rb`, gate 18) apply the credit rules without re-reading
the anchors file; the verdict also records `valued_matched` and a
`provenance_census`. It stamps an `anchors` summary into `parity-final.json`
when present. Exit 0 all matched / 1 with a per-miss report naming each miss
and its closest candidate.

## Coexistence with the warehouse ground-truth oracle (PR-6)

**Anchors are rendered-source truth; the tile-grain ground-truth oracle
(`refs/ground-truth-oracle.md` — Tableau today; other converters adopt when
they emit a `ground-truth-plan.json` ledger) is warehouse truth.** They verify different
things and neither subsumes the other: the oracle proves the built tile
computes the right SQL over the warehouse; anchors prove the workbook shows
what the source *rendered*. When they disagree, `verify-ground-truth.rb` is
**FATAL-investigate, never auto-resolved**:

- oracle diverges but anchors matched → **data bug** (warehouse drifted/wrong,
  or a wrong ground-truth derivation);
- anchors diverge but oracle matches → **translation/source-reading bug**
  (Sigma faithfully computes the WRONG semantics);
- both match → verified by two independent oracles.

Both sides' evidence is printed; never edit either oracle to force agreement.

## Canonicalization rules (`scripts/lib/anchor_values.rb`)

**Match rule:** a printed value MATCHES a real number when the real number
**rounds to the printed form at the printed precision** — i.e.
`|actual − printed| ≤ half of the last printed digit's place value`, scaled by
any suffix.

| Printed | Canonical value | Tolerance | Notes |
|---|---|---|---|
| `12,345B` | 1.2345e13 | ±0.5e9 | last digit = units of B |
| `$1.2T` | 1.2e12 | ±0.05e12 | currency; one decimal of T |
| `46.5M` | 4.65e7 | ±0.05e6 | |
| `-2%` | −2 points | ±0.5 | also matches the fraction −0.02 ± 0.005 |
| `1,687` | 1687 | ±0.5 | |
| `$733,215.26` | 733215.26 | ±0.005 | cents precision |
| `(12.3%)` | −12.3 points | ±0.05 | accounting-paren negative |
| `12.3k` | 12300 | ±50 | lowercase suffixes accepted |

Extra interpretations checked (they never weaken 10x detection):

- Suffixed forms also match the **unscaled face value** (`12,345B` ↔ a column
  already denominated in billions storing `12345`).
- Percents match both **points** (−2) and **fraction** (−0.02) storage.

So `1.2e12` does **not** match `12,345B` under any interpretation — the exact
field failure — while `12,344,800,000,000` (rounds to 12,345B) does.

## Worked example

Source image shows a KPI `$45.6T`, a TOP ACCOUNTS list headed by
`United Widgets 12,345B`, `Acme Holdings 9,876B`, `Initech 4,321B`, and a YoY panel with
`-2%` on one bucket:

```json
{ "source_image": "views/abc123.png", "transcribed_at": "2026-07-08T15:04:00Z",
  "anchors": [
    { "id": "a1", "panel": "KPI",           "label": "Global revenue total", "raw": "$45.6T",  "kind": "currency" },
    { "id": "a2", "panel": "TOP ACCOUNTS", "label": "United Widgets",   "raw": "12,345B", "kind": "number", "sigma_element_hint": "Top Accounts" },
    { "id": "a3", "panel": "TOP ACCOUNTS", "label": "Acme Holdings",           "raw": "9,876B", "kind": "number", "sigma_element_hint": "Top Accounts" },
    { "id": "a4", "panel": "TOP ACCOUNTS", "label": "Initech",           "raw": "4,321B",  "kind": "number", "sigma_element_hint": "Top Accounts" },
    { "id": "a5", "panel": "YOY BY REGION", "label": "largest decline bucket", "raw": "-2%", "kind": "percent" }
  ] }
```

If the built workbook's Top Accounts element exports `1.2e12` for the top row,
`verify-anchors.rb` reports:

```
MISSING  a2 "United Widgets" raw="12,345B" — closest candidate 1.2e12 in "Top Accounts"
```

— the 10x failure caught mechanically, before any visual verdict is consulted.

## Gate wiring (`assert-phase6-ran.rb`)

- **Gate 13 (exit 18):** whenever the workdir carries a source dashboard PNG
  (the Phase 1d artifact — `png-read.json` `source_png`, `views/*.png`, or
  `dashboards/*.png`), `source-anchors.json` must exist with ≥ 5 anchors AND
  `anchors-verdict.json` must pass with every anchor checked (a stale verdict —
  fewer checked than transcribed — fails). No source PNG → stated SKIP.
  Escape: `--skip-anchors-gate "<reason>"` (counted against the waiver budget).
- **Conditional `--skip-parity-gate` (exit 18):** waiving source parity is
  REJECTED unless `anchors-verdict.json` exists and passes. The anchors oracle
  replaces parity — never nothing. This is the no-standalone-views path's
  contract too: parity oracle = anchors + warehouse (`verify-warehouse.rb`).
- **Anchors-ORACLE substitution coverage floor (`charts_total==0`, exit 2):**
  when the oracle stands in for an all-embedded workbook, ALL FOUR must hold —
  (a) every anchor matched, (b) every visual-verify tile confirmed, (c) every
  displayed tile exports ≥1 data row, and (d) **anchor coverage**:
  `anchor_coverage.covered == displayed`, or every uncovered tile named in
  `coverage_waivers`. A verdict predating the coverage measurement fails closed
  (re-run `verify-anchors.rb`). On the normal parity path, uncovered tiles are
  a WARN only (each tile is still chart-by-chart parity-verified there).
- **Data-class RCF residuals (exit 15):** any unresolved `data`-class entry in
  `fidelity-ledger.json` blocks GREEN whenever the ledger exists —
  `--accept-residuals` does not apply. The numbers are wrong; fix or reclassify
  with evidence.
- **Waiver budget (exit 19):** more than 2 quality waivers → GREEN unavailable
  (YELLOW cap). Anchors and similarity skips count; the sanctioned
  builder→verifier `--skip-visual-comparison` handoff does not.
