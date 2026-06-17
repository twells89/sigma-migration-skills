#!/usr/bin/env python3
"""looker-inventory — Looker instance inventory + per-dashboard migration complexity.

    python3 looker-inventory.py [--out assessment-<host>] [--usage-days 90] [--ini PATH]

Enumerates LookML models / explores / projects / connections (dialects), Looks,
dashboards (UDD vs LookML), users / groups, folders. Then opens each dashboard via
GET /dashboards/{id} to bucket vis-types and hard-to-migrate features (pivots, table
calcs, merged results, custom viz, Liquid, cross-filtering) against Sigma coverage.
Pulls per-dashboard / per-look usage and active-user counts from Looker's System
Activity model (`system__activity`) via POST /queries/run/json, then scores
value / (1 + cost) and tags each dashboard. Emits <out>/inventory.json + readout.md.

READ-ONLY: only GETs and System Activity inline queries (no app mutation, no
warehouse rows). Mirrors qlik-inventory.py / tableau-assessment's scoring + tags.

Auth from ~/.looker/looker.ini (client_credentials, API 4.0) via looker_api.py.
"""
import json, os, re, sys, argparse, math, datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import looker_api as L


# ---------------------------------------------------------------------------
# Looker vis-type -> Sigma element coverage (mirrors build_workbook.py's tile map
# in ../looker-to-sigma/scripts and the converter's known coverage).
# ---------------------------------------------------------------------------
VIZ_AUTO = {
    "single_value", "looker_single_record", "table", "looker_grid",
    "looker_column", "looker_bar", "looker_line", "looker_area",
    "looker_scatter", "looker_pie", "looker_donut_multiples", "looker_funnel",
    "looker_google_map", "text", "looker_field_text",  # text -> Sigma text element
    "looker_timeline", "looker_boxplot",
}
VIZ_MANUAL = {
    # recreate with the closest Sigma element (geo / waterfall / heatmap / sankey)
    "looker_map", "looker_geo_coordinates", "looker_geo_choropleth",
    "looker_waterfall", "looker_wordcloud", "looker_heatmap", "sankey",
}
# non-chart tile types (buttons / dividers) — not a migration cost, skipped
VIZ_SKIP = {"button", "divider", "image"}
# anything else (marketplace / custom viz extensions) -> unhandled


def bucket_viz(t):
    t = (t or "").lower()
    if t in VIZ_SKIP:
        return None
    if t in VIZ_AUTO:
        return "auto"
    if t in VIZ_MANUAL:
        return "manual"
    return "unhandled"   # marketplace / custom viz extensions


# Liquid templating in a field/filter/html string -> manual re-author
LIQUID = re.compile(r"\{\{.*?\}\}|\{%.*?%\}")


def _query_of(el):
    """The query backing an element — direct or via result_maker."""
    if el.get("query"):
        return el["query"]
    rm = el.get("result_maker") or {}
    return rm.get("query") or {}


def _vis_type(el, q):
    for src in (q.get("vis_config"),
                (el.get("result_maker") or {}).get("vis_config"),
                el.get("vis_config")):
        if isinstance(src, dict) and src.get("type"):
            return src["type"]
    return el.get("type")  # "vis" / "text"


def _dyn(df):
    """dashboard_element.query.dynamic_fields is a JSON string of table calcs."""
    if isinstance(df, str):
        try:
            return json.loads(df)
        except Exception:
            return []
    return df or []


def _has_liquid(q):
    blob = json.dumps(q)
    return bool(LIQUID.search(blob))


def scan_dashboard(did):
    """Open one dashboard, return (rolled element features, viz mix, flags)."""
    fields = ("id,title,dashboard_elements(id,type,title,merge_result_id,note_text,"
              "query(view,model,pivots,dynamic_fields,filters,vis_config),"
              "result_maker(query(view,model,pivots,dynamic_fields,filters,vis_config),"
              "merge_result_id)),dashboard_filters(name,type,dimension)")
    code, d = L.call("GET", f"/dashboards/{did}?fields={fields}")
    if code != 200 or not isinstance(d, dict):
        return None
    els = d.get("dashboard_elements") or []
    filters = d.get("dashboard_filters") or []

    viz_types = {}
    feats = {"pivots": 0, "table_calcs": 0, "merged_results": 0,
             "custom_viz": 0, "liquid": 0, "cross_filtering": 0}
    n_tiles = 0
    n_auto = n_manual = n_unhandled = 0
    sources = set()   # model::explore tokens the tiles query (the dashboard's data grain)
    fields = set()    # LookML fields referenced (filter dimensions)

    for el in els:
        etype = el.get("type")
        q = _query_of(el)
        if not q and etype in (None, "text") and not (el.get("title") or el.get("note_text")):
            continue
        m, v = q.get("model"), q.get("view")
        if m and v:
            sources.add(f"{m}::{v}")
        elif v:
            sources.add(v)
        for fl in (q.get("filters") or {}):
            fields.add(fl)
        vt = _vis_type(el, q)
        b = bucket_viz(vt)
        if b is None:   # button / divider / image — not a chart, skip entirely
            continue
        n_tiles += 1
        viz_types[vt] = viz_types.get(vt, 0) + 1

        if b == "auto":
            n_auto += 1
        elif b == "manual":
            n_manual += 1
        else:
            n_unhandled += 1
            feats["custom_viz"] += 1

        if q.get("pivots"):
            feats["pivots"] += 1
            n_manual += 1
        dyn = _dyn(q.get("dynamic_fields"))
        if dyn:
            feats["table_calcs"] += len(dyn)
            n_manual += 1
        if el.get("merge_result_id") or (el.get("result_maker") or {}).get("merge_result_id"):
            feats["merged_results"] += 1
            n_unhandled += 1
        if q and _has_liquid(q):
            feats["liquid"] += 1
            n_manual += 1

    # cross-filtering proxy: a dashboard filter that >1 tile listens on is fine,
    # but Looker's auto cross-filter (filterables linking tiles) is the manual one.
    # We approximate "has filters wired to tiles" as a normal (auto) feature and only
    # flag explicit cross_filtering when a dashboard sets it. The filter COUNT is the
    # migration signal.
    n_filters = len(filters)
    for f in filters:
        dim = f.get("dimension")
        if dim:
            fields.add(dim)

    return {
        "tiles": n_tiles, "filters": n_filters, "viz_types": viz_types,
        "features": feats, "n_auto": n_auto, "n_manual": n_manual,
        "n_unhandled": n_unhandled,
        "sources": sorted(sources), "fields": sorted(fields),
    }


# ---------------------------------------------------------------------------
# System Activity usage (the value axis)
# ---------------------------------------------------------------------------
def sa_query(view, fields, filters, sorts=None, limit="5000"):
    body = {"model": "system__activity", "view": view, "fields": fields,
            "filters": filters, "limit": limit}
    if sorts:
        body["sorts"] = sorts
    code, out = L.call("POST", "/queries/run/json", body)
    return out if (code == 200 and isinstance(out, list)) else []


def dashboard_usage(days):
    rows = sa_query("history",
                    ["dashboard.id", "dashboard.title",
                     "history.query_run_count", "history.dashboard_run_count"],
                    {"history.created_date": f"{days} days", "dashboard.id": "NOT NULL"},
                    ["history.query_run_count desc"])
    out = {}
    for r in rows:
        did = str(r.get("dashboard.id"))
        out[did] = {"queries": int(r.get("history.query_run_count") or 0),
                    "runs": int(r.get("history.dashboard_run_count") or 0)}
    return out


def look_usage(days):
    rows = sa_query("history",
                    ["look.id", "look.title", "history.query_run_count"],
                    {"history.created_date": f"{days} days", "look.id": "NOT NULL"},
                    ["history.query_run_count desc"])
    return {str(r.get("look.id")): int(r.get("history.query_run_count") or 0) for r in rows}


def activity_totals(days):
    rows = sa_query("history",
                    ["user.count", "history.query_run_count", "history.dashboard_run_count"],
                    {"history.created_date": f"{days} days"}, None, "1")
    if not rows:
        return {"active_users": 0, "queries": 0, "dashboard_runs": 0}
    r = rows[0]
    return {"active_users": int(r.get("user.count") or 0),
            "queries": int(r.get("history.query_run_count") or 0),
            "dashboard_runs": int(r.get("history.dashboard_run_count") or 0)}


# ---------------------------------------------------------------------------
# Scoring (identical framework to tableau-assessment / qlik-assessment)
# ---------------------------------------------------------------------------
def score(runs, queries, n_auto, n_hint, n_manual, n_unhandled, tiles):
    cost = 10 * n_unhandled + 3 * n_manual + 1 * n_hint
    # value: dashboard runs weighted by query volume; proxy on tiles when cold
    value = (runs * math.sqrt(max(queries, 1))) if (runs or queries) else 5 * tiles
    return cost, round(value / (1 + cost), 2)


def tag(runs, queries, sc, n_manual, n_unhandled):
    if not runs and not queries:
        return "retire"
    if n_unhandled >= 1:
        return "needs-gap-scout"
    if sc >= 20 and (n_manual + n_unhandled) == 0:
        return "migrate-first"
    if sc >= 10:
        return "easy-win"
    return "moderate"


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    ap.add_argument("--usage-days", type=int, default=90)
    ap.add_argument("--ini")
    ap.add_argument("--no-deep", action="store_true",
                    help="skip per-dashboard complexity scan (counts + usage only)")
    a = ap.parse_args()
    if a.ini:
        L.INI = os.path.expanduser(a.ini)

    # host / out dir
    base, _, _, _ = L._cfg()
    host = re.sub(r"^https?://", "", base).split(":")[0].split("/")[0]
    out = a.out or f"assessment-{host}"
    os.makedirs(out, exist_ok=True)

    # ---- environment counts ----
    def glist(path):
        code, o = L.call("GET", path)
        return o if (code == 200 and isinstance(o, list)) else []

    models = glist("/lookml_models")
    projects = glist("/projects")
    connections = glist("/connections")
    looks = glist("/looks?fields=id,title,user_id,deleted")
    folders = glist("/folders")
    groups = glist("/groups?fields=id,name")
    users = glist("/users?fields=id,display_name,email,is_disabled")

    # explores rolled up from models
    n_explores = sum(len(m.get("explores") or []) for m in models)
    dialects = {}
    for c in connections:
        dn = (c.get("dialect") or {}).get("name") or "unknown"
        dialects[dn] = dialects.get(dn, 0) + 1

    # ---- dashboards (UDD vs LookML kind) ----
    dash = glist("/dashboards?fields=id,title,user_id,folder(name),deleted,hidden")
    n_udd = sum(1 for d in dash if "::" not in str(d.get("id")))
    n_lookml = len(dash) - n_udd

    # ---- usage (System Activity) ----
    days = a.usage_days
    du = dashboard_usage(days)
    lu = look_usage(days)
    totals = activity_totals(days)

    # ---- per-dashboard shortlist ----
    user_name = {str(u.get("id")): (u.get("display_name") or u.get("email") or "?")
                 for u in users}
    rows = []
    for d in dash:
        did = str(d.get("id"))
        kind = "LookML" if "::" in did else "UDD"
        u = du.get(did, {"queries": 0, "runs": 0})
        row = {
            "id": did, "name": d.get("title"), "kind": kind,
            "folder": (d.get("folder") or {}).get("name"),
            "owner": user_name.get(str(d.get("user_id")), "(unknown)"),
            "runs": u["runs"], "queries": u["queries"],
            "tiles": 0, "filters": 0, "viz_types": {}, "features": {},
            "n_auto": 0, "n_hint": 0, "n_manual": 0, "n_unhandled": 0,
            "sources": [], "fields": [],
        }
        if not a.no_deep:
            sc = scan_dashboard(did)
            if sc:
                row.update({k: sc[k] for k in
                            ("tiles", "filters", "viz_types", "features",
                             "n_auto", "n_manual", "n_unhandled",
                             "sources", "fields")})
        c, s = score(row["runs"], row["queries"], row["n_auto"], row["n_hint"],
                     row["n_manual"], row["n_unhandled"], row["tiles"])
        row["cost"], row["score"] = c, s
        row["tag"] = tag(row["runs"], row["queries"], s, row["n_manual"], row["n_unhandled"])
        rows.append(row)
    rows.sort(key=lambda r: r["score"], reverse=True)

    # ---- ownership rollup ----
    own = {}
    for r in rows:
        o = r.get("owner") or "(unknown)"
        d = own.setdefault(o, {"owner": o, "dashboards": 0, "runs": 0, "tiles": 0})
        d["dashboards"] += 1
        d["runs"] += int(r.get("runs") or 0)
        d["tiles"] += int(r.get("tiles") or 0)
    ownership = sorted(own.values(), key=lambda d: -d["dashboards"])

    # ---- feature rollup across all scanned dashboards ----
    feat_totals = {"pivots": 0, "table_calcs": 0, "merged_results": 0,
                   "custom_viz": 0, "liquid": 0, "cross_filtering": 0}
    viz_totals = {}
    for r in rows:
        for k, v in (r.get("features") or {}).items():
            feat_totals[k] = feat_totals.get(k, 0) + int(v)
        for k, v in (r.get("viz_types") or {}).items():
            viz_totals[k] = viz_totals.get(k, 0) + int(v)

    # ---- duplicate / consolidation candidates ----
    # Shared, tool-neutral detector: flags dashboards that look like the same
    # report rebuilt (shared explore + overlapping fields/viz + near-identical
    # name) so the estate migrates ONCE instead of N times. Only signals actually
    # captured are passed — never fabricated (sources/fields/viz are empty under
    # --no-deep, so the detector falls back to name+usage and stays conservative).
    import importlib.util
    _dd_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dup-dashboards.py")
    _spec = importlib.util.spec_from_file_location("dup_dashboards", _dd_path)
    _dd = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_dd)
    duplicate_dashboards = _dd.detect([
        {"id": r["id"], "name": r["name"],
         "sources": r.get("sources") or [],
         "fields": r.get("fields") or [],
         "viz": list((r.get("viz_types") or {}).keys()),
         "usage": (r.get("runs") or 0) or None}
        for r in rows])

    inv = {
        "instance": {
            "name": host,
            "url": f"https://{host}",
            "generated_at": datetime.date.today().isoformat(),
            "usage_window_days": days,
            "mode": "rest-4.0 inventory-only" if a.no_deep else "rest-4.0 + deep",
        },
        "environment_overview": {
            "models": len(models),
            "explores": n_explores,
            "projects": len(projects),
            "connections": len(connections),
            "looks": len(looks),
            "dashboards": len(dash),
            "dashboards_udd": n_udd,
            "dashboards_lookml": n_lookml,
            "users": len([u for u in users if not u.get("is_disabled")]) or len(users),
            "groups": len(groups),
            "folders": len(folders),
        },
        "connections": {
            "n_connections": len(connections),
            "dialects": [{"dialect": k, "n": v}
                         for k, v in sorted(dialects.items(), key=lambda kv: -kv[1])],
            "detail": [{"name": c.get("name"),
                        "dialect": (c.get("dialect") or {}).get("name"),
                        "database": c.get("database"), "host": c.get("host")}
                       for c in connections],
        },
        "activity": {
            "active_users": totals["active_users"],
            "queries": totals["queries"],
            "dashboard_runs": totals["dashboard_runs"],
            "looks_used": len(lu),
            "look_usage": [{"id": k, "queries": v}
                           for k, v in sorted(lu.items(), key=lambda kv: -kv[1])][:25],
        },
        "feature_usage": feat_totals,
        "viz_mix": [{"type": k, "n": v}
                    for k, v in sorted(viz_totals.items(), key=lambda kv: -kv[1])],
        "ownership": ownership,
        "duplicate_dashboards": duplicate_dashboards,
        "shortlist": rows,
        # back-compat top-level counts
        "dashboards": len(dash), "models": len(models),
    }
    json.dump(inv, open(os.path.join(out, "inventory.json"), "w"), indent=2)

    # compact markdown
    md = [f"# Looker → Sigma assessment — {host}\n",
          f"- **Models:** {len(models)} · **Explores:** {n_explores} · "
          f"**Dashboards:** {len(dash)} ({n_udd} UDD / {n_lookml} LookML) · "
          f"**Looks:** {len(looks)} · **Connections:** {len(connections)}\n",
          f"- **Usage window:** last {days} days · "
          f"**Active users:** {totals['active_users']} · "
          f"**Dashboard runs:** {totals['dashboard_runs']}\n",
          "\n## Migration shortlist\n",
          "| # | Dashboard | Kind | Runs | Tiles | Tag | Score | auto/manual/unhandled |",
          "|--:|---|---|--:|--:|---|--:|---|"]
    for i, r in enumerate(rows, 1):
        md.append(f"| {i} | {r['name']} | {r['kind']} | {r['runs']} | {r['tiles']} | "
                  f"**{r['tag']}** | {r['score']} | "
                  f"{r['n_auto']}/{r['n_manual']}/{r['n_unhandled']} |")
    md.append("\n" + _dd.render_md(duplicate_dashboards))
    open(os.path.join(out, "readout.md"), "w").write("\n".join(md) + "\n")

    _ds = duplicate_dashboards["summary"]
    print(f"dashboards={len(dash)} ({n_udd} UDD/{n_lookml} LookML) models={len(models)} "
          f"explores={n_explores} connections={len(connections)} "
          f"active_users={totals['active_users']} "
          f"dup_groups={_ds['duplicate_groups']}(avoid {_ds['conversions_avoided']}) "
          f"-> {out}/inventory.json + readout.md"
          + ("  (run without --no-deep for per-dashboard complexity)" if a.no_deep else ""))


if __name__ == "__main__":
    main()
