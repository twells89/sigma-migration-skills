#!/usr/bin/env python3
"""scout-validate — gap-scout validation primitive (ThoughtSpot → Sigma).

Validates a candidate Sigma formula against a real data-model element by building a
throwaway test workbook, checking the column resolves (type != "error"), and — on
success — persisting the rule to the customer-local learned-rules.yaml. Generic across
skills via --home.

    python3 scout-validate.py \
      --formula 'DateAdd("day", 7, [Order Fact/Order Date])' \
      --data-model-id <dm> --element-id <denorm-elem-id> --folder-id <folder> \
      --feature 'add_days' --pattern '\\badd_days\\s*\\(\\s*(.+?)\\s*,\\s*(.+?)\\s*\\)' \
      --template 'DateAdd("day", \\2, [\\1])' --hint 'date arithmetic' \
      --description 'TML add_days -> Sigma DateAdd' --home ~/.thoughtspot-to-sigma

To feed the run-each-time gap-scout gate (bead beads-sigma-5l5e), also pass the
error column's gate id and the conversion working dir — the result is appended to
<workdir>/scout-ledger.jsonl so migrate.py's type=error readback gate sees the gap
as scouted (validated → ok; error → escalated):

      --gap-id 'errcol:<elementId>/<label>' --workdir <wd>

Env: SIGMA_BASE_URL plus a valid bearer, browser-login keychain session, or
SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET fallback.
Prints JSON: {status: validated|error, workbook_id, error, ...}. Cleans up the test workbook.
"""
import json, os, sys, argparse, datetime, re, hashlib
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import scout_gate
import code_rep
import sigma_rest

def api(method, path, body=None, accept_json=True):
    try:
        raw = sigma_rest.request(
            method.lower(),
            path,
            body=json.dumps(body) if body is not None else None,
            accept="application/json" if accept_json else "*/*",
            binary=True,
        )
        return 200, raw.decode()
    except sigma_rest.SigmaError as exc:
        detail = str(exc)
        match = re.search(r" -> (\d+)[^\n]*\n?(.*)", detail, re.DOTALL)
        if not match:
            raise
        return int(match.group(1)), match.group(2)

def dm_element_master_columns(dm_id, el_id):
    """Read the DM spec, find the element, return (elementName, [displayName,...])."""
    st, body = api("GET", f"/v2/dataModels/{dm_id}/spec")
    if st != 200:
        raise sigma_rest.SigmaError(f"GET data model spec failed ({st}): {body}")
    spec = json.loads(body)
    for pg in spec.get("pages", []):
        for el in pg.get("elements", []):
            if el.get("id") == el_id:
                src = el.get("source", {})
                name = el.get("name") or ("Custom SQL" if src.get("kind")=="sql"
                       else (src.get("path",["Element"])[-1] if src.get("kind")=="warehouse-table" else "Element"))
                cols = []
                for c in el.get("columns", []):
                    dn = c.get("name") or re.sub(r'.*/', '', c.get("formula","").strip("[]"))
                    cols.append(dn)
                return name, cols
    raise SystemExit("element not found in DM spec")

def build_escalation(a, err):
    """Record the gap locally and return opt-in escalate-gap.py commands.

    Filing a tracking issue is NOT automatic: the main agent runs dry_run_cmd
    (drafts the issue + dedupes against open issues/beads), shows the user, and
    runs file_cmd only if they accept. Source-formula gaps are converter gaps."""
    import shlex
    skill = (a.skill or os.path.basename(os.path.normpath(a.home)).lstrip("."))
    esc_dir = os.path.join(a.home, "escalations"); os.makedirs(esc_dir, exist_ok=True)
    slug = re.sub(r"[^a-z0-9]+", "-", a.feature.lower()).strip("-") or "gap"
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    esc_path = os.path.join(esc_dir, f"{ts}-{slug}.yaml")
    payload = {"feature": a.feature, "description": a.description,
               "source_pattern": a.pattern, "sigma_template_attempted": a.template,
               "test_formula": a.formula, "example_from": a.example_from,
               "error_column": err, "escalated_at": ts}
    try:
        import yaml; yaml.safe_dump(payload, open(esc_path, "w"), sort_keys=False)
    except Exception:
        json.dump(payload, open(esc_path, "w"), indent=2)
    filer = os.path.join(os.path.dirname(os.path.abspath(__file__)), "escalate-gap.py")
    cmd = [sys.executable, filer, "--skill", skill, "--category", "converter",
           "--feature", a.feature, "--description", a.description or "",
           "--source-pattern", a.pattern or "", "--template-attempted", a.template or "",
           "--test-formula", a.formula, "--sigma-response", json.dumps(err)[:1500],
           "--example-from", a.example_from or "", "--escalation-yaml", esc_path]
    dry = " ".join(shlex.quote(c) for c in cmd)
    return {"note": "Gap recorded locally. Filing a tracking issue is opt-in — run "
                    "dry_run_cmd, show the user, then file_cmd only if they accept.",
            "escalation_yaml": esc_path, "dry_run_cmd": dry, "file_cmd": dry + " --yes"}


def main():
    ap = argparse.ArgumentParser()
    for f in ["formula","data-model-id","element-id","feature"]:
        ap.add_argument("--"+f, required=True)
    ap.add_argument("--folder-id", required=True)
    ap.add_argument("--pattern"); ap.add_argument("--template")
    ap.add_argument("--hint", default=""); ap.add_argument("--description", default="")
    ap.add_argument("--example-from", default="")
    ap.add_argument("--kind", default="kpi-chart", choices=["kpi-chart","table"])
    ap.add_argument("--home", default=os.path.expanduser("~/.thoughtspot-to-sigma"))
    ap.add_argument("--skill", default="", help="skill name for issue routing (default: derived from --home)")
    ap.add_argument("--gap-id", default="", help="gap-report row this scout addressed (gate ledger; e.g. errcol:<elementId>/<label>)")
    ap.add_argument("--workdir", default="", help="conversion working dir; ledger written here")
    a = ap.parse_args()

    elem_name, cols = dm_element_master_columns(a.data_model_id, a.element_id)
    master = {"id":"m","name":"Master","kind":"table",
              "source":{"dataModelId":a.data_model_id,"elementId":a.element_id,"kind":"data-model"},
              "columns":[{"id":f"mc{i}","name":c,"formula":f"[{elem_name}/{c}]"} for i,c in enumerate(cols)]}
    if a.kind == "kpi-chart":
        test = {"id":"scout","kind":"kpi-chart","name":"scout","source":{"elementId":"m","kind":"table"},
                "columns":[{"id":"sc","formula":a.formula,"name":"scout_test"}],"value":{"columnId":"sc"}}
    else:
        test = {"id":"scout","kind":"table","name":"scout","source":{"elementId":"m","kind":"table"},
                "columns":[{"id":"sc","formula":a.formula,"name":"scout_test"}]}
    doc = {
        "schemaVersion": 1,
        "kind": "workbook",
        "pages": [{"id": "d", "name": "Data", "visibility": "hidden"},
                  {"id": "t", "name": "Test"}],
        "elements": [master, test],
        "layout": (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
            'gridTemplateRows="auto" id="d">\n'
            '  <Element elementId="m" gridColumn="1 / 25" gridRow="1 / 21"/>\n'
            '</Page>\n'
            '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
            'gridTemplateRows="auto" id="t">\n'
            '  <Element elementId="scout" gridColumn="1 / 25" gridRow="1 / 12"/>\n'
            '</Page>\n'
        ),
    }
    # Live POST /v2/workbooks/spec now REJECTS the old flat body with a 400
    # (verified 2026-08-03/04) — every non-metadata field must nest under a
    # top-level `document` key. code_rep.wrap keeps the metadata (name,
    # folderId) alongside it.
    spec = code_rep.wrap(doc, {"name":f"SCOUT TEST {a.feature}","folderId":a.folder_id})
    st, body = api("POST","/v2/workbooks/spec",spec)
    wb = None
    try: wb = json.loads(body).get("workbookId")
    except Exception: pass
    if not wb:
        m = re.search(r'workbookId:\s*(\S+)', body)
        if m: wb = m.group(1)
    result = {"feature":a.feature,"formula":a.formula,"workbook_id":wb}
    if not wb:
        print(json.dumps({**result,"status":"error","error":"POST failed: "+body[:200]})); return
    # check the test column's type
    st2, cbody = api("GET", f"/v2/workbooks/{wb}/elements/scout/columns")
    err = None
    try:
        colsout = json.loads(cbody)
        entries = colsout.get("entries", colsout) if isinstance(colsout, dict) else colsout
        for c in (entries or []):
            t = (c.get("type") or {})
            if (t.get("type") or t) == "error" or "error" in str(t).lower():
                err = c
    except Exception as e:
        err = {"parse": str(e), "raw": cbody[:200]}
    status = "error" if err else "validated"
    # persist on success
    if status == "validated":
        if a.pattern and a.template:
            os.makedirs(a.home, exist_ok=True)
            import yaml
            rp = os.path.join(a.home, "learned-rules.yaml")
            doc = yaml.safe_load(open(rp)) if os.path.exists(rp) else None
            doc = doc or {"rules":[]}
            doc["rules"].append({"feature":a.feature,"description":a.description,
                "source_pattern":a.pattern,"sigma_template":a.template,"hint":a.hint,
                "validated_at":datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "validated_workbook":wb,"example_from":a.example_from,"confidence":"validated"})
            yaml.safe_dump(doc, open(rp,"w"), sort_keys=False)
            result["persisted_to"] = rp
    else:
        # opt-in escalation: record the gap locally + hand back ready-to-run filer cmds
        result["error_column"] = err
        result["escalation"] = build_escalation(a, err)
    # cleanup test workbook
    api("DELETE", f"/v2/files/{wb}")
    # record to the run-each-time gap-scout ledger (bead beads-sigma-5l5e) so the
    # migrate.py type=error readback gate sees this gap as scouted. A 'validated'
    # row MUST carry live-probe evidence (issue #458): the real Sigma workbook id
    # this POST created + a SHA-256 of the live columns-readback + the probe
    # timestamp. scout_gate signs the row (per-conversion .scout-ledger.key) so the
    # gate (migrate.py -> scout_gate.classify) honors ONLY a signed, evidenced
    # 'validated'; a hand-written line cannot forge this probe.
    evidence = None
    if status == "validated":
        evidence = {
            "workbook_id": str(wb or ""),
            "response_sha256": hashlib.sha256((cbody or "").encode("utf-8")).hexdigest(),
            "phase": "columns",
            "probed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
    scout_gate.record(a.workdir, a.gap_id, a.feature,
                      "validated" if status == "validated" else "escalated", evidence)
    print(json.dumps({**result,"status":status}, indent=2))

if __name__ == "__main__":
    main()
