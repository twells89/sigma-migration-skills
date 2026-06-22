#!/usr/bin/env python3
"""Unit tests for jaql_expr — the JAQL→Sigma translation surface.
Run: python3 tests/test_jaql.py  (stdlib only, no pytest dependency)."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import jaql_expr as J

passed = failed = 0
def check(label, got, want):
    global passed, failed
    if got == want:
        passed += 1
    else:
        failed += 1
        print(f"  FAIL {label}\n       got:  {got!r}\n       want: {want!r}")

def check_flag(label, jaql):
    global passed, failed
    try:
        J.classify(jaql); failed += 1; print(f"  FAIL {label}: expected Unsupported, got a translation")
    except J.Unsupported:
        passed += 1

# --- aggregates ---
check("sum", J.classify({"dim": "[Commerce.Revenue]", "agg": "sum"}), ("measure", "Sum([Revenue])"))
check("countdistinct", J.classify({"dim": "[Brand.Brand]", "agg": "countDistinct".lower()}), ("measure", "CountDistinct([Brand])"))
check("avg", J.classify({"dim": "[Commerce.Cost]", "agg": "avg"}), ("measure", "Avg([Cost])"))
check("min", J.classify({"dim": "[Commerce.Cost]", "agg": "min"}), ("measure", "Min([Cost])"))
# --- dimensions ---
check("plain dim", J.classify({"dim": "[Category.Category]"}), ("dimension", "[Category]"))
check("date month", J.classify({"dim": "[Commerce.Date]", "level": "months"}), ("dimension", 'DateTrunc("month", [Date])'))
check("date year", J.classify({"dim": "[Commerce.Date]", "level": "years"}), ("dimension", 'DateTrunc("year", [Date])'))
# --- formula + context (ratio) ---
check("ratio formula",
      J.classify({"formula": "SUM([r])/SUM([q])",
                  "context": {"[r]": {"dim": "[Commerce.Revenue]"}, "[q]": {"dim": "[Commerce.Quantity]"}}}),
      ("measure", "Sum([Revenue])/Sum([Quantity])"))
# --- nested formula context ---
check("nested formula",
      J.classify({"formula": "[a]-[b]",
                  "context": {"[a]": {"formula": "SUM([x])", "context": {"[x]": {"dim": "[Commerce.Revenue]"}}},
                              "[b]": {"dim": "[Commerce.Cost]", "agg": "sum"}}}),
      ("measure", "Sum([Revenue])-Sum([Cost])"))
# --- top-N extraction ---
check("top-n", J.top_n({"dim": "[Country.Country]", "filter": {"top": {"count": 10, "by": {"dim": "[Commerce.Revenue]", "agg": "sum"}}}}),
      {"count": 10, "by_col": "Revenue", "by_agg": "Sum"})
check("no top-n", J.top_n({"dim": "[Country.Country]"}), None)
# --- raw_dims (Master registration) ---
check("raw_dims formula", J.raw_dims({"formula": "[r]/[q]", "context": {"[r]": {"dim": "[Commerce.Revenue]"}, "[q]": {"dim": "[Category.X]"}}}),
      "[Commerce.Revenue] [Category.X]")
# --- FLAG: functions with no clean Sigma equivalent ---
for fn in ["PREV", "PAST", "RSUM", "GROWTH", "CONTRIBUTION"]:
    check_flag(f"flag {fn}", {"formula": f"{fn}([m])", "context": {"[m]": {"dim": "[Commerce.Revenue]", "agg": "sum"}}})

# --- FLAG: filtered/scoped measures (no clean 1:1) ---
check_flag("flag filtered measure", {"formula": "[m]", "context": {"[m]": {"dim": "[Commerce.Revenue]", "agg": "sum", "filter": {"members": ["New"]}}}})
check_flag("flag unresolvable ctx", {"formula": "[m]", "context": {"[m]": {"foo": 1}}})

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
