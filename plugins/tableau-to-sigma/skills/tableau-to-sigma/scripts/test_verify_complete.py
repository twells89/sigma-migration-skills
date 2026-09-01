import importlib.util
import hashlib
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
        self.blind = self.workdir / "blind.json"
        self.source_png = self.workdir / "source.png"
        self.target_png = self.workdir / "target.png"
        self.source_png.write_bytes(b"source pixels")
        self.target_png.write_bytes(b"target pixels")
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
            "anchors-verdict.json": {"pass": True},
            "visual-similarity-final.json": {
                "pass": True,
                "source_health": {"path": str(self.source_png)},
                "render_health": {"path": str(self.target_png)},
            },
            "semantic-edits.json": {"match": True},
            "dm-ids.json": {"dataModelId": "dm-1"},
            "wb-ids.json": {"workbookId": "wb-1"},
        }
        for name, value in self.docs.items():
            (self.workdir / name).write_text(json.dumps(value), encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def write_blind(self, verdict):
        self.blind.write_text(
            json.dumps(
                {
                    "verdict": verdict,
                    "source_png": str(self.source_png),
                    "target_png": str(self.target_png),
                    "source_sha256": hashlib.sha256(self.source_png.read_bytes()).hexdigest(),
                    "target_sha256": hashlib.sha256(self.target_png.read_bytes()).hexdigest(),
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

    def test_stale_blind_grade_hash_blocks_completion(self):
        self.write_blind("pass")
        self.target_png.write_bytes(b"changed pixels")
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertFalse(result["complete"])
        self.assertTrue(any("stale target_png hash" in item for item in result["failures"]))


if __name__ == "__main__":
    unittest.main()
