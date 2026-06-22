#!/usr/bin/env python3
"""
JAQL -> Sigma formula translation.

A JAQL panel item is `{ "jaql": {...}, "format": {...} }`. The jaql is one of:
  - dimension:        { "dim": "[Table.Column]", "level": "months"? , "sort"? , "filter"? }
  - aggregated meas.: { "dim": "[Table.Column]", "agg": "sum" }
  - formula measure:  { "formula": "SUM([r])/SUM([c])", "context": {"[r]":{dim..}, "[c]":{dim..}} }

translate_agg()   -> a Sigma aggregate formula string e.g. "Sum([Revenue])"
translate_dim()   -> a Sigma dimension column reference / date-trunc expression
classify()        -> ('measure'|'dimension', sigma_formula) for any jaql item

Unsupported constructs raise Unsupported so the converter FLAGS them instead of
emitting wrong logic. Column display names are taken verbatim from the JAQL dim
(the last [Table.Column] segment), which match the Sigma DM column names.
"""
import re

class Unsupported(Exception):
    pass

AGG = {
    "sum": "Sum", "count": "Count", "countdistinct": "CountDistinct",
    "avg": "Avg", "average": "Avg", "min": "Min", "max": "Max",
    "median": "Median", "stdev": "Stdev", "var": "Var",
}

# JAQL date level -> Sigma DateTrunc unit (None = no truncation)
LEVEL = {
    "years": "year", "quarters": "quarter", "months": "month", "weeks": "week",
    "days": "day", "minutes": "minute", "hours": "hour", "seconds": "second",
}

# JAQL formula functions that need special handling or flagging
SAFE_FUNC = {  # JAQL fn -> Sigma fn (same arg order)
    "SUM": "Sum", "COUNT": "Count", "AVG": "Avg", "MIN": "Min", "MAX": "Max",
    "COUNTDISTINCT": "CountDistinct", "ABS": "Abs", "ROUND": "Round",
    "RANK": "Rank",  # verify partition semantics downstream
}
FLAG_FUNC = {  # JAQL fns with no clean 1:1 Sigma equivalent -> flag for human
    "PREV", "PAST", "GROWTH", "GROWTHPAST", "RSUM", "DIFF", "DIFFPAST",
    "QUARTILE", "PERCENTILE", "CONTRIBUTION", "ALL", "LISTAGG",
}

def col_name(dim):
    """'[Commerce.Revenue]' -> 'Revenue' (the column display name in the DM)."""
    m = re.match(r"\[([^.\]]+)\.([^\]]+)\]", dim.strip())
    if not m:
        raise Unsupported(f"unparseable JAQL dim: {dim!r}")
    return m.group(2)

def table_of(dim):
    m = re.match(r"\[([^.\]]+)\.([^\]]+)\]", dim.strip())
    return m.group(1) if m else None

def translate_agg(jaql):
    agg = jaql["agg"].lower()
    if agg not in AGG:
        raise Unsupported(f"unsupported agg: {agg}")
    return f"{AGG[agg]}([{col_name(jaql['dim'])}])"

def translate_dim(jaql):
    name = col_name(jaql["dim"])
    lvl = jaql.get("level")
    if lvl:
        if lvl not in LEVEL:
            raise Unsupported(f"unsupported date level: {lvl}")
        return f'DateTrunc("{LEVEL[lvl]}", [{name}])'
    return f"[{name}]"

def translate_formula(jaql):
    """Resolve a JAQL formula's [tokens] from its context into a Sigma formula."""
    formula = jaql["formula"]
    ctx = jaql.get("context", {})
    # flag JAQL functions we won't fake
    for fn in re.findall(r"([A-Za-z_]+)\s*\(", formula):
        if fn.upper() in FLAG_FUNC:
            raise Unsupported(f"JAQL function {fn}() has no clean Sigma equivalent")
    out = formula
    for token, sub in ctx.items():
        # a context member carrying a filter (filtered/scoped measure) has no
        # clean 1:1 Sigma form — flag rather than silently drop the filter
        if isinstance(sub, dict) and sub.get("filter"):
            raise Unsupported("filtered/scoped JAQL measure — needs manual SumIf/CountIf")
        if "formula" in sub:
            rep = translate_formula(sub)
        elif "agg" in sub:
            rep = translate_agg(sub)
        elif "dim" in sub:
            rep = f"[{col_name(sub['dim'])}]"
        else:
            raise Unsupported(f"unresolvable JAQL context member: {sub!r}")
        out = out.replace(token, rep)
    # map JAQL scalar/agg function names to Sigma (case-insensitive)
    def _fn(m):
        fn = m.group(1)
        return SAFE_FUNC.get(fn.upper(), fn) + "("
    out = re.sub(r"([A-Za-z_]+)\s*\(", _fn, out)
    return out

def classify(jaql):
    """Return ('measure'|'dimension', sigma_formula). Raises Unsupported to flag."""
    if "formula" in jaql:
        return "measure", translate_formula(jaql)
    if jaql.get("agg"):
        return "measure", translate_agg(jaql)
    return "dimension", translate_dim(jaql)

def raw_dims(jaql):
    """Return a string containing every raw [Table.Column] token this JAQL item
    references — from its dim, or from each sub-item in a formula's context.
    Used to register the underlying columns into the workbook Master element."""
    toks = []
    if "dim" in jaql:
        toks.append(jaql["dim"])
    for sub in (jaql.get("context") or {}).values():
        if isinstance(sub, dict):
            toks.append(raw_dims(sub))
    return " ".join(toks)

def top_n(jaql):
    """Extract a top-N spec from a JAQL dim filter, or None."""
    f = jaql.get("filter") or {}
    top = f.get("top")
    if top:
        return {"count": top.get("count"), "by_col": col_name(top["by"]["dim"]),
                "by_agg": AGG.get(top["by"].get("agg", "sum").lower(), "Sum")}
    return None
