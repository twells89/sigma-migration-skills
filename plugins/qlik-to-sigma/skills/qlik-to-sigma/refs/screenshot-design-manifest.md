# Screenshot design manifest

The Qlik converter uses source screenshots as an agent-reviewed build input.
Scripts seed and validate this file; an image-capable agent supplies the visual
interpretation. No script claims to infer chart semantics from pixels.

```json
{
  "schemaVersion": 1,
  "status": "approved",
  "iteration": 1,
  "pages": [
    {
      "sheetId": "sheet-overview",
      "title": "Executive Overview",
      "sourceImage": "/work/source-pages/sheet-overview.png",
      "columns": 24,
      "rows": 18,
      "reviewed": true,
      "tiles": [
        {
          "objectId": "chart-revenue",
          "sourceKind": "barchart",
          "kind": "bar-chart",
          "title": "Revenue by Region",
          "orientation": "horizontal",
          "legend": "hidden",
          "grid": {
            "col": 0,
            "row": 6,
            "colspan": 12,
            "rowspan": 8
          },
          "reviewed": true,
          "notes": [
            "Source screenshot shows ranked horizontal bars."
          ]
        }
      ]
    }
  ]
}
```

## Contract

- `status` must be `approved` before any Sigma write.
- Every page and tile must have `reviewed: true`.
- Every `sourceImage` must exist.
- Every tile `objectId` must exist in `charts.json`.
- `kind` is `keep` or a released Sigma workbook kind accepted by the validator.
- `grid` uses the source sheet coordinate system and must stay within
  `columns` × `rows`.
- The manifest can change visual interpretation and composition, but never
  formulas, source fields, security, or parity expectations.

## Loop

1. First run seeds `design-manifest.json` and exits 10.
2. Agent reads each source image, completes and approves the manifest.
3. Rerun builds and renders.
4. A failed visual gate writes `design-iteration-request.json`.
5. Agent compares source/target images, revises the manifest, increments
   `iteration`, and reruns with `--workbook-id` to update in place.
