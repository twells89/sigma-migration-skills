# Visual QA (Spotfire)

Warehouse verification proves that posted Sigma elements evaluate and return
data. It does not prove fidelity to rendered Spotfire pages.

After the live orchestrator reaches exit `16`:

1. Capture each source Spotfire page in a controlled viewport.
2. Export the corresponding Sigma page/element images with
   `scripts/sigma-export-png.py`.
3. Compare visual census, chart type, titles, axes, series, controls, ordering,
   and material layout differences. Record every compared pair and reviewer
   result.
4. Supply a JSON evidence file to `--source-visual-evidence`:

```json
{
  "status": "PASS",
  "verified_against": "spotfire-render",
  "workbook_id": "posted-sigma-workbook-id",
  "source_artifact_sha256": "manifest-source-sha256",
  "pages_total": 1,
  "pages_pass": 1,
  "pages_fail": 0,
  "evidence": [
    {
      "source_page_id": "page:overview",
      "spotfire_page": "Overview",
      "sigma_page": "Overview",
      "source_capture": "evidence/spotfire-overview.png",
      "source_capture_sha256": "<sha256>",
      "sigma_capture": "evidence/sigma-overview.png",
      "sigma_capture_sha256": "<sha256>",
      "reviewer": "customer",
      "result": "PASS"
    }
  ]
}
```

The evidence path is resolved relative to the JSON ledger. The orchestrator
recomputes both image hashes, rejects duplicate/missing source page IDs, and
requires exactly one PASS record for every manifest page that contains a
visual. This closes the source-visual checkpoint only. It does not change
`source_parity_claimed=false`; the numeric gate remains explicitly
warehouse-only.
