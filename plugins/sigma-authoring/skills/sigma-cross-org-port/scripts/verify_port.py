#!/usr/bin/env python3
"""Verify a cross-org port. A 2xx on create proves nothing: Sigma accepts specs
whose formulas don't resolve and embeds the failure as a string literal in the
compiled SQL, so the element renders empty.

    structure --src-spec S.yaml --dst-spec D.yaml
        Offline. Element ids/kinds, pages, panels, overlays, layout placement,
        and a field-level diff that ignores the rewrites a port is SUPPOSED to
        make (connectionId, image source, groupingId: base).

    compile --base-url URL --workbook-id ID [--token T]
        Live. Queries every data element and fails on an error literal baked
        into the SQL. Token defaults to $SIGMA_API_TOKEN.

    baseline --base-url URL --workbook-id ID [--token T]
        Same probe against the SOURCE workbook. Run it whenever `compile`
        reports a failure: if the source fails identically, the port is
        faithful and the defect is pre-existing upstream.

Stdlib only.
"""

import argparse
import collections
import json
import os
import re
import sys
import urllib.error
import urllib.request

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML required: python3 -m pip install pyyaml")

DATA_KINDS = {"table", "pivot-table", "input-table", "bar-chart", "line-chart",
              "kpi-chart", "point-map", "region-map", "geography-map",
              "pie-chart", "donut-chart", "scatter-chart", "combo-chart"}

# Errors Sigma bakes into compiled SQL as string literals when a ref won't resolve.
ERR_RE = re.compile(
    r"'((?:Unknown column|Circular column reference|Column )[^']{0,160})'")


def load_doc(path):
    with open(path, encoding="utf-8") as fh:
        spec = yaml.safe_load(fh)
    return spec["document"] if "document" in spec else spec


def scrub(node):
    """Neutralise the differences a port is SUPPOSED to introduce."""
    if isinstance(node, dict):
        if node.get("kind") == "upload":
            return {"__IMAGE__": True}
        if node.get("kind") == "url" and str(node.get("url", "")).startswith("data:"):
            return {"__IMAGE__": True}
        return {k: scrub(v) for k, v in node.items()
                if k not in ("connectionId",) and not (k == "groupingId" and v == "base")}
    if isinstance(node, list):
        return [scrub(v) for v in node]
    return node


def diff(a, b, path, out):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a:
                out.append(f"+ {path}.{k} = {json.dumps(b[k])[:90]}")
            elif k not in b:
                out.append(f"- {path}.{k} = {json.dumps(a[k])[:90]}")
            else:
                diff(a[k], b[k], f"{path}.{k}", out)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append(f"~ {path}: length {len(a)} -> {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, f"{path}[{i}]", out)
    elif a != b:
        out.append(f"~ {path}: {json.dumps(a)[:70]} -> {json.dumps(b)[:70]}")


def cmd_structure(args):
    s, t = load_doc(args.src_spec), load_doc(args.dst_spec)
    fails = []

    def kinds(d):
        return dict(sorted(collections.Counter(
            e.get("kind") for e in d.get("elements", [])).items()))

    checks = [
        ("element count", len(s.get("elements", [])), len(t.get("elements", []))),
        ("page count", len(s.get("pages", [])), len(t.get("pages", []))),
        ("panel count", len(s.get("panels", [])), len(t.get("panels", []))),
        ("overlay count", len(s.get("overlays", [])), len(t.get("overlays", []))),
        ("element kinds", kinds(s), kinds(t)),
        ("layout <Element> count",
         len(re.findall(r"<Element\s", s.get("layout") or "")),
         len(re.findall(r"<Element\s", t.get("layout") or ""))),
        ("layout <Container> count",
         len(re.findall(r"<Container\s", s.get("layout") or "")),
         len(re.findall(r"<Container\s", t.get("layout") or ""))),
        ("layout <Page> count",
         len(re.findall(r"<Page\s", s.get("layout") or "")),
         len(re.findall(r"<Page\s", t.get("layout") or ""))),
        ("settings", s.get("settings"), t.get("settings")),
    ]
    for label, a, b in checks:
        ok = a == b
        print(f"  [{'OK  ' if ok else 'FAIL'}] {label}: {a if not isinstance(a, dict) else ''}"
              f"{'' if ok else f'  src={a} dst={b}'}")
        if not ok:
            fails.append(label)

    sid = {e["id"] for e in s.get("elements", []) if "id" in e}
    tid = {e["id"] for e in t.get("elements", []) if "id" in e}
    if sid != tid:
        fails.append("element ids")
        print(f"  [FAIL] element ids: missing={sorted(sid - tid)} extra={sorted(tid - sid)}")
    else:
        print(f"  [OK  ] element ids: all {len(sid)} preserved")

    se = {e["id"]: e for e in s.get("elements", []) if "id" in e}
    te = {e["id"]: e for e in t.get("elements", []) if "id" in e}
    unexpected = 0
    for eid in sorted(sid & tid):
        out = []
        diff(scrub(se[eid]), scrub(te[eid]), "", out)
        if out:
            unexpected += 1
            print(f"  [DIFF] {eid} ({se[eid].get('kind')}) {se[eid].get('name')!r}")
            for line in out[:6]:
                print(f"           {line}")
    print(f"  [{'OK  ' if not unexpected else 'WARN'}] "
          f"{unexpected} element(s) differ beyond the expected port rewrites")

    if fails:
        print(f"\nSTRUCTURE FAIL: {', '.join(fails)}")
        return 1
    print("\nSTRUCTURE OK")
    return 0


def api_get(base, token, path):
    req = urllib.request.Request(base.rstrip("/") + path,
                                 headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read().decode("utf-8", "replace")


def probe(args, label):
    token = args.token or os.environ.get("SIGMA_API_TOKEN")
    if not token:
        sys.exit("no token: pass --token or export SIGMA_API_TOKEN")
    spec = yaml.safe_load(api_get(args.base_url, token,
                                  f"/v2/workbooks/{args.workbook_id}/spec"))
    doc = spec["document"]
    results, bad = [], 0
    for e in doc.get("elements", []):
        if e.get("kind") not in DATA_KINDS:
            continue
        try:
            body = api_get(args.base_url, token,
                           f"/v2/workbooks/{args.workbook_id}/elements/{e['id']}/query?limit=1")
        except urllib.error.HTTPError as ex:
            print(f"  [FAIL] {e['id']} ({e.get('kind')}) HTTP {ex.code}")
            bad += 1
            results.append({"id": e["id"], "error": f"HTTP {ex.code}"})
            continue
        errs = sorted(set(ERR_RE.findall(body)))
        if errs:
            print(f"  [FAIL] {e['id']} ({e.get('kind')}) {e.get('name')!r}: {errs[0]}")
            bad += 1
            results.append({"id": e["id"], "name": e.get("name"), "errors": errs})
        else:
            results.append({"id": e["id"], "name": e.get("name"), "ok": True})
    total = len(results)
    print(f"\n{label}: {total - bad}/{total} data elements compile clean")
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump(results, fh, indent=2)
    return 1 if bad else 0


def cmd_compile(args):
    return probe(args, "PORTED WORKBOOK")


def cmd_baseline(args):
    rc = probe(args, "SOURCE WORKBOOK (baseline)")
    if rc:
        print("Source fails too — compare the element ids against the ported run. "
              "Identical failures mean the port is faithful and the defect is upstream.")
    return 0  # baseline is informational; never gate on it


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("structure")
    p.add_argument("--src-spec", required=True)
    p.add_argument("--dst-spec", required=True)
    p.set_defaults(fn=cmd_structure)

    for name, fn in (("compile", cmd_compile), ("baseline", cmd_baseline)):
        p = sub.add_parser(name)
        p.add_argument("--base-url", required=True)
        p.add_argument("--workbook-id", required=True)
        p.add_argument("--token")
        p.add_argument("--json-out")
        p.set_defaults(fn=fn)

    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
