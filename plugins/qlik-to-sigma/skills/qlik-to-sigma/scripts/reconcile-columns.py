#!/usr/bin/env python3
"""reconcile-columns — auto-derive the Qlik-field → warehouse-column map from the load script.

    python3 reconcile-columns.py --script discovery/script.qvs [--out reconcile.json]

Phase 3 of qlik-to-sigma. The Qlik LOAD script renames warehouse columns
(`ORDER_STORE_KEY AS STORE_KEY`, `REGION AS CUSTOMER_REGION`) — so when you build the
Sigma data model against the real warehouse, you must point columns at the REAL column
while keeping the Qlik field name. This parses the load script's `AS` clauses + the
source table per `LOAD` block and emits that mapping, so the DM build (or the denormalized
SQL element) can use `<real col> AS <qlik name>` faithfully.

Output per Qlik table:
  { qlikTable, sourceTable, fields:[{ qlikField, realColumn, renamed }] }

Handles: `SQL SELECT ... FROM db.schema.TABLE;` (real migration) and
`FROM [lib://Conn/FILE.csv]` (CSV fixture). RESIDENT/INLINE are flagged, not resolved.
"""
import re, json, argparse, sys

BLOCK = re.compile(
    r'(\w+)\s*:\s*\n\s*LOAD\b(.*?;)\s*((?:SQL\s+)?SELECT\b.*?;)?\s*(?:\n|$)',
    re.IGNORECASE | re.DOTALL)
SOURCE = re.compile(
    r'\b(?:SQL\s+)?SELECT\b.*?\bFROM\s+([A-Za-z0-9_."]+(?:\.[A-Za-z0-9_."]+)*)'  # [SQL] SELECT ... FROM db.schema.table
    r'|\bFROM\s+\[lib://[^/]+/([^\]]+)\]'                                    # lib CSV
    r'|\bRESIDENT\s+(\w+)|\b(INLINE|AUTOGENERATE)\b',
    re.IGNORECASE | re.DOTALL)

def split_fields(s):
    """Split a LOAD field list on top-level commas only (paren-depth aware), so
    function-built fields like `Dual(MONTH_NAME, MONTH_NUMBER) AS MONTH` stay
    one token instead of shedding a bogus duplicate column."""
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth = max(0, depth - 1)
        if ch == "," and depth == 0:
            parts.append("".join(cur)); cur = []
        else:
            cur.append(ch)
    if cur:
        parts.append("".join(cur))
    return parts

def parse(qvs):
    out = []
    for m in BLOCK.finditer(qvs):
        name, body, trailing = m.group(1), m.group(2), (m.group(3) or "")
        # split source clause off the field list (the SELECT may trail the LOAD as
        # a separate preceding-load statement, with or without the SQL keyword)
        full = body + ("\n" + trailing if trailing else "")
        src_m = SOURCE.search(full)
        field_part = body[:src_m.start()] if src_m and src_m.start() < len(body) else body
        sql_from, lib_file, resident, special = (src_m.groups() if src_m else (None, None, None, None))
        # A file load (QlikView QVD / CSV fixture) names the source by FILE — the
        # warehouse table is the file stem, so drop the path + data-file extension
        # (else the DM element resolves to a table literally named ".qvd").
        lib_table = ""
        if lib_file:
            lib_table = re.sub(r"\.(qvd|qvx|csv|txt|xlsx?)$", "", lib_file.strip().split("/")[-1], flags=re.I)
        source = (sql_from or "").strip('"') or lib_table or (f"RESIDENT {resident}" if resident else "") or (special or "?")
        fields = []
        for tok in split_fields(field_part):
            tok = tok.strip().strip(";").strip()
            if not tok or tok.upper() == "LOAD": continue
            tok = re.sub(r'^LOAD\b', '', tok, flags=re.IGNORECASE).strip()
            am = re.search(r'^(.*?)\s+AS\s+"?([A-Za-z0-9_]+)"?$', tok, re.IGNORECASE)
            if am:
                real = am.group(1).strip().strip('"'); qlik = am.group(2)
                # real may be an expression; flag if not a plain column
                dual = re.match(r'^Dual\s*\(\s*"?([A-Za-z0-9_]+)"?\s*,\s*"?([A-Za-z0-9_]+)"?\s*\)$', real, re.IGNORECASE)
                if dual:  # Dual(text, num): the dual's IDENTITY is the numeric arg
                    # (Qlik collapses buckets by number; text is display-only and
                    # may be dirty, e.g. mixed Apr/April) -> map to the numeric column
                    real = dual.group(2)
                renamed = real.upper() != qlik.upper()
                fields.append({"qlikField": qlik, "realColumn": real, "renamed": renamed,
                               "isExpression": not re.match(r'^[A-Za-z0-9_]+$', real)})
            else:
                col = tok.strip('"')
                if re.match(r'^[A-Za-z0-9_*]+$', col):
                    fields.append({"qlikField": col, "realColumn": col, "renamed": False, "isExpression": False})
        if fields:
            out.append({"qlikTable": name, "sourceTable": source, "fields": fields})
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", required=True)
    ap.add_argument("--out", default="reconcile.json")
    a = ap.parse_args()
    tables = parse(open(a.script).read())
    json.dump(tables, open(a.out, "w"), indent=2)
    print(f"tables={len(tables)} -> {a.out}")
    for t in tables:
        ren = [f for f in t["fields"] if f["renamed"]]
        print(f"  {t['qlikTable']:14} src={t['sourceTable']:30} fields={len(t['fields']):2}  renamed={len(ren)}")
        for f in ren:
            tag = " (EXPR)" if f.get("isExpression") else ""
            print(f"      {f['qlikField']}  <-  {f['realColumn']}{tag}")

if __name__ == "__main__":
    main()
