# Schema hints

Static SQL projection inference works for explicit `SELECT` columns and aliases.
It intentionally does not query the warehouse or execute the app.

Hints are required before posting when:

- SQL uses `SELECT *`.
- output columns come from a stored procedure/table function;
- dynamic SQL changes the projection;
- a dataframe is constructed outside a recognized SQL loader;
- source column types/formats are needed for an ambiguous chart/control.

Recommended project-side file:

```yaml
queries:
  load_orders:
    columns:
      - {name: Order Id, type: text}
      - {name: Order Date, type: datetime}
      - {name: Revenue, type: number, semantic: currency}
dataframes:
  filtered:
    rootQuery: load_orders
controls:
  Region:
    dataframe: filtered
    column: Region
```

The CLI does not yet consume this YAML automatically. Treat this as
the stable design contract for the next implementation increment; until then,
replace unresolved values in `streamlit-ir.json` through an explicit,
reviewed preprocessing step.

Never use hints to conceal dynamic SQL or unsupported logic. Keep the
corresponding gap and document why the hint is equivalent.
