#!/usr/bin/env python3
"""Offline contract tests for screenshot-driven Qlik design iteration."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SKILL = Path(__file__).resolve().parents[1]
SCRIPTS = SKILL / "scripts"
sys.path.insert(0, str(SCRIPTS))

import qlik_design_manifest as design  # noqa: E402


class DesignManifestTests(unittest.TestCase):
    def setUp(self):
        self.charts = [
            {
                "id": "chart-1",
                "vizType": "barchart",
                "title": "Revenue",
                "dimensions": [["Region"]],
                "measures": ["Sum(Revenue)"],
            }
        ]
        self.sheets = [
            {
                "sheetId": "sheet-1",
                "title": "Overview",
                "columns": 24,
                "rows": 12,
                "cells": [
                    {
                        "objectId": "chart-1",
                        "type": "barchart",
                        "col": 0,
                        "row": 0,
                        "colspan": 12,
                        "rowspan": 6,
                    }
                ],
            }
        ]

    def test_seed_requires_explicit_image_review(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "sheet-1.png"
            image.write_bytes(b"fixture")
            manifest = design.seed_manifest(
                self.charts,
                self.sheets,
                {"sheet-1": image},
            )
            self.assertEqual("needs-review", manifest["status"])
            self.assertFalse(manifest["pages"][0]["reviewed"])
            self.assertFalse(manifest["pages"][0]["tiles"][0]["reviewed"])
            with self.assertRaisesRegex(
                design.ManifestError,
                "status must be 'approved'",
            ):
                design.validate_manifest(manifest, self.charts, self.sheets)

    def test_approved_manifest_overrides_kind_layout_and_presentation(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "sheet-1.png"
            image.write_bytes(b"fixture")
            manifest = design.seed_manifest(
                self.charts,
                self.sheets,
                {"sheet-1": image},
            )
            manifest["status"] = "approved"
            page = manifest["pages"][0]
            page["reviewed"] = True
            page["title"] = "Executive Overview"
            tile = page["tiles"][0]
            tile.update(
                {
                    "reviewed": True,
                    "kind": "area-chart",
                    "title": "Revenue Trend",
                    "orientation": "horizontal",
                    "legend": "hidden",
                    "grid": {
                        "col": 2,
                        "row": 1,
                        "colspan": 20,
                        "rowspan": 10,
                    },
                    "notes": ["Matched source screenshot."],
                }
            )
            charts, sheets, notes = design.apply_manifest(
                manifest,
                self.charts,
                self.sheets,
            )
            self.assertEqual("area-chart", charts[0]["designKind"])
            self.assertEqual("Revenue Trend", charts[0]["title"])
            self.assertEqual(
                "horizontal",
                charts[0]["presentation"]["orientation"],
            )
            self.assertFalse(charts[0]["legend"]["show"])
            self.assertEqual("Executive Overview", sheets[0]["title"])
            self.assertEqual(2, sheets[0]["cells"][0]["col"])
            self.assertEqual(
                ["sheet-1/chart-1: Matched source screenshot."],
                notes,
            )

    def test_manifest_rejects_unknown_or_out_of_bounds_tiles(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "sheet-1.png"
            image.write_bytes(b"fixture")
            manifest = design.seed_manifest(
                self.charts,
                self.sheets,
                {"sheet-1": image},
            )
            manifest["status"] = "approved"
            manifest["pages"][0]["reviewed"] = True
            tile = manifest["pages"][0]["tiles"][0]
            tile["reviewed"] = True
            tile["objectId"] = "missing"
            tile["grid"]["colspan"] = 30
            with self.assertRaises(design.ManifestError) as error:
                design.validate_manifest(manifest, self.charts, self.sheets)
            self.assertIn("unknown objectId", str(error.exception))
            self.assertIn("grid must fit", str(error.exception))

    def test_builder_consumes_approved_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = root / "sheet-1.png"
            image.write_bytes(b"fixture")
            manifest = design.seed_manifest(
                self.charts,
                self.sheets,
                {"sheet-1": image},
            )
            manifest["status"] = "approved"
            manifest["pages"][0]["reviewed"] = True
            tile = manifest["pages"][0]["tiles"][0]
            tile.update(
                {
                    "reviewed": True,
                    "kind": "area-chart",
                    "title": "Screenshot Revenue",
                    "orientation": "keep",
                    "legend": "hidden",
                }
            )
            files = {
                "charts.json": self.charts,
                "layout.json": self.sheets,
                "design-manifest.json": manifest,
                "denorm.json": {
                    "element": {
                        "columns": [
                            {
                                "name": "Region",
                                "formula": "[Custom SQL/REGION]",
                            },
                            {
                                "name": "Revenue",
                                "formula": "[Custom SQL/REVENUE]",
                            },
                        ]
                    }
                },
            }
            for filename, value in files.items():
                (root / filename).write_text(
                    json.dumps(value),
                    encoding="utf-8",
                )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS / "build-sigma-workbook.py"),
                    "--charts",
                    str(root / "charts.json"),
                    "--layout",
                    str(root / "layout.json"),
                    "--denorm",
                    str(root / "denorm.json"),
                    "--dm-id",
                    "dm-1",
                    "--denorm-element-id",
                    "denorm-1",
                    "--name",
                    "Screenshot Build",
                    "--design-manifest",
                    str(root / "design-manifest.json"),
                    "--synth-controls",
                    "off",
                    "--dry-run",
                    "--out",
                    str(root / "result.json"),
                    "--spec-out",
                    str(root / "spec.json"),
                    "--layout-out",
                    str(root / "layout.xml"),
                    "--element-map",
                    str(root / "element-map.json"),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            spec = json.loads((root / "spec.json").read_text())
            element = next(
                item for item in spec["document"]["elements"]
                if item.get("id") == "el-chart1"
            )
            self.assertEqual("area-chart", element["kind"])
            self.assertEqual("Screenshot Revenue", element["name"])
            self.assertEqual(
                "Executive Overview"
                if manifest["pages"][0]["title"] == "Executive Overview"
                else "Overview",
                spec["document"]["pages"][1]["name"],
            )


if __name__ == "__main__":
    unittest.main()
