#!/usr/bin/env python3
"""Phase 1 discovery for quicksight-to-sigma.

Pulls a QuickSight analysis (or dashboard) definition + its datasets + data sources
and writes a normalized signals.json the convert + workbook phases consume.

FAST DISCOVERY (customer scale: 20-40 dashboard estates sharing datasets):
  * in-process boto3 client when available (one session for the whole run)
    instead of one `aws` CLI subprocess per call (0.4-0.6s interpreter startup
    tax EACH — a 1-analysis/2-dataset/1-source discovery paid it 4-5x, an
    estate re-paid it per dashboard). Falls back to the aws CLI automatically
    when boto3 isn't installed (same call shapes; boto3 is NOT a hard dep).
  * estate-level dataset cache (/tmp/qs-estate-cache/<acct>__<region>/) keyed
    DataSetArn + LastUpdatedTime: shared datasets are described ONCE per
    estate, not once per dashboard. Freshness is validated against ONE
    list-data-sets call per process; any LastUpdatedTime mismatch re-describes.
  * data sources are described once, LAZILY (first dashboard that needs one
    pays; the rest read the cache — sources change far less often than sets).
  * batch mode (--analysis-ids a,b,c --pool 4): per-analysis discovery runs
    4-8 wide; each analysis lands in <out-dir>/<id>/ with its own signals.json.
  * timings.json (per-call wall clock) is ALWAYS written to --out-dir.

Enterprise edition required for the *-definition calls (Standard edition rejects them).
QuickSight's identity region (often us-east-1) is where the resources live — pass --region accordingly.

Usage (single analysis — unchanged interface):
  python3 scripts/quicksight-discover.py \
    --account-id 153722385948 --region us-east-1 --profile pivot \
    --analysis-id orders-overview --out-dir ~/quicksight-migration/orders-overview

Batch (estate) mode:
  python3 scripts/quicksight-discover.py \
    --account-id ... --region ... --analysis-ids id1,id2,id3 --pool 4 \
    --out-dir /tmp/qs-estate

Offline / fixture mode (no AWS account or CLI needed):
  python3 scripts/quicksight-discover.py \
    --from-fixtures plugins/.../fixtures --out-dir /tmp/qs-orders

Cache controls: --no-cache bypasses the estate cache entirely; --refresh-cache
forces re-describe (and rewrites the cache). QS_ESTATE_CACHE overrides the root.
QS_FORCE_CLI=1 forces the aws-CLI transport even when boto3 is importable.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

CACHE_ROOT = os.environ.get("QS_ESTATE_CACHE", "/tmp/qs-estate-cache")
MAX_POOL = 8  # batch fan-out cap


def _jsonable(o):
    """boto3 responses carry datetime objects; the CLI emits ISO strings.
    Normalize so cached/written JSON is transport-independent."""
    if isinstance(o, dict):
        return {k: _jsonable(v) for k, v in o.items() if k != "ResponseMetadata"}
    if isinstance(o, list):
        return [_jsonable(v) for v in o]
    if isinstance(o, (datetime.datetime, datetime.date)):
        return o.isoformat()
    return o


class Timings:
    """Per-call wall-clock evidence trail; ALWAYS written (timings.json)."""

    def __init__(self):
        self._t0 = time.monotonic()
        self._lock = threading.Lock()
        self.tasks = []

    def record(self, name, seconds, **extra):
        with self._lock:
            self.tasks.append({"task": name, "seconds": round(seconds, 3), **extra})

    def write(self, path, **meta):
        body = {"totalSeconds": round(time.monotonic() - self._t0, 2),
                "tasks": self.tasks, **meta}
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        json.dump(body, open(path, "w"), indent=2)
        return body


class QSApi:
    """One QuickSight transport for the whole run.

    boto3 (in-process, one session) when importable; aws CLI subprocess
    otherwise. Both paths take/return the same shapes: ops are CLI-style
    ("describe-data-set"), params are boto-style PascalCase kwargs
    ({"DataSetId": ...}); AwsAccountId is injected automatically."""

    def __init__(self, acct, region, profile=None, timings=None, force_cli=None):
        self.acct, self.region, self.profile = acct, region, profile
        self.timings = timings
        self.boto = None
        if force_cli is None:
            force_cli = os.environ.get("QS_FORCE_CLI", "") not in ("", "0")
        if not force_cli:
            try:
                import boto3  # optional — NOT a hard dependency
                session = boto3.Session(profile_name=profile, region_name=region)
                self.boto = session.client("quicksight")
            except Exception:  # noqa: BLE001 — any failure -> CLI fallback
                self.boto = None

    @property
    def transport(self):
        return "boto3" if self.boto is not None else "aws-cli"

    @staticmethod
    def _kebab(name):
        return re.sub(r"(?<!^)(?=[A-Z])", "-", name).lower()

    def call(self, op, **params):
        t = time.monotonic()
        try:
            if self.boto is not None:
                fn = getattr(self.boto, op.replace("-", "_"))
                return _jsonable(fn(AwsAccountId=self.acct, **params))
            cmd = ["aws", "quicksight", op, "--aws-account-id", self.acct,
                   "--region", self.region, "--output", "json"]
            for k, v in params.items():
                cmd += [f"--{self._kebab(k)}", str(v)]
            if self.profile:
                cmd += ["--profile", self.profile]
            p = subprocess.run(cmd, capture_output=True, text=True)
            if p.returncode != 0:
                raise RuntimeError(p.stderr.strip() or f"aws call failed: {op}")
            return json.loads(p.stdout)
        finally:
            if self.timings:
                self.timings.record(f"{op}", time.monotonic() - t, transport=self.transport)


class EstateCache:
    """Estate-level dataset/datasource describe cache.

    Datasets are keyed DataSetArn + LastUpdatedTime: cached entries are valid
    only while the estate's list-data-sets summary (fetched ONCE per process)
    reports the same LastUpdatedTime. Data sources are cached without a
    freshness probe (described once, lazily — they change rarely); use
    --refresh-cache to force. Thread-safe for batch mode."""

    def __init__(self, api, enabled=True, refresh=False):
        self.api = api
        self.enabled = enabled
        self.refresh = refresh
        self.dir = os.path.join(CACHE_ROOT, f"{api.acct}__{api.region}")
        self._lock = threading.Lock()
        self._listing = None  # DataSetArn -> LastUpdatedTime (one call per process)
        self._mem = {}        # in-process memo: "kind/id" -> describe response
        self._inflight = {}   # single-flight per key (batch threads share one describe)

    def _listing_map(self):
        with self._lock:
            if self._listing is None:
                out, token = {}, None
                while True:
                    params = {"NextToken": token} if token else {}
                    try:
                        r = self.api.call("list-data-sets", **params)
                    except Exception:  # listing denied -> cache validates by presence only
                        self._listing = {}
                        return self._listing
                    for s in r.get("DataSetSummaries", []):
                        out[s.get("Arn")] = str(s.get("LastUpdatedTime") or "")
                    token = r.get("NextToken")
                    if not token:
                        break
                self._listing = out
            return self._listing

    def _path(self, kind, rid):
        return os.path.join(self.dir, kind, rid + ".json")

    def _read(self, kind, rid):
        try:
            return json.load(open(self._path(kind, rid)))
        except (OSError, ValueError):
            return None

    def _write(self, kind, rid, body):
        try:
            os.makedirs(os.path.dirname(self._path(kind, rid)), exist_ok=True)
            json.dump(body, open(self._path(kind, rid), "w"), indent=2)
        except OSError:
            pass  # cache is best-effort

    def _key_lock(self, key):
        with self._lock:
            return self._inflight.setdefault(key, threading.Lock())

    def dataset(self, ds_id):
        key = f"datasets/{ds_id}"
        with self._key_lock(key):  # single-flight: batch threads share one describe
            with self._lock:
                if key in self._mem:
                    return self._mem[key], "memo"
            how = "describe"
            ds = None
            if self.enabled and not self.refresh:
                cached = self._read("datasets", ds_id)
                if cached:
                    arn = cached.get("DataSet", {}).get("Arn")
                    cached_lut = str(cached.get("DataSet", {}).get("LastUpdatedTime") or "")
                    live_lut = self._listing_map().get(arn)
                    # valid when the estate listing reports the same LastUpdatedTime
                    # (listing unavailable/empty -> treat presence as a miss, not a hit)
                    if live_lut is not None and live_lut == cached_lut:
                        ds, how = cached, "cache"
            if ds is None:
                ds = self.api.call("describe-data-set", DataSetId=ds_id)
                if self.enabled:
                    self._write("datasets", ds_id, ds)
            with self._lock:
                self._mem[key] = ds
            return ds, how

    def datasource(self, src_id):
        key = f"datasources/{src_id}"
        with self._key_lock(key):  # single-flight
            with self._lock:
                if key in self._mem:
                    return self._mem[key], "memo"
            how = "describe"
            s = None
            if self.enabled and not self.refresh:
                cached = self._read("datasources", src_id)
                if cached:
                    s, how = cached, "cache"
            if s is None:
                s = self.api.call("describe-data-source", DataSourceId=src_id)
                if self.enabled:
                    self._write("datasources", src_id, s)
            with self._lock:
                self._mem[key] = s
            return s, how


def arn_id(arn):
    return arn.rsplit("/", 1)[-1]


def field_columns(inner):
    """Shallow-walk a visual's ChartConfiguration collecting referenced ColumnNames."""
    cols = []
    def walk(o):
        if isinstance(o, dict):
            col = o.get("Column")
            if isinstance(col, dict) and "ColumnName" in col:
                cols.append(col["ColumnName"])
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(inner.get("ChartConfiguration", {}))
    # dedupe, preserve order
    seen, out = set(), []
    for c in cols:
        if c not in seen:
            seen.add(c); out.append(c)
    return out


def visual_reference_lines(inner):
    """ChartConfiguration.ReferenceLines[] -> a compact signal list (A-gap).
    Captures axis binding + static value / dynamic aggregation + label so the
    builder can emit Sigma refMarks faithfully."""
    cc = inner.get("ChartConfiguration", {}) or {}
    out = []
    for rl in (cc.get("ReferenceLines") or []):
        if str(rl.get("Status", "")).upper() == "DISABLED":
            continue
        dc = rl.get("DataConfiguration", {}) or {}
        axis = "x" if "XAXIS" in str(dc.get("AxisBinding", "")).upper() else "y"
        rec = {"axis": axis,
               "label": (rl.get("LabelConfiguration", {})
                         .get("CustomLabelConfiguration", {}) or {}).get("CustomLabel"),
               "color": (rl.get("StyleConfiguration", {}) or {}).get("Color")}
        sc = dc.get("StaticConfiguration") or {}
        dyn = dc.get("DynamicConfiguration") or {}
        if sc.get("Value") is not None:
            rec["value"] = sc["Value"]
        elif dyn:
            rec["dynamicColumn"] = (dyn.get("Column", {}) or {}).get("ColumnName") \
                or (dyn.get("MeasureAggregationFunction", {}).get("Column", {}) or {}).get("ColumnName")
            rec["aggregation"] = (dyn.get("Calculation", {}) or {}).get("SimpleNumericalAggregation") \
                or (dyn.get("MeasureAggregationFunction", {}) or {}).get("SimpleNumericalAggregation")
        out.append(rec)
    return out


def visual_color(inner):
    """Chart color encoding (B-gap). by-dimension = a Colors well holding a
    categorical field; by-measure = a ColorScale gradient (Colors[] stops)."""
    cc = inner.get("ChartConfiguration", {}) or {}
    wells = cc.get("FieldWells", {}) or {}
    agg = next((v for v in wells.values() if isinstance(v, dict)), wells)
    color_fields = agg.get("Colors") or []
    for f in color_fields:
        if isinstance(f, dict) and ("CategoricalDimensionField" in f or "DateDimensionField" in f):
            cdf = f.get("CategoricalDimensionField") or f.get("DateDimensionField") or {}
            return {"by": "dimension", "column": (cdf.get("Column", {}) or {}).get("ColumnName")}
    cs = agg.get("ColorScale") or cc.get("ColorScale")
    if isinstance(cs, dict):
        stops = [s.get("Color") if isinstance(s, dict) else s for s in (cs.get("Colors") or [])]
        return {"by": "measure", "scheme": [c for c in stops if c]}
    return None


def sheet_controls(sh):
    """QuickSight sheet FilterControls + ParameterControls (C-gap). Each becomes
    a Sigma list control; the builder resolves the target column through the
    analysis FilterGroups (FilterControl.SourceFilterId)."""
    out = []
    for kind, wraps in (("filter", sh.get("FilterControls") or []),
                        ("parameter", sh.get("ParameterControls") or [])):
        for w in wraps:
            if not isinstance(w, dict):
                continue
            wtype, body = next(iter(w.items()), (None, {}))
            body = body or {}
            out.append({"kind": kind, "controlType": wtype,
                        "controlId": body.get("FilterControlId") or body.get("ParameterControlId"),
                        "title": body.get("Title"),
                        "sourceFilterId": body.get("SourceFilterId"),
                        "sourceParameterName": body.get("SourceParameterName")})
    return out


def filter_group_columns(defn):
    """FilterId -> filtered ColumnName across the analysis FilterGroups, so a
    FilterControl's SourceFilterId resolves to the column the control drives."""
    out = {}
    for fg in (defn.get("FilterGroups") or []):
        for flt in (fg.get("Filters") or []):
            if not isinstance(flt, dict):
                continue
            body = next(iter(flt.values()), {}) or {}
            fid = body.get("FilterId")
            col = (body.get("Column", {}) or {}).get("ColumnName") or body.get("ColumnName")
            if fid and col:
                out[fid] = col
    return out


def load_fixtures(fdir):
    """Read describe-shaped JSONs from a dir: one analysis/dashboard definition
    (top-level "Definition") + one or more datasets (top-level "DataSet")."""
    analysis, datasets = None, []
    for fn in sorted(os.listdir(fdir)):
        if not fn.endswith(".json"):
            continue
        try:
            j = json.load(open(os.path.join(fdir, fn)))
        except (ValueError, OSError):
            continue
        if isinstance(j, dict) and "Definition" in j:
            analysis = j
        elif isinstance(j, dict) and "DataSet" in j:
            datasets.append(j)
    if analysis is None:
        sys.exit(f"--from-fixtures: no analysis/dashboard definition JSON (top-level 'Definition') in {fdir}")
    return analysis, datasets


def discover_one(out, cache, fixture_dir=None, analysis_id=None, dashboard_id=None,
                 log=print):
    """One analysis/dashboard -> analysis.json + datasets/ + datasources/ +
    signals.json under `out`. Shared `cache` makes repeated datasets free."""
    os.makedirs(os.path.join(out, "datasets"), exist_ok=True)
    os.makedirs(os.path.join(out, "datasources"), exist_ok=True)
    offline = bool(fixture_dir)

    fixture_ds = []
    # 1. the analysis / dashboard definition
    if offline:
        d, fixture_ds = load_fixtures(os.path.expanduser(fixture_dir))
        src_kind = "dashboard" if d.get("DashboardId") else "analysis"
        src_id = d.get("AnalysisId") or d.get("DashboardId") or "fixture"
    elif analysis_id:
        d = cache.api.call("describe-analysis-definition", AnalysisId=analysis_id)
        src_kind, src_id = "analysis", analysis_id
    else:
        d = cache.api.call("describe-dashboard-definition", DashboardId=dashboard_id)
        src_kind, src_id = "dashboard", dashboard_id
    name = d.get("Name")
    defn = d["Definition"]
    json.dump(d, open(os.path.join(out, "analysis.json"), "w"), indent=2)

    # 2. datasets referenced by the definition — via the ESTATE CACHE (shared
    #    datasets are described once per estate, not once per dashboard)
    ds_meta, src_arns = [], set()
    fixture_by_id = {ds["DataSet"].get("DataSetId"): ds for ds in fixture_ds}
    for decl in defn.get("DataSetIdentifierDeclarations", []):
        ident, ds_id = decl["Identifier"], arn_id(decl["DataSetArn"])
        if offline:
            ds = fixture_by_id.get(ds_id)
            if ds is None:
                log(f"  WARN: no fixture dataset JSON for '{ds_id}' — skipping")
                continue
        else:
            ds, how = cache.dataset(ds_id)
            if how != "describe":
                log(f"  dataset {ds_id}: estate-cache {how} (no describe round-trip)")
        json.dump(ds, open(os.path.join(out, "datasets", ds_id + ".json"), "w"), indent=2)
        dso = ds["DataSet"]
        for ptv in (dso.get("PhysicalTableMap") or {}).values():
            for v in ptv.values():
                if isinstance(v, dict) and v.get("DataSourceArn"):
                    src_arns.add(v["DataSourceArn"])
        ds_meta.append({"identifier": ident, "dataSetId": ds_id, "name": dso.get("Name"),
                        "importMode": dso.get("ImportMode"),
                        "columns": [c.get("Name") for c in dso.get("OutputColumns", [])]})

    # 3. data sources (type tells us Snowflake/Redshift/S3/etc.) — once, lazily
    src_meta = []
    for arn in sorted(src_arns):
        sid = arn_id(arn)
        if offline:
            src_meta.append({"dataSourceId": sid, "name": None, "type": "OFFLINE-FIXTURE"})
            continue
        try:
            s, how = cache.datasource(sid)
            if how != "describe":
                log(f"  datasource {sid}: estate-cache {how}")
            json.dump(s, open(os.path.join(out, "datasources", sid + ".json"), "w"), indent=2)
            so = s["DataSource"]
            src_meta.append({"dataSourceId": sid, "name": so.get("Name"), "type": so.get("Type")})
        except Exception as e:  # noqa: BLE001 — datasource describe is best-effort
            src_meta.append({"dataSourceId": sid, "name": None, "type": "UNKNOWN", "error": str(e)[:120]})

    # 4. signals: per-sheet visuals + calc fields + params
    fg_cols = filter_group_columns(defn)
    sheets = []
    for sh in defn.get("Sheets", []):
        vis = []
        for v in sh.get("Visuals", []):
            (vtype, inner), = v.items()
            t = inner.get("Title", {})
            title = (t.get("FormatText") or {}).get("PlainText") if isinstance(t, dict) else None
            rec = {"type": vtype, "visualId": inner.get("VisualId"),
                   "title": title, "columns": field_columns(inner)}
            # chart-fidelity signals: reference lines (A), color encoding (B)
            refs = visual_reference_lines(inner)
            if refs:
                rec["referenceLines"] = refs
            color = visual_color(inner)
            if color:
                rec["color"] = color
            vis.append(rec)
        # interactive controls (C): resolve each control's target column now so the
        # signal is self-contained (the builder still resolves independently from
        # analysis.json, but signals.json carries the resolved column for visibility).
        ctls = sheet_controls(sh)
        for c in ctls:
            if c.get("sourceFilterId"):
                c["targetColumn"] = fg_cols.get(c["sourceFilterId"])
        srec = {"sheetId": sh.get("SheetId"), "name": sh.get("Name"), "visuals": vis}
        if ctls:
            srec["controls"] = ctls
        sheets.append(srec)

    calc = [{"name": c.get("Name"), "expression": c.get("Expression"), "dataset": c.get("DataSetIdentifier")}
            for c in defn.get("CalculatedFields", [])]
    params = [{"name": (list(p.values())[0] or {}).get("Name")} for p in defn.get("ParameterDeclarations", [])]

    signals = {"source": {"kind": src_kind, "id": src_id, "name": name},
               "datasets": ds_meta, "dataSources": src_meta,
               "calculatedFields": calc, "parameters": params, "sheets": sheets}
    json.dump(signals, open(os.path.join(out, "signals.json"), "w"), indent=2)

    # summary
    log(f"Discovered {src_kind} '{name}' → {out}")
    log(f"  datasets: {len(ds_meta)}  | data sources: {[s['type'] for s in src_meta]}")
    log(f"  calc fields: {len(calc)} | parameters: {len(params)}")
    for s in sheets:
        kinds = ", ".join(v["type"] for v in s["visuals"])
        log(f"  sheet '{s['name']}': {len(s['visuals'])} visuals — {kinds}")
    return signals


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--account-id")
    ap.add_argument("--region")
    ap.add_argument("--profile")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--analysis-id")
    g.add_argument("--dashboard-id")
    g.add_argument("--analysis-ids", help="comma-separated — BATCH mode; each lands in <out-dir>/<id>/")
    ap.add_argument("--from-fixtures", help="dir of describe-shaped JSONs — offline mode, no AWS calls")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--pool", type=int, default=4,
                    help=f"batch-mode parallel discoveries (default 4, cap {MAX_POOL})")
    ap.add_argument("--no-cache", action="store_true", help="bypass the estate dataset/datasource cache")
    ap.add_argument("--refresh-cache", action="store_true", help="force re-describe (and rewrite the cache)")
    a = ap.parse_args(argv)
    offline = bool(a.from_fixtures)
    batch = [s.strip() for s in (a.analysis_ids or "").split(",") if s.strip()]
    if not offline and not (a.analysis_id or a.dashboard_id or batch):
        ap.error("need --analysis-id / --dashboard-id / --analysis-ids (or --from-fixtures)")
    if not offline and not (a.account_id and a.region):
        ap.error("--account-id and --region are required for live discovery")

    out = os.path.expanduser(a.out_dir)
    tm = Timings()
    api = None
    if not offline:
        api = QSApi(a.account_id, a.region, a.profile, timings=tm)
        print(f"[transport] {api.transport}"
              + ("" if api.transport == "boto3" else " (boto3 not importable — per-call subprocess fallback)"))
    cache = EstateCache(api, enabled=not a.no_cache, refresh=a.refresh_cache) if api else None

    if batch:
        pool = max(1, min(a.pool, MAX_POOL))
        print(f"[batch] {len(batch)} analyses, pool={pool}, estate cache "
              f"{'OFF' if a.no_cache else cache.dir}")
        lock = threading.Lock()
        def log(s):
            with lock:
                print(s)
        def one(aid):
            t = time.monotonic()
            try:
                discover_one(os.path.join(out, aid), cache, analysis_id=aid, log=log)
                return aid, None, time.monotonic() - t
            except Exception as e:  # noqa: BLE001 — batch keeps going
                return aid, str(e)[:200], time.monotonic() - t
        results = []
        with ThreadPoolExecutor(max_workers=pool) as ex:
            results = list(ex.map(one, batch))
        failed = [(aid, err) for aid, err, _ in results if err]
        for aid, err, secs in results:
            tm.record(f"analysis:{aid}", secs, ok=err is None)
            print(f"  {aid}: {'OK' if not err else 'FAIL — ' + err} ({secs:.1f}s)")
        t = tm.write(os.path.join(out, "timings.json"), mode="batch",
                     transport=api.transport, pool=pool,
                     analyses=len(batch), failed=len(failed))
        print(f"TIMINGS total={t['totalSeconds']}s -> {os.path.join(out, 'timings.json')}")
        sys.exit(1 if failed else 0)

    discover_one(out, cache, fixture_dir=a.from_fixtures,
                 analysis_id=a.analysis_id, dashboard_id=a.dashboard_id)
    t = tm.write(os.path.join(out, "timings.json"), mode="offline" if offline else "single",
                 transport=api.transport if api else "none")
    print(f"TIMINGS total={t['totalSeconds']}s "
          + "  ".join(f"{x['task']}={x['seconds']}s" for x in t["tasks"]))


if __name__ == "__main__":
    main()
