import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "verify-complete.py"
spec = importlib.util.spec_from_file_location("verify_complete", SCRIPT)
verify_complete = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_complete)


class VerifyCompleteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.workdir = Path(self.tmp.name)
        self.docs = {
            "mission.json": {
                key: {"value": key, "provenance": "stated"}
                for key in (
                    "source",
                    "sigma_connection",
                    "destination",
                    "landing",
                    "scope",
                )
            },
            "datamodel-readback-verdict.json": {"pass": True},
            "workbook-readback-verdict.json": {"pass": True},
            "parity-final.json": {"match": True},
            "visual-similarity-final.json": {"status": "PASS"},
            "semantic-edits.json": {"match": True},
            "dm-ids.json": {"dataModelId": "dm-1"},
            "wb-ids.json": {"workbookId": "wb-1"},
        }
        for name, value in self.docs.items():
            (self.workdir / name).write_text(json.dumps(value), encoding="utf-8")
        self.blind = self.workdir / "blind.json"

    def tearDown(self):
        self.tmp.cleanup()

    def write_blind(self, verdict):
        self.blind.write_text(
            json.dumps(
                {
                    "verdict": verdict,
                    "dimensions": {
                        "composition_match": {
                            "verdict": verdict,
                            "evidence": "fixture",
                        }
                    },
                }
            ),
            encoding="utf-8",
        )

    def test_green_requires_every_gate(self):
        self.write_blind("pass")
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertTrue(result["complete"])
        self.assertEqual("GREEN", result["status"])

    def test_blind_visual_failure_blocks_completion(self):
        self.write_blind("fail")
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertFalse(result["complete"])
        self.assertIn("blind_grade: visual fidelity failed", result["failures"][0])

    def test_inferred_mission_field_blocks_completion(self):
        mission = self.docs["mission.json"]
        mission["destination"]["provenance"] = "inferred"
        (self.workdir / "mission.json").write_text(
            json.dumps(mission), encoding="utf-8"
        )
        self.write_blind("pass")
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertFalse(result["complete"])
        self.assertTrue(any("destination" in item for item in result["failures"]))


if __name__ == "__main__":
    unittest.main()
