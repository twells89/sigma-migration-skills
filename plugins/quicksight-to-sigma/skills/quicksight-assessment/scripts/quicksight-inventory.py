#!/usr/bin/env python3
"""Phase 1-3 inventory extractor for the quicksight-assessment skill.

READ-ONLY. Surveys an Amazon QuickSight account (what the configured AWS
credentials can reach) and writes raw JSON the Ruby renderers consume:

  <out>/inventory.json          — environment + per-analysis + per-dataset metadata
  <out>/raw-defs/<id>.json      — describe-analysis-definition response per analysis
  <out>/raw-datasets/<id>.json  — describe-data-set response per referenced dataset

Auth is whatever the AWS CLI is already configured with: a named --profile, SSO
(`aws sso login`), or gimme-aws-creds (Okta orgs). We shell out to `aws
quicksight ...` via subprocess — NO boto3 dependency.

Enterprise edition is REQUIRED: the describe-*-definition / describe-data-set
calls are Enterprise-only. On a Standard account they 4xx; we record that and
degrade gracefully (the analysis still inventories from list-* metadata, but
without visual/calc-field complexity).

QuickSight's identity region is often us-east-1 even when the data lives
elsewhere — pass --region accordingly.

Usage:
  python3 scripts/quicksight-inventory.py --account-id <ID> --region us-east-1 \
      --profile <p> --out /tmp/qs-assessment-<acct>
  ... [--limit-analyses N]  [--dashboards-too]
"""
import argparse, json, os, re, subprocess, sys, time


def aws(args, acct, region, profile):
    """Run an aws quicksight subcommand; return (ok, parsed_json_or_errtext)."""
    cmd = ["aws", "quicksight"] + args + [
        "--aws-account-id", acct, "--region", region, "--output", "json"]
    if profile:
        cmd += ["--profile", profile]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        return False, (p.stderr.strip() or "aws call failed: " + " ".join(args[:2]))
    try:
        return True, json.loads(p.stdout)
    except Exception:
        return True, {}


def arn_id(arn):
    return arn.rsplit("/", 1)[-1] if arn else None


# ---------------------------------------------------------------------------
# Complexity classification
# ---------------------------------------------------------------------------

# Visuals the workbook builder reproduces vs. not. From refs/migration-test-slate.md.
VISUAL_BUILT = {"KPIVisual", "BarChartVisual", "LineChartVisual", "PieChartVisual"}
VISUAL_MID = {  # in the catalog but not built — manual rebuild
    "ComboChartVisual", "TableVisual", "PivotTableVisual", "ScatterPlotVisual",
    "HeatMapVisual", "GaugeChartVisual", "FunnelChartVisual", "TreeMapVisual",
    "HistogramVisual", "BoxPlotVisual", "WaterfallVisual", "RadarChartVisual",
}
VISUAL_UNHANDLED = {  # no Sigma equivalent / best-effort only
    "SankeyDiagramVisual", "WordCloudVisual", "GeospatialMapVisual",
    "FilledMapVisual", "LayerMapVisual", "InsightVisual",
    "CustomContentVisual", "PluginVisual",
}

# QuickSight calc-field functions that have no clean Sigma formula equivalent —
# the converter degrades these to a /* TODO */ placeholder. From the test slate.
WINDOW_FUNCS = [
    "sumOver", "avgOver", "countOver", "maxOver", "minOver", "runningSum",
    "runningAvg", "runningCount", "runningMax", "runningMin", "rank",
    "denseRank", "percentOfTotal", "percentileOver", "periodOverPeriodDifference",
    "periodOverPeriodPercentDifference", "periodToDateSum", "periodToDateAvg",
    "lag", "lead", "windowSum", "windowAvg", "windowCount", "windowMax",
    "windowMin", "firstValue", "lastValue", "difference",
]
WINDOW_RE = re.compile(r"\b(" + "|".join(WINDOW_FUNCS) + r")\s*\(")
FUNC_RE = re.compile(r"\b([a-zA-Z][a-zA-Z0-9]*)\s*\(")


def classify_calc(expr):
    """Return 'a' (mechanical) | 'b' (restructure) | 'c' (no-equiv window/table-calc)."""
    if not expr:
        return "a"
    if WINDOW_RE.search(expr):
        return "c"
    # ifelse/switch nesting or aggregation-of-aggregation hints at restructuring;
    # otherwise a direct rewrite.
    funcs = set(f.lower() for f in FUNC_RE.findall(expr))
    if {"percentiledisc", "percentilecont", "medianif", "distinctcountif"} & funcs:
        return "b"
    return "a"


def analyze_definition(defn):
    """Walk an AnalysisDefinition: visual-kind histogram, calc-field buckets, params,
    sheet/layout shape. Returns a complexity-signal dict."""
    out = {
        "sheet_count": 0,
        "visual_count": 0,
        "visual_kinds": {},
        "visuals_built": 0,
        "visuals_mid": 0,
        "visuals_unhandled": 0,
        "calc_field_count": 0,
        "calc_buckets": {"a": 0, "b": 0, "c": 0},
        "window_calc_count": 0,
        "parameter_count": 0,
        "filter_group_count": 0,
        "free_form_sheets": 0,
        "section_based_sheets": 0,
        "dataset_identifiers": [],
    }
    for sh in defn.get("Sheets", []):
        out["sheet_count"] += 1
        for v in sh.get("Visuals", []):
            for vtype in v.keys():
                out["visual_count"] += 1
                out["visual_kinds"][vtype] = out["visual_kinds"].get(vtype, 0) + 1
                if vtype in VISUAL_BUILT:
                    out["visuals_built"] += 1
                elif vtype in VISUAL_UNHANDLED:
                    out["visuals_unhandled"] += 1
                elif vtype in VISUAL_MID:
                    out["visuals_mid"] += 1
                else:
                    out["visuals_mid"] += 1  # EmptyVisual/unknown → treat as mid
        # layout shape per sheet
        for lay in sh.get("Layouts", []):
            cfg = lay.get("Configuration", {}) or {}
            if "FreeFormLayout" in cfg:
                out["free_form_sheets"] += 1
            if "SectionBasedLayout" in cfg:
                out["section_based_sheets"] += 1
    for c in defn.get("CalculatedFields", []):
        out["calc_field_count"] += 1
        bucket = classify_calc(c.get("Expression"))
        out["calc_buckets"][bucket] += 1
        if bucket == "c":
            out["window_calc_count"] += 1
    out["parameter_count"] = len(defn.get("ParameterDeclarations", []))
    out["filter_group_count"] = len(defn.get("FilterGroups", []))
    out["dataset_identifiers"] = [
        d.get("Identifier") for d in defn.get("DataSetIdentifierDeclarations", [])]
    return out


def analyze_dataset(dso):
    """Source type(s), import mode, RLS/CLS presence, custom-sql usage."""
    out = {
        "import_mode": dso.get("ImportMode"),
        "physical_kinds": [],
        "has_custom_sql": False,
        "has_joins": False,
        "transform_count": 0,
        "rls_enabled": bool(dso.get("RowLevelPermissionDataSet")),
        "cls_enabled": bool(dso.get("ColumnLevelPermissionRules")),
        "column_count": len(dso.get("OutputColumns", []) or []),
    }
    for ptv in (dso.get("PhysicalTableMap") or {}).values():
        for kind in ptv.keys():
            out["physical_kinds"].append(kind)
            if kind == "CustomSql":
                out["has_custom_sql"] = True
    for ltv in (dso.get("LogicalTableMap") or {}).values():
        src = ltv.get("Source", {}) or {}
        if "JoinInstruction" in src:
            out["has_joins"] = True
        out["transform_count"] += len(ltv.get("DataTransforms", []) or [])
    out["physical_kinds"] = sorted(set(out["physical_kinds"]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--account-id", required=True)
    ap.add_argument("--region", default="us-east-1",
                    help="QuickSight identity region (often us-east-1)")
    ap.add_argument("--profile")
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit-analyses", type=int, default=0, help="cap analyses scanned (0=all)")
    ap.add_argument("--dashboards-too", action="store_true",
                    help="also list dashboards (counts only; conversion targets analyses)")
    args = ap.parse_args()

    acct, region, profile = args.account_id, args.region, args.profile
    out = os.path.expanduser(args.out)
    os.makedirs(os.path.join(out, "raw-defs"), exist_ok=True)
    os.makedirs(os.path.join(out, "raw-datasets"), exist_ok=True)

    inv = {
        "account": {
            "account_id": acct, "region": region,
            "generated_at": time.strftime("%Y-%m-%d"),
            "edition": None, "enterprise": None,
        },
        "analyses": [],
        "datasets": [],
        "data_sources": [],
        "environment_overview": {
            "analyses": 0, "dashboards": 0, "datasets": 0, "data_sources": 0,
        },
    }

    # --- list analyses ------------------------------------------------------
    ok, res = aws(["list-analyses"], acct, region, profile)
    if not ok:
        print(f"[list-analyses] FAILED: {res}", file=sys.stderr)
        sys.exit(3)
    analyses = [a for a in res.get("AnalysisSummaryList", [])
                if a.get("Status") != "DELETED"]
    inv["environment_overview"]["analyses"] = len(analyses)

    # --- list datasets (catalog; describe per referenced dataset later) -----
    ok, res = aws(["list-data-sets"], acct, region, profile)
    ds_summaries = res.get("DataSetSummaries", []) if ok else []
    inv["environment_overview"]["datasets"] = len(ds_summaries)

    ok, res = aws(["list-data-sources"], acct, region, profile)
    src_summaries = res.get("DataSources", []) if ok else []
    inv["environment_overview"]["data_sources"] = len(src_summaries)
    for s in src_summaries:
        inv["data_sources"].append({
            "id": arn_id(s.get("Arn")), "name": s.get("Name"), "type": s.get("Type")})

    if args.dashboards_too:
        ok, res = aws(["list-dashboards"], acct, region, profile)
        inv["environment_overview"]["dashboards"] = len(res.get("DashboardSummaryList", [])) if ok else 0

    # --- describe each analysis definition (Enterprise-only) ----------------
    seen_datasets = {}
    edition_flagged = False
    scanned = 0
    for a in analyses:
        if args.limit_analyses and scanned >= args.limit_analyses:
            break
        aid, aname = a.get("AnalysisId"), a.get("Name")
        print(f"[analysis] {aname}", file=sys.stderr)
        entry = {"id": aid, "name": aname,
                 "last_updated": a.get("LastUpdatedTime")}
        ok, d = aws(["describe-analysis-definition", "--analysis-id", aid],
                    acct, region, profile)
        if not ok:
            entry["def_error"] = str(d)[:200]
            # First definition failure usually means Standard edition / no perms.
            if not edition_flagged and re.search(
                    r"Standard|Enterprise|not supported|AccessDenied", str(d), re.I):
                inv["account"]["enterprise"] = False
                inv["account"]["edition"] = "Standard? (definition API rejected)"
                edition_flagged = True
            inv["analyses"].append(entry)
            scanned += 1
            continue
        inv["account"]["enterprise"] = True
        inv["account"]["edition"] = "Enterprise"
        defn = d.get("Definition", {}) or {}
        with open(os.path.join(out, "raw-defs", f"{aid}.json"), "w") as fh:
            json.dump(d, fh, indent=2)
        entry.update(analyze_definition(defn))

        # describe each referenced dataset once
        for decl in defn.get("DataSetIdentifierDeclarations", []):
            ds_id = arn_id(decl.get("DataSetArn"))
            if not ds_id or ds_id in seen_datasets:
                continue
            ok2, ds = aws(["describe-data-set", "--data-set-id", ds_id],
                          acct, region, profile)
            if not ok2:
                seen_datasets[ds_id] = {"id": ds_id, "ds_error": str(ds)[:160]}
                continue
            dso = ds.get("DataSet", {}) or {}
            with open(os.path.join(out, "raw-datasets", f"{ds_id}.json"), "w") as fh:
                json.dump(ds, fh, indent=2)
            seen_datasets[ds_id] = dict(
                {"id": ds_id, "name": dso.get("Name")}, **analyze_dataset(dso))
        entry["dataset_ids"] = [arn_id(decl.get("DataSetArn"))
                                for decl in defn.get("DataSetIdentifierDeclarations", [])]
        inv["analyses"].append(entry)
        scanned += 1

    inv["datasets"] = list(seen_datasets.values())

    # --- duplicate / consolidation candidates -------------------------------
    # Flag analyses that are the same report rebuilt (shared dataset + overlapping
    # visual set + near-identical name) so the estate migrates ONCE instead of N
    # times. Shared, tool-neutral detector (the hyphenated filename blocks a normal
    # import). Only signals actually captured by the inventory are passed —
    # QuickSight inventory has dataset references + visual kinds, but no per-analysis
    # column refs and no view counts on this surface, so `fields` reuses the
    # source/viz proxy and `usage` is omitted.
    import importlib.util
    _dd_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dup-dashboards.py")
    _spec = importlib.util.spec_from_file_location("dup_dashboards", _dd_path)
    _dd = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_dd)

    def _ds_name(ds_id):
        return (seen_datasets.get(ds_id) or {}).get("name") or ds_id

    normalized = []
    for a in inv["analyses"]:
        sources = [_ds_name(i) for i in (a.get("dataset_ids") or []) if i]
        viz = list((a.get("visual_kinds") or {}).keys())
        normalized.append({
            "id": a["id"], "name": a["name"],
            "sources": sources,
            "viz": viz,
            "fields": sources + viz,
        })
    inv["duplicate_dashboards"] = _dd.detect(normalized)
    with open(os.path.join(out, "dup-normalized.json"), "w") as fh:
        json.dump(normalized, fh, indent=2)

    with open(os.path.join(out, "inventory.json"), "w") as fh:
        json.dump(inv, fh, indent=2)

    eo = inv["environment_overview"]
    print(f"\nWROTE {os.path.join(out, 'inventory.json')}", file=sys.stderr)
    print(f"  analyses={eo['analyses']} dashboards={eo['dashboards']} "
          f"datasets={eo['datasets']} data_sources={eo['data_sources']}", file=sys.stderr)
    print(f"  edition={inv['account']['edition']}  analyses scanned for definition: {scanned}",
          file=sys.stderr)
    _ds = inv["duplicate_dashboards"]["summary"]
    print(f"  duplicate/consolidation: {_ds['duplicate_groups']} group(s) across "
          f"{_ds['dashboards_in_groups']} analyses ({_ds['conversions_avoided']} avoidable)",
          file=sys.stderr)
    if inv["account"]["enterprise"] is False:
        print("  WARNING: definition API rejected — this looks like a Standard-edition "
              "account; complexity is unavailable (counts only).", file=sys.stderr)


if __name__ == "__main__":
    main()
