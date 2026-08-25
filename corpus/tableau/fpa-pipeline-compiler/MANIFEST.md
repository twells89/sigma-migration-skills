# tableau / fpa-pipeline-compiler

Sanitized recorded-live pipeline-reuse evidence. This is deliberately a WIP
negative promotion control: structural reuse works, while semantic KPI/filter/
pivot/no-data defects must remain visible until fixed.

## Expectations

```json
{
  "artifacts": [
    {"path": "evidence.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
