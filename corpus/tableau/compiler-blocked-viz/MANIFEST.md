# tableau / compiler-blocked-viz

Synthetic compile-plan negative control. A bound but unsupported radial-tree
visual must produce `viz.unknown.v1` and strict compiler exit 2 before any live
write.

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-ir.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
