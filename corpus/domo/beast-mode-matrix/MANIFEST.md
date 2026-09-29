# domo / beast-mode-matrix

Sanitized synthetic discovery fixture generated from a disposable 2026-09-23
live Domo acceptance page. It covers every source-valid formula family measured
in that run: FIXED BY/ADD/REMOVE/filter policies/percent totals, running/ranking/
shifting windows, aggregate edge cases, LIKE/BETWEEN and mixed CASE expressions,
date/time functions (including field-reported `CURDATE()`/numeric-`CONCAT`
CASE shapes), timezone conversion, legacy function aliases, `LENGTH()` /
`SUBSTRING()` text handling, and Domo-valid block/line comments.

The original live source had 37 cards. Domo served values for 35; `PERCENT_RANK` failed
with “Not a valid analytic function,” and `MICROSECOND` was marked
`ILLEGAL_FUNCTION` and failed card-data/render. Those two formulas are retained
as fail-closed fixtures. A later live Domo card added the exact
`CASE WHEN date > CURDATE()` regression and passed strict Sigma parity. Two
additional live cards proved that `/* ... */` and `-- comment` formulas also
migrate with strict parity. Domo rejected `# comment` as `PARSING_ERROR`.

## Live evidence

- 36/36 source-valid cards produced Sigma elements with zero error columns.
- Every live-tested source-valid card passed strict Domo-card-data versus
  Sigma-export parity, including the exact `CURDATE()` regression and both
  source-valid comment forms.
- Eight hidden helper elements (FIXED grain and SUM DISTINCT) were excluded from
  source parity by design; every visible source card remained in the denominator.
- No formula override or generated-spec edit was used.

## Artifacts

| File | Purpose |
|---|---|
| `fixtures/datasets.json` | Synthetic 20-column workforce/sales schema |
| `fixtures/cards.json` | 36 source-valid formula cards with stable sanitized ids |
| `fixtures/beast-modes.json` | Raw Domo SQL for 40 formulas (36 card formulas + dataset-level date/comment/text regressions) |
| `fixtures/dataset-map.json` | Synthetic mapping used to exercise data-model formula placement |
| `fixtures/blocked-beast-modes.json` | Two live-proven source-invalid formulas |
| `checks.sh` | Runs the real vendored converter and workbook builder, then asserts every translation, placement, helper, and fail-closed disposition |

## Expectations

```json
{
  "artifacts": [
    {"path": "fixtures/datasets.json", "format": "json"},
    {"path": "fixtures/cards.json", "format": "json"},
    {"path": "fixtures/beast-modes.json", "format": "json"},
    {"path": "fixtures/dataset-map.json", "format": "json"},
    {"path": "fixtures/blocked-beast-modes.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
