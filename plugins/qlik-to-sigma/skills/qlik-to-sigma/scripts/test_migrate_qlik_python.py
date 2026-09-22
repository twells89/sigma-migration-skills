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
                if path.endswith("/columns"):
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

            self.assertTrue(parity_ok and layout_ok and controls_ok and flip_ok)
            self.assertEqual("warehouse", parity["mode"])
            self.assertEqual("warehouse", parity["verified_against"])
            self.assertEqual("WAREHOUSE-PASS", parity["per_chart"][0]["status"])
            self.assertEqual(["--source-parity-unavailable"], parity["waivers"])

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
