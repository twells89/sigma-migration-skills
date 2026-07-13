#!/usr/bin/env python3
"""gen-coverage-matrix.py — generate refs/<skill>-coverage.md FROM the JSON
catalogs (refs/catalogs/*.json), so the human-readable coverage matrix can never
drift from the machine-loaded single source of truth (beads-sigma-kvza).

  python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs --skill looker \
      --out refs/looker-coverage.md
  python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs --skill looker \
      --out refs/looker-coverage.md --check     # exit 1 if the file is stale

One table per dimension, five columns (the handoff's shape):
  | construct | doc ref | Sigma target | sigma_verified (y/n·date) | on-unmapped |

Stdlib only; Windows-safe.
"""
import argparse
import json
import os
import sys

DIM_ORDER = ["viz-kind", "number-format", "aggregation", "control"]
DIM_TITLE = {
    "viz-kind": "Visualization / chart kind",
    "number-format": "Number format",
    "aggregation": "Aggregation",
    "control": "Control / filter",
}


def _md_escape(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def _verified_cell(r):
    sv = r.get("sigma_verified") or {}
    status = sv.get("status", "n")
    if status == "y":
        return "✅ y · %s" % sv.get("date", "?")
    return "🟡 n"


def _target_cell(r):
    sig = r.get("sigma")
    if sig is None and r.get("sigma_if") is None:
        return "— (no Sigma equivalent)"
    parts = []
    if sig is not None:
        parts.append("`%s`" % _md_escape(sig))
    if r.get("sigma_if"):
        parts.append("if→`%s`" % _md_escape(r["sigma_if"]))
    return " ".join(parts) if parts else "—"


def _doc_cell(r):
    ref = r.get("doc_ref", "")
    return "[doc](%s)" % ref if ref.startswith("http") else _md_escape(ref or "—")


def render(catalogs, skill):
    cats = {}
    for fn in sorted(os.listdir(catalogs)):
        if fn.endswith(".json"):
            cats[fn[:-5]] = json.load(open(os.path.join(catalogs, fn)))
    order = [d for d in DIM_ORDER if d in cats] + [d for d in sorted(cats) if d not in DIM_ORDER]

    out = []
    out.append("# %s → Sigma — dashboard classifier coverage matrix" % skill.capitalize())
    out.append("")
    out.append("> **GENERATED — do not edit by hand.** Regenerate with "
               "`python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs "
               "--skill %s --out refs/%s-coverage.md`. The JSON catalogs in "
               "`refs/catalogs/` are the single source of truth; the classifier "
               "(`scripts/build_workbook.py` / `build-sigma-workbook.py`) LOADS them "
               "via `shared/lib/coverage_catalog.py`. A no-drift test asserts this "
               "file matches the catalogs." % (skill, skill))
    out.append("")
    out.append("Every documented source construct maps to a real, current Sigma target "
               "or a loud fallback — no silent wrong-defaults, no name-substring "
               "guessing (beads-sigma-kvza).")
    out.append("")
    out.append("**`sigma_verified` legend:** ✅ y = the mapped Sigma target resolved at "
               "**query time** in a live migration (no `type=error` column) on the date "
               "shown; 🟡 n = target is documented but not yet query-verified.")
    out.append("")
    total = sum(len(c.get("rows", [])) for c in cats.values())
    ver = sum(1 for c in cats.values() for r in c.get("rows", [])
              if (r.get("sigma_verified") or {}).get("status") == "y")
    out.append("**Coverage:** %d documented constructs across %d dimensions; "
               "%d live-verified." % (total, len(cats), ver))
    out.append("")

    for dim in order:
        c = cats[dim]
        out.append("## %s" % DIM_TITLE.get(dim, dim))
        out.append("")
        if c.get("description"):
            out.append("_%s_" % c["description"])
            out.append("")
        if c.get("authoritative_doc"):
            out.append("Authoritative source: <%s>" % c["authoritative_doc"])
            out.append("")
        out.append("| construct | doc ref | Sigma target | sigma_verified | on-unmapped |")
        out.append("|---|---|---|---|---|")
        for r in c.get("rows", []):
            notes = r.get("notes")
            src = "`%s`" % _md_escape(r["source"])
            onun = _md_escape(r.get("on_unmapped", c.get("on_unmapped_default", "")))
            row = "| %s | %s | %s | %s | %s |" % (
                src, _doc_cell(r), _target_cell(r), _verified_cell(r), onun)
            out.append(row)
            if notes:
                out.append("| | | | | _%s_ |" % _md_escape(notes))
        out.append("")

    out.append("---")
    out.append("_Compositional constructs that do not serialize to a flat table "
               "(Set Analysis, filtered `*If`, ratio measures, TO_CHAR/Excel mask "
               "parsers, count-on-joined-view) stay as cited predicates in the "
               "classifier; this matrix covers the enumerable maps._")
    out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalogs", required=True)
    ap.add_argument("--skill", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if --out is stale vs the catalogs (no write)")
    a = ap.parse_args()
    text = render(a.catalogs, a.skill)
    if a.check:
        cur = open(a.out).read() if os.path.exists(a.out) else ""
        if cur != text:
            sys.stderr.write("STALE: %s does not match refs/catalogs — regenerate.\n" % a.out)
            sys.exit(1)
        print("OK: %s matches the catalogs." % a.out)
        return
    open(a.out, "w").write(text)
    print("wrote %s (%d bytes)" % (a.out, len(text)))


if __name__ == "__main__":
    main()
