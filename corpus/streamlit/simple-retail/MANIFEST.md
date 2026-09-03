# Streamlit simple retail

Synthetic Streamlit-in-Workspaces project covering a SQL loader, sidebar
multiselect, dataframe filter, three KPIs, tabs, bar chart, and detail table.
No credentials or live organization identifiers are required.

## Artifacts

| Artifact | Purpose |
|---|---|
| `fixtures/simple-retail/streamlit_app.py` | Source Streamlit app |
| `golden/data-model.json` | Normalized DM candidate |
| `golden/workbook.json` | Normalized workbook code representation |
| `checks.py` / `checks.sh` | Offline byte-stable reconversion |

## Converter

```bash
python3 plugins/streamlit-to-sigma/skills/streamlit-to-sigma/scripts/streamlit-convert.py \
  plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/simple-retail \
  --connection connection-placeholder \
  --folder folder-placeholder \
  --name "Streamlit Retail Fixture" \
  --out-dir /tmp/streamlit-simple-retail
```

## Expectations

```json
{
  "artifacts": [
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/simple-retail/streamlit_app.py",
      "format": "text"
    },
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/simple-retail/snowflake.yml",
      "format": "yaml"
    },
    {
      "path": "checks.py",
      "format": "text"
    },
    {
      "path": "checks.sh",
      "format": "text"
    }
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 1,
      "columns": 6,
      "metrics": 0,
      "relationships": 0,
      "warnings": 0,
      "element_names": [
        "Load Sales"
      ],
      "metric_names": [],
      "relationship_names": []
    },
    "workbook.json": {
      "pages": 2,
      "elements": 11,
      "columns": 17,
      "metrics": 0,
      "relationships": 0,
      "warnings": 0,
      "element_names": [
        "Data — Load Sales",
        "Region",
        "id0010",
        "Revenue",
        "Profit",
        "Orders",
        "Bar Chart",
        "Detail",
        "id0027",
        "id0028",
        "id0029"
      ],
      "metric_names": [],
      "relationship_names": []
    }
  }
}
```
