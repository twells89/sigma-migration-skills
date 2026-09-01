import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runtime_profile


class RuntimeProfileTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "scripts").mkdir()
        (self.root / "scripts" / "migrate.rb").write_text("", encoding="utf-8")
        (self.root / "scripts" / "migrate.py").write_text("", encoding="utf-8")
        self.path = self.root / "runtime-capabilities.json"

    def tearDown(self):
        self.tmp.cleanup()

    def capabilities(self, python_status="supported"):
        data = {
            "schemaVersion": 1,
            "skill": "fixture",
            "profiles": {
                "ruby": {
                    "status": "supported",
                    "requiredRuntimes": ["ruby", "python", "node", "bash"],
                    "entrypoint": ["ruby", "scripts/migrate.rb"],
                },
                "python": {
                    "status": python_status,
                    "requiredRuntimes": ["python", "node", "bash"],
                    "entrypoint": ["python", "scripts/migrate.py"],
                },
            },
        }
        self.path.write_text(json.dumps(data), encoding="utf-8")
        return data

    @staticmethod
    def runtimes(ruby=True):
        return {"ruby": ruby, "python": True, "node": True, "bash": True}

    def test_auto_prefers_supported_ruby(self):
        result = runtime_profile.resolve_profile(
            self.capabilities(),
            "auto",
            self.runtimes(),
            manifest_path=self.path,
        )
        self.assertTrue(result["pass"])
        self.assertEqual("ruby", result["selectedProfile"])
        self.assertIsNone(result["fallbackReason"])

    def test_auto_falls_back_to_supported_python_when_ruby_missing(self):
        result = runtime_profile.resolve_profile(
            self.capabilities(),
            "auto",
            self.runtimes(ruby=False),
            manifest_path=self.path,
        )
        self.assertTrue(result["pass"])
        self.assertEqual("python", result["selectedProfile"])
        self.assertIn("ruby", result["fallbackReason"])
        self.assertNotIn("ruby", result["requiredRuntimes"])

    def test_auto_never_selects_preview(self):
        result = runtime_profile.resolve_profile(
            self.capabilities(python_status="preview"),
            "auto",
            self.runtimes(ruby=False),
            allow_preview=True,
            manifest_path=self.path,
        )
        self.assertFalse(result["pass"])
        self.assertIsNone(result["selectedProfile"])
        self.assertEqual("profile status is preview", result["failures"]["python"])

    def test_explicit_preview_requires_opt_in(self):
        capabilities = self.capabilities(python_status="preview")
        denied = runtime_profile.resolve_profile(
            capabilities,
            "python",
            self.runtimes(ruby=False),
            manifest_path=self.path,
        )
        allowed = runtime_profile.resolve_profile(
            capabilities,
            "python",
            self.runtimes(ruby=False),
            allow_preview=True,
            manifest_path=self.path,
        )
        self.assertFalse(denied["pass"])
        self.assertTrue(allowed["pass"])
        self.assertEqual("python", allowed["selectedProfile"])

    def test_missing_entrypoint_fails_closed(self):
        capabilities = self.capabilities()
        (self.root / "scripts" / "migrate.py").unlink()
        result = runtime_profile.resolve_profile(
            capabilities,
            "python",
            self.runtimes(ruby=False),
            manifest_path=self.path,
        )
        self.assertFalse(result["pass"])
        self.assertIn("entrypoint does not exist", result["failures"]["python"])

    def test_missing_manifest_uses_legacy_profile(self):
        capabilities, path = runtime_profile.load_capabilities(None)
        self.assertIsNone(path)
        result = runtime_profile.resolve_profile(
            capabilities,
            "auto",
            self.runtimes(),
            manifest_path=path,
        )
        self.assertTrue(result["pass"])
        self.assertEqual("ruby", result["selectedProfile"])


if __name__ == "__main__":
    unittest.main()
