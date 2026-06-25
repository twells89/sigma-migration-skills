"""
Warehouse-specific SQL transforms for Sigma migration skills.

Usage:
    from warehouse_transforms import apply_transforms, detect_warehouse

    warehouse = detect_warehouse(sigma_base, token, connection_id)
    clean_sql  = apply_transforms(raw_sql, warehouse)

Warehouses: bigquery | snowflake | databricks | redshift | postgres | mysql | athena | unknown
"""

import re
import urllib.request
import urllib.error
import json

# Sigma connection type string → dialect key
_SIGMA_TYPE_MAP = {
    "bigquery":   "bigquery",
    "snowflake":  "snowflake",
    "databricks": "databricks",
    "redshift":   "redshift",
    "postgres":   "postgres",
    "postgresql": "postgres",
    "mysql":      "mysql",
    "athena":     "athena",
}


def detect_warehouse(sigma_base: str, token: str, connection_id: str) -> str:
    """
    Query the Sigma connection API to determine the warehouse dialect.
    Returns a dialect string or 'unknown' on any failure.
    """
    if not all([sigma_base, token, connection_id]):
        return "unknown"
    try:
        url = f"{sigma_base.rstrip('/')}/v2/connections/{connection_id}"
        req = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        })
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read())
        raw_type = str(data.get("type") or data.get("connectionType") or "").lower()
        return _SIGMA_TYPE_MAP.get(raw_type, "unknown")
    except Exception:
        return "unknown"


def apply_transforms(sql: str, warehouse: str) -> str:
    """
    Apply warehouse-specific SQL transforms to a SQL string.
    Currently handles: array aggregations → string aggregations.

    Sigma cannot render array/nested types in table cells. Each warehouse
    has its own string-aggregation idiom; this rewrites the common patterns.
    """
    if not sql or warehouse == "unknown":
        return sql

    if warehouse == "bigquery":
        # ARRAY_AGG(x [IGNORE NULLS]) → array_to_string(ARRAY_AGG(x [IGNORE NULLS]), ', ')
        # Guard against double-wrapping.
        def _bq_replace(m):
            full = m.group(0)
            if re.search(r'array_to_string', full, re.IGNORECASE):
                return full
            return f"array_to_string({full}, ', ')"
        sql = re.sub(
            r'\bARRAY_AGG\s*\([^)]+(?:\s+IGNORE\s+NULLS)?\)(?:\s+IGNORE\s+NULLS)?',
            _bq_replace, sql, flags=re.IGNORECASE,
        )

    elif warehouse == "snowflake":
        # ARRAY_AGG returns VARIANT in Snowflake — Sigma renders as "[object]".
        sql = re.sub(
            r'\bARRAY_AGG\s*\(([^)]+)\)',
            lambda m: f"LISTAGG({m.group(1)}, ', ')",
            sql, flags=re.IGNORECASE,
        )

    elif warehouse == "databricks":
        # collect_list → array_join
        sql = re.sub(
            r'\bcollect_list\s*\(([^)]+)\)',
            lambda m: f"array_join(collect_list({m.group(1)}), ', ')",
            sql, flags=re.IGNORECASE,
        )

    elif warehouse in ("redshift", "postgres"):
        sql = re.sub(
            r'\bARRAY_AGG\s*\(([^)]+)\)',
            lambda m: f"STRING_AGG(CAST({m.group(1)} AS VARCHAR), ', ')",
            sql, flags=re.IGNORECASE,
        )

    elif warehouse == "athena":
        sql = re.sub(
            r'\bARRAY_AGG\s*\(([^)]+)\)',
            lambda m: f"array_join(array_agg({m.group(1)}), ', ')",
            sql, flags=re.IGNORECASE,
        )

    return sql
