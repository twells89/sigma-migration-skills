#!/usr/bin/env python3
"""pbi-dm-signature.py — build a DM-reuse signature from a Power BI model.bim.

Feeds tableau-to-sigma/scripts/find-or-pick-dm.rb (Phase 1.5) so the converter
REUSES an existing Sigma data model that already covers the same warehouse
tables instead of creating a 4th near-identical one. Emits the signature shape
find-or-pick-dm expects:

  { "tableau_workbook": "<model name>",          # label only
    "warehouse_tables":   ["DB.SCHEMA.TABLE", ...],
    "referenced_columns": ["COL", ...],
    "measures":           [{"col": "COL", "derivation": "Sum|CountDistinct|..."}] }

Warehouse tables are parsed from each table partition's M `Snowflake.Databases`
navigation (Kind=Database/Schema/Table). Auto-date tables (Calendar(...)) and
calc tables are skipped. Pure (no network).

Usage: python3 pbi-dm-signature.py --bim /tmp/pbix/model.bim --out /tmp/x/sig.json
"""
import argparse, json, re, sys

AGG = {"SUM": "Sum", "AVERAGE": "Avg", "MIN": "Min", "MAX": "Max",
       "COUNT": "Count", "COUNTA": "Count", "DISTINCTCOUNT": "CountDistinct",
       "COUNTROWS": "Count"}

def _m_text(part):
    src = (part or {}).get("source", {})
    e = src.get("expression", "")
    return "\n".join(e) if isinstance(e, list) else str(e)

def _fqn(m_expr):
    """DB.SCHEMA.TABLE from Snowflake.Databases navigation, else None."""
    names = re.findall(r'\[Name\s*=\s*"([^"]+)"\s*,\s*Kind\s*=\s*"(Database|Schema|Table)"\]', m_expr)
    if len(names) >= 3:
        return ".".join(n for n, _ in names[:3])
    # SQL-source fallback: FROM DB.SCHEMA.TABLE
    sm = re.search(r'FROM\s+"?(\w+)"?\."?(\w+)"?\."?(\w+)"?', m_expr, re.I)
    return ".".join(sm.groups()) if sm else None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bim", required=True); ap.add_argument("--out", required=True)
    a = ap.parse_args()
    model = json.load(open(a.bim)); mdl = model.get("model", model)
    tables, cols, measures, promoted = [], [], [], []
    for t in mdl.get("tables", []):
        name = t.get("name", "")
        # skip auto date tables / calc tables (no warehouse source)
        if re.match(r'(LocalDateTable_|DateTableTemplate_)', name):
            continue
        m_expr = "".join(_m_text(p) for p in t.get("partitions", []))
        fqn = _fqn(m_expr)
        if fqn:
            tables.append(fqn.upper())
        # E-04: Table.PromoteHeaders in the M-query means the warehouse table was
        # loaded with AUTO-GENERATED column names (C1, C2, ...) and the semantic
        # names sit in row 0 — so TMSL sourceColumn names will NOT match the
        # warehouse columns and downstream refs/SQL break. Flag it.
        if re.search(r'Table\.PromoteHeaders', m_expr):
            promoted.append(name)
        for c in t.get("columns", []):
            sc = c.get("sourceColumn") or c.get("name")
            if sc:
                cols.append(str(sc).upper())
        for me in t.get("measures", []):
            expr = me.get("expression", "")
            expr = " ".join(expr) if isinstance(expr, list) else str(expr)
            mm = re.search(r'\b(' + "|".join(AGG) + r')\s*\(\s*\'?[^\'\[]*\'?\[([^\]]+)\]', expr, re.I)
            measures.append({"col": (mm.group(2).upper() if mm else me.get("name", "")),
                             "derivation": (AGG.get(mm.group(1).upper(), "Sum") if mm else None)})
    sig = {"tableau_workbook": mdl.get("name") or "Power BI model",
           "warehouse_tables": sorted(set(tables)),
           "referenced_columns": sorted(set(cols)),
           "measures": measures,
           "promoted_header_tables": sorted(set(promoted))}
    json.dump(sig, open(a.out, "w"), indent=2)
    print(f"[pbi-dm-signature] {len(sig['warehouse_tables'])} table(s), "
          f"{len(sig['referenced_columns'])} col(s), {len(measures)} measure(s) -> {a.out}", file=sys.stderr)
    if promoted:
        print(f"[pbi-dm-signature] WARNING: {len(promoted)} table(s) use Table.PromoteHeaders "
              f"({', '.join(promoted)}). Their warehouse columns are likely auto-named (C1, C2, ...) "
              f"with semantic names in row 0 — TMSL sourceColumn names will NOT match the warehouse. "
              f"Verify the landed table's real column names and use convert-model.rb --table-map "
              f"(or a column rename) before the workbook refs resolve. See SKILL.md PromoteHeaders.",
              file=sys.stderr)

if __name__ == "__main__":
    main()
