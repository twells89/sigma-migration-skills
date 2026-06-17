#!/usr/bin/env python3
"""ThoughtSpot migration-readiness assessment.

Inventories a REAL ThoughtSpot instance (models/worksheets + Liveboards +
Answers + connections + tables), pulls per-object usage from the built-in
`TS: BI Server` system worksheet (views + distinct users + per-user activity),
and for every exportable Liveboard scores migration complexity from its TML:
viz count, distinct chart kinds, models touched, plus TML formula and RLS
complexity. Produces a value/cost-style migration shortlist for a
ThoughtSpot -> Sigma migration.

This assumes a populated production instance: usage data is a FIRST-CLASS
signal, not an optional extra. If `TS: BI Server` is genuinely absent (a fresh
instance, or an identity without admin scope) the scan records a single note and
falls back to effort-only ranking — but the design and the readout are built for
the populated case.

Env: TS_HOST, TS_TOKEN.
"""
import sys, os, json, datetime
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import yaml, ts_lib

# ThoughtSpot TML uses bare `=` (e.g. `oper: =`) which PyYAML reads as the
# special value tag — treat it as a plain string.
yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value",
                                lambda loader, node: loader.construct_scalar(node))

OUT = os.path.expanduser("~/thoughtspot-migration/assessment.json")

# Chart kinds the thoughtspot-to-sigma pipeline maps to Sigma today.
# ThoughtSpot vizTypes that map to a native Sigma element kind. Sigma's chart
# universe: kpi / bar / line / area / pie / donut / scatter / combo / table /
# pivot-table / region-map / point-map / geography-map. So pivot tables, scatter
# (incl. bubble = scatter w/ size), donut, dual-axis combos, and geo area/bubble
# maps ALL convert. Only kinds with no native Sigma equivalent (treemap,
# waterfall, funnel, heat-map, sankey, histogram, radar/spider, pareto) stay
# flagged for review.
SUPPORTED = {"KPI", "COLUMN", "BAR", "STACKED_COLUMN", "STACKED_BAR", "ADVANCED_COLUMN",
             "LINE", "AREA", "STACKED_AREA", "LINE_COLUMN", "LINE_STACKED_COLUMN",
             "PIE", "DONUT", "SCATTER", "BUBBLE", "PIVOT_TABLE", "TABLE",
             "GEO_AREA", "GEO_BUBBLE"}


def _author(x):
    """Best-effort author/owner display from a metadata/search hit."""
    h = x.get("metadata_header", {}) or {}
    return (h.get("authorName") or h.get("authorDisplayName")
            or x.get("metadata_author_name") or h.get("author") or "unknown")


def liveboard_profile(lb_id, name, author):
    edoc, err = ts_lib.export_tml(lb_id, "LIVEBOARD")
    if err:
        return {"id": lb_id, "name": name, "author": author,
                "exportable": False, "note": err.split(":")[0]}
    try:
        lb = yaml.safe_load(edoc)["liveboard"]
    except Exception as e:
        return {"id": lb_id, "name": name, "author": author,
                "exportable": False, "note": f"parse: {type(e).__name__}"}
    types, models, unsupported = {}, set(), []
    n_formula = 0       # TML formulas (calculated fields) referenced
    n_filter = 0        # viz-level / liveboard filters
    for v in lb.get("visualizations", []):
        a = v.get("answer")
        if not a:
            continue
        ct = (a.get("chart") or {}).get("type") or ("TABLE" if a.get("display_mode") == "TABLE_MODE" else "?")
        types[ct] = types.get(ct, 0) + 1
        if ct not in SUPPORTED:
            unsupported.append(ct)
        for t in a.get("tables", []):
            models.add(t.get("name"))
        n_formula += len(a.get("formulas", []) or [])
        n_filter += len(a.get("filters", []) or [])
    # Liveboard-level filters (cross-viz controls)
    n_filter += len(lb.get("filters", []) or [])
    nviz = sum(types.values())
    # complexity: viz count + distinct chart kinds + #models touched + TML
    # formula weight + filter weight. Mirrors the value/cost intuition of the
    # other assessment skills (auto/manual/review classes).
    complexity = nviz + 2 * len(types) + 3 * len(models) + 2 * n_formula + n_filter
    return {"id": lb_id, "name": name, "author": author, "exportable": True,
            "viz": nviz, "chart_types": types, "models": sorted(models),
            "n_formula": n_formula, "n_filter": n_filter,
            "unsupported": sorted(set(unsupported)), "complexity": complexity}


def classify_connection(ctype):
    """Embrace (live, query pushed to the warehouse) vs Falcon (in-memory)."""
    if not ctype:
        return "unknown"
    c = str(ctype).upper()
    if "FALCON" in c or c in ("RDBMS_FALCON", "DEFAULT"):
        return "falcon"
    return "embrace"


def get_connections():
    """Connections classified Embrace (live warehouse) vs Falcon (in-memory)."""
    out = []
    for x in ts_lib.search("CONNECTION"):
        h = x.get("metadata_header", {}) or {}
        ctype = (h.get("type") or x.get("metadata_type")
                 or x.get("data_source_type") or h.get("dataSourceType"))
        out.append({"id": x.get("metadata_id"), "name": x.get("metadata_name"),
                    "author": _author(x), "connection_type": ctype,
                    "class": classify_connection(ctype)})
    return out


def get_tables():
    """Physical tables. file-uploaded (CSV/XLSX) tables flagged — they have no
    governed warehouse source and must land in a warehouse for Sigma."""
    out = []
    for x in ts_lib.search("LOGICAL_TABLE"):
        h = x.get("metadata_header", {}) or {}
        t = h.get("type")
        if t not in ("ONE_TO_ONE_LOGICAL", "SYSTEM_TABLE", "TABLE", None):
            # WORKSHEET / MODEL handled separately
            if t in ("WORKSHEET", "MODEL", "AGGR_WORKSHEET"):
                continue
        is_upload = bool(h.get("isImported") or h.get("isFileUpload")
                         or "Imported Data" in str(h.get("databaseStripe", "")))
        out.append({"id": x.get("metadata_id"), "name": x.get("metadata_name"),
                    "author": _author(x), "type": t,
                    "file_uploaded": is_upload})
    return out


def get_usage(days_query="[Timestamp].'last 12 months'"):
    """Per-object usage from the TS: BI Server system worksheet (ThoughtSpot's
    built-in usage/activity log). On a real instance with admin scope this is
    the primary value signal. Returns:
        (by_object, by_user, reason_or_None)
      by_object: {object_name: {views, users}}
      by_user:   {user: total_actions}
    """
    bi = next((x for x in ts_lib.search("LOGICAL_TABLE")
               if x.get("metadata_name") == "TS: BI Server"), None)
    if not bi:
        return {}, {}, "TS: BI Server worksheet not present (fresh instance or non-admin identity)"
    bid = bi.get("metadata_id")
    by_object, by_user = {}, {}
    try:
        # Per-Liveboard/Answer: views + distinct users
        views = ts_lib.searchdata(
            f"[Answer Book Name] count [User Action] unique count [User] "
            f"[User Action] != 'invalid' {days_query}", bid, record_size=1000)
        for row in views["data_rows"]:
            name = row[0]
            if name is None:
                continue
            by_object[name] = {"views": row[1], "users": row[2]}
    except Exception as e:
        return {}, {}, f"BI Server views query failed: {e}"
    try:
        # Per-user activity (distinct users + their action volume)
        ua = ts_lib.searchdata(
            f"[User] count [User Action] [User Action] != 'invalid' {days_query}",
            bid, record_size=1000)
        for row in ua["data_rows"]:
            u = row[0]
            if u is None:
                continue
            by_user[u] = row[1]
    except Exception:
        pass  # per-user is a bonus; views are the load-bearing signal
    reason = None if by_object else "no recorded views in window"
    return by_object, by_user, reason


def main():
    models = [x for x in ts_lib.search("LOGICAL_TABLE")
              if x.get("metadata_header", {}).get("type") in ("WORKSHEET", "MODEL")]
    lbs = ts_lib.search("LIVEBOARD")
    answers = ts_lib.search("ANSWER")
    conns = get_connections()
    tables = get_tables()

    print("=" * 64)
    print("THOUGHTSPOT MIGRATION ASSESSMENT")
    print("=" * 64)
    print(f"Inventory: {len(conns)} connection(s), {len(models)} models/worksheets, "
          f"{len(tables)} tables, {len(lbs)} Liveboards, {len(answers)} Answers\n")

    profiles = [liveboard_profile(x["metadata_id"], x["metadata_name"], _author(x))
                for x in lbs]
    exportable = [p for p in profiles if p.get("exportable")]
    locked = [p for p in profiles if not p.get("exportable")]

    # Usage (ThoughtSpot's built-in activity log) — FIRST-CLASS signal.
    usage, by_user, usage_note = get_usage()
    for p in profiles:
        u = usage.get(p["name"]) or usage.get(p["name"].replace(" (TS)", ""))
        p["views"] = (u or {}).get("views", 0)
        p["users"] = (u or {}).get("users", 0)
    total_views = sum(p.get("views", 0) for p in profiles)

    print("USAGE (TS: BI Server — interactive views, the migration value signal):")
    if total_views == 0:
        print(f"  note: {usage_note or 'no usage recorded'}\n")
    else:
        for p in sorted(profiles, key=lambda p: -p.get("views", 0))[:15]:
            if p.get("views"):
                print(f"  {p['name'][:36]:36s} {p['views']:>6} views  {p['users']:>3} users")
        print()

    print(f"Liveboards readable via API: {len(exportable)}/{len(profiles)} "
          f"({len(locked)} system/locked)\n")

    # value/cost ranking: value = interactive views, cost = complexity.
    for p in exportable:
        p["value_cost"] = round(p.get("views", 0) / (1 + p["complexity"]), 3)
    ranked = (sorted(exportable, key=lambda p: -p["value_cost"]) if total_views
              else sorted(exportable, key=lambda p: p["complexity"]))

    # tag each ranked Liveboard
    for p in ranked:
        if total_views and p.get("views", 0) == 0:
            p["tag"] = "retire"
        elif p["unsupported"]:
            p["tag"] = "needs-gap-scout"
        elif p["complexity"] < 20 and total_views:
            p["tag"] = "migrate-first"
        elif p["complexity"] < 30:
            p["tag"] = "easy-win"
        else:
            p["tag"] = "moderate"

    print("MIGRATION SHORTLIST (%s):" % ("value/cost — high-value, low-effort first"
                                         if total_views else "easiest first; rank by effort"))
    print(f"  {'Liveboard':32s} {'viz':>3s} {'kinds':>5s} {'cx':>4s} {'v/c':>6s}  chart types")
    for p in ranked:
        flag = "  ! " + ",".join(p["unsupported"]) if p["unsupported"] else ""
        print(f"  {p['name'][:32]:32s} {p['viz']:>3d} {len(p['chart_types']):>5d} {p['complexity']:>4d} "
              f"{p['value_cost']:>6} {','.join(f'{k}x{v}' for k,v in p['chart_types'].items())}{flag}")

    all_types = {}
    for p in exportable:
        for k, v in p["chart_types"].items():
            all_types[k] = all_types.get(k, 0) + v
    unsup = {k: v for k, v in all_types.items() if k not in SUPPORTED}
    total_viz = sum(all_types.values())
    cov = 100 * (total_viz - sum(unsup.values())) / total_viz if total_viz else 100
    print(f"\nChart-type coverage: {cov:.1f}%  ({total_viz} viz across exportable Liveboards)")

    models_used = sorted({m for p in exportable for m in p["models"]})
    print(f"\nModels referenced by exportable Liveboards: {len(models_used)}")

    # Duplicate / consolidation candidates — flag Liveboards that are the same
    # report rebuilt (shared model + overlapping chart set + near-identical name),
    # so the estate migrates ONCE instead of N times. Shared, tool-neutral detector.
    import importlib.util
    _dd_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dup-dashboards.py")
    _spec = importlib.util.spec_from_file_location("dup_dashboards", _dd_path)
    _dd = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_dd)
    duplicate_dashboards = _dd.detect([
        {"id": p["id"], "name": p["name"], "sources": p.get("models") or [],
         "viz": list((p.get("chart_types") or {}).keys()),
         "fields": (p.get("models") or []) + list((p.get("chart_types") or {}).keys()),
         "usage": p.get("views")} for p in profiles])
    _ds = duplicate_dashboards["summary"]
    if _ds["duplicate_groups"]:
        print(f"\nDUPLICATE/CONSOLIDATION: {_ds['duplicate_groups']} group(s) across "
              f"{_ds['dashboards_in_groups']} Liveboards — consolidating avoids "
              f"{_ds['conversions_avoided']} redundant migration(s).")

    # Ownership / concentration by author (across Liveboards).
    owners = {}
    for p in profiles:
        owners[p["author"]] = owners.get(p["author"], 0) + 1
    ownership = sorted(({"author": a, "liveboards": n} for a, n in owners.items()),
                       key=lambda o: -o["liveboards"])

    # Data-source patterns
    ds_summary = {
        "embrace": sum(1 for c in conns if c["class"] == "embrace"),
        "falcon": sum(1 for c in conns if c["class"] == "falcon"),
        "unknown": sum(1 for c in conns if c["class"] == "unknown"),
        "file_uploaded_tables": sum(1 for t in tables if t["file_uploaded"]),
        "tables_total": len(tables),
    }

    report = {
        "instance": {
            "host": ts_lib.HOST,
            "generated_at": datetime.date.today().strftime("%Y-%m-%d"),
        },
        "environment_overview": {
            "liveboards": len(lbs),
            "answers": len(answers),
            "models": len(models),
            "tables": len(tables),
            "connections": len(conns),
        },
        "profiles": profiles,
        "shortlist": ranked,
        "ownership": ownership,
        "connections": conns,
        "tables": tables,
        "datasource_summary": ds_summary,
        "usage_by_user": [{"user": u, "actions": n}
                          for u, n in sorted(by_user.items(), key=lambda kv: -kv[1])],
        "coverage": cov,
        "chart_types": all_types,
        "unsupported_chart_types": unsup,
        "models_used": models_used,
        "duplicate_dashboards": duplicate_dashboards,
        "usage_available": bool(usage),
        "usage_note": usage_note,
        "total_views": total_views,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(report, open(OUT, "w"), indent=2)
    print(f"\nFull report -> {OUT}")


if __name__ == "__main__":
    main()
