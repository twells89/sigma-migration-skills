#!/usr/bin/env python3
"""
Sisense estate assessment — read-only inventory + converter-coverage scoring.

Reuses the converter's discovery bundle (run ../sisense-to-sigma/scripts/
discover.py first) and scores every dashboard/widget against the SAME coverage
the sisense-to-sigma converter actually applies (WIDGET_MAP + jaql_expr), so the
readout reflects what the tool will really do.

Emits <out>/assessment.json + <out>/assessment.md:
  - model + dashboard counts, datasets/tables/relations per model
  - widget-type histogram
  - JAQL complexity buckets (simple agg / formula / flagged)
  - per-dashboard AUTO / HINT / MANUAL / UNHANDLED tally + a migration shortlist

Usage: python3 assess.py [--out ~/sisense-migration]
"""
import argparse, json, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "sisense-to-sigma", "scripts"))
import convert as C
import jaql_expr as J

def jaql_complexity(w):
    simple = formula = flagged = 0
    for p in w.get("metadata", {}).get("panels", []):
        for it in p.get("items", []):
            jq = it.get("jaql", {})
            if not jq:
                continue
            try:
                J.classify(jq)
                formula += 1 if "formula" in jq else 0
                simple += 0 if "formula" in jq else 1
            except J.Unsupported:
                flagged += 1
    return simple, formula, flagged

def tag_for(wt):
    _, tag = C.WIDGET_MAP.get(wt, (None, "UNHANDLED"))
    if C.SIGMA_KIND.get(wt) is None and tag != "UNHANDLED":
        tag = "MANUAL"
    return tag

def assess(out_dir):
    disc = os.path.join(out_dir, "discovery")
    cubes = json.load(open(os.path.join(disc, "elasticubes.json")))
    dashboards = json.load(open(os.path.join(disc, "dashboards.json")))

    models = []
    for c in cubes:
        safe = c["title"].replace("/", "_").replace(" ", "_")
        mp = os.path.join(disc, f"model_{safe}.json")
        if os.path.exists(mp):
            m = json.load(open(mp))
            tbls = [t for ds in m["datasets"] for t in ds["schema"]["tables"]]
            models.append({"title": c["title"], "datasets": len(m["datasets"]),
                           "tables": len(tbls), "relations": len(m.get("relations", [])),
                           "custom_sql_tables": sum(1 for t in tbls if t.get("expression"))})

    hist, dash_rows = {}, []
    for d in dashboards:
        tags = {"AUTO": 0, "HINT": 0, "MANUAL": 0, "UNHANDLED": 0}
        cx = {"simple": 0, "formula": 0, "flagged": 0}
        for w in d.get("widgets", []):
            wt = w.get("type")
            hist[wt] = hist.get(wt, 0) + 1
            tags[tag_for(wt)] = tags.get(tag_for(wt), 0) + 1
            s, f, fl = jaql_complexity(w)
            cx["simple"] += s; cx["formula"] += f; cx["flagged"] += fl
        n = max(1, len(d.get("widgets", [])))
        score = round(100 * (tags["AUTO"] + 0.6 * tags["HINT"]) / n - 5 * cx["flagged"], 1)
        dash_rows.append({"title": d.get("title"), "widgets": len(d.get("widgets", [])),
                          "tags": tags, "jaql": cx, "readiness": score})

    out = {"models": models, "widget_histogram": hist,
           "dashboards": sorted(dash_rows, key=lambda r: -r["readiness"])}
    json.dump(out, open(os.path.join(out_dir, "assessment.json"), "w"), indent=2)
    _write_md(out, os.path.join(out_dir, "assessment.md"))
    print(f"wrote assessment.json + assessment.md  ({len(models)} models, "
          f"{len(dash_rows)} dashboards, {sum(hist.values())} widgets)")

def _write_md(o, path):
    L = ["# Sisense → Sigma — Migration Assessment\n", "## Data models\n",
         "| Model | Datasets | Tables | Relations | Custom-SQL tables |", "|---|---|---|---|---|"]
    for m in o["models"]:
        L.append(f'| {m["title"]} | {m["datasets"]} | {m["tables"]} | {m["relations"]} | {m["custom_sql_tables"]} |')
    L += ["\n## Widget-type histogram\n", "| Sisense widget | Count | Converter coverage |", "|---|---|---|"]
    for wt, n in sorted(o["widget_histogram"].items(), key=lambda x: -x[1]):
        L.append(f"| `{wt}` | {n} | {tag_for(wt)} |")
    L += ["\n## Dashboards — migration shortlist (most ready first)\n",
          "| Dashboard | Widgets | AUTO | HINT | MANUAL | UNHANDLED | Flagged JAQL | Readiness |",
          "|---|---|---|---|---|---|---|---|"]
    for r in o["dashboards"]:
        t = r["tags"]
        L.append(f'| {r["title"]} | {r["widgets"]} | {t["AUTO"]} | {t["HINT"]} | '
                 f'{t["MANUAL"]} | {t["UNHANDLED"]} | {r["jaql"]["flagged"]} | {r["readiness"]} |')
    L += ["\n_AUTO = converts cleanly · HINT = converts, verify · MANUAL = needs a human "
          "decision (no native Sigma viz) · UNHANDLED = flagged, not converted. Read-only, all-free pre-scoping._\n"]
    open(path, "w").write("\n".join(L))

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.expanduser("~/sisense-migration"))
    assess(ap.parse_args().out)
