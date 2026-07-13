#!/usr/bin/env python3
"""Grounding regression for build_workbook.py (beads-sigma-kvza).

Proves the dashboard classifier is documentation-grounded and loud-on-unmapped:
  1. GOLDEN LOCK   — the fixture builds byte-identical (modulo random ids) to the
     committed golden, so catalog extraction + loud-fallback edits changed no
     behavior on a clean dashboard.
  2. CATALOGS      — all four refs/catalogs/*.json load, have unique cited rows.
  3. NO INLINE MAP — the viz/format/aggregation maps are LOADED from the catalogs;
     no residual inline literal bypasses the single source of truth.
  4. LOUD FALLBACKS — an unknown vis type, an unmapped value_format_name, and an
     unmapped measure type each WARN (never a silent skip / wrong default).

Run: python3 tests/test_grounding.py   (exit 0 = pass)
"""
import json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIX = os.path.join(SKILL, "fixtures", "skilltest-orders")
VIEWS = os.path.join(FIX, "views")
DASH = os.path.join(FIX, "skilltest_orders.dashboard.lookml")
CATDIR = os.path.join(SKILL, "refs", "catalogs")
GOLDEN = os.path.join(HERE, "golden", "skilltest_orders_workbook.canon.txt")
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))

ID_RE = re.compile(r'[a-z]{1,6}-[a-z0-9]{8}')

def canon(spec):
    s = json.dumps(spec, indent=2, sort_keys=True)
    remap = {}
    def repl(m):
        t = m.group(0)
        if t not in remap: remap[t] = "ID%04d" % len(remap)
        return remap[t]
    return ID_RE.sub(repl, s)

def build(contract, views=VIEWS):
    with tempfile.TemporaryDirectory() as d:
        cpath = os.path.join(d, "c.json"); opath = os.path.join(d, "wb.json")
        json.dump(contract, open(cpath, "w"))
        r = subprocess.run(
            [sys.executable, os.path.join(SCRIPTS, "build_workbook.py"), cpath,
             "--views", views, "--dm-id", "dm-x", "--element-id", "el-x",
             "--dm-element-name", "Order Fact", "--out", opath],
            capture_output=True, text=True)
        assert r.returncode == 0, "build_workbook failed:\n" + r.stderr
        return json.load(open(opath)), (r.stdout + r.stderr)


def test_golden():
    import parse_lookml_dashboard as offline
    contract = offline.parse(DASH)[0]
    spec, _ = build(contract)
    got = canon(spec)
    want = open(GOLDEN).read()
    assert got == want, ("GOLDEN DRIFT — build_workbook output changed on the clean "
                         "fixture. If intentional, regenerate the golden.\n"
                         + "\n".join(_first_diff(want, got)))
    print("[ok] golden: fixture builds byte-identical to committed golden")

def _first_diff(a, b):
    la, lb = a.splitlines(), b.splitlines()
    for i, (x, y) in enumerate(zip(la, lb)):
        if x != y:
            return ["  first diff @line %d" % i, "  golden: " + x, "  got:    " + y]
    return ["  (length differs: %d vs %d lines)" % (len(la), len(lb))]


def test_catalogs_valid():
    import coverage_catalog as cc
    cats = cc.load_all(CATDIR)
    assert set(cats) == {"viz-kind", "number-format", "aggregation", "control"}, sorted(cats)
    for name, cat in cats.items():
        assert cat.rows, name
        assert cat.source_tool == "looker", (name, cat.source_tool)
        assert cat.authoritative_doc.startswith("http") or name == "control", name
        seen = set()
        for r in cat.rows:
            key = str(r["source"]).lower()
            assert key not in seen, ("duplicate source in %s: %s" % (name, key))
            seen.add(key)
            assert r.get("doc_ref", "").startswith("http"), (name, r["source"])
            # every mapped Sigma target present (aggregation count/cd document it too)
            assert r.get("sigma") is not None or r.get("sigma_if") is not None, (name, r["source"])
    print("[ok] catalogs: 4 dimensions load, cited, unique sources")


def test_no_inline_maps():
    src = open(os.path.join(SCRIPTS, "build_workbook.py")).read()
    assert "coverage_catalog" in src and "_cc.load(" in src, "builder does not load catalogs"
    # the maps must be catalog-derived, not inline literals
    assert "for r in VIZ_CAT.rows" in src, "TILE_KIND not derived from viz-kind catalog"
    assert "for r in FMT_CAT.rows" in src, "VALUE_FORMAT_NAME_MAP not derived from catalog"
    assert "for r in AGG_CAT.rows" in src, "AGG/IF_AGG not derived from aggregation catalog"
    # the two old silent defaults must be gone
    assert 'if fn and cd else "Count()"' not in src, "silent AGG else-Count() still present"
    assert 'if cd else "Count()"' not in src, "silent count_distinct else-Count() still present"
    print("[ok] no-inline-map: viz/format/agg maps loaded from catalogs; silent Count() removed")


def _clone_element(contract, pred):
    for el in contract["elements"]:
        if pred(el):
            return json.loads(json.dumps(el))
    raise AssertionError("no element matched")


def test_loud_unknown_viz():
    import parse_lookml_dashboard as offline
    contract = offline.parse(DASH)[0]
    el = _clone_element(contract, lambda e: e.get("tileType") == "single_value")
    el["name"] = "Funnel Tile"; el["tileType"] = "looker_funnel"
    contract["elements"].append(el)
    spec, out = build(contract)
    assert "looker_funnel" in out and "no Sigma mapping" in out, out
    # the funnel tile must NOT have produced an element
    names = re.findall(r'"name":\s*"([^"]*)"', json.dumps(spec))
    assert "Funnel Tile" not in names, "unmapped viz was silently emitted"
    print("[ok] loud viz: unknown vis type 'looker_funnel' warns + skips")


def test_loud_unknown_format():
    import importlib, coverage_catalog  # noqa
    bw = importlib.import_module("build_workbook")
    with tempfile.TemporaryDirectory() as d:
        vpath = os.path.join(d, "t.view.lkml")
        open(vpath, "w").write(
            "view: t {\n"
            "  dimension: pk { primary_key: yes type: number sql: ${TABLE}.ID ;; }\n"
            "  dimension: amt { hidden: yes type: number sql: ${TABLE}.AMT ;; }\n"
            "  measure: good { type: sum sql: ${amt} ;; value_format_name: usd }\n"
            "  measure: bad_fmt { type: sum sql: ${amt} ;; value_format_name: zzz_bogus_fmt }\n"
            "}\n")
        w = []
        bw.build_field_index([vpath], None, w)
        joined = "\n".join(w)
        assert "zzz_bogus_fmt" in joined and "UNFORMATTED" in joined, joined
        # the good one produced NO warning
        assert "value_format_name 'usd'" not in joined, joined
    print("[ok] loud format: unmapped value_format_name warns (ships unformatted)")


def test_loud_unknown_agg():
    """A measure of an unmapped LookML type -> loud placeholder, not a silent Count()."""
    import parse_lookml_dashboard as offline
    with tempfile.TemporaryDirectory() as d:
        vdir = os.path.join(d, "views"); shutil.copytree(VIEWS, vdir)
        of = os.path.join(vdir, "order_fact.view.lkml")
        txt = open(of).read().rstrip()
        assert txt.endswith("}"), "unexpected view file shape"
        txt = txt[:-1] + (
            "\n  measure: weird_metric {\n"
            "    type: sum_distinct\n"
            "    sql: ${net_revenue} ;;\n"
            "  }\n}\n")
        open(of, "w").write(txt)
        contract = offline.parse(DASH)[0]
        el = _clone_element(contract, lambda e: e.get("tileType") == "single_value")
        el["name"] = "Weird KPI"; el["fields"] = ["order_fact.weird_metric"]
        el["listen"] = {}
        contract["elements"].append(el)
        spec, out = build(contract, views=vdir)
        assert "weird_metric" in out and "no documented Sigma aggregate" in out, out
        assert "unmapped measure type sum_distinct" in json.dumps(spec), \
            "expected a loud placeholder column formula for the unmapped measure type"
        assert "Count()" not in json.dumps(spec).split("Weird")[1][:200] if "Weird" in json.dumps(spec) else True
    print("[ok] loud agg: unmapped measure type -> placeholder + warn (no silent Count())")


def test_coverage_matrix_fresh():
    """refs/looker-coverage.md must be regenerated from the catalogs (no drift)."""
    r = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "gen-coverage-matrix.py"),
         "--catalogs", CATDIR, "--skill", "looker",
         "--out", os.path.join(SKILL, "refs", "looker-coverage.md"), "--check"],
        capture_output=True, text=True)
    assert r.returncode == 0, ("coverage matrix is stale — regenerate:\n" + r.stderr)
    print("[ok] coverage matrix: refs/looker-coverage.md matches the catalogs")


if __name__ == "__main__":
    test_catalogs_valid()
    test_no_inline_maps()
    test_coverage_matrix_fresh()
    test_golden()
    test_loud_unknown_viz()
    test_loud_unknown_format()
    test_loud_unknown_agg()
    print("ALL PASS")
