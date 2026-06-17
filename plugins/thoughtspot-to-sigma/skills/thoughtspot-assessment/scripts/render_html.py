#!/usr/bin/env python3
"""Render a share-friendly HTML readout from assessment.json (written by scan.py).

Usage: python3 render_html.py [assessment.json] [out.html]
Defaults: ~/thoughtspot-migration/assessment.json -> ~/thoughtspot-migration/assessment.html
"""
import json, os, sys, html, datetime

SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/thoughtspot-migration/assessment.json")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/thoughtspot-migration/assessment.html")
UNSUP = {"LINE_STACKED_COLUMN", "PIVOT_TABLE", "SCATTER", "BUBBLE", "TREEMAP",
         "WATERFALL", "GEO_AREA", "FUNNEL"}
d = json.load(open(SRC))
profs = [p for p in d["profiles"] if p.get("exportable")]
fixtures = [p for p in profs if p["name"].endswith("(TS)") or "TS Fixture" in p["name"]]
samples = [p for p in profs if p not in fixtures]
total_viz = sum(d["chart_types"].values())
sup_viz = sum(v for k, v in d["chart_types"].items() if k not in UNSUP)
n_models = len({m for p in profs for m in p.get("models", [])})

def esc(s): return html.escape(str(s))
def tier(p): return "EASY" if not p["unsupported"] and p["complexity"] < 20 else "REVIEW"

# Duplicate / consolidation candidates — render from the stored result (scan.py),
# falling back to computing it here so older assessment.json files still get it.
import importlib.util as _ilu
_dd_spec = _ilu.spec_from_file_location(
    "dup_dashboards", os.path.join(os.path.dirname(os.path.abspath(__file__)), "dup-dashboards.py"))
_dd = _ilu.module_from_spec(_dd_spec); _dd_spec.loader.exec_module(_dd)
_dups = d.get("duplicate_dashboards") or _dd.detect([
    {"id": p.get("id"), "name": p.get("name"), "sources": p.get("models") or [],
     "viz": list((p.get("chart_types") or {}).keys()),
     "fields": (p.get("models") or []) + list((p.get("chart_types") or {}).keys()),
     "usage": p.get("views")} for p in d["profiles"]])
dup_html = _dd.render_html(_dups)

def rows(group, collapse_sw=False):
    out, seen = [], False
    for p in sorted(group, key=lambda p: p["complexity"]):
        nm = p["name"]
        if collapse_sw and nm.startswith("Software & Technology"):
            if seen: continue
            seen = True; nm = "Software & Technology-Dashboard (×9 identical)"
        types = ", ".join(f"{k}×{v}" for k, v in sorted(p["chart_types"].items(), key=lambda x: -x[1]))
        u = ", ".join(p["unsupported"]) or "—"
        t = tier(p)
        badge = f'<span class="tier {t.lower()}">{t}</span>'
        out.append(f"<tr><td>{esc(nm)}</td><td class=n>{p['viz']}</td><td class=n>{p.get('views',0)}</td>"
                   f"<td class=n>{p.get('users',0)}</td><td class=n>{p['complexity']}</td><td>{badge}</td>"
                   f"<td class=types>{esc(types)}</td><td class=flag>{esc(u)}</td></tr>")
    return "\n".join(out)

TH = ("<tr><th>Liveboard</th><th>Viz</th><th>Views</th><th>Users</th><th>Cx</th>"
      "<th>Tier</th><th>Chart types</th><th>Needs review</th></tr>")
usage_banner = ("" if d.get("total_views") else
  '<div class=usagebanner>⚠ <b>Usage:</b> ThoughtSpot exposes per-object views &amp; users via the '
  '<code>TS: BI Server</code> system worksheet (ThoughtSpot&#39;s built-in usage log) — a value signal '
  'for the migration shortlist. This trial has <b>0 recorded interactive views</b> (content was created '
  'via API and never opened in the UI), so Views/Users below read 0; they populate on a live instance.</div>')

bars = ""
for k, v in sorted(d["chart_types"].items(), key=lambda x: -x[1]):
    pct = 100 * v / total_viz
    cls = "warn" if k in UNSUP else "ok"
    bars += (f'<div class=barrow><span class=blabel>{esc(k)}</span>'
             f'<span class=bar><span class="fill {cls}" style="width:{max(pct,2):.1f}%"></span></span>'
             f'<span class=bnum>{v}</span></div>')

date = datetime.date.today().strftime("%B %d, %Y")
doc = f"""<!doctype html><html><head><meta charset=utf-8>
<title>ThoughtSpot → Sigma Migration Assessment</title>
<style>
body{{font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;color:#1a2030;max-width:1000px;margin:0 auto;padding:32px;background:#f7f8fa}}
h1{{font-size:26px;margin:0 0 4px}} h2{{font-size:18px;margin:32px 0 10px;color:#2b3550}}
.sub{{color:#6b7488;margin-bottom:24px}}
.cards{{display:flex;gap:14px;flex-wrap:wrap;margin:18px 0}}
.card{{background:#fff;border:1px solid #e4e7ee;border-radius:10px;padding:16px 20px;flex:1;min-width:140px}}
.card .v{{font-size:28px;font-weight:700;color:#3b5bdb}} .card .l{{color:#6b7488;font-size:13px}}
table{{border-collapse:collapse;width:100%;background:#fff;border:1px solid #e4e7ee;border-radius:10px;overflow:hidden}}
th,td{{padding:9px 12px;text-align:left;border-bottom:1px solid #eef0f4;font-size:14px}}
th{{background:#eef1f7;font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:#54607a}}
td.n{{text-align:right;font-variant-numeric:tabular-nums}} td.types{{color:#6b7488;font-size:12px}}
td.flag{{color:#b4690e;font-size:12px}}
.tier{{font-size:11px;font-weight:700;padding:2px 8px;border-radius:20px}}
.tier.easy{{background:#e6f4ea;color:#1e7d36}} .tier.review{{background:#fdf0e3;color:#b4690e}}
.barrow{{display:flex;align-items:center;gap:10px;margin:3px 0}}
.blabel{{width:180px;font-size:13px}}
.bar{{flex:1;background:#eef0f4;border-radius:4px;height:14px;overflow:hidden}}
.fill{{display:block;height:100%}} .fill.ok{{background:#3b5bdb}} .fill.warn{{background:#e8a13a}}
.bnum{{width:34px;text-align:right;font-size:12px;color:#6b7488}}
.note{{color:#8a92a6;font-size:12px;margin-top:10px}}
.legend{{font-size:12px;color:#6b7488;margin:6px 0 0}}
.usagebanner{{background:#fdf0e3;border:1px solid #f0d9bb;border-radius:8px;padding:12px 16px;font-size:13px;color:#7a5418;margin:8px 0}}
code{{background:#eef0f4;padding:1px 5px;border-radius:4px;font-size:12px}}
</style></head><body>
<h1>ThoughtSpot → Sigma — Migration Assessment</h1>
<div class=sub>team2.thoughtspot.cloud · generated {date}</div>
<div class=cards>
  <div class=card><div class=v>{len(profs)}</div><div class=l>Liveboards (readable)</div></div>
  <div class=card><div class=v>{n_models}</div><div class=l>models referenced</div></div>
  <div class=card><div class=v>{total_viz}</div><div class=l>visualizations</div></div>
  <div class=card><div class=v>{d['coverage']:.1f}%</div><div class=l>chart-type coverage</div></div>
</div>
{usage_banner}

<h2>Migration shortlist — fixtures (built &amp; migrated, parity-exact)</h2>
<table>{TH}
{rows(fixtures)}</table>

<h2>Pre-existing / sample Liveboards</h2>
<table>{TH}
{rows(samples, collapse_sw=True)}</table>
<div class=legend>Cx = complexity heuristic (viz count + 2×chart kinds + 3×models). EASY = all chart types supported &amp; Cx &lt; 20.</div>

<h2>Chart-type coverage — {sup_viz}/{total_viz} viz supported ({d['coverage']:.1f}%)</h2>
{bars}
<div class=note>⬛ supported by the thoughtspot-to-sigma pipeline today · 🟧 needs an element-builder or redesign (PIVOT_TABLE, WATERFALL, FUNNEL, SCATTER, TREEMAP, GEO_AREA, BUBBLE, LINE_STACKED_COLUMN). Sigma supports most of these natively — they just need mapping work.</div>

{dup_html}

<div class=note>Methodology: inventory via ThoughtSpot REST v2 metadata/search; per-Liveboard profile from exported TML. Complexity is a relative effort proxy, not a time estimate. This is a trial instance — most Liveboards are ThoughtSpot demo/sample content.</div>
</body></html>"""
open(OUT, "w").write(doc)
print("wrote", OUT)
