#!/usr/bin/env python3
"""
Sisense discovery — pull the source content a migration needs, over REST.

Validated live against signense trial (signup-jnzavd0c.sisense.com) 2026-06-17.

Outputs a normalized discovery bundle to <out>/discovery/:
  - elasticubes.json        list of data models (oid, title, datasets count)
  - model_<title>.json      full datamodel schema export per cube
  - dashboards.json         list of dashboards (with widgets inlined)

Endpoints used (see refs/sisense-rest-api.md for the full map):
  GET  /api/v1/elasticubes/getElasticubes
  GET  /api/v2/datamodels/schema?title=<title>     <- full datasets/relations/transforms
  GET  /api/v1/dashboards
  GET  /api/v1/dashboards/{oid}/widgets

Auth: reads SISENSE_BASE_URL + SISENSE_API_TOKEN from the env
      (eval "$(scripts/sisense-auth.sh)" first).

Usage:
  python3 discover.py [--out DIR] [--cube TITLE ...]
"""
import argparse
import json
import os
import ssl
import sys
import urllib.parse
import urllib.request

BASE = os.environ.get("SISENSE_BASE_URL", "").rstrip("/")
TOKEN = os.environ.get("SISENSE_API_TOKEN", "")

# Some Sisense instances (notably trial/self-signed) present a cert chain that
# Python's verifier rejects even though curl/browsers accept it. Try verified
# first; on a cert-verification error, fall back to an unverified context (the
# target is the customer's own instance, reached over their own creds) and warn.
_UNVERIFIED = ssl._create_unverified_context()
_warned_ssl = False


def _get(path):
    global _warned_ssl
    url = f"{BASE}{path}"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {TOKEN}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read().decode("utf-8")
    except urllib.error.URLError as e:
        if not isinstance(getattr(e, "reason", None), ssl.SSLCertVerificationError):
            raise
        if not _warned_ssl:
            print("  ! TLS cert not verifiable — falling back to unverified "
                  "context (trial/self-signed cert)", file=sys.stderr)
            _warned_ssl = True
        with urllib.request.urlopen(req, context=_UNVERIFIED) as r:
            body = r.read().decode("utf-8")
    return json.loads(body)


def discover(out_dir, only_cubes=None):
    if not BASE or not TOKEN:
        sys.exit("SISENSE_BASE_URL / SISENSE_API_TOKEN not set — run "
                 'eval "$(scripts/sisense-auth.sh)" first.')
    disc = os.path.join(out_dir, "discovery")
    os.makedirs(disc, exist_ok=True)

    # 1. Data models (ElastiCubes / Live)
    cubes = _get("/api/v1/elasticubes/getElasticubes")
    summary = [{
        "oid": c.get("_id") or c.get("oid"),
        "title": c.get("title"),
        "datasets": len(c.get("datasets", [])),
        "destination": (c.get("buildDestination") or {}).get("destination"),
    } for c in cubes]
    json.dump(summary, open(os.path.join(disc, "elasticubes.json"), "w"), indent=2)
    print(f"elasticubes: {len(summary)}")

    # 2. Full schema export per model
    for c in summary:
        title = c["title"]
        if only_cubes and title not in only_cubes:
            continue
        q = urllib.parse.quote(title)
        try:
            schema = _get(f"/api/v2/datamodels/schema?title={q}")
        except Exception as e:  # noqa: BLE001
            print(f"  ! schema export failed for {title!r}: {e}")
            continue
        safe = title.replace("/", "_").replace(" ", "_")
        json.dump(schema, open(os.path.join(disc, f"model_{safe}.json"), "w"), indent=2)
        n_ds = len(schema.get("datasets", []))
        n_rel = len(schema.get("relations", []))
        print(f"  model {title!r}: {n_ds} datasets, {n_rel} relations")

    # 3. Dashboards + widgets
    dashboards = _get("/api/v1/dashboards")
    if not isinstance(dashboards, list):
        dashboards = dashboards.get("dashboards", [])
    for d in dashboards:
        oid = d.get("oid") or d.get("_id")
        if not d.get("widgets") and oid:
            try:
                d["widgets"] = _get(f"/api/v1/dashboards/{oid}/widgets")
            except Exception as e:  # noqa: BLE001
                print(f"  ! widgets fetch failed for dashboard {oid}: {e}")
    json.dump(dashboards, open(os.path.join(disc, "dashboards.json"), "w"), indent=2)
    print(f"dashboards: {len(dashboards)}")
    if not dashboards:
        print("  (none — build a sample dashboard in Sisense before an "
              "end-to-end parity run)")

    print(f"\nwrote bundle -> {disc}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.expanduser("~/sisense-migration"))
    ap.add_argument("--cube", action="append", dest="cubes")
    a = ap.parse_args()
    discover(a.out, a.cubes)
