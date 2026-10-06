#!/usr/bin/env python3
"""Focused offline contracts for the Sisense uplift orchestration layer."""
import base64
import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
SCRIPTS = SKILL / "scripts"
FIXTURES = SKILL / "fixtures"


def command(script, *args, env=None, cwd=None):
    return subprocess.run(
        [sys.executable if str(script).endswith(".py") else "ruby", str(script), *map(str, args)],
        cwd=cwd, env={**os.environ, **(env or {})},
        capture_output=True, text=True,
    )


def dump(path, value):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def load_orchestrator():
    spec = importlib.util.spec_from_file_location(
        "migrate_sisense", SCRIPTS / "migrate-sisense.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MockSigma(BaseHTTPRequestHandler):
    posts = []

    def log_message(self, _format, *_args):
        return

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.__class__.posts.append((self.path, self.rfile.read(length)))
        if self.path == "/v2/dataModels/spec":
            body = b"dataModelId: dm-yaml\n"
        elif self.path == "/v2/workbooks/spec":
            body = b"workbookId: wb-yaml\n"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/yaml")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/v2/dataModels/dm-yaml/spec":
            body = {"name": "DM", "pages": [{"elements": [
                {"id": "fact-live", "name": "Fact", "columns": [{"id": "c"}]}
            ]}]}
        elif self.path == "/v2/workbooks/wb-yaml/spec":
            body = {"name": "WB", "document": {"pages": [], "elements": []}}
        else:
            self.send_error(404)
            return
        payload = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class UpliftContracts(unittest.TestCase):
    def test_live_target_values_are_each_required_before_any_write(self):
        required_flags = {
            "connection": ("--connection-id", "connection-id"),
            "database": ("--database", "database"),
            "schema": ("--schema", "schema"),
            "folder": ("--folder-id", "folder-id"),
        }
        MockSigma.posts = []
        server = ThreadingHTTPServer(("127.0.0.1", 0), MockSigma)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as home:
                for missing_name, (_missing_flag, expected_message) in required_flags.items():
                    with self.subTest(missing=missing_name), tempfile.TemporaryDirectory() as td:
                        args = [
                            "--cube", "Customer Cube", "--workdir", td,
                        ]
                        for name, (flag, _message) in required_flags.items():
                            if name != missing_name:
                                args += [flag, "resolved-%s" % name]
                        result = command(
                            SCRIPTS / "migrate-sisense.py", *args,
                            env={
                                "HOME": home,
                                "SIGMA_CONNECTION_ID": "",
                                "SISENSE_TARGET_DATABASE": "",
                                "SISENSE_TARGET_SCHEMA": "",
                                "SIGMA_FOLDER_ID": "",
                                "SIGMA_BASE_URL": (
                                    "http://127.0.0.1:%d" % server.server_port
                                ),
                                "SIGMA_API_TOKEN": "must-not-be-used",
                            },
                        )
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(expected_message, result.stderr)
                        self.assertFalse((Path(td) / "run-state.json").exists())
                        self.assertFalse((Path(td) / "posted-workbooks.jsonl").exists())
            self.assertEqual(MockSigma.posts, [])
        finally:
            server.shutdown()
            server.server_close()

    def test_help_identifies_live_requirements_and_dry_defaults(self):
        result = command(SCRIPTS / "migrate-sisense.py", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        help_text = " ".join(result.stdout.split())
        self.assertIn("required live (env: SIGMA_CONNECTION_ID)", help_text)
        self.assertIn("required live (env: SISENSE_TARGET_DATABASE)", help_text)
        self.assertIn("required live (env: SISENSE_TARGET_SCHEMA)", help_text)
        self.assertIn("required live (env: SIGMA_FOLDER_ID)", help_text)
        self.assertIn("permits fixture DEMO_DB/SISENSE_ECOMMERCE defaults",
                      help_text)

    def test_dry_run_orders_offline_work_and_never_stamps_success(self):
        with tempfile.TemporaryDirectory() as td:
            result = command(
                SCRIPTS / "migrate-sisense.py",
                "--dry-run", "--workdir", td,
                env={
                    "SIGMA_BASE_URL": "http://127.0.0.1:1",
                    "SIGMA_API_TOKEN": "must-not-be-used",
                    "SISENSE_BASE_URL": "http://127.0.0.1:1",
                    "SISENSE_API_TOKEN": "must-not-be-used",
                },
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            state = json.loads((Path(td) / "run-state.json").read_text())
            phases = [row["name"] for row in state["phases"]]
            self.assertEqual(phases[:6], [
                "start", "discovery", "gap-preflight", "rls-decision",
                "convert-model", "dm-reuse",
            ])
            self.assertIn("workbook-convert-layout", phases)
            self.assertFalse(state["post_complete"])
            self.assertFalse(state["parity_complete"])
            self.assertFalse(state["render_complete"])
            self.assertFalse(state["success_stamped"])
            self.assertFalse((Path(td) / "phase6-success.json").exists())
            self.assertFalse((Path(td) / "posted-workbooks.jsonl").exists())
            for artifact in (
                "gap-report.json", "sigma_dm_spec.json", "sigma_workbook_spec.json",
                "blank-risk-elements.json", "parity-plan.json",
                "source-object-census.json", "coverage.json",
                "sisense-controls-coverage.json", "dm-signature.json",
                "dm-match.json",
            ):
                self.assertTrue((Path(td) / artifact).is_file(), artifact)
            match = json.loads((Path(td) / "dm-match.json").read_text())
            self.assertEqual(match["scan_status"], "skipped-offline")
            self.assertIsNone(match["recommended_dm_id"])

    def test_dm_signature_uses_converted_paths_columns_and_measures(self):
        with tempfile.TemporaryDirectory() as td:
            converted = command(
                SCRIPTS / "convert.py", "model", FIXTURES / "model_ecommerce.json",
                "00000000-0000-0000-0000-000000000000",
                "SISENSE_ECOMMERCE", "DEMO_DB",
                "--dashboards", FIXTURES / "dashboards.json",
                cwd=td,
            )
            self.assertEqual(converted.returncode, 0, converted.stderr)
            output = Path(td) / "dm-signature.json"
            built = command(
                SCRIPTS / "sisense-dm-signature.py",
                "--model", FIXTURES / "model_ecommerce.json",
                "--dm-spec", Path(td) / "sigma_dm_spec.json",
                "--database", "DEMO_DB", "--schema", "SISENSE_ECOMMERCE",
                "--out", output,
            )
            self.assertEqual(built.returncode, 0, built.stderr)
            signature = json.loads(output.read_text())
            self.assertIn("DEMO_DB.SISENSE_ECOMMERCE.COMMERCE",
                          signature["warehouse_tables"])
            self.assertIn("REVENUE", signature["referenced_columns"])
            self.assertIn(
                {"col": "REVENUE", "derivation": "Sum"},
                signature["measures"],
            )

    def test_post_readback_accepts_yaml_and_resume_never_reposts(self):
        MockSigma.posts = []
        server = ThreadingHTTPServer(("127.0.0.1", 0), MockSigma)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as td:
                dm_spec = Path(td) / "dm.json"
                wb_spec = Path(td) / "wb.json"
                dump(dm_spec, {"name": "DM", "pages": []})
                dump(wb_spec, {"name": "WB", "document": {"pages": [], "elements": []}})
                env = {
                    "SIGMA_BASE_URL": "http://127.0.0.1:%d" % server.server_port,
                    "SIGMA_API_TOKEN": "test",
                    "SIGMA_ALLOW_INSECURE_BASE_URL": "1",
                }
                first = command(SCRIPTS / "post-sisense-spec.py", "dm",
                                "--spec", dm_spec, "--workdir", td, env=env)
                self.assertEqual(first.returncode, 0, first.stderr)
                resumed = command(SCRIPTS / "post-sisense-spec.py", "dm",
                                  "--spec", dm_spec, "--workdir", td, env=env)
                self.assertEqual(resumed.returncode, 0, resumed.stderr)
                workbook = command(SCRIPTS / "post-sisense-spec.py", "workbook",
                                   "--spec", wb_spec, "--workdir", td, env=env)
                self.assertEqual(workbook.returncode, 0, workbook.stderr)
                self.assertEqual([path for path, _body in MockSigma.posts],
                                 ["/v2/dataModels/spec", "/v2/workbooks/spec"])
                self.assertEqual(json.loads((Path(td) / "dm-ids.json").read_text())
                                 ["dataModelId"], "dm-yaml")
                self.assertTrue((Path(td) / "dm-readback.json").is_file())
                posted = [json.loads(line) for line in
                          (Path(td) / "posted-workbooks.jsonl").read_text().splitlines()]
                self.assertEqual(posted, [{"id": "wb-yaml", "name": "WB"}])
        finally:
            server.shutdown()
            server.server_close()

    def test_post_refuses_readback_without_recoverable_id(self):
        MockSigma.posts = []
        server = ThreadingHTTPServer(("127.0.0.1", 0), MockSigma)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as td:
                spec = Path(td) / "dm.json"
                dump(spec, {"name": "DM", "pages": []})
                dump(Path(td) / "dm-readback.json", {"name": "DM", "pages": []})
                result = command(
                    SCRIPTS / "post-sisense-spec.py", "dm",
                    "--spec", spec, "--workdir", td,
                    env={
                        "SIGMA_BASE_URL": "http://127.0.0.1:%d" % server.server_port,
                        "SIGMA_API_TOKEN": "test",
                        "SIGMA_ALLOW_INSECURE_BASE_URL": "1",
                    },
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("refusing to blindly re-POST", result.stderr)
                self.assertEqual(MockSigma.posts, [])
        finally:
            server.shutdown()
            server.server_close()

    def test_zero_parity_is_red(self):
        with tempfile.TemporaryDirectory() as td:
            plan = Path(td) / "plan.json"
            detail = Path(td) / "detail.json"
            output = Path(td) / "parity-final.json"
            dump(plan, {"charts": [], "tile_census": {"source_tiles": 1}})
            dump(detail, [])
            result = command(
                SCRIPTS / "build-sisense-parity.py", "normalize",
                "--plan", plan, "--results", detail, "--out", output,
            )
            self.assertEqual(result.returncode, 1)
            final = json.loads(output.read_text())
            self.assertEqual(final["status"], "FAIL")
            self.assertEqual(final["charts_total"], 0)
            self.assertFalse(final["strict_complete"])

    def test_tile_boxes_come_from_authoritative_inline_layout(self):
        module = load_orchestrator()
        workbook = {
            "document": {
                "elements": [
                    {"id": "master", "name": "Master", "kind": "table"},
                    {"id": "control", "name": "Region", "kind": "control"},
                    {"id": "chart", "name": "Revenue", "kind": "bar-chart"},
                ],
                "layout": (
                    '<Page id="data"><Element elementId="master" '
                    'gridColumn="1 / 25" gridRow="1 / 13"/></Page>'
                    '<Page id="main"><Element elementId="control" '
                    'gridColumn="1 / 25" gridRow="1 / 4"/>'
                    '<Element elementId="chart" gridColumn="1 / 25" '
                    'gridRow="4 / 12"/></Page>'
                ),
            }
        }
        with tempfile.TemporaryDirectory() as td:
            output = Path(td) / "tiles.json"
            rows, unplaced, fill = module.tile_boxes(workbook, "main", output)
            self.assertEqual([row["name"] for row in rows], ["Revenue"])
            self.assertEqual(unplaced, [])
            self.assertGreater(fill, 0.9)
            self.assertEqual(json.loads(output.read_text()), rows)

    def test_control_scope_no_source_controls_passes(self):
        with tempfile.TemporaryDirectory() as td:
            dashboards = Path(td) / "dashboards.json"
            workbook = Path(td) / "workbook.json"
            scope = Path(td) / "control-scope.json"
            dump(dashboards, [{"title": "D", "filters": [], "widgets": []}])
            dump(workbook, {
                "document": {
                    "pages": [{"id": "main", "name": "Main"}],
                    "elements": [{"id": "chart", "name": "Revenue", "kind": "bar-chart"}],
                    "layout": (
                        '<Page id="main"><Element elementId="chart" '
                        'gridColumn="1 / 25" gridRow="1 / 10"/></Page>'
                    ),
                }
            })
            built = command(
                SCRIPTS / "build-sisense-control-scope.py",
                "--dashboards", dashboards, "--workbook", workbook, "--out", scope,
            )
            self.assertEqual(built.returncode, 0, built.stderr)
            document = json.loads(scope.read_text())
            self.assertEqual(document["sourceFilterSignals"], 0)
            self.assertEqual(document["controls"], [])
            lint = command(SCRIPTS / "lib/control_lint.rb", workbook, scope)
            self.assertEqual(lint.returncode, 0, lint.stdout + lint.stderr)

    def test_control_scope_fully_wired_duplicate_names_use_stable_ids(self):
        with tempfile.TemporaryDirectory() as td:
            dashboards = Path(td) / "dashboards.json"
            workbook = Path(td) / "workbook.json"
            scope = Path(td) / "control-scope.json"
            dump(dashboards, [{
                "title": "D",
                "filters": [{"jaql": {"title": "Region", "dim": "[Sales.Region]"}}],
                "widgets": [],
            }])
            dump(workbook, {
                "document": {
                    "pages": [
                        {"id": "data", "name": "Data"},
                        {"id": "main", "name": "Main"},
                    ],
                    "elements": [
                        {"id": "master", "name": "Master", "kind": "table"},
                        {
                            "id": "region-control", "name": "Region", "kind": "control",
                            "controlId": "Region", "controlType": "list",
                            "filters": [{"source": {"elementId": "master"}, "columnId": "c"}],
                        },
                        {
                            "id": "chart-a", "name": "Revenue", "kind": "bar-chart",
                            "source": {"elementId": "master"},
                        },
                        {
                            "id": "chart-b", "name": "Revenue", "kind": "bar-chart",
                            "source": {"elementId": "master"},
                        },
                    ],
                    "layout": (
                        '<Page id="data"><Element elementId="master" '
                        'gridColumn="1 / 25" gridRow="1 / 10"/></Page>'
                        '<Page id="main"><Element elementId="region-control" '
                        'gridColumn="1 / 25" gridRow="1 / 4"/>'
                        '<Element elementId="chart-a" gridColumn="1 / 13" '
                        'gridRow="4 / 12"/>'
                        '<Element elementId="chart-b" gridColumn="13 / 25" '
                        'gridRow="4 / 12"/></Page>'
                    ),
                }
            })
            built = command(
                SCRIPTS / "build-sisense-control-scope.py",
                "--dashboards", dashboards, "--workbook", workbook, "--out", scope,
            )
            self.assertEqual(built.returncode, 0, built.stderr)
            row = json.loads(scope.read_text())["controls"][0]
            self.assertEqual(row["status"], "emitted")
            self.assertEqual(row["mustReach"], ["chart-a", "chart-b"])
            lint = command(SCRIPTS / "lib/control_lint.rb", workbook, scope)
            self.assertEqual(lint.returncode, 0, lint.stdout + lint.stderr)

    def test_control_scope_missing_control_fails(self):
        with tempfile.TemporaryDirectory() as td:
            dashboards = Path(td) / "dashboards.json"
            workbook = Path(td) / "workbook.json"
            scope = Path(td) / "control-scope.json"
            dump(dashboards, [{
                "title": "D",
                "filters": [{"jaql": {"title": "Region", "dim": "[Sales.Region]"}}],
                "widgets": [],
            }])
            dump(workbook, {
                "document": {
                    "pages": [{"id": "main", "name": "Main"}],
                    "elements": [{"id": "chart", "name": "Revenue", "kind": "bar-chart"}],
                    "layout": (
                        '<Page id="main"><Element elementId="chart" '
                        'gridColumn="1 / 25" gridRow="1 / 10"/></Page>'
                    ),
                }
            })
            built = command(
                SCRIPTS / "build-sisense-control-scope.py",
                "--dashboards", dashboards, "--workbook", workbook, "--out", scope,
            )
            self.assertEqual(built.returncode, 0, built.stderr)
            document = json.loads(scope.read_text())
            self.assertEqual(document["controls"][0]["status"], "unbound")
            self.assertEqual(len(document["unbound"]), 1)
            lint = command(SCRIPTS / "lib/control_lint.rb", workbook, scope)
            self.assertNotEqual(lint.returncode, 0)
            self.assertIn("missing control", lint.stderr)

    def test_visual_comparison_is_never_automatically_waived(self):
        module = load_orchestrator()
        plain = argparse.Namespace(
            skip_visual_comparison=None, waive_source_page=[]
        )
        self.assertEqual(module.visual_gate_options(plain), [])
        explicit = argparse.Namespace(
            skip_visual_comparison="operator accepted", waive_source_page=[]
        )
        self.assertEqual(module.visual_gate_options(explicit), [
            "--skip-visual-comparison", "operator accepted",
        ])

    def test_accounting_handles_mixed_outcomes_and_rejects_unaccounted(self):
        with tempfile.TemporaryDirectory() as td:
            gap = Path(td) / "gap-report.json"
            dump(gap, {
                "summary": {"objects": 3},
                "objects": [
                    {"type": "model-table", "id": "t", "name": "Fact",
                     "status": "auto", "evidence": ["mapped"],
                     "source": {"artifact": "model.json", "json_pointer": "/t"}},
                    {"type": "widget", "id": "w", "name": "Custom",
                     "status": "manual", "evidence": ["manual"],
                     "source": {"artifact": "dash.json", "json_pointer": "/w"}},
                    {"type": "dashboard", "id": "d", "name": "Dash",
                     "status": "not-applicable", "evidence": ["container"],
                     "source": {"artifact": "dash.json", "json_pointer": "/d"}},
                ],
                "gaps": [],
            })
            dump(Path(td) / "sigma_dm_spec.json", {
                "pages": [{"elements": [{"id": "fact", "name": "Fact", "columns": []}]}]
            })
            dump(Path(td) / "sigma_workbook_spec.json", {
                "document": {"pages": [{"id": "p", "name": "Dash"}], "elements": []}
            })
            result = command(
                SCRIPTS / "build-sisense-accounting.py",
                "--workdir", td, "--gap-report", gap,
                "--dm-spec", Path(td) / "sigma_dm_spec.json",
                "--wb-spec", Path(td) / "sigma_workbook_spec.json",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = json.loads((Path(td) / "source-object-census.json").read_text())["objects"]
            self.assertEqual({row["id"]: row["status"] for row in rows},
                             {"t": "migrated", "w": "needs-review",
                              "d": "not-applicable"})
            bad = json.loads(gap.read_text())
            bad["objects"][0]["evidence"] = []
            dump(gap, bad)
            rejected = command(
                SCRIPTS / "build-sisense-accounting.py",
                "--workdir", td, "--gap-report", gap,
                "--dm-spec", Path(td) / "sigma_dm_spec.json",
                "--wb-spec", Path(td) / "sigma_workbook_spec.json",
            )
            self.assertEqual(rejected.returncode, 1)
            census = json.loads((Path(td) / "source-object-census.json").read_text())
            self.assertFalse(census["summary"]["complete"])

    def test_blank_png_fails_visual_finalization(self):
        # 1x1 opaque white PNG.
        white_png = base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8"
            "/x8AAusB9Y9Z0k8AAAAASUVORK5CYII="
        )
        with tempfile.TemporaryDirectory() as td:
            target = Path(td) / "page.png"
            target.write_bytes(white_png)
            result = command(
                SCRIPTS / "finalize-sisense-report.py",
                "--workdir", td, "--target-png", "page=%s" % target,
                "--waive-source-page", "page=source export unavailable",
                "--visual-only",
            )
            self.assertNotEqual(result.returncode, 0)
            health = json.loads((Path(td) / "render-health.json").read_text())
            self.assertEqual(health["status"], "FAIL")

    def test_report_contradiction_is_red(self):
        with tempfile.TemporaryDirectory() as td:
            census = {
                "summary": {"total": 1, "accounted": 1, "complete": True},
                "objects": [{"type": "widget", "id": "w", "name": "W",
                             "status": "migrated"}],
            }
            dump(Path(td) / "source-object-census.json", census)
            dump(Path(td) / "coverage.json", {
                "objects": [{"type": "widget", "source_object_id": "w",
                             "name": "W", "status": "needs-review"}]
            })
            dump(Path(td) / "parity-final.json", {
                "status": "PASS", "charts_total": 1, "charts_pass": 1
            })
            dump(Path(td) / "render-health.json", {"status": "PASS"})
            result = subprocess.run([
                "ruby", str(SCRIPTS / "build-migration-report.rb"),
                "--workdir", td, "--inventory", str(Path(td) / "source-object-census.json"),
            ], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            report = json.loads((Path(td) / "migration-result.json").read_text())
            self.assertEqual(report["verdict"], "RED")

    def test_shared_assert_is_invoked_not_reimplemented(self):
        source = (SCRIPTS / "migrate-sisense.py").read_text(encoding="utf-8")
        self.assertIn('HERE / "assert-phase6-ran.rb"', source)
        self.assertIn('"--control-scope", control_scope', source)
        self.assertIn('"--require-control-flip"', source)
        self.assertIn('HERE / "record-visual-check.rb"', source)
        self.assertLess(
            source.index('HERE / "assert-phase6-ran.rb"'),
            source.index('phase("10", "post-gate accounting and final report")'),
        )
        self.assertEqual(len(list(SCRIPTS.glob("assert-phase6-ran.rb"))), 1)

    def test_complete_fixture_passes_terminal_verifier(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            obj = {"type": "dashboard", "id": "d", "name": "D",
                   "status": "not-applicable"}
            dump(root / "run-state.json", {
                "mode": "live", "complete": True, "post_complete": True,
                "parity_complete": True, "render_complete": True,
            })
            dump(root / "source-object-census.json", {
                "summary": {"total": 1, "accounted": 1, "complete": True},
                "objects": [obj],
            })
            dump(root / "parity-final.json", {
                "status": "PASS", "strict_complete": True,
                "charts_total": 1, "charts_pass": 1, "charts_fail": 0,
            })
            time.sleep(0.01)
            dump(root / "render-health.json", {"status": "PASS", "images": []})
            dump(root / "degradation-ledger.json", {"entries": [], "counts": {}})
            time.sleep(0.01)
            dump(root / "migration-result.json", {
                "verdict": "GREEN",
                "summary": {"total": 1, "accounted": 1, "complete": True},
                "source_objects": [obj],
            })
            time.sleep(0.01)
            dump(root / "sisense-report-finalization.json", {"status": "PASS"})
            dump(root / "phase6-success.json", {
                "gates": "all-pass", "workbookId": "wb", "chartCount": 1,
            })
            result = subprocess.run([
                "ruby", str(SCRIPTS / "verify-complete.rb"),
                "--workdir", td, "--workbook-id", "wb",
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            parity = json.loads((root / "parity-final.json").read_text())
            parity.pop("strict_complete")
            dump(root / "parity-final.json", parity)
            not_strict = subprocess.run([
                "ruby", str(SCRIPTS / "verify-complete.rb"),
                "--workdir", td, "--workbook-id", "wb",
            ], capture_output=True, text=True)
            self.assertEqual(not_strict.returncode, 3)


if __name__ == "__main__":
    unittest.main()
