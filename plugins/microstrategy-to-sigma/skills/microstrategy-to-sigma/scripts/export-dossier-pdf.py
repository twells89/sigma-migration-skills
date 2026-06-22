#!/usr/bin/env python3
"""Export the SOURCE MicroStrategy dossier to PDF — the visual-parity reference.

Why this exists: the dossier *definition* (panelStacks/visualizations) does NOT
carry the rendered layout, styling, branding, or the actual metric VALUES each
viz displays. A converter that builds only from the definition produces a
workbook with the right data but the wrong *look*. To match the source you must
SEE it. This pulls a pixel-faithful PDF of the live dossier so the Visual QA
gate can put the Sigma render side-by-side with the original and check fidelity
(arrangement, chart kinds, KPI semantics, branding), not just generic quality.

Pairs with execute-instance value capture (see SKILL.md Phase 1): the PDF tells
you the layout; executing each visualization tells you the exact displayed
values (KPIs are often a LATEST-DATE stat, not a windowed Sum — never assume).

Usage:
  python3 scripts/export-dossier-pdf.py <dossierId> [out.pdf]

Env: ~/microstrategy-migration/.mstr_env (or wherever mstr.py reads), same auth
as the rest of the pipeline. Requires mstr.py alongside this script.
"""
import base64
import sys
import mstr


def main():
    if len(sys.argv) < 2:
        print("usage: export-dossier-pdf.py <dossierId> [out.pdf]", file=sys.stderr)
        sys.exit(2)
    dossier_id = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "source_dossier.pdf"

    s = mstr.Session()
    # Instance must be created and exported within ONE auth session (session-bound).
    iid = s.post(f"/dossiers/{dossier_id}/instances", {})["mid"]
    # NOTE: the v1 path works; /v2/dossiers/.../pdf 404s on this build.
    resp = s.post(f"/documents/{dossier_id}/instances/{iid}/pdf", {})
    if not resp or "data" not in resp:
        print(f"error: no PDF data returned: {str(resp)[:200]}", file=sys.stderr)
        sys.exit(1)
    pdf = base64.b64decode(resp["data"])
    with open(out, "wb") as f:
        f.write(pdf)
    print(f"wrote {out} ({len(pdf)} bytes) — READ it, then match the Sigma build to it")


if __name__ == "__main__":
    main()
