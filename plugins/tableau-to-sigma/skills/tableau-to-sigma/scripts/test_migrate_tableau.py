import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "migrate-tableau.py"
spec = importlib.util.spec_from_file_location("migrate_tableau_python", SCRIPT)
migrate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migrate)


class MigrateTableauPythonTest(unittest.TestCase):
    @staticmethod
    def embedded_classification():
        return {
            "classification": "embedded-file-extract",
            "datasources": [
                {
                    "name": "federated.extract",
                    "caption": "Sample Extract",
                    "classification": "embedded-file-extract",
                    "embedded_classes": ["hyper"],
                    "hyper_files": ["Sample.hyper"],
                }
            ],
        }

    @staticmethod
    def landing_args(**overrides):
        values = {
            "skip_extract_landing": None,
            "no_auto_land": True,
            "db": "DB",
            "schema": "LANDING",
            "connection": "sigma-connection",
            "name": "Fixture",
        }
        values.update(overrides)
        return SimpleNamespace(**values)

    def test_share_url_routes_to_python_discovery_url_flag(self):
        url = "https://tableau.example.com/#/site/example/views/Fixture/Overview"
        self.assertEqual(["--workbook-url", url], migrate.source_arguments(url))

    def test_named_workbook_routes_to_name_flag(self):
        self.assertEqual(
            ["--workbook-name", "Fixture Workbook"],
            migrate.source_arguments("Fixture Workbook"),
        )

    def test_fact_element_resolves_from_server_readback(self):
        readback = {
            "pages": [
                {
                    "elements": [
                        {"id": "fact-live", "name": "FACT"},
                        {"id": "dim-live", "name": "DIM"},
                    ]
                }
            ]
        }
        self.assertEqual("fact-live", migrate.find_element_id(readback, "FACT"))

    def test_reused_fact_resolves_by_unique_column_coverage(self):
        readback = {
            "pages": [
                {
                    "elements": [
                        {
                            "id": "compatible-live",
                            "name": "Different Name",
                            "columns": [
                                {"name": "Region"},
                                {"name": "Sales"},
                                {"name": "Extra"},
                            ],
                        },
                        {
                            "id": "partial-live",
                            "name": "Partial",
                            "columns": [{"name": "Region"}],
                        },
                    ]
                }
            ]
        }
        self.assertEqual(
            "compatible-live",
            migrate.find_element_id(
                readback, "ORDER_FACT", ["Region", "Sales"]
            ),
        )

    def test_warehouse_paths_are_unique_and_sorted(self):
        model = {
            "pages": [
                {
                    "elements": [
                        {
                            "source": {
                                "kind": "warehouse-table",
                                "path": ["DB", "S", "B"],
                            }
                        },
                        {
                            "source": {
                                "kind": "warehouse-table",
                                "path": ["DB", "S", "A"],
                            }
                        },
                        {
                            "source": {
                                "kind": "warehouse-table",
                                "path": ["DB", "S", "B"],
                            }
                        },
                    ]
                }
            ]
        }
        self.assertEqual(
            [["DB", "S", "A"], ["DB", "S", "B"]],
            migrate.warehouse_paths(model),
        )

    def test_unhandled_gaps_require_validated_resolutions(self):
        gaps = {
            "detected_features": [
                {"name": "hard gap", "status": "unhandled"},
                {"name": "automatic", "status": "auto"},
            ]
        }
        self.assertEqual(
            [{"name": "hard gap", "status": "unhandled"}],
            migrate.unresolved_gaps(gaps, None),
        )
        self.assertEqual(
            [],
            migrate.unresolved_gaps(
                gaps,
                {
                    "resolutions": {
                        "hard gap": {
                            "status": "validated",
                            "evidence": "fixture",
                        }
                    }
                },
            ),
        )
        self.assertEqual(
            [{"name": "hard gap", "status": "unhandled"}],
            migrate.unresolved_gaps(
                gaps,
                {"resolutions": {"hard gap": {"status": "accepted"}}},
            ),
        )

    def test_orchestrator_contains_no_ruby_subprocess(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn('["ruby"', source)
        self.assertNotIn("RbConfig", source)

    def test_state_json_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            migrate.write(path, {"workbook_id": "wb-1"})
            self.assertEqual({"workbook_id": "wb-1"}, migrate.load(path))

    def test_empty_manifest_stops_extract_landing(self):
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            migrate.write(workdir / "landing-manifest.json", [])
            with self.assertRaises(migrate.ExtractLandingRequired) as caught:
                migrate.extract_landing_gate(
                    self.landing_args(),
                    workdir,
                    self.embedded_classification(),
                    environment={},
                    neutral_path=workdir / "missing-env",
                )
            self.assertIn("non-empty landing-manifest.json", str(caught.exception))

    def test_extract_skip_writes_explicit_non_exact_offramp(self):
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            result = migrate.extract_landing_gate(
                self.landing_args(skip_extract_landing="approved live repoint"),
                workdir,
                self.embedded_classification(),
            )
            self.assertEqual("skipped", result["status"])
            self.assertFalse(result["exact_parity_eligible"])
            artifact = migrate.load(workdir / "extract-landing-offramp.json")
            self.assertEqual("prohibited", artifact["exact_parity_claim"])
            self.assertEqual("approved live repoint", artifact["reason"])

    def test_auto_land_keeps_complete_manifest_after_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            (workdir / "workbook-content.twb").write_text(
                "<workbook/>", encoding="utf-8"
            )
            with zipfile.ZipFile(
                workdir / "workbook-content.twbx", "w"
            ) as archive:
                archive.writestr("Data/Sample.hyper", b"fixture")

            def fake_runner(command, check):
                self.assertFalse(check)
                manifest_path = Path(
                    command[command.index("--manifest-out") + 1]
                )
                migrate.write(
                    manifest_path,
                    [
                        {
                            "datasource": "federated.extract",
                            "caption": "Sample Extract",
                            "hyper": "Sample.hyper",
                            "sf_table": "DB.LANDING.SAMPLE",
                            "columns": {"Region": "REGION"},
                        }
                    ],
                )
                return SimpleNamespace(returncode=9)

            result = migrate.extract_landing_gate(
                self.landing_args(no_auto_land=False),
                workdir,
                self.embedded_classification(),
                runner=fake_runner,
                environment={
                    "SNOWFLAKE_ACCOUNT": "account",
                    "SNOWFLAKE_USER": "user",
                },
                neutral_path=workdir / "missing-env",
            )
            self.assertEqual("landed", result["status"])
            self.assertEqual(9, result["landing_returncode"])
            self.assertTrue(result["catalog_sync_warning"])
            self.assertTrue((workdir / "landing-manifest.json").is_file())

    def test_strict_reuse_tie_fails_but_auto_creates_new(self):
        tie = {
            "data_model": {
                "selected_id": None,
                "rationale": "2 high-confidence matches",
            },
            "workbook": {"selected_id": None},
        }
        self.assertEqual((None, None), migrate.reuse_decision(tie, "auto"))
        with self.assertRaises(migrate.ReuseRequired):
            migrate.reuse_decision(tie, "require")

    def test_selected_reuse_returns_both_ids_for_update_paths(self):
        selected = {
            "data_model": {"selected_id": "dm-existing"},
            "workbook": {"selected_id": "wb-existing"},
        }
        self.assertEqual(
            ("dm-existing", "wb-existing"),
            migrate.reuse_decision(selected, "auto"),
        )
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('"--update-id", workbook_id', source)
        self.assertLess(
            source.index("discover-tableau-reuse.py"),
            source.index('"Phases 3–4"'),
        )


if __name__ == "__main__":
    unittest.main()
