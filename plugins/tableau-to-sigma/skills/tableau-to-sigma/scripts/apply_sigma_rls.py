#!/usr/bin/env python3
"""Phase 1.5 (RLS decision gate) — apply a Looker RLS finding to Sigma, scripted.

Sigma user attributes are FULLY API-supported (confirmed live 2026-06-10):
  - GET  /v2/user-attributes            list (reuse-first)
  - POST /v2/user-attributes            create
  - POST /v2/user-attributes/{id}/users assign a value to a member
And the Sigma RLS row-filter is fully spec-expressible (NOT UI-only): a boolean
calc column `CurrentUserAttributeText("<attr>") = [<Field>]` on the base element
plus an element `filters` entry `{kind:list, mode:include, values:[true]}`.

This script does the whole flow, REUSE-FIRST and SAFE-BY-DEFAULT:
  1. attribute   GET /v2/user-attributes → print a match if one already exists
                 (by name, case-insensitive) before creating anything.
  2. provision   --create  → POST /v2/user-attributes when nothing reusable exists.
                 --assign   → POST /v2/user-attributes/{id}/users (needs --member-id
                 + --value) to assign the attribute value to a member.
  3. apply       --field <DisplayName> (+ --element-id/--dm-id) → print the RLS
                 calc-column + element-filter spec snippet; with --apply, PATCH it
                 into the DM element's spec (GET/PUT /v2/dataModels/{id}/spec).

By default this only READS and PRINTS a plan — it mutates ONLY when you pass an
explicit --create / --assign / --apply flag. Mirrors post_dm.py: reads
$SIGMA_BASE_URL / $SIGMA_API_TOKEN from env (eval "$(scripts/get-token.sh)").
Dependency-free (stdlib only).

Live-validated: this exact flow produced exact 3-way parity (Looker-restricted ==
Sigma-restricted == warehouse: $38,906.82 / 220 rows, region=West).

Usage:
  eval "$(scripts/get-token.sh)"
  # reuse-first lookup only (default, read-only):
  python3 apply_sigma_rls.py --attr region
  # create the attribute if missing:
  python3 apply_sigma_rls.py --attr region --value West --create
  # assign a value to the querying member:
  python3 apply_sigma_rls.py --attr region --value West --member-id <id> --assign
  # print the RLS spec snippet for a DM element (plan only):
  python3 apply_sigma_rls.py --attr region --field Region --element-id <eid>
  # ...and PATCH it into the DM element spec:
  python3 apply_sigma_rls.py --attr region --field Region --element-id <eid> \
      --dm-id <dataModelId> --apply

BATCH MODE (tool-agnostic) — ingest a converter's result.security[] (architecture B:
the converter REPORTS RLS/CLS; this script provisions + applies). Handles RLS via
user attribute / team (CurrentUserInTeam) / email, and CLS (columnSecurities):
  # 1) convert + POST the model (converter injects NO RLS), capture dataModelId
  # 2) write result.security to a JSON file, then:
  python3 apply_sigma_rls.py --from-security security.json --dm-id <dmId>            # plan only
  python3 apply_sigma_rls.py --from-security security.json --dm-id <dmId> --provision --apply
Elements match by name (Sigma reassigns ids on POST); CLS columns match by normalized
name. --provision creates missing attributes/teams (assign per-user values separately).
Works for tableau/quicksight/powerbi/thoughtspot/qlik/lookml converter output alike.
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("SIGMA_BASE_URL")
TOK = os.environ.get("SIGMA_API_TOKEN")


def api(method, path, body=None):
    if not BASE or not TOK:
        sys.exit("SIGMA_BASE_URL / SIGMA_API_TOKEN unset — run: eval \"$(scripts/get-token.sh)\"")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path, data=data, method=method,
        headers={"Authorization": "Bearer " + TOK, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read().decode()
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, method, path, "->", e.read().decode()[:1000], file=sys.stderr)
        raise
    try:
        return json.loads(raw)
    except Exception:
        return raw  # spec endpoints return YAML


def _short_id(prefix="rls"):
    """A short, deterministic-enough id for a calc column / filter."""
    import hashlib
    return prefix + "-" + hashlib.md5(prefix.encode() + os.urandom(4)).hexdigest()[:8]


# --- 1. reuse-first attribute lookup --------------------------------------
def find_attribute(name):
    """Return the existing user-attribute entry matching `name` (case-insensitive), else None."""
    res = api("GET", "/v2/user-attributes?limit=200")
    entries = res.get("entries", res.get("data", [])) if isinstance(res, dict) else []
    for e in entries:
        if (e.get("name") or "").lower() == name.lower():
            return e
    return None


def list_attributes():
    res = api("GET", "/v2/user-attributes?limit=200")
    return res.get("entries", res.get("data", [])) if isinstance(res, dict) else []


# --- 3. RLS spec snippet --------------------------------------------------
def rls_spec_snippet(attr, field, element_id):
    """The verified row-filter shape: a boolean calc column + an element list filter showing only True."""
    col_id = _short_id("rlscol")
    filt_id = _short_id("rlsf")
    calc = {
        "id": col_id,
        "name": f"RLS {attr}",
        "formula": f'CurrentUserAttributeText("{attr}") = [{field}]',
    }
    filt = {
        "id": filt_id,
        "columnId": col_id,
        "kind": "list",
        "mode": "include",
        "values": [True],
    }
    return {
        "elementId": element_id,
        "calcColumn": calc,
        "filter": filt,
        "_note": (
            f'Add calcColumn to element "{element_id}" columns, and `filter` to that '
            f"element's filters[]. CurrentUserAttributeText(\"{attr}\") = [{field}] is the "
            "user-attribute mode; team mode = CurrentUserInTeam([...]); email mode = "
            "[Email] = CurrentUserEmail()."
        ),
    }


def apply_to_dm(dm_id, element_id, calc, filt):
    """PATCH the calc column + filter into the DM element's spec (GET → mutate → PUT)."""
    spec = api("GET", f"/v2/dataModels/{dm_id}/spec")
    if not isinstance(spec, dict):
        # spec endpoints can return YAML; we can't safely mutate that here.
        sys.exit("DM spec came back non-JSON (YAML) — cannot auto-PATCH; apply the snippet by hand.")
    # The spec shape nests elements under the model; search for the element by id.
    found = _inject(spec, element_id, calc, filt)
    if not found:
        sys.exit(f"element id {element_id} not found in DM {dm_id} spec — check --element-id")
    res = api("PUT", f"/v2/dataModels/{dm_id}/spec", spec)
    print("PUT /v2/dataModels/%s/spec ->" % dm_id,
          json.dumps(res)[:300] if isinstance(res, dict) else str(res)[:300])


def _inject(node, element_id, calc, filt):
    """Recursively find an element dict whose id == element_id; add calc col + filter. Returns True if injected."""
    if isinstance(node, dict):
        if node.get("id") == element_id and ("columns" in node or "kind" in node or "source" in node):
            cols = node.setdefault("columns", [])
            if not any(c.get("id") == calc["id"] for c in cols if isinstance(c, dict)):
                cols.append(calc)
            filters = node.setdefault("filters", [])
            filters.append(filt)
            return True
        for v in node.values():
            if _inject(v, element_id, calc, filt):
                return True
    elif isinstance(node, list):
        for v in node:
            if _inject(v, element_id, calc, filt):
                return True
    return False



# --- shared engine: teams, element/column resolution, CLS, batch from result.security ---
def find_team(name):
    res = api("GET", "/v2/teams?limit=500")
    entries = res.get("entries", res.get("data", [])) if isinstance(res, dict) else []
    for e in entries:
        if (e.get("name") or "").lower() == name.lower():
            return e
    return None

def ensure_team(name, do_create):
    t = find_team(name)
    if t:
        print(f"  REUSE team '{name}' (id={t.get('teamId') or t.get('id')}).")
        return t.get("teamId") or t.get("id")
    if do_create:
        res = api("POST", "/v2/teams", {"name": name})
        tid = res.get("teamId") or res.get("id") if isinstance(res, dict) else None
        print(f"  CREATED team '{name}' (id={tid}). NOTE: add members via POST /v2/teams/{tid}/members.")
        return tid
    print(f"  (plan: team '{name}' missing — pass --provision to create it, then add members.)")
    return None

def _walk_elements(node, out):
    if isinstance(node, dict):
        if node.get("id") and ("columns" in node or "kind" in node):
            out.append(node)
        for v in node.values():
            _walk_elements(v, out)
    elif isinstance(node, list):
        for v in node:
            _walk_elements(v, out)
    return out

def _resolve_element(spec, element_id, element_name):
    els = _walk_elements(spec, [])
    for e in els:
        if element_id and e.get("id") == element_id:
            return e
    for e in els:                                  # Sigma reassigns ids on POST → match by name
        if element_name and (e.get("name") == element_name):
            return e
    # last resort: a path-tail match (warehouse-table element named by table)
    for e in els:
        path = (e.get("source") or {}).get("path") or []
        if element_name and path and str(path[-1]).upper() == str(element_name).upper():
            return e
    return None

def _norm(x):
    """Normalize a column name for matching across raw/display forms (NET_PROFIT == Net Profit)."""
    return __import__("re").sub(r"[^a-z0-9]", "", (x or "").lower())

def _resolve_col_ids(element, names):
    """Map raw-or-display column names -> live column ids (formula tail or name, normalized)."""
    out = []
    re = __import__("re")
    for nm in (names or []):
        cid = None
        for c in (element.get("columns") or []):
            cand = c.get("name") or ""
            f = c.get("formula") or ""
            m = re.match(r"^\[(?:[^\]/]+/)?([^\]]+)\]$", f)
            if m:
                cand = cand or m.group(1)
                if _norm(m.group(1)) == _norm(nm): cid = c.get("id"); break
            if _norm(cand) == _norm(nm): cid = c.get("id"); break
        if cid: out.append(cid)
        else: print(f"  WARN: CLS column '{nm}' not found on element — skipped.")
    return out

def apply_from_security(dm_id, security, do_apply, do_provision):
    """Provision attrs/teams + apply RLS calc/filter and CLS for each result.security entry."""
    spec = api("GET", f"/v2/dataModels/{dm_id}/spec")
    if not isinstance(spec, dict):
        sys.exit("DM spec came back non-JSON — cannot auto-apply.")
    applied = 0
    def _elname(e): return e.get('name') or ((e.get('source') or {}).get('path') or ['?'])[-1]
    for rule in security:
        el = _resolve_element(spec, rule.get("elementId"), rule.get("elementName"))
        if not el:
            print(f"⚠ {rule.get('kind')} on element '{rule.get('elementName')}' — not found in DM {dm_id}; skipped."); continue
        if rule.get("kind") == "rls" and rule.get("rls"):
            r = rule["rls"]
            print(f"RLS → element '{_elname(el)}': {r['formula'][:80]}")
            for attr in (r.get("userAttributes") or []):
                ex = find_attribute(attr)
                if ex: print(f"  REUSE attribute '{attr}'.")
                elif do_provision:
                    api("POST", "/v2/user-attributes", {"name": attr, "defaultValue": {"val": "", "type": "string"}})
                    print(f"  CREATED attribute '{attr}'. NOTE: assign per-user values via POST /v2/user-attributes/{{id}}/users.")
                else: print(f"  (plan: attribute '{attr}' — pass --provision to create; then assign per-user values.)")
            for team in (r.get("teams") or []):
                ensure_team(team, do_provision)
            calc = {"id": _short_id("rlscol"), "name": r.get("name") or "RLS", "formula": r["formula"]}
            filt = {"id": _short_id("rlsf"), "columnId": calc["id"], "kind": "list", "mode": "include", "values": [True]}
            if do_apply:
                el.setdefault("columns", []).append(calc)
                el.setdefault("filters", []).append(filt); applied += 1
        elif rule.get("kind") == "cls" and rule.get("cls"):
            c = rule["cls"]
            ids = _resolve_col_ids(el, c.get("restrictedColumnNames"))
            print(f"CLS → element '{_elname(el)}': hide {c.get('restrictedColumnNames')}")
            if do_apply and ids:
                el.setdefault("columnSecurities", []).append({"id": _short_id("cls"), "criteria": c.get("criteria") or {"kind": "no-one-can-view"}, "restrictedColumns": ids}); applied += 1
    if do_apply and applied:
        res = api("PUT", f"/v2/dataModels/{dm_id}/spec", spec)
        print(f"PUT spec -> applied {applied} rule(s):", (json.dumps(res)[:200] if isinstance(res, dict) else str(res)[:200]))
    elif not do_apply:
        print("\n(plan only — pass --apply --dm-id <id> to PATCH these into the DM spec; --provision to create attributes/teams.)")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Apply a Looker RLS finding to Sigma (safe-by-default).")
    ap.add_argument("--attr", help="Sigma user-attribute name (e.g. region)")
    ap.add_argument("--value", help="attribute value (for --create defaultValue / --assign)")
    ap.add_argument("--description", help="description when creating the attribute")
    ap.add_argument("--member-id", help="Sigma memberId to assign the value to (with --assign)")
    ap.add_argument("--field", help="DM column display name to filter on (e.g. Region) — for the RLS snippet")
    ap.add_argument("--element-id", help="DM element id the RLS calc col + filter attach to")
    ap.add_argument("--dm-id", help="dataModelId (with --apply, to PATCH the element spec)")
    ap.add_argument("--create", action="store_true", help="create the user attribute if no reusable match")
    ap.add_argument("--assign", action="store_true", help="assign --value to --member-id")
    ap.add_argument("--apply", action="store_true", help="PATCH the RLS calc col + filter into the DM element spec")
    ap.add_argument("--from-security", help="path to a converter result.security[] JSON (batch RLS+CLS apply)")
    ap.add_argument("--provision", action="store_true", help="create missing user attributes / teams (with --from-security)")
    ap.add_argument("--print-plan", action="store_true", help="OFFLINE: parse --from-security and print the rules + attributes/teams to provision (no API, no --dm-id)")
    a = ap.parse_args()

    # Offline review: parse a security.json and print what WOULD be provisioned +
    # applied, with no API call (no token / --dm-id needed). Lets you sanity-check
    # the converter's RLS output (and is the CI-portable test entrypoint).
    if a.from_security and a.print_plan:
        raw = json.load(open(a.from_security))
        security = raw.get("security", raw) if isinstance(raw, dict) else raw
        attrs, teams, n_email = set(), set(), 0
        print(f"RLS/CLS plan from {a.from_security}: {len(security)} rule(s)")
        for r in security:
            rls = r.get("rls", {})
            for x in (rls.get("userAttributes") or []): attrs.add(x)
            for t in (rls.get("teams") or []): teams.add(t)
            if rls.get("usesCurrentUserEmail"): n_email += 1
            print(f"  • {rls.get('name') or r.get('source')} → element '{r.get('elementName')}': {rls.get('formula','')[:90]}")
        print(f"provision: {len(attrs)} user attribute(s) {sorted(attrs)}; {len(teams)} team(s) {sorted(teams)}; "
              f"{n_email} rule(s) use CurrentUserEmail (no provisioning)")
        return

    # Batch mode: ingest a converter's result.security[] and provision + apply all rules.
    if a.from_security:
        if not a.dm_id:
            sys.exit("--from-security requires --dm-id (the posted data model).")
        raw = json.load(open(a.from_security))
        security = raw.get("security", raw) if isinstance(raw, dict) else raw
        return apply_from_security(a.dm_id, security, a.apply, a.provision)

    if not a.attr:
        sys.exit("Provide --attr (single-rule mode) or --from-security <json> (batch mode).")
    # --- 1. reuse-first --------------------------------------------------
    existing = find_attribute(a.attr)
    attr_id = None
    if existing:
        attr_id = existing.get("userAttributeId") or existing.get("id")
        print(f"REUSE: user attribute '{a.attr}' already exists "
              f"(id={attr_id}, default={existing.get('defaultValue')}) — reusing, NOT creating.")
    else:
        print(f"No existing Sigma user attribute named '{a.attr}'.")
        if a.create:
            body = {"name": a.attr}
            if a.description:
                body["description"] = a.description
            if a.value is not None:
                body["defaultValue"] = {"val": a.value, "type": "string"}
            res = api("POST", "/v2/user-attributes", body)
            attr_id = res.get("userAttributeId") or res.get("id") if isinstance(res, dict) else None
            print(f"CREATED user attribute '{a.attr}' (id={attr_id}).")
        else:
            print("  (plan only — pass --create to create it.)")

    # --- 2. assign -------------------------------------------------------
    if a.assign:
        if not attr_id:
            sys.exit("--assign needs an attribute id — create/reuse it first (no id resolved).")
        if not a.member_id or a.value is None:
            sys.exit("--assign requires --member-id and --value.")
        body = {"assignments": [{"userId": a.member_id, "value": {"val": a.value, "type": "string"}}]}
        res = api("POST", f"/v2/user-attributes/{attr_id}/users", body)
        print(f"ASSIGNED '{a.attr}'={a.value} to member {a.member_id}: "
              + (json.dumps(res)[:200] if isinstance(res, dict) else str(res)[:200]))
    elif a.value is not None and a.member_id:
        print(f"  (plan: would assign '{a.attr}'={a.value} to member {a.member_id} — pass --assign.)")

    # --- 3. RLS spec snippet --------------------------------------------
    if a.field:
        if not a.element_id:
            print("\nNOTE: --field given without --element-id; printing the formula only.")
            print(f'  calc column formula: CurrentUserAttributeText("{a.attr}") = [{a.field}]')
        else:
            snip = rls_spec_snippet(a.attr, a.field, a.element_id)
            print("\nRLS spec snippet (verified shape — boolean calc col + element list filter on True):")
            print(json.dumps(snip, indent=2))
            if a.apply:
                if not a.dm_id:
                    sys.exit("--apply requires --dm-id.")
                apply_to_dm(a.dm_id, a.element_id, snip["calcColumn"], snip["filter"])
            else:
                print("  (plan only — pass --apply --dm-id <id> to PATCH it into the DM element spec.)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
