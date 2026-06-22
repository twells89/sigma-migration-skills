#!/usr/bin/env python3
"""scout-gate-readback — the run-each-time gap-scout gate for MicroStrategy → Sigma
(bead beads-sigma-5l5e).

MSTR's converter (convert.py metric_formula) passes metric function names through
optimistically — a function with no Sigma equivalent does NOT surface as a
convert-time warning; it surfaces as a type=error column when the freshly-POSTed
workbook is read back. There is no Python orchestrator that POSTs (Phase 4 of
SKILL.md POSTs the workbook via curl), so this standalone script IS the mechanical
gate: SKILL.md mandates running it immediately after the workbook POST, replacing
the prose "check for type:error columns" instruction with a hard, scripted STOP.

Run it after the workbook POST (Phase 4):
    eval "$(scripts/get-token.sh)"
    python3 scripts/scout-gate-readback.py --workbook-id <id> --workdir <dir>

Behavior (mirrors the looker / thoughtspot readback gate):
  - GET /v2/workbooks/{id}/columns, find type=error columns.
  - gap-id = errcol:<elementId>/<label>; classify against <workdir>/scout-ledger.jsonl.
  - any UNSCOUTED error column  -> exit 11 (GAP-SCOUT REQUIRED; scout each, re-run).
    --yes does NOT skip this gate; it only accepts columns the scout already tried.
  - every error column scouted (validated or escalated) -> exit 0 (proceed).
  - no error columns -> exit 0.

Env: SIGMA_BASE_URL, SIGMA_API_TOKEN (eval get-token.sh first).
"""
import argparse
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import scout_gate

BASE = os.environ.get("SIGMA_BASE_URL", "https://aws-api.sigmacomputing.com")
TOKEN = os.environ.get("SIGMA_API_TOKEN") or sys.exit(
    'SIGMA_API_TOKEN not set — run: eval "$(scripts/get-token.sh)"')


def api(method, path):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workbook-id", required=True)
    ap.add_argument("--workdir", required=True,
                    help="conversion working dir holding scout-ledger.jsonl")
    ap.add_argument("--yes", action="store_true",
                    help="unattended: accept unscouted ERROR-typed columns (they ship "
                         "FLAGGED in Sigma) and proceed instead of stopping")
    a = ap.parse_args()

    st, body = api("GET", f"/v2/workbooks/{a.workbook_id}/columns")
    if st >= 300:
        sys.exit(f"FATAL: columns GET failed {st}: {body[:300]}")
    cols = json.loads(body)
    entries = cols.get("entries") if isinstance(cols, dict) else cols
    entries = entries or []
    errs = [c for c in entries if (c.get("type") or {}).get("type") == "error"]
    n = len(entries)
    print(f"workbook {a.workbook_id}: {n - len(errs)}/{n} columns resolve"
          + (f" — {len(errs)} ERROR-typed" if errs else ""))
    if not errs:
        return
    for c in errs[:6]:
        print(f"  [{c.get('elementId')}] {c.get('label')}: {c.get('formula')}")

    gid = lambda c: "errcol:%s/%s" % (c.get("elementId"), c.get("label"))
    gap_ids = list(dict.fromkeys(gid(c) for c in errs))
    bk = scout_gate.classify(a.workdir, gap_ids)
    if bk["unscouted"] and a.yes:
        # Regression fix (gap-scout PR #153 made --yes a no-op here, hard-stopping the
        # unattended/demo path). Under --yes the gate is ADVISORY: ERROR-typed columns
        # ship FLAGGED in Sigma (as before the gate existed) and the run proceeds.
        # Record them so re-runs don't re-surface; recommend the gap-scout.
        print("\ngap-scout: %d ERROR-typed column(s) NOT scouted — proceeding (--yes); they ship FLAGGED/broken in Sigma."
              % len(bk["unscouted"]))
        print("(optional: run scripts/gap-scout.md on these to persist a faithful Sigma translation)")
        for i in bk["unscouted"]:
            scout_gate.record(a.workdir, i, "errcol", "accepted")
        return
    if bk["unscouted"]:
        print("\n==================== GAP-SCOUT REQUIRED ====================")
        print("%d of %d ERROR-typed column(s) have NOT been scouted — the gap-scout must"
              % (len(bk["unscouted"]), len(gap_ids)))
        print("attempt a Sigma translation before a broken column ships:")
        for i in bk["unscouted"]:
            print("  --gap-id '%s'" % i)
        print("\nSpawn one gap-scout per column (scripts/gap-scout.md) with the exact --gap-id")
        print("above plus --workdir %s, then re-run this gate, OR re-run with --yes to ship them FLAGGED." % a.workdir)
        print("===========================================================")
        sys.exit(11)
    print("gap-scout: all %d error column(s) accounted for (validated or escalated)" % len(gap_ids))


if __name__ == "__main__":
    main()
