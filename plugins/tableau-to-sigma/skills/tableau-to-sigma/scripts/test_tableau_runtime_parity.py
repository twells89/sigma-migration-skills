import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "tableau-runtime-parity.py"
SPEC = importlib.util.spec_from_file_location("tableau_runtime_parity", SCRIPT)
parity = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = parity
SPEC.loader.exec_module(parity)


class TableauRuntimeParityTest(unittest.TestCase):
    def test_manifest_covers_layout_gaps_and_column_independent_conversion(self):
        cases = parity.load_cases(parity.DEFAULT_CASES)
        self.assertEqual(6, len(cases))
        self.assertEqual(
            {"layout", "gaps", "conversion"},
            {case.kind for case in cases},
        )
        self.assertTrue(all(case.twb.is_file() for case in cases))
        self.assertTrue(
            all(
                case.twb.is_relative_to(parity.REPO_ROOT / "corpus" / "tableau")
                for case in cases
            )
        )

    def test_conversion_ids_normalize_without_losing_reference_topology(self):
        ruby = {
            "pages": [
                {
                    "id": "ruby-page",
                    "elements": [
                        {
                            "id": "ruby-element",
                            "relationships": [
                                {
                                    "id": "ruby-rel",
                                    "targetElementId": "ruby-target",
                                }
                            ],
                        },
                        {"id": "ruby-target"},
                    ],
                }
            ]
        }
        python = {
            "pages": [
                {
                    "id": "python-page",
                    "elements": [
                        {
                            "id": "python-element",
                            "relationships": [
                                {
                                    "id": "python-rel",
                                    "targetElementId": "python-target",
                                }
                            ],
                        },
                        {"id": "python-target"},
                    ],
                }
            ]
        }
        self.assertEqual(parity.normalize_ids(ruby), parity.normalize_ids(python))
        python["pages"][0]["elements"][0]["relationships"][0][
            "targetElementId"
        ] = "python-element"
        self.assertNotEqual(parity.normalize_ids(ruby), parity.normalize_ids(python))

    def test_normalizer_only_masks_nondeterministic_values(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            value = {
                "generated_at": "2026-09-01T10:00:00Z",
                "fixture": str(root / "input.twb"),
                "source": {
                    "path": ["PARITY_DB", "PARITY_SCHEMA", "ORDER_FACT"]
                },
                "geometry": {"x": 1.0, "width": 12.5},
                "unused": None,
            }
            normalized = parity.normalize_artifact(
                "layout",
                "dashboard-layout.json",
                value,
                (root,),
            )
        self.assertEqual("<TIMESTAMP>", normalized["generated_at"])
        self.assertEqual("<WORKDIR>/input.twb", normalized["fixture"])
        self.assertEqual(
            ["PARITY_DB", "PARITY_SCHEMA", "ORDER_FACT"],
            normalized["source"]["path"],
        )
        self.assertEqual({"x": 1, "width": 12.5}, normalized["geometry"])
        self.assertNotIn("unused", normalized)

    def test_gap_feature_order_is_not_a_semantic_difference(self):
        ruby = {
            "detected_features": [
                {"name": "B", "status": "hint"},
                {"name": "A", "status": "auto"},
            ]
        }
        python = {
            "detected_features": list(reversed(ruby["detected_features"]))
        }
        self.assertEqual(
            parity.normalize_artifact("gaps", "gaps.json", ruby, ()),
            parity.normalize_artifact("gaps", "gaps.json", python, ()),
        )

    def test_diff_names_case_runtime_and_artifact(self):
        rendered = parity.artifact_diff(
            "layout-case",
            "dashboard-layout.json",
            {"kind": "bar"},
            {"kind": "line"},
            limit=40,
        )
        self.assertIn("layout-case/ruby/dashboard-layout.json", rendered)
        self.assertIn("layout-case/python/dashboard-layout.json", rendered)
        self.assertIn('-  "kind": "bar"', rendered)
        self.assertIn('+  "kind": "line"', rendered)

    def test_credentials_are_removed_from_child_process_environment(self):
        with mock.patch.dict(
            os.environ,
            {
                "SIGMA_API_TOKEN": "do-not-pass",
                "TABLEAU_PAT_SECRET": "do-not-pass",
                "PARITY_SENTINEL": "keep",
            },
            clear=False,
        ):
            environment = parity.clean_environment()
        self.assertNotIn("SIGMA_API_TOKEN", environment)
        self.assertNotIn("TABLEAU_PAT_SECRET", environment)
        self.assertEqual("keep", environment["PARITY_SENTINEL"])

    def test_list_does_not_require_runtimes(self):
        stdout = io.StringIO()
        with mock.patch.object(parity, "check_runtimes") as check:
            with contextlib.redirect_stdout(stdout):
                code = parity.main(["--list"])
        self.assertEqual(0, code)
        check.assert_not_called()
        self.assertIn("layout-partner-crosstab-controls", stdout.getvalue())
        self.assertIn("conversion-orders-overview", stdout.getvalue())

    def test_missing_runtime_is_a_named_blocker(self):
        stderr = io.StringIO()
        with mock.patch.object(parity, "check_runtimes", return_value=["ruby"]):
            with contextlib.redirect_stderr(stderr):
                code = parity.main(["--case", "gaps-union-wildcard-seed"])
        self.assertEqual(2, code)
        self.assertIn("BLOCKED", stderr.getvalue())
        self.assertIn("ruby", stderr.getvalue())

    def test_manifest_rejects_fixture_outside_repo(self):
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "cases.json"
            manifest.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "cases": [
                            {
                                "id": "escape",
                                "kind": "layout",
                                "twb": "../../outside.twb",
                                "artifacts": ["dashboard-layout.json"],
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(parity.HarnessError, "escapes the repo"):
                parity.load_cases(manifest)


if __name__ == "__main__":
    unittest.main(verbosity=2)
