# tableau / pipeline-reuse-smoke

Offline fixture for the reviewed workbook-pipeline reuse seam: copy a donor
pipeline element, route the generated page master, apply a semantic constant,
rewrite a metric formula, and normalize a structured display name.

## Expectations

```json
{
  "artifacts": [
    {"path": "donor.json", "format": "json"},
    {"path": "generated.json", "format": "json"},
    {"path": "pipeline-map.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
