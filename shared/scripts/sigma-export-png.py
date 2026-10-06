#!/usr/bin/env python3
# NOTE: authentication is resolved by the shared browser-first Sigma provider.
"""sigma-export-png.py — render a Sigma workbook page or element to PNG via the
REST export API, for VISUAL QA of a migrated workbook (Phase 4: side-by-side
against the source Looker dashboard).

A PNG is more reliable than an MCP SQL query for catching LAYOUT/render problems —
hidden KPI titles, orphaned filters, overlapping tiles, wrong chart kinds — that a
numeric parity check can't see.

POST /v2/workbooks/{id}/export {pageId|elementId, format:{type:"png",pixelWidth,pixelHeight}}
  -> {queryId, jobComplete}; then GET /v2/query/{queryId}/download until the PNG is ready.

Env: SIGMA_BASE_URL plus browser-keychain state or client-credential fallback.
Usage:
  python3 sigma-export-png.py --workbook <id> --page <pageId> --out /tmp/x.png
  python3 sigma-export-png.py --workbook <id> --element <elId> --out /tmp/x.png [--w 1600 --h 900]
  python3 sigma-export-png.py --workbook <id> --page <pageId> --param <controlId>=<value> --out /tmp/x.png

--param (repeatable) sets a control value for the render via the export body's
"parameters" map — the ONLY programmatic way to render a non-default control
state (same channel probe-controls.rb proved for CSV exports on 2026-06-12).
Used by verify-interaction.rb for the flipped-state render EVIDENCE; callers
must treat a failure here as advisory (PNG+parameters is unproven — the
interaction verdict never depends on it).
"""
import argparse, os, sys, time, requests

_HERE = os.path.dirname(os.path.abspath(__file__))
for _lib in (os.path.join(_HERE, "lib"), os.path.join(_HERE, "..", "lib")):
    if os.path.isdir(_lib):
        sys.path.insert(0, _lib)
import sigma_rest


def current_token():
    """Reuse a valid caller token; refresh only when missing or known-stale."""
    try:
        return sigma_rest.auth_token()
    except (sigma_rest.SigmaError, SystemExit) as exc:
        raise SystemExit(
            "Sigma token unavailable: authenticate with the browser provider or "
            "provide SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET/SIGMA_BASE_URL"
        ) from exc


def refreshed_token():
    """Force the dual provider after a rejected bearer."""
    try:
        return sigma_rest.refresh_token()
    except (sigma_rest.SigmaError, SystemExit) as exc:
        raise SystemExit(
            "Sigma token unavailable: authenticate with the browser provider or "
            "provide SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET/SIGMA_BASE_URL"
        ) from exc


def credentials():
    try:
        base = sigma_rest.base_url()
    except sigma_rest.SigmaError as exc:
        raise SystemExit(
            "Sigma token unavailable: authenticate with the browser provider or "
            "provide SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET/SIGMA_BASE_URL"
        ) from exc
    return base.rstrip("/"), current_token()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workbook", required=True)
    ap.add_argument("--page"); ap.add_argument("--element")
    ap.add_argument("--out", required=True)
    ap.add_argument("--w", type=int, default=1600); ap.add_argument("--h", type=int, default=900)
    ap.add_argument("--param", action="append", default=[],
                    metavar="CID=VALUE", help="control value for the render (repeatable)")
    a = ap.parse_args()
    base, tok = credentials()
    h = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
    fmt = {"type": "png", "pixelWidth": a.w, "pixelHeight": a.h}
    body = {"format": fmt}
    if a.element: body["elementId"] = a.element
    elif a.page:  body["pageId"] = a.page
    else: sys.exit("need --page or --element")
    if a.param:
        params = {}
        for spec in a.param:
            cid, sep, val = spec.partition("=")
            if not sep or not cid: sys.exit(f"bad --param {spec!r} (want <controlId>=<value>)")
            params[cid] = val
        body["parameters"] = params
    # Explicit network timeouts (field-caught: a stuck render job left the
    # bare POST/GET hanging INDEFINITELY — the caller saw a frozen script, not
    # a diagnosable failure). Repeated 500s on the poll are surfaced loudly:
    # that pattern is usually the workbook's own content — run the bisect
    # playbook (refs/layout-visual-qa.md) before blaming the service.
    export_url = f"{base}/v2/workbooks/{a.workbook}/export"
    r = requests.post(export_url, headers=h, json=body, timeout=60)
    if r.status_code == 401:
        tok = refreshed_token()
        h["Authorization"] = f"Bearer {tok}"
        r = requests.post(export_url, headers=h, json=body, timeout=60)
    if r.status_code != 200: sys.exit(f"export POST {r.status_code}: {r.text[:300]}")
    qid = r.json()["queryId"]
    dl = f"{base}/v2/query/{qid}/download"
    n500 = 0
    poll_auth_retried = False
    for i in range(60):
        try:
            g = requests.get(dl, headers={"Authorization": f"Bearer {tok}"}, timeout=60)
        except requests.exceptions.Timeout:
            time.sleep(3); continue
        if g.status_code == 401 and not poll_auth_retried:
            tok = refreshed_token()
            poll_auth_retried = True
            try:
                g = requests.get(dl, headers={"Authorization": f"Bearer {tok}"}, timeout=60)
            except requests.exceptions.Timeout:
                time.sleep(3); continue
        ct = g.headers.get("Content-Type", "")
        if g.status_code == 200 and ("image" in ct or g.content[:8] == b"\x89PNG\r\n\x1a\n"):
            open(a.out, "wb").write(g.content)
            print(f"[png] {len(g.content)} bytes -> {a.out}"); return
        if g.status_code == 500:
            n500 += 1
            if n500 >= 5:
                sys.exit("render job failed: HTTP 500 x5 on download — this is usually the "
                         "WORKBOOK'S OWN content (e.g. an unbounded pivot dimension), not a "
                         "service outage. Run the bisect playbook in refs/layout-visual-qa.md "
                         "('Render 500 / export-timeout bisect') before waiving any gate.")
        time.sleep(3)
    sys.exit("timed out waiting for PNG (job never materialized) — run the bisect playbook in "
             "refs/layout-visual-qa.md before treating this as a service outage.")

if __name__ == "__main__":
    main()
