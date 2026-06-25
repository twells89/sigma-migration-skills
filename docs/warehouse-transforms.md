# Warehouse-Specific SQL Transforms

Sigma cannot render array or nested types in table cells. Source tools (Metabase, Tableau, Qlik, etc.) often emit SQL that produces these types — the migrated workbook will show blank cells or errors until the SQL is rewritten to return a scalar string instead.

## Detection

Always detect the warehouse from the Sigma connection before converting:

```bash
# In any skill script (Python)
from warehouse_transforms import detect_warehouse
warehouse = detect_warehouse(os.environ["SIGMA_BASE_URL"], os.environ["SIGMA_API_TOKEN"], connection_id)

# In any skill script (Ruby)
require_relative '../shared/lib/warehouse_transforms'
warehouse = WarehouseTransforms.detect(ENV["SIGMA_BASE_URL"], ENV["SIGMA_API_TOKEN"], connection_id)
```

Or via curl:
```bash
WAREHOUSE=$(curl -s "$SIGMA_BASE_URL/v2/connections/<id>" \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('type','unknown'))")
```

## Array Aggregation → String Aggregation

| Warehouse | Source pattern | Rewritten to |
|---|---|---|
| BigQuery | `ARRAY_AGG(x [IGNORE NULLS])` | `array_to_string(ARRAY_AGG(x [IGNORE NULLS]), ', ')` |
| Snowflake | `ARRAY_AGG(x)` | `LISTAGG(x, ', ')` |
| Databricks | `collect_list(x)` | `array_join(collect_list(x), ', ')` |
| Redshift / Postgres | `ARRAY_AGG(x)` | `STRING_AGG(CAST(x AS VARCHAR), ', ')` |
| Athena | `ARRAY_AGG(x)` | `array_join(array_agg(x), ', ')` |
| MySQL | `GROUP_CONCAT(x)` | already a string — no change needed |

## Applying Transforms

```python
# Python
from warehouse_transforms import apply_transforms
sql = apply_transforms(raw_sql, warehouse)   # no-op if warehouse == 'unknown'
```

```ruby
# Ruby
require_relative '../shared/lib/warehouse_transforms'
sql = WarehouseTransforms.apply(raw_sql, warehouse)
```

The metabase-to-sigma converter applies these automatically when `--warehouse` is passed (or auto-detected from the Sigma connection). For other skills, call `apply_transforms` after generating or extracting SQL, before writing it to the spec.

## Other Warehouse Gotchas (not yet automated)

These require case-by-case handling; document them in the skill's refs/ as they're discovered:

| Issue | BigQuery | Snowflake | Databricks |
|---|---|---|---|
| Identifier quoting | backticks `` `table` `` | double quotes `"table"` | backticks or none |
| Date trunc syntax | `DATE_TRUNC(date, WEEK)` | `DATE_TRUNC('week', date)` | `DATE_TRUNC('week', date)` |
| String concat | `CONCAT(a, b)` or `a || b` (BQ std) | `a || b` or `CONCAT` | `CONCAT` or `a || b` |
| Regex | `REGEXP_CONTAINS(x, r)` | `REGEXP_LIKE(x, p)` | `x RLIKE p` |
| ILIKE | not supported — use `LOWER(x) LIKE LOWER(y)` | supported | not supported |
| Struct/nested fields | `x.field` | `x:field` (semi-structured) | `x.field` |
