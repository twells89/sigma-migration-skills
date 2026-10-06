#!/usr/bin/env python3
"""Automated visual + structural compare: ThoughtSpot Liveboard viz vs the migrated
Sigma workbook elements. Exports each viz as a PNG from both tools, matches them by
name, and writes a self-contained HTML report (images side-by-side + a structural
diff: chart kind, and whether the element resolved). Dependency-free (base64 imgs).

  python3 compare.py --liveboard <TS_LB_ID> --workbook <SIGMA_WB_ID> [--out compare.html]

Env: TS_HOST, TS_TOKEN, SIGMA_BASE_URL plus a valid Sigma bearer,
browser-login keychain session, or client-credentials fallback.
"""
import argparse, base64, json, os, re, sys, time, urllib.request, html
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import yaml, ts_lib
import code_rep  # workbook code-rep document-wrapper adapter (nested GET shape)
import sigma_rest
yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", lambda l, n: l.construct_scalar(n))
_SSL = ts_lib.ssl_context()

# TS chart type -> the Sigma element kind the migration produces (for the structural check)
EXPECTED = {"KPI": "kpi-chart", "COLUMN": "bar-chart", "BAR": "bar-chart", "LINE": "line-chart",
            "PIE": "donut-chart", "DONUT": "donut-chart", "TABLE": "table", "ADVANCED_COLUMN": "table",
            "PIVOT_TABLE": "pivot-table", "STACKED_COLUMN": "bar-chart",
            "WATERFALL": "waterfall-chart", "WHISKER_SCATTER": "table"}

import time
def ts_png(lb_id, viz_guid):
    body = json.dumps({"metadata_identifier": lb_id, "file_format": "PNG",
                       "visualization_identifiers": [viz_guid]}).encode()
    for attempt in range(3):
        try:
            r = urllib.request.Request(f"{ts_lib.HOST}/api/rest/2.0/report/liveboard", data=body, method="POST",
                headers={"Authorization": f"Bearer {ts_lib.TOKEN}", "Content-Type": "application/json"})
            return urllib.request.urlopen(r, context=_SSL).read()
        except Exception as e:
            if attempt == 2:
                print(f"    (TS png failed: {type(e).__name__})"); return None
            time.sleep(2)

def sigma(method, path, body=None, raw=False):
    data = sigma_rest.request(
        method.lower(),
        path,
        body=json.dumps(body) if body else None,
        accept="application/json",
        binary=True,
    )
    return (data if raw else data.decode()), 200

def sigma_png(wb, el):
    txt, _ = sigma("POST", f"/v2/workbooks/{wb}/export", {"elementId": el, "format": {"type": "png", "pixelWidth": 900, "pixelHeight": 560}})
    qid = json.loads(txt).get("queryId")
    for _ in range(40):
        try:
            data, st = sigma("GET", f"/v2/query/{qid}/download", raw=True)
            if st == 200 and data[:4] == b"\x89PNG":
                return data
        except sigma_rest.SigmaError as exc:
            match = re.search(r" -> (\d+)", str(exc))
            status = int(match.group(1)) if match else None
            if status not in (202, 204, 404):
                raise
        time.sleep(2)
    return None

def img_tag(png):
    if not png: return "<span class=miss>(no image)</span>"
    return f'<img src="data:image/png;base64,{base64.b64encode(png).decode()}">'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--liveboard", required=True); ap.add_argument("--workbook", required=True)
    ap.add_argument("--out", default=os.path.expanduser("~/thoughtspot-migration/compare.html"))
    a = ap.parse_args()

    edoc, err = ts_lib.export_tml(a.liveboard, "LIVEBOARD")
    if err: sys.exit("liveboard export failed: " + err)
    ts_vizzes = []
    for v in yaml.safe_load(edoc)["liveboard"].get("visualizations", []):
        an = v.get("answer")
        if an: ts_vizzes.append({"name": an.get("name", v.get("id")), "guid": v.get("viz_guid") or v.get("id"),
                                 "type": (an.get("chart") or {}).get("type") or ("TABLE" if an.get("display_mode") == "TABLE_MODE" else "?")})
    raw_wbspec = yaml.safe_load(sigma("GET", f"/v2/workbooks/{a.workbook}/spec")[0])
    # Workbook code-rep GETs nest pages under a top-level `document` key (live
    # since 2026-08); a bare wbspec.get("pages", []) read here was always
    # empty, so every viz silently reported as "not resolved" in the report.
    sig_els = {}
    for el in code_rep.workbook_elements(raw_wbspec):
        if el.get("kind") != "table" or el.get("name") != "OFV":   # skip the master
            sig_els[el.get("name")] = el
    sig_els.pop("OFV", None)

    rows = []
    for v in ts_vizzes:
        el = sig_els.get(v["name"])
        exp = EXPECTED.get(v["type"], "?")
        got = el.get("kind") if el else None
        ok = "✓" if got == exp else ("≈" if got else "✗")
        tspng = ts_png(a.liveboard, v["guid"])
        try:
            sgpng = sigma_png(a.workbook, el["id"]) if el else None
        except Exception as e:
            print(f"    (Sigma png failed: {type(e).__name__})"); sgpng = None
        rows.append((v["name"], v["type"], exp, got or "(no match)", ok, tspng, sgpng))
        print(f"  {ok} {v['name'][:34]:34s} TS {v['type']:14s} → Sigma {got or '(none)'}")

    body = "".join(
        f"<tr><td>{html.escape(n)}</td><td><span class=k>{html.escape(t)}</span></td>"
        f"<td><span class=k>{html.escape(g)}</span> {ok}</td>"
        f"<td class=img><div class=lbl>ThoughtSpot</div>{img_tag(tp)}</td>"
        f"<td class=img><div class=lbl>Sigma</div>{img_tag(sp)}</td></tr>"
        for n, t, e, g, ok, tp, sp in rows)
    doc = f"""<!doctype html><meta charset=utf-8><title>Migration visual compare</title>
<style>body{{font:14px -apple-system,Segoe UI,sans-serif;background:#f7f8fa;padding:24px;color:#1a2030}}
h1{{font-size:20px}} table{{border-collapse:collapse;width:100%;background:#fff;border:1px solid #e4e7ee;border-radius:10px}}
td,th{{border-bottom:1px solid #eef0f4;padding:10px;vertical-align:top}} td.img{{width:36%}}
img{{max-width:100%;border:1px solid #eef0f4;border-radius:6px}} .lbl{{font-size:11px;color:#6b7488;margin-bottom:4px}}
.k{{font-family:monospace;font-size:12px;background:#eef1f7;padding:1px 6px;border-radius:4px}} .miss{{color:#b4690e}}</style>
<h1>ThoughtSpot → Sigma — visual &amp; structural compare</h1>
<p>Liveboard <code>{a.liveboard}</code> vs workbook <code>{a.workbook}</code>. ✓ = chart kind matches expected mapping.</p>
<table><tr><th>Visualization</th><th>TS type</th><th>Sigma kind</th><th>ThoughtSpot</th><th>Sigma</th></tr>{body}</table>"""
    open(a.out, "w").write(doc)
    print(f"\nReport → {a.out}")

if __name__ == "__main__":
    main()
