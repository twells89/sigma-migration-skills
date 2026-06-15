#!/usr/bin/env python3
"""Generalized ThoughtSpot → Sigma migration — works on ANY model, no baked ids.

  python3 migrate.py --model <TS_MODEL_ID> [--liveboard <ID> ...] [--name PREFIX] \
                     [--workdir DIR] [--converted FILE]

Steps: export the model's TML → convert to a Sigma data model → POST it →
discover the denormalized "<root> View" element → build a column resolver from
the model TML → for each Liveboard that reads the model, rebuild its
visualizations as a Sigma workbook off that element → apply the Liveboard's own
tile geometry (layout.tiles) as the Sigma grid layout.

Converter paths (in priority order):
  1. --converted <file>   JSON output of the `convert_thoughtspot_to_sigma`
                          MCP tool (or a bare Sigma DM spec) — continues the
                          pipeline without any local converter build.
  2. CONVERTER_PATH       one-shot: a local sigma-data-model-mcp
                          build/thoughtspot.js, run via convert_model.mjs.
  3. neither              MCP fallback: writes <workdir>/model.tml +
                          <workdir>/convert-request.json and prints the exact
                          mcp__sigma-data-model__convert_thoughtspot_to_sigma
                          call to make; save the tool's JSON output and re-run
                          with --converted <file>. Exits 3 (not an error).

Offline mode: --model-tml FILE and --liveboard-tml FILE (repeatable) read TML
from disk instead of the live ThoughtSpot API — see fixtures/ for a real
exported pair. No TS_HOST/TS_TOKEN needed.

Env:
  TS_HOST, TS_TOKEN                         ThoughtSpot (live mode only)
  SIGMA_BASE_URL, SIGMA_API_TOKEN           Sigma
  SIGMA_CONNECTION_ID                       warehouse connection in Sigma
  SIGMA_FOLDER_ID                           destination folder
  TS_DB, TS_SCHEMA                          warehouse db/schema for the model's tables
  TS_WORKDIR                                default for --workdir (else ./ts-migration)
"""
import argparse, json, os, re, ssl, subprocess, sys, time, urllib.request, urllib.error
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import yaml, ts_common, apply_layouts
yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", lambda l, n: l.construct_scalar(n))

HERE = os.path.dirname(os.path.abspath(__file__))
_SSL = ssl._create_unverified_context()
MCP_TOOL = "mcp__sigma-data-model__convert_thoughtspot_to_sigma"

def need_env(*names):
    missing = [n for n in names if not os.environ.get(n)]
    if missing:
        sys.exit("missing env: " + ", ".join(missing))
    return [os.environ[n] for n in names]

def sigma(method, path, body=None):
    base, tok = need_env("SIGMA_BASE_URL", "SIGMA_API_TOKEN")
    r = urllib.request.Request(base + path, data=(json.dumps(body).encode() if body else None),
        method=method, headers={"Authorization": "Bearer " + tok, "Accept": "application/json",
        **({"Content-Type": "application/json"} if body else {})})
    try:
        return urllib.request.urlopen(r, context=_SSL).read().decode()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Sigma {method} {path} -> {e.code}: {e.read().decode()[:300]}")

def resolve_workdir(arg):
    wd = arg or os.environ.get("TS_WORKDIR") or os.path.join(os.getcwd(), "ts-migration")
    wd = os.path.abspath(os.path.expanduser(wd))
    os.makedirs(wd, exist_ok=True)
    return wd

def convert_model(model_tml, wd, converted_path):
    """Return the converter output dict {model, stats?, warnings?} via one of the
    three converter paths (see module docstring). Exits 3 on the MCP-fallback
    pass-1 (request emitted, awaiting --converted)."""
    if converted_path:                                   # path 1: MCP tool output
        conv = json.load(open(converted_path))
        if "sigmaDataModel" in conv:                     # MCP tool wraps under sigmaDataModel
            conv = {**conv, "model": conv["sigmaDataModel"]}
        elif "model" not in conv:                        # bare DM spec → wrap
            conv = {"model": conv, "stats": {}, "warnings": []}
        return conv
    if os.environ.get("CONVERTER_PATH"):                 # path 2: local one-shot
        tml_path = os.path.join(wd, "model.tml")
        open(tml_path, "w").write(model_tml)
        out = subprocess.run(["node", os.path.join(HERE, "convert_model.mjs"), tml_path],
                             capture_output=True, text=True, env=dict(os.environ))
        if out.returncode:
            raise RuntimeError("convert failed: " + out.stderr[-300:])
        return json.loads(out.stdout)
    # path 3: MCP fallback — emit the exact conversion request and stop.
    tml_path = os.path.join(wd, "model.tml")
    open(tml_path, "w").write(model_tml)
    req = {"tool": MCP_TOOL,
           "arguments": {"tml_yaml": model_tml,
                         "connection_id": os.environ.get("SIGMA_CONNECTION_ID", ""),
                         "database": os.environ.get("TS_DB", ""),
                         "schema": os.environ.get("TS_SCHEMA", "")}}
    req_path = os.path.join(wd, "convert-request.json")
    json.dump(req, open(req_path, "w"), indent=2)
    print(f"""
No local converter build (CONVERTER_PATH unset) — use the MCP converter:

  1. Call the `{MCP_TOOL}` MCP tool with the arguments in
       {req_path}
     (tml_yaml = contents of {tml_path},
      connection_id = $SIGMA_CONNECTION_ID, database = $TS_DB, schema = $TS_SCHEMA).
  2. Save the tool's JSON output (the {{sigmaDataModel, stats, warnings}} object,
     or just the model spec) to {wd}/converted.json
  3. Re-run this command with:  --converted {wd}/converted.json
""")
    sys.exit(3)

def find_denorm(dm):
    """Read a DM's spec back and locate the denormalized "<root> View" element.
    Returns (denormElemId, denormName)."""
    dmspec = yaml.safe_load(sigma("GET", f"/v2/dataModels/{dm}/spec"))
    els = dmspec["pages"][0]["elements"]
    denorm = next((el for el in els if (el.get("name") or "").endswith(" View")), None)
    if not denorm:
        # no joins → no denormalized view; use the base fact element (most columns).
        denorm = max(els, key=lambda e: len(e.get("columns", [])))
    return denorm["id"], denorm["name"]

def find_table_elements(dm):
    """Map the DM's raw warehouse-table elements: {TABLE_NAME: {id, name}}.
    Used to source dimension-grain measures at their owning table's grain
    (chasm-trap guard) instead of the fanned-out denorm view."""
    dmspec = yaml.safe_load(sigma("GET", f"/v2/dataModels/{dm}/spec"))
    out = {}
    for el in dmspec["pages"][0]["elements"]:
        src = el.get("source") or {}
        if src.get("kind") == "warehouse-table" and src.get("path"):
            out[src["path"][-1]] = {"id": el["id"], "name": el.get("name") or src["path"][-1]}
    return out


def build_dm(conv, name, folder):
    """POST the converted Sigma data model. Returns (dmId, denormElemId, denormName)."""
    spec = conv["model"]; spec["name"] = name
    res = json.loads(sigma("POST", "/v2/dataModels/spec", {"folderId": folder, **spec}))
    dm = res["dataModelId"]
    # discover the denormalized "<root> View" element from the posted DM spec
    denorm_id, denorm_name = find_denorm(dm)
    stats = conv.get("stats") or {}
    print(f"  DM {dm}  ·  denorm '{denorm_name}' ({denorm_id})  ·  "
          f"{stats.get('relationships', '?')} rels, {stats.get('elements', '?')} elements")
    return dm, denorm_id, denorm_name

def post_workbook(spec, wd):
    resp = sigma("POST", "/v2/workbooks/spec", spec)
    m = re.search(r'workbookId["\s:]+([0-9a-f-]{36})', resp)
    if not m:
        raise RuntimeError("workbook POST: " + resp[:300])
    wb = m.group(1)
    with open(os.path.join(wd, "posted-workbooks.jsonl"), "a") as f:
        f.write(json.dumps({"id": wb, "name": spec.get("name")}) + "\n")
    return wb

def lb_tiles(lb, viz_specs, elements):
    """Map the Liveboard's layout.tiles (ThoughtSpot 12-col grid) to the built
    Sigma elements, in viz order. Returns None when geometry is incomplete
    (apply_layouts falls back to its auto grid)."""
    by_viz = {t.get("visualization_id"): t for t in ((lb.get("layout") or {}).get("tiles") or [])}
    tiles = []
    for (viz_id, _), el in zip(viz_specs, elements):
        t = by_viz.get(viz_id)
        if not t:
            return None
        tiles.append({"element_id": el["id"], "x": t.get("x", 0), "y": t.get("y", 0),
                      "width": t.get("width", 6), "height": t.get("height", 6)})
    return tiles or None

def migrate_liveboard(lb_doc, dm, denorm_id, denorm_name, resolver, prefix, fallback_name, folder, wd):
    lb = yaml.safe_load(lb_doc)["liveboard"]
    display = lb.get("name") or fallback_name          # never name a workbook after a UUID
    viz_specs = [(v.get("id"), ps) for v in lb["visualizations"] if (ps := ts_common.parse_ts_viz(v, resolver))]
    specs = [ps for _, ps in viz_specs]
    master = ts_common.master_element(specs, resolver, dm, denorm_id, denorm_name)
    elements = [ts_common.sigma_element(s, resolver) for s in specs]
    # Hidden grouped scatter-source tables must live on the SAME page as the
    # m-ofv master they source (visibleAsSource:False → no layout slot needed).
    data_elems = [master] + ts_common.drain_scatter_sources()
    spec = {"name": f"{prefix}{display} (from ThoughtSpot)", "folderId": folder, "schemaVersion": 1,
            "pages": [{"id": "p-data", "name": "Data", "elements": data_elems},
                      {"id": "p-main", "name": display[:40], "elements": elements}]}
    wb = post_workbook(spec, wd)
    tiles = lb_tiles(lb, viz_specs, elements)
    apply_layouts.apply(wb, tiles=tiles)
    return wb, display, len(specs), tiles

def collect_liveboards(a, model_name):
    """Liveboard candidate selection + TML export — runs as a LANE concurrent
    with convert + DM POST (main joins it before workbook builds). Estate-scale
    behavior (an org with 40+ liveboards must not cost 40+ serial exports):

      1. explicit --liveboard ids       → cached parallel export of exactly those
      2. dependency API                 → ts_lib.dependents(model): the server
         names the liveboards that READ this model; only those are exported
         (parallel, disk-cached). VERIFIED LIVE 2026-06-11.
      3. fallback (PATCH POINT)         → when dependents() returns None (older
         TS builds with no dependent_objects in metadata/search), fall back to
         export-ALL-then-grep — still parallel + cached, but O(org-size). If
         you hit this on a customer estate, verify their TS version's
         dependency endpoint and extend ts_lib.dependents() accordingly.

    Returns [(edoc, fallback_name)]."""
    import ts_lib
    log = lambda m: print("  " + m.lstrip())
    if a.liveboard:
        heads = {h["id"]: h for h in ts_lib.search_headers("LIVEBOARD")}
        items = [heads.get(i) or {"id": i, "name": i, "modified": None} for i in a.liveboard]
    else:
        deps = ts_lib.dependents(a.model)
        org = ts_lib.search_headers("LIVEBOARD")
        if deps is None:
            # ── PATCH POINT: dependency API unusable on this TS build ──
            log(f"dependency API unavailable — falling back to export-all-then-grep "
                f"({len(org)} liveboard(s) in org; parallel + cached)")
            out = []
            for it, edoc, err in ts_lib.export_tml_many(org, log=log):
                if not err and edoc and model_name in edoc:
                    out.append((edoc, it.get("name") or it["id"]))
            return out
        log(f"dependency API: {len(deps)} liveboard(s) read this model "
            f"(org has {len(org)} — exporting candidates only)")
        items = deps
    out = []
    for it, edoc, err in ts_lib.export_tml_many(items, log=log):
        if err:
            log(f"✗ liveboard {it['id']}: export failed: {err}")
            continue
        out.append((edoc, it.get("name") or it["id"]))
    return out


def migrate_answer(ans_id, dm, denorm_id, denorm_name, resolver, prefix, folder, wd):
    """A standalone Answer is a single viz — build a one-element workbook."""
    import ts_lib
    edoc, err = ts_lib.export_tml(ans_id, "ANSWER")
    if err:
        raise RuntimeError("export failed: " + err)
    ans = yaml.safe_load(edoc)["answer"]
    display = ans.get("name") or ("Answer " + ans_id[:8])
    spec_v = ts_common.parse_ts_viz({"answer": ans}, resolver)
    master = ts_common.master_element([spec_v], resolver, dm, denorm_id, denorm_name)
    main_el = ts_common.sigma_element(spec_v, resolver)
    data_elems = [master] + ts_common.drain_scatter_sources()  # park any hidden scatter source by the master
    spec = {"name": f"{prefix}{display} (from ThoughtSpot)", "folderId": folder, "schemaVersion": 1,
            "pages": [{"id": "p-data", "name": "Data", "elements": data_elems},
                      {"id": "p-main", "name": display[:40], "elements": [main_el]}]}
    wb = post_workbook(spec, wd)
    apply_layouts.apply(wb)
    return wb, display

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", help="ThoughtSpot model (LOGICAL_TABLE) id")
    ap.add_argument("--model-tml", help="offline: read the model TML from a file (see fixtures/)")
    ap.add_argument("--liveboard", action="append", help="specific Liveboard id(s); default = all that read the model")
    ap.add_argument("--liveboard-tml", action="append", help="offline: read Liveboard TML from file(s)")
    ap.add_argument("--answer", action="append", help="standalone Answer id(s) to migrate as one-element workbooks")
    ap.add_argument("--name", default=None, help="name PREFIX applied to BOTH the data model and every workbook")
    ap.add_argument("--workdir", default=None, help="working dir for artifacts (default $TS_WORKDIR or ./ts-migration)")
    ap.add_argument("--converted", default=None, help="JSON output of the convert_thoughtspot_to_sigma MCP tool")
    ap.add_argument("--reuse-dm", default=None, help="existing Sigma dataModelId to reuse — skips convert + POST "
                    "(decided via ts-dm-signature.py + find-or-pick-dm.rb; see SKILL.md step 2.5)")
    a = ap.parse_args()
    wd = resolve_workdir(a.workdir)
    offline = bool(a.model_tml)
    if not a.model and not a.model_tml:
        ap.error("--model or --model-tml required")

    if offline:
        model_tml = open(a.model_tml).read()
    else:
        import ts_lib
        model_tml, err = ts_lib.export_tml(a.model, "LOGICAL_TABLE")
        if err:
            sys.exit("model export failed: " + err)
    open(os.path.join(wd, "model.tml"), "w").write(model_tml)   # always persist (parity/freshness consume it)
    root = yaml.safe_load(model_tml)
    root = root.get("model") or root.get("worksheet") or root
    model_name = root.get("name", "Migrated Model")
    prefix = (a.name.strip() + " ") if a.name else ""
    resolver = ts_common.build_resolver(root)
    print(f"Model '{model_name}': {len(resolver)} resolvable columns  ·  workdir {wd}")

    folder = need_env("SIGMA_FOLDER_ID")[0]

    # ── Liveboard selection + TML export LANE: starts BEFORE convert + DM POST
    #    and runs concurrent with them (pure TS-side reads vs pure Sigma-side
    #    writes — no shared state). Joined right before the workbook builds.
    #    On the MCP-fallback exit(3) path the lane still completes before the
    #    process exits (non-daemon thread), so its exports land in the TML
    #    disk cache and the --converted resume run gets all cache hits.
    lb_lane = None
    if not (offline or a.liveboard_tml):
        from concurrent.futures import ThreadPoolExecutor
        t_lane = time.time()
        lb_lane = ThreadPoolExecutor(max_workers=1).submit(collect_liveboards, a, model_name)

    if a.reuse_dm:
        dm = a.reuse_dm
        denorm_id, denorm_name = find_denorm(dm)
        print(f"  REUSING DM {dm}  ·  denorm '{denorm_name}' ({denorm_id})  — convert + POST skipped")
    else:
        conv = convert_model(model_tml, wd, a.converted)
        dm, denorm_id, denorm_name = build_dm(conv, f"{prefix}{model_name} (from ThoughtSpot)", folder)

    # chasm-trap guard inputs: the DM's raw table elements, for dimension-grain
    # measures that must NOT be aggregated over the fanned-out denorm view
    resolver["__dm_id__"] = dm
    try:
        resolver["__dim_elements__"] = find_table_elements(dm)
    except Exception as ex:
        print(f"  WARN: could not map DM table elements ({ex}) — dim-grain measures will use the denorm view")
        resolver["__dim_elements__"] = {}

    # pick Liveboards: offline TML files, or join the export lane
    targets = []                                       # (lb_doc, fallback_name)
    if a.liveboard_tml:
        targets = [(open(p).read(), os.path.basename(p)) for p in a.liveboard_tml]
    elif lb_lane:
        targets = lb_lane.result()
        print(f"  Liveboard TML lane: {len(targets)} ready in {time.time() - t_lane:.1f}s "
              f"(ran concurrent with convert + DM POST)")
    print(f"Migrating {len(targets)} Liveboard(s)…")

    # persist each Liveboard TML so downstream phases (parity expected-side,
    # freshness probe) can re-derive viz specs without re-exporting from TS
    lbdir = os.path.join(wd, "liveboards")
    os.makedirs(lbdir, exist_ok=True)
    results = {}
    for i, (lb_doc, fallback) in enumerate(targets):
        lb_path = os.path.join(lbdir, f"lb-{i + 1}.tml")
        open(lb_path, "w").write(lb_doc)
        try:
            wb, display, n, tiles = migrate_liveboard(lb_doc, dm, denorm_id, denorm_name,
                                                      resolver, prefix, fallback, folder, wd)
            results[display] = {"workbook": wb, "viz": n, "tiles": tiles, "lb_tml": lb_path}
            print(f"  ✓ {display[:34]:34s} WB {wb} ({n} viz, layout={'TML tiles' if tiles else 'auto grid'})")
        except Exception as ex:
            results[fallback] = {"error": str(ex), "lb_tml": lb_path}
            print(f"  ✗ {fallback[:34]:34s} {ex}")
    for ans_id in (a.answer or []):
        try:
            wb, display = migrate_answer(ans_id, dm, denorm_id, denorm_name, resolver, prefix, folder, wd)
            results[display] = {"answer": ans_id, "workbook": wb}
            print(f"  ✓ answer {display[:26]:26s} WB {wb}")
        except Exception as ex:
            results["answer:" + ans_id] = {"error": str(ex)}
            print(f"  ✗ answer {ans_id[:8]}  {ex}")
    wbs = [r["workbook"] for r in results.values() if r.get("workbook")]
    json.dump({"model": a.model or a.model_tml, "modelName": model_name, "dataModel": dm,
               "dmReused": bool(a.reuse_dm), "denormElementId": denorm_id,
               "denormName": denorm_name, "results": results},
              open(os.path.join(wd, "migrate_out.json"), "w"), indent=2)
    if len(wbs) == 1:        # convenience for the parity gate (assert-phase6-ran.rb)
        json.dump({"workbookId": wbs[0]}, open(os.path.join(wd, "wb-ids.json"), "w"))
    print(f"\nDM: {dm}  ·  {len(wbs)}/{len(targets)} workbooks  ·  manifest {wd}/migrate_out.json")

if __name__ == "__main__":
    main()
