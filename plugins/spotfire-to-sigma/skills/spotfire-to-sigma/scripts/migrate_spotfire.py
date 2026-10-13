#!/usr/bin/env python3
"""Gated Spotfire manifest -> Sigma live migration orchestrator.

Dry-run performs only local validation/conversion. Live mode validates the
authoritative manifest, makes an explicit data-model reuse decision, POSTs or
reuses and reads back the data model, rebuilds against server IDs, lints and
POSTs the workbook, then verifies every chart against the live warehouse.

Warehouse verification is not Spotfire source parity. A live run exits at a
documented checkpoint after doing the live work unless separately supplied
source-visual evidence passes the strict evidence contract.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

import convert
import post_and_readback
import scan_gaps
import validate_manifest


EXIT_ERROR = 2
EXIT_REUSE_DECISION_REQUIRED = 15
EXIT_SOURCE_VISUAL_CHECKPOINT = 16
EXIT_GAP_DECISIONS_REQUIRED = 17
HERE = Path(__file__).resolve().parent
SKILL_DIR = HERE.parent


class MigrationError(Exception):
    pass


class CommandError(MigrationError):
    pass


def _read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def _write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp.%d" % os.getpid())
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def _sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _sha256_json(value):
    payload = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _validate_resume_binding(
        workdir, manifest_path, source_map_path, data_model_spec):
    binding_path = workdir / "live-binding.json"
    if not binding_path.is_file():
        raise MigrationError(
            "--resume-live requires %s from the prior live run" % binding_path
        )
    binding = _read_json(binding_path)
    expected = {
        "manifest_sha256": _sha256_file(manifest_path),
        "warehouse_source_map_sha256": _sha256_file(source_map_path),
        "data_model_spec_sha256": _sha256_json(data_model_spec),
    }
    mismatches = [
        key for key, value in expected.items()
        if binding.get(key) != value
    ]
    if mismatches:
        raise MigrationError(
            "--resume-live inputs/spec changed since the posted run: %s; "
            "start a new workdir" % ", ".join(mismatches)
        )
    return binding, binding_path


def _looks_like_manifest(path):
    try:
        value = _read_json(path)
    except (OSError, ValueError):
        return False
    if not isinstance(value, dict):
        return False
    return (
        value.get("manifest_type") == "spotfire_neutral_manifest"
        and value.get("manifest_version") == "1.0"
    )


def resolve_manifest(manifest=None, from_discovery=None):
    if manifest:
        path = Path(manifest).expanduser().resolve()
        if not path.is_file():
            raise MigrationError("--manifest is not a file: %s" % path)
        return path
    root = Path(from_discovery).expanduser().resolve()
    if root.is_file():
        if not _looks_like_manifest(root):
            raise MigrationError(
                "--from-discovery file is not an authoritative Spotfire "
                "manifest: %s" % root
            )
        return root
    if not root.is_dir():
        raise MigrationError(
            "--from-discovery is not a directory or manifest file: %s" % root
        )
    preferred = (
        "spotfire-manifest.json",
        "spotfire_manifest.json",
        "manifest.json",
        "discovery/spotfire-manifest.json",
        "discovery/spotfire_manifest.json",
        "discovery/manifest.json",
    )
    for relative in preferred:
        candidate = root / relative
        if candidate.is_file() and _looks_like_manifest(candidate):
            return candidate
    candidates = sorted(
        (path for path in root.rglob("*.json") if path.is_file()),
        key=lambda path: str(path.relative_to(root)).casefold(),
    )
    matches = [path for path in candidates if _looks_like_manifest(path)]
    if not matches:
        raise MigrationError(
            "--from-discovery contains no authoritative Spotfire manifest"
        )
    return matches[0]


def _state_writer(workdir, dry_run):
    state = {
        "schema_version": 2,
        "run_id": str(uuid.uuid4()),
        "source": "spotfire",
        "mode": "dry-run" if dry_run else "live",
        "status": "running",
        "complete": False,
        "manifest_validated": False,
        "conversion_complete": False,
        "signature_complete": False,
        "reuse_check_complete": False,
        "data_model_post_complete": False,
        "data_model_readback_complete": False,
        "workbook_lints_complete": False,
        "workbook_post_complete": False,
        "workbook_readback_complete": False,
        "post_complete": False,
        "warehouse_verification_complete": False,
        "source_visual_comparison_complete": False,
        "gap_decisions_complete": False,
        "source_parity_claimed": False,
        "parity_complete": False,
        "render_complete": False,
        "success_stamped": False,
        "artifacts": {},
        "phases": [],
    }
    state_path = workdir / "run-state.json"

    def record(name, phase_status="complete", **extra):
        state["phases"].append(
            {"name": name, "status": phase_status, **extra}
        )
        state.update(extra)
        _write_json(state_path, state)

    _write_json(state_path, state)
    return state, record


def _manifest_name(manifest):
    source = manifest.get("source")
    source = source if isinstance(source, dict) else {}
    return str(
        manifest.get("name")
        or manifest.get("title")
        or source.get("name")
        or "Spotfire Document"
    )


def _workbook_signature(manifest, conversion):
    warehouse_tables = sorted({
        ".".join(value["path"])
        for value in conversion["resolved_sources"].values()
    })
    columns = []
    measures = []
    for table in convert._manifest_tables(manifest):
        if not isinstance(table, dict):
            continue
        for column in convert._table_columns(table):
            name = convert._column_name(column)
            columns.append(name)
            expression = convert._column_expression(column)
            if expression:
                measures.append({
                    "col": name,
                    "derivation": "calculated",
                })
    source_hash = (
        (manifest.get("source") or {})
        .get("artifact_hash", {})
        .get("value")
    )
    name = _manifest_name(manifest)
    return {
        "schema_version": 1,
        "source": "spotfire",
        "spotfire_document": name,
        # Compatibility key consumed by the vendored generic reuse scorer.
        "tableau_workbook": name,
        "workbook": name,
        "source_artifact_sha256": source_hash,
        "warehouse_tables": warehouse_tables,
        "referenced_columns": sorted(set(columns), key=str.casefold),
        "measures": measures,
    }


def _run_command(runner, command, workdir, allowed=(0,)):
    environment = os.environ.copy()
    environment["SIGMA_WORKDIR"] = str(workdir)
    completed = runner(
        [str(value) for value in command],
        cwd=str(SKILL_DIR),
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode not in allowed:
        detail = (completed.stderr or completed.stdout or "").strip()
        raise CommandError(
            "%s exited %s%s" % (
                Path(str(command[0])).name,
                completed.returncode,
                ": " + detail if detail else "",
            )
        )
    return completed


def _persist_readback(
    workdir,
    prefix,
    object_id,
    response,
    readback,
    verdict,
):
    response_path = workdir / ("%s-post-response.json" % prefix)
    readback_path = workdir / ("%s-readback.json" % prefix)
    verdict_path = workdir / ("%s-readback-verdict.json" % prefix)
    ids_path = workdir / ("%s-ids.json" % prefix)
    _write_json(response_path, response)
    _write_json(readback_path, readback)
    _write_json(verdict_path, verdict)
    _write_json(
        ids_path,
        {
            (
                "dataModelId" if prefix == "datamodel" else "workbookId"
            ): object_id,
            "elementIds": verdict["element_ids"],
            "columnIds": verdict["column_ids"],
        },
    )
    return {
        "%s_post_response" % prefix: str(response_path),
        "%s_readback" % prefix: str(readback_path),
        "%s_readback_verdict" % prefix: str(verdict_path),
        "%s_ids" % prefix: str(ids_path),
    }


def _reuse_decision(arguments, runner, workdir, signature_path):
    decision_path = workdir / "dm-reuse-decision.json"
    match_path = workdir / "dm-match.json"
    if arguments.resume_live:
        ids_path = workdir / "datamodel-ids.json"
        if not ids_path.is_file():
            raise MigrationError(
                "--resume-live requires %s from the prior live run" % ids_path
            )
        data_model_id = _read_json(ids_path).get("dataModelId")
        if not data_model_id:
            raise MigrationError(
                "%s contains no dataModelId" % ids_path
            )
        decision = {
            "schema_version": 1,
            "decision": "reuse",
            "data_model_id": str(data_model_id),
            "basis": "resume existing object from the same workdir",
            "scan_performed": False,
            "requires_user_decision": False,
        }
    elif arguments.reuse_dm:
        decision = {
            "schema_version": 1,
            "decision": "reuse",
            "data_model_id": arguments.reuse_dm,
            "basis": "explicit --reuse-dm",
            "scan_performed": False,
            "requires_user_decision": False,
        }
    elif arguments.force_new_dm:
        decision = {
            "schema_version": 1,
            "decision": "create-new",
            "data_model_id": None,
            "basis": "explicit --force-new-dm",
            "scan_performed": False,
            "requires_user_decision": False,
        }
    else:
        _run_command(
            runner,
            [
                "ruby",
                HERE / "find-or-pick-dm.rb",
                "--workbook-signature",
                signature_path,
                "--out",
                match_path,
                "--auto-pick",
            ],
            workdir,
            allowed=(0, 1),
        )
        if not match_path.is_file():
            raise MigrationError(
                "reuse scanner did not write %s" % match_path
            )
        match = _read_json(match_path)
        recommendation = match.get("recommended_dm_id")
        auto_picked = match.get("auto_picked") is True
        if recommendation and auto_picked:
            selected = "reuse"
            requires_decision = False
        elif recommendation:
            selected = "decision-required"
            requires_decision = True
        else:
            selected = "create-new"
            requires_decision = False
        decision = {
            "schema_version": 1,
            "decision": selected,
            "data_model_id": recommendation if selected == "reuse" else None,
            "recommended_data_model_id": recommendation,
            "basis": match.get("rationale") or "reuse scan result",
            "scan_performed": True,
            "requires_user_decision": requires_decision,
            "match_path": str(match_path),
        }
    _write_json(decision_path, decision)
    return decision, decision_path, match_path if match_path.is_file() else None


def _run_workbook_lints(runner, workdir, workbook_path):
    commands = [
        ["ruby", HERE / "lib" / "preflight_lint.rb", workbook_path],
        ["ruby", HERE / "lib" / "layout_lint.rb", workbook_path],
        ["ruby", HERE / "lib" / "control_lint.rb", workbook_path],
    ]
    results = []
    for command in commands:
        completed = _run_command(runner, command, workdir)
        results.append({
            "lint": Path(str(command[1])).stem,
            "stdout": completed.stdout.strip(),
            "stderr": completed.stderr.strip(),
        })
    lint_path = workdir / "workbook-lints.json"
    _write_json(lint_path, {"status": "PASS", "results": results})
    return lint_path


def _verify_warehouse_result(path, workbook_id):
    result = _read_json(path)
    if (
        result.get("status") != "PASS"
        or result.get("verified_against") != "warehouse"
        or result.get("mode") != "warehouse"
        or str(result.get("workbook_id")) != str(workbook_id)
        or not isinstance(result.get("charts_total"), int)
        or result["charts_total"] <= 0
        or result.get("charts_pass") != result["charts_total"]
        or result.get("charts_fail") != 0
    ):
        raise MigrationError(
            "warehouse verification result is not a complete PASS"
        )
    return result


def _disambiguate_parity_plan(path):
    """Keep the shared verifier's display-name result map collision-free."""
    plan = _read_json(path)
    charts = plan.get("charts")
    if not isinstance(charts, list) or not charts:
        raise MigrationError("parity plan contains no charts")
    names = [str(chart.get("chart") or "") for chart in charts]
    for chart, name in zip(charts, names):
        if names.count(name) > 1:
            element_id = chart.get("sigma_element_id")
            if not element_id:
                raise MigrationError(
                    "duplicate parity chart name has no sigma_element_id"
                )
            chart["chart"] = "%s [%s]" % (name, element_id)
    final_names = [chart.get("chart") for chart in charts]
    if len(final_names) != len(set(final_names)):
        raise MigrationError(
            "parity plan chart labels are not unique after disambiguation"
        )
    _write_json(path, plan)
    return plan


def _validate_source_visual_evidence(path, manifest, workbook_id):
    evidence = _read_json(path)
    total = evidence.get("pages_total")
    source_pages = [
        (index, page)
        for index, page in enumerate(convert._manifest_pages(manifest))
        if isinstance(page, dict) and convert._page_visuals(page)
    ]
    expected_ids = {
        convert._page_id(page, index)
        for index, page in source_pages
    }
    expected_total = len(expected_ids)
    records = evidence.get("evidence")
    expected_hash = (
        (manifest.get("source") or {})
        .get("artifact_hash", {})
        .get("value")
    )
    if evidence.get("status") != "PASS":
        raise MigrationError("source visual evidence status must be PASS")
    if evidence.get("verified_against") not in (
        "spotfire",
        "spotfire-render",
        "source-visuals",
    ):
        raise MigrationError(
            "source visual evidence must identify rendered Spotfire/source visuals"
        )
    if str(evidence.get("workbook_id")) != str(workbook_id):
        raise MigrationError(
            "source visual evidence workbook_id does not match posted workbook"
        )
    if (
        not isinstance(total, int)
        or total <= 0
        or evidence.get("pages_pass") != total
        or evidence.get("pages_fail") != 0
    ):
        raise MigrationError(
            "source visual evidence must pass every compared visual"
        )
    if total != expected_total:
        raise MigrationError(
            "source visual evidence census %s does not match the manifest "
            "page census %s" % (total, expected_total)
        )
    if not isinstance(records, list) or len(records) != total:
        raise MigrationError(
            "source visual evidence must contain one record per source page"
        )
    ledger_dir = Path(path).resolve().parent
    actual_ids = set()
    for index, record in enumerate(records):
        if not isinstance(record, dict) or record.get("result") != "PASS":
            raise MigrationError(
                "every source visual evidence record must have result=PASS"
            )
        source_page_id = str(record.get("source_page_id") or "")
        if not source_page_id or source_page_id in actual_ids:
            raise MigrationError(
                "source visual evidence record %d has a missing/duplicate "
                "source_page_id" % index
            )
        actual_ids.add(source_page_id)
        for path_key, hash_key in (
            ("source_capture", "source_capture_sha256"),
            ("sigma_capture", "sigma_capture_sha256"),
        ):
            capture_value = record.get(path_key)
            digest = record.get(hash_key)
            if not capture_value or not digest:
                raise MigrationError(
                    "source visual evidence record %d requires %s and %s"
                    % (index, path_key, hash_key)
                )
            capture = Path(capture_value)
            if not capture.is_absolute():
                capture = ledger_dir / capture
            if not capture.is_file():
                raise MigrationError(
                    "source visual evidence capture does not exist: %s"
                    % capture
                )
            actual_digest = hashlib.sha256(capture.read_bytes()).hexdigest()
            if actual_digest != digest:
                raise MigrationError(
                    "source visual evidence hash mismatch for %s" % capture
                )
    if actual_ids != expected_ids:
        raise MigrationError(
            "source visual evidence page ids do not match the manifest: "
            "missing=%s extras=%s"
            % (sorted(expected_ids - actual_ids), sorted(actual_ids - expected_ids))
        )
    if expected_hash and evidence.get("source_artifact_sha256") != expected_hash:
        raise MigrationError(
            "source visual evidence artifact hash does not match the manifest"
        )
    return evidence


def _validate_gap_decisions(path, gaps):
    ledger = _read_json(path)
    decisions = ledger.get("decisions")
    if not isinstance(decisions, list):
        raise MigrationError("gap decisions must contain a decisions array")
    indexed = {}
    for index, decision in enumerate(decisions):
        if not isinstance(decision, dict):
            raise MigrationError(
                "gap decision %d must be an object" % index
            )
        key = (
            str(decision.get("object_type") or ""),
            str(decision.get("object_id") or ""),
            str(decision.get("warning_id") or ""),
        )
        if not all(key):
            raise MigrationError(
                "gap decision %d requires object_type, object_id, and warning_id"
                % index
            )
        if key in indexed:
            raise MigrationError(
                "gap decisions contain a duplicate entry for %s/%s/%s" % key
            )
        outcome = decision.get("decision")
        if outcome not in ("resolved", "accepted"):
            raise MigrationError(
                "gap decision %d must be resolved or accepted" % index
            )
        if not str(decision.get("reason") or "").strip():
            raise MigrationError(
                "gap decision %d requires a non-empty reason" % index
            )
        indexed[key] = decision

    expected = {
        (
            str(gap.get("object_type") or ""),
            str(gap.get("object_id") or ""),
            str(gap.get("warning_id") or ""),
        )
        for gap in gaps
    }
    missing = sorted(expected - set(indexed))
    extras = sorted(set(indexed) - expected)
    if missing or extras:
        raise MigrationError(
            "gap decisions do not match the current gap report: "
            "missing=%s extras=%s" % (missing, extras)
        )
    return ledger


def _completion_gaps(scan_gaps, conversion_gaps):
    """Merge discovery and emitted-spec gaps into one decision contract."""
    merged = {}
    for gap in scan_gaps:
        row = dict(gap)
        key = (
            str(row.get("object_type") or ""),
            str(row.get("object_id") or ""),
            str(row.get("warning_id") or ""),
        )
        merged[key] = row
    for gap in conversion_gaps:
        row = {
            "object_type": str(gap.get("object_type") or ""),
            "object_id": str(gap.get("object_id") or ""),
            "object_name": str(
                gap.get("visual")
                or gap.get("table")
                or gap.get("object_id")
                or ""
            ),
            "warning_id": str(gap.get("code") or ""),
            "category": "conversion",
            "reason": str(gap.get("reason") or ""),
            "source": {"artifact": "conversion-gaps.json"},
        }
        key = (
            row["object_type"], row["object_id"], row["warning_id"]
        )
        if key in merged and merged[key].get("reason") != row["reason"]:
            suffix = hashlib.sha256(
                json.dumps(gap, sort_keys=True, default=str).encode("utf-8")
            ).hexdigest()[:10]
            row["object_id"] = "%s#%s" % (row["object_id"], suffix)
            key = (
                row["object_type"], row["object_id"], row["warning_id"]
            )
        merged.setdefault(key, row)
    return [
        merged[key] for key in sorted(
            merged,
            key=lambda value: tuple(part.casefold() for part in value),
        )
    ]


def main(argv=None, api=None, runner=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--manifest")
    source.add_argument(
        "--from-discovery",
        help="directory containing a manifest, or the manifest file itself",
    )
    parser.add_argument(
        "--source-map",
        required=True,
        help="customer warehouse target map (not exporter provenance)",
    )
    parser.add_argument("--connection-id")
    parser.add_argument("--database")
    parser.add_argument("--schema")
    parser.add_argument("--folder-id", help="Sigma destination folder id")
    reuse = parser.add_mutually_exclusive_group()
    reuse.add_argument(
        "--reuse-dm",
        help="explicitly reuse and read back this Sigma data-model id",
    )
    reuse.add_argument(
        "--force-new-dm",
        action="store_true",
        help="explicitly create a new data model without scanning",
    )
    parser.add_argument("--parity-pool", type=int, default=5)
    parser.add_argument("--parity-timeout", type=int, default=120)
    parser.add_argument(
        "--source-visual-evidence",
        help="JSON proof tying rendered Spotfire visuals to the posted workbook",
    )
    parser.add_argument(
        "--gap-decisions",
        help="per-gap resolved/accepted ledger required before completion",
    )
    parser.add_argument(
        "--resume-live",
        action="store_true",
        help=(
            "reuse datamodel-ids.json and workbook-ids.json from this workdir; "
            "needed when supplying evidence after the exit-16 checkpoint"
        ),
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--workdir",
        default="./spotfire-migration",
        help="artifact directory (default: ./spotfire-migration)",
    )
    arguments = parser.parse_args(argv)
    if arguments.parity_pool < 1 or arguments.parity_pool > 16:
        parser.error("--parity-pool must be between 1 and 16")
    if arguments.parity_timeout < 1:
        parser.error("--parity-timeout must be positive")
    if arguments.resume_live and arguments.dry_run:
        parser.error("--resume-live cannot be combined with --dry-run")
    if arguments.resume_live and (
            arguments.reuse_dm or arguments.force_new_dm):
        parser.error(
            "--resume-live cannot be combined with --reuse-dm or --force-new-dm"
        )

    runner = runner or subprocess.run
    api = api or post_and_readback.sigma_rest
    workdir = Path(arguments.workdir).expanduser().resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    state, record = _state_writer(workdir, arguments.dry_run)
    started = time.time()

    try:
        manifest_path = resolve_manifest(
            arguments.manifest, arguments.from_discovery
        )
        source_map_path = Path(arguments.source_map).expanduser().resolve()
        if not source_map_path.is_file():
            raise MigrationError(
                "--source-map is not a file: %s" % source_map_path
            )
        manifest = _read_json(manifest_path)
        source_map = _read_json(source_map_path)

        validation_errors, validation_warnings = (
            validate_manifest.validate_manifest(manifest)
        )
        validation_path = workdir / "manifest-validation.json"
        _write_json(
            validation_path,
            {
                "valid": not validation_errors,
                "errors": validation_errors,
                "warnings": validation_warnings,
                "manifest": str(manifest_path),
            },
        )
        if validation_errors:
            raise MigrationError(
                "authoritative manifest validation failed:\n  - "
                + "\n  - ".join(validation_errors)
            )
        source_hash = (
            (manifest.get("source") or {})
            .get("artifact_hash", {})
        )
        if (
            not arguments.dry_run
            and (
                source_hash.get("status") != "available"
                or not source_hash.get("value")
            )
        ):
            raise MigrationError(
                "live mode requires an available source DXP SHA-256; rerun "
                "the Spotfire exporter with SourceDxpPath"
            )

        discovery_dir = workdir / "discovery"
        discovery_dir.mkdir(exist_ok=True)
        manifest_copy = discovery_dir / "spotfire-manifest.json"
        source_map_copy = discovery_dir / "warehouse-source-map.json"
        if manifest_path != manifest_copy:
            shutil.copy2(manifest_path, manifest_copy)
        if source_map_path != source_map_copy:
            shutil.copy2(source_map_path, source_map_copy)
        state["artifacts"].update({
            "manifest_validation": str(validation_path),
            "manifest": str(manifest_copy),
            "warehouse_source_map": str(source_map_copy),
        })
        record(
            "validate-manifest",
            manifest_validated=True,
            manifest_warning_count=len(validation_warnings),
            manifest=str(manifest_path),
            source_map=str(source_map_path),
        )

        gap_report = scan_gaps.build_report(
            manifest, artifact=str(manifest_path), source_map=source_map
        )
        gap_path = workdir / "gap-report.json"
        _write_json(gap_path, gap_report)
        state["artifacts"]["gap_report"] = str(gap_path)
        record(
            "gap-scan",
            gap_count=gap_report["summary"]["gaps"],
            security_findings=gap_report["security"]["findings"],
        )

        result = convert.convert_manifest(
            manifest,
            source_map,
            connection_id=arguments.connection_id,
            database=arguments.database,
            schema=arguments.schema,
        )
        dm_path = workdir / "sigma_dm_spec.json"
        initial_workbook_path = workdir / "sigma_workbook_spec.initial.json"
        workbook_path = workdir / "sigma_workbook_spec.json"
        conversion_gaps_path = workdir / "conversion-gaps.json"
        resolved_sources_path = workdir / "resolved-sources.json"
        signature_path = workdir / "workbook-signature.json"
        _write_json(dm_path, result["data_model"])
        _write_json(initial_workbook_path, result["workbook"])
        _write_json(workbook_path, result["workbook"])
        _write_json(conversion_gaps_path, {
            "schema_version": 1,
            "source": "spotfire",
            "summary": {"gaps": len(result["gaps"])},
            "gaps": result["gaps"],
        })
        completion_gaps_path = workdir / "completion-gaps.json"
        completion_gaps = _completion_gaps(
            gap_report["gaps"], result["gaps"]
        )
        _write_json(completion_gaps_path, {
            "schema_version": 1,
            "source": "spotfire",
            "summary": {"gaps": len(completion_gaps)},
            "gaps": completion_gaps,
        })
        _write_json(resolved_sources_path, result["resolved_sources"])
        _write_json(
            signature_path, _workbook_signature(manifest, result)
        )
        state["artifacts"].update({
            "data_model_spec": str(dm_path),
            "initial_workbook_spec": str(initial_workbook_path),
            "workbook_spec": str(workbook_path),
            "conversion_gaps": str(conversion_gaps_path),
            "completion_gaps": str(completion_gaps_path),
            "resolved_sources": str(resolved_sources_path),
            "workbook_signature": str(signature_path),
        })
        record(
            "convert",
            conversion_complete=True,
            signature_complete=True,
            conversion_gap_count=len(result["gaps"]),
        )
        blocking_gaps = [
            gap for gap in completion_gaps if gap.get("blocking") is True
        ]
        if blocking_gaps and not arguments.dry_run:
            raise MigrationError(
                "authoritative manifest contains %d blocking finding(s); "
                "fix and re-export before any Sigma write: %s"
                % (
                    len(blocking_gaps),
                    ", ".join(
                        "%s/%s" % (
                            gap["object_type"], gap["object_id"]
                        )
                        for gap in blocking_gaps[:5]
                    ),
                )
            )
        resume_binding = None
        if arguments.resume_live:
            resume_binding, binding_path = _validate_resume_binding(
                workdir, manifest_path, source_map_path, result["data_model"]
            )
            state["artifacts"]["live_binding"] = str(binding_path)

        if arguments.dry_run:
            decision_path = workdir / "dm-reuse-decision.json"
            _write_json(decision_path, {
                "schema_version": 1,
                "decision": "not-run",
                "basis": "dry-run never calls the Sigma API",
                "scan_performed": False,
                "requires_user_decision": True,
            })
            state["artifacts"]["dm_reuse_decision"] = str(decision_path)
            record(
                "reuse-check",
                "not-run",
                reason="dry-run never makes network calls",
                reuse_check_complete=False,
            )
            record(
                "post",
                "not-run",
                reason="dry-run never writes to Sigma",
                post_complete=False,
            )
            record(
                "warehouse-verification",
                "not-run",
                reason="dry-run has no posted workbook to query",
                warehouse_verification_complete=False,
                parity_complete=False,
            )
            record(
                "source-visual-comparison",
                "not-run",
                reason="dry-run has no posted workbook to compare",
                source_visual_comparison_complete=False,
                render_complete=False,
            )
            record(
                "finish",
                "incomplete",
                status="dry-run-complete",
                complete=False,
                success_stamped=False,
                elapsed_seconds=round(time.time() - started, 3),
            )
            print(
                "DRY RUN COMPLETE: local specs and reports were generated at %s"
                % workdir
            )
            print(
                "NO SIGMA WRITES: reuse scan, POST/readback, warehouse "
                "verification, and source visual comparison were not run."
            )
            return 0

        decision, decision_path, match_path = _reuse_decision(
            arguments, runner, workdir, signature_path
        )
        state["artifacts"]["dm_reuse_decision"] = str(decision_path)
        if match_path:
            state["artifacts"]["dm_match"] = str(match_path)
        record(
            "reuse-check",
            reuse_check_complete=True,
            reuse_decision=decision["decision"],
            reuse_basis=decision["basis"],
        )
        if decision["requires_user_decision"]:
            record(
                "finish",
                "checkpoint",
                status="reuse-decision-required",
                complete=False,
                success_stamped=False,
                checkpoint_exit_code=EXIT_REUSE_DECISION_REQUIRED,
                checkpoint=(
                    "rerun with --reuse-dm %s or --force-new-dm"
                    % decision["recommended_data_model_id"]
                ),
                elapsed_seconds=round(time.time() - started, 3),
            )
            print(
                "REUSE DECISION REQUIRED: %s" % decision["basis"],
                file=sys.stderr,
            )
            return EXIT_REUSE_DECISION_REQUIRED

        if decision["decision"] == "reuse":
            data_model_id = decision["data_model_id"]
            dm_readback, dm_verdict = post_and_readback.read_existing(
                "datamodel",
                data_model_id,
                result["data_model"],
                api=api,
            )
            dm_response = {
                "reused": True,
                "dataModelId": data_model_id,
                "basis": decision["basis"],
            }
            dm_was_posted = False
        else:
            (
                data_model_id,
                dm_response,
                dm_readback,
                dm_verdict,
            ) = post_and_readback.post_and_readback(
                "datamodel",
                result["data_model"],
                folder_id=arguments.folder_id,
                api=api,
            )
            dm_was_posted = True
        state["artifacts"].update(_persist_readback(
            workdir,
            "datamodel",
            data_model_id,
            dm_response,
            dm_readback,
            dm_verdict,
        ))
        record(
            "post-readback-data-model",
            data_model_id=data_model_id,
            data_model_reused=not dm_was_posted,
            data_model_post_complete=dm_was_posted,
            data_model_readback_complete=True,
            data_model_element_count=dm_verdict["census"][
                "matched_elements"
            ],
            data_model_column_count=dm_verdict["census"][
                "expected_columns"
            ],
        )

        live_result = convert.convert_manifest(
            manifest,
            source_map,
            connection_id=arguments.connection_id,
            database=arguments.database,
            schema=arguments.schema,
            data_model_id=data_model_id,
            dm_element_ids=dm_verdict["element_ids"],
        )
        if resume_binding:
            if str(resume_binding.get("data_model_id")) != str(
                    data_model_id):
                raise MigrationError(
                    "--resume-live data model id differs from live-binding.json"
                )
            current_workbook_hash = _sha256_json(live_result["workbook"])
            if (
                resume_binding.get("workbook_spec_sha256")
                != current_workbook_hash
            ):
                raise MigrationError(
                    "--resume-live workbook spec changed since the posted run; "
                    "start a new workdir"
                )
        _write_json(workbook_path, live_result["workbook"])
        lint_path = _run_workbook_lints(
            runner, workdir, workbook_path
        )
        state["artifacts"]["workbook_lints"] = str(lint_path)
        record(
            "rebuild-lint-workbook",
            workbook_lints_complete=True,
            workbook_data_model_id=data_model_id,
        )

        workbook_was_posted = not arguments.resume_live
        if arguments.resume_live:
            workbook_ids_path = workdir / "workbook-ids.json"
            if not workbook_ids_path.is_file():
                raise MigrationError(
                    "--resume-live requires %s from the prior live run"
                    % workbook_ids_path
                )
            workbook_id = _read_json(workbook_ids_path).get("workbookId")
            if not workbook_id:
                raise MigrationError(
                    "%s contains no workbookId" % workbook_ids_path
                )
            workbook_readback, workbook_verdict = (
                post_and_readback.read_existing(
                    "workbook",
                    str(workbook_id),
                    live_result["workbook"],
                    api=api,
                )
            )
            workbook_response = {
                "reused": True,
                "workbookId": str(workbook_id),
                "basis": "resume existing object from the same workdir",
            }
            workbook_id = str(workbook_id)
        else:
            (
                workbook_id,
                workbook_response,
                workbook_readback,
                workbook_verdict,
            ) = post_and_readback.post_and_readback(
                "workbook",
                live_result["workbook"],
                folder_id=arguments.folder_id,
                api=api,
            )
        state["artifacts"].update(_persist_readback(
            workdir,
            "workbook",
            workbook_id,
            workbook_response,
            workbook_readback,
            workbook_verdict,
        ))
        record(
            "post-readback-workbook",
            workbook_id=workbook_id,
            workbook_post_complete=workbook_was_posted,
            workbook_reused=not workbook_was_posted,
            workbook_readback_complete=True,
            post_complete=True,
            workbook_element_count=workbook_verdict["census"][
                "matched_elements"
            ],
            workbook_column_count=workbook_verdict["census"][
                "expected_columns"
            ],
        )
        binding_path = workdir / "live-binding.json"
        if resume_binding:
            if str(resume_binding.get("workbook_id")) != str(workbook_id):
                raise MigrationError(
                    "--resume-live workbook id differs from live-binding.json"
                )
        else:
            _write_json(binding_path, {
                "schema_version": 1,
                "manifest_sha256": _sha256_file(manifest_path),
                "warehouse_source_map_sha256":
                    _sha256_file(source_map_path),
                "data_model_spec_sha256":
                    _sha256_json(result["data_model"]),
                "workbook_spec_sha256":
                    _sha256_json(live_result["workbook"]),
                "data_model_id": data_model_id,
                "workbook_id": workbook_id,
            })
        state["artifacts"]["live_binding"] = str(binding_path)

        parity_plan_path = workdir / "parity-plan.json"
        parity_final_path = workdir / "parity-final.json"
        workbook_readback_path = Path(
            state["artifacts"]["workbook_readback"]
        )
        _run_command(
            runner,
            [
                "ruby",
                HERE / "build-parity-plan.rb",
                "--workbook-id",
                workbook_id,
                "--workbook-spec",
                workbook_readback_path,
                "--out",
                parity_plan_path,
            ],
            workdir,
        )
        _disambiguate_parity_plan(parity_plan_path)
        _run_command(
            runner,
            [
                "ruby",
                HERE / "verify-warehouse.rb",
                "--plan",
                parity_plan_path,
                "--workbook-id",
                workbook_id,
                "--workbook-spec",
                workbook_readback_path,
                "--out",
                parity_final_path,
                "--pool",
                arguments.parity_pool,
                "--timeout",
                arguments.parity_timeout,
            ],
            workdir,
        )
        warehouse_result = _verify_warehouse_result(
            parity_final_path, workbook_id
        )
        state["artifacts"].update({
            "parity_plan": str(parity_plan_path),
            "warehouse_verification": str(parity_final_path),
        })
        record(
            "warehouse-verification",
            warehouse_verification_complete=True,
            warehouse_charts_verified=warehouse_result["charts_total"],
            verified_against="warehouse",
            source_parity_claimed=False,
            parity_complete=True,
        )
        print(
            "WAREHOUSE VERIFICATION ONLY: %d/%d workbook elements returned "
            "live warehouse data." % (
                warehouse_result["charts_pass"],
                warehouse_result["charts_total"],
            )
        )
        print(
            "NOT SOURCE PARITY: Spotfire rendered values and visuals were not "
            "used by the warehouse verification."
        )

        if not arguments.source_visual_evidence:
            record(
                "source-visual-comparison",
                "checkpoint",
                reason=(
                    "customer/source rendered Spotfire evidence is required "
                    "before visual comparison can be proven"
                ),
                source_visual_comparison_complete=False,
                render_complete=False,
            )
            record(
                "finish",
                "incomplete",
                status="warehouse-verified-source-visual-checkpoint",
                complete=False,
                success_stamped=False,
                source_parity_claimed=False,
                checkpoint_exit_code=EXIT_SOURCE_VISUAL_CHECKPOINT,
                checkpoint=(
                    "supply --source-visual-evidence after comparing rendered "
                    "Spotfire and Sigma visuals"
                ),
                elapsed_seconds=round(time.time() - started, 3),
            )
            return EXIT_SOURCE_VISUAL_CHECKPOINT

        source_visual_path = Path(
            arguments.source_visual_evidence
        ).expanduser().resolve()
        evidence = _validate_source_visual_evidence(
            source_visual_path, manifest, workbook_id
        )
        evidence_copy = workdir / "source-visual-evidence.json"
        if source_visual_path != evidence_copy:
            shutil.copy2(source_visual_path, evidence_copy)
        state["artifacts"]["source_visual_evidence"] = str(evidence_copy)
        record(
            "source-visual-comparison",
            source_visual_comparison_complete=True,
            render_complete=True,
            source_pages_compared=evidence["pages_total"],
            source_parity_claimed=False,
        )
        gaps = completion_gaps
        if gaps and not arguments.gap_decisions:
            record(
                "gap-decisions",
                "checkpoint",
                reason=(
                    "every reported migration/security gap requires a named "
                    "resolved or accepted decision"
                ),
            )
            record(
                "finish",
                "incomplete",
                status="gap-decisions-required",
                complete=False,
                success_stamped=False,
                source_parity_claimed=False,
                checkpoint_exit_code=EXIT_GAP_DECISIONS_REQUIRED,
                checkpoint=(
                    "supply --gap-decisions with one reasoned decision for "
                    "every gap-report.json entry"
                ),
                elapsed_seconds=round(time.time() - started, 3),
            )
            return EXIT_GAP_DECISIONS_REQUIRED
        if arguments.gap_decisions:
            decisions_path = Path(
                arguments.gap_decisions
            ).expanduser().resolve()
            _validate_gap_decisions(decisions_path, gaps)
            decisions_copy = workdir / "gap-decisions.json"
            if decisions_path != decisions_copy:
                shutil.copy2(decisions_path, decisions_copy)
            state["artifacts"]["gap_decisions"] = str(decisions_copy)
            record(
                "gap-decisions",
                gap_decisions_complete=True,
                gap_decision_count=len(gaps),
            )
        record(
            "finish",
            status="complete-warehouse-and-visual-verification",
            complete=True,
            success_stamped=True,
            source_parity_claimed=False,
            parity_complete=True,
            elapsed_seconds=round(time.time() - started, 3),
        )
        return 0
    except (
        MigrationError,
        convert.ConversionError,
        post_and_readback.ReadbackError,
        post_and_readback.sigma_rest.SigmaError,
        OSError,
        json.JSONDecodeError,
    ) as error:
        record(
            "failure",
            "failed",
            status="failed",
            complete=False,
            success_stamped=False,
            source_parity_claimed=False,
            error=str(error),
            elapsed_seconds=round(time.time() - started, 3),
        )
        print("migrate_spotfire: %s" % error, file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
