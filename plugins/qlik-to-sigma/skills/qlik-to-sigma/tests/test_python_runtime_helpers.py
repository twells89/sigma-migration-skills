#!/usr/bin/env python3
"""Credentials-free contracts for the Qlik no-Ruby runtime helpers."""

from __future__ import annotations

import ast
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock


SKILL = Path(__file__).resolve().parents[1]
SCRIPTS = SKILL / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from lib import blind_grade as blind_grade_lib


def load_script(filename: str):
    """Load a hyphenated script without executing its command-line entrypoint."""
    path = SCRIPTS / filename
    module_name = "qlik_runtime_test_" + re.sub(r"\W+", "_", filename)
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def write_json(path: Path, value) -> None:
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def workbook(elements, *, layout: str = "", pages=None):
    return {
        "name": "Neutral fixture",
        "folderId": "fixture-folder",
        "document": {
            "schemaVersion": 1,
            "kind": "workbook",
            "pages": pages or [{"id": "page-1", "name": "Overview"}],
            "elements": elements,
            "layout": layout,
        },
    }


PREFLIGHT = load_script("preflight_lint.py")
RENDER_INTEGRITY = load_script("render_integrity.py")
PUT_LAYOUT = load_script("put_layout.py")
LAYOUT_LINT = load_script("layout_lint.py")
CONTROL_LINT = load_script("control_lint.py")
FLIP_GATE = load_script("flip_gate.py")
WAREHOUSE = load_script("preflight_warehouse.py")
DM_PICKER = load_script("find_or_pick_dm.py")
CLEANUP = load_script("cleanup_orphan_workbooks.py")
DOCTOR_GATE = load_script("assert-doctor-ran.py")
INTAKE = load_script("intake.py")
PHASE_GATE = load_script("assert-phase6-ran.py")
RLS_APPLY = load_script("apply_sigma_rls.py")


class WorkbookPreflightTest(unittest.TestCase):
    def test_rejects_ungrouped_aggregate_table_and_malformed_control(self):
        spec = workbook(
            [
                {
                    "id": "table-1",
                    "name": "Sales by Region",
                    "kind": "table",
                    "columns": [
                        {
                            "id": "region",
                            "name": "Region",
                            "formula": "[Master/Region]",
                        },
                        {
                            "id": "sales",
                            "name": "Sales",
                            "formula": "Sum([Master/Sales])",
                        },
                    ],
                },
                {
                    "id": "control-1",
                    "name": "Broken Region Filter",
                    "kind": "control",
                    "controlType": "list",
                    "value": {"values": ["West"]},
                },
            ]
        )

        errors = PREFLIGHT.lint(spec)

        self.assertTrue(any(error.startswith("T1 ") for error in errors), errors)
        self.assertTrue(any(error.startswith("C1 ") for error in errors), errors)
        self.assertTrue(any(error.startswith("C2 ") for error in errors), errors)
        self.assertTrue(any(error.startswith("C3 ") for error in errors), errors)

    def test_accepts_grouped_table_and_well_formed_control(self):
        spec = workbook(
            [
                {
                    "id": "master",
                    "name": "Master",
                    "kind": "table",
                    "columns": [
                        {
                            "id": "region",
                            "name": "Region",
                            "formula": "[Orders/Region]",
                        },
                        {
                            "id": "sales",
                            "name": "Sales",
                            "formula": "Sum([Orders/Sales])",
                        },
                    ],
                    "groupings": [
                        {
                            "id": "group-1",
                            "groupBy": ["region"],
                            "calculations": ["sales"],
                        }
                    ],
                },
                {
                    "id": "control-element",
                    "name": "Region Filter",
                    "kind": "control",
                    "controlId": "region-filter",
                    "controlType": "list",
                    "source": {
                        "kind": "source",
                        "source": {"kind": "table", "elementId": "master"},
                    },
                },
            ]
        )

        self.assertEqual([], PREFLIGHT.lint(spec))


class RenderAndLayoutTest(unittest.TestCase):
    def test_blind_grade_maps_supported_chart_families(self):
        self.assertEqual("kpi", blind_grade_lib.family("progress"))
        self.assertEqual("other", blind_grade_lib.family("box-chart"))
        self.assertEqual("bar", blind_grade_lib.family("waterfall-chart"))
        self.assertEqual("text", blind_grade_lib.family("text"))
        self.assertNotIn("text", blind_grade_lib.CHART_FAMILIES)
        self.assertTrue(
            {"kpi", "other", "bar"}.issubset(blind_grade_lib.CHART_FAMILIES)
        )

    def test_visible_source_page_named_data_remains_in_visual_census(self):
        spec = workbook(
            [{
                "id": "chart-1",
                "name": "Sales",
                "kind": "bar-chart",
                "columns": [{"id": "region"}, {"id": "sales"}],
            }],
            pages=[{"id": "pg-1", "name": "Data"}],
            layout=(
                '<Page id="pg-1"><Element elementId="chart-1" '
                'gridColumn="1 / 25" gridRow="1 / 13"/></Page>'
            ),
        )
        self.assertEqual(["bar"], blind_grade_lib.built_families(spec))

    def test_render_integrity_reports_data_elements_without_usable_bindings(self):
        spec = workbook(
            [
                {
                    "id": "blank-chart",
                    "name": "Blank risk",
                    "kind": "bar-chart",
                    "columns": [
                        {
                            "id": "category",
                            "name": "Category",
                            "formula": "[Master/Category]",
                        }
                    ],
                    "xAxis": {"columnId": "category"},
                },
                {
                    "id": "healthy-kpi",
                    "name": "Revenue",
                    "kind": "kpi-chart",
                    "value": {"columnId": "revenue"},
                },
            ]
        )

        report = RENDER_INTEGRITY.lint(spec, "fixture.json")

        self.assertEqual("FAIL", report["status"])
        self.assertEqual(2, report["elements_checked"])
        self.assertEqual(1, report["blank_risk_count"])
        self.assertEqual("blank-chart", report["elements"][0]["id"])
        self.assertEqual(["no usable data bindings"], report["elements"][0]["reasons"])

    def test_apply_layout_preserves_document_and_injects_valid_sidecars(self):
        raw = workbook(
            [{"id": "chart-1", "name": "Sales", "kind": "bar-chart"}]
        )
        raw["document"]["settings"] = {"theme": {"name": "Neutral"}}
        raw["document"]["panels"] = [{"id": "panel-1"}]
        xml = (
            '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
            'id="page-1"><Element elementId="chart-1" '
            'gridColumn="1 / 25" gridRow="1 / 9"/></Page>'
        )
        warnings = []
        sidecars = {
            "page-1": [
                {"id": "header-1", "name": "Header", "kind": "text"},
                {"id": "chart-1", "name": "Duplicate", "kind": "text"},
            ],
            "unknown-page": [
                {"id": "ignored", "name": "Ignored", "kind": "text"}
            ],
        }

        payload, count = PUT_LAYOUT.apply_layout(
            raw, xml, sidecars, warn=warnings.append
        )

        self.assertEqual({"document"}, set(payload))
        document = payload["document"]
        self.assertEqual(xml, document["layout"])
        self.assertEqual({"theme": {"name": "Neutral"}}, document["settings"])
        self.assertEqual([{"id": "panel-1"}], document["panels"])
        self.assertEqual(["chart-1", "header-1"], [
            element["id"] for element in document["elements"]
        ])
        self.assertEqual(1, count)
        self.assertEqual(1, len(warnings))
        self.assertIn("unknown page", warnings[0])

    def test_layout_and_control_lints_catch_representative_violations(self):
        layout = """
        <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="page-1">
          <Container elementId="header-band" gridColumn="1 / 25" gridRow="1 / 3">
            <Element elementId="title-1" gridColumn="1 / 25" gridRow="1 / 3"/>
          </Container>
          <Container elementId="content-band" gridColumn="1 / 25" gridRow="3 / 12">
            <Element elementId="chart-1" gridColumn="1 / 25" gridRow="3 / 12"/>
          </Container>
          <Element elementId="control-1" gridColumn="1 / 7" gridRow="12 / 14"/>
        </Page>
        """
        layout_spec = workbook(
            [
                {
                    "id": "title-1",
                    "name": "Page title",
                    "kind": "text",
                    "body": "Sheet 1",
                },
                {
                    "id": "chart-1",
                    "name": "abcdefabcdef",
                    "kind": "bar-chart",
                },
                {
                    "id": "control-1",
                    "name": "Region Filter",
                    "kind": "control",
                    "controlId": "region-filter",
                    "controlType": "list",
                },
            ],
            layout=layout,
        )

        layout_errors = LAYOUT_LINT.lint(layout_spec)

        self.assertTrue(
            any("raw-id display name" in error for error in layout_errors),
            layout_errors,
        )
        self.assertTrue(
            any("orphan control" in error for error in layout_errors),
            layout_errors,
        )
        self.assertTrue(
            any("generic header title" in error for error in layout_errors),
            layout_errors,
        )

        control_spec = workbook(
            [
                {
                    "id": "chart-1",
                    "name": "Sales",
                    "kind": "bar-chart",
                },
                {
                    "id": "control-1",
                    "name": "Region Filter",
                    "kind": "control",
                    "controlId": "region-filter",
                    "controlType": "list",
                    "filters": [
                        {
                            "source": {
                                "kind": "table",
                                "elementId": "missing-master",
                            },
                            "columnId": "region",
                        }
                    ],
                },
            ],
            layout=(
                '<Page id="page-1"><Element elementId="chart-1"/>'
                '<Element elementId="control-1"/></Page>'
            ),
        )

        control_errors = CONTROL_LINT.lint(control_spec)

        self.assertTrue(
            any("ghost target" in error for error in control_errors),
            control_errors,
        )
        self.assertTrue(
            any("dead control" in error for error in control_errors),
            control_errors,
        )


class DecisionAndCatalogTest(unittest.TestCase):
    def test_flip_gate_classifies_pass_fail_skip_and_errors(self):
        passing = [{"result": "PASS", "control": "Region"}]
        failing = [{"result": "FAIL", "control": "Region", "note": "unchanged"}]
        skipped = [{"result": "SKIP", "control": "Date", "note": "no values"}]

        self.assertEqual("ok", FLIP_GATE.decide(0, passing)[0])
        self.assertEqual("advisory", FLIP_GATE.decide(0, skipped)[0])
        decision, details = FLIP_GATE.decide(1, failing)
        self.assertEqual("fail", decision)
        self.assertEqual([("Region", "unchanged")], details["fails"])
        self.assertEqual("error", FLIP_GATE.decide(1, passing)[0])
        self.assertEqual("advisory", FLIP_GATE.decide(2, None)[0])
        self.assertEqual(0, FLIP_GATE.derive_rc(passing))
        self.assertEqual(1, FLIP_GATE.derive_rc(failing))
        self.assertEqual(2, FLIP_GATE.derive_rc(skipped))

    def test_warehouse_preflight_resolves_case_and_reports_missing_columns(self):
        connection_id = "fixture-connection"
        reconcile = [
            {
                "qlikTable": "Orders",
                "sourceTable": '"sales"',
                "fields": [
                    {
                        "qlikField": "Region",
                        "realColumn": "region",
                        "isExpression": False,
                    },
                    {
                        "qlikField": "Gross",
                        "realColumn": "gross_amount",
                        "isExpression": False,
                    },
                    {
                        "qlikField": "Adjusted",
                        "isExpression": True,
                        "expressionColumns": ["Region", "tax"],
                    },
                ],
            }
        ]
        calls = []

        def lookup(actual_connection, path):
            calls.append(("lookup", actual_connection, path))
            return {"kind": "table", "inodeId": "inode-1"}

        def list_columns(inode):
            calls.append(("columns", inode))
            return [{"name": "REGION"}, {"name": "NET_REVENUE"}]

        resolved, report = WAREHOUSE.preflight_tables(
            reconcile,
            connection_id=connection_id,
            database="ANALYTICS",
            schema="PUBLIC",
            catalog_paths=[
                {
                    "connectionId": connection_id,
                    "path": ["Analytics", "Public", "Sales"],
                }
            ],
            lookup=lookup,
            list_columns=list_columns,
        )

        self.assertEqual(
            ["ANALYTICS", "PUBLIC", "orders"],
            WAREHOUSE.expected_path('"orders"', "ANALYTICS", "PUBLIC"),
        )
        self.assertEqual("Analytics.Public.Sales", resolved[0]["sourceTable"])
        self.assertEqual("REGION", resolved[0]["fields"][0]["realColumn"])
        self.assertEqual(
            ["region", "tax"],
            resolved[0]["fields"][2]["expressionColumnsResolved"],
        )
        self.assertEqual(["gross_amount", "tax"], report["tables"][0]["missingColumns"])
        self.assertIn("missing required column(s): gross_amount, tax", report["errors"][0])
        self.assertEqual(
            [
                (
                    "lookup",
                    connection_id,
                    ["Analytics", "Public", "Sales"],
                ),
                ("columns", "inode-1"),
            ],
            calls,
        )

    def test_dm_picker_scores_and_selects_entirely_from_local_cache(self):
        signature = {
            "app": "Orders",
            "warehouse_tables": ["DB.PUBLIC.ORDERS"],
            "referenced_columns": ["Order ID", "Revenue"],
            "measures": [{"col": "Revenue", "derivation": "sum"}],
        }
        cache = {
            "dms": [
                {
                    "dataModelId": "dm-full",
                    "name": "Orders",
                    "updatedAt": "2026-01-02T00:00:00Z",
                },
                {
                    "dataModelId": "dm-partial",
                    "name": "Orders Archive",
                    "updatedAt": "2026-01-01T00:00:00Z",
                },
            ],
            "specs": {
                "dm-full": {
                    "elements": [
                        {
                            "id": "orders",
                            "source": {
                                "kind": "warehouse-table",
                                "path": ["DB", "PUBLIC", "ORDERS"],
                            },
                            "columns": [
                                {"name": "Order ID"},
                                {"name": "Revenue"},
                            ],
                            "metrics": [
                                {"name": "REVENUE", "aggregation": "sum"}
                            ],
                        }
                    ]
                },
                "dm-partial": {
                    "elements": [
                        {
                            "id": "orders-old",
                            "source": {
                                "kind": "warehouse-table",
                                "path": ["DB", "PUBLIC", "ORDERS"],
                            },
                            "columns": [{"name": "Order ID"}],
                        }
                    ]
                },
            },
        }

        with mock.patch.object(
            DM_PICKER.sigma_rest,
            "request",
            side_effect=AssertionError("network access is forbidden"),
        ):
            result = DM_PICKER.scan(
                signature,
                cache=cache,
                limit=25,
                max_fetch=25,
                min_score=0.6,
                auto_pick=True,
                auto_pick_threshold=0.8,
                tie_window=0.05,
            )

        self.assertEqual("dm-full", result["recommended_dm_id"])
        self.assertTrue(result["auto_picked"])
        self.assertEqual(1.0, result["score"])
        self.assertEqual("dm-full", result["candidates"][0]["dm_id"])
        self.assertEqual(2, result["scanned_dm_count"])


class OfflineBoundaryTest(unittest.TestCase):
    def test_security_apply_writes_model_and_denorm_bound_decision(self):
        with tempfile.TemporaryDirectory() as temporary:
            workdir = Path(temporary)
            decision_path = workdir / "security-decision.json"
            spec = {
                "pages": [{"elements": [{
                    "id": "denorm-1",
                    "name": "Custom SQL",
                    "kind": "table",
                    "columns": [{"id": "region", "name": "Region"}],
                }]}],
            }

            def api(method, path, body=None):
                if method == "GET":
                    return spec
                if method == "PUT":
                    return {"dataModelId": "dm-1"}
                raise AssertionError((method, path, body))

            security = [{
                "kind": "rls",
                "rls": {
                    "name": "Sales Team RLS",
                    "formula": 'CurrentUserInTeam("Sales")',
                    "userAttributes": [],
                    "teams": ["Sales"],
                },
            }]
            with mock.patch.object(RLS_APPLY, "api", side_effect=api):
                result = RLS_APPLY.apply_from_security(
                    "dm-1",
                    security,
                    True,
                    False,
                    decision_out=decision_path,
                    run_id="run-1",
                    decision="port",
                    required_element_id="denorm-1",
                )
            self.assertEqual(0, result)
            decision = json.loads(decision_path.read_text())
            self.assertEqual("dm-1", decision["dataModelId"])
            self.assertEqual("denorm-1", decision["securedElementId"])
            self.assertEqual("run-1", decision["run_id"])
            self.assertTrue(decision["readback_verified"])
            self.assertEqual(1, decision["rules_applied"])
            self.assertFalse(decision["membership_verified"])

    def test_mixed_control_probe_requires_complete_skip_marker(self):
        with tempfile.TemporaryDirectory() as temporary:
            workdir = Path(temporary)
            probe = workdir / "probe-controls"
            probe.mkdir()
            export = probe / "pass.csv"
            export.write_text("Region,Sales\nWest,10\n", encoding="utf-8")
            write_json(probe / "probe-results.json", [
                {"control": "region-filter", "result": "PASS"},
                {"control": "date-filter", "result": "SKIP"},
            ])
            write_json(probe / "probe-evidence.json", {
                "workbook_id": "wb-1",
                "doc_version": "7",
                "probed_at": datetime.now(timezone.utc).isoformat(),
                "exports": {
                    export.name: hashlib.sha256(export.read_bytes()).hexdigest(),
                },
            })
            controls = [
                {"id": "region-control", "controlId": "region-filter"},
                {"id": "date-control", "controlId": "date-filter"},
            ]
            with self.assertRaises(PHASE_GATE.GateFailure):
                PHASE_GATE.gate_flip(
                    workdir,
                    "wb-1",
                    "7",
                    controls,
                    True,
                    None,
                )
            write_json(workdir / "control-flip-unverified.json", {
                "workbookId": "wb-1",
                "unprobed": [{
                    "control": "date-filter",
                    "reason": "no safe automatic date sample",
                }],
            })
            PHASE_GATE.gate_flip(
                workdir,
                "wb-1",
                "7",
                controls,
                True,
                None,
            )

    def test_cleanup_no_ledger_and_single_ledger_never_call_network(self):
        def forbidden_requester(_method, _path):
            raise AssertionError("cleanup attempted network access")

        with tempfile.TemporaryDirectory() as temporary:
            no_ledger = Path(temporary) / "none"
            no_ledger.mkdir()
            output = io.StringIO()
            result = CLEANUP.cleanup(
                no_ledger,
                None,
                dry_run=False,
                requester=forbidden_requester,
                output_stream=output,
                error_stream=io.StringIO(),
            )
            self.assertEqual(0, result)
            self.assertIn("nothing to clean up", output.getvalue())

            single = Path(temporary) / "single"
            single.mkdir()
            (single / "posted-workbooks.jsonl").write_text(
                json.dumps({"id": "workbook_fixture"}) + "\n",
                encoding="utf-8",
            )
            result = CLEANUP.cleanup(
                single,
                None,
                dry_run=False,
                requester=forbidden_requester,
                output_stream=io.StringIO(),
                error_stream=io.StringIO(),
            )
            self.assertEqual(0, result)
            marker = json.loads(
                (single / "cleanup-marker.json").read_text(encoding="utf-8")
            )
            self.assertEqual("workbook_fixture", marker["kept"])
            self.assertEqual([], marker["deleted"])
            self.assertEqual([], marker["failed"])

    def test_assert_doctor_ran_accepts_python_node_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            workdir = Path(temporary)
            runtime_profile = {
                "selected": "python",
                "required_runtimes": ["python", "node"],
            }
            write_json(
                workdir / "doctor.json",
                {
                    "pass": True,
                    "runtime_profile": runtime_profile,
                    "runtimes": {"python": True, "node": True, "ruby": False},
                },
            )
            write_json(
                workdir / "bootstrap.json",
                {
                    "doctor_pass": True,
                    "runtime_profile": runtime_profile,
                },
            )

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = DOCTOR_GATE.main(
                    ["--workdir", str(workdir), "--runtime-profile", "python"]
                )

            self.assertEqual(0, result)
            self.assertIn("profile=python", output.getvalue())
            self.assertIn("runtimes=python,node", output.getvalue())

    def test_intake_resolves_named_connection_fixture_without_network(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workdir = root / "work"
            fixture = root / "connections.json"
            write_json(
                fixture,
                {
                    "entries": [
                        {
                            "connectionId": "11111111-1111-4111-8111-111111111111",
                            "name": "Neutral Warehouse",
                            "type": "snowflake",
                            "host": "example.invalid",
                        },
                        {
                            "connectionId": "22222222-2222-4222-8222-222222222222",
                            "name": "Secondary Fixture",
                            "type": "postgres",
                        },
                    ]
                },
            )
            completed = subprocess.CompletedProcess([], 0)
            with (
                mock.patch.object(INTAKE.subprocess, "run", return_value=completed),
                mock.patch.object(
                    INTAKE.sigma_rest,
                    "request",
                    side_effect=AssertionError("network access is forbidden"),
                ),
                mock.patch.dict(os.environ, {"SIGMA_CONNECTION_ID": ""}, clear=False),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                result = INTAKE.main(
                    [
                        "--workdir",
                        str(workdir),
                        "--connections-fixture",
                        str(fixture),
                        "--name",
                        "neutral",
                    ]
                )

            self.assertEqual(0, result)
            connection = json.loads(
                (workdir / "connection.json").read_text(encoding="utf-8")
            )
            self.assertEqual(
                "11111111-1111-4111-8111-111111111111",
                connection["connection_id"],
            )
            self.assertEqual("Neutral Warehouse", connection["name"])
            intake = json.loads(
                (workdir / "intake.json").read_text(encoding="utf-8")
            )
            self.assertEqual("qlik-to-sigma", intake["tool"])
            self.assertEqual("live", intake["input_mode"])

    def test_orchestrator_is_ruby_free_and_orders_hard_gates(self):
        path = SCRIPTS / "migrate-qlik.py"
        text = path.read_text(encoding="utf-8")
        tree = ast.parse(text, filename=str(path))

        ruby_strings = []
        for node in ast.walk(tree):
            if not isinstance(node, ast.Constant) or not isinstance(node.value, str):
                continue
            tokens = re.findall(r"[A-Za-z0-9_.+-]+", node.value.casefold())
            if "ruby" in tokens or "ruby.exe" in tokens:
                ruby_strings.append((node.lineno, node.value))
        self.assertEqual([], ruby_strings)

        subprocess_calls = [
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "subprocess"
        ]
        self.assertTrue(subprocess_calls)
        for call in subprocess_calls:
            if not call.args or not isinstance(call.args[0], (ast.List, ast.Tuple)):
                continue
            literal_tokens = [
                token.casefold()
                for item in call.args[0].elts
                if isinstance(item, ast.Constant) and isinstance(item.value, str)
                for token in re.findall(r"[A-Za-z0-9_.+-]+", item.value)
            ]
            self.assertNotIn("ruby", literal_tokens)
            self.assertNotIn("ruby.exe", literal_tokens)

        python_command = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "python_command"
        )
        command_return = next(
            node for node in ast.walk(python_command) if isinstance(node, ast.Return)
        )
        self.assertIsInstance(command_return.value, ast.List)
        executable = command_return.value.elts[0]
        self.assertIsInstance(executable, ast.Attribute)
        self.assertEqual(("sys", "executable"), (executable.value.id, executable.attr))

        normalize = text.index('"normalize-qlik-expressions.py"')
        blank_risk = text.index('"blank-risk-elements.json"', normalize)
        post = text.index("self.execute(workbook_command)", blank_risk)
        parity = text.index("    def parity(", post)
        cleanup = text.index('"cleanup_orphan_workbooks.py"', parity)
        shared_assert = text.index(
            "assertion = self.execute(assert_command", cleanup
        )
        terminal_finalizer = text.index(
            "post_finalizer = self.execute(finalizer_command", shared_assert
        )
        terminal_verify = text.index('"verify-complete.py"', terminal_finalizer)
        self.assertLess(normalize, blank_risk)
        self.assertLess(blank_risk, post)
        self.assertLess(post, parity)
        self.assertLess(parity, cleanup)
        self.assertLess(cleanup, shared_assert)
        self.assertLess(shared_assert, terminal_finalizer)
        self.assertLess(terminal_finalizer, terminal_verify)


if __name__ == "__main__":
    unittest.main()
