#!/usr/bin/env python3
"""test_batch_migrate_coderep.py — batch-migrate.py's workbook code-rep
`document` envelope handling (2026-08, task 3.9).

Before this fix: build() POSTed its flat workbook spec straight to
/v2/workbooks/spec — the live workbook code-rep surface requires the nested
`document` envelope and 400s on a flat body.

Offline: monkeypatches the module's post() (the only network call site in
build()) and runs the real function unchanged.

Usage: python3 scripts/test_batch_migrate_coderep.py
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "batch-migrate.py")

FAILS = []


def check(cond, msg):
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")
    if not cond:
        FAILS.append(msg)


os.environ.setdefault("SIGMA_BASE_URL", "http://stub.invalid")
os.environ.setdefault("SIGMA_API_TOKEN", "dummy-test-token")


def _load_module():
    spec = importlib.util.spec_from_file_location("batch_migrate_coderep_ut", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


BM = _load_module()

calls = {"post_body": None}


def fake_post(path, body):
    assert path == "/v2/workbooks/spec", path
    calls["post_body"] = body
    return "workbookId: 11111111-1111-4111-8111-111111111111"


BM.post = fake_post
# build() shells out to the Python layout PUT helper (a real Sigma PUT) once it
# has a workbookId — stub it out so this test stays fully offline/no-subprocess.
BM.subprocess.run = lambda *a, **k: None

wb = BM.build("Acme Retail")

check(wb == "11111111-1111-4111-8111-111111111111", f"build() returns the posted workbookId (got {wb!r})")
posted = calls["post_body"]
check(posted is not None, "a POST was issued")
check(isinstance(posted, dict) and isinstance(posted.get("document"), dict),
      "POST body carries a top-level `document` key (the wrap the bug omitted)")
check(posted is not None and "pages" not in posted,
      "POST body has NO top-level `pages` (must be nested, not flat)")
check(posted is not None and isinstance(posted["document"].get("pages"), list)
      and len(posted["document"]["pages"]) == 2,
      "wrapped document carries both pages (Data + Overview)")
check(posted is not None and posted.get("name") == "Acme Retail → Sigma",
      "name stays OUTSIDE document as metadata")
check(posted is not None and posted.get("schemaVersion") is None,
      "schemaVersion is NOT left at the top level (moved into document)")
check(posted is not None and posted["document"].get("schemaVersion") == 1,
      "schemaVersion moved into document")
check(posted is not None and all("elements" not in p for p in posted["document"]["pages"]),
      "workbook pages are metadata-only")
check(posted is not None and isinstance(posted["document"].get("elements"), list),
      "workbook elements are flat under document")
check(posted is not None and bool(posted["document"].get("layout")),
      "the wrapped document carries required authoritative layout XML")
layout = posted["document"]["layout"]
check("<Element " in layout and "<Container " in layout,
      "layout uses canonical Element and Container tags")
check("<LayoutElement" not in layout and "<GridContainer" not in layout,
      "layout does not emit rejected legacy tags")

print()
if FAILS:
    print(f"{len(FAILS)} FAILURE(S):")
    for f in FAILS:
        print(f"  - {f}")
    sys.exit(1)
print("ALL PASS")
