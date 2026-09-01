import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
FIXTURE = ROOT / "corpus" / "tableau" / "logical-model-objectgraph" / "workbook-content.twb"
SCRIPT = HERE / "convert-tableau.py"

sys.path.insert(0, str(HERE))
import importlib.util

spec = importlib.util.spec_from_file_location("convert_tableau", SCRIPT)
convert_tableau = importlib.util.module_from_spec(spec)
spec.loader.exec_module(convert_tableau)


class ConvertTableauTest(unittest.TestCase):
    def test_parameter_case_is_promoted_to_workbook_switch(self):
        pattern = {
            "kind": "param-filter",
            "source": 'CASE [Parameters].[Choose] WHEN "A" THEN [Sales] ELSE [Profit] END',
        }
        promoted = convert_tableau.parameter_switch_pattern(pattern)
        self.assertEqual("param-switch", promoted["kind"])
        self.assertEqual("Choose", promoted["paramName"])
        self.assertEqual([{"when": "A", "then": "[Sales]"}], promoted["cases"])
        self.assertEqual("[Profit]", promoted["elseExpr"])

    def test_vendored_converter_writes_model_and_audit_wrapper(self):
        self.assertTrue(FIXTURE.is_file(), FIXTURE)
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--twb",
                    str(FIXTURE),
                    "--connection",
                    "test-connection",
                    "--database",
                    "TEST_DB",
                    "--schema",
                    "TEST_SCHEMA",
                    "--out",
                    tmp,
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            model = json.loads((Path(tmp) / "dm-raw.json").read_text(encoding="utf-8"))
            meta = json.loads((Path(tmp) / "conv-meta.json").read_text(encoding="utf-8"))
            self.assertIsInstance(model.get("pages"), list)
            self.assertEqual(model, meta["model"])
            self.assertIn("security", meta)
            self.assertIn("workbookPatterns", meta)
            self.assertIn("relationshipCoverage", meta)


if __name__ == "__main__":
    unittest.main()
