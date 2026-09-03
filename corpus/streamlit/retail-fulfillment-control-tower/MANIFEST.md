# Streamlit retail fulfillment control tower

Synthetic four-page Streamlit-in-Workspaces project covering external static SQL,
shared deferred sidebar filters, synced controls, navigation, KPI helpers,
progress, grouped charts/scatter, ranked tables, conditional empty states,
popover content, custom sort, and browser CSV download.

## Converter

```bash
python3 plugins/streamlit-to-sigma/skills/streamlit-to-sigma/scripts/streamlit-convert.py \
  plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/retail-fulfillment-control-tower \
  --connection connection-placeholder \
  --folder folder-placeholder \
  --name "Retail Fulfillment Control Tower Fixture" \
  --out-dir /tmp/streamlit-retail-fulfillment
```

## Expectations

```json
{
  "artifacts": [
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/retail-fulfillment-control-tower/streamlit_app.py",
      "format": "text"
    },
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/retail-fulfillment-control-tower/snowflake.yml",
      "format": "yaml"
    },
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/retail-fulfillment-control-tower/pyproject.toml",
      "format": "toml"
    },
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/retail-fulfillment-control-tower/.streamlit/config.toml",
      "format": "toml"
    },
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/retail-fulfillment-control-tower/app_pages/executive.py",
      "format": "text"
    },
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/retail-fulfillment-control-tower/app_pages/fulfillment.py",
      "format": "text"
    },
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/retail-fulfillment-control-tower/app_pages/returns.py",
      "format": "text"
    },
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/retail-fulfillment-control-tower/app_pages/exceptions.py",
      "format": "text"
    },
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/retail-fulfillment-control-tower/lib/data.py",
      "format": "text"
    },
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/retail-fulfillment-control-tower/lib/filters.py",
      "format": "text"
    },
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/retail-fulfillment-control-tower/lib/metrics.py",
      "format": "text"
    },
    {
      "path": "../../../plugins/streamlit-to-sigma/skills/streamlit-to-sigma/fixtures/retail-fulfillment-control-tower/sql/orders.sql",
      "format": "text"
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
      "columns": 17,
      "metrics": 0,
      "relationships": 0,
      "warnings": 0
    },
    "workbook.json": {
      "pages": 5,
      "elements": 82,
      "columns": 70,
      "metrics": 0,
      "relationships": 0,
      "warnings": 0
    }
  }
}
```
