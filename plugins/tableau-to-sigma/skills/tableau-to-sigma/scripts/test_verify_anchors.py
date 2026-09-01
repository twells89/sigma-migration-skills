import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "verify-anchors.py"
spec = importlib.util.spec_from_file_location("verify_anchors_python", SCRIPT)
verify_anchors = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_anchors)


class AnchorValueTest(unittest.TestCase):
    def test_printed_precision_and_scaled_candidates_match(self):
        parsed = verify_anchors.parse_printed("12,345B")
        self.assertEqual(12_345_000_000_000.0, parsed["value"])
        self.assertEqual(500_000_000.0, parsed["tolerance"])
        self.assertTrue(
            verify_anchors.printed_match("12,345B", 12_344_800_000_000.0)
        )
        self.assertTrue(verify_anchors.printed_match("12,345B", 12_345.0))
        self.assertFalse(verify_anchors.printed_match("12,345B", 1.2e12))

    def test_currency_percent_and_accounting_forms(self):
        self.assertTrue(verify_anchors.printed_match("$733,215.26", 733_215.264))
        self.assertTrue(verify_anchors.printed_match("-2%", -0.02))
        self.assertTrue(verify_anchors.printed_match("(12.3%)", -12.3))
        self.assertFalse(verify_anchors.printed_match("-2%", 2.0))

    def test_hint_scopes_numeric_and_text_anchors(self):
        tiles = verify_anchors.normalize_actuals(
            {
                "tiles": [
                    {"name": "Total Stores", "rows": [[104]]},
                    {
                        "name": "Sales Detail",
                        "displayed": False,
                        "is_feeder": True,
                        "rows": [[1040], ["United Widgets"]],
                    },
                    {"name": "Top Accounts", "rows": [["Acme Holdings", 900]]},
                ]
            }
        )
        verdict = verify_anchors.verify(
            [
                {
                    "id": "n1",
                    "raw": "1,040",
                    "label": "Total Stores",
                    "sigma_element_hint": "Total Stores",
                },
                {
                    "id": "t1",
                    "raw": "United Widgets",
                    "kind": "text",
                    "label": "top member",
                    "sigma_element_hint": "Top Accounts",
                },
            ],
            tiles,
        )
        self.assertFalse(verdict["pass"])
        self.assertEqual({"n1", "t1"}, {item["id"] for item in verdict["missing"]})

    def test_explicit_tolerance_is_required_and_recorded(self):
        anchors = [{"id": "a1", "raw": "104", "label": "Total Stores"}]
        tiles = verify_anchors.normalize_actuals({"Total Stores": [[106]]})
        exact = verify_anchors.verify(anchors, tiles)
        tolerant = verify_anchors.verify(anchors, tiles, relative_tolerance=0.03)
        self.assertFalse(exact["pass"])
        self.assertTrue(tolerant["pass"])
        self.assertEqual(1, tolerant["matched_via_tolerance"])
        self.assertEqual(
            {"relative": 0.03},
            tolerant["detail"][0]["tolerance_used"],
        )

    def test_empty_or_unavailable_displayed_tile_fails_closed(self):
        anchors = [{"id": "a1", "raw": "104", "label": "KPI"}]
        empty_tiles = verify_anchors.normalize_actuals(
            {"KPI": [[104]], "Empty Chart": []}
        )
        unavailable_tiles = verify_anchors.normalize_actuals(
            {
                "tiles": [
                    {"name": "KPI", "rows": [[104]]},
                    {"name": "Timed Out", "status": "timeout"},
                ]
            }
        )
        empty = verify_anchors.verify(anchors, empty_tiles)
        unavailable = verify_anchors.verify(anchors, unavailable_tiles)
        self.assertFalse(empty["pass"])
        self.assertEqual("Empty Chart", empty["dashboard_tiles_empty"][0]["name"])
        self.assertFalse(unavailable["pass"])
        self.assertEqual(
            "Timed Out", unavailable["dashboard_tiles_unavailable"][0]["name"]
        )


class AnchorCliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.workdir = Path(self.tmp.name)
        self.anchors_path = self.workdir / "source-anchors.json"
        self.actuals_path = self.workdir / "parity-actuals.json"
        self.verdict_path = self.workdir / "anchors-verdict.json"

    def tearDown(self):
        self.tmp.cleanup()

    def write_anchors(self, raw="104"):
        self.anchors_path.write_text(
            json.dumps(
                {
                    "source_image": "dashboards/source.png",
                    "anchors": [
                        {
                            "id": "a1",
                            "panel": "KPI",
                            "label": "Total Stores",
                            "raw": raw,
                            "kind": "number",
                            "provenance": "view-csv",
                            "sigma_element_hint": "KPI",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

    def run_cli(self, *extra):
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--workdir",
                str(self.workdir),
                *extra,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_collected_actuals_emit_passing_verdict_and_hash_lock(self):
        self.write_anchors()
        self.actuals_path.write_text(json.dumps({"KPI": [[104]]}), encoding="utf-8")
        completed = self.run_cli()
        self.assertEqual(0, completed.returncode, completed.stderr)
        verdict = json.loads(self.verdict_path.read_text(encoding="utf-8"))
        lock = json.loads(
            (self.workdir / "source-anchors.lock.json").read_text(encoding="utf-8")
        )
        self.assertTrue(verdict["pass"])
        self.assertTrue(verdict["anchor_lock_valid"])
        self.assertEqual(1, verdict["valued_matched"])
        self.assertEqual(lock["anchors_sha256"], verdict["source_anchor_values_sha256"])
        self.assertEqual(
            verify_anchors.file_sha256(self.anchors_path),
            verdict["source_anchors_sha256"],
        )

    def test_changed_locked_value_is_rejected_without_relocking(self):
        self.write_anchors("104")
        self.actuals_path.write_text(json.dumps({"KPI": [[104]]}), encoding="utf-8")
        first = self.run_cli()
        self.assertEqual(0, first.returncode, first.stderr)
        lock_path = self.workdir / "source-anchors.lock.json"
        original_lock = lock_path.read_bytes()

        self.write_anchors("106")
        self.actuals_path.write_text(json.dumps({"KPI": [[106]]}), encoding="utf-8")
        second = self.run_cli()
        self.assertEqual(1, second.returncode)
        verdict = json.loads(self.verdict_path.read_text(encoding="utf-8"))
        self.assertFalse(verdict["pass"])
        self.assertFalse(verdict["anchor_lock_valid"])
        self.assertEqual(
            [{"id": "a1", "from": "104", "to": "106"}],
            verdict["changed_anchors"],
        )
        self.assertEqual(original_lock, lock_path.read_bytes())

    def test_empty_displayed_tile_exits_one_even_when_anchor_matches(self):
        self.write_anchors()
        self.actuals_path.write_text(
            json.dumps(
                {
                    "tiles": [
                        {"id": "kpi", "name": "KPI", "rows": [[104]]},
                        {"id": "trend", "name": "Revenue Trend", "rows": []},
                        {
                            "id": "master",
                            "name": "Master",
                            "displayed": False,
                            "is_feeder": True,
                            "rows": [],
                        },
                    ]
                }
            ),
            encoding="utf-8",
        )
        completed = self.run_cli()
        self.assertEqual(1, completed.returncode)
        verdict = json.loads(self.verdict_path.read_text(encoding="utf-8"))
        self.assertTrue(verdict["anchor_values_pass"])
        self.assertFalse(verdict["tiles_all_nonempty"])
        self.assertEqual(["trend"], [row["id"] for row in verdict["dashboard_tiles_empty"]])
        self.assertIn("EMPTY displayed tile", completed.stderr)

    def test_malformed_actuals_still_emit_failed_verdict(self):
        self.write_anchors()
        self.actuals_path.write_text("{not-json", encoding="utf-8")
        completed = self.run_cli()
        self.assertEqual(2, completed.returncode)
        verdict = json.loads(self.verdict_path.read_text(encoding="utf-8"))
        self.assertFalse(verdict["pass"])
        self.assertTrue(verdict["errors"])

    def test_cli_tolerance_is_explicit_in_verdict(self):
        self.write_anchors("104")
        self.actuals_path.write_text(json.dumps({"KPI": [[106]]}), encoding="utf-8")
        completed = self.run_cli("--tolerance", "0.03")
        self.assertEqual(0, completed.returncode, completed.stderr)
        verdict = json.loads(self.verdict_path.read_text(encoding="utf-8"))
        self.assertEqual(
            {"relative": 0.03, "absolute": None},
            verdict["explicit_tolerance"],
        )
        self.assertEqual(1, verdict["matched_via_tolerance"])


if __name__ == "__main__":
    unittest.main()
