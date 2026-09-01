import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE / "assert-doctor-ran.py"


class AssertDoctorRanTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.workdir = Path(self.tmp.name)
        self.doctor = {
            "pass": True,
            "failures": [],
            "behind_count": 0,
            "runtime_profile": {
                "requested": "python",
                "selected": "python",
                "required_runtimes": ["python", "node", "bash"],
                "fallback_reason": "missing required runtime(s): ruby",
            },
            "runtimes": {
                "ruby": False,
                "python": True,
                "node": True,
                "bash": True,
            },
        }
        self.bootstrap = {
            "doctor_pass": True,
            "runtime_profile": {
                "requested": "python",
                "selected": "python",
                "required_runtimes": ["python", "node", "bash"],
                "fallback_reason": "missing required runtime(s): ruby",
            },
        }
        self.write()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self):
        (self.workdir / "doctor.json").write_text(
            json.dumps(self.doctor), encoding="utf-8"
        )
        (self.workdir / "bootstrap.json").write_text(
            json.dumps(self.bootstrap), encoding="utf-8"
        )

    def run_gate(self, *extra):
        return subprocess.run(
            [
                sys.executable,
                str(GATE),
                "--workdir",
                str(self.workdir),
                *extra,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_python_profile_accepts_observed_missing_ruby(self):
        result = self.run_gate("--runtime-profile", "python")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("profile=python", result.stdout)

    def test_requested_profile_mismatch_fails(self):
        result = self.run_gate("--runtime-profile", "ruby")
        self.assertEqual(1, result.returncode)
        self.assertIn("profile mismatch", result.stderr)

    def test_bootstrap_profile_mismatch_fails(self):
        self.bootstrap["runtime_profile"]["selected"] = "ruby"
        self.write()
        result = self.run_gate("--runtime-profile", "python")
        self.assertEqual(1, result.returncode)
        self.assertIn("doctor/bootstrap runtime profiles differ", result.stderr)

    def test_failed_doctor_fails(self):
        self.doctor["pass"] = False
        self.doctor["failures"] = ["node not found"]
        self.write()
        result = self.run_gate("--runtime-profile", "python")
        self.assertEqual(1, result.returncode)
        self.assertIn("node not found", result.stderr)

    def test_waiver_is_recorded(self):
        result = self.run_gate("--skip-doctor-gate", "test harness")
        self.assertEqual(0, result.returncode, result.stderr)
        records = (self.workdir / "offramps.jsonl").read_text(encoding="utf-8")
        self.assertIn("test harness", records)


if __name__ == "__main__":
    unittest.main()
