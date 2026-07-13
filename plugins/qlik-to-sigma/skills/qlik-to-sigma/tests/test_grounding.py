#!/usr/bin/env python3
"""Grounding regression for build-sigma-workbook.py (beads-sigma-kvza).

  1. GOLDEN LOCK   — the fixture builds byte-identical to the committed golden
     (build-sigma-workbook.py uses a deterministic id counter, no randomness).
  2. CATALOGS      — all four refs/catalogs/*.json load, cited, unique rows.
  3. NO INLINE MAP — viz/aggregation/control maps LOADED from the catalogs; the
     name-substring currency guess + silent ,.0f default are gone.
  4. FORMAT PARSER — sigma_fmt() reproduces every pinned qNumFormat example in
     number-format.json (parser grounded to documented Qlik semantics).
  5. LOUD FALLBACKS — an unknown vizType warns+skips; an absent qFmt ships the
     value unformatted + a loud note (no name-substring guess, no silent default).
  6. NO-DRIFT      — refs/qlik-coverage.md is regenerated from the catalogs.

Run: python3 tests/test_grounding.py   (exit 0 = pass)
"""
import importlib.util, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIX = os.path.join(SKILL, "fixtures", "retail-orders")
CATDIR = os.path.join(SKILL, "refs", "catalogs")
GOLDEN = os.path.join(HERE, "golden", "retail_orders_workbook.spec.json")
BUILDER = os.path.join(SCRIPTS, "build-sigma-workbook.py")
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))


def _load_builder():
    spec = importlib.util.spec_from_file_location("bsw", BUILDER)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def _build(charts=None, denorm=None):
    with tempfile.TemporaryDirectory() as d:
        charts = charts or os.path.join(FIX, "charts.json")
        denorm = denorm or os.path.join(FIX, "denorm.json")
        spec_out = os.path.join(d, "spec.json")
        r = subprocess.run(
            [sys.executable, BUILDER, "--charts", charts, "--layout", os.path.join(FIX, "layout.json"),
             "--denorm", denorm, "--dm-id", "dm-x", "--denorm-element-id", "el-x", "--name", "GOLDEN",
             "--dry-run", "--spec-out", spec_out, "--out", os.path.join(d, "res.json"),
             "--element-map", os.path.join(d, "emap.json"), "--layout-out", os.path.join(d, "l.xml")],
            capture_output=True, text=True)
        assert r.returncode == 0, "builder failed:\n" + r.stderr
        return json.load(open(spec_out)), (r.stdout + r.stderr)


def test_golden():
    spec, _ = _build()
    got = json.dumps(spec, indent=2)
    want = open(GOLDEN).read()
    assert got == want, "GOLDEN DRIFT — build-sigma-workbook output changed on the fixture."
    print("[ok] golden: fixture builds byte-identical to committed golden")


def test_catalogs_valid():
    import coverage_catalog as cc
    cats = cc.load_all(CATDIR)
    assert set(cats) == {"viz-kind", "number-format", "aggregation", "control"}, sorted(cats)
    for name, cat in cats.items():
        assert cat.rows and cat.source_tool == "qlik", name
        seen = set()
        for r in cat.rows:
            k = str(r["source"]).lower()
            assert k not in seen, ("dup source in %s: %s" % (name, k)); seen.add(k)
            assert r.get("doc_ref", "").startswith("http"), (name, r["source"])
    print("[ok] catalogs: 4 dimensions load, cited, unique sources")


def test_no_inline_maps():
    src = open(BUILDER).read()
    assert "coverage_catalog" in src and "_cc.load(" in src, "builder does not load catalogs"
    assert "for r in VIZ_CAT.rows" in src, "NATIVE not derived from viz-kind catalog"
    assert "_AGG_ALT" in src and "AGG_CAT.rows" in src, "aggregation not catalog-derived"
    assert "CTRL_CAT.target(" in src, "control kind not catalog-derived"
    # the name-substring currency guess + silent default must be gone
    assert "revenue|profit|amount|value|cost|price" not in src, "name-substring currency guess still present"
    assert 'return {"kind": "number", "formatString": ",.0f"}' not in src, "silent ,.0f default still present"
    print("[ok] no-inline-map: maps catalog-derived; name-guess + silent default removed")


def test_format_parser_pinned():
    m = _load_builder()
    cat = json.load(open(os.path.join(CATDIR, "number-format.json")))
    for r in cat["rows"]:
        got = (m.sigma_fmt(r["source"]) or {}).get("formatString")
        assert got == r["sigma"], ("qFmt %r -> %r, catalog says %r" % (r["source"], got, r["sigma"]))
    print("[ok] format parser: reproduces all %d pinned qNumFormat examples" % len(cat["rows"]))


def test_loud_no_qfmt_format():
    m = _load_builder()
    # a revenue-named measure with NO qFmt used to name-guess $,.0f; now None + warn
    w = []
    assert m.sigma_fmt(None, "Net Revenue", w) is None, "absent qFmt must yield no format"
    assert w and "UNFORMATTED" in w[0], w
    assert m.sigma_fmt(None, "Total Profit") is None, "no name-substring currency guess allowed"
    # a real qFmt still parses
    assert m.sigma_fmt("$#,##0")["formatString"] == "$,.0f"
    print("[ok] loud format: absent qFmt -> None + warn (no name guess, no silent default)")


def test_loud_unknown_viz():
    # mutate an EXISTING (layout-referenced) chart's vizType to an unmapped one so
    # it is actually placed + classified — an appended chart absent from layout.json
    # is never built.
    charts = json.load(open(os.path.join(FIX, "charts.json")))
    placed = {"c-cat", "c-seg", "c-mon", "c-tbl"}  # ids referenced by layout.json
    hit = next(i for i, c in enumerate(charts) if c["id"] in placed)
    charts[hit] = json.loads(json.dumps(charts[hit]))
    charts[hit]["vizType"] = "sankey"
    with tempfile.TemporaryDirectory() as d:
        cpath = os.path.join(d, "charts.json"); json.dump(charts, open(cpath, "w"))
        spec, out = _build(charts=cpath)
    assert "sankey" in out and ("no native Sigma kind" in out or "approximated" in out), out
    print("[ok] loud viz: unmapped vizType 'sankey' warns (approximated/skipped, not silent)")


def test_coverage_matrix_fresh():
    r = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "gen-coverage-matrix.py"),
         "--catalogs", CATDIR, "--skill", "qlik",
         "--out", os.path.join(SKILL, "refs", "qlik-coverage.md"), "--check"],
        capture_output=True, text=True)
    assert r.returncode == 0, ("coverage matrix stale — regenerate:\n" + r.stderr)
    print("[ok] coverage matrix: refs/qlik-coverage.md matches the catalogs")


if __name__ == "__main__":
    test_catalogs_valid()
    test_no_inline_maps()
    test_format_parser_pinned()
    test_loud_no_qfmt_format()
    test_loud_unknown_viz()
    test_coverage_matrix_fresh()
    test_golden()
    print("ALL PASS")
