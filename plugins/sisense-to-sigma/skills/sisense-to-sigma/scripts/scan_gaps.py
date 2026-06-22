#!/usr/bin/env python3
"""scan_gaps.py — gap-scout for Sisense→Sigma converter coverage.

Runs the converter's own classifier over every widget in a discovery bundle and
reports coverage by category — so coverage is *measured*, not assumed — and
appends every unmapped widget / flagged JAQL to a learned-rules file for
follow-up. This is the "flag, never fake" gate: a migration is not done until
the scout has run and any UNHANDLED/MANUAL gap is either ported or knowingly
accepted. Run each time; shared with the sisense-assessment skill.

Categories (from convert.WIDGET_MAP + jaql_expr):
  AUTO      widget type + all its JAQL map cleanly to a Sigma element
  HINT      maps to a near-equivalent (e.g. polar→bar, map→geo) — review
  MANUAL    no native Sigma element (treemap/sunburst) — rebuild by hand
  UNHANDLED unknown widget type — not converted
  plus per-widget FIELD FLAGS: JAQL the translator refused (custom funcs,
  filtered/scoped measures, unresolvable context) — never faked.

Usage:
  python3 scan_gaps.py <dashboards.json> [--rules learned-rules.json] [--strict]
    --strict : exit non-zero if any MANUAL/UNHANDLED/flagged gap remains
               (use in the done-gate; default exit 0 just reports + records).
"""
import argparse, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import convert as C

CATEGORY_NOTE = {
    "AUTO":      "widget + JAQL map cleanly to a Sigma element",
    "HINT":      "near-equivalent Sigma element — review the substitution",
    "MANUAL":    "no native Sigma element — rebuild by hand",
    "UNHANDLED": "unknown widget type — not converted",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dashboards")
    ap.add_argument("--rules", default="learned-rules.json")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 if any MANUAL/UNHANDLED/flagged gap remains (done-gate)")
    a = ap.parse_args()

    dashboards = json.load(open(a.dashboards))
    dashboards = dashboards if isinstance(dashboards, list) else [dashboards]
    rows = C.classify_dashboard(dashboards)

    by_cat, gaps = {}, []
    for r in rows:
        by_cat.setdefault(r["tag"], []).append(r)
        if r["tag"] in ("MANUAL", "UNHANDLED"):
            gaps.append({"widget": r["title"], "sisense_type": r["sisense_type"],
                         "category": r["tag"], "reason": CATEGORY_NOTE[r["tag"]]})
        for fl in r.get("field_flags", []):           # JAQL the translator refused
            gaps.append({"widget": r["title"], "sisense_type": r["sisense_type"],
                         "category": "JAQL", "reason": fl})

    total = len(rows) or 1
    auto = len(by_cat.get("AUTO", []))
    print(f"=== Sisense->Sigma coverage: {len(rows)} widgets ===")
    for cat in ("AUTO", "HINT", "MANUAL", "UNHANDLED"):
        grp = by_cat.get(cat, [])
        if grp:
            print(f"  {cat:10} {len(grp):3}  ({CATEGORY_NOTE[cat]})")
            for r in grp:
                fl = f"  FLAGS={r['field_flags']}" if r.get("field_flags") else ""
                print(f"       - {r['title']:34} {r['sisense_type']:14} -> {r['sigma_element']}{fl}")
    flagged = sum(1 for g in gaps if g["category"] == "JAQL")
    print(f"  ---\n  AUTO: {auto}/{len(rows)} ({100*auto//total}%); "
          f"hint: {len(by_cat.get('HINT', []))}; "
          f"manual/unhandled: {len(by_cat.get('MANUAL', []))+len(by_cat.get('UNHANDLED', []))}; "
          f"flagged JAQL: {flagged}")

    if gaps:
        prev = json.load(open(a.rules)) if os.path.exists(a.rules) else []
        seen = {(g["widget"], g["reason"]) for g in prev}
        fresh = [g for g in gaps if (g["widget"], g["reason"]) not in seen]
        if fresh:
            json.dump(prev + fresh, open(a.rules, "w"), indent=2)
            print(f"  appended {len(fresh)} new gap(s) -> {a.rules}")
        print("  -> flag, never fake: port each gap, accept it knowingly, or "
              "escalate-gap.py to file a tracking issue (opt-in).")

    if a.strict and gaps:
        sys.exit(f"\nRED: {len(gaps)} unresolved gap(s) — not done until ported or accepted.")
    print("\nGREEN" if not gaps else "\n(reported — re-run with the gaps resolved for a clean scan)")


if __name__ == "__main__":
    main()
