#!/usr/bin/env python3
"""test-extract-model-pbix.py — synthetic unit test for the pbixray -> TMSL
assembly in extract-model-pbix.py.

The assembly (build_model_from_pbixray / assemble_tmsl) is a PURE function of
the pbixray DataFrames, so this test MOCKS the dataframes (a tiny FakeDF that
exposes .empty + .to_dict('records'), exactly what pbixray returns) with
GENERIC SALES_FACT / DATE_DIM data — no pbixray, no pandas, no .pbix, no
network. Asserts the emitted model.bim shape:
  * tables carry columns [{name,dataType,...}] with PandasDataType -> TMSL
    dataType mapping, and measures [{name,expression}]
  * relationships carry from/to table+column, crossFilteringBehavior, isActive
  * DAX calculated tables keep calculated partitions; regular tables keep M

Also loads the vendored converter (if `node` is present) and asserts the
emitted model.bim CONVERTS without error — the "flows through the convert
step" check from the task, kept synthetic.

Run: python3 tests/test-extract-model-pbix.py   (exit 0 = pass)
"""
import importlib.util, json, os, shutil, subprocess, sys, tempfile, zipfile
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.join(HERE, "..")
SCRIPT = os.path.join(SKILL, "scripts", "extract-model-pbix.py")
CONVERTER = os.path.join(SKILL, "converter", "powerbi.mjs")


def _load_module():
    spec = importlib.util.spec_from_file_location("extract_model_pbix", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeDF:
    """Minimal stand-in for a pandas DataFrame as pbixray returns it: an
    .empty flag and .to_dict('records') yielding a list of row dicts."""
    def __init__(self, records):
        self._records = list(records)

    @property
    def empty(self):
        return len(self._records) == 0

    def to_dict(self, orient="records"):
        assert orient == "records", orient
        return [dict(r) for r in self._records]


class FakePBIXRay:
    """Mock of pbixray.PBIXRay exposing the DataFrame properties the assembly
    reads. Generic SALES_FACT / DATE_DIM model."""
    tables = ["SALES_FACT", "DATE_DIM"]
    schema = FakeDF([
        {"TableName": "SALES_FACT", "ColumnName": "SALE_ID", "PandasDataType": "Int64"},
        {"TableName": "SALES_FACT", "ColumnName": "AMOUNT", "PandasDataType": "Float64"},
        {"TableName": "SALES_FACT", "ColumnName": "SALE_DATE", "PandasDataType": "datetime64[ns]"},
        {"TableName": "SALES_FACT", "ColumnName": "IS_RETURN", "PandasDataType": "bool"},
        {"TableName": "DATE_DIM", "ColumnName": "Date", "PandasDataType": "datetime64[ns]"},
        {"TableName": "DATE_DIM", "ColumnName": "MONTH", "PandasDataType": "string"},
    ])
    dax_measures = FakeDF([
        {"TableName": "SALES_FACT", "Name": "Total Sales",
         "Expression": "SUM(SALES_FACT[AMOUNT])", "Description": "Sum of amount"},
        {"TableName": "SALES_FACT", "Name": "Sale Count",
         "Expression": "COUNTROWS(SALES_FACT)", "Description": ""},
    ])
    dax_columns = FakeDF([
        {"TableName": "SALES_FACT", "ColumnName": "Net Amount",
         "Expression": "SALES_FACT[AMOUNT] * 0.9"},
    ])
    dax_tables = FakeDF([
        {"TableName": "DATE_DIM",
         "Expression": 'ADDCOLUMNS(CALENDAR(DATE(2024,1,1), DATE(2024,12,31)), '
                       '"MONTH", FORMAT([Date], "MMM"))'},
    ])
    relationships = FakeDF([
        {"FromTableName": "SALES_FACT", "FromColumnName": "SALE_DATE",
         "ToTableName": "DATE_DIM", "ToColumnName": "Date",
         "IsActive": True, "CrossFilteringBehavior": "Single"},
        {"FromTableName": "SALES_FACT", "FromColumnName": "SALE_DATE",
         "ToTableName": "DATE_DIM", "ToColumnName": "Date",
         "IsActive": False, "CrossFilteringBehavior": "Both"},
    ])
    power_query = FakeDF([
        {"TableName": "SALES_FACT",
         "Expression": 'let Source = Snowflake.Databases("acct.snowflakecomputing.com","WH"),'
                       ' Nav = Source{[Name="RAW",Kind="Database"]}[Data],'
                       ' Sch = Nav{[Name="SALES",Kind="Schema"]}[Data],'
                       ' Tbl = Sch{[Name="SALES_FACT",Kind="Table"]}[Data] in Tbl'},
        # DATE_DIM deliberately has no M: dax_tables must supply its partition.
    ])


def test_assembly():
    mod = _load_module()
    tmsl = mod.build_model_from_pbixray(FakePBIXRay(), "Synthetic Sales")

    assert tmsl["name"] == "Synthetic Sales"
    m = tmsl["model"]
    tbls = {t["name"]: t for t in m["tables"]}
    assert list(tbls) == ["SALES_FACT", "DATE_DIM"], f"table order {list(tbls)}"

    sf = tbls["SALES_FACT"]
    cols = {c["name"]: c for c in sf["columns"]}
    # PandasDataType -> TMSL dataType mapping.
    assert cols["SALE_ID"]["dataType"] == "int64", cols["SALE_ID"]
    assert cols["AMOUNT"]["dataType"] == "double", cols["AMOUNT"]
    assert cols["SALE_DATE"]["dataType"] == "dateTime", cols["SALE_DATE"]
    assert cols["IS_RETURN"]["dataType"] == "boolean", cols["IS_RETURN"]
    assert cols["SALE_ID"]["sourceColumn"] == "SALE_ID"
    # Calculated (DAX) column carried through, marked calculated (not a WH col).
    assert cols["Net Amount"]["type"] == "calculated", cols["Net Amount"]
    assert cols["Net Amount"]["expression"] == "SALES_FACT[AMOUNT] * 0.9"

    # Measures.
    meas = {x["name"]: x for x in sf["measures"]}
    assert meas["Total Sales"]["expression"] == "SUM(SALES_FACT[AMOUNT])", meas
    assert meas["Total Sales"]["description"] == "Sum of amount"
    assert "description" not in meas["Sale Count"], "empty description must be omitted"

    # Partitions: SALES_FACT passes M through (so the WH FQN survives); DATE_DIM
    # keeps its calculated-table DAX rather than becoming a fake warehouse path.
    sf_part = sf["partitions"][0]
    assert sf_part["mode"] == "import" and sf_part["source"]["type"] == "m"
    assert "Snowflake.Databases" in sf_part["source"]["expression"], sf_part
    dd_part = tbls["DATE_DIM"]["partitions"][0]
    assert dd_part["mode"] == "import"
    assert dd_part["source"]["type"] == "calculated", dd_part
    assert "ADDCOLUMNS(CALENDAR" in dd_part["source"]["expression"], dd_part
    dd_cols = {c["name"]: c for c in tbls["DATE_DIM"]["columns"]}
    assert dd_cols["Date"]["type"] == "calculatedTableColumn", dd_cols["Date"]
    assert dd_cols["Date"]["sourceColumn"] == "[Date]", dd_cols["Date"]

    # Relationships: field mapping + crossFilteringBehavior + isActive.
    rels = m["relationships"]
    assert len(rels) == 2, rels
    r0, r1 = rels
    assert (r0["fromTable"], r0["fromColumn"], r0["toTable"], r0["toColumn"]) == \
           ("SALES_FACT", "SALE_DATE", "DATE_DIM", "Date"), r0
    assert r0["crossFilteringBehavior"] == "oneDirection" and r0["isActive"] is True, r0
    assert r1["crossFilteringBehavior"] == "bothDirections" and r1["isActive"] is False, r1
    assert r0["name"] and r1["name"] and r0["name"] != r1["name"], "relationships need unique names"

    # assemble_tmsl accepts plain records too (no DataFrame needed).
    direct = mod.assemble_tmsl("X",
        [{"TableName": "T", "ColumnName": "C", "PandasDataType": "string"}],
        [], [])
    assert direct["model"]["tables"][0]["columns"][0]["dataType"] == "string"
    print("  ok [assembly]: columns/dataType, measures, calc cols/tables, partitions, relationships")
    return tmsl


def test_converts(tmsl):
    if not shutil.which("node"):
        print("  skip [convert]: node not found (assembly test still covers the shape)")
        return
    if not os.path.exists(CONVERTER):
        print("  skip [convert]: vendored converter not present")
        return
    with tempfile.TemporaryDirectory() as d:
        bim = os.path.join(d, "model.bim")
        with open(bim, "w") as f:
            json.dump(tmsl, f)
        shim = os.path.join(d, "conv.mjs")
        # Import the converter by file:// URL so the shim also runs on Windows
        # (Node rejects a bare absolute/drive-letter ESM specifier).
        conv_url = Path(CONVERTER).resolve().as_uri()
        with open(shim, "w") as f:
            f.write(
                "import { readFileSync } from 'node:fs';\n"
                f"import {{ convertPowerBIToSigma }} from {json.dumps(conv_url)};\n"
                f"const model = JSON.parse(readFileSync({json.dumps(bim)},'utf8'));\n"
                "const out = convertPowerBIToSigma(model, {connectionId:'11111111-2222-3333-4444-555555555555', database:'ANALYTICS', schema:'PUBLIC'});\n"
                "const bare = out.model || out.sigmaDataModel || out;\n"
                "const els = (bare.pages||[]).flatMap(p=>p.elements||[]);\n"
                "if (!els.length) { console.error('NO ELEMENTS'); process.exit(3); }\n"
                "const wh = els.find(e=>e.source && e.source.kind==='warehouse-table');\n"
                "if (!wh || !(wh.source.path||[]).includes('SALES_FACT')) { console.error('NO SALES_FACT PATH'); process.exit(4); }\n"
                "const cal = els.find(e=>e.source && e.source.kind==='sql' && /GENERATOR/.test(e.source.statement||''));\n"
                "if (!cal || /_placeholder/.test(cal.source.statement||'')) { console.error('NO CALCULATED DATE SPINE'); process.exit(5); }\n"
                "if (els.some(e=>(e.source&&e.source.path||[]).includes('DATE_DIM'))) { console.error('DATE_DIM BECAME WAREHOUSE TABLE'); process.exit(6); }\n"
                "console.log('CONVERT_OK elements='+els.length);\n")
        r = subprocess.run(["node", shim], capture_output=True, text=True)
        assert r.returncode == 0 and "CONVERT_OK" in r.stdout, \
            f"converter rejected the emitted model.bim ({r.returncode})\n{r.stdout}\n{r.stderr}"
        print(f"  ok [convert]: emitted model.bim flows through the vendored converter ({r.stdout.strip()})")


def test_composite_detection():
    """Composite / live-connection detection from the .pbix `Connections` doc
    (RemoteArtifacts is the offline tell). Pure function — fake dicts, no .pbix."""
    mod = _load_module()

    # RemoteArtifacts present -> composite.
    conns_remote = {"Version": 3,
                    "Connections": [{"Name": "EntityDataSource", "ConnectionType": "pbiServiceLive"}],
                    "RemoteArtifacts": [{"DatasetId": "ds-123", "ReportId": "rp-456"}]}
    assert mod.is_composite_connections(conns_remote) is True, "RemoteArtifacts must => composite"
    assert mod.remote_artifacts(conns_remote) == [{"DatasetId": "ds-123", "ReportId": "rp-456"}]

    # A plain local import model -> NOT composite.
    conns_local = {"Version": 3,
                   "Connections": [{"Name": "LocalModel", "ConnectionType": "structured",
                                    "ConnectionString": "Data Source=SNOWFLAKE"}]}
    assert mod.is_composite_connections(conns_local) is False, "local import must NOT be composite"
    assert mod.remote_artifacts(conns_local) == []

    # No RemoteArtifacts but a remote-model connection string -> composite.
    conns_pbiazure = {"Connections": [{"ConnectionString":
                       "Data Source=pbiazure://api.powerbi.com;Initial Catalog=x"}]}
    assert mod.is_composite_connections(conns_pbiazure) is True, "pbiazure conn => composite"

    # None / empty -> False (no Connections member).
    assert mod.is_composite_connections(None) is False
    assert mod.is_composite_connections({}) is False

    # CLI --detect-composite on synthetic .pbix zips (exercises read_pbix_connections + zip).
    with tempfile.TemporaryDirectory() as d:
        comp = os.path.join(d, "Composite.pbix")
        with zipfile.ZipFile(comp, "w") as z:
            z.writestr("Connections", json.dumps(conns_remote).encode("utf-8"))
            z.writestr("Report/Layout", "{}".encode("utf-16-le"))
        r = subprocess.run([sys.executable, SCRIPT, "--pbix", comp, "--detect-composite"],
                           capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        res = json.loads(r.stdout)
        assert res["composite"] is True and len(res["remoteArtifacts"]) == 1, res

        plain = os.path.join(d, "Local.pbix")
        with zipfile.ZipFile(plain, "w") as z:
            z.writestr("Connections", json.dumps(conns_local).encode("utf-8"))
        r = subprocess.run([sys.executable, SCRIPT, "--pbix", plain, "--detect-composite"],
                           capture_output=True, text=True)
        assert r.returncode == 0 and json.loads(r.stdout)["composite"] is False, r.stdout
    print("  ok [composite]: RemoteArtifacts/pbiazure => composite; local import => not; CLI probe works")


def main():
    tmsl = test_assembly()
    test_converts(tmsl)
    test_composite_detection()
    print("PASS test-extract-model-pbix.py")


if __name__ == "__main__":
    main()
