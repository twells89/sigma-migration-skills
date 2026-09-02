# Blind visual grader handoff

`migrate-domo.rb` writes `visual-grade-request.json` after rendering and strict
value parity. A fresh vision-capable agent receives only that request, its two
images, and `layout-visual-qa.md`. It must not receive the migration transcript,
workbook spec, parity result, or expected verdict.

Read the source image first and independently enumerate its visualization tiles
left-to-right, top-to-bottom. Then read the target independently. Use only these
families:

`bar | line | area | combo | scatter | pie | kpi | map | table | text | control | image | missing`

Grade all six dimensions against `layout-visual-qa.md`:

- `element_titles_hidden`
- `palette_match`
- `composition_match`
- `chart_shapes_match`
- `labels_legible`
- `numbers_formatted`

Every dimension is `pass` or `fail` with one sentence of pixel evidence.
Overall `pass` requires all six to pass and no chart-family substitution.
Source-application navigation/action chrome is not a visualization tile.

Hash both image files and write only the request's `output_json`:

```json
{
  "schema": "blind-grade/v1",
  "source_png": "/absolute/source.png",
  "target_png": "/absolute/target.png",
  "source_sha256": "<64 hex>",
  "target_sha256": "<64 hex>",
  "dimensions": {
    "element_titles_hidden": {"verdict": "pass", "evidence": "..."},
    "palette_match": {"verdict": "pass", "evidence": "..."},
    "composition_match": {"verdict": "pass", "evidence": "..."},
    "chart_shapes_match": {"verdict": "pass", "evidence": "..."},
    "labels_legible": {"verdict": "pass", "evidence": "..."},
    "numbers_formatted": {"verdict": "pass", "evidence": "..."}
  },
  "per_tile": [
    {"position": "r1c1", "source_family": "kpi", "target_family": "kpi"}
  ],
  "verdict": "pass",
  "top_gaps": []
}
```

`per_tile` must be an array covering every observed source/target tile. Never
soften `fail` to help the builder. On completion, rerun the exact same
`migrate-domo.rb` command; it consumes and validates the grade automatically.
