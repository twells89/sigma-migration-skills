#!/usr/bin/env python3
"""Phase 1 (RLS scan) — detect Sisense data-security rules and map them to Sigma
row-level security, so the migration makes ONE consolidated, reviewed decision
about porting RLS — never silently drop it, never silently port a wrong mapping.

OPTIONAL + NEVER SLOW: RLS porting is opt-in (like every sibling skill). This
detector runs cheaply during discovery; if the cube has NO data-security rules
it prints NOTHING and exits 0 — the happy path is untouched. When rules ARE
found it prints a structured summary + the recommended Sigma mapping, and (with
--out) writes a converter-style `security[]` JSON that the tool-agnostic
`apply_sigma_rls.py --from-security` provisions and applies (opt-in, plan-only
by default). Exit 0 always on a clean scan; exit 2 on a usage/IO error.

Sisense data security (per ElastiCube/Live cube) restricts a table column to a
set of member values per user/group:
  GET /api/elasticubes/{server}/{cube}/datasecurity  -> [ rule, ... ]
  rule ≈ {table, column, members[], allMembers, exclusionary, shares[{party,type}]}

Sigma mapping (the verified recipe — see refs + apply_sigma_rls.py):
  a per-column **user attribute** + a boolean calc column on the table element
  `CurrentUserAttributeText("<col>") = [<Col>]` + an element list filter showing
  only True. Per-user member values are assigned to the attribute (not faked
  here — flagged for provisioning).

Usage:
  eval "$(scripts/sisense-auth.sh)"
  python3 detect_rls.py "Sample ECommerce" [--server LocalHost] [--json] [--out security.json]
"""
import argparse, json, os, ssl, sys, urllib.parse, urllib.request, urllib.error

def _get(url):
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer " + os.environ["SISENSE_API_TOKEN"])
    ctx = ssl._create_unverified_context()           # trial CA lacks key-usage ext
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
            return json.loads(r.read() or "null")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        sys.exit(f"[detect_rls] HTTP {e.code} on {url}: {e.read().decode()[:200]}")

def fetch_rules(base, server, cube):
    path = f"/api/elasticubes/{urllib.parse.quote(server)}/{urllib.parse.quote(cube)}/datasecurity"
    rules = _get(base.rstrip('/') + path)
    return rules if isinstance(rules, list) else []

def to_security(rules):
    """Sisense data-security rules -> converter-style result.security[] entries
    (the shape apply_sigma_rls.py --from-security consumes)."""
    out = []
    for r in rules:
        table = r.get("table") or r.get("elasticubeTable") or "?"
        col = r.get("column") or r.get("dim") or "?"
        attr = col                                   # one Sigma user attribute per restricted column
        members = r.get("members") or []
        parties = [s.get("party") or s.get("partyId") for s in (r.get("shares") or [])]
        out.append({
            "kind": "rls", "elementName": table,
            "rls": {
                "name": f"RLS {col}",
                # Text([col]) coerces the operand so the comparison is text=text
                # regardless of the restricted column's type — a numeric column
                # (e.g. an ID) compared bare to the text user-attribute value
                # silently matches nothing. Text() is idempotent on text columns.
                "formula": f'CurrentUserAttributeText("{attr}") = Text([{col}])',
                "userAttributes": [attr], "teams": [],
            },
            "_source": {"table": table, "column": col, "members": members,
                        "allMembers": bool(r.get("allMembers")),
                        "exclusionary": bool(r.get("exclusionary")),
                        "appliesTo": parties},
        })
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cube", help="ElastiCube / Live cube title (datasource title)")
    ap.add_argument("--server", default="LocalHost")
    ap.add_argument("--json", action="store_true", help="machine output (security[] JSON to stdout)")
    ap.add_argument("--out", help="write the security[] JSON to this file (for apply_sigma_rls.py)")
    a = ap.parse_args()
    if not os.environ.get("SISENSE_API_TOKEN"):
        sys.exit('[detect_rls] need SISENSE_API_TOKEN — run: eval "$(scripts/sisense-auth.sh)"')

    rules = fetch_rules(os.environ["SISENSE_BASE_URL"], a.server, a.cube)
    security = to_security(rules)

    if a.out:
        json.dump(security, open(a.out, "w"), indent=2)
    if a.json:
        print(json.dumps(security, indent=2))
        return

    if not security:
        # NEVER SLOW: nothing to decide -> silent, clean exit.
        return
    print(f"=== Sisense data security on '{a.cube}': {len(security)} rule(s) -> Sigma RLS ===")
    for s in security:
        src = s["_source"]
        scope = "ALL members" if src["allMembers"] else (f"{len(src['members'])} member(s)")
        excl = " (exclusionary)" if src["exclusionary"] else ""
        print(f"  • {src['table']}.{src['column']}  restrict to {scope}{excl}; "
              f"applies to {len(src['appliesTo'])} principal(s)")
        print(f"      Sigma → user attribute \"{s['rls']['userAttributes'][0]}\" + row filter "
              f"{s['rls']['formula']}")
    print("\nRLS porting is OPT-IN. To provision + apply (reuse-first, plan-only by default):")
    print('  python3 detect_rls.py "%s" --out security.json' % a.cube)
    print("  python3 apply_sigma_rls.py --from-security security.json --dm-id <dataModelId>")
    print("  # add --provision --apply once you've reviewed the plan; assign per-user")
    print("  # values with POST /v2/user-attributes/{id}/users (members not faked here).")

if __name__ == "__main__":
    main()
