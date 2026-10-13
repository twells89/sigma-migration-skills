# spotfire / retail-smoke

Synthetic, sanitized Spotfire Application API manifest for a two-page sales
analysis. The case references the plugin fixture in place and exercises the
supported customer-side manifest boundary; it does not treat raw DXP internals
as conversion-grade input.

## Artifacts

| File | What it is |
|---|---|
| `plugins/.../fixtures/spotfire-manifest.json` | Authoritative neutral manifest with model, presentation, automation, and security evidence |
| `plugins/.../fixtures/source-map.json` | Explicit mapping from imported/embedded/on-demand/data-function tables to warehouse targets |
| `checks.sh` | Offline validation, gap census, conversion, lint, dry-run gate, and byte-golden checks |

## Features exercised

- four landed source modes and fail-closed warehouse source resolution
- a calculated column plus one relationship
- table, cross-table, KPI, bar, line, area, combo, pie, donut, and scatter visuals
- filtering-scheme and page controls
- complete normalized 24-column layout
- loud findings for a Mod, script, data function, marking, bookmark, source
  export diagnostic, document-property consumer, and security review
- dry-run state proving no reuse scan, Sigma write, parity, render, or success
  stamp occurred

## Converter

```sh
bash corpus/spotfire/retail-smoke/checks.sh
./corpus/run-corpus.sh --check spotfire
```

The converter is local Python and uses only the standard library. Goldens are
normalized through the ordinary corpus normalizer.

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/spotfire-to-sigma/skills/spotfire-to-sigma/fixtures/spotfire-manifest.json", "format": "json"},
    {"path": "../../../plugins/spotfire-to-sigma/skills/spotfire-to-sigma/fixtures/source-map.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 4,
      "columns": 15,
      "metrics": 0,
      "relationships": 1,
      "warnings": 0,
      "element_names": ["Sales", "Customers", "Targets", "Scores"],
      "relationship_names": ["Customers"]
    },
    "workbook.json": {
      "pages": 3,
      "elements": 17,
      "columns": 41,
      "metrics": 0,
      "relationships": 0,
      "warnings": 0
    },
    "gap-report.json": {}
  }
}
```
