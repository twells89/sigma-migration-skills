# domo / beast-mode-matrix

Sanitized synthetic discovery fixture generated from a disposable 2026-09-23
live Domo acceptance page. It covers every source-valid formula family measured
in that run: FIXED BY/ADD/REMOVE/filter policies/percent totals, running/ranking/
shifting windows, aggregate edge cases, LIKE/BETWEEN and mixed CASE expressions,
date/time functions, timezone conversion, and legacy function aliases.

The live source had 37 cards. Domo served values for 35; `PERCENT_RANK` failed
with “Not a valid analytic function,” and `MICROSECOND` was marked
`ILLEGAL_FUNCTION` and failed card-data/render. Those two formulas are retained
as fail-closed fixtures.

## Live evidence

- 35/35 source-valid cards produced Sigma elements with zero error columns.
- 35/35 passed strict Domo-card-data versus Sigma-export parity.
- Eight hidden helper elements (FIXED grain and SUM DISTINCT) were excluded from
  source parity by design; every visible source card remained in the denominator.
- No formula override or generated-spec edit was used.

## Artifacts

| File | Purpose |
|---|---|
| `fixtures/datasets.json` | Synthetic 17-column workforce/sales schema |
| `fixtures/cards.json` | 35 source-valid formula cards with stable sanitized ids |
| `fixtures/beast-modes.json` | Raw Domo SQL for those 35 cards |
| `fixtures/blocked-beast-modes.json` | Two live-proven source-invalid formulas |
| `checks.sh` | Runs the real vendored converter and workbook builder, then asserts every translation, placement, helper, and fail-closed disposition |

## Expectations

```json
{
  "artifacts": [
    {"path": "fixtures/datasets.json", "format": "json"},
    {"path": "fixtures/cards.json", "format": "json"},
    {"path": "fixtures/beast-modes.json", "format": "json"},
    {"path": "fixtures/blocked-beast-modes.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
