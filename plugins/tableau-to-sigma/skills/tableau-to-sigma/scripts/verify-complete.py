#!/usr/bin/env python3
"""Fail-closed completion gate for the Tableau Python migration path."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import relationship_coverage as relationship_coverage_lib  # noqa: E402
import dashboard_coverage as dashboard_coverage_lib  # noqa: E402
import sql_provenance as sql_provenance_lib  # noqa: E402


def load(path: Path) -> dict:
    with path.open(encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def evaluate(workdir: Path, blind_grade: Path) -> dict:
    failures = []
    required = {
        "mission": workdir / "mission.json",
        "data_model_readback": workdir / "datamodel-readback-verdict.json",
        "workbook_readback": workdir / "workbook-readback-verdict.json",
        "parity": workdir / "parity-final.json",
        "anchors": workdir / "anchors-verdict.json",
        "visual_similarity": workdir / "visual-similarity-final.json",
        "semantic_edits": workdir / "semantic-edits.json",
        "relationship_coverage": workdir / "relationship-coverage.json",
        "dashboard_coverage": workdir / "dashboard-coverage.json",
        "sql_provenance": workdir / "sql-provenance.json",
        "source_census": workdir / "source-object-census.json",
        "security_decision": workdir / "security-decision.json",
        "data_model_ids": workdir / "dm-ids.json",
        "workbook_ids": workdir / "wb-ids.json",
        "blind_grade": blind_grade,
    }
    documents = {}
    for name, path in required.items():
        if not path.is_file():
            failures.append(f"{name}: missing {path.name}")
            continue
        try:
            documents[name] = load(path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            failures.append(f"{name}: unreadable ({exc})")

    mission = documents.get("mission") or {}
    inferred = [
        key
        for key, value in mission.items()
        if isinstance(value, dict) and value.get("provenance") != "stated"
    ]
    if inferred:
        failures.append("mission has unstated field(s): " + ", ".join(inferred))

    for key in ("data_model_readback", "workbook_readback"):
        if documents.get(key, {}).get("pass") is not True:
            failures.append(f"{key}: readback verdict is not pass")
    if documents.get("parity", {}).get("match") is not True:
        failures.append("parity: numeric source/target comparison failed")
    if documents.get("anchors", {}).get("pass") is not True:
        failures.append("anchors: source values or displayed-tile health failed")
    visual = documents.get("visual_similarity") or {}
    visual_pass = visual.get("pass") is True or visual.get("status") == "PASS"
    if not visual_pass:
        failures.append("visual_similarity: machine floor failed")
    if documents.get("semantic_edits", {}).get("match") is not True:
        failures.append("semantic_edits: structural proof missing or failed")
    relationship_gate_pass = False
    relationship_doc = documents.get("relationship_coverage")
    metadata_path = workdir / "conv-meta.json"
    source_path = workdir / "workbook-content.twb"
    relationship_model = next(
        (
            path
            for path in (
                workdir / "datamodel-readback.json",
                workdir / "dm-remapped.json",
                workdir / "dm-raw.json",
                workdir / "dm-spec.json",
            )
            if path.is_file()
        ),
        None,
    )
    if relationship_doc is not None:
        try:
            expected_relationships = relationship_coverage_lib.from_files(
                metadata_path, source_path, relationship_model
            )
            relationship_gate_pass = (
                relationship_doc == expected_relationships
                and expected_relationships.get("status") != "fail"
            )
        except (OSError, ValueError, json.JSONDecodeError):
            relationship_gate_pass = False
    if not relationship_gate_pass:
        failures.append(
            "relationship_coverage: artifact is stale, unwired, partial, or unreadable"
        )
    dashboard_gate_pass = False
    dashboard_doc = documents.get("dashboard_coverage")
    dashboard_spec = next(
        (
            path
            for path in (
                workdir / "workbook-readback.json",
                workdir / "wb-spec-python.json",
                workdir / "wb-spec.resolved.json",
                workdir / "wb-spec.json",
            )
            if path.is_file()
        ),
        None,
    )
    try:
        dashboard_scope = load(workdir / "dashboard-scope.json")
        expected_dashboards = dashboard_coverage_lib.evaluate(
            workdir / "workbook-content.twb",
            dashboard_spec,
            dashboard_scope,
            workdir / "story-plan.json",
        )
        dashboard_gate_pass = (
            dashboard_doc == expected_dashboards
            and expected_dashboards.get("status") == "pass"
        )
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        dashboard_gate_pass = False
    if not dashboard_gate_pass:
        failures.append(
            "dashboard_coverage: visible in-scope Tableau dashboard is missing "
            "or the artifact is stale"
        )
    sql_gate_pass = False
    sql_doc = documents.get("sql_provenance")
    sql_spec = next(
        (
            path
            for path in (
                workdir / "dm-remapped.json",
                workdir / "dm-raw.json",
                workdir / "dm-spec.json",
            )
            if path.is_file()
        ),
        None,
    )
    try:
        expected_sql = sql_provenance_lib.evaluate(
            sql_spec,
            workdir / "conv-meta.json",
            workdir / "workbook-content.twb",
            workdir / "custom-sql.json",
            workdir / "sql-provenance-overrides.json",
        )
        sql_gate_pass = sql_doc == expected_sql and expected_sql.get("status") == "pass"
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        sql_gate_pass = False
    if not sql_gate_pass:
        failures.append(
            "sql_provenance: a data-model SQL element is unattributed or the artifact is stale"
        )
    census = documents.get("source_census") or {}
    census_summary = census.get("summary") or {}
    source_objects = census.get("objects") or []
    if (
        census_summary.get("complete") is not True
        or census_summary.get("total") != len(source_objects)
    ):
        failures.append("source_census: accounting is incomplete")
    security = documents.get("security_decision") or {}
    if security.get("decision") not in {"not-required", "port", "customize", "skip"}:
        failures.append("security_decision: missing or invalid")
    blind = documents.get("blind_grade") or {}
    for path_key, hash_key, health_key in (
        ("source_png", "source_sha256", "source_health"),
        ("target_png", "target_sha256", "render_health"),
    ):
        image_path = Path(str(blind.get(path_key) or ""))
        expected_hash = blind.get(hash_key)
        measured_path = Path(str((visual.get(health_key) or {}).get("path") or ""))
        if not image_path.is_file() or not expected_hash:
            failures.append(f"blind_grade: missing bound {path_key}")
        elif sha256(image_path) != expected_hash:
            failures.append(f"blind_grade: stale {path_key} hash")
        elif not measured_path.is_file() or image_path.resolve() != measured_path.resolve():
            failures.append(f"blind_grade: {path_key} does not match visual-similarity input")
    failed_dimensions = [
        name
        for name, value in (blind.get("dimensions") or {}).items()
        if value.get("verdict") != "pass"
    ]
    if blind.get("verdict") != "pass" or failed_dimensions:
        failures.append(
            "blind_grade: visual fidelity failed"
            + (f" ({', '.join(failed_dimensions)})" if failed_dimensions else "")
        )

    dm_ids = documents.get("data_model_ids") or {}
    wb_ids = documents.get("workbook_ids") or {}
    yellow = security.get("decision") == "skip" or any(
        item.get("status") in {"approximated", "needs-review", "skipped"}
        for item in source_objects
        if isinstance(item, dict)
    )
    verdict = "BLOCKED" if failures else ("YELLOW" if yellow else "GREEN")
    counts = {
        status: sum(item.get("status") == status for item in source_objects)
        for status in (
            "migrated",
            "approximated",
            "needs-review",
            "skipped",
            "not-applicable",
        )
    }
    gates = {
        "mission": not inferred and "mission" in documents,
        "data_model_readback": documents.get("data_model_readback", {}).get("pass") is True,
        "workbook_readback": documents.get("workbook_readback", {}).get("pass") is True,
        "source_accounting": census_summary.get("complete") is True,
        "numeric_parity": documents.get("parity", {}).get("match") is True,
        "source_anchors": documents.get("anchors", {}).get("pass") is True,
        "visual_floor": visual_pass,
        "blind_visual_grade": blind.get("verdict") == "pass" and not failed_dimensions,
        "semantic_edit_proof": documents.get("semantic_edits", {}).get("match") is True,
        "relationship_coverage": relationship_gate_pass,
        "dashboard_coverage": dashboard_gate_pass,
        "sql_provenance": sql_gate_pass,
        "security_decision": security.get("decision") in {"not-required", "port", "customize", "skip"},
    }
    return {
        "schema_version": 1,
        "status": verdict,
        "verdict": verdict,
        "complete": not failures,
        "dataModelId": dm_ids.get("dataModelId"),
        "workbookId": wb_ids.get("workbookId"),
        "summary": {
            "complete": not failures and census_summary.get("complete") is True,
            "total": len(source_objects),
            "accounted": len(source_objects),
            "counts": counts,
        },
        "source_objects": source_objects,
        "checks": [
            {"name": "source-accounting", "status": "PASS" if gates["source_accounting"] else "FAIL"},
            {"name": "parity", "status": "PASS" if gates["numeric_parity"] else "FAIL"},
            {
                "name": "render",
                "status": (
                    "PASS"
                    if gates["visual_floor"] and gates["blind_visual_grade"]
                    else "FAIL"
                ),
            },
        ],
        "failures": failures,
        "gates": gates,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--blind-grade", required=True)
    args = parser.parse_args()
    workdir = Path(args.workdir).expanduser().resolve()
    try:
        result = evaluate(workdir, Path(args.blind_grade).expanduser().resolve())
        (workdir / "migration-result.json").write_text(
            json.dumps(result, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FATAL: completion gate could not run: {exc}", file=sys.stderr)
        return 2
    if not result["complete"]:
        print("BLOCKED: Tableau Python migration is not complete", file=sys.stderr)
        for failure in result["failures"]:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(
        f"DONE: GREEN dataModelId={result['dataModelId']} "
        f"workbookId={result['workbookId']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
