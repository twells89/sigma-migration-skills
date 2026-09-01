import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "migrate-tableau.py"
spec = importlib.util.spec_from_file_location("migrate_tableau_python", SCRIPT)
migrate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migrate)


class MigrateTableauPythonTest(unittest.TestCase):
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

    def test_orchestrator_contains_no_ruby_subprocess(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn('["ruby"', source)
        self.assertNotIn("RbConfig", source)

    def test_state_json_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            migrate.write(path, {"workbook_id": "wb-1"})
            self.assertEqual({"workbook_id": "wb-1"}, migrate.load(path))


if __name__ == "__main__":
    unittest.main()
