#!/usr/bin/env python3
"""Offline regression for corectl unbuild, LOAD expressions, and coverage."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIXTURE = os.path.join(SKILL, "fixtures", "corectl-country-unbuild")
sys.path.insert(0, SCRIPTS)
SUBPROCESS_TEXT = {"capture_output": True, "text": True, "encoding": "utf-8", "errors": "replace"}


def load_discovery():
    path = os.path.join(SCRIPTS, "qlik-discover.py")
    spec = importlib.util.spec_from_file_location("qlik_discovery_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(*args):
    result = subprocess.run(args, **SUBPROCESS_TEXT)
    assert result.returncode == 0, result.stdout + result.stderr
    return result


def test_chart_hypercube_rows_preserve_dimensions_and_numeric_measures():
    module = load_discovery()
    module.qlik = lambda *_args, **_kwargs: {
        "qDataPages": [{
            "qArea": {"qTop": 0, "qLeft": 0, "qWidth": 2, "qHeight": 2},
            "qMatrix": [
                [
                    {"qText": "West", "qNum": 0},
                    {"qText": "$42.00", "qNum": 42.0},
                ],
                [
                    {"qText": "East", "qNum": 0},
                    {"qText": "$10.50", "qNum": 10.5},
                ],
            ]
        }]
    }
    result = module.qlik_chart_rows(
        "app",
        ["--context", "fixture"],
        {"id": "chart-1", "dimensions": ["Region"], "measures": ["Sum(Sales)"]},
    )
    assert result["rows"] == [["West", 42.0], ["East", 10.5]]
    assert result["complete"] is True
    assert result["expectedRows"] == 2


def test_pivot_hypercube_rows_capture_numeric_value_matrix():
    module = load_discovery()
    module.qlik = lambda *_args, **_kwargs: {
        "qPivotDataPages": [{
            "qArea": {"qTop": 0, "qLeft": 0, "qWidth": 2, "qHeight": 2},
            "qData": [
                [
                    {"qText": "42", "qNum": 42.0, "qType": "V"},
                    {"qText": "-", "qNum": float("nan"), "qType": "U"},
                ],
                [
                    {"qText": "10.5", "qNum": 10.5, "qType": "V"},
                    {"qText": "3", "qNum": 3.0, "qType": "V"},
                ],
            ],
        }]
    }
    result = module.qlik_chart_rows(
        "app",
        ["--context", "fixture"],
        {
            "id": "pivot-1",
            "dimensions": ["Region"],
            "measures": ["Sum(Sales)"],
        },
    )
    assert result["pivot"] is True
    assert result["complete"] is True
    assert result["rows"] == [[42.0, None], [10.5, 3.0]]


def test_normalizes_nested_children_with_empty_master_items():
    with tempfile.TemporaryDirectory() as output:
        run(sys.executable, os.path.join(SCRIPTS, "qlik-unbuild-discover.py"),
            "--unbuild", FIXTURE, "--out", output)
        charts = json.load(open(os.path.join(output, "charts.json")))
        layout = json.load(open(os.path.join(output, "layout.json")))
        converter_input = json.load(open(os.path.join(output, "converter-input.json")))
        assert json.load(open(os.path.join(output, "measures.json"))) == []
        assert json.load(open(os.path.join(output, "dimensions.json"))) == []
        assert {chart["id"] for chart in charts} == {"kpi-sales", "bar-region"}
        assert all(chart["sheet"] == "sheet-country" for chart in charts)
        assert {cell["objectId"] for cell in layout[0]["cells"]} == {"kpi-sales", "bar-region"}
        fields = {field["name"] for field in converter_input["tables"][0]["fields"]}
        assert fields == {"COUNTRY", "SALES", "REGION_GROUP"}


def test_preserves_if_match_as_sql_case():
    with tempfile.TemporaryDirectory() as output:
        reconcile = os.path.join(output, "reconcile.json")
        denorm = os.path.join(output, "denorm.json")
        run(sys.executable, os.path.join(SCRIPTS, "reconcile-columns.py"),
            "--script", os.path.join(FIXTURE, "script.qvs"), "--out", reconcile)
        rec = json.load(open(reconcile))
        calc = next(field for field in rec[0]["fields"] if field["qlikField"] == "REGION_GROUP")
        assert calc["isExpression"] is True and calc["expressionColumns"] == ["COUNTRY"]
        run(sys.executable, os.path.join(SCRIPTS, "gen-denorm-sql.py"),
            "--reconcile", reconcile, "--database", "ANALYTICS", "--schema", "PUBLIC",
            "--connection", "conn-offline", "--out", denorm)
        generated = json.load(open(denorm))
        assert "CASE WHEN f.COUNTRY IN ('US', 'CA') THEN 'North America' ELSE 'Other' END AS REGION_GROUP" in generated["sql"]
        assert "REGION_GROUP" in generated["calculatedFields"]
        assert any(column["formula"] == "[Custom SQL/REGION_GROUP]"
                   for column in generated["element"]["columns"])


def test_unsupported_load_expression_blocks_instead_of_dropping():
    with tempfile.TemporaryDirectory() as output:
        reconcile = os.path.join(output, "reconcile.json")
        denorm = os.path.join(output, "denorm.json")
        json.dump([{
            "qlikTable": "Facts", "sourceTable": "FACTS",
            "fields": [
                {"qlikField": "SALES", "realColumn": "SALES", "isExpression": False},
                {"qlikField": "RANKED", "realColumn": "Aggr(Sum(SALES), COUNTRY)",
                 "loadExpression": "Aggr(Sum(SALES), COUNTRY)", "isExpression": True}
            ]
        }], open(reconcile, "w"))
        result = subprocess.run([
            sys.executable, os.path.join(SCRIPTS, "gen-denorm-sql.py"),
            "--reconcile", reconcile, "--database", "ANALYTICS", "--schema", "PUBLIC",
            "--connection", "conn-offline", "--out", denorm
        ], **SUBPROCESS_TEXT)
        assert result.returncode != 0 and "unsupported Qlik LOAD expression" in result.stderr
        assert not os.path.exists(denorm)


def test_dimension_calculation_stays_null_when_left_join_misses():
    with tempfile.TemporaryDirectory() as output:
        reconcile = os.path.join(output, "reconcile.json")
        denorm = os.path.join(output, "denorm.json")
        json.dump([
            {
                "qlikTable": "Customers", "sourceTable": "CUSTOMERS",
                "fields": [
                    {"qlikField": "CUSTOMER_KEY", "realColumn": "CUSTOMER_KEY", "isExpression": False},
                    {"qlikField": "REGION", "realColumn": "REGION", "isExpression": False},
                    {"qlikField": "REGION_GROUP", "realColumn": "If(REGION='West','West','Other')",
                     "loadExpression": "If(REGION='West','West','Other')", "isExpression": True},
                ],
            },
            {
                "qlikTable": "OrderFact", "sourceTable": "ORDER_FACT",
                "fields": [
                    {"qlikField": "ORDER_ID", "realColumn": "ORDER_ID", "isExpression": False},
                    {"qlikField": "CUSTOMER_KEY", "realColumn": "CUSTOMER_KEY", "isExpression": False},
                    {"qlikField": "NET_REVENUE", "realColumn": "NET_REVENUE", "isExpression": False},
                ],
            },
        ], open(reconcile, "w"))
        run(sys.executable, os.path.join(SCRIPTS, "gen-denorm-sql.py"),
            "--reconcile", reconcile, "--database", "ANALYTICS", "--schema", "PUBLIC",
            "--connection", "conn-offline", "--out", denorm)
        sql = json.load(open(denorm))["sql"]
        assert (
            "CASE WHEN a.CUSTOMER_KEY IS NULL THEN NULL ELSE CASE WHEN a.REGION = 'West' "
            "THEN 'West' ELSE 'Other' END END AS REGION_GROUP"
        ) in sql


def test_load_expression_helpers_compose_with_arithmetic_and_concat():
    from qlik_load_expr import translate
    columns = {"COUNTRY": "COUNTRY", "SALES": "SALES"}
    assert translate("Upper(COUNTRY) & '-' & SALES", "f", columns) == \
        "UPPER(f.COUNTRY) || '-' || f.SALES"
    assert translate("If(COUNTRY = 'US', SALES * 2, -1)", "f", columns) == \
        "CASE WHEN f.COUNTRY = 'US' THEN f.SALES * 2 ELSE -1 END"
    assert translate("If(COUNTRY = 'A OR B' OR COUNTRY = 'US', 1, 0)", "f", columns) == \
        "CASE WHEN f.COUNTRY = 'A OR B' OR f.COUNTRY = 'US' THEN 1 ELSE 0 END"
    assert translate("If(LIFETIME_REVENUE>1000,1,0)", "c", {"LIFETIME_REVENUE": "LIFETIME_REVENUE"}) == \
        "CASE WHEN c.LIFETIME_REVENUE > 1000 THEN 1 ELSE 0 END"
    assert translate(
        "If(Match(REGION,'West','Southwest','Northwest'),'West Coast', "
        "If(Match(REGION,'Northeast','Southeast','South'),'East/South','Central'))",
        "c", {"REGION": "REGION"},
    ) == (
        "CASE WHEN c.REGION IN ('West', 'Southwest', 'Northwest') THEN 'West Coast' ELSE "
        "CASE WHEN c.REGION IN ('Northeast', 'Southeast', 'South') THEN 'East/South' "
        "ELSE 'Central' END END"
    )


def test_direct_sql_and_resident_load_resolve_to_final_physical_tables():
    from qlik_load_script import parse_reconcile, parse_tables
    script = """CustomerStage:
LOAD CUSTOMER_KEY, REGION,
  If(Match(REGION, 'West'), 1, 0) AS IS_WEST;
SQL SELECT CUSTOMER_KEY, REGION FROM DB.SCHEMA.CUSTOMER_DIM;

CustomerDim:
LOAD CUSTOMER_KEY, REGION, IS_WEST,
  If(Match(REGION, 'West'), 'Coast',
     If(Match(REGION, 'East'), 'Atlantic', 'Other')) AS REGION_GROUP
RESIDENT CustomerStage;
DROP TABLE CustomerStage;

OrderFact:
SQL SELECT ORDER_ID, CUSTOMER_KEY, NET_REVENUE FROM DB.SCHEMA.ORDER_FACT;
"""
    reconciled = parse_reconcile(script)
    assert [table["qlikTable"] for table in reconciled] == ["CustomerDim", "OrderFact"]
    assert reconciled[0]["sourceTable"] == "DB.SCHEMA.CUSTOMER_DIM"
    assert reconciled[0]["fields"][2]["loadExpression"] == "If(Match(REGION, 'West'), 1, 0)"
    assert reconciled[0]["fields"][3]["expressionColumns"] == ["REGION"]
    assert [table["name"] for table in parse_tables(script)] == ["CustomerDim", "OrderFact"]


def test_auto_chart_uses_generated_visualization_and_primary_color():
    from qlik_object_props import effective_chart_properties
    props = {
        "qInfo": {"qId": "auto-1", "qType": "auto-chart"},
        "visualization": "auto-chart",
        "qHyperCubeDef": {"qMeasures": [{"qDef": {"qDef": "Count(ID)"}}]},
        "qUndoExclude": {"generated": {
            "visualization": "scatterplot",
            "qHyperCubeDef": {"qMeasures": [
                {"qDef": {"qDef": "Sum(REVENUE)"}},
                {"qDef": {"qDef": "Sum(PREMIUM)"}},
                {"qDef": {"qDef": "Count(ID)"}},
            ]},
            "color": {"mode": "primary", "paletteColor": {"index": 6}},
        }},
    }
    effective, viz_type = effective_chart_properties(props, "auto-chart")
    assert viz_type == "scatterplot"
    assert [measure["qDef"]["qDef"] for measure in effective["qHyperCubeDef"]["qMeasures"]] == [
        "Sum(REVENUE)", "Sum(PREMIUM)", "Count(ID)"]
    assert effective["color"]["mode"] == "primary"


def test_one_command_dry_run_builds_both_source_visuals():
    with tempfile.TemporaryDirectory() as output:
        runtime_profile = {
            "selected": "python",
            "required_runtimes": ["python", "node"],
        }
        json.dump(
            {
                "pass": True,
                "runtime_profile": runtime_profile,
                "runtimes": {"python": True, "node": True, "ruby": False},
            },
            open(os.path.join(output, "doctor.json"), "w"),
        )
        json.dump(
            {"doctor_pass": True, "runtime_profile": runtime_profile},
            open(os.path.join(output, "bootstrap.json"), "w"),
        )
        result = run(sys.executable, os.path.join(SCRIPTS, "migrate-qlik.py"),
                     "--unbuild", FIXTURE, "--connection", "00000000-0000-0000-0000-000000000000",
                     "--database", "ANALYTICS", "--schema", "PUBLIC", "--dry-run", "--yes", "--out", output)
        coverage = json.load(open(os.path.join(output, "workbook-coverage.json")))
        workbook = json.load(open(os.path.join(output, "wb-result.json")))
        assert coverage["status"] == "PASS" and coverage["sourceVisuals"] == 2
        assert coverage["queryableElements"] == 2 and coverage["unbuiltSourceVisualIds"] == []
        assert workbook["queryableElements"] == 2
        assert "pre-write source coverage: 2/2" in result.stdout


def test_data_only_workbook_is_rejected_in_dry_run():
    with tempfile.TemporaryDirectory() as output:
        charts = os.path.join(output, "charts.json")
        layout = os.path.join(output, "layout.json")
        denorm = os.path.join(output, "denorm.json")
        json.dump([], open(charts, "w"))
        json.dump([], open(layout, "w"))
        json.dump({"element": {"columns": [{"name": "Sales", "formula": "[Custom SQL/SALES]"}]}}, open(denorm, "w"))
        result_path = os.path.join(output, "result.json")
        result = subprocess.run([
            sys.executable, os.path.join(SCRIPTS, "build-sigma-workbook.py"),
            "--charts", charts, "--layout", layout, "--denorm", denorm,
            "--dm-id", "dm-x", "--denorm-element-id", "el-x", "--name", "Empty",
            "--dry-run", "--out", result_path, "--spec-out", os.path.join(output, "spec.json"),
            "--layout-out", os.path.join(output, "layout.xml"),
            "--element-map", os.path.join(output, "element-map.json")
        ], **SUBPROCESS_TEXT)
        assert result.returncode != 0 and "Data page" in result.stderr
        report = json.load(open(result_path))
        assert report["queryableElements"] == 0


def test_partial_visual_drop_is_rejected_before_post():
    with tempfile.TemporaryDirectory() as output:
        charts = os.path.join(output, "charts.json")
        layout = os.path.join(output, "layout.json")
        denorm = os.path.join(output, "denorm.json")
        base = {"dimensions": [], "dimLabels": [], "dimNullSuppression": [],
                "measureLabels": ["Sales"], "measureFmts": [None], "sort": {}}
        json.dump([
            {**base, "id": "valid", "vizType": "kpi", "title": "Valid", "measures": ["Sum(SALES)"]},
            {**base, "id": "dropped", "vizType": "kpi", "title": "Dropped", "measures": ["Aggr(Sum(SALES), COUNTRY)"]}
        ], open(charts, "w"))
        json.dump([], open(layout, "w"))
        json.dump({"element": {"columns": [
            {"name": "Sales", "formula": "[Custom SQL/SALES]"},
            {"name": "Country", "formula": "[Custom SQL/COUNTRY]"}
        ]}}, open(denorm, "w"))
        result_path = os.path.join(output, "result.json")
        result = subprocess.run([
            sys.executable, os.path.join(SCRIPTS, "build-sigma-workbook.py"),
            "--charts", charts, "--layout", layout, "--denorm", denorm,
            "--dm-id", "dm-x", "--denorm-element-id", "el-x", "--name", "Partial",
            "--dry-run", "--out", result_path, "--spec-out", os.path.join(output, "spec.json"),
            "--layout-out", os.path.join(output, "layout.xml"),
            "--element-map", os.path.join(output, "element-map.json")
        ], **SUBPROCESS_TEXT)
        assert result.returncode != 0 and "source visual(s) were not rebuilt: dropped" in result.stderr
        report = json.load(open(result_path))
        assert report["queryableElements"] == 1 and report["unbuiltSourceVisuals"] == ["dropped"]


if __name__ == "__main__":
    failures = 0
    for name, function in sorted((name, value) for name, value in globals().items() if name.startswith("test_")):
        try:
            function()
            print("ok ", name)
        except AssertionError as error:
            failures += 1
            print("FAIL", name, error)
    sys.exit(1 if failures else 0)
