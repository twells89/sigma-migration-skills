import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
CONVERTER = ROOT.parent / "spotfire-to-sigma"
SPEC = importlib.util.spec_from_file_location("spotfire_assess", ROOT / "scripts" / "assess.py")
ASSESS = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(ASSESS)


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        self.close()


class SpotfireAssessmentTest(unittest.TestCase):
    def run_fixture(self, fixture):
        temporary = tempfile.TemporaryDirectory()
        out = Path(temporary.name)
        code = ASSESS.main(
            [
                "--from-fixtures",
                str(ROOT / "fixtures" / fixture),
                "--out",
                str(out),
            ]
        )
        self.assertEqual(code, 0)
        return temporary, out

    def test_full_fixture_pipeline_and_scoring(self):
        temporary, out = self.run_fixture("full")
        self.addCleanup(temporary.cleanup)
        expected = {
            "probe.json",
            "inventory.json",
            "usage.json",
            "complexity.json",
            "shortlist.json",
            "migration-plan.json",
            "readout.md",
        }
        self.assertTrue(expected.issubset({path.name for path in out.iterdir()}))
        complexity = json.loads((out / "complexity.json").read_text())
        self.assertEqual(complexity["capability_tier"], "full-exported-manifest")
        by_id = {artifact["id"]: artifact for artifact in complexity["artifacts"]}
        self.assertEqual(by_id["analysis-sales"]["tag"], "migrate-first")
        self.assertEqual(by_id["analysis-risk"]["tag"], "needs-gap-scout")
        self.assertGreaterEqual(by_id["analysis-risk"]["n_unhandled"], 4)
        self.assertEqual(by_id["analysis-unused"]["tag"], "retire")
        self.assertEqual(complexity["evidence_gaps"], [])
        plan = json.loads((out / "migration-plan.json").read_text())
        self.assertGreaterEqual(
            plan["duplicate_dashboards"]["summary"]["duplicate_groups"], 1
        )

    def test_metadata_fixture_discloses_missing_analysis_internals(self):
        temporary, out = self.run_fixture("metadata-only")
        self.addCleanup(temporary.cleanup)
        inventory = json.loads((out / "inventory.json").read_text())
        self.assertEqual(inventory["capability_tier"], "library-metadata-only")
        self.assertEqual(len(inventory["analyses"]), 2)
        self.assertIn("spotfire.datafunction", inventory["library"]["item_type_counts"])
        self.assertTrue(out.joinpath("usage.json").exists())
        usage = json.loads((out / "usage.json").read_text())
        self.assertFalse(usage["quantitative_views"])
        self.assertIn("favorite_count", usage["by_analysis"]["library-analysis-sales"])
        readout = (out / "readout.md").read_text()
        self.assertIn("Evidence-limited", readout)
        self.assertIn("formulas", inventory["analyses"][0]["evidence"]["missing_categories"])
        self.assertNotIn("security", inventory["analyses"][1]["evidence"]["missing_categories"])

    def test_usage_file_is_absent_without_evidence(self):
        payload = {
            "items": [
                {
                    "id": "a",
                    "title": "No Usage",
                    "type": "spotfire.dxp",
                    "permissions": [],
                }
            ]
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "library.json"
            out = root / "out"
            source.write_text(json.dumps(payload))
            ASSESS.main(["--inventory", str(source), "--out", str(out)])
            self.assertFalse((out / "usage.json").exists())
            self.assertFalse(json.loads((out / "probe.json").read_text())["usage_evidence"])

    def test_raw_dxp_inventory_is_normalized_without_binary_introspection(self):
        payload = {
            "instance": {"name": "raw-export"},
            "analyses": [
                {
                    "id": "raw-1",
                    "title": "Raw Export",
                    "visuals": [{"type": "table"}],
                    "formulas": [{"expression": "Sum([Amount])"}],
                    "evidence": {"available_categories": ["visuals", "formulas"]},
                }
            ],
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "inventory.json"
            out = root / "out"
            source.write_text(json.dumps(payload))
            ASSESS.main(["--inventory", str(source), "--out", str(out)])
            inventory = json.loads((out / "inventory.json").read_text())
            self.assertEqual(inventory["capability_tier"], "raw-dxp-inventory")
            self.assertIn("scripts", inventory["analyses"][0]["evidence"]["missing_categories"])
            self.assertTrue(any("opaque DXP" in gap for gap in inventory["evidence_gaps"]))

    def test_converter_authoritative_manifest_is_one_complete_analysis(self):
        manifest = CONVERTER / "fixtures" / "spotfire-manifest.json"
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary) / "out"
            code = ASSESS.main(
                ["--manifest", str(manifest), "--out", str(out)]
            )
            self.assertEqual(code, 0)
            inventory = json.loads((out / "inventory.json").read_text())
            self.assertEqual(1, len(inventory["analyses"]))
            analysis = inventory["analyses"][0]
            self.assertEqual("dxp-sales", analysis["id"])
            self.assertEqual("Sales Operations", analysis["title"])
            self.assertEqual(
                set(ASSESS.CATEGORIES),
                set(analysis["evidence"]["available_categories"]),
            )
            self.assertEqual(11, len(analysis["visuals"]))
            # One calculated column plus every extracted visual-axis expression.
            self.assertEqual(26, len(analysis["formulas"]))
            self.assertEqual(3, len(analysis["security"]))
            self.assertEqual(1, len(analysis["scripts"]))
            self.assertEqual(1, len(analysis["data_functions"]))
            self.assertEqual(1, len(analysis["mods"]))
            self.assertEqual(4, len(inventory["data_sources"]))

    def test_manifest_mode_rejects_non_authoritative_estate_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "not-authoritative.json"
            manifest.write_text(
                json.dumps({"analyses": [{"id": "a", "title": "A"}]}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                    SystemExit, "spotfire_neutral_manifest"):
                ASSESS.main([
                    "--manifest", str(manifest),
                    "--out", str(Path(temporary) / "out"),
                ])

    def test_catalog_classifies_all_required_categories(self):
        catalog = ASSESS.load_catalog()
        cases = {
            "visuals": ({"type": "bar_chart"}, "auto"),
            "formulas": ({"expression": "Sum([Revenue]) OVER ([Region])"}, "manual"),
            "security": ({"type": "row_level_security"}, "manual"),
            "scripts": ({"language": "IronPython"}, "unhandled"),
            "data_functions": ({"language": "Python"}, "unhandled"),
            "mods": ({"type": "spotfire_mod"}, "unhandled"),
        }
        for category, (feature, expected) in cases.items():
            with self.subTest(category=category):
                actual, _ = ASSESS.classify_feature(category, feature, catalog)
                self.assertEqual(actual, expected)

    def test_library_transport_uses_get_and_documented_path(self):
        calls = []

        def fake_urlopen(request, **kwargs):
            calls.append((request.get_method(), request.full_url))
            return FakeResponse(json.dumps({"items": []}).encode())

        client = ASSESS.LibraryClient("https://spotfire.example", "not-a-real-token")
        with mock.patch.object(ASSESS.urllib.request, "urlopen", fake_urlopen):
            self.assertEqual(client.items(0), {"items": []})
        self.assertEqual(calls[0][0], "GET")
        self.assertTrue(
            calls[0][1].startswith(
                "https://spotfire.example/spotfire/api/rest/library/v2/items?"
            )
        )
        self.assertIn("attributes=all", calls[0][1])

    def test_oauth_mint_requests_read_scope_only(self):
        calls = []

        def fake_urlopen(request, **kwargs):
            calls.append(request)
            return FakeResponse(json.dumps({"access_token": "synthetic"}).encode())

        with mock.patch.object(ASSESS.urllib.request, "urlopen", fake_urlopen):
            token = ASSESS.mint_access_token(
                "https://spotfire.example/spotfire/oauth2/token",
                "client",
                "secret",
                "basic",
            )
        self.assertEqual(token, "synthetic")
        self.assertEqual(calls[0].get_method(), "POST")
        form = calls[0].data.decode()
        self.assertIn("scope=api.library.read", form)
        self.assertNotIn("api.library.write", form)

    def test_pre_14_live_mode_fails_to_offline_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(SystemExit, "pre-14"):
                ASSESS.main(
                    [
                        "--base-url",
                        "https://spotfire.example",
                        "--server-version",
                        "12.5",
                        "--out",
                        temporary,
                    ]
                )


if __name__ == "__main__":
    unittest.main()
