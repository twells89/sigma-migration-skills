#!/usr/bin/env python3
"""Offline tests for the gap-scout (scan_gaps.py) + RLS mapping (detect_rls.py).
Run: python3 tests/test_gaps_rls.py"""
import sys, os, json, subprocess, tempfile
HERE = os.path.dirname(__file__)
SCRIPTS = os.path.join(HERE, "..", "scripts")
sys.path.insert(0, SCRIPTS)
import detect_rls as R

FIX = os.path.join(HERE, "..", "fixtures")
passed = failed = 0
def ok(label, cond, extra=""):
    global passed, failed
    passed += 1 if cond else 0
    failed += 0 if cond else 1
    print(("  ok  " if cond else "  FAIL ") + label + (f"  {extra}" if extra and not cond else ""))

# --- gap scout: coverage report + learned-rules ledger + strict gate ---
with tempfile.TemporaryDirectory() as td:
    rules = os.path.join(td, "learned.json")
    r = subprocess.run([sys.executable, os.path.join(SCRIPTS, "scan_gaps.py"),
                        os.path.join(FIX, "dashboards.json"), "--rules", rules],
                       capture_output=True, text=True)
    ok("scan_gaps runs, reports coverage", r.returncode == 0 and "coverage" in r.stdout, r.stdout + r.stderr)
    ok("scan_gaps flags MANUAL treemap/sunburst", "MANUAL" in r.stdout and "treemap" in r.stdout.lower())
    ok("scan_gaps writes learned-rules ledger", os.path.exists(rules))
    if os.path.exists(rules):
        led = json.load(open(rules))
        ok("ledger captured the unmapped widgets", any(g["category"] == "MANUAL" for g in led), str(led)[:200])
    # strict mode -> non-zero while gaps remain
    rs = subprocess.run([sys.executable, os.path.join(SCRIPTS, "scan_gaps.py"),
                         os.path.join(FIX, "dashboards.json"), "--rules", rules, "--strict"],
                        capture_output=True, text=True)
    ok("scan_gaps --strict exits non-zero on unresolved gaps", rs.returncode != 0 and "RED" in rs.stdout + rs.stderr)

# --- RLS: Sisense data-security rule -> Sigma security[] mapping ---
fake = [{"table": "Commerce", "column": "Country", "members": ["USA", "Canada"],
         "allMembers": False, "exclusionary": False, "shares": [{"party": "u1", "type": "user"}]}]
sec = R.to_security(fake)
ok("detect_rls maps a rule to one security entry", len(sec) == 1)
e = sec[0]
ok("entry kind=rls on the right element", e["kind"] == "rls" and e["elementName"] == "Commerce")
ok("entry uses CurrentUserAttributeText row filter (Text-coerced operand)",
   e["rls"]["formula"] == 'CurrentUserAttributeText("Country") = Text([Country])')
ok("entry names the user attribute", e["rls"]["userAttributes"] == ["Country"])
ok("members carried (not faked) for provisioning", e["_source"]["members"] == ["USA", "Canada"])
ok("no rules -> empty security[] (zero-overhead path)", R.to_security([]) == [])

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
