#!/usr/bin/env python3
"""Offline run-state and mocked live-sequence tests."""
import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
sys.path.insert(0, SCRIPTS)

import migrate_spotfire  # noqa: E402


SCRIPT = os.path.join(SKILL, "scripts", "migrate_spotfire.py")
FIXTURES = os.path.join(SKILL, "fixtures")


def run_migration(workdir, *extra):
    return subprocess.run(
        [
            sys.executable, SCRIPT,
            "--from-discovery", FIXTURES,
            "--source-map", os.path.join(FIXTURES, "source-map.json"),
            "--workdir", workdir,
            *extra,
        ],
        capture_output=True,
        text=True,
    )


def read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


class MigrateSpotfireTests(unittest.TestCase):
    def test_dry_run_generates_artifacts_without_false_success(self):
        with tempfile.TemporaryDirectory() as directory:
            result = run_migration(directory, "--dry-run")
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            state = read_json(os.path.join(directory, "run-state.json"))
            self.assertEqual("dry-run-complete", state["status"])
            self.assertTrue(state["conversion_complete"])
            for key in (
                "complete", "post_complete", "parity_complete",
                "render_complete", "success_stamped",
                "reuse_check_complete", "data_model_post_complete",
                "data_model_readback_complete", "workbook_post_complete",
                "workbook_readback_complete",
                "warehouse_verification_complete",
                "source_visual_comparison_complete",
                "gap_decisions_complete",
                "source_parity_claimed",
            ):
                self.assertFalse(state[key], key)
            phase_status = {
                phase["name"]: phase["status"] for phase in state["phases"]
            }
            self.assertEqual("not-run", phase_status["post"])
            self.assertEqual(
                "not-run", phase_status["warehouse-verification"]
            )
            self.assertEqual(
                "not-run", phase_status["source-visual-comparison"]
            )
            for name in (
                "sigma_dm_spec.json", "sigma_workbook_spec.json",
                "gap-report.json", "conversion-gaps.json",
                "completion-gaps.json",
                "resolved-sources.json", "workbook-signature.json",
                "manifest-validation.json", "dm-reuse-decision.json",
            ):
                self.assertTrue(os.path.isfile(os.path.join(directory, name)), name)

    def test_dry_run_never_calls_api_or_subprocess(self):
        with tempfile.TemporaryDirectory() as directory:
            class ExplodingApi:
                @staticmethod
                def request(*_args, **_kwargs):
                    raise AssertionError("dry-run made an API request")

            def exploding_runner(*_args, **_kwargs):
                raise AssertionError("dry-run invoked a subprocess")

            exit_code = migrate_spotfire.main(
                [
                    "--manifest",
                    os.path.join(FIXTURES, "spotfire-manifest.json"),
                    "--source-map",
                    os.path.join(FIXTURES, "source-map.json"),
                    "--workdir",
                    directory,
                    "--dry-run",
                ],
                api=ExplodingApi(),
                runner=exploding_runner,
            )
            self.assertEqual(0, exit_code)
            state = read_json(os.path.join(directory, "run-state.json"))
            self.assertEqual("dry-run-complete", state["status"])
            self.assertFalse(state["post_complete"])
            self.assertFalse(state["complete"])
            self.assertFalse(state["success_stamped"])

    def test_mocked_live_sequence_posts_reads_back_and_checkpoints(self):
        class FakeApi:
            def __init__(self):
                self.calls = []
                self.dm_readback = None
                self.workbook_readback = None

            def request(self, method, path, body=None):
                parsed = json.loads(body) if body else None
                self.calls.append((method, path, parsed))
                if method == "post" and path == "/v2/dataModels/spec":
                    self.assertEqual("folder-1", parsed["folderId"])
                    self.dm_readback = copy.deepcopy(parsed)
                    element_ids = {}
                    column_ids = {}
                    for element in self.dm_readback["pages"][0]["elements"]:
                        local_element_id = element["id"]
                        element["id"] = "server-dm-" + element["name"].lower()
                        element_ids[local_element_id] = element["id"]
                        for index, column in enumerate(element["columns"]):
                            local_column_id = column["id"]
                            column["id"] = "server-dm-column-%d" % index
                            column_ids[local_column_id] = column["id"]
                    for element in self.dm_readback["pages"][0]["elements"]:
                        for relationship in element.get(
                                "relationships", []):
                            relationship["targetElementId"] = element_ids[
                                relationship["targetElementId"]
                            ]
                            for key in relationship.get("keys", []):
                                key["sourceColumnId"] = column_ids[
                                    key["sourceColumnId"]
                                ]
                                key["targetColumnId"] = column_ids[
                                    key["targetColumnId"]
                                ]
                    return {"dataModelId": "server-dm"}
                if method == "get" and path == "/v2/dataModels/server-dm/spec":
                    return copy.deepcopy(self.dm_readback)
                if (
                    method == "get"
                    and path.startswith(
                        "/v2/dataModels/server-dm/columns?"
                    )
                ):
                    return {"entries": []}
                if (
                    method == "post"
                    and path == "/v2/workbooks/spec/verify"
                ):
                    self.assertEqual("folder-1", parsed["folderId"])
                    return {"valid": True}
                if method == "post" and path == "/v2/workbooks/spec":
                    self.workbook_readback = copy.deepcopy(parsed)
                    return {"workbookId": "server-workbook"}
                if (
                    method == "get"
                    and path == "/v2/workbooks/server-workbook/spec"
                ):
                    return copy.deepcopy(self.workbook_readback)
                if (
                    method == "get"
                    and path.startswith(
                        "/v2/workbooks/server-workbook/columns?"
                    )
                ):
                    return {"entries": []}
                raise AssertionError((method, path))

            def assertEqual(self, expected, actual):
                if expected != actual:
                    raise AssertionError((expected, actual))

        class FakeRunner:
            def __init__(self):
                self.calls = []

            @staticmethod
            def value_after(command, flag):
                return command[command.index(flag) + 1]

            def __call__(self, command, **_kwargs):
                command = [str(value) for value in command]
                self.calls.append(command)
                script = os.path.basename(command[1])
                if script == "find-or-pick-dm.rb":
                    output = self.value_after(command, "--out")
                    with open(output, "w", encoding="utf-8") as handle:
                        json.dump({
                            "recommended_dm_id": None,
                            "auto_picked": False,
                            "score": 0.0,
                            "rationale": "no reusable model in mocked estate",
                        }, handle)
                    return SimpleNamespace(
                        returncode=1, stdout="", stderr=""
                    )
                if script == "build-parity-plan.rb":
                    output = self.value_after(command, "--out")
                    with open(output, "w", encoding="utf-8") as handle:
                        json.dump({"charts": [{
                            "chart": "Revenue by Region",
                            "sigma_element_id": "viz-revenue",
                            "sigma_kind": "bar-chart",
                            "sigma_columns": ["revenue"],
                        }]}, handle)
                    return SimpleNamespace(
                        returncode=0, stdout="plan built", stderr=""
                    )
                if script == "verify-warehouse.rb":
                    output = self.value_after(command, "--out")
                    workbook_id = self.value_after(
                        command, "--workbook-id"
                    )
                    with open(output, "w", encoding="utf-8") as handle:
                        json.dump({
                            "workbook_id": workbook_id,
                            "mode": "warehouse",
                            "verified_against": "warehouse",
                            "charts_total": 1,
                            "charts_pass": 1,
                            "charts_fail": 0,
                            "status": "PASS",
                        }, handle)
                    return SimpleNamespace(
                        returncode=0,
                        stdout="WAREHOUSE VERIFICATION ONLY",
                        stderr="",
                    )
                if script in (
                    "preflight_lint.rb",
                    "layout_lint.rb",
                    "control_lint.rb",
                ):
                    return SimpleNamespace(
                        returncode=0, stdout="clean", stderr=""
                    )
                raise AssertionError(command)

        with tempfile.TemporaryDirectory() as directory:
            api = FakeApi()
            runner = FakeRunner()
            exit_code = migrate_spotfire.main(
                [
                    "--manifest",
                    os.path.join(FIXTURES, "spotfire-manifest.json"),
                    "--source-map",
                    os.path.join(FIXTURES, "source-map.json"),
                    "--folder-id",
                    "folder-1",
                    "--workdir",
                    directory,
                ],
                api=api,
                runner=runner,
            )
            self.assertEqual(
                migrate_spotfire.EXIT_SOURCE_VISUAL_CHECKPOINT,
                exit_code,
            )
            state = read_json(os.path.join(directory, "run-state.json"))
            self.assertEqual(
                "warehouse-verified-source-visual-checkpoint",
                state["status"],
            )
            for key in (
                "manifest_validated", "conversion_complete",
                "signature_complete", "reuse_check_complete",
                "data_model_post_complete",
                "data_model_readback_complete",
                "workbook_lints_complete", "workbook_post_complete",
                "workbook_readback_complete", "post_complete",
                "warehouse_verification_complete",
                "parity_complete",
            ):
                self.assertTrue(state[key], key)
            for key in (
                "complete", "render_complete",
                "source_visual_comparison_complete",
                "source_parity_claimed", "success_stamped",
            ):
                self.assertFalse(state[key], key)
            workbook = read_json(os.path.join(
                directory, "sigma_workbook_spec.json"
            ))
            data_model_sources = [
                element["source"]
                for element in workbook["document"]["elements"]
                if element.get("source", {}).get("kind") == "data-model"
            ]
            self.assertTrue(data_model_sources)
            self.assertEqual(
                {"server-dm"},
                {source["dataModelId"] for source in data_model_sources},
            )
            self.assertTrue(all(
                source["elementId"].startswith("server-dm-")
                for source in data_model_sources
            ))
            script_names = [
                os.path.basename(command[1]) for command in runner.calls
            ]
            self.assertEqual(
                [
                    "find-or-pick-dm.rb",
                    "preflight_lint.rb",
                    "layout_lint.rb",
                    "control_lint.rb",
                    "build-parity-plan.rb",
                    "verify-warehouse.rb",
                ],
                script_names,
            )
            api_paths = [path for _method, path, _body in api.calls]
            self.assertEqual(
                [
                    "/v2/dataModels/spec",
                    "/v2/dataModels/server-dm/spec",
                    "/v2/dataModels/server-dm/columns?limit=1000",
                    "/v2/workbooks/spec/verify",
                    "/v2/workbooks/spec",
                    "/v2/workbooks/server-workbook/spec",
                    (
                        "/v2/workbooks/server-workbook/columns"
                        "?limit=1000"
                    ),
                ],
                api_paths,
            )
            initial_posts = [
                call for call in api.calls if call[0] == "post"
            ]
            resumed = migrate_spotfire.main(
                [
                    "--manifest",
                    os.path.join(FIXTURES, "spotfire-manifest.json"),
                    "--source-map",
                    os.path.join(FIXTURES, "source-map.json"),
                    "--workdir",
                    directory,
                    "--resume-live",
                ],
                api=api,
                runner=runner,
            )
            self.assertEqual(
                migrate_spotfire.EXIT_SOURCE_VISUAL_CHECKPOINT,
                resumed,
            )
            self.assertEqual(
                initial_posts,
                [call for call in api.calls if call[0] == "post"],
            )
            resumed_state = read_json(os.path.join(
                directory, "run-state.json"
            ))
            self.assertTrue(resumed_state["workbook_reused"])
            self.assertFalse(resumed_state["workbook_post_complete"])

            manifest = read_json(os.path.join(
                FIXTURES, "spotfire-manifest.json"
            ))
            visual_records = []
            for index, page in enumerate(
                    migrate_spotfire.convert._manifest_pages(manifest)):
                if not migrate_spotfire.convert._page_visuals(page):
                    continue
                source_image = os.path.join(
                    directory, "source-page-%d.png" % index
                )
                sigma_image = os.path.join(
                    directory, "sigma-page-%d.png" % index
                )
                source_bytes = b"source-page-" + bytes([index])
                sigma_bytes = b"sigma-page-" + bytes([index])
                with open(source_image, "wb") as handle:
                    handle.write(source_bytes)
                with open(sigma_image, "wb") as handle:
                    handle.write(sigma_bytes)
                visual_records.append({
                    "source_page_id":
                        migrate_spotfire.convert._page_id(page, index),
                    "source_capture": os.path.basename(source_image),
                    "source_capture_sha256":
                        hashlib.sha256(source_bytes).hexdigest(),
                    "sigma_capture": os.path.basename(sigma_image),
                    "sigma_capture_sha256":
                        hashlib.sha256(sigma_bytes).hexdigest(),
                    "result": "PASS",
                })
            visual_evidence = os.path.join(
                directory, "visual-evidence-input.json"
            )
            with open(visual_evidence, "w", encoding="utf-8") as handle:
                json.dump({
                    "status": "PASS",
                    "verified_against": "spotfire-render",
                    "workbook_id": "server-workbook",
                    "source_artifact_sha256":
                        manifest["source"]["artifact_hash"]["value"],
                    "pages_total": len(visual_records),
                    "pages_pass": len(visual_records),
                    "pages_fail": 0,
                    "evidence": visual_records,
                }, handle)
            completion_gaps = read_json(os.path.join(
                directory, "completion-gaps.json"
            ))["gaps"]
            gap_decisions = os.path.join(
                directory, "gap-decisions-input.json"
            )
            with open(gap_decisions, "w", encoding="utf-8") as handle:
                json.dump({"decisions": [{
                    "object_type": gap["object_type"],
                    "object_id": gap["object_id"],
                    "warning_id": gap["warning_id"],
                    "decision": "accepted",
                    "reason": "mocked customer decision",
                } for gap in completion_gaps]}, handle)
            completed = migrate_spotfire.main(
                [
                    "--manifest",
                    os.path.join(FIXTURES, "spotfire-manifest.json"),
                    "--source-map",
                    os.path.join(FIXTURES, "source-map.json"),
                    "--workdir",
                    directory,
                    "--resume-live",
                    "--source-visual-evidence",
                    visual_evidence,
                    "--gap-decisions",
                    gap_decisions,
                ],
                api=api,
                runner=runner,
            )
            self.assertEqual(0, completed)
            final_state = read_json(os.path.join(
                directory, "run-state.json"
            ))
            self.assertTrue(final_state["complete"])
            self.assertTrue(final_state["parity_complete"])
            self.assertTrue(final_state["gap_decisions_complete"])
            self.assertTrue(final_state["source_visual_comparison_complete"])
            self.assertFalse(final_state["source_parity_claimed"])
            self.assertEqual(
                initial_posts,
                [call for call in api.calls if call[0] == "post"],
            )
            changed_manifest = os.path.join(
                directory, "changed-manifest.json"
            )
            changed = copy.deepcopy(manifest)
            changed["source"]["name"] = "Changed analysis"
            with open(changed_manifest, "w", encoding="utf-8") as handle:
                json.dump(changed, handle)
            with self.assertRaisesRegex(
                    migrate_spotfire.MigrationError, "inputs/spec changed"):
                migrate_spotfire._validate_resume_binding(
                    migrate_spotfire.Path(directory),
                    changed_manifest,
                    os.path.join(FIXTURES, "source-map.json"),
                    read_json(os.path.join(directory, "sigma_dm_spec.json")),
                )

    def test_gap_decisions_require_one_reasoned_entry_per_gap(self):
        gaps = [
            {
                "object_type": "visual",
                "object_id": "visual:mod",
                "warning_id": "SPOTFIRE-MOD-UNSUPPORTED",
            },
            {
                "object_type": "security",
                "object_id": "security:rls",
                "warning_id": "SPOTFIRE-SECURITY-REVIEW",
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            complete = os.path.join(directory, "complete.json")
            with open(complete, "w", encoding="utf-8") as handle:
                json.dump({
                    "decisions": [
                        {
                            **gap,
                            "decision": "accepted",
                            "reason": "customer-approved redesign",
                        }
                        for gap in gaps
                    ]
                }, handle)
            ledger = migrate_spotfire._validate_gap_decisions(
                complete, gaps
            )
            self.assertEqual(2, len(ledger["decisions"]))

            incomplete = os.path.join(directory, "incomplete.json")
            with open(incomplete, "w", encoding="utf-8") as handle:
                json.dump({"decisions": ledger["decisions"][:1]}, handle)
            with self.assertRaises(migrate_spotfire.MigrationError):
                migrate_spotfire._validate_gap_decisions(incomplete, gaps)
        merged = migrate_spotfire._completion_gaps([], [
            {
                "object_type": "visual",
                "object_id": "visual:one",
                "code": "SPOTFIRE-EXPR-UNSUPPORTED",
                "reason": "x axis failed",
            },
            {
                "object_type": "visual",
                "object_id": "visual:one",
                "code": "SPOTFIRE-EXPR-UNSUPPORTED",
                "reason": "y axis failed",
            },
        ])
        self.assertEqual(2, len(merged))
        self.assertEqual(2, len({
            (gap["object_id"], gap["warning_id"]) for gap in merged
        }))

    def test_parity_plan_disambiguates_duplicate_chart_names(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "parity-plan.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"charts": [
                    {
                        "chart": "Revenue",
                        "sigma_element_id": "chart-1",
                    },
                    {
                        "chart": "Revenue",
                        "sigma_element_id": "chart-2",
                    },
                ]}, handle)
            plan = migrate_spotfire._disambiguate_parity_plan(path)
            self.assertEqual(
                ["Revenue [chart-1]", "Revenue [chart-2]"],
                [chart["chart"] for chart in plan["charts"]],
            )

    def test_source_visual_evidence_is_page_complete_and_hash_bound(self):
        manifest = read_json(os.path.join(
            FIXTURES, "spotfire-manifest.json"
        ))
        with tempfile.TemporaryDirectory() as directory:
            records = []
            for index, page in enumerate(
                    migrate_spotfire.convert._manifest_pages(manifest)):
                if not migrate_spotfire.convert._page_visuals(page):
                    continue
                source = os.path.join(directory, "source-%d.png" % index)
                sigma = os.path.join(directory, "sigma-%d.png" % index)
                source_bytes = b"\x89PNG\r\n\x1a\nsource" + bytes([index])
                sigma_bytes = b"\x89PNG\r\n\x1a\nsigma" + bytes([index])
                with open(source, "wb") as handle:
                    handle.write(source_bytes)
                with open(sigma, "wb") as handle:
                    handle.write(sigma_bytes)
                records.append({
                    "source_page_id":
                        migrate_spotfire.convert._page_id(page, index),
                    "source_capture": os.path.basename(source),
                    "source_capture_sha256":
                        hashlib.sha256(source_bytes).hexdigest(),
                    "sigma_capture": os.path.basename(sigma),
                    "sigma_capture_sha256":
                        hashlib.sha256(sigma_bytes).hexdigest(),
                    "result": "PASS",
                })
            evidence_path = os.path.join(directory, "evidence.json")
            with open(evidence_path, "w", encoding="utf-8") as handle:
                json.dump({
                    "status": "PASS",
                    "verified_against": "spotfire-render",
                    "workbook_id": "workbook-1",
                    "source_artifact_sha256":
                        manifest["source"]["artifact_hash"]["value"],
                    "pages_total": len(records),
                    "pages_pass": len(records),
                    "pages_fail": 0,
                    "evidence": records,
                }, handle)
            result = migrate_spotfire._validate_source_visual_evidence(
                evidence_path, manifest, "workbook-1"
            )
            self.assertEqual(len(records), result["pages_pass"])

            records[0]["source_capture_sha256"] = "0" * 64
            with open(evidence_path, "w", encoding="utf-8") as handle:
                json.dump({**result, "evidence": records}, handle)
            with self.assertRaises(migrate_spotfire.MigrationError):
                migrate_spotfire._validate_source_visual_evidence(
                    evidence_path, manifest, "workbook-1"
                )

    def test_source_map_failure_is_recorded_without_post_success(self):
        with tempfile.TemporaryDirectory() as directory:
            bad_map = os.path.join(directory, "source-map.json")
            source = read_json(os.path.join(FIXTURES, "source-map.json"))
            del source["tables"]["table:targets"]
            with open(bad_map, "w", encoding="utf-8") as handle:
                json.dump(source, handle)
            workdir = os.path.join(directory, "work")
            result = subprocess.run(
                [
                    sys.executable, SCRIPT,
                    "--manifest", os.path.join(
                        FIXTURES, "spotfire-manifest.json"),
                    "--source-map", bad_map,
                    "--workdir", workdir,
                    "--dry-run",
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(2, result.returncode)
            state = read_json(os.path.join(workdir, "run-state.json"))
            self.assertEqual("failed", state["status"])
            self.assertFalse(state["conversion_complete"])
            self.assertFalse(state["post_complete"])
            self.assertFalse(state["success_stamped"])
            self.assertIn("source-map resolution failed closed", state["error"])


if __name__ == "__main__":
    unittest.main()
