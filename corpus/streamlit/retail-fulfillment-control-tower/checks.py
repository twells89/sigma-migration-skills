#!/usr/bin/env python3
import filecmp
import json
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


CASE = Path(__file__).resolve().parent
ROOT = CASE.parents[2]
SKILL = ROOT / "plugins" / "streamlit-to-sigma" / "skills" / "streamlit-to-sigma"
FIXTURE = SKILL / "fixtures" / "retail-fulfillment-control-tower"
CONVERT = SKILL / "scripts" / "streamlit-convert.py"
ASSESS = (
    ROOT
    / "plugins"
    / "streamlit-to-sigma"
    / "skills"
    / "streamlit-assessment"
    / "scripts"
    / "assess-streamlit.py"
)
NORMALIZE = ROOT / "corpus" / "lib" / "corpus_check.py"


def grid_range(value):
    start, end = value.split("/")
    return int(start.strip()), int(end.strip())


def assert_no_sibling_collisions(layout):
    root = ET.fromstring(f"<Root>{layout.split('?>', 1)[-1]}</Root>")
    for parent in root.iter():
        children = [
            child
            for child in list(parent)
            if child.tag in {"Element", "Container", "TabbedContainer"}
        ]
        rectangles = []
        for child in children:
            if "gridColumn" not in child.attrib or "gridRow" not in child.attrib:
                continue
            c0, c1 = grid_range(child.attrib["gridColumn"])
            r0, r1 = grid_range(child.attrib["gridRow"])
            for other_id, oc0, oc1, or0, or1 in rectangles:
                overlap = c0 < oc1 and oc0 < c1 and r0 < or1 and or0 < r1
                assert not overlap, (
                    f"layout collision: {child.attrib.get('elementId')} and "
                    f"{other_id}"
                )
            rectangles.append(
                (child.attrib.get("elementId"), c0, c1, r0, r1)
            )


with tempfile.TemporaryDirectory() as tmp:
    output = Path(tmp) / "converted"
    subprocess.run(
        [
            "python3",
            str(CONVERT),
            str(FIXTURE),
            "--connection",
            "connection-placeholder",
            "--folder",
            "folder-placeholder",
            "--name",
            "Retail Fulfillment Control Tower Fixture",
            "--out-dir",
            str(output),
        ],
        check=True,
    )
    converted = {
        "data-model.json": output / "dm-result.json",
        "workbook.json": output / "workbook-result.json",
    }
    for name, source in converted.items():
        normalized = Path(tmp) / name
        subprocess.run(
            [
                "python3",
                str(NORMALIZE),
                "normalize",
                str(source),
                str(normalized),
            ],
            check=True,
        )
        assert filecmp.cmp(
            normalized,
            CASE / "golden" / name,
            shallow=False,
        ), f"{name} differs from committed golden"

    ir = json.loads((output / "streamlit-ir.json").read_text())
    assert len(ir["pages"]) == 4
    assert len(ir["queries"]) == 1
    assert ir["queries"][0]["dynamic"] is False
    assert len(ir["queries"][0]["columns"]) == 17
    assert len(ir["controls"]) == 22
    assert "dynamic-sql" not in {gap["code"] for gap in ir["gaps"]}
    assert "deferred-sidebar-filters" in ir["metadata"]["loweredPatterns"]
    assert any(
        gap["code"] == "deferred-form-state" and gap["resolved"]
        for gap in ir["gaps"]
    )

    result = json.loads((output / "workbook-result.json").read_text())
    assert result["warnings"] == []
    document = result["workbook"]["document"]
    elements = document["elements"]
    assert len([item for item in elements if item["kind"] == "navigation"]) == 4
    assert len(
        [
            item
            for item in elements
            if item["kind"] == "container"
            and item["id"].startswith("filter-card-")
        ]
    ) == 4
    assert len(
        [
            item
            for item in elements
            if item["kind"] == "control"
            and item["controlId"].endswith("-applied")
        ]
    ) == 5

    apply_buttons = [
        item for item in elements if item.get("text") == "Apply Filters"
    ]
    assert len(apply_buttons) == 4
    assert all(
        len(button["actions"][0]["effects"]) == 5
        and {
            effect["effect"]
            for effect in button["actions"][0]["effects"]
        }
        == {"set-control-value"}
        for button in apply_buttons
    )
    reset_buttons = [item for item in elements if item.get("text") == "Reset"]
    assert len(reset_buttons) == 4
    assert all(
        len(button["actions"][0]["effects"]) == 10
        and {
            effect["scope"]["type"]
            for effect in button["actions"][0]["effects"]
        }
        == {"control"}
        for button in reset_buttons
    )

    download = next(
        item for item in elements if item.get("text") == "Download CSV"
    )
    assert download["actions"][0]["effects"] == [
        {
            "effect": "export",
            "channel": "download",
            "source": {
                "type": "element",
                "element": next(
                    item["id"]
                    for item in elements
                    if item.get("name") == "Exception Rows"
                ),
            },
            "format": {"type": "csv"},
        }
    ]

    sort_control = next(
        item for item in elements if item.get("name") == "Sort by"
    )
    sort_effects = json.dumps(sort_control["actions"])
    assert '"effect": "if-else"' in sort_effects
    assert sort_effects.count('"effect": "custom-sort"') == 4
    assert {
        "ascending",
        "descending",
    } <= set(re.findall(r'"direction": "([^"]+)"', sort_effects))

    formulas = [
        column["formula"]
        for item in elements
        for column in item.get("columns", [])
    ]
    assert any("CountDistinct(" in formula for formula in formulas)
    assert any("Avg(If(" in formula for formula in formulas)
    assert any('DateTrunc("month"' in formula for formula in formulas)
    scatter = next(
        item for item in elements if item["kind"] == "scatter-chart"
    )
    assert scatter["source"].get("groupingId")
    charts = [
        item for item in elements if item["kind"].endswith("-chart")
    ]
    assert all(
        chart["xAxis"]["format"]["title"].get("text")
        for chart in charts
        if chart["kind"] != "kpi-chart"
    )
    assert_no_sibling_collisions(document["layout"])

    assessment_path = Path(tmp) / "assessment.json"
    subprocess.run(
        [
            "python3",
            str(ASSESS),
            str(FIXTURE),
            "--out",
            str(assessment_path),
        ],
        check=True,
    )
    assessment = json.loads(assessment_path.read_text())["projects"][0]
    assert assessment["readiness"] == "direct"
    assert assessment["complexity"]["class"] == "medium"
    assert assessment["migrationDisposition"] == "spec-native"

print(
    "Streamlit retail-fulfillment-control-tower reconverts byte-identical "
    "with deferred filters, navigation, sort, download, and collision-free layout"
)
