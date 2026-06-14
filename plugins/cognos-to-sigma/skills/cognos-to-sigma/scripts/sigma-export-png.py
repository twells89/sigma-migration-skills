#!/usr/bin/env python3
"""sigma-export-png.py — render a Sigma workbook page or element to PNG via the
REST export API, for VISUAL QA of a migrated workbook (Phase 4: side-by-side
against the source Looker dashboard).

A PNG is more reliable than an MCP SQL query for catching LAYOUT/render problems —
hidden KPI titles, orphaned filters, overlapping tiles, wrong chart kinds — that a
numeric parity check can't see.

POST /v2/workbooks/{id}/export {pageId|elementId, format:{type:"png",pixelWidth,pixelHeight}}
  -> {queryId, jobComplete}; then GET /v2/query/{queryId}/download until the PNG is ready.

Env: SIGMA_BASE_URL + SIGMA_API_TOKEN (eval "$(scripts/get-token.sh)").
Usage:
  python3 sigma-export-png.py --workbook <id> --page <pageId> --out /tmp/x.png
  python3 sigma-export-png.py --workbook <id> --element <elId> --out /tmp/x.png [--w 1600 --h 900]
"""
import argparse, os, sys, time, requests

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workbook", required=True)
    ap.add_argument("--page"); ap.add_argument("--element")
    ap.add_argument("--out", required=True)
    ap.add_argument("--w", type=int, default=1600); ap.add_argument("--h", type=int, default=900)
    a = ap.parse_args()
    base = os.environ["SIGMA_BASE_URL"]; tok = os.environ["SIGMA_API_TOKEN"]
    h = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
    fmt = {"type": "png", "pixelWidth": a.w, "pixelHeight": a.h}
    body = {"format": fmt}
    if a.element: body["elementId"] = a.element
    elif a.page:  body["pageId"] = a.page
    else: sys.exit("need --page or --element")
    r = requests.post(f"{base}/v2/workbooks/{a.workbook}/export", headers=h, json=body)
    if r.status_code != 200: sys.exit(f"export POST {r.status_code}: {r.text[:300]}")
    qid = r.json()["queryId"]
    dl = f"{base}/v2/query/{qid}/download"
    for i in range(60):
        g = requests.get(dl, headers={"Authorization": f"Bearer {tok}"})
        ct = g.headers.get("Content-Type", "")
        if g.status_code == 200 and ("image" in ct or g.content[:8] == b"\x89PNG\r\n\x1a\n"):
            open(a.out, "wb").write(g.content)
            print(f"[png] {len(g.content)} bytes -> {a.out}"); return
        time.sleep(3)
    sys.exit("timed out waiting for PNG")

if __name__ == "__main__":
    main()
