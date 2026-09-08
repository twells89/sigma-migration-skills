#!/usr/bin/env python3
"""Contract coverage for every documented Qlik chart mapping."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
BUILDER = os.path.join(SCRIPTS, "build-sigma-workbook.py")
DISCOVERY = os.path.join(SCRIPTS, "qlik-discover.py")
CATALOG = os.path.join(SKILL, "refs", "catalogs", "viz-kind.json")

sys.path.insert(0, os.path.join(SCRIPTS, "lib"))
spec = importlib.util.spec_from_file_location("qlik_workbook_builder", BUILDER)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
discovery_spec = importlib.util.spec_from_file_location("qlik_discovery", DISCOVERY)
discovery = importlib.util.module_from_spec(discovery_spec)
discovery_spec.loader.exec_module(discovery)


EXPECTED = {
    "barchart": "bar-chart",
    "boxplot": "box-chart",
    "bulletchart": "progress",
    "combochart": "combo-chart",
    "distributionplot": "box-chart",
    "gauge": "progress",
    "histogram": "bar-chart",
    "kpi": "kpi-chart",
    "linechart": "line-chart",
    "map": "region-map",
    "mekkochart": "bar-chart",
    "piechart": "pie-chart",
    "pivot-table": "pivot-table",
    "scatterplot": "scatter-chart",
    "table": "table",
    "treemap": "bar-chart",
    "waterfallchart": "waterfall-chart",
}
APPROXIMATIONS = {"bulletchart", "histogram", "mekkochart", "treemap"}
RESOLVE = builder.Resolver([
    ("Category", "CATEGORY"),
    ("Segment", "SEGMENT"),
    ("State", "STATE"),
    ("Score", "SCORE"),
    ("Revenue", "REVENUE"),
    ("Cost", "COST"),
    ("Quantity", "QUANTITY"),
])


def chart(viz_type):
    dims = [["CATEGORY"]]
    measures = ["Sum(REVENUE)"]
    if viz_type in ("kpi", "gauge", "bulletchart"):
        dims = []
    elif viz_type == "map":
        dims = [["STATE"]]
    elif viz_type in ("pivot-table", "boxplot", "distributionplot", "mekkochart", "treemap"):
        dims = [["CATEGORY"], ["SEGMENT"]]
    elif viz_type == "scatterplot":
        measures = ["Sum(REVENUE)", "Sum(COST)", "Sum(QUANTITY)"]
    elif viz_type == "combochart":
        measures = ["Sum(REVENUE)", "Sum(COST)"]
    elif viz_type == "histogram":
        dims, measures = [["SCORE"]], []
    record = {
        "id": viz_type,
        "vizType": viz_type,
        "title": viz_type,
        "dimensions": dims,
        "dimLabels": [None] * len(dims),
        "dimNullSuppression": [False] * len(dims),
        "measures": measures,
        "measureLabels": [None] * len(measures),
        "measureFmts": [None] * len(measures),
        "sort": {"interColumnSortOrder": [], "dimensions": [[]] * len(dims), "measures": [{}] * len(measures)},
        "gauge": {"min": 0, "max": 100, "shape": "bar"},
    }
    if viz_type == "combochart":
        record["seriesTypes"] = ["bar", "line"]
    return record


def test_catalog_is_complete():
    rows = json.load(open(CATALOG, encoding="utf-8"))["rows"]
    actual = {row["source"]: row["sigma"] for row in rows}
    assert actual == EXPECTED, f"chart catalog drift:\nactual={actual}\nexpected={EXPECTED}"
    flagged = {row["source"] for row in rows if row.get("approximation")}
    assert flagged == APPROXIMATIONS


def test_every_mapping_emits_its_contract_shape():
    for source, target in EXPECTED.items():
        builder._ids.clear()
        builder._SCATTER_SRC.clear()
        warnings = []
        element = builder.build_element(chart(source), RESOLVE, warnings)
        assert element is not None, f"{source} was dropped: {warnings}"
        assert element["kind"] == target, f"{source} -> {element['kind']}, expected {target}"
        if source in APPROXIMATIONS:
            assert any("EXPLICIT APPROXIMATION" in warning for warning in warnings), (source, warnings)

        if source in ("barchart", "linechart", "waterfallchart"):
            assert element["xAxis"]["columnId"] and element["yAxis"]["columnIds"]
        elif source in ("boxplot", "distributionplot"):
            assert element["splitBy"]["columnId"] and element["yAxis"]["columnIds"]
            if source == "distributionplot":
                assert element["boxShape"] == {"points": "all-points"}
        elif source in ("bulletchart", "gauge"):
            assert element["mode"] == "value" and element["value"].startswith("Sum(")
        elif source == "combochart":
            assert element["yAxis"]["columnIds"][1]["type"] == "line"
        elif source == "histogram":
            assert any(column["formula"] == "Count([Master/Score])" for column in element["columns"])
        elif source == "kpi":
            assert element["value"]["columnId"]
        elif source == "map":
            assert element["region"]["columnId"] and element["region"]["regionType"] == "us-state"
        elif source in ("mekkochart", "treemap"):
            assert element["color"]["by"] == "category"
            assert element["stacking"] == ("normalized" if source == "mekkochart" else "stacked")
        elif source == "piechart":
            assert element["value"]["columnId"] and element["color"]["columnId"]
        elif source == "pivot-table":
            assert element["rowsBy"] and element["columnsBy"] and element["values"]
        elif source == "scatterplot":
            assert element["source"]["groupingId"] and element["size"]["columnId"]
            assert len(builder._SCATTER_SRC) == 1
        elif source == "table":
            assert element["groupings"][0]["groupBy"] and element["groupings"][0]["calculations"]


def test_full_catalog_builds_one_workbook():
    with tempfile.TemporaryDirectory() as directory:
        charts_path = os.path.join(directory, "charts.json")
        denorm_path = os.path.join(directory, "denorm.json")
        spec_path = os.path.join(directory, "spec.json")
        source_charts = [chart(source) for source in EXPECTED]
        source_charts.append({"id": "about", "vizType": "text-image", "title": "About",
                              "markdown": "Authored source narrative."})
        json.dump(source_charts, open(charts_path, "w", encoding="utf-8"))
        json.dump({"element": {"columns": [
            {"name": name, "formula": f"[Custom SQL/{raw}]"}
            for name, raw in [
                ("Category", "CATEGORY"), ("Segment", "SEGMENT"), ("State", "STATE"),
                ("Score", "SCORE"), ("Revenue", "REVENUE"), ("Cost", "COST"),
                ("Quantity", "QUANTITY"),
            ]
        ]}}, open(denorm_path, "w", encoding="utf-8"))
        run = subprocess.run([
            sys.executable, BUILDER,
            "--charts", charts_path,
            "--denorm", denorm_path,
            "--dm-id", "dm-chart-contract",
            "--denorm-element-id", "el-chart-contract",
            "--name", "Qlik chart contract",
            "--dry-run",
            "--spec-out", spec_path,
            "--out", os.path.join(directory, "result.json"),
            "--layout-out", os.path.join(directory, "layout.xml"),
            "--element-map", os.path.join(directory, "element-map.json"),
        ], capture_output=True, text=True, encoding="utf-8", errors="replace")
        assert run.returncode == 0, run.stdout + run.stderr
        document = json.load(open(spec_path, encoding="utf-8"))["document"]
        elements = {element["id"]: element for element in document["elements"]}
        for source, target in EXPECTED.items():
            element_id = "el-" + source.replace("-", "")
            assert elements[element_id]["kind"] == target, (source, elements.get(element_id))
        assert elements["el-about"]["kind"] == "text"
        assert "Authored source narrative." in elements["el-about"]["body"]
        coverage = json.load(open(os.path.join(directory, "workbook-coverage.json"), encoding="utf-8"))
        assert coverage["status"] == "PASS"
        assert coverage["sourceVisuals"] == len(EXPECTED)
        assert coverage["unbuiltSourceVisualIds"] == []


def test_auto_chart_shape_mapping():
    cases = [
        ([], ["Sum(REVENUE)"], "kpi-chart"),
        ([["CATEGORY"]], ["Sum(REVENUE)"], "bar-chart"),
        ([["ORDER_DATE"]], ["Sum(REVENUE)"], "line-chart"),
        ([["CATEGORY"], ["SEGMENT"]], ["Sum(REVENUE)"], "table"),
    ]
    auto_resolve = builder.Resolver([
        ("Category", "CATEGORY"), ("Segment", "SEGMENT"),
        ("Order Date", "ORDER_DATE"), ("Revenue", "REVENUE"),
    ])
    for dimensions, measures, expected in cases:
        record = chart("auto-chart")
        record.update({
            "dimensions": dimensions,
            "dimLabels": [None] * len(dimensions),
            "dimNullSuppression": [False] * len(dimensions),
            "measures": measures,
            "measureLabels": [None] * len(measures),
            "measureFmts": [None] * len(measures),
        })
        builder._ids.clear()
        element = builder.build_element(record, auto_resolve, [])
        assert element["kind"] == expected, (dimensions, element["kind"], expected)


def test_live_presentation_subtypes_and_content():
    presentation = discovery._presentation({
        "lineType": "area", "donut": {"showAsDonut": True},
    })
    assert presentation == {"lineType": "area", "showAsDonut": True}
    assert discovery._combo_series({"qDef": {}}) == "bar"
    assert discovery._combo_series({"qDef": {"series": {"type": "line"}}}) == "line"
    assert discovery._content_fields({"markdown": "Source text"}, "text-image") == {
        "markdown": "Source text"
    }

    area = chart("linechart")
    area["presentation"] = {"lineType": "area"}
    assert builder.build_element(area, RESOLVE, [])["kind"] == "area-chart"

    donut = chart("piechart")
    donut["presentation"] = {"showAsDonut": True}
    assert builder.build_element(donut, RESOLVE, [])["kind"] == "donut-chart"

    bars = chart("combochart")
    bars["seriesTypes"] = ["bar", "bar"]
    bars["presentation"] = {"grouping": "grouped"}
    assert bars["seriesTypes"] == ["bar", "bar"]
    combo = builder.build_element(bars, RESOLVE, [])
    measure_ids = [column["id"] for column in combo["columns"] if column["id"].startswith("y")]
    assert combo["kind"] == "bar-chart"
    assert combo["yAxis"]["columnIds"] == measure_ids
    assert combo["stacking"] == "none"
    assert combo["xAxis"]["sort"] == {"by": measure_ids[0], "direction": "descending"}

    mixed = chart("combochart")
    mixed["seriesTypes"] = ["bar", "line"]
    mixed_element = builder.build_element(mixed, RESOLVE, [])
    assert mixed_element["kind"] == "combo-chart"
    assert mixed_element["yAxis"]["columnIds"][1]["type"] == "line"

    auto_sorted_area = chart("linechart")
    auto_sorted_area["presentation"] = {"lineType": "area"}
    area_element = builder.build_element(auto_sorted_area, RESOLVE, [])
    assert area_element["xAxis"]["sort"]["direction"] == "descending"

    grouped = chart("barchart")
    grouped["presentation"] = {"grouping": "grouped"}
    assert "stacking" not in builder.build_element(grouped, RESOLVE, [])

    horizontal = chart("barchart")
    horizontal["presentation"] = {"orientation": "horizontal"}
    horizontal_warnings = []
    assert "orientation" not in builder.build_element(horizontal, RESOLVE, horizontal_warnings)
    assert any("HORIZONTAL ORIENTATION GAP" in warning for warning in horizontal_warnings)

    colored = chart("barchart")
    colored["color"] = {"mode": "byDimension"}
    colored_element = builder.build_element(colored, RESOLVE, [])
    assert colored_element["color"]["column"] != colored_element["xAxis"]["columnId"]

    expression_colored = chart("linechart")
    expression_colored["color"] = {"mode": "byExpression", "singleColor": "#4477aa"}
    assert builder.build_element(expression_colored, RESOLVE, [])["color"] == {
        "by": "single", "value": "#4477aa"
    }

    refmarks = builder.qlik_refmarks({
        "refLines": {"x": [], "y": [{"value": 0.85, "color": 2}]}
    })
    assert refmarks[0]["line"]["color"] == "#46C646"


def test_sparse_singleton_band_expands_to_full_width():
    layout, _ = builder.banded_page(
        "page", [["pivot", 1, 13, 1, 11, {"kind": "pivot-table"}]], "Charts"
    )
    assert 'elementId="pivot" gridColumn="1 / 25"' in layout


if __name__ == "__main__":
    for name, function in sorted((name, value) for name, value in globals().items() if name.startswith("test_")):
        function()
        print("ok ", name)
