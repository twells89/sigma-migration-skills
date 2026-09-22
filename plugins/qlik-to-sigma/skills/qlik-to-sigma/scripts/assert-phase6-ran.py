#!/usr/bin/env python3
"""Qlik-specific, Python-only Phase 6 completion gate.

This gate consumes the artifacts produced by ``migrate-qlik`` and the Qlik
finalizer.  It does not perform source or Sigma writes.  It is the only Python
command allowed to create ``phase6-success.json``; every failed run removes a
stale marker.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import degradation_ledger  # noqa: E402
from lib import blind_grade  # noqa: E402
import control_lint  # noqa: E402
import layout_lint  # noqa: E402
import render_integrity  # noqa: E402

HERE = Path(__file__).resolve().parent
TERMINAL = {
    "migrated",
    "approximated",
    "needs-review",
    "skipped",
    "not-applicable",
}
PROVENANCE = {"live", "engine-export", "inferred"}
PASS_STATES = {"PASS", "MATCH", "PASSED", "GREEN", "OK", "WAREHOUSE-PASS"}
QUERYABLE_KINDS = {
    "table",
    "pivot-table",
    "pivot",
    "kpi",
    "kpi-chart",
    "progress",
    "bar",
    "bar-chart",
    "line",
    "line-chart",
    "area",
    "area-chart",
    "combo",
    "combo-chart",
    "pie",
    "pie-chart",
    "donut",
    "scatter",
    "scatterplot",
    "trellis",
}
NON_QUERYABLE_KINDS = {
    "control",
    "text",
    "image",
    "container",
    "tabbed-container",
    "divider",
    "spacer",
}


@dataclass
class GateFailure(Exception):
    code: int
    gate: str
    detail: str

    def __str__(self) -> str:
        return self.detail


def fail(code: int, gate: str, detail: str) -> None:
    raise GateFailure(code, gate, detail)


def integer(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def load_json(path: Path, code: int, gate: str) -> Any:
    if not path.is_file():
        fail(code, gate, f"missing {path.name}")
    try:
        with path.open(encoding="utf-8-sig") as handle:
            return json.load(handle)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        fail(code, gate, f"{path.name} is unreadable: {exc}")


def load_object(path: Path, code: int, gate: str) -> dict[str, Any]:
    value = load_json(path, code, gate)
    if not isinstance(value, dict):
        fail(code, gate, f"{path.name} must contain a JSON object")
    return value


def write_json(path: Path, value: Any) -> None:
    temporary = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    try:
        temporary.write_text(
            json.dumps(value, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def source_rows(document: dict[str, Any]) -> list[dict[str, Any]]:
    value = (
        document.get("source_objects")
        if isinstance(document.get("source_objects"), list)
        else document.get("objects")
    )
    return [row for row in value or [] if isinstance(row, dict)]


def row_status(row: dict[str, Any]) -> str:
    value = (
        row.get("status")
        or row.get("terminal_status")
        or row.get("migration_status")
        or row.get("outcome")
        or ""
    )
    return re.sub(r"[_\s]+", "-", str(value).strip().casefold())


def identity(row: dict[str, Any]) -> tuple[str, str, str]:
    kind = str(
        row.get("type") or row.get("object_type") or row.get("kind") or ""
    ).strip().casefold()
    object_id = str(
        row.get("id")
        or row.get("source_object_id")
        or row.get("objectId")
        or row.get("sourceId")
        or ""
    ).strip().casefold()
    name = str(row.get("name") or row.get("title") or row.get("visual") or "").strip().casefold()
    return kind, object_id or f"name:{name}", row_status(row)


def workbook_document(document: dict[str, Any]) -> dict[str, Any]:
    nested = document.get("document")
    return nested if isinstance(nested, dict) else document


def workbook_spec(
    workdir: Path, workbook_id: str
) -> tuple[dict[str, Any], Path, str]:
    for name in ("wb-readback.json", "workbook-readback.json"):
        path = workdir / name
        if path.is_file():
            readback = load_object(path, 6, "layout")
            recorded_id = str(readback.get("workbookId") or "")
            if recorded_id != workbook_id:
                fail(
                    6,
                    "layout",
                    f"{name} belongs to {recorded_id or 'an unknown workbook'}, "
                    f"not {workbook_id}",
                )
            version = readback.get("latestDocumentVersion") or readback.get(
                "latestVersion"
            )
            if version in (None, ""):
                fail(6, "layout", f"{name} has no live document version")
            return readback, path, str(version)
    fail(6, "layout", "live workbook spec readback is missing")


def all_elements(document: dict[str, Any]) -> list[dict[str, Any]]:
    root = workbook_document(document)
    result = [
        row for row in root.get("elements") or [] if isinstance(row, dict)
    ]
    for page in root.get("pages") or []:
        if isinstance(page, dict):
            result.extend(
                row for row in page.get("elements") or [] if isinstance(row, dict)
            )
    unique: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row in result:
        key = str(row.get("id") or id(row))
        if key not in seen:
            seen.add(key)
            unique.append(row)
    return unique


def queryable_elements(document: dict[str, Any]) -> list[dict[str, Any]]:
    result = []
    for element in all_elements(document):
        kind = str(element.get("kind") or "").casefold()
        if kind in NON_QUERYABLE_KINDS:
            continue
        if kind in QUERYABLE_KINDS or element.get("columns") or element.get("source"):
            result.append(element)
    return result


def gate_parity(workdir: Path) -> tuple[dict[str, Any], int]:
    path = workdir / "parity-final.json"
    if not path.is_file():
        fail(1, "parity", "parity-final.json is missing")
    parity = load_object(path, 3, "parity")
    total = integer(parity.get("charts_total"))
    passed = integer(parity.get("charts_pass"))
    failed = (
        integer(parity.get("charts_fail"))
        if "charts_fail" in parity
        else total - passed
    )
    rows = parity.get("per_chart")
    strict_rows = isinstance(rows, list) and bool(rows) and all(
        isinstance(row, dict)
        and row.get("pass") is True
        and str(row.get("status") or "").upper() in PASS_STATES
        for row in rows
    )
    valid = (
        parity.get("status") == "PASS"
        and parity.get("strict") is True
        and total > 0
        and passed == total
        and failed == 0
        and not (parity.get("fail_names") or [])
        and not (parity.get("pending_names") or [])
        and integer(parity.get("charts_stale_explained")) == 0
        and parity.get("divergent") is not True
        and strict_rows
    )
    if not valid:
        fail(
            2,
            "parity",
            "strict source parity is incomplete or divergent "
            f"(status={parity.get('status')!r}, strict={parity.get('strict')!r}, "
            f"charts={passed}/{total}, failed={failed})",
        )
    column_errors = parity.get("column_errors") or []
    if column_errors:
        fail(5, "parity", f"{len(column_errors)} error-typed workbook column(s) remain")
    column_scan = load_object(workdir / "column-scan.json", 5, "parity")
    if (
        column_scan.get("status") != "complete-clean"
        or integer(column_scan.get("columns_read")) <= 0
        or (column_scan.get("errors") or [])
    ):
        fail(5, "parity", "live workbook column scan is empty, incomplete, or contains errors")
    return parity, total


def gate_coverage(workdir: Path, parity: dict[str, Any]) -> None:
    coverage = load_object(workdir / "workbook-coverage.json", 7, "coverage")
    source_ids = [str(value) for value in coverage.get("sourceVisualIds") or []]
    built_ids = [str(value) for value in coverage.get("builtSourceVisualIds") or []]
    source_count = integer(coverage.get("sourceVisuals") or len(source_ids))
    queryable_count = integer(coverage.get("queryableElements"))
    unbuilt = [str(value) for value in coverage.get("unbuiltSourceVisualIds") or []]
    if (
        coverage.get("status") not in (None, "PASS")
        or source_count <= 0
        or queryable_count <= 0
        or not source_ids
        or set(source_ids) != set(built_ids)
        or len(source_ids) != len(set(source_ids))
        or len(built_ids) != len(set(built_ids))
        or integer(parity.get("charts_total")) != len(built_ids)
        or unbuilt
    ):
        fail(
            7,
            "coverage",
            "workbook coverage is empty, partial, duplicated, or inconsistent "
            f"(source={source_count}, built={len(built_ids)}, "
            f"queryable={queryable_count}, unbuilt={unbuilt})",
        )
    tile = parity.get("tile_census")
    if not isinstance(tile, dict):
        fail(7, "coverage", "parity-final.json lacks the tile census")
    zones = integer(tile.get("zones_total"))
    built = integer(tile.get("charts_built"))
    unmatched = integer(tile.get("zones_unmatched"))
    if (
        zones <= 0
        or zones != len(source_ids)
        or built != len(built_ids)
        or unmatched != 0
        or tile.get("unmatched_zone_names")
    ):
        fail(
            7,
            "coverage",
            f"tile census is not exact (zones={zones}, built={built}, unmatched={unmatched})",
        )


def gate_layout(
    workdir: Path,
    document: dict[str, Any],
    skip_lint_reason: str | None,
) -> None:
    layout_path = workdir / "layout.xml"
    root = workbook_document(document)
    embedded = root.get("layout")
    if not layout_path.is_file() and not embedded:
        fail(6, "layout", "layout.xml and persisted layout are both absent")
    layout_text = ""
    if layout_path.is_file():
        try:
            layout_text = layout_path.read_text(encoding="utf-8-sig")
        except (OSError, UnicodeError) as exc:
            fail(6, "layout", f"layout.xml is unreadable: {exc}")
        if "<Page" not in layout_text or "<Element" not in layout_text:
            fail(6, "layout", "layout.xml has no page/element placement")
    queryable = queryable_elements(document)
    if not queryable:
        fail(6, "layout", "workbook spec has no queryable elements")
    if layout_text:
        missing = [
            str(row.get("id"))
            for row in queryable
            if row.get("id") and str(row.get("id")) not in layout_text
        ]
        if missing:
            fail(
                6,
                "layout",
                "layout.xml omits queryable element(s): " + ", ".join(missing[:10]),
            )
    render_report = render_integrity.lint(document, "live-workbook-readback")
    if render_report.get("status") != "PASS":
        fail(
            6,
            "layout",
            f"live readback has {render_report.get('blank_risk_count')} "
            "blank-risk data element(s)",
        )
    if skip_lint_reason:
        return
    violations = list(layout_lint.lint(document))
    for page in root.get("pages") or []:
        if not isinstance(page, dict) or page.get("visibility") == "hidden":
            continue
        name = str(page.get("name") or page.get("title") or "")
        if re.fullmatch(r"(?:page|sheet|dashboard)\s*\d+", name.strip(), re.I):
            violations.append(f"generic page title {name!r}")
    raw_id = re.compile(r"^(?:[0-9a-f]{8}-[0-9a-f-]{27,}|(?:el|pg|chart)[-_][0-9a-z_-]+)$", re.I)
    for element in all_elements(document):
        if str(element.get("kind") or "").casefold() in {"container", "divider", "spacer"}:
            continue
        name = str(element.get("name") or element.get("title") or "")
        element_id = str(element.get("id") or "")
        if not name or name == element_id or raw_id.fullmatch(name):
            violations.append(f"raw or missing display name for {element_id or '(unknown)'}")
    if violations:
        fail(8, "layout", "; ".join(violations[:10]))


def gate_controls(
    workdir: Path,
    document: dict[str, Any],
    control_scope_path: Path,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    scope = load_object(control_scope_path, 9, "controls")
    if not isinstance(scope.get("controls"), list):
        fail(9, "controls", "control-scope.json lacks a controls array")
    if not isinstance(scope.get("unbound"), list):
        fail(9, "controls", "control-scope.json lacks an unbound array")
    lint_violations = control_lint.lint(document, scope)
    if lint_violations:
        fail(9, "controls", "; ".join(lint_violations[:10]))
    spec_controls = [
        row
        for row in all_elements(document)
        if str(row.get("kind") or "").casefold() == "control"
    ]
    spec_by_id = {
        str(row.get("controlId") or row.get("id")): row
        for row in spec_controls
        if row.get("controlId") or row.get("id")
    }
    scope_by_id: dict[str, dict[str, Any]] = {}
    for row in scope["controls"]:
        if not isinstance(row, dict) or not str(row.get("controlId") or "").strip():
            fail(9, "controls", "a control-scope entry has no controlId")
        control_id = str(row["controlId"])
        if control_id in scope_by_id:
            fail(9, "controls", f"duplicate control-scope entry: {control_id}")
        scope_by_id[control_id] = row
        if control_id not in spec_by_id:
            fail(9, "controls", f"control-scope references missing control {control_id}")
        if not isinstance(row.get("mustReach"), list):
            fail(9, "controls", f"control {control_id} lacks mustReach evidence")
    for control_id, row in spec_by_id.items():
        if control_id not in scope_by_id:
            fail(9, "controls", f"workbook control {control_id} is absent from control-scope")
        if not row.get("filters") and not row.get("source"):
            fail(9, "controls", f"workbook control {control_id} has no source/filter target")
    queryable_ids = {
        str(row.get("id")) for row in queryable_elements(document) if row.get("id")
    }
    for control_id, row in scope_by_id.items():
        must_reach = {str(value) for value in row.get("mustReach") or []}
        missing = must_reach - queryable_ids
        if missing:
            fail(
                9,
                "controls",
                f"control {control_id} mustReach references missing target(s): "
                + ", ".join(sorted(missing)),
            )
        if queryable_ids and not must_reach:
            fail(9, "controls", f"control {control_id} has empty mustReach coverage")
    for row in scope["unbound"]:
        if (
            not isinstance(row, dict)
            or not str(row.get("status") or "").strip()
            or not str(row.get("reason") or "").strip()
        ):
            fail(9, "controls", "an unbound source control lacks status/reason evidence")
    source_signals = integer(scope.get("sourceFilterSignals"))
    if source_signals > 0 and not scope_by_id and not scope["unbound"]:
        fail(9, "controls", "source filter signals exist but no controls/dispositions were recorded")

    coverage_paths = sorted(workdir.glob("*-controls-coverage.json"))
    for path in coverage_paths:
        coverage = load_object(path, 9, "controls")
        details = coverage.get("detail")
        if not isinstance(details, list):
            fail(9, "controls", f"{path.name} lacks detail rows")
        for row in details:
            if not isinstance(row, dict):
                fail(9, "controls", f"{path.name} contains a malformed detail row")
            if row.get("status") != "emitted" and (
                not row.get("detail")
                or row.get("terminal_status") not in TERMINAL
            ):
                fail(
                    9,
                    "controls",
                    f"source control {row.get('name') or row.get('id')} has no terminal disposition",
                )
    return spec_controls, scope


def probe_rows(document: Any) -> list[dict[str, Any]]:
    if isinstance(document, list):
        return [row for row in document if isinstance(row, dict)]
    if isinstance(document, dict):
        for key in ("results", "controls", "probes"):
            if isinstance(document.get(key), list):
                return [row for row in document[key] if isinstance(row, dict)]
    return []


def gate_flip(
    workdir: Path,
    workbook_id: str,
    document_version: str,
    controls: list[dict[str, Any]],
    required: bool,
    waiver_reason: str | None,
) -> None:
    if not required:
        return
    if waiver_reason:
        return
    if not controls:
        return
    path = workdir / "probe-controls" / "probe-results.json"
    if path.is_file():
        rows = probe_rows(load_json(path, 21, "control-flip"))
        failures = [
            row for row in rows if str(row.get("result") or "").upper() == "FAIL"
        ]
        passes = [
            row for row in rows if str(row.get("result") or "").upper() == "PASS"
        ]
        skips = [
            row for row in rows if str(row.get("result") or "").upper() == "SKIP"
        ]
        if not failures and not passes and skips:
            marker_path = workdir / "control-flip-unverified.json"
            marker = (
                load_object(marker_path, 21, "control-flip")
                if marker_path.is_file()
                else {}
            )
            evidence = load_object(
                workdir / "probe-controls" / "probe-evidence.json",
                21,
                "control-flip",
            )
            try:
                probed_at = datetime.fromisoformat(
                    str(evidence.get("probed_at") or "").replace("Z", "+00:00")
                )
                age = datetime.now(timezone.utc) - probed_at.astimezone(
                    timezone.utc
                )
            except ValueError:
                age = None
            expected_controls = {
                str(row.get("controlId") or row.get("id"))
                for row in controls
                if row.get("controlId") or row.get("id")
            }
            skipped_controls = {
                str(row.get("control"))
                for row in skips
                if row.get("control")
            }
            marker_controls = {
                str(row.get("control"))
                for row in marker.get("unprobed") or []
                if isinstance(row, dict) and row.get("control")
            }
            if (
                marker.get("workbookId") == workbook_id
                and isinstance(marker.get("unprobed"), list)
                and marker["unprobed"]
                and str(evidence.get("workbook_id") or "") == workbook_id
                and str(evidence.get("doc_version") or "") == document_version
                and age is not None
                and age.total_seconds() <= 24 * 3600
                and expected_controls == skipped_controls == marker_controls
            ):
                return
            fail(
                21,
                "control-flip",
                "all controls were unprobeable but no matching advisory marker exists",
            )
        evidence = load_object(
            workdir / "probe-controls" / "probe-evidence.json",
            21,
            "control-flip",
        )
        if (
            str(evidence.get("workbook_id") or "") != workbook_id
            or str(evidence.get("doc_version") or "") != document_version
        ):
            fail(21, "control-flip", "runtime flip evidence belongs to a stale workbook version")
        try:
            probed_at = datetime.fromisoformat(
                str(evidence.get("probed_at") or "").replace("Z", "+00:00")
            )
            age = datetime.now(timezone.utc) - probed_at.astimezone(timezone.utc)
        except ValueError:
            fail(21, "control-flip", "runtime flip evidence has no valid probe timestamp")
        if age.total_seconds() > 24 * 3600:
            fail(21, "control-flip", "runtime flip evidence is older than 24 hours")
        exports = evidence.get("exports")
        if not isinstance(exports, dict) or not exports:
            fail(21, "control-flip", "runtime flip evidence contains no raw export hashes")
        for filename, expected_hash in exports.items():
            export_path = workdir / "probe-controls" / str(filename)
            if (
                not export_path.is_file()
                or hashlib.sha256(export_path.read_bytes()).hexdigest()
                != str(expected_hash)
            ):
                fail(21, "control-flip", f"runtime flip export is missing or stale: {filename}")
        wrong_workbooks = {
            str(row.get("workbookId"))
            for row in rows
            if row.get("workbookId") and str(row.get("workbookId")) != workbook_id
        }
        if skips:
            marker_path = workdir / "control-flip-unverified.json"
            marker = (
                load_object(marker_path, 21, "control-flip")
                if marker_path.is_file()
                else {}
            )
            expected_controls = {
                str(row.get("controlId") or row.get("id"))
                for row in controls
                if row.get("controlId") or row.get("id")
            }
            passed_controls = {
                str(row.get("control"))
                for row in passes
                if row.get("control")
            }
            skipped_controls = {
                str(row.get("control"))
                for row in skips
                if row.get("control")
            }
            marker_controls = {
                str(row.get("control"))
                for row in marker.get("unprobed") or []
                if isinstance(row, dict) and row.get("control")
            }
            if not (
                marker.get("workbookId") == workbook_id
                and expected_controls == passed_controls | skipped_controls
                and skipped_controls == marker_controls
            ):
                fail(
                    21,
                    "control-flip",
                    "mixed PASS/SKIP control evidence lacks complete advisory coverage",
                )
        if failures or not passes or wrong_workbooks:
            fail(
                21,
                "control-flip",
                f"runtime flip evidence has {len(passes)} PASS and "
                f"{len(failures)} FAIL row(s)",
            )
        return
    fail(
        21,
        "control-flip",
        "controls exist but no current probe results or named waiver are present",
    )


def valid_png(path: Path) -> bool:
    try:
        data = path.read_bytes()
    except OSError:
        return False
    return len(data) > 64 and data.startswith(b"\x89PNG\r\n\x1a\n")


def gate_render(
    workdir: Path,
    sigma_render: Path | None,
    workbook_id: str,
    document_version: str,
    run_id: str,
) -> dict[str, Any]:
    render = load_object(workdir / "render-health.json", 10, "render")
    pages = render.get("sigma_pages")
    expected = integer(render.get("expected_sigma_pages"))
    if (
        render.get("status") != "PASS"
        or expected <= 0
        or not isinstance(pages, list)
        or len(pages) < expected
        or any(not isinstance(row, dict) or row.get("status") != "PASS" for row in pages)
    ):
        fail(10, "render", "render-health.json does not prove every Sigma page is healthy")
    paths = []
    for row in pages:
        path = Path(str(row.get("path") or "")).expanduser()
        if not path.is_absolute():
            path = workdir / path
        paths.append(path.resolve())
    if sigma_render:
        requested = sigma_render.expanduser().resolve()
        if not valid_png(requested):
            fail(10, "render", f"--sigma-render is missing or invalid: {requested}")
        if paths and requested not in paths:
            fail(10, "render", "--sigma-render is not one of the health-checked page renders")
    if any(not valid_png(path) for path in paths):
        fail(10, "render", "a health-checked Sigma render is now missing or invalid")
    evidence = load_object(workdir / "render-evidence.json", 10, "render")
    image_rows = evidence.get("images")
    if (
        evidence.get("workbookId") != workbook_id
        or str(evidence.get("documentVersion") or "") != document_version
        or evidence.get("run_id") != run_id
        or not isinstance(image_rows, list)
        or len(image_rows) != expected
    ):
        fail(10, "render", "render evidence is stale or belongs to another run/version")
    evidence_paths = set()
    for row in image_rows:
        path = Path(str(row.get("path") or "")).expanduser().resolve()
        evidence_paths.add(path)
        if (
            not path.is_file()
            or hashlib.sha256(path.read_bytes()).hexdigest()
            != str(row.get("sha256") or "").lower()
        ):
            fail(10, "render", f"render evidence hash is stale: {path}")
    if evidence_paths != set(paths):
        fail(10, "render", "render evidence does not cover exactly the health-checked pages")
    blank = load_object(workdir / "blank-risk.json", 10, "render")
    if (
        blank.get("status") != "PASS"
        or integer(blank.get("blank_count")) != 0
        or (blank.get("failures") or [])
    ):
        fail(10, "render", "blank-risk.json reports a blank or indeterminate render")
    return render


def gate_visual_comparison(
    workdir: Path,
    parity: dict[str, Any],
    waiver_reason: str | None,
) -> None:
    if waiver_reason:
        return
    checklist = parity.get("style_checklist")
    required = {
        "element_titles_hidden",
        "palette_match",
        "composition_match",
        "chart_shapes_match",
        "labels_legible",
        "numbers_formatted",
    }
    if (
        parity.get("visual_checked") is not True
        or parity.get("visual_verdict") != "pass"
        or parity.get("agent_vision") is False
        or not isinstance(checklist, dict)
        or set(checklist) != required
        or any(value not in {"pass", "na"} for value in checklist.values())
    ):
        fail(
            19,
            "visual-comparison",
            "source-vs-target visual review is missing, incomplete, or not passing",
        )
    blind = parity.get("blind_grade")
    blind_waiver = parity.get("blind_grade_waiver")
    if isinstance(blind, dict):
        grade_path = Path(str(blind.get("path") or "")).expanduser()
        if not grade_path.is_absolute():
            grade_path = workdir / grade_path
        try:
            verified = blind_grade.validate(grade_path, workdir)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            fail(19, "visual-comparison", str(exc))
        if (
            verified.get("source_sha256") != blind.get("source_sha256")
            or verified.get("target_sha256") != blind.get("target_sha256")
        ):
            fail(19, "visual-comparison", "blind grade metadata drifted after recording")
    elif not (
        isinstance(blind_waiver, dict)
        and str(blind_waiver.get("reason") or "").strip()
    ):
        fail(
            19,
            "visual-comparison",
            "passing visual review lacks a blind grade or named independent-grade waiver",
        )


def gate_similarity(
    workdir: Path,
    visual_waiver: str | None,
    similarity_waiver: str | None,
) -> None:
    document = load_object(
        workdir / "visual-similarity.json", 20, "visual-similarity"
    )
    if document.get("status") == "PASS":
        pages = document.get("pages")
        if (
            document.get("pass") is not True
            or integer(document.get("pages_total")) <= 0
            or integer(document.get("pages_compared"))
            != integer(document.get("pages_total"))
            or not isinstance(pages, list)
            or any(not isinstance(row, dict) or row.get("pass") is not True for row in pages)
        ):
            fail(20, "visual-similarity", "visual similarity does not cover every page")
        return
    waiver = similarity_waiver or visual_waiver
    if (
        document.get("status") == "WAIVED"
        and document.get("pass") is True
        and str(document.get("reason") or "").strip()
        and waiver
    ):
        return
    fail(20, "visual-similarity", "visual similarity is neither passing nor explicitly waived")


def gate_anchors(workdir: Path, render: dict[str, Any], waiver_reason: str | None) -> None:
    if waiver_reason:
        return
    sources = render.get("sources")
    if not isinstance(sources, list) or not sources:
        fail(18, "anchors", "source anchor proof is absent and no named waiver was supplied")
    anchors = load_object(workdir / "source-anchors.json", 18, "anchors")
    rows = anchors.get("anchors")
    if not isinstance(rows, list) or len(rows) < 5:
        fail(18, "anchors", "source-anchors.json must contain at least five anchors")
    verdict = load_object(workdir / "anchors-verdict.json", 18, "anchors")
    if (
        verdict.get("pass") is not True
        or integer(verdict.get("checked")) != len(rows)
        or integer(verdict.get("matched")) != len(rows)
        or (verdict.get("missing") or [])
        or verdict.get("tiles_all_nonempty") is not True
    ):
        fail(18, "anchors", "source anchor matching is stale or incomplete")


def gate_security(workdir: Path) -> dict[str, str] | None:
    app_meta_path = workdir / "app-meta.json"
    app_meta = (
        load_object(app_meta_path, 32, "security")
        if app_meta_path.is_file()
        else {}
    )
    try:
        load_script = (workdir / "script.qvs").read_text(
            encoding="utf-8-sig"
        )
    except OSError:
        load_script = ""
    security_path = workdir / "security.json"
    security = load_json(security_path, 32, "security") if security_path.is_file() else []
    security_rows = (
        security.get("security") or []
        if isinstance(security, dict)
        else security
    )
    section_access = (
        app_meta.get("hasSectionAccess") is True
        or re.search(r"(?im)^\s*SECTION\s+ACCESS\s*;", load_script) is not None
        or bool(security_rows)
    )
    if not section_access:
        return None
    decision = load_object(workdir / "security-decision.json", 32, "security")
    dm_ids = load_object(workdir / "dm-ids.json", 32, "security")
    run_state = load_object(workdir / "run-state.json", 32, "security")
    readback_path = workdir / "datamodel-readback.json"
    if not readback_path.is_file():
        fail(32, "security", "data-model readback is missing")
    expected_hash = hashlib.sha256(readback_path.read_bytes()).hexdigest()
    if (
        str(decision.get("dataModelId") or "")
        != str(dm_ids.get("dataModelId") or "")
        or str(decision.get("run_id") or "")
        != str(run_state.get("run_id") or "")
        or str(decision.get("readback_sha256") or "").lower() != expected_hash
    ):
        fail(
            32,
            "security",
            "security decision is stale or belongs to a different run/data model",
        )
    choice = str(decision.get("decision") or "")
    if choice == "skip":
        reason = str(decision.get("reason") or "").strip()
        if not reason or decision.get("acknowledges_all_rows_visible") is not True:
            fail(
                32,
                "security",
                "Section Access skip requires a reason and explicit all-rows-visible acknowledgement",
            )
        return {
            "flag": "--skip-source-security",
            "gate": "security",
            "reason": reason,
        }
    if choice not in {"port", "customize"}:
        fail(
            32,
            "security",
            "Section Access requires decision=port|customize|skip before completion",
        )
    if (
        decision.get("status") != "applied"
        or decision.get("readback_verified") is not True
    ):
        fail(
            32,
            "security",
            f"Section Access decision {choice!r} is not applied and readback-verified",
        )
    if not isinstance(security_rows, list) or not security_rows:
        fail(
            32,
            "security",
            "Section Access was detected but no concrete RLS/CLS rules were supplied",
        )
    dm_result = load_object(workdir / "dm-result.json", 32, "security")
    denorm_id = str(dm_result.get("denormElementId") or "")
    secured_id = str(decision.get("securedElementId") or "")
    if not denorm_id or secured_id != denorm_id:
        fail(
            32,
            "security",
            "security evidence is not bound to the denormalized workbook source element",
        )
    readback = load_object(readback_path, 32, "security")
    secured = next(
        (
            element
            for element in all_elements(readback)
            if str(element.get("id") or element.get("elementId") or "")
            == secured_id
        ),
        None,
    )
    if not isinstance(secured, dict):
        fail(32, "security", "secured denormalized element is absent from readback")
    expected_rules = [
        row
        for row in security_rows
        if isinstance(row, dict) and (row.get("rls") or row.get("cls"))
    ]
    if len(expected_rules) != len(security_rows):
        fail(
            32,
            "security",
            "security.json contains unsupported or malformed rule rows",
        )
    if (
        integer(decision.get("rules_detected")) != len(security_rows)
        or integer(decision.get("rules_applied")) != len(expected_rules)
    ):
        fail(
            32,
            "security",
            "security decision rule counts do not cover every supplied rule",
        )
    columns = [
        row for row in secured.get("columns") or [] if isinstance(row, dict)
    ]
    filters = [
        row for row in secured.get("filters") or [] if isinstance(row, dict)
    ]
    securities = [
        row
        for row in secured.get("columnSecurities") or []
        if isinstance(row, dict)
    ]
    for row in expected_rules:
        if row.get("kind") == "rls" and isinstance(row.get("rls"), dict):
            formula = str(row["rls"].get("formula") or "")
            column = next(
                (candidate for candidate in columns if candidate.get("formula") == formula),
                None,
            )
            if not column or not any(
                candidate.get("columnId") == column.get("id")
                and candidate.get("values") == [True]
                and candidate.get("kind") == "list"
                and candidate.get("mode") == "include"
                for candidate in filters
            ):
                fail(
                    32,
                    "security",
                    "a supplied RLS formula/filter is absent from persisted readback",
                )
        elif row.get("kind") == "cls" and isinstance(row.get("cls"), dict):
            if row["cls"].get("verifiedEquivalent") is not True:
                fail(
                    32,
                    "security",
                    "Qlik OMIT requires customized CLS with verifiedEquivalent:true",
                )
            expected_names = {
                re.sub(r"[^a-z0-9]", "", str(name).casefold())
                for name in row["cls"].get("restrictedColumnNames") or []
            }
            column_ids = {
                str(column.get("id"))
                for column in columns
                if re.sub(
                    r"[^a-z0-9]",
                    "",
                    str(column.get("name") or "").casefold(),
                )
                in expected_names
            }
            expected_criteria = row["cls"].get("criteria") or {
                "kind": "no-one-can-view"
            }
            if (
                not expected_names
                or len(column_ids) != len(expected_names)
                or not any(
                column_ids.issubset(
                    {str(value) for value in security.get("restrictedColumns") or []}
                )
                and security.get("criteria") == expected_criteria
                for security in securities
                )
            ):
                fail(
                    32,
                    "security",
                    "a supplied CLS restriction is absent from persisted readback",
                )
    required_principals = set()
    for row in expected_rules:
        rls = row.get("rls")
        if not isinstance(rls, dict):
            continue
        formula = str(rls.get("formula") or "")
        if re.search(r"CurrentUserInTeam\s*\(\s*\[", formula):
            fail(
                32,
                "security",
                "dynamic CurrentUserInTeam([field]) must be customized to explicit teams",
            )
        required_principals.update(
            str(value)
            for value in (
                (rls.get("userAttributes") or [])
                + (rls.get("teams") or [])
            )
            if str(value)
        )
        required_principals.update(
            re.findall(
                r'CurrentUserInTeam\s*\(\s*["\']([^"\']+)["\']\s*\)',
                formula,
            )
        )
        required_principals.update(
            re.findall(
                r'CurrentUserAttribute\w*\s*\(\s*["\']([^"\']+)["\']\s*\)',
                formula,
            )
        )
    if required_principals:
        membership_evidence = decision.get("membership_evidence")
        if (
            decision.get("membership_verified") is not True
            or not isinstance(membership_evidence, list)
            or not membership_evidence
        ):
            fail(
                32,
                "security",
                "security principals require membership/attribute assignment evidence",
            )
        assigned_principals = set()
        for evidence in membership_evidence:
            path = Path(str((evidence or {}).get("path") or "")).expanduser()
            if not path.is_absolute():
                path = workdir / path
            if (
                not path.is_file()
                or hashlib.sha256(path.read_bytes()).hexdigest()
                != str((evidence or {}).get("sha256") or "").lower()
            ):
                fail(32, "security", f"membership evidence is missing or stale: {path}")
            document = load_object(path, 32, "security")
            if (
                document.get("dataModelId") != dm_ids.get("dataModelId")
                or document.get("run_id") != run_state.get("run_id")
                or not isinstance(document.get("assignments"), list)
            ):
                fail(32, "security", "membership evidence belongs to another run/model")
            assigned_principals.update(
                str(assignment.get("principal") or assignment.get("name") or "")
                for assignment in document["assignments"]
                if isinstance(assignment, dict)
                and assignment.get("readback_verified") is True
                and (assignment.get("members") or assignment.get("values"))
            )
        if not required_principals.issubset(assigned_principals):
            fail(
                32,
                "security",
                "membership evidence does not cover every required team/user attribute",
            )
    effective = load_object(
        workdir / "security-effective-user-verdict.json",
        32,
        "security",
    )
    if (
        effective.get("status") != "PASS"
        or effective.get("dataModelId") != dm_ids.get("dataModelId")
        or effective.get("run_id") != run_state.get("run_id")
        or effective.get("readback_sha256") != expected_hash
    ):
        fail(
            32,
            "security",
            "effective-user security verdict is missing, stale, or not PASS",
        )
    effective_documents = {}
    effective_paths = {}
    for key in ("source_policy", "source_roster", "sigma_roster"):
        evidence = effective.get(key)
        path = Path(str((evidence or {}).get("path") or "")).expanduser()
        if not path.is_absolute():
            path = workdir / path
        if (
            not path.is_file()
            or hashlib.sha256(path.read_bytes()).hexdigest()
            != str((evidence or {}).get("sha256") or "").lower()
        ):
            fail(32, "security", f"{key} evidence is missing or stale: {path}")
        effective_documents[key] = load_object(path, 32, "security")
        effective_paths[key] = path
    source_policy = effective_documents["source_policy"]
    if source_policy.get("security") != security_rows:
        fail(
            32,
            "security",
            "source policy evidence does not exactly match security.json",
        )
    policy_sha256 = hashlib.sha256(
        effective_paths["source_policy"].read_bytes()
    ).hexdigest()
    expected_rule_ids = {
        hashlib.sha256(
            json.dumps(
                row,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        for row in expected_rules
    }

    def assignment_map(
        document: dict[str, Any], label: str
    ) -> dict[str, Any]:
        result = {}
        for assignment in document.get("assignments") or []:
            if not isinstance(assignment, dict):
                continue
            principal = str(
                assignment.get("principal") or assignment.get("name") or ""
            )
            if principal:
                if principal in result:
                    fail(
                        32,
                        "security",
                        f"{label} roster contains duplicate principal {principal!r}",
                    )
                result[principal] = (
                    assignment.get("members")
                    if assignment.get("members") is not None
                    else assignment.get("values")
                )
        return result

    source_assignments = assignment_map(
        effective_documents["source_roster"], "source"
    )
    sigma_assignments = assignment_map(
        effective_documents["sigma_roster"], "Sigma"
    )
    if source_assignments != sigma_assignments:
        fail(32, "security", "source and Sigma membership rosters do not reconcile")
    if required_principals and (
        not source_assignments
        or not required_principals.issubset(set(source_assignments))
    ):
        fail(
            32,
            "security",
            "reconciled rosters do not cover every required security principal",
        )
    source_subjects = {
        str(value)
        for value in effective_documents["source_roster"].get("subjects") or []
    }
    sigma_subjects = {
        str(value)
        for value in effective_documents["sigma_roster"].get("subjects") or []
    }
    if not source_subjects or source_subjects != sigma_subjects:
        fail(32, "security", "source and Sigma effective-user subjects do not reconcile")
    tests = effective.get("tests")
    if (
        not isinstance(tests, list)
        or not tests
        or any(
            not isinstance(test, dict)
            or test.get("status") != "PASS"
            or test.get("match") is not True
            or not str(test.get("principal") or "").strip()
            for test in tests
        )
        or not {"allow", "deny"}.issubset(
            {str(test.get("kind") or "") for test in tests}
        )
    ):
        fail(
            32,
            "security",
            "effective-user verdict requires passing allow and deny tests",
        )
    covered_rule_ids = set()
    for test in tests:
        principal = str(test.get("principal") or "")
        if principal not in source_subjects:
            fail(
                32,
                "security",
                f"effective-user test principal is absent from reconciled rosters: {principal}",
            )
        query = str(test.get("query") or "").strip()
        test_rule_ids = {
            str(value) for value in test.get("rule_ids") or []
        }
        if (
            not query
            or not test_rule_ids
            or not test_rule_ids.issubset(expected_rule_ids)
        ):
            fail(
                32,
                "security",
                "effective-user test is not bound to known policy rule ids/query",
            )
        covered_rule_ids.update(test_rule_ids)
        result_documents = {}
        result_paths = {}
        for key in ("source_result", "sigma_result"):
            evidence = test.get(key)
            path = Path(str((evidence or {}).get("path") or "")).expanduser()
            if not path.is_absolute():
                path = workdir / path
            if (
                not path.is_file()
                or hashlib.sha256(path.read_bytes()).hexdigest()
                != str((evidence or {}).get("sha256") or "").lower()
            ):
                fail(
                    32,
                    "security",
                    f"effective-user {key} evidence is missing or stale: {path}",
                )
            result_documents[key] = load_json(path, 32, "security")
            result_paths[key] = path
        if result_paths["source_result"] == result_paths["sigma_result"]:
            fail(32, "security", "source and Sigma query evidence must be distinct")
        source_result = result_documents["source_result"]
        sigma_result = result_documents["sigma_result"]
        for label, result, system in (
            ("source", source_result, "qlik"),
            ("Sigma", sigma_result, "sigma"),
        ):
            if (
                not isinstance(result, dict)
                or result.get("system") != system
                or result.get("principal") != principal
                or result.get("query") != query
                or result.get("policy_sha256") != policy_sha256
                or {str(value) for value in result.get("rule_ids") or []}
                != test_rule_ids
                or not str(result.get("captured_at") or "").strip()
                or not str(result.get("transport") or "").strip()
                or not isinstance(result.get("rows"), list)
            ):
                fail(
                    32,
                    "security",
                    f"{label} result is not provenance/policy/query bound",
                )
        if source_result["rows"] != sigma_result["rows"]:
            fail(
                32,
                "security",
                f"effective-user {test.get('kind')} source/Sigma results differ",
            )
        if test.get("kind") == "allow" and not source_result["rows"]:
            fail(32, "security", "allow test must prove at least one visible result")
        if test.get("kind") == "deny" and source_result["rows"]:
            fail(32, "security", "deny test must prove zero visible restricted rows")
    if covered_rule_ids != expected_rule_ids:
        fail(
            32,
            "security",
            "effective-user tests do not cover every source security rule",
        )
    return None


def ledger_ids(path: Path) -> list[str]:
    ids = []
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except OSError as exc:
        fail(4, "cleanup", f"posted-workbooks.jsonl is unreadable: {exc}")
    for index, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            fail(4, "cleanup", f"posted-workbooks.jsonl line {index} is malformed")
        if not isinstance(row, dict) or not str(row.get("id") or "").strip():
            fail(4, "cleanup", f"posted-workbooks.jsonl line {index} has no workbook id")
        if str(row["id"]) not in ids:
            ids.append(str(row["id"]))
    return ids


def gate_cleanup(workdir: Path, workbook_id: str) -> None:
    ledger = workdir / "posted-workbooks.jsonl"
    marker_path = workdir / "cleanup-marker.json"
    ids = ledger_ids(ledger) if ledger.is_file() else []
    marker = load_object(marker_path, 4, "cleanup") if marker_path.is_file() else None
    if ids and workbook_id not in ids:
        fail(4, "cleanup", "requested workbook is absent from posted-workbooks.jsonl")
    if len(ids) > 1 and marker is None:
        fail(4, "cleanup", "multiple posted workbooks exist without cleanup-marker.json")
    if marker is not None:
        if marker.get("kept") not in (None, "", workbook_id):
            fail(4, "cleanup", "cleanup marker kept a different workbook")
        if marker.get("dry_run") is True:
            fail(4, "cleanup", "cleanup marker is from a dry run")
        if marker.get("failed") or marker.get("skipped"):
            fail(4, "cleanup", "orphan cleanup records failed or skipped workbooks")
        deleted = {
            str(row.get("id") if isinstance(row, dict) else row)
            for row in marker.get("deleted") or []
        }
        if len(ids) > 1 and set(ids) - {workbook_id} - deleted:
            fail(4, "cleanup", "cleanup marker does not account for every orphan workbook")


def gate_accounting_and_report(workdir: Path) -> None:
    census = load_object(
        workdir / "source-object-census.json", 33, "accounting/report"
    )
    report = load_object(workdir / "migration-result.json", 33, "accounting/report")
    census_rows = source_rows(census)
    report_rows = source_rows(report)
    summary = census.get("summary") or {}
    if (
        summary.get("complete") is not True
        or integer(summary.get("total")) != len(census_rows)
        or integer(summary.get("accounted")) != len(census_rows)
        or not census_rows
        or any(
            row_status(row) not in TERMINAL
            or row.get("source_provenance") not in PROVENANCE
            or not isinstance(row.get("evidence"), list)
            or not row["evidence"]
            for row in census_rows
        )
    ):
        fail(33, "accounting/report", "source census is empty, incomplete, or lacks evidence")
    report_summary = report.get("summary") or {}
    checks = report.get("checks")
    if (
        str(report.get("verdict") or "").upper() == "RED"
        or report_summary.get("complete") is not True
        or integer(report_summary.get("total")) != len(report_rows)
        or integer(report_summary.get("accounted")) != len(report_rows)
        or not isinstance(checks, list)
        or not checks
        or any(not isinstance(row, dict) or row.get("status") != "PASS" for row in checks)
    ):
        fail(33, "accounting/report", "migration report is RED, incomplete, or has failed checks")
    if sorted(map(identity, census_rows)) != sorted(map(identity, report_rows)):
        fail(33, "accounting/report", "migration report does not exactly match source census")
    command = [
        sys.executable,
        str(HERE / "build-migration-report.py"),
        "--workdir",
        str(workdir),
        "--inventory",
        str(workdir / "source-object-census.json"),
        "--check",
    ]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        fail(33, "accounting/report", f"deterministic report check failed: {detail}")


def waiver_rows(args: argparse.Namespace) -> list[dict[str, str]]:
    values = (
        ("--skip-layout-lint", "layout-lint", args.skip_layout_lint),
        ("--skip-control-flip", "control-flip", args.skip_control_flip),
        ("--skip-visual-comparison", "visual-comparison", args.skip_visual_comparison),
        ("--skip-visual-similarity", "visual-similarity", args.skip_visual_similarity),
        ("--skip-anchors-gate", "source-anchors", args.skip_anchors_gate),
    )
    result = []
    for flag, gate, value in values:
        if value is None:
            continue
        reason = str(value).strip()
        if not reason:
            fail(34, "waivers", f"{flag} requires a non-empty reason")
        result.append({"flag": flag, "gate": gate, "reason": reason})
    return result


def append_evidence(
    workdir: Path,
    gate: str,
    verdict: str,
    workbook_id: str,
    evidence_path: str | None = None,
    detail: dict[str, Any] | None = None,
) -> None:
    record: dict[str, Any] = {
        "gate": gate,
        "verdict": verdict,
        "evidence_key": f"wb:{workbook_id}@v?",
        "at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
            "+00:00", "Z"
        ),
    }
    if evidence_path:
        record["evidence_path"] = evidence_path
        path = workdir / evidence_path
        if path.is_file():
            record["evidence_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    if detail:
        record["detail"] = detail
    try:
        with (workdir / "evidence-ledger.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
        pass


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--workbook-id", required=True)
    parser.add_argument("--control-scope")
    parser.add_argument("--require-control-flip", action="store_true")
    parser.add_argument("--sigma-render")
    parser.add_argument("--skip-layout-lint", nargs="?", const="")
    parser.add_argument("--skip-control-flip", nargs="?", const="")
    parser.add_argument("--skip-visual-comparison")
    parser.add_argument("--skip-visual-similarity")
    parser.add_argument("--skip-anchors-gate")
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> dict[str, Any]:
    workdir = Path(args.workdir).expanduser().resolve()
    if not workdir.is_dir():
        fail(35, "invocation", f"--workdir is not a directory: {workdir}")
    workbook_id = str(args.workbook_id or "").strip()
    if not workbook_id:
        fail(35, "invocation", "--workbook-id is empty")
    run_state = load_object(workdir / "run-state.json", 35, "invocation")
    run_id = str(run_state.get("run_id") or "").strip()
    if not run_id:
        fail(35, "invocation", "run-state.json has no current run_id")
    ids_path = workdir / "wb-ids.json"
    if ids_path.is_file():
        ids = load_object(ids_path, 4, "workbook")
        if ids.get("workbookId") not in (None, "", workbook_id):
            fail(4, "workbook", "wb-ids.json belongs to a different workbook")
    waivers = waiver_rows(args)
    parity, chart_count = gate_parity(workdir)
    parity_reasons = parity.get("waiver_reasons") or {}
    mode_waivers: list[dict[str, str]] = []
    declared_parity_waivers = set(parity.get("waivers") or [])
    warehouse_rows = any(
        str(row.get("status") or "").upper() == "WAREHOUSE-PASS"
        for row in parity.get("per_chart") or []
        if isinstance(row, dict)
    )
    if warehouse_rows and (
        parity.get("mode") != "warehouse"
        or parity.get("verified_against") != "warehouse"
    ):
        fail(
            19,
            "waiver-budget",
            "WAREHOUSE-PASS evidence requires mode=warehouse and "
            "verified_against=warehouse",
        )
    if parity.get("mode") == "warehouse" and not warehouse_rows:
        fail(19, "waiver-budget", "warehouse mode has no WAREHOUSE-PASS evidence")
    if (
        parity.get("mode") == "warehouse"
        and "--source-parity-unavailable" not in declared_parity_waivers
    ):
        fail(
            19,
            "waiver-budget",
            "warehouse-only parity requires the named "
            "--source-parity-unavailable disposition",
        )
    for flag in parity.get("waivers") or []:
        if flag != "--source-parity-unavailable":
            continue
        reason = str(parity_reasons.get(flag) or "").strip()
        if not reason:
            fail(19, "waiver-budget", f"{flag} requires a non-empty reason")
        mode_waivers.append(
            {
                "flag": flag,
                "gate": "source-parity",
                "reason": reason,
            }
        )
    blind_waiver = parity.get("blind_grade_waiver")
    if isinstance(blind_waiver, dict) and str(
        blind_waiver.get("reason") or ""
    ).strip():
        waivers.append(
            {
                "flag": "--no-vision-grader",
                "gate": "visual-comparison",
                "reason": str(blind_waiver["reason"]).strip(),
            }
        )
    security_waiver = gate_security(workdir)
    if security_waiver:
        waivers.append(security_waiver)
    if len(mode_waivers) + len(waivers) > 2:
        fail(
            19,
            "waiver-budget",
            f"{len(mode_waivers) + len(waivers)} quality waivers exceed the maximum of 2",
        )
    gate_coverage(workdir, parity)
    document, _spec_path, document_version = workbook_spec(workdir, workbook_id)
    gate_layout(workdir, document, args.skip_layout_lint)
    scope_path = (
        Path(args.control_scope).expanduser().resolve()
        if args.control_scope
        else workdir / "control-scope.json"
    )
    controls, _scope = gate_controls(workdir, document, scope_path)
    gate_flip(
        workdir,
        workbook_id,
        document_version,
        controls,
        True,
        args.skip_control_flip,
    )
    render = gate_render(
        workdir,
        Path(args.sigma_render) if args.sigma_render else None,
        workbook_id,
        document_version,
        run_id,
    )
    gate_visual_comparison(
        workdir,
        parity,
        args.skip_visual_comparison,
    )
    gate_similarity(
        workdir,
        args.skip_visual_comparison,
        args.skip_visual_similarity,
    )
    gate_anchors(
        workdir,
        render,
        args.skip_anchors_gate or args.skip_visual_comparison,
    )
    gate_cleanup(workdir, workbook_id)
    gate_accounting_and_report(workdir)

    all_waivers = mode_waivers + waivers
    waiver_flags = [row["flag"] for row in all_waivers]
    waiver_reasons = {row["flag"]: row["reason"] for row in all_waivers}
    write_json(
        workdir / "waivers.json",
        {"version": 1, "count": len(all_waivers), "waivers": all_waivers},
    )
    parity["waivers"] = waiver_flags
    parity["waiver_count"] = len(waiver_flags)
    parity["waiver_reasons"] = waiver_reasons
    parity["success_sentinel"] = True
    write_json(workdir / "parity-final.json", parity)
    entries = degradation_ledger.derive(workdir)
    if not degradation_ledger.write(workdir, entries):
        fail(36, "ledger", "could not write degradation-ledger.json")
    ledger_verdict = degradation_ledger.verdict(entries)
    report_command = [
        sys.executable,
        str(HERE / "build-migration-report.py"),
        "--workdir",
        str(workdir),
        "--inventory",
        str(workdir / "source-object-census.json"),
    ]
    report_result = subprocess.run(
        report_command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if report_result.returncode != 0:
        fail(
            33,
            "accounting/report",
            "terminal report refresh failed: "
            + (report_result.stderr or report_result.stdout).strip(),
        )
    gate_accounting_and_report(workdir)
    marker = {
        "workbookId": workbook_id,
        "chartCount": chart_count,
        "gates": "all-pass",
        "waivers": waiver_flags,
        "generatedAt": datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "verdict": ledger_verdict,
        "verdict_by": "python-phase6-gate",
        "run_id": run_id,
        "documentVersion": document_version,
    }
    write_json(workdir / "phase6-success.json", marker)
    append_evidence(
        workdir,
        "phase6-gates",
        ledger_verdict,
        workbook_id,
        "parity-final.json",
        {"waivers": len(all_waivers), "degradations": len(entries)},
    )
    return marker


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    workdir = Path(args.workdir).expanduser().resolve()
    marker_path = workdir / "phase6-success.json"
    try:
        marker = run(args)
    except GateFailure as exc:
        try:
            marker_path.unlink()
        except FileNotFoundError:
            pass
        append_evidence(
            workdir,
            exc.gate,
            "fail",
            str(args.workbook_id or "?"),
            detail={"exit": exc.code, "reason": exc.detail},
        )
        print(f"NOT DONE [{exc.gate}]: {exc.detail}", file=sys.stderr)
        return exc.code
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as exc:
        try:
            marker_path.unlink()
        except FileNotFoundError:
            pass
        print(f"NOT DONE [filesystem]: {exc}", file=sys.stderr)
        return 70
    print(
        f"DONE: Qlik Phase 6 all-pass; workbook={marker['workbookId']} "
        f"charts={marker['chartCount']} verdict={marker['verdict']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
