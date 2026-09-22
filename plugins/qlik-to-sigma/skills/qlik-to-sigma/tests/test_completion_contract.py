#!/usr/bin/env python3
"""Focused offline regression tests for the Qlik completion contract."""

import importlib.util
import binascii
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from datetime import datetime, timezone
from pathlib import Path


SKILL = Path(__file__).resolve().parents[1]
SCRIPTS = SKILL / "scripts"


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def write_png(path, width, height, pixel):
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = b"".join(
        b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(width))
        for y in range(height)
    )

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF)
        )

    payload = b"\x89PNG\r\n\x1a\n"
    payload += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    payload += chunk(b"IDAT", zlib.compress(rows))
    payload += chunk(b"IEND", b"")
    path.write_bytes(payload)


def healthy_png(path, blank_tiles=False):
    def pixel(x, y):
        if y < (35 if blank_tiles else 45):
            return (25, 55, 95)
        if blank_tiles:
            return (0, 0, 0) if 49 <= y <= 51 and 20 <= x <= 580 else (255, 255, 255)
        for bar_x in range(25, 575, 55):
            if bar_x <= x <= bar_x + 25 and 70 <= y <= 260 - (bar_x % 95):
                return (50, 120, 190)
        return (255, 255, 255)

    write_png(path, 600, 300, pixel)


def blank_png(path):
    write_png(path, 600, 300, lambda _x, _y: (255, 255, 255))


class CompletionContractTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.workdir = Path(self.temp.name)
        self.make_complete_workdir()

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, name, *args):
        self.assertTrue(name.endswith(".py"), "completion fixtures must be Python-only")
        command = [sys.executable, str(SCRIPTS / name), *map(str, args)]
        return subprocess.run(command, text=True, capture_output=True, check=False)

    def make_complete_workdir(self):
        wd = self.workdir
        write_json(wd / "converter-input.json", {
            "appId": "app-1",
            "appName": "Orders",
            "tables": [{"name": "Orders", "fields": [{"name": "Country"}]}],
        })
        write_json(wd / "charts.json", [{
            "id": "chart-1", "title": "Sales", "vizType": "barchart",
            "dimensions": ["Country"], "measures": ["Sum(Sales)"],
        }])
        write_json(wd / "layout.json", [{
            "sheetId": "sheet-1", "title": "Overview", "columns": 24, "rows": 12,
            "cells": [{"objectId": "chart-1", "col": 0, "row": 0,
                       "colspan": 24, "rowspan": 12}],
        }])
        write_json(wd / "measures.json", [])
        write_json(wd / "dimensions.json", [])
        write_json(wd / "app-meta.json", {
            "id": "app-1", "name": "Orders", "hasSectionAccess": False,
        })
        (wd / "script.qvs").write_text(
            "Orders:\nLOAD Country FROM [lib://orders.qvd];\n", encoding="utf-8"
        )
        write_json(wd / "formula-mapping.json", {"formulas": []})
        write_json(wd / "dm-spec.json", {
            "pages": [{"elements": [{
                "id": "dm-orders", "name": "Orders Country", "kind": "table",
                "columns": [{"id": "country", "name": "Country"}],
            }]}],
        })
        write_json(wd / "dm-ids.json", {"dataModelId": "dm-1"})
        write_json(wd / "dm-result.json", {
            "dataModelId": "dm-1",
            "denormElementId": "dm-orders",
        })
        write_json(wd / "datamodel-readback.json", {
            "dataModelId": "dm-1",
            "pages": [{"elements": [{
                "id": "dm-orders", "name": "Orders Country", "kind": "table",
                "columns": [{"id": "country", "name": "Country"}],
            }]}],
        })
        workbook_spec = {
            "pages": [{"id": "sheet-1", "name": "Overview", "elements": [{
                "id": "sigma-chart-1", "name": "Sales", "kind": "bar-chart",
                "columns": [{"id": "country"}, {"id": "sales"}],
            }]}],
        }
        layout_xml = (
            '<Page id="sheet-1" type="grid" '
            'gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">'
            '<Element elementId="sigma-chart-1" gridColumn="1 / 25" '
            'gridRow="1 / 13"/></Page>\n'
        )
        write_json(wd / "wb-spec.json", workbook_spec)
        write_json(wd / "wb-readback.json", {
            "workbookId": "wb-1",
            "latestDocumentVersion": 1,
            "document": {**workbook_spec, "layout": layout_xml},
        })
        (wd / "layout.xml").write_text(layout_xml, encoding="utf-8")
        write_json(wd / "run-state.json", {
            "run_id": "fixture-run",
            "runtime_profile": "python",
        })
        write_json(wd / "column-scan.json", {
            "status": "complete-clean", "columns_read": 2, "errors": [],
        })
        write_json(wd / "workbook-coverage.json", {
            "sourceVisuals": 1,
            "sourceVisualIds": ["chart-1"],
            "queryableElements": 1,
            "builtSourceVisualIds": ["chart-1"],
            "unbuiltSourceVisualIds": [],
            "status": "PASS",
        })
        write_json(wd / "control-scope.json", {
            "version": 1, "source": "qlik", "sourceFilterSignals": 0,
            "controls": [], "unbound": [], "dropped": [],
        })
        write_json(wd / "element-map.json", [{
            "elementId": "sigma-chart-1", "name": "Sales", "kind": "bar-chart",
            "qlik": {"objectId": "chart-1", "dims": ["Country"],
                     "measures": ["Sum(Sales)"]},
        }])
        write_json(wd / "parity-final.json", {
            "status": "PASS", "strict": True, "mode": "live-engine",
            "verified_against": "qlik-engine", "charts_total": 1,
            "charts_pass": 1, "charts_fail": 0, "charts_stale_explained": 0,
            "fail_names": [], "pending_names": [], "divergent": False,
            "visual_checked": True, "visual_verdict": "pass",
            "agent_vision": True,
            "style_checklist": {
                "element_titles_hidden": "na",
                "palette_match": "pass",
                "composition_match": "pass",
                "chart_shapes_match": "pass",
                "labels_legible": "pass",
                "numbers_formatted": "pass",
            },
            "blind_grade_waiver": {
                "kind": "no-vision-grader",
                "reason": "fixture visual review is deterministic",
            },
            "per_chart": [{"chart": "Sales", "status": "MATCH", "pass": True}],
            "tile_census": {
                "zones_total": 1, "charts_built": 1, "zones_unmatched": 0,
                "unmatched_zone_names": [],
            },
        })
        healthy_png(wd / "source-pages" / "sheet-1.png")
        healthy_png(wd / "visual-qa" / "sheet-1.png")
        target = wd / "visual-qa" / "sheet-1.png"
        write_json(wd / "render-evidence.json", {
            "workbookId": "wb-1",
            "documentVersion": "1",
            "run_id": "fixture-run",
            "images": [{
                "path": str(target.resolve()),
                "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
            }],
        })

    def finalize(self):
        return self.run_script("finalize-qlik-report.py", "--workdir", self.workdir)

    def assert_phase6(self):
        return self.run_script(
            "assert-phase6-ran.py",
            "--workdir", self.workdir,
            "--workbook-id", "wb-1",
            "--control-scope", self.workdir / "control-scope.json",
            "--require-control-flip",
            "--sigma-render", self.workdir / "visual-qa" / "sheet-1.png",
            "--skip-anchors-gate", "fixture has no transcribed source values",
        )

    def complete_python_gate(self):
        first = self.finalize()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        asserted = self.assert_phase6()
        self.assertEqual(asserted.returncode, 0, asserted.stdout + asserted.stderr)
        terminal = self.finalize()
        self.assertEqual(terminal.returncode, 0, terminal.stdout + terminal.stderr)

    def test_unaccounted_source_object_fails_closed(self):
        dm = json.loads((self.workdir / "dm-spec.json").read_text())
        dm["pages"][0]["elements"][0]["columns"] = []
        dm["pages"][0]["elements"][0]["name"] = "Orders"
        write_json(self.workdir / "dm-spec.json", dm)
        result = self.run_script(
            "build-qlik-accounting.py", "--workdir", self.workdir
        )
        self.assertNotEqual(result.returncode, 0)
        census = json.loads((self.workdir / "source-object-census.json").read_text())
        self.assertFalse(census["summary"]["complete"])
        self.assertIn("field:Orders.Country", census["diagnostics"]["unaccounted"])

    def test_missing_and_blank_source_or_target_render_fail(self):
        (self.workdir / "visual-qa" / "sheet-1.png").unlink()
        missing = self.finalize()
        self.assertNotEqual(missing.returncode, 0)
        health = json.loads((self.workdir / "render-health.json").read_text())
        self.assertEqual(health["status"], "FAIL")
        self.assertEqual(health["sigma_pages"][0]["status"], "ERROR")

        healthy_png(self.workdir / "visual-qa" / "sheet-1.png")
        blank_png(self.workdir / "source-pages" / "sheet-1.png")
        blank = self.finalize()
        self.assertNotEqual(blank.returncode, 0)
        health = json.loads((self.workdir / "render-health.json").read_text())
        self.assertEqual(health["sources"][0]["status"], "FAIL")

    def test_render_hash_blocks_reused_or_replaced_page_png(self):
        first = self.finalize()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        target = self.workdir / "visual-qa" / "sheet-1.png"
        write_png(
            target,
            600,
            300,
            lambda x, y: (
                (15, 70, 130)
                if y < 50 or (x % 80 < 35 and 60 < y < 250)
                else (250, 250, 250)
            ),
        )
        result = self.assert_phase6()
        self.assertEqual(10, result.returncode, result.stdout + result.stderr)
        self.assertIn("hash", result.stderr)

    def test_visible_page_named_data_is_still_finalized(self):
        for filename in ("wb-spec.json", "wb-readback.json"):
            path = self.workdir / filename
            document = json.loads(path.read_text())
            root = document.get("document") or document
            root["pages"][0]["name"] = "Data"
            write_json(path, document)
        result = self.finalize()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        health = json.loads((self.workdir / "render-health.json").read_text())
        self.assertEqual(1, health["expected_sigma_pages"])
        self.assertEqual(1, health["sigma_pages_checked"])

    def test_tile_aware_majority_blank_fails(self):
        source = self.workdir / "source.png"
        render = self.workdir / "render.png"
        healthy_png(source, blank_tiles=True)
        healthy_png(render, blank_tiles=True)
        tiles = [
            {"name": "A", "kind": "chart", "x_pct": 0, "y_pct": 20,
             "w_pct": 33, "h_pct": 80},
            {"name": "B", "kind": "chart", "x_pct": 33, "y_pct": 20,
             "w_pct": 34, "h_pct": 80},
            {"name": "C", "kind": "chart", "x_pct": 67, "y_pct": 20,
             "w_pct": 33, "h_pct": 80},
        ]
        write_json(self.workdir / "tiles.json", tiles)
        out = self.workdir / "similarity.json"
        result = self.run_script(
            "visual-similarity.py", "--source", source, "--render", render,
            "--tiles", self.workdir / "tiles.json", "--json-out", out,
        )
        self.assertEqual(result.returncode, 1)
        verdict = json.loads(out.read_text())
        self.assertEqual(verdict["tiles_measured"], 3)
        self.assertGreater(len(verdict["tiles_blank"]), 1)
        self.assertFalse(verdict["pass"])

    def test_qlik_screenshot_rejects_valid_blank_png(self):
        module_path = SCRIPTS / "qlik-screenshot.py"
        spec = importlib.util.spec_from_file_location("qlik_screenshot", module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        blank = self.workdir / "download.png"
        blank_png(blank)
        blank_bytes = blank.read_bytes()
        real_run = module.subprocess.run

        def fake_qlik(*args, **kwargs):
            if args[:3] == ("raw", "post", "v1/reports"):
                return "", "reports/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/status"
            return {"status": "done", "results": [{"location": "/api/download"}]}

        def fake_run(command, *args, **kwargs):
            if command[:3] == ["qlik", "raw", "get"]:
                return subprocess.CompletedProcess(command, 0, stdout=blank_bytes, stderr=b"")
            return real_run(command, *args, **kwargs)

        module.qlik = fake_qlik
        module.subprocess.run = fake_run
        path, error, health = module.export_png("app", "viz", str(self.workdir))
        self.assertIsNone(path)
        self.assertIn("PNG health FAIL", error)
        self.assertEqual(health["status"], "FAIL")

    def test_orchestrator_orders_full_assert_and_never_stamps_success(self):
        text = (SCRIPTS / "migrate-qlik.rb").read_text(encoding="utf-8")
        normalize = text.index("normalize-qlik-expressions.py")
        lint = text.index("blank-risk-elements.json")
        post = text.index("run!(wb_cmd) unless opts[:dry_run]")
        parity = text.index("'parity-final.json'")
        cleanup = text.index("'cleanup-orphan-workbooks.rb'")
        shared_assert = text.index("'assert-phase6-ran.rb'")
        terminal_report = text.index(
            "Qlik accounting and report finalization (terminal)"
        )
        self.assertLess(normalize, lint)
        self.assertLess(lint, post)
        self.assertLess(post, parity)
        self.assertLess(parity, cleanup)
        self.assertLess(cleanup, shared_assert)
        self.assertLess(shared_assert, terminal_report)
        self.assertNotRegex(
            text, r"File\.write\([^)]*phase6-success\.json"
        )
        self.assertIn("assert_ok = run_terminal.call", text)
        self.assertIn("mechanical_ok && cleanup_ok && pre_finalizer_ok && assert_ok", text)

        python = (SCRIPTS / "migrate-qlik.py").read_text(encoding="utf-8")
        normalize = python.index('"normalize-qlik-expressions.py"')
        lint = python.index('"blank-risk-elements.json"', normalize)
        post = python.index("self.execute(workbook_command)", lint)
        parity = python.index("    def parity(", post)
        cleanup = python.index('"cleanup_orphan_workbooks.py"', parity)
        shared_assert = python.index(
            "assertion = self.execute(assert_command", cleanup
        )
        terminal_report = python.index(
            "post_finalizer = self.execute(finalizer_command", shared_assert
        )
        verify = python.index('"verify-complete.py"', terminal_report)
        self.assertLess(normalize, lint)
        self.assertLess(lint, post)
        self.assertLess(post, parity)
        self.assertLess(parity, cleanup)
        self.assertLess(cleanup, shared_assert)
        self.assertLess(shared_assert, terminal_report)
        self.assertLess(terminal_report, verify)
        self.assertNotIn("write_text(phase6-success", python)

    def test_report_contradiction_fails_completion(self):
        self.complete_python_gate()
        report = json.loads((self.workdir / "migration-result.json").read_text())
        report["source_objects"][0]["status"] = "skipped"
        write_json(self.workdir / "migration-result.json", report)
        result = self.run_script(
            "verify-complete.py", "--workdir", self.workdir,
            "--workbook-id", "wb-1",
        )
        self.assertEqual(result.returncode, 7)
        self.assertIn("does not exactly match", result.stderr)

    def test_complete_success(self):
        self.complete_python_gate()
        result = self.run_script(
            "verify-complete.py", "--workdir", self.workdir,
            "--workbook-id", "wb-1",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("strict parity", result.stdout)
        census = json.loads((self.workdir / "source-object-census.json").read_text())
        self.assertTrue(census["summary"]["complete"])
        self.assertTrue(all(
            row["status"] in {
                "migrated", "approximated", "needs-review", "skipped",
                "not-applicable",
            }
            and row["source_provenance"] in {
                "live", "engine-export", "inferred",
            }
            and row["evidence"]
            for row in census["objects"]
        ))
        tiles = json.loads((self.workdir / "qlik-tile-layout.json").read_text())
        self.assertEqual(tiles[0]["kind"], "chart")
        similarity = json.loads((self.workdir / "visual-similarity.json").read_text())
        self.assertEqual(similarity["pages"][0]["tiles_measured"], 1)

    def test_failed_assert_clears_stale_success_marker(self):
        first = self.finalize()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        write_json(self.workdir / "phase6-success.json", {
            "workbookId": "stale", "chartCount": 99, "gates": "all-pass",
            "waivers": [], "generatedAt": "2026-08-20T00:00:00Z",
        })
        parity = json.loads((self.workdir / "parity-final.json").read_text())
        parity["strict"] = False
        write_json(self.workdir / "parity-final.json", parity)
        result = self.assert_phase6()
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.workdir / "phase6-success.json").exists())

    def test_waiver_budget_rejects_more_than_two_quality_waivers(self):
        first = self.finalize()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        result = self.run_script(
            "assert-phase6-ran.py",
            "--workdir", self.workdir,
            "--workbook-id", "wb-1",
            "--control-scope", self.workdir / "control-scope.json",
            "--require-control-flip",
            "--sigma-render", self.workdir / "visual-qa" / "sheet-1.png",
            "--skip-anchors-gate", "fixture has no transcribed source values",
            "--skip-layout-lint", "fixture layout waiver",
        )
        self.assertEqual(19, result.returncode, result.stdout + result.stderr)
        self.assertFalse((self.workdir / "phase6-success.json").exists())

    def test_warehouse_mode_requires_named_source_parity_disposition(self):
        parity_path = self.workdir / "parity-final.json"
        parity = json.loads(parity_path.read_text())
        parity["mode"] = "warehouse"
        parity["verified_against"] = "warehouse"
        parity.pop("waivers", None)
        parity.pop("waiver_reasons", None)
        write_json(parity_path, parity)
        first = self.finalize()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        result = self.assert_phase6()
        self.assertEqual(19, result.returncode, result.stdout + result.stderr)
        self.assertFalse((self.workdir / "phase6-success.json").exists())

    def test_warehouse_evidence_cannot_hide_behind_missing_mode(self):
        parity_path = self.workdir / "parity-final.json"
        parity = json.loads(parity_path.read_text())
        parity.pop("mode", None)
        parity["verified_against"] = "warehouse"
        parity["per_chart"][0]["status"] = "WAREHOUSE-PASS"
        parity["waivers"] = ["--source-parity-unavailable"]
        parity["waiver_reasons"] = {
            "--source-parity-unavailable": "offline source fixture",
        }
        write_json(parity_path, parity)
        first = self.finalize()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        result = self.assert_phase6()
        self.assertEqual(19, result.returncode, result.stdout + result.stderr)
        self.assertFalse((self.workdir / "phase6-success.json").exists())

    def test_section_access_cannot_complete_without_applied_decision(self):
        app_meta_path = self.workdir / "app-meta.json"
        app_meta = json.loads(app_meta_path.read_text())
        app_meta["hasSectionAccess"] = True
        write_json(app_meta_path, app_meta)
        first = self.finalize()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        result = self.assert_phase6()
        self.assertEqual(32, result.returncode, result.stdout + result.stderr)
        self.assertFalse((self.workdir / "phase6-success.json").exists())

    def test_section_access_load_script_cannot_hide_behind_false_metadata(self):
        with (self.workdir / "script.qvs").open("a", encoding="utf-8") as handle:
            handle.write("\nSECTION ACCESS;\nLOAD USERID, REDUCTION INLINE [];\n")
        first = self.finalize()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        result = self.assert_phase6()
        self.assertEqual(32, result.returncode, result.stdout + result.stderr)
        self.assertFalse((self.workdir / "phase6-success.json").exists())

    def test_stale_security_decision_cannot_approve_new_model(self):
        app_meta_path = self.workdir / "app-meta.json"
        app_meta = json.loads(app_meta_path.read_text())
        app_meta["hasSectionAccess"] = True
        write_json(app_meta_path, app_meta)
        write_json(self.workdir / "security-decision.json", {
            "decision": "port",
            "status": "applied",
            "readback_verified": True,
            "dataModelId": "different-model",
            "run_id": "stale-run",
            "readback_sha256": "0" * 64,
        })
        first = self.finalize()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        result = self.assert_phase6()
        self.assertEqual(32, result.returncode, result.stdout + result.stderr)
        self.assertIn("stale", result.stderr)

    def test_applied_security_must_persist_on_denormalized_source(self):
        app_meta_path = self.workdir / "app-meta.json"
        app_meta = json.loads(app_meta_path.read_text())
        app_meta["hasSectionAccess"] = True
        write_json(app_meta_path, app_meta)
        write_json(self.workdir / "security.json", {
            "security": [{
                "kind": "rls",
                "rls": {
                    "name": "Region RLS",
                    "formula": (
                        'CurrentUserAttributeText("Region") = [Region]'
                    ),
                },
            }],
        })
        readback_path = self.workdir / "datamodel-readback.json"
        readback = json.loads(readback_path.read_text())
        element = readback["pages"][0]["elements"][0]
        element["columns"].append({
            "id": "rls-column",
            "name": "Region RLS",
            "formula": 'CurrentUserAttributeText("Region") = [Region]',
        })
        element["filters"] = [{
            "id": "rls-filter",
            "kind": "list",
            "mode": "include",
            "columnId": "rls-column",
            "values": [True],
        }]
        write_json(readback_path, readback)
        membership_path = self.workdir / "membership-readback.json"
        write_json(membership_path, {
            "dataModelId": "dm-1",
            "run_id": "fixture-run",
            "subjects": ["member-1", "member-2"],
            "assignments": [{
                "principal": "Region",
                "readback_verified": True,
                "values": {"member-1": "West"},
            }],
        })
        write_json(self.workdir / "security-decision.json", {
            "decision": "port",
            "status": "applied",
            "readback_verified": True,
            "rules_detected": 1,
            "rules_applied": 1,
            "dataModelId": "dm-1",
            "securedElementId": "dm-orders",
            "run_id": "fixture-run",
            "requiredPrincipals": ["Region"],
            "membership_verified": True,
            "membership_evidence": [{
                "path": str(membership_path),
                "sha256": hashlib.sha256(
                    membership_path.read_bytes()
                ).hexdigest(),
            }],
            "readback_sha256": hashlib.sha256(
                readback_path.read_bytes()
            ).hexdigest(),
        })
        sigma_roster_path = self.workdir / "sigma-membership-readback.json"
        write_json(sigma_roster_path, {
            "dataModelId": "dm-1",
            "subjects": ["member-1", "member-2"],
            "assignments": [{
                "principal": "Region",
                "values": {"member-1": "West"},
            }],
        })
        source_policy_path = self.workdir / "source-security-policy.json"
        write_json(source_policy_path, {
            "security": [{
                "kind": "rls",
                "rls": {
                    "name": "Region RLS",
                    "formula": (
                        'CurrentUserAttributeText("Region") = [Region]'
                    ),
                },
            }],
        })
        policy_sha256 = hashlib.sha256(
            source_policy_path.read_bytes()
        ).hexdigest()
        rule_id = hashlib.sha256(
            json.dumps(
                {
                    "kind": "rls",
                    "rls": {
                        "name": "Region RLS",
                        "formula": (
                            'CurrentUserAttributeText("Region") = [Region]'
                        ),
                    },
                },
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        allow_source = self.workdir / "allow-source.json"
        allow_sigma = self.workdir / "allow-sigma.json"
        deny_source = self.workdir / "deny-source.json"
        deny_sigma = self.workdir / "deny-sigma.json"
        write_json(allow_source, {
            "system": "qlik",
            "principal": "member-1",
            "query": "restricted-region-check",
            "policy_sha256": policy_sha256,
            "rule_ids": [rule_id],
            "captured_at": "2026-09-22T00:00:00Z",
            "transport": "qlik-engine",
            "rows": ["West"],
        })
        write_json(allow_sigma, {
            "system": "sigma",
            "principal": "member-1",
            "query": "restricted-region-check",
            "policy_sha256": policy_sha256,
            "rule_ids": [rule_id],
            "captured_at": "2026-09-22T00:00:00Z",
            "transport": "sigma-export",
            "rows": ["West"],
        })
        write_json(deny_source, {
            "system": "qlik",
            "principal": "member-2",
            "query": "restricted-region-check",
            "policy_sha256": policy_sha256,
            "rule_ids": [rule_id],
            "captured_at": "2026-09-22T00:00:00Z",
            "transport": "qlik-engine",
            "rows": [],
        })
        write_json(deny_sigma, {
            "system": "sigma",
            "principal": "member-2",
            "query": "restricted-region-check",
            "policy_sha256": policy_sha256,
            "rule_ids": [rule_id],
            "captured_at": "2026-09-22T00:00:00Z",
            "transport": "sigma-export",
            "rows": [],
        })
        def evidence(path):
            return {
                "path": str(path),
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        readback_hash = hashlib.sha256(
            readback_path.read_bytes()
        ).hexdigest()
        write_json(self.workdir / "security-effective-user-verdict.json", {
            "status": "PASS",
            "dataModelId": "dm-1",
            "run_id": "fixture-run",
            "readback_sha256": readback_hash,
            "source_policy": evidence(source_policy_path),
            "source_roster": {
                "path": str(membership_path),
                "sha256": hashlib.sha256(
                    membership_path.read_bytes()
                ).hexdigest(),
            },
            "sigma_roster": {
                "path": str(sigma_roster_path),
                "sha256": hashlib.sha256(
                    sigma_roster_path.read_bytes()
                ).hexdigest(),
            },
            "tests": [
                {
                    "kind": "allow",
                    "principal": "member-1",
                    "status": "PASS",
                    "match": True,
                    "query": "restricted-region-check",
                    "rule_ids": [rule_id],
                    "source_result": evidence(allow_source),
                    "sigma_result": evidence(allow_sigma),
                },
                {
                    "kind": "deny",
                    "principal": "member-2",
                    "status": "PASS",
                    "match": True,
                    "query": "restricted-region-check",
                    "rule_ids": [rule_id],
                    "source_result": evidence(deny_source),
                    "sigma_result": evidence(deny_sigma),
                },
            ],
        })
        self.complete_python_gate()
        result = self.run_script(
            "verify-complete.py",
            "--workdir", self.workdir,
            "--workbook-id", "wb-1",
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        mismatched_allow = json.loads(allow_sigma.read_text())
        mismatched_allow["rows"] = ["East"]
        write_json(allow_sigma, mismatched_allow)
        verdict_path = self.workdir / "security-effective-user-verdict.json"
        verdict = json.loads(verdict_path.read_text())
        verdict["tests"][0]["sigma_result"]["sha256"] = hashlib.sha256(
            allow_sigma.read_bytes()
        ).hexdigest()
        write_json(verdict_path, verdict)
        mismatch = self.assert_phase6()
        self.assertEqual(32, mismatch.returncode, mismatch.stdout + mismatch.stderr)
        self.assertIn("results differ", mismatch.stderr)

    def test_missing_app_meta_is_valid_for_unsecured_offline_project(self):
        (self.workdir / "app-meta.json").unlink()
        self.complete_python_gate()
        result = self.run_script(
            "verify-complete.py",
            "--workdir", self.workdir,
            "--workbook-id", "wb-1",
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_all_unprobeable_controls_use_advisory_marker(self):
        control = {
            "id": "control-element",
            "name": "Date Filter",
            "kind": "control",
            "controlId": "date-filter",
            "controlType": "date-range",
            "source": {
                "kind": "source",
                "source": {"kind": "table", "elementId": "sigma-chart-1"},
                "columnId": "country",
            },
            "filters": [{
                "source": {"kind": "table", "elementId": "sigma-chart-1"},
                "columnId": "country",
            }],
        }
        for filename in ("wb-spec.json", "wb-readback.json"):
            path = self.workdir / filename
            document = json.loads(path.read_text())
            root = document.get("document") or document
            root["pages"][0]["elements"].append(control)
            root["layout"] = str(root.get("layout") or "") + (
                '<Page id="controls"><Element elementId="control-element" '
                'gridColumn="1 / 25" gridRow="1 / 4"/></Page>'
            )
            write_json(path, document)
        write_json(self.workdir / "control-scope.json", {
            "version": 1,
            "source": "qlik",
            "sourceFilterSignals": 1,
            "controls": [{
                "controlId": "date-filter",
                "mustReach": ["sigma-chart-1"],
            }],
            "unbound": [],
            "dropped": [],
        })
        write_json(self.workdir / "probe-controls" / "probe-results.json", [{
            "control": "date-filter",
            "result": "SKIP",
            "note": "date range has no safe automatic sample",
        }])
        write_json(self.workdir / "probe-controls" / "probe-evidence.json", {
            "workbook_id": "wb-1",
            "doc_version": "1",
            "probed_at": datetime.now(timezone.utc).isoformat(),
            "exports": {},
        })
        write_json(self.workdir / "control-flip-unverified.json", {
            "workbookId": "wb-1",
            "status": "ADVISORY",
            "unprobed": [{
                "control": "date-filter",
                "reason": "date range has no safe automatic sample",
            }],
        })
        first = self.finalize()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        result = self.assert_phase6()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        (self.workdir / "probe-controls" / "probe-results.json").unlink()
        stale = self.assert_phase6()
        self.assertEqual(21, stale.returncode, stale.stdout + stale.stderr)
        self.assertFalse((self.workdir / "phase6-success.json").exists())

    def test_visual_recorder_rejects_incomplete_blind_grade(self):
        source = self.workdir / "source-pages" / "sheet-1.png"
        target = self.workdir / "visual-qa" / "sheet-1.png"
        grade = self.workdir / "blind-grade.json"
        write_json(grade, {
            "verdict": "pass",
            "source_png": str(source),
            "target_png": str(target),
            "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "target_sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
            "dimensions": {},
            "per_tile": [{
                "position": "main",
                "source_family": "bar",
                "target_family": "bar",
            }],
        })
        checklist = ",".join(
            f"{name}=pass"
            for name in (
                "element_titles_hidden",
                "palette_match",
                "composition_match",
                "chart_shapes_match",
                "labels_legible",
                "numbers_formatted",
            )
        )
        result = self.run_script(
            "record_visual_check.py",
            "--workdir", self.workdir,
            "--verdict", "pass",
            "--agent-vision", "true",
            "--checklist", checklist,
            "--blind-grade", grade,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dimension", result.stderr)

    def test_visual_recorder_rejects_incomplete_tile_census(self):
        readback_path = self.workdir / "wb-readback.json"
        readback = json.loads(readback_path.read_text())
        readback["document"]["pages"][0]["elements"].append({
            "id": "sigma-chart-2",
            "name": "Profit",
            "kind": "line-chart",
            "columns": [{"id": "country-2"}, {"id": "profit"}],
        })
        write_json(readback_path, readback)
        source = self.workdir / "source-pages" / "sheet-1.png"
        target = self.workdir / "visual-qa" / "sheet-1.png"
        dimensions = {
            name: {"verdict": "pass"}
            for name in (
                "element_titles_hidden",
                "palette_match",
                "composition_match",
                "chart_shapes_match",
                "labels_legible",
                "numbers_formatted",
            )
        }
        grade = self.workdir / "blind-grade.json"
        write_json(grade, {
            "verdict": "pass",
            "source_png": str(source),
            "target_png": str(target),
            "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "target_sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
            "dimensions": dimensions,
            "per_tile": [{
                "position": "main",
                "source_family": "bar",
                "target_family": "bar",
            }],
        })
        checklist = ",".join(f"{name}=pass" for name in dimensions)
        result = self.run_script(
            "record_visual_check.py",
            "--workdir", self.workdir,
            "--verdict", "pass",
            "--agent-vision", "true",
            "--checklist", checklist,
            "--blind-grade", grade,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("census", result.stderr)

    def test_visual_census_ignores_hidden_data_page_master(self):
        readback_path = self.workdir / "wb-readback.json"
        readback = json.loads(readback_path.read_text())
        readback["document"]["pages"].append({
            "id": "page-data",
            "name": "Data",
            "visibility": "hidden",
            "elements": [{
                "id": "m-master",
                "name": "Master",
                "kind": "table",
                "columns": [{"id": "master-country"}],
            }],
        })
        readback["document"]["layout"] += (
            '<Page id="page-data" type="grid">'
            '<Element elementId="m-master" gridColumn="1 / 25" '
            'gridRow="1 / 13"/></Page>'
        )
        write_json(readback_path, readback)
        source = self.workdir / "source-pages" / "sheet-1.png"
        target = self.workdir / "visual-qa" / "sheet-1.png"
        dimensions = {
            name: {"verdict": "pass"}
            for name in (
                "element_titles_hidden",
                "palette_match",
                "composition_match",
                "chart_shapes_match",
                "labels_legible",
                "numbers_formatted",
            )
        }
        grade = self.workdir / "blind-grade.json"
        write_json(grade, {
            "verdict": "pass",
            "source_png": str(source),
            "target_png": str(target),
            "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "target_sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
            "dimensions": dimensions,
            "per_tile": [{
                "position": "main",
                "source_family": "bar",
                "target_family": "bar",
            }],
        })
        result = self.run_script(
            "record_visual_check.py",
            "--workdir", self.workdir,
            "--verdict", "pass",
            "--agent-vision", "true",
            "--checklist", ",".join(f"{name}=pass" for name in dimensions),
            "--blind-grade", grade,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_report_check_is_deterministic_and_read_only(self):
        final = self.finalize()
        self.assertEqual(final.returncode, 0, final.stdout + final.stderr)
        before = (self.workdir / "MIGRATION_REPORT.md").read_bytes()
        check = self.run_script(
            "build-migration-report.py", "--workdir", self.workdir, "--check"
        )
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        self.assertEqual(before, (self.workdir / "MIGRATION_REPORT.md").read_bytes())
        (self.workdir / "MIGRATION_REPORT.md").write_text(
            before.decode("utf-8") + "stale\n", encoding="utf-8"
        )
        stale = self.run_script(
            "build-migration-report.py", "--workdir", self.workdir, "--check"
        )
        self.assertEqual(stale.returncode, 1)

    def test_finalizer_has_no_ruby_subprocess(self):
        text = (SCRIPTS / "finalize-qlik-report.py").read_text(encoding="utf-8")
        self.assertNotIn('"ruby"', text)
        self.assertIn("build-migration-report.py", text)


if __name__ == "__main__":
    unittest.main()
