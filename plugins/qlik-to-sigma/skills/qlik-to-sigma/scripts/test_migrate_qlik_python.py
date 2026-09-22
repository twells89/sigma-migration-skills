#!/usr/bin/env python3
"""Ordering, exit-code, and no-Ruby contract tests for migrate-qlik.py."""

from __future__ import annotations

import ast
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

HERE = Path(__file__).resolve().parent
ENTRYPOINT = HERE / "migrate-qlik.py"


def load_entrypoint():
    specification = importlib.util.spec_from_file_location(
        "migrate_qlik_python_entrypoint", ENTRYPOINT
    )
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot import {ENTRYPOINT}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


migrate = load_entrypoint()


class CliContractTests(unittest.TestCase):
    def test_cli_preserves_the_ruby_entrypoint_flags(self) -> None:
        parsed = migrate.parse_args(
            [
                "--app",
                "app",
                "--connection",
                "conn",
                "--database",
                "db",
                "--schema",
                "schema",
                "--context",
                "ctx",
                "--folder",
                "folder",
                "--name",
                "prefix",
                "--out",
                "/tmp/out",
                "--answers",
                "{}",
                "--yes",
                "--from-discovery",
                "/tmp/discovery",
                "--reuse-dm",
                "dm",
                "--no-reuse",
                "--dry-run",
                "--skip-layout-lint",
                "--skip-control-flip",
                "flip reason",
                "--skip-visual-comparison",
                "visual reason",
                "--skip-visual-similarity",
                "similarity reason",
                "--skip-anchors-gate",
                "anchor reason",
                "--print-converter",
            ]
        )
        self.assertEqual("app", parsed.app)
        self.assertEqual("conn", parsed.conn)
        self.assertEqual("db", parsed.database)
        self.assertEqual("schema", parsed.schema)
        self.assertEqual("ctx", parsed.context)
        self.assertEqual("folder", parsed.folder)
        self.assertEqual("prefix", parsed.name)
        self.assertEqual("/tmp/out", parsed.out)
        self.assertEqual("{}", parsed.answers)
        self.assertTrue(parsed.yes)
        self.assertEqual("/tmp/discovery", parsed.from_discovery)
        self.assertEqual("dm", parsed.reuse_dm)
        self.assertTrue(parsed.no_reuse)
        self.assertTrue(parsed.dry_run)
        self.assertTrue(parsed.skip_layout_lint)
        self.assertEqual("flip reason", parsed.skip_control_flip)
        self.assertEqual("visual reason", parsed.skip_visual_comparison)
        self.assertEqual("similarity reason", parsed.skip_visual_similarity)
        self.assertEqual("anchor reason", parsed.skip_anchors_gate)
        self.assertTrue(parsed.print_converter)
        self.assertEqual("/tmp/unbuild", migrate.parse_args(["--unbuild", "/tmp/unbuild"]).unbuild)
        self.assertEqual("/tmp/prj", migrate.parse_args(["--prj", "/tmp/prj"]).prj)

    def test_optional_control_flip_reason_matches_ruby_semantics(self) -> None:
        self.assertIs(
            True,
            migrate.parse_args(["--skip-control-flip"]).skip_control_flip,
        )
        self.assertEqual(
            "known export limitation",
            migrate.parse_args(
                ["--skip-control-flip", "known export limitation"]
            ).skip_control_flip,
        )

    def test_entrypoint_does_not_write_the_completion_marker(self) -> None:
        source = ENTRYPOINT.read_text(encoding="utf-8")
        self.assertNotRegex(
            source,
            r"(?:write_text|open)\s*\([^\\n]*phase6-success\\.json",
        )

    def test_columns_endpoint_is_exhaustively_paginated(self) -> None:
        responses = [
            {
                "entries": [{"label": "first", "type": {"type": "text"}}],
                "nextPageToken": "p2",
            },
            {
                "entries": [{"label": "second", "type": {"type": "text"}}],
                "nextPage": "p3",
            },
            {
                "entries": [{"label": "broken", "type": {"type": "error"}}],
            },
        ]
        with mock.patch.object(
            migrate.sigma_rest,
            "request",
            side_effect=responses,
        ) as request:
            rows = migrate.sigma_entries("/v2/workbooks/wb-1/columns")
        self.assertEqual(3, len(rows))
        self.assertEqual("error", rows[-1]["type"]["type"])
        self.assertIn("limit=1000", request.call_args_list[0].args[1])
        self.assertIn("pageToken=p2", request.call_args_list[1].args[1])
        self.assertIn("page=p3", request.call_args_list[2].args[1])

    def test_content_page_filter_uses_reserved_ids_not_substrings(self) -> None:
        self.assertTrue(migrate.is_content_page({
            "id": "customer-data",
            "name": "Data",
        }))
        self.assertFalse(migrate.is_content_page({
            "id": "page-data",
            "name": "Data",
            "visibility": "hidden",
        }))

    def test_numeric_parity_handles_zero_percent_and_display_rounding(self) -> None:
        self.assertEqual(0.0, migrate.Migration.numeric(0))
        self.assertEqual(0.42, migrate.Migration.numeric("42%"))
        self.assertTrue(
            migrate.Migration.chart_rows_match(
                [["West", 10.504]],
                [["West", "10.50"]],
                1,
            )
        )
        self.assertFalse(
            migrate.Migration.chart_rows_match(
                [["West", 10.51]],
                [["West", "10.50"]],
                1,
            )
        )


class NoRubyContractTests(unittest.TestCase):
    RUNTIME_FILES = (
        "migrate-qlik.py",
        "assert-doctor-ran.py",
        "preflight_warehouse.py",
        "preflight_lint.py",
        "render_integrity.py",
        "put_layout.py",
        "layout_lint.py",
        "control_lint.py",
        "probe_controls.py",
        "cleanup_orphan_workbooks.py",
        "find_or_pick_dm.py",
        "verify_anchors.py",
        "verify_trellis_survived.py",
        "lib/degradation_ledger.py",
        "build-migration-report.py",
        "finalize-qlik-report.py",
        "assert-phase6-ran.py",
        "verify-complete.py",
    )

    def test_python_runtime_has_no_ruby_command_or_import(self) -> None:
        failures = []
        for filename in self.RUNTIME_FILES:
            path = HERE / filename
            tree = ast.parse(path.read_text(encoding="utf-8"), filename=filename)
            for node in ast.walk(tree):
                if isinstance(node, (ast.Import, ast.ImportFrom)):
                    names = (
                        [alias.name for alias in node.names]
                        if isinstance(node, ast.Import)
                        else [str(node.module or "")]
                    )
                    if any(name.casefold() == "ruby" for name in names):
                        failures.append(f"{filename}: imports Ruby")
                if not isinstance(node, ast.Call):
                    continue
                function_name = (
                    node.func.attr
                    if isinstance(node.func, ast.Attribute)
                    else node.func.id
                    if isinstance(node.func, ast.Name)
                    else ""
                )
                if function_name not in {
                    "run",
                    "Popen",
                    "call",
                    "check_call",
                    "check_output",
                    "execute",
                    "python_command",
                }:
                    continue
                for argument in node.args:
                    for value_node in ast.walk(argument):
                        if not (
                            isinstance(value_node, ast.Constant)
                            and isinstance(value_node.value, str)
                        ):
                            continue
                        value = value_node.value.strip().casefold()
                        if value == "ruby" or value.endswith(".rb"):
                            failures.append(
                                f"{filename}: Ruby command/script literal "
                                f"{value_node.value!r}"
                            )
        self.assertEqual([], failures)


class OrchestrationTests(unittest.TestCase):
    @staticmethod
    def args(*extra: str):
        return migrate.parse_args(
            ["--app", "app-id", "--connection", "connection-id", "--yes", *extra]
        )

    def configure_migration(
        self, migration, workdir: Path, events: list[str], decision: int | None
    ) -> None:
        def prepare() -> None:
            events.append("prepare")

        def validate() -> None:
            events.append("validate")
            migration.workdir = workdir

        def discover():
            events.append("discover")
            return (
                {"appName": "Orders", "tables": []},
                [],
                [],
                {"name": "Orders"},
                {},
                [],
            )

        def convert(_converter_input):
            events.append("convert")
            return {"warnings": [], "stats": {}}, workdir / "converter-out.json"

        def dm_reuse() -> None:
            events.append("dm-reuse")

        def decisions(*_arguments):
            events.append("decisions")
            return decision

        def build(*_arguments):
            events.append("build")
            return (
                {"dataModelId": "dm-1"},
                {
                    "workbookId": "wb-1",
                    "queryableElements": 1,
                    "unbuiltSourceVisuals": [],
                },
                "dm-1",
            )

        def render(_workbook_id):
            events.append("render")
            return workdir / "render.png"

        def parity(*_arguments):
            events.append("parity")
            return True, True, True, True, {"status": "PASS"}

        def terminal(*_arguments):
            events.append("terminal")
            return 3

        migration.prepare_source = prepare
        migration.validate_front_door = validate
        migration.discover = discover
        migration.convert = convert
        migration.dm_reuse_scan = dm_reuse
        migration.decisions = decisions
        migration.build = build
        migration.render_pages = render
        migration.parity = parity
        migration.terminal = terminal

    def test_live_path_orders_all_gates_and_propagates_terminal_red(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workdir = Path(temporary)
            (workdir / "workbook-coverage.json").write_text(
                json.dumps({"sourceVisualIds": ["chart-1"]}),
                encoding="utf-8",
            )
            events: list[str] = []
            migration = migrate.Migration(self.args())
            self.configure_migration(migration, workdir, events, decision=None)
            self.assertEqual(3, migration.run())
            self.assertEqual(
                [
                    "prepare",
                    "validate",
                    "discover",
                    "convert",
                    "dm-reuse",
                    "decisions",
                    "build",
                    "render",
                    "parity",
                    "terminal",
                ],
                events,
            )

    def test_decision_checkpoint_exits_ten_before_any_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            events: list[str] = []
            migration = migrate.Migration(self.args())
            self.configure_migration(
                migration, Path(temporary), events, decision=10
            )
            self.assertEqual(10, migration.run())
            self.assertEqual(
                [
                    "prepare",
                    "validate",
                    "discover",
                    "convert",
                    "dm-reuse",
                    "decisions",
                ],
                events,
            )

    def test_section_access_default_stops_before_unsecured_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            migration = migrate.Migration(self.args())
            migration.workdir = Path(temporary)
            result = migration.decisions(
                "Secured App",
                {"warnings": []},
                {"hasSectionAccess": True},
                [],
            )
            self.assertEqual(10, result)
            self.assertFalse((Path(temporary) / "security-decision.json").exists())

    def test_section_access_script_stops_even_when_metadata_is_false(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workdir = Path(temporary)
            (workdir / "script.qvs").write_text(
                "SECTION ACCESS;\nLOAD USERID, REDUCTION INLINE [];\n",
                encoding="utf-8",
            )
            migration = migrate.Migration(self.args())
            migration.workdir = workdir
            result = migration.decisions(
                "Secured App",
                {"warnings": []},
                {"hasSectionAccess": False},
                [],
            )
            self.assertEqual(10, result)

    def test_removed_skip_chart_answer_fails_instead_of_being_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            migration = migrate.Migration(
                migrate.parse_args([
                    "--app", "app-id",
                    "--connection", "connection-id",
                    "--answers", '{"chart_no_native_kind":"skip this chart"}',
                ])
            )
            migration.workdir = Path(temporary)
            with self.assertRaisesRegex(ValueError, "invalid answer"):
                migration.decisions(
                    "Orders",
                    {"warnings": []},
                    {},
                    [{
                        "id": "unsupported-1",
                        "title": "Unsupported",
                        "vizType": "unsupported-kind",
                    }],
                )

    def test_dry_run_exits_zero_before_render_and_terminal_gates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            events: list[str] = []
            migration = migrate.Migration(self.args("--dry-run"))
            self.configure_migration(
                migration, Path(temporary), events, decision=None
            )
            self.assertEqual(0, migration.run())
            self.assertEqual("build", events[-1])
            self.assertNotIn("render", events)
            self.assertNotIn("terminal", events)

    def test_offline_source_uses_honest_warehouse_execution_parity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workdir = Path(temporary)
            migration = migrate.Migration(self.args())
            migration.args.app = None
            migration.workdir = workdir
            (workdir / "element-map.json").write_text(
                json.dumps([{
                    "elementId": "el-1",
                    "name": "Sales",
                    "kind": "bar-chart",
                    "qlik": {"objectId": "chart-1", "dims": ["Region"]},
                }]),
                encoding="utf-8",
            )
            (workdir / "control-scope.json").write_text(
                json.dumps({
                    "sourceFilterSignals": 0,
                    "controls": [],
                    "unbound": [],
                }),
                encoding="utf-8",
            )
            live = {
                "workbookId": "wb-1",
                "latestDocumentVersion": 7,
                "document": {
                    "pages": [{"id": "page-1", "name": "Overview"}],
                    "elements": [{
                        "id": "el-1",
                        "name": "Sales",
                        "kind": "bar-chart",
                        "columns": [
                            {"id": "region", "name": "Region"},
                            {"id": "sales", "name": "Sales"},
                        ],
                    }],
                    "layout": (
                        '<Page id="page-1" type="grid" '
                        'gridTemplateColumns="repeat(24, 1fr)" '
                        'gridTemplateRows="auto"><Element elementId="el-1" '
                        'gridColumn="1 / 25" gridRow="1 / 13"/></Page>'
                    ),
                },
            }

            def api(_method, path, **_kwargs):
                if "/columns" in path:
                    return {
                        "entries": [{
                            "elementId": "el-1",
                            "type": {"type": "number"},
                        }]
                    }
                if path.endswith("/spec"):
                    return live
                raise AssertionError(path)

            migration.export_elements = lambda *_args: {
                "el-1": "Region,Sales\nWest,10\n"
            }
            with mock.patch.object(migrate.sigma_rest, "request", side_effect=api):
                parity_ok, layout_ok, controls_ok, flip_ok, parity = migration.parity(
                    {"workbookId": "wb-1"},
                    "dm-1",
                    {},
                    {},
                    [{"id": "chart-1", "title": "Sales"}],
                    {
                        "sourceVisualIds": ["chart-1"],
                        "builtSourceVisualIds": ["chart-1"],
                    },
                )

            self.assertFalse(parity_ok)
            self.assertTrue(layout_ok and controls_ok and flip_ok)
            self.assertEqual("warehouse", parity["mode"])
            self.assertEqual("warehouse-executability", parity["verified_against"])
            self.assertEqual("WAREHOUSE-PASS", parity["per_chart"][0]["status"])
            self.assertFalse(parity["strict"])
            self.assertEqual("WAREHOUSE-ONLY", parity["status"])

            expected = workdir / "warehouse-expected.json"
            expected.write_text(
                json.dumps({"chart-1": [["West", "10"]]}),
                encoding="utf-8",
            )
            migration.args.warehouse_expected = str(expected)
            with mock.patch.object(migrate.sigma_rest, "request", side_effect=api):
                strict_ok, _, _, _, strict = migration.parity(
                    {"workbookId": "wb-1"},
                    "dm-1",
                    {},
                    {},
                    [{"id": "chart-1", "title": "Sales"}],
                    {
                        "sourceVisualIds": ["chart-1"],
                        "builtSourceVisualIds": ["chart-1"],
                    },
                )
            self.assertTrue(strict_ok)
            self.assertTrue(strict["strict"])
            self.assertEqual("warehouse-expected", strict["mode"])
            self.assertEqual("MATCH", strict["per_chart"][0]["status"])

    def test_progress_visual_participates_in_source_value_parity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workdir = Path(temporary)
            migration = migrate.Migration(self.args())
            migration.args.app = None
            migration.workdir = workdir
            (workdir / "element-map.json").write_text(
                json.dumps([{
                    "elementId": "progress-1",
                    "name": "Sales Gauge",
                    "kind": "progress",
                    "qlik": {
                        "objectId": "gauge-1",
                        "dims": [],
                        "measures": ["Sum(Sales)"],
                    },
                }]),
                encoding="utf-8",
            )
            (workdir / "control-scope.json").write_text(
                json.dumps({
                    "sourceFilterSignals": 0,
                    "controls": [],
                    "unbound": [],
                }),
                encoding="utf-8",
            )
            live = {
                "workbookId": "wb-1",
                "latestDocumentVersion": 7,
                "document": {
                    "pages": [{"id": "page-1", "name": "Overview"}],
                    "elements": [{
                        "id": "progress-1",
                        "name": "Sales Gauge",
                        "kind": "progress",
                        "value": "Sum([Master/Sales])",
                    }],
                    "layout": (
                        '<Page id="page-1"><Element elementId="progress-1" '
                        'gridColumn="1 / 25" gridRow="1 / 13"/></Page>'
                    ),
                },
            }

            def api(_method, path, **_kwargs):
                if "/columns" in path:
                    return {
                        "entries": [{
                            "elementId": "progress-1",
                            "type": {"type": "number"},
                        }]
                    }
                if path.endswith("/spec"):
                    return live
                raise AssertionError(path)

            migration.export_elements = lambda *_args: {
                "progress-1": "Value\n42\n"
            }
            with mock.patch.object(migrate.sigma_rest, "request", side_effect=api):
                parity_ok, _, _, _, parity = migration.parity(
                    {"workbookId": "wb-1"},
                    "dm-1",
                    {},
                    {"kpis": [{"expr": "Sum(Sales)", "value": "42"}]},
                    [{"id": "gauge-1", "title": "Sales Gauge"}],
                    {
                        "sourceVisualIds": ["gauge-1"],
                        "builtSourceVisualIds": ["gauge-1"],
                    },
                )
            self.assertTrue(parity_ok)
            self.assertEqual(1, parity["charts_total"])
            self.assertEqual("MATCH", parity["per_chart"][0]["status"])
            self.assertEqual("progress", parity["per_chart"][0]["kind"])

            element_map = json.loads(
                (workdir / "element-map.json").read_text()
            )
            element_map[0]["qlik"]["measures"].append("Avg(Margin)")
            (workdir / "element-map.json").write_text(
                json.dumps(element_map),
                encoding="utf-8",
            )
            with mock.patch.object(migrate.sigma_rest, "request", side_effect=api):
                parity_ok, _, _, _, parity = migration.parity(
                    {"workbookId": "wb-1"},
                    "dm-1",
                    {},
                    {
                        "kpis": [
                            {"expr": "Sum(Sales)", "value": "42"},
                            {"expr": "Avg(Margin)", "value": "0.25"},
                        ]
                    },
                    [{"id": "gauge-1", "title": "Sales Gauge"}],
                    {
                        "sourceVisualIds": ["gauge-1"],
                        "builtSourceVisualIds": ["gauge-1"],
                    },
                )
            self.assertFalse(parity_ok)
            self.assertEqual(
                "SECONDARY-MEASURE-UNBUILT",
                parity["per_chart"][0]["status"],
            )

    def test_live_chart_parity_compares_full_hypercube_values(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workdir = Path(temporary)
            migration = migrate.Migration(self.args())
            migration.args.app = None
            migration.workdir = workdir
            (workdir / "element-map.json").write_text(
                json.dumps([{
                    "elementId": "bar-1",
                    "name": "Sales by Region",
                    "kind": "bar-chart",
                    "qlik": {
                        "objectId": "chart-1",
                        "dims": ["Region"],
                        "measures": ["Sum(Sales)"],
                    },
                }]),
                encoding="utf-8",
            )
            (workdir / "control-scope.json").write_text(
                json.dumps({
                    "sourceFilterSignals": 0,
                    "controls": [],
                    "unbound": [],
                }),
                encoding="utf-8",
            )
            live = {
                "workbookId": "wb-1",
                "latestDocumentVersion": 7,
                "document": {
                    "pages": [{"id": "page-1", "name": "Overview"}],
                    "elements": [{
                        "id": "bar-1",
                        "name": "Sales by Region",
                        "kind": "bar-chart",
                        "columns": [
                            {"id": "region", "name": "Region"},
                            {"id": "sales", "name": "Sales"},
                        ],
                    }],
                    "layout": (
                        '<Page id="page-1"><Element elementId="bar-1" '
                        'gridColumn="1 / 25" gridRow="1 / 13"/></Page>'
                    ),
                },
            }

            def api(_method, path, **_kwargs):
                if "/columns" in path:
                    return {
                        "entries": [{
                            "elementId": "bar-1",
                            "type": {"type": "number"},
                        }]
                    }
                if path.endswith("/spec"):
                    return live
                raise AssertionError(path)

            migration.export_elements = lambda *_args: {
                "bar-1": "Region,Sales\nWest,10\n"
            }
            base_snapshot = {
                "buckets": [{
                    "expr": "Count(distinct [Region])",
                    "value": "1",
                }],
                "chartData": [{
                    "objectId": "chart-1",
                    "dimensionCount": 1,
                    "measureCount": 1,
                    "rows": [["West", 10.0]],
                    "complete": True,
                }],
            }
            coverage = {
                "sourceVisualIds": ["chart-1"],
                "builtSourceVisualIds": ["chart-1"],
            }
            with mock.patch.object(migrate.sigma_rest, "request", side_effect=api):
                matched, _, _, _, parity = migration.parity(
                    {"workbookId": "wb-1"},
                    "dm-1",
                    {},
                    base_snapshot,
                    [{"id": "chart-1", "title": "Sales by Region"}],
                    coverage,
                )
            self.assertTrue(matched)
            self.assertEqual("MATCH", parity["per_chart"][0]["status"])

            mismatched_snapshot = json.loads(json.dumps(base_snapshot))
            mismatched_snapshot["chartData"][0]["rows"][0][1] = 11.0
            with mock.patch.object(migrate.sigma_rest, "request", side_effect=api):
                matched, _, _, _, parity = migration.parity(
                    {"workbookId": "wb-1"},
                    "dm-1",
                    {},
                    mismatched_snapshot,
                    [{"id": "chart-1", "title": "Sales by Region"}],
                    coverage,
                )
            self.assertFalse(matched)
            self.assertEqual("VALUE-MISMATCH", parity["per_chart"][0]["status"])

    def test_render_failure_cannot_reuse_prior_page_png(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workdir = Path(temporary)
            visual = workdir / "visual-qa"
            visual.mkdir()
            stale = visual / "page-1.png"
            stale.write_bytes(b"\x89PNG\r\n\x1a\n" + b"stale" * 20)
            (workdir / "wb-spec.json").write_text(
                json.dumps({
                    "document": {
                        "pages": [{"id": "page-1", "name": "Overview"}],
                        "elements": [],
                    }
                }),
                encoding="utf-8",
            )
            migration = migrate.Migration(self.args())
            migration.workdir = workdir
            migration.execute = lambda *_args, **_kwargs: SimpleNamespace(
                returncode=1,
                stdout="render failed",
            )
            with mock.patch.object(
                migrate.sigma_rest,
                "request",
                return_value={
                    "workbookId": "wb-1",
                    "latestDocumentVersion": 9,
                    "document": {},
                },
            ):
                rendered = migration.render_pages("wb-1")
            self.assertIsNone(rendered)
            self.assertFalse(stale.exists())
            evidence = json.loads(
                (workdir / "render-evidence.json").read_text()
            )
            self.assertEqual([], evidence["images"])
            self.assertEqual("9", evidence["documentVersion"])

    def test_terminal_gate_order_is_cleanup_finalize_assert_finalize(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workdir = Path(temporary)
            migration = migrate.Migration(self.args())
            migration.workdir = workdir
            commands: list[str] = []

            def execute(command, **_kwargs):
                script = Path(str(command[1])).name
                commands.append(script)
                return SimpleNamespace(
                    returncode=1 if script == "assert-phase6-ran.py" else 0,
                    stdout="",
                )

            migration.execute = execute
            with mock.patch.object(migration, "summary"):
                result = migration.terminal(
                    {
                        "workbookId": "wb-1",
                        "queryableElements": 1,
                        "unbuiltSourceVisuals": [],
                    },
                    "dm-1",
                    True,
                    True,
                    True,
                    True,
                    None,
                )
            self.assertEqual(3, result)
            self.assertEqual(
                [
                    "cleanup_orphan_workbooks.py",
                    "finalize-qlik-report.py",
                    "assert-phase6-ran.py",
                    "finalize-qlik-report.py",
                    "verify-complete.py",
                ],
                commands,
            )
            self.assertFalse((workdir / "phase6-success.json").exists())


if __name__ == "__main__":
    unittest.main()
