#!/usr/bin/env python3
"""Python-only Tableau Phase 6 hard gate.

This is an additive counterpart to ``assert-phase6-ran.rb`` for the explicit
Python runtime profile. It reads completed-run artifacts only and fails closed.

Exit codes:
  0  all gates passed
  40 mission is incomplete or contains inferred fields
  41 doctor/bootstrap did not select a healthy Python profile
  42 data-model POST/readback evidence is incomplete
  43 workbook POST/readback evidence is incomplete
  44 source-gap accounting is incomplete
  45 formula/source-object accounting is incomplete
  46 numeric parity did not pass
  47 source-anchor verification is incomplete
  48 deterministic visual-similarity verification did not pass
  49 blind grade is not passing or is not hash-bound to measured images
  50 source-security decision is absent, unsafe, or unverified
  51 structural semantic edits are unproven
  52 migration report/census accounting is incomplete or contradictory
  70 an unexpected filesystem failure prevented the gate from running

On success, ``phase6-success-python.json`` is written atomically. On every
failure, a stale success marker is removed before returning the gate's code.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

MISSION_FIELDS = ("source", "sigma_connection", "destination", "landing", "scope")
TERMINAL_STATUSES = {
    "migrated",
    "approximated",
    "needs-review",
    "skipped",
    "not-applicable",
}
FORMULA_STATUSES = {
    "spec",
    "verify",
    "chart_only",
    "rls",
    "not_converted",
    "unmapped",
}
EXIT_CODES = {
    "mission": 40,
    "environment": 41,
    "data-model-readback": 42,
    "workbook-readback": 43,
    "gaps": 44,
    "formula-accounting": 45,
    "parity": 46,
    "anchors": 47,
    "visual-similarity": 48,
    "blind-grade": 49,
    "security": 50,
    "semantic-edits": 51,
    "report": 52,
}


@dataclass
class GateFailure(Exception):
    gate: str
    detail: str

    @property
    def exit_code(self) -> int:
        return EXIT_CODES[self.gate]

    def __str__(self) -> str:
        return self.detail


def fail(gate: str, detail: str) -> None:
    raise GateFailure(gate, detail)


def read_json(path: Path, gate: str) -> Any:
    if not path.is_file():
        fail(gate, f"missing {path.name}")
    try:
        with path.open(encoding="utf-8-sig") as handle:
            return json.load(handle)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        fail(gate, f"{path.name} is unreadable: {exc}")


def require_object(path: Path, gate: str) -> dict[str, Any]:
    value = read_json(path, gate)
    if not isinstance(value, dict):
        fail(gate, f"{path.name} must contain a JSON object")
    return value


def read_text(path: Path, gate: str) -> str:
    if not path.is_file():
        fail(gate, f"missing {path.name}")
    try:
        return path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError) as exc:
        fail(gate, f"{path.name} is unreadable: {exc}")


def nonempty(value: Any) -> bool:
    if value is None or value is False:
        return False
    if isinstance(value, str):
        return bool(value.strip())
    if isinstance(value, (list, dict, tuple, set)):
        return bool(value)
    return True


def path_from(value: Any, base: Path, gate: str, label: str) -> Path:
    if not isinstance(value, str) or not value.strip():
        fail(gate, f"{label} path is missing")
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = base / path
    path = path.resolve()
    if not path.is_file():
        fail(gate, f"{label} image is missing: {path}")
    return path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def gate_mission(workdir: Path) -> None:
    mission = require_object(workdir / "mission.json", "mission")
    errors = []
    for field in MISSION_FIELDS:
        record = mission.get(field)
        if not isinstance(record, dict):
            errors.append(f"{field} is missing")
        elif record.get("provenance") != "stated":
            errors.append(f"{field} is not stated")
        elif not nonempty(record.get("value")):
            errors.append(f"{field} has no value")
    if errors:
        fail("mission", "; ".join(errors))


def selected_profile(document: dict[str, Any]) -> tuple[str | None, list[str]]:
    profile = document.get("runtime_profile") or document.get("runtimeProfile") or {}
    if not isinstance(profile, dict):
        return None, []
    selected = profile.get("selected") or profile.get("selectedProfile")
    required = profile.get("required_runtimes") or profile.get("requiredRuntimes") or []
    return selected, list(required) if isinstance(required, list) else []


def gate_environment(workdir: Path) -> None:
    doctor = require_object(workdir / "doctor.json", "environment")
    bootstrap = require_object(workdir / "bootstrap.json", "environment")
    doctor_profile, required = selected_profile(doctor)
    bootstrap_profile, bootstrap_required = selected_profile(bootstrap)
    if doctor.get("pass") is not True:
        fail("environment", "doctor.json does not report pass=true")
    if bootstrap.get("doctor_pass") is not True:
        fail("environment", "bootstrap.json does not report doctor_pass=true")
    if doctor_profile != "python" or bootstrap_profile != "python":
        fail(
            "environment",
            "doctor/bootstrap must both select the python runtime profile "
            f"(doctor={doctor_profile!r}, bootstrap={bootstrap_profile!r})",
        )
    if required != bootstrap_required:
        fail("environment", "doctor/bootstrap required runtime lists disagree")
    if not required or "python" not in required or "ruby" in required:
        fail(
            "environment",
            f"selected Python profile has an invalid required runtime list: {required!r}",
        )
    runtimes = doctor.get("runtimes") or doctor.get("observedRuntimes") or {}
    missing = [
        name
        for name in required
        if not isinstance(runtimes, dict) or runtimes.get(name) is not True
    ]
    if missing:
        fail("environment", "required runtime(s) were not observed: " + ", ".join(missing))


def gate_readback(workdir: Path, kind: str) -> None:
    is_dm = kind == "data-model-readback"
    prefix = "datamodel" if is_dm else "workbook"
    id_file = "dm-ids.json" if is_dm else "wb-ids.json"
    id_key = "dataModelId" if is_dm else "workbookId"
    gate = kind
    ids = require_object(workdir / id_file, gate)
    readback = require_object(workdir / f"{prefix}-readback.json", gate)
    verdict = require_object(workdir / f"{prefix}-readback-verdict.json", gate)
    if not nonempty(ids.get(id_key)):
        fail(gate, f"{id_file} has no {id_key}")
    if not readback:
        fail(gate, f"{prefix}-readback.json is empty")
    if verdict.get("pass") is not True:
        fail(gate, f"{prefix} readback verdict does not report pass=true")
    for key in ("missing_elements", "error_columns"):
        if verdict.get(key) not in (None, []):
            fail(gate, f"{prefix} readback reports {key}")
    if verdict.get("dropped_columns") not in (None, {}):
        fail(gate, f"{prefix} readback reports dropped_columns")


def validated_gap_names(workdir: Path) -> set[str]:
    path = workdir / "gap-resolutions.json"
    if not path.is_file():
        return set()
    document = require_object(path, "gaps")
    records = document.get("resolutions")
    if not isinstance(records, dict):
        fail("gaps", "gap-resolutions.json lacks a resolutions object")
    return {
        str(name)
        for name, record in records.items()
        if isinstance(record, dict)
        and record.get("status") == "validated"
        and nonempty(record.get("evidence"))
    }


def gate_gaps(workdir: Path) -> None:
    gaps = require_object(workdir / "gaps.json", "gaps")
    features = gaps.get("detected_features")
    if not isinstance(features, list) or any(not isinstance(row, dict) for row in features):
        fail("gaps", "gaps.json detected_features must be an array of objects")
    if (workdir / "unresolved-gaps.json").is_file():
        unresolved = read_json(workdir / "unresolved-gaps.json", "gaps")
        if unresolved:
            fail("gaps", "unresolved-gaps.json is non-empty")
    validated = validated_gap_names(workdir)
    open_names = sorted(
        {
            str(row.get("name") or "(unnamed)")
            for row in features
            if row.get("status") == "unhandled" and str(row.get("name") or "") not in validated
        }
    )
    if open_names:
        fail("gaps", "unhandled source gap(s): " + ", ".join(open_names))

    audit = read_json(workdir / "formula-audit.json", "gaps")
    if gaps.get("formula_audit") != audit:
        fail("gaps", "gaps.json formula_audit does not match formula-audit.json")


def census_identity(row: dict[str, Any]) -> tuple[str, str, str]:
    return (
        str(row.get("type") or row.get("kind") or "").strip().casefold(),
        str(row.get("id") or row.get("object_id") or "").strip().casefold(),
        str(row.get("name") or row.get("title") or "").strip().casefold(),
    )


def census_rows(document: dict[str, Any], gate: str) -> list[dict[str, Any]]:
    rows = document.get("objects")
    if rows is None:
        rows = document.get("source_objects")
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        fail(gate, "source-object-census.json lacks an objects array")
    identities = [census_identity(row) for row in rows]
    if any(not identity[1] and not identity[2] for identity in identities):
        fail(gate, "a census object has neither id nor name")
    if len(identities) != len(set(identities)):
        fail(gate, "source-object-census.json contains duplicate object identities")
    bad = [
        row
        for row in rows
        if row.get("status") not in TERMINAL_STATUSES
        or not nonempty(row.get("evidence") or row.get("status_sources"))
    ]
    if bad:
        fail(gate, f"{len(bad)} census object(s) lack a terminal status with evidence")
    summary = document.get("summary")
    if not isinstance(summary, dict):
        fail(gate, "source-object-census.json lacks summary accounting")
    if summary.get("complete") is not True:
        fail(gate, "source-object-census.json summary.complete is not true")
    if summary.get("total") != len(rows):
        fail(gate, "source-object-census.json summary.total disagrees with objects")
    return rows


def formula_candidates(row: dict[str, Any]) -> set[str]:
    return {
        str(row.get(key)).strip().casefold()
        for key in ("internal_name", "calculation", "caption", "name", "id")
        if nonempty(row.get(key))
    }


def gate_formula_accounting(workdir: Path) -> None:
    audit = require_object(workdir / "formula-audit.json", "formula-accounting")
    if str(audit.get("status") or "").upper() == "ERROR":
        fail("formula-accounting", "formula-audit.json reports ERROR")
    formulas = audit.get("formulas")
    counts = audit.get("counts")
    if not isinstance(formulas, list) or any(not isinstance(row, dict) for row in formulas):
        fail("formula-accounting", "formula-audit.json formulas must be an array of objects")
    if not isinstance(counts, dict):
        fail("formula-accounting", "formula-audit.json lacks counts")
    observed: dict[str, int] = {}
    for row in formulas:
        status = str(row.get("status") or "")
        if status not in FORMULA_STATUSES:
            fail("formula-accounting", f"formula has unknown status {status!r}")
        observed[status] = observed.get(status, 0) + 1
    for status in set(observed) | set(counts):
        if counts.get(status, 0) != observed.get(status, 0):
            fail("formula-accounting", f"formula count for {status!r} is inconsistent")
    expected = audit.get("expected_formula_count")
    if expected is not None and expected != len(formulas):
        fail("formula-accounting", "expected_formula_count disagrees with formulas")

    census = require_object(workdir / "source-object-census.json", "formula-accounting")
    objects = census_rows(census, "formula-accounting")
    accounted: dict[str, set[str]] = {}
    for obj in objects:
        for value in (census_identity(obj)[1], census_identity(obj)[2]):
            if value:
                accounted.setdefault(value, set()).add(str(obj.get("status")))
    missing = []
    for row in formulas:
        direct = row.get("terminal_status")
        if direct in TERMINAL_STATUSES:
            continue
        matches = {
            status
            for candidate in formula_candidates(row)
            for status in accounted.get(candidate, set())
        }
        if len(matches) != 1:
            missing.append(str(row.get("caption") or row.get("internal_name") or "(unnamed)"))
    if missing:
        fail(
            "formula-accounting",
            "formula(s) lack exactly one terminal census disposition: " + ", ".join(sorted(missing)),
        )


def gate_parity(workdir: Path) -> None:
    parity = require_object(workdir / "parity-final.json", "parity")
    if parity.get("status") != "PASS" or parity.get("match") is not True:
        fail("parity", "parity-final.json must report status=PASS and match=true")
    if parity.get("differences") not in (None, []):
        fail("parity", "parity-final.json contains differences")


def gate_anchors(workdir: Path) -> None:
    source = require_object(workdir / "source-anchors.json", "anchors")
    verdict = require_object(workdir / "anchors-verdict.json", "anchors")
    anchors = source.get("anchors")
    if not isinstance(anchors, list) or len(anchors) < 5:
        fail("anchors", "source-anchors.json must contain at least five anchors")
    if any(
        not isinstance(row, dict) or not nonempty(row.get("id"))
        for row in anchors
    ):
        fail("anchors", "every source anchor must be an object with an id")
    if verdict.get("pass") is not True:
        fail("anchors", "anchors-verdict.json does not report pass=true")
    if verdict.get("checked") != len(anchors) or verdict.get("matched") != len(anchors):
        fail("anchors", "anchor checked/matched counts are stale or incomplete")
    if verdict.get("missing") not in (None, []):
        fail("anchors", "anchors-verdict.json contains missing anchors")
    if verdict.get("tiles_all_nonempty") is not True:
        fail("anchors", "displayed tile exports were not all non-empty")
    coverage = verdict.get("anchor_coverage")
    if not isinstance(coverage, dict):
        fail("anchors", "anchors-verdict.json lacks per-displayed-tile anchor_coverage")
    covered = coverage.get("covered")
    displayed = coverage.get("displayed")
    if not isinstance(covered, int) or not isinstance(displayed, int) or displayed <= 0:
        fail("anchors", "anchor coverage counts are invalid")
    uncovered = coverage.get("uncovered") or []
    waivers = source.get("coverage_waivers") or []
    waived = {
        str(row.get("tile"))
        for row in waivers
        if isinstance(row, dict) and nonempty(row.get("tile")) and nonempty(row.get("reason"))
    }
    uncovered_names = {
        str(row.get("tile") or row.get("name") or row)
        for row in uncovered
    }
    if (
        covered > displayed
        or covered + len(uncovered_names) != displayed
        or not uncovered_names.issubset(waived)
    ):
        fail("anchors", "not every displayed tile has an anchor or a named coverage waiver")


def gate_visual(workdir: Path) -> tuple[dict[str, Any], Path, Path]:
    visual = require_object(workdir / "visual-similarity-final.json", "visual-similarity")
    if visual.get("pass") is not True:
        fail("visual-similarity", "visual-similarity-final.json does not report pass=true")
    score = visual.get("score_overall")
    threshold = visual.get("threshold")
    if (
        not isinstance(score, (int, float))
        or isinstance(score, bool)
        or not isinstance(threshold, (int, float))
        or isinstance(threshold, bool)
        or score < threshold
    ):
        fail("visual-similarity", "visual score is absent or below its recorded threshold")
    health_paths = []
    for key, label in (("source_health", "source"), ("render_health", "target")):
        health = visual.get(key)
        if not isinstance(health, dict) or health.get("status") != "PASS":
            fail("visual-similarity", f"{key} does not report status=PASS")
        health_paths.append(
            path_from(health.get("path"), workdir, "visual-similarity", label)
        )
    return visual, health_paths[0], health_paths[1]


def gate_blind_grade(blind_path: Path, source_png: Path, target_png: Path) -> str:
    blind = require_object(blind_path, "blind-grade")
    if blind.get("verdict") != "pass":
        fail("blind-grade", "blind grade verdict is not pass")
    dimensions = blind.get("dimensions")
    if not isinstance(dimensions, dict) or not dimensions:
        fail("blind-grade", "blind grade has no dimension verdicts")
    failed = [
        str(name)
        for name, record in dimensions.items()
        if not isinstance(record, dict) or record.get("verdict") != "pass"
    ]
    if failed:
        fail("blind-grade", "blind grade has non-passing dimension(s): " + ", ".join(failed))
    expected = (
        ("source_png", "source_sha256", source_png),
        ("target_png", "target_sha256", target_png),
    )
    for path_key, hash_key, measured in expected:
        bound = path_from(
            blind.get(path_key), blind_path.parent, "blind-grade", path_key
        )
        if bound != measured:
            fail("blind-grade", f"{path_key} is not the visual-similarity input")
        recorded_hash = blind.get(hash_key)
        if not isinstance(recorded_hash, str) or len(recorded_hash) != 64:
            fail("blind-grade", f"{hash_key} is missing or malformed")
        if not hmac.compare_digest(sha256(bound), recorded_hash.lower()):
            fail("blind-grade", f"{path_key} hash is stale")
    return sha256(blind_path)


def security_rules(workdir: Path) -> list[Any]:
    security_path = workdir / "security.json"
    if security_path.is_file():
        raw = read_json(security_path, "security")
        rules = raw.get("security") if isinstance(raw, dict) else raw
    else:
        meta_path = (
            workdir / "conv-meta-repaired.json"
            if (workdir / "conv-meta-repaired.json").is_file()
            else workdir / "conv-meta.json"
        )
        metadata = require_object(meta_path, "security")
        rules = metadata.get("security") or []
    if not isinstance(rules, list):
        fail("security", "source security findings must be an array")
    return rules


def gate_security(workdir: Path) -> None:
    rules = security_rules(workdir)
    decision = require_object(workdir / "security-decision.json", "security")
    if decision.get("rules_detected") != len(rules):
        fail("security", "security decision rule count disagrees with converter findings")
    choice = decision.get("decision")
    if not rules:
        if choice != "not-required":
            fail("security", "zero detected rules require decision=not-required")
        return
    if choice not in {"port", "customize", "skip"}:
        fail("security", "detected security rules require port, customize, or skip")
    if choice == "skip":
        if (
            not nonempty(decision.get("reason"))
            or decision.get("acknowledges_all_rows_visible") is not True
        ):
            fail(
                "security",
                "skip requires a reason and acknowledges_all_rows_visible=true",
            )
    elif (
        decision.get("status") != "applied"
        or decision.get("readback_verified") is not True
    ):
        fail("security", f"{choice} must be applied and readback_verified")


def gate_semantic_edits(workdir: Path) -> None:
    document = require_object(workdir / "semantic-edits.json", "semantic-edits")
    entries = document.get("entries")
    if entries is None:
        entries = document.get("edits")
    if not isinstance(entries, list) or any(not isinstance(row, dict) for row in entries):
        fail("semantic-edits", "semantic-edits.json must contain an edits/entries array")
    if document.get("match") is not True:
        fail("semantic-edits", "semantic-edits.json does not report match=true")
    unproven = []
    for row in entries:
        proof = row.get("proof")
        if not isinstance(proof, dict) or proof.get("match") is not True:
            unproven.append(str(row.get("edit_description") or row.get("name") or "(unnamed)"))
    if unproven:
        fail("semantic-edits", "unproven structural edit(s): " + ", ".join(unproven))


def gate_report(workdir: Path) -> tuple[str, str, str]:
    census = require_object(workdir / "source-object-census.json", "report")
    census_objects = census_rows(census, "report")
    result = require_object(workdir / "migration-result.json", "report")
    markdown_path = workdir / "MIGRATION_REPORT.md"
    markdown = read_text(markdown_path, "report")
    verdict = result.get("verdict") or result.get("status")
    if verdict not in {"GREEN", "YELLOW"}:
        fail("report", f"migration-result verdict is not completable: {verdict!r}")
    summary = result.get("summary")
    result_objects = result.get("source_objects")
    if not isinstance(summary, dict) or not isinstance(result_objects, list):
        fail("report", "migration-result.json lacks summary/source_objects accounting")
    if (
        summary.get("complete") is not True
        or summary.get("total") != len(result_objects)
        or summary.get("accounted") != summary.get("total")
    ):
        fail("report", "migration-result summary is incomplete or inconsistent")
    counts = summary.get("counts")
    expected_counts = {
        status: sum(row.get("status") == status for row in census_objects)
        for status in TERMINAL_STATUSES
    }
    if not isinstance(counts, dict) or any(
        counts.get(status) != count for status, count in expected_counts.items()
    ):
        fail("report", "migration-result terminal-status counts are incomplete or inconsistent")
    census_map = {census_identity(row): row.get("status") for row in census_objects}
    result_map = {
        census_identity(row): row.get("status")
        for row in result_objects
        if isinstance(row, dict)
    }
    if len(result_map) != len(result_objects) or result_map != census_map:
        fail("report", "migration-result source objects disagree with the source census")
    checks = result.get("checks")
    if not isinstance(checks, list) or not checks:
        fail("report", "migration-result.json has no completion checks")
    if any(not isinstance(row, dict) or row.get("status") != "PASS" for row in checks):
        fail("report", "migration-result.json contains a non-passing completion check")
    check_names = {
        str(row.get("name"))
        for row in checks
        if isinstance(row, dict) and nonempty(row.get("name"))
    }
    missing_checks = {"source-accounting", "parity", "render"} - check_names
    if missing_checks:
        fail(
            "report",
            "migration-result.json lacks required check(s): "
            + ", ".join(sorted(missing_checks)),
        )
    gates = result.get("gates")
    if gates is not None and (
        not isinstance(gates, dict) or not gates or any(value is not True for value in gates.values())
    ):
        fail("report", "migration-result.json contains an incomplete gate census")
    if result.get("failures") not in (None, []):
        fail("report", "migration-result.json contains blocking failures")
    decision = require_object(workdir / "security-decision.json", "report")
    security_skip = decision.get("decision") == "skip"
    yellow_status = any(
        row.get("status") in {"approximated", "needs-review", "skipped"}
        for row in census_objects
    )
    yellow_evidence = nonempty(result.get("waivers")) or nonempty(
        result.get("degradations")
    )
    expected_verdict = (
        "YELLOW"
        if security_skip or yellow_status or yellow_evidence
        else "GREEN"
    )
    if verdict != expected_verdict:
        fail(
            "report",
            f"migration-result verdict {verdict} contradicts derived {expected_verdict}",
        )
    if (
        f"Verdict: **{verdict}**" not in markdown
        and f"**Verdict:** {verdict}" not in markdown
    ):
        fail("report", "MIGRATION_REPORT.md verdict disagrees with migration-result.json")
    total = summary["total"]
    if f"{total}/{total}" not in markdown:
        fail("report", "MIGRATION_REPORT.md lacks complete accounting totals")
    if security_skip and (
        "security" not in markdown.casefold()
        or str(decision.get("reason") or "") not in markdown
    ):
        fail("report", "MIGRATION_REPORT.md omits the loud security-skip decision")
    for row in census_objects:
        tokens = [
            str(value)
            for value in (
                row.get("type"),
                row.get("id"),
                row.get("name"),
                row.get("status"),
            )
            if nonempty(value)
        ]
        if not any(all(token in line for token in tokens) for line in markdown.splitlines()):
            fail("report", "MIGRATION_REPORT.md omits a canonical source-object row")
    ids_dm = require_object(workdir / "dm-ids.json", "report").get("dataModelId")
    ids_wb = require_object(workdir / "wb-ids.json", "report").get("workbookId")
    return str(verdict), str(ids_dm), str(ids_wb)


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def clear_marker(marker: Path) -> None:
    try:
        marker.unlink(missing_ok=True)
    except OSError as exc:
        raise OSError(f"could not remove stale success marker {marker}: {exc}") from exc


def run_gates(workdir: Path, blind_grade: Path) -> dict[str, Any]:
    checks: list[tuple[str, Callable[[], Any]]] = [
        ("mission", lambda: gate_mission(workdir)),
        ("environment", lambda: gate_environment(workdir)),
        (
            "data-model-readback",
            lambda: gate_readback(workdir, "data-model-readback"),
        ),
        ("workbook-readback", lambda: gate_readback(workdir, "workbook-readback")),
        ("gaps", lambda: gate_gaps(workdir)),
        ("formula-accounting", lambda: gate_formula_accounting(workdir)),
        ("parity", lambda: gate_parity(workdir)),
        ("anchors", lambda: gate_anchors(workdir)),
    ]
    passed = []
    for name, check in checks:
        check()
        passed.append(name)
    _visual, source_png, target_png = gate_visual(workdir)
    passed.append("visual-similarity")
    blind_sha = gate_blind_grade(blind_grade, source_png, target_png)
    passed.append("blind-grade")
    gate_security(workdir)
    passed.append("security")
    gate_semantic_edits(workdir)
    passed.append("semantic-edits")
    verdict, data_model_id, workbook_id = gate_report(workdir)
    passed.append("report")
    return {
        "complete": True,
        "verdict": verdict,
        "runtime_profile": "python",
        "dataModelId": data_model_id,
        "workbookId": workbook_id,
        "blind_grade_sha256": blind_sha,
        "gates": {name: True for name in passed},
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--blind-grade", required=True)
    args = parser.parse_args(argv)
    workdir = Path(args.workdir).expanduser().resolve()
    blind_grade = Path(args.blind_grade).expanduser().resolve()
    marker = workdir / "phase6-success-python.json"
    try:
        result = run_gates(workdir, blind_grade)
        atomic_write_json(marker, result)
    except GateFailure as exc:
        try:
            clear_marker(marker)
        except OSError as marker_error:
            print(f"[FATAL] {marker_error}", file=sys.stderr)
            return 70
        print(
            f"[FAIL] gate {exc.gate} (exit {exc.exit_code}): {exc.detail}",
            file=sys.stderr,
        )
        return exc.exit_code
    except OSError as exc:
        try:
            clear_marker(marker)
        except OSError as marker_error:
            exc = OSError(f"{exc}; {marker_error}")
        print(f"[FATAL] Phase 6 gate could not access an artifact: {exc}", file=sys.stderr)
        return 70
    print(
        "[PASS] all Python Phase 6 gates passed — "
        f"verdict={result['verdict']} dataModelId={result['dataModelId']} "
        f"workbookId={result['workbookId']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
