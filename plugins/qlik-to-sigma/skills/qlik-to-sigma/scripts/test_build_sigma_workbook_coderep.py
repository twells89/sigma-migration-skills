#!/usr/bin/env python3
"""test_build_sigma_workbook_coderep.py — guards the workbook POST in
build-sigma-workbook.py's main() against the workbook code-rep `document`
wrapper (live since 2026-08).

build-sigma-workbook.py POSTs its built flat workbook spec to
/v2/workbooks/spec. The live workbook code-rep surface requires the nested
`document` envelope and 400s on a flat body.

main() is a ~250-line orchestrator (argparse + control-scope + coverage
bookkeeping around this POST, so it can't be isolated into a runnable unit
offline) — source-level assertions, mirroring the same "can't isolate a
god-function" approach used for migrate-looker.py / migrate-powerbi.rb /
the Qlik migration entrypoints in this same task.

Usage: python3 scripts/test_build_sigma_workbook_coderep.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "build-sigma-workbook.py")).read()

FAILS = []


def check(cond, msg):
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")
    if not cond:
        FAILS.append(msg)


check("import code_rep as _cr" in SRC, "build-sigma-workbook.py imports code_rep")

post_idx = SRC.find('api_post("/v2/workbooks/spec", ')
check(post_idx >= 0, "the workbook-spec api_post call is present")

if post_idx >= 0:
    window = SRC[max(0, post_idx - 300):post_idx + 80]
    wrap_m = re.search(
        r"post_body\s*=\s*_cr\.wrap\(\s*_cr\.document\(spec\)\s*,\s*_cr\.metadata\(spec\)\s*\)",
        window)
    check(wrap_m is not None, "post_body = _cr.wrap(_cr.document(spec), _cr.metadata(spec)) precedes the POST")
    check('api_post("/v2/workbooks/spec", post_body)' in window,
          "the api_post call passes `post_body` (the wrapped spec), not the raw flat `spec`")
    if wrap_m:
        wrap_end = max(0, post_idx - 300) + wrap_m.end()
        check(wrap_end <= post_idx, "the wrap assignment precedes the api_post call (source order)")

all_post_sites = [m.start() for m in re.finditer(r'api_post\(\s*"/v2/workbooks/spec"', SRC)]
check(len(all_post_sites) == 1,
      f"exactly one /v2/workbooks/spec api_post call site in the file (got {len(all_post_sites)})")

print()
if FAILS:
    print(f"{len(FAILS)} FAILURE(S):")
    for f in FAILS:
        print(f"  - {f}")
    sys.exit(1)
print("ALL PASS")
