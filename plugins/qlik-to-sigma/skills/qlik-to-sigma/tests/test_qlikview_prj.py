#!/usr/bin/env python3
"""Grounding test for the QlikView (.qvw) "-prj" migration path (migrate-qlikview.rb).

Offline (no Sigma): runs the dedicated QlikView entry point in --dry-run over the
committed fixture and asserts the LOCAL vendored converter produces a well-formed,
POST-shaped data model. The LIVE column-resolution check (0 error-typed columns)
is exercised by the converter repo's `npm run regression -- qvw` gate; this test
guards the skill-side wiring (delegation, file gather, converter invocation, spec
shape) without needing credentials.

Run: python3 tests/test_qlikview_prj.py   (exit 0 = pass)
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIX = os.path.join(SKILL, "fixtures", "qlikview-retail-prj")


def _run_dry(entry_args):
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run(
            ["ruby", *entry_args, "--prj", FIX, "--out", d, "--dry-run",
             "--database", "CSA", "--schema", "TJ"],
            capture_output=True, text=True)
        assert r.returncode == 0, "dry-run failed:\n" + r.stdout + r.stderr
        conv = json.load(open(os.path.join(d, "converter-out.json")))
        spec = json.load(open(os.path.join(d, "dm-spec.json")))
        return conv, spec, (r.stdout + r.stderr)


def test_dedicated_entrypoint():
    conv, spec, out = _run_dry([os.path.join(SCRIPTS, "migrate-qlikview.rb")])
    stats = conv.get("stats", {})
    # Same shape the converter's expected.summary.json asserts, verified skill-side.
    assert stats.get("elements", 0) >= 3, stats
    assert stats.get("relationships", 0) >= 2, stats
    assert stats.get("metrics", 0) >= 3, stats
    assert spec.get("schemaVersion") == 1, spec.get("schemaVersion")
    # Honesty: a -prj folder has no row counts, so the shared-field-name caveat must surface.
    assert any("shared field name" in w for w in conv.get("warnings", [])), conv.get("warnings")


def test_delegation_from_migrate_qlik():
    # `migrate-qlik.rb --prj` must delegate to the QlikView path and produce the same model.
    conv, spec, out = _run_dry([os.path.join(SCRIPTS, "migrate-qlik.rb")])
    assert conv.get("stats", {}).get("elements", 0) >= 3, conv.get("stats")
    assert "QlikView -prj" in out, "delegation banner missing — migrate-qlik.rb may not be delegating"


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted((n, f) for n, f in globals().items() if n.startswith("test_")):
        try:
            fn(); print(f"ok  {name}")
        except AssertionError as e:
            fails += 1; print(f"FAIL {name}: {e}")
    sys.exit(1 if fails else 0)
