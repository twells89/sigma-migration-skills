#!/usr/bin/env python3
import filecmp
import json
import subprocess
import tempfile
from pathlib import Path


CASE = Path(__file__).resolve().parent
ROOT = CASE.parents[2]
SKILL = ROOT / "plugins" / "streamlit-to-sigma" / "skills" / "streamlit-to-sigma"
CONVERT = SKILL / "scripts" / "streamlit-convert.py"
FIXTURE = SKILL / "fixtures" / "simple-retail"
NORMALIZE = ROOT / "corpus" / "lib" / "corpus_check.py"

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
            "Streamlit Retail Fixture",
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
        golden = CASE / "golden" / name
        if not filecmp.cmp(normalized, golden, shallow=False):
            raise SystemExit(f"{name} differs from committed golden")

    workbook_result = json.loads((output / "workbook-result.json").read_text())
    workbook = workbook_result["workbook"]
    document = workbook["document"]
    assert document["kind"] == "workbook"
    assert "elements" not in document["pages"][0]
    assert "LayoutElement" not in document["layout"]
    assert "GridContainer" not in document["layout"]
    assert json.loads((output / "gaps.json").read_text()) == []

print("Streamlit simple-retail reconverts byte-identical to both goldens")
