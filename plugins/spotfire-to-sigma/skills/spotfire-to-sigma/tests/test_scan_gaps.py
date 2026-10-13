#!/usr/bin/env python3
"""Structured census tests for scan_gaps.py."""
import json
import os
import subprocess
import sys
import tempfile
import unittest


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIXTURES = os.path.join(SKILL, "fixtures")
sys.path.insert(0, SCRIPTS)
import scan_gaps  # noqa: E402


def load(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as handle:
        return json.load(handle)


class ScanGapTests(unittest.TestCase):
    def setUp(self):
        self.manifest = load("spotfire-manifest.json")
        self.source_map = load("source-map.json")

    def test_complete_deterministic_census(self):
        first = scan_gaps.build_report(
            self.manifest, "spotfire-manifest.json", self.source_map
        )
        second = scan_gaps.build_report(
            self.manifest, "spotfire-manifest.json", self.source_map
        )
        self.assertEqual(
            json.dumps(first, sort_keys=True),
            json.dumps(second, sort_keys=True),
        )
        self.assertEqual(1, first["schema_version"])
        self.assertEqual(len(first["objects"]), first["summary"]["objects"])
        self.assertEqual(len(first["gaps"]), first["summary"]["gaps"])
        self.assertEqual(4, first["summary"]["by_type"]["table"])
        self.assertEqual(15, first["summary"]["by_type"]["column"])
        self.assertEqual(2, first["summary"]["by_type"]["page"])
        self.assertEqual(11, first["summary"]["by_type"]["visual"])
        self.assertEqual(2, first["summary"]["by_type"]["filter"])
        self.assertEqual(3, first["security"]["findings"])
        self.assertEqual("review-required", first["security"]["status"])
        self.assertTrue(all(
            set(obj) == {"type", "id", "name", "status", "evidence", "source"}
            and obj["source"]["artifact"]
            and "json_pointer" in obj["source"]
            for obj in first["objects"]
        ))

    def test_every_source_visual_is_accounted(self):
        report = scan_gaps.build_report(
            self.manifest, "manifest.json", self.source_map
        )
        source_ids = {
            visual["source_id"]
            for page in self.manifest["presentation"]["pages"]
            for visual in page["visuals"]
        }
        census_ids = {
            obj["id"] for obj in report["objects"]
            if obj["type"] == "visual"
        }
        self.assertEqual(source_ids, census_ids)

    def test_missing_source_mapping_is_an_unhandled_gap(self):
        source_map = dict(self.source_map)
        source_map["tables"] = dict(source_map["tables"])
        del source_map["tables"]["table:sales"]
        report = scan_gaps.build_report(
            self.manifest, "manifest.json", source_map
        )
        sales = next(obj for obj in report["objects"]
                     if obj["type"] == "table"
                     and obj["id"] == "table:sales")
        self.assertEqual("unhandled", sales["status"])
        self.assertTrue(any(
            gap.get("warning_id") == "SPOTFIRE-SOURCE-MAP-MISSING"
            and gap["object_id"] == "table:sales"
            for gap in report["gaps"]
        ))

    def test_strict_cli_fails_on_security_and_unsupported_features(self):
        with tempfile.TemporaryDirectory() as directory:
            output = os.path.join(directory, "gaps.json")
            result = subprocess.run(
                [
                    sys.executable,
                    os.path.join(SCRIPTS, "scan_gaps.py"),
                    os.path.join(FIXTURES, "spotfire-manifest.json"),
                    "--source-map", os.path.join(FIXTURES, "source-map.json"),
                    "--out", output,
                    "--strict",
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("RED:", result.stderr)
            self.assertTrue(os.path.isfile(output))

    def test_authoritative_nested_shape_has_full_object_census(self):
        with open(
            os.path.join(HERE, "fixtures", "valid_manifest.json"),
            encoding="utf-8",
        ) as handle:
            manifest = json.load(handle)
        source_map = {
            "connectionId": "connection",
            "database": "ANALYTICS",
            "schema": "PUBLIC",
            "tables": {"table:sales": {"table": "SALES"}},
        }
        report = scan_gaps.build_report(
            manifest, "valid_manifest.json", source_map
        )
        by_type = report["summary"]["by_type"]
        self.assertEqual(1, by_type["document"])
        self.assertEqual(1, by_type["source-operation"])
        self.assertEqual(1, by_type["axis"])
        self.assertEqual(1, by_type["filtering-scheme"])
        self.assertEqual(1, by_type["bookmark"])
        self.assertEqual(3, by_type["security"])
        self.assertEqual(3, report["security"]["findings"])
        self.assertEqual(3, report["security"]["signals"])


if __name__ == "__main__":
    unittest.main()
