#!/usr/bin/env python3
"""extract-model-pbix.py — LOCAL semantic-model front door for a `.pbix` file.

The normal powerbi-to-sigma model path is a Fabric getDefinition/TMSL bundle
(migrate-powerbi.rb --tmsl). A user who only has a local `.pbix` on disk has
no such bundle: the `.pbix` DataModel is a binary VertiPaq blob. This script
reads that blob LOCALLY with the `pbixray` library (no Fabric, no tenant) and
emits a TMSL `model.bim` in the SAME shape migrate-powerbi.rb --tmsl and the
vendored converter (convertPowerBIToSigma) already consume:

  { "name": <model>,
    "compatibilityLevel": 1600,
    "model": {
      "culture": "en-US",
      "tables": [ { "name", "columns":[{"name","dataType","sourceColumn",...}],
                    "measures":[{"name","expression"}],
                    "partitions":[M or calculated-table DAX] } ],
      "relationships": [ { "name","fromTable","fromColumn","toTable","toColumn",
                           "crossFilteringBehavior","isActive" } ] } }

The pbixray → TMSL assembly (assemble_tmsl / build_model_from_pbixray) is a
PURE function of the pbixray DataFrames, so it is unit-testable with mocked
dataframes and needs no `.pbix` at test time.

pbixray PACKAGING CAVEAT (be honest with the user): pbixray depends on
`xpress8` (ships a working wheel) plus `xpress9` and `xmhuffman`, whose PyPI
sdists are BROKEN — they must be built FROM SOURCE. Install path:
  pip install apsw pandas xpress8 \
    "git+https://github.com/Hugoberry/xpress9-python@main" \
    "git+https://github.com/Hugoberry/xmhuffman-cython@main" \
    pbixray
(see refs/local-pbix.md). Without pbixray this script exits with a clear
"pbixray required for local model extraction" message + that setup pointer;
the dependency-free report front door (extract-report-classic.py --pbix) and
the whole --tmsl Fabric path are unaffected.

Usage:
  python3 extract-model-pbix.py --pbix /path/Sales.pbix --out model.bim [--name "Sales"]
"""
import argparse, json, math, os, re, sys, zipfile

# pbixray schema PandasDataType (pandas dtype string) -> TMSL dataType. TMSL
# uses string/int64/double/dateTime/boolean/binary; the converter special-cases
# "binary" (skips it as an embedded asset) and reads dataType on calc columns.
def _tmsl_datatype(pandas_dtype):
    d = str(pandas_dtype or "").strip().lower()
    if d.startswith("int") or d.startswith("uint"):
        return "int64"
    if d.startswith("float") or d.startswith("decimal") or d.startswith("number"):
        return "double"
    if d.startswith("datetime") or d.startswith("date") or d.startswith("timestamp"):
        return "dateTime"
    if d.startswith("bool"):
        return "boolean"
    if d.startswith("bytes") or d.startswith("binary"):
        return "binary"
    # "string", "object", "category", unknown -> Sigma treats as text
    return "string"


def _clean(v, default=""):
    """DataFrame cells arrive as str / numpy scalars / NaN — normalize to a
    plain Python string, mapping missing (None/NaN) to `default`."""
    if v is None:
        return default
    if isinstance(v, float) and math.isnan(v):
        return default
    s = str(v)
    return default if s in ("nan", "NaT", "None") else s


def _truthy(v, default=True):
    if v is None:
        return default
    if isinstance(v, float) and math.isnan(v):
        return default
    if isinstance(v, str):
        return v.strip().lower() not in ("false", "0", "", "no")
    return bool(v)


def assemble_tmsl(model_name, schema_recs, measure_recs, relationship_recs,
                  calc_col_recs=(), calc_table_recs=(), mquery_recs=(),
                  table_order=None):
    """PURE pbixray-records -> TMSL model.bim dict.

    Each *_recs arg is a list of dicts (what pandas `df.to_dict("records")`
    yields), so this is fully testable with hand-built dicts — no pbixray:
      schema_recs       : {TableName, ColumnName, PandasDataType}
      measure_recs      : {TableName, Name, Expression, [Description]}
      relationship_recs : {FromTableName, FromColumnName, ToTableName,
                           ToColumnName, [IsActive], [CrossFilteringBehavior], [Name]}
      calc_col_recs     : {TableName, ColumnName, Expression}  (DAX calc columns)
      calc_table_recs   : {TableName, Expression}              (DAX calc tables)
      mquery_recs       : {TableName, Expression}              (Power Query M)
    """
    tables = {}          # name -> table dict (insertion-ordered)
    order = []
    calc_tables = {}
    for r in calc_table_recs:
        tn = _clean(r.get("TableName"))
        expr = _clean(r.get("Expression"))
        if tn and expr:
            calc_tables.setdefault(tn, expr)

    def _table(name):
        name = _clean(name)
        if not name:
            return None
        if name not in tables:
            tables[name] = {"name": name, "columns": [], "measures": [], "partitions": []}
            order.append(name)
        return tables[name]

    # Seed table order from the model's declared table list when provided so
    # the emitted .bim mirrors the pbix ordering (fact-first, etc.).
    for t in (table_order or []):
        _table(t)

    # Data columns (schema).
    for r in schema_recs:
        t = _table(r.get("TableName"))
        if t is None:
            continue
        col = _clean(r.get("ColumnName"))
        if not col:
            continue
        column = {
            "name": col,
            "dataType": _tmsl_datatype(r.get("PandasDataType")),
            "sourceColumn": f"[{col}]" if _clean(r.get("TableName")) in calc_tables else col,
            "summarizeBy": "none",
        }
        if _clean(r.get("TableName")) in calc_tables:
            column["type"] = "calculatedTableColumn"
        t["columns"].append(column)

    # Calculated (DAX) columns — carried through so the converter's calc-column
    # translator can see them; marked type=calculated so it does NOT treat them
    # as warehouse columns.
    for r in calc_col_recs:
        t = _table(r.get("TableName"))
        if t is None:
            continue
        col = _clean(r.get("ColumnName"))
        expr = _clean(r.get("Expression"))
        if not col or not expr:
            continue
        t["columns"].append({
            "name": col, "type": "calculated", "expression": expr,
            "dataType": "string", "summarizeBy": "none",
        })

    # Measures.
    for r in measure_recs:
        t = _table(r.get("TableName"))
        if t is None:
            continue
        nm = _clean(r.get("Name"))
        if not nm:
            continue
        m = {"name": nm, "expression": _clean(r.get("Expression"))}
        desc = _clean(r.get("Description"))
        if desc:
            m["description"] = desc
        t["measures"].append(m)

    # Partitions. A DAX calculated table must win over the generic no-M fallback:
    # pbixray exposes its constructor through dax_tables, and losing that
    # expression makes the converter invent a physical warehouse table. Regular
    # tables retain their Power Query M (and therefore warehouse FQN); tables
    # with neither get an honest placeholder M partition.
    mq_by_table = {}
    for r in mquery_recs:
        tn = _clean(r.get("TableName"))
        expr = _clean(r.get("Expression"))
        if tn and expr:
            mq_by_table.setdefault(tn, expr)
    for name, t in tables.items():
        mq = mq_by_table.get(name)
        calc_expr = calc_tables.get(name)
        if calc_expr:
            t["partitions"].append({"name": name, "mode": "import",
                                    "source": {"type": "calculated",
                                               "expression": calc_expr}})
        elif mq:
            t["partitions"].append({"name": name, "mode": "import",
                                    "source": {"type": "m", "expression": mq}})
        else:
            t["partitions"].append({"name": name, "mode": "import", "source": {
                "type": "m",
                "expression": [
                    f'-- pbixray: no Power Query (M) captured for "{name}"',
                    '-- source path falls back to --database/--schema + table name at convert time',
                ]}})

    # Relationships.
    relationships = []
    for i, r in enumerate(relationship_recs):
        ft = _clean(r.get("FromTableName")); fc = _clean(r.get("FromColumnName"))
        tt = _clean(r.get("ToTableName")); tc = _clean(r.get("ToColumnName"))
        if not (ft and fc and tt and tc):
            continue
        xfb_raw = _clean(r.get("CrossFilteringBehavior")).lower()
        xfb = "bothDirections" if xfb_raw in ("both", "2", "bothdirections") else "oneDirection"
        rel = {
            "name": _clean(r.get("Name")) or f"rel_{ft}_{tt}_{i}",
            "fromTable": ft, "fromColumn": fc, "toTable": tt, "toColumn": tc,
            "crossFilteringBehavior": xfb,
            "isActive": _truthy(r.get("IsActive")),
        }
        relationships.append(rel)

    return {
        "name": model_name,
        "compatibilityLevel": 1600,
        "model": {
            "culture": "en-US",
            "tables": [tables[n] for n in order],
            "relationships": relationships,
        },
    }


# --- composite / live-connection detection --------------------------------
# A Power BI COMPOSITE report (or one live-connected to a shared dataset) keeps
# references to a REMOTE semantic model. The offline tell is the `.pbix` zip's
# `Connections` member: a JSON doc whose `RemoteArtifacts` lists the shared
# dataset(s) it points at ([{DatasetId, ReportId}, ...]), and/or a `Connections`
# entry whose connection string names a remote PBI model (pbiazure /
# PbiModelDatabaseName). For such reports the Fabric getDefinition of the
# report's BOUND semantic model is INCOMPLETE — it misses the report-local
# measures / calc tables (composite) or isn't resolvable standalone
# (thin-live). The COMPLETE model lives in this local `.pbix`, so we prefer it.
CONNECTIONS_MEMBER = "Connections"


def read_pbix_connections(pbix_path):
    """Parse the `.pbix`'s `Connections` member (JSON) -> dict, or None if the
    file has no such member. stdlib-only (no pbixray)."""
    try:
        with zipfile.ZipFile(pbix_path) as z:
            member = next((n for n in z.namelist()
                           if n.replace("\\", "/") == CONNECTIONS_MEMBER), None)
            if not member:
                return None
            raw = z.read(member)
    except (OSError, zipfile.BadZipFile):
        return None
    for enc in ("utf-8-sig", "utf-8", "utf-16-le", "utf-16"):
        try:
            return json.loads(raw.decode(enc))
        except (UnicodeDecodeError, ValueError):
            continue
    return None


def remote_artifacts(connections):
    """The RemoteArtifacts list ([{DatasetId, ReportId}, ...]) or []."""
    if not isinstance(connections, dict):
        return []
    ra = connections.get("RemoteArtifacts") or connections.get("remoteArtifacts") or []
    return [a for a in ra if isinstance(a, dict)]


_REMOTE_CONN_RE = re.compile(
    r"pbiazure|PbiModelDatabaseName|PbiServiceModelId|PbiModelVirtualServerName"
    r"|Data\s*Source\s*=\s*pbiazure|powerbi://", re.I)


def is_composite_connections(connections):
    """True when the Connections doc shows a COMPOSITE / live-connected model:
    RemoteArtifacts present, or a connection entry that points at a remote PBI
    model (pbiazure / PbiModelDatabaseName / a live-connect ConnectionType)."""
    if not isinstance(connections, dict):
        return False
    if remote_artifacts(connections):
        return True
    for c in (connections.get("Connections") or connections.get("connections") or []):
        if not isinstance(c, dict):
            continue
        blob = " ".join(str(c.get(k, "")) for k in
                        ("ConnectionString", "connectionString", "PbiModelDatabaseName"))
        if _REMOTE_CONN_RE.search(blob):
            return True
        if str(c.get("ConnectionType", c.get("connectionType", ""))).lower() in (
                "pbiservicexmlastyleliveconnect", "analysisservicesdatabaselive",
                "pbiservicelive", "pbidatasetlive"):
            return True
    return False


def pbix_is_composite(pbix_path):
    return is_composite_connections(read_pbix_connections(pbix_path))


def _records(df):
    """DataFrame (pandas or any object exposing to_dict('records')) -> list of
    dicts. None / empty -> []. A plain list is returned as-is (mock convenience)."""
    if df is None:
        return []
    if isinstance(df, list):
        return df
    empty = getattr(df, "empty", None)
    if empty is True:
        return []
    to_dict = getattr(df, "to_dict", None)
    if callable(to_dict):
        try:
            return to_dict("records")
        except TypeError:
            return to_dict(orient="records")
    return list(df)


def build_model_from_pbixray(pbi, model_name):
    """PBIXRay-like object (real pbixray.PBIXRay OR a mock exposing the same
    DataFrame properties) -> TMSL model.bim dict."""
    try:
        table_order = [str(t) for t in list(pbi.tables)]
    except Exception:
        table_order = None
    return assemble_tmsl(
        model_name,
        _records(getattr(pbi, "schema", None)),
        _records(getattr(pbi, "dax_measures", None)),
        _records(getattr(pbi, "relationships", None)),
        calc_col_recs=_records(getattr(pbi, "dax_columns", None)),
        calc_table_recs=_records(getattr(pbi, "dax_tables", None)),
        mquery_recs=_records(getattr(pbi, "power_query", None)),
        table_order=table_order,
    )


PBIXRAY_HINT = (
    "pbixray required for local model extraction.\n"
    "Install it (its xpress9/xmhuffman deps ship BROKEN sdists — build from source):\n"
    "  pip install apsw pandas xpress8 \\\n"
    '    "git+https://github.com/Hugoberry/xpress9-python@main" \\\n'
    '    "git+https://github.com/Hugoberry/xmhuffman-cython@main" \\\n'
    "    pbixray\n"
    "See refs/local-pbix.md. The report front door (extract-report-classic.py "
    "--pbix) and the --tmsl Fabric path do NOT need pbixray."
)


def load_pbix(pbix_path, model_name):
    try:
        from pbixray import PBIXRay  # lazy: only local-model extraction needs it
    except ImportError:
        raise SystemExit("FATAL: " + PBIXRAY_HINT)
    pbi = PBIXRay(pbix_path)
    return build_model_from_pbixray(pbi, model_name)


def main():
    ap = argparse.ArgumentParser(
        description="Extract a local .pbix VertiPaq model into a TMSL model.bim "
                    "(pbixray → the shape migrate-powerbi.rb --tmsl consumes).")
    ap.add_argument("--pbix", required=True, help="local .pbix file")
    ap.add_argument("--out", help="output model.bim path (required unless --detect-composite)")
    ap.add_argument("--name", help="model name (default: .pbix basename)")
    # stdlib-only composite probe (no pbixray): prints
    # {"composite":bool,"remoteArtifacts":[...]} and exits. Used by the
    # orchestrator/Fabric path to decide whether to prefer this local .pbix.
    ap.add_argument("--detect-composite", action="store_true",
                    help="report whether the .pbix is a composite/live-connected model, then exit")
    a = ap.parse_args()
    if a.detect_composite:
        conns = read_pbix_connections(a.pbix)
        print(json.dumps({
            "composite": is_composite_connections(conns),
            "remoteArtifacts": remote_artifacts(conns),
        }))
        return
    if not a.out:
        raise SystemExit("FATAL: --out is required (unless --detect-composite).")
    model_name = a.name or os.path.splitext(os.path.basename(a.pbix))[0]
    tmsl = load_pbix(a.pbix, model_name)
    with open(a.out, "w") as f:
        json.dump(tmsl, f, indent=2)
    m = tmsl["model"]
    ncols = sum(len(t["columns"]) for t in m["tables"])
    nmeas = sum(len(t["measures"]) for t in m["tables"])
    print(f"[pbix-model] '{model_name}': {len(m['tables'])} table(s), {ncols} column(s), "
          f"{nmeas} measure(s), {len(m['relationships'])} relationship(s) -> {a.out}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
