#!/usr/bin/env python3
"""Offline terminal verifier for the Python-only Qlik completion contract.

Exit codes intentionally preserve the existing Qlik verifier contract:
  2 missing marker
  3 invalid/empty marker
  4 workbook mismatch
  5 non-strict parity
  6 incomplete census/report
  7 census/report drift
  8 PNG, finalization, or report freshness failure
  9 degradation-ledger/report contradiction
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import degradation_ledger  # noqa: E402

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


def load_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8-sig") as handle:
            return json.load(handle)
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def integer(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def rows(document: Any) -> list[dict[str, Any]]:
    if isinstance(document, list):
        return [row for row in document if isinstance(row, dict)]
    if not isinstance(document, dict):
        return []
    for key in ("source_objects", "objects", "sourceObjects", "inventory", "items"):
        if isinstance(document.get(key), list):
            return [row for row in document[key] if isinstance(row, dict)]
    return []


def status(row: dict[str, Any]) -> str:
    value = (
        row.get("status")
        or row.get("terminal_status")
        or row.get("migration_status")
        or row.get("outcome")
        or ""
    )
    return "-".join(str(value).strip().casefold().replace("_", " ").split())


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
    return kind, object_id or f"name:{name}", status(row)


def stop(code: int, message: str, details: list[str] | None = None) -> int:
    print(f"NOT DONE: {message}", file=sys.stderr)
    for detail in details or []:
        print(f"  {detail}", file=sys.stderr)
    return code


def path_from(value: Any, workdir: Path) -> Path | None:
    if not isinstance(value, str) or not value.strip():
        return None
    path = Path(value).expanduser()
    return (path if path.is_absolute() else workdir / path).resolve()


def valid_png(path: Path | None) -> bool:
    if not path or not path.is_file():
        return False
    try:
        data = path.read_bytes()
    except OSError:
        return False
    return len(data) > 64 and data.startswith(b"\x89PNG\r\n\x1a\n")


def report_check(workdir: Path, census_path: Path) -> bool:
    result = subprocess.run(
        [
            sys.executable,
            str(HERE / "build-migration-report.py"),
            "--workdir",
            str(workdir),
            "--inventory",
            str(census_path),
            "--check",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--workbook-id")
    args = parser.parse_args(argv)
    workdir = Path(args.workdir).expanduser().resolve()

    marker_path = workdir / "phase6-success.json"
    marker = load_json(marker_path)
    if not isinstance(marker, dict):
        return stop(2, "Python Phase 6 gate did not stamp success.")
    if integer(marker.get("chartCount")) <= 0 or marker.get("gates") != "all-pass":
        return stop(
            3,
            "success marker does not prove a non-empty all-gates run.",
            [
                f"chartCount={marker.get('chartCount')!r}",
                f"gates={marker.get('gates')!r}",
            ],
        )
    if args.workbook_id and marker.get("workbookId") != args.workbook_id:
        return stop(
            4,
            "success marker belongs to a different workbook.",
            [
                f"marker={marker.get('workbookId')}",
                f"requested={args.workbook_id}",
            ],
        )
    run_state = load_json(workdir / "run-state.json")
    if (
        not isinstance(run_state, dict)
        or not str(run_state.get("run_id") or "").strip()
        or marker.get("run_id") != run_state.get("run_id")
        or marker.get("verdict_by") != "python-phase6-gate"
    ):
        return stop(3, "success marker is stale or not bound to the current Python run.")
    readback = load_json(workdir / "wb-readback.json")
    readback_version = (
        readback.get("latestDocumentVersion") or readback.get("latestVersion")
        if isinstance(readback, dict)
        else None
    )
    if (
        not isinstance(readback, dict)
        or readback.get("workbookId") != marker.get("workbookId")
        or str(readback_version or "") != str(marker.get("documentVersion") or "")
    ):
        return stop(4, "success marker is not bound to the live workbook readback version.")

    parity_path = workdir / "parity-final.json"
    parity = load_json(parity_path)
    if not isinstance(parity, dict):
        return stop(5, "parity-final.json is missing or malformed.")
    total = integer(parity.get("charts_total"))
    passed = integer(parity.get("charts_pass"))
    failed = (
        integer(parity.get("charts_fail"))
        if "charts_fail" in parity
        else total - passed
    )
    per_chart = parity.get("per_chart")
    strict_rows = isinstance(per_chart, list) and bool(per_chart) and all(
        isinstance(row, dict)
        and row.get("pass") is True
        and str(row.get("status") or "").upper() in PASS_STATES
        for row in per_chart
    )
    strict = (
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
    if not strict:
        return stop(
            5,
            "parity is not strict, complete, and non-divergent.",
            [
                f"status={parity.get('status')!r} strict={parity.get('strict')!r}",
                f"charts={passed}/{total}, failed={failed}, "
                f"stale={integer(parity.get('charts_stale_explained'))}",
            ],
        )
    warehouse_rows = any(
        isinstance(row, dict)
        and str(row.get("status") or "").upper() == "WAREHOUSE-PASS"
        for row in per_chart
    )
    if warehouse_rows and (
        parity.get("mode") != "warehouse"
        or parity.get("verified_against") != "warehouse"
        or "--source-parity-unavailable" not in (parity.get("waivers") or [])
    ):
        return stop(
            5,
            "warehouse-only parity lacks its mode, oracle, or named source-parity disposition.",
        )
    column_scan = load_json(workdir / "column-scan.json")
    if (
        not isinstance(column_scan, dict)
        or column_scan.get("status") != "complete-clean"
        or integer(column_scan.get("columns_read")) <= 0
        or (column_scan.get("errors") or [])
    ):
        return stop(5, "live workbook column scan is empty, incomplete, or contains errors.")

    census_path = workdir / "source-object-census.json"
    report_path = workdir / "migration-result.json"
    markdown_path = workdir / "MIGRATION_REPORT.md"
    census = load_json(census_path)
    report = load_json(report_path)
    if not isinstance(census, dict) or not isinstance(report, dict):
        return stop(6, "source census or migration report is missing/malformed.")
    census_rows = rows(census)
    report_rows = rows(report)
    census_summary = census.get("summary") or {}
    report_summary = report.get("summary") or {}
    census_complete = (
        census_summary.get("complete") is True
        and integer(census_summary.get("accounted"))
        == integer(census_summary.get("total"))
        == len(census_rows)
        and bool(census_rows)
        and all(
            status(row) in TERMINAL
            and row.get("source_provenance") in PROVENANCE
            and isinstance(row.get("evidence"), list)
            and bool(row["evidence"])
            for row in census_rows
        )
    )
    checks = report.get("checks")
    report_complete = (
        str(report.get("verdict") or "").upper() != "RED"
        and report_summary.get("complete") is True
        and integer(report_summary.get("accounted"))
        == integer(report_summary.get("total"))
        == len(report_rows)
        and isinstance(checks, list)
        and bool(checks)
        and all(isinstance(row, dict) and row.get("status") == "PASS" for row in checks)
    )
    if not census_complete or not report_complete:
        return stop(
            6,
            "source census/report is RED, incomplete, or has a failed check.",
            [
                f"census complete={census_summary.get('complete')!r} "
                f"{census_summary.get('accounted')}/{census_summary.get('total')}",
                f"report verdict={report.get('verdict')!r} "
                f"complete={report_summary.get('complete')!r}",
            ],
        )
    if sorted(map(identity, census_rows)) != sorted(map(identity, report_rows)):
        return stop(7, "migration report does not exactly match source census.")

    render_path = workdir / "render-health.json"
    blank_path = workdir / "blank-risk.json"
    similarity_path = workdir / "visual-similarity.json"
    finalization_path = workdir / "qlik-finalization.json"
    ledger_path = degradation_ledger.ledger_path(workdir)
    render = load_json(render_path)
    blank = load_json(blank_path)
    similarity = load_json(similarity_path)
    finalization = load_json(finalization_path)
    png_errors: list[str] = []
    if not isinstance(render, dict) or render.get("status") != "PASS":
        png_errors.append("render-health.json is missing or not PASS")
    else:
        expected = integer(render.get("expected_sigma_pages"))
        sigma_pages = render.get("sigma_pages")
        if expected <= 0:
            png_errors.append("no expected Sigma pages were checked")
        if not isinstance(sigma_pages, list) or len(sigma_pages) < expected:
            png_errors.append(
                f"Sigma page health covers "
                f"{len(sigma_pages) if isinstance(sigma_pages, list) else 0}/{expected}"
            )
        elif any(
            not isinstance(row, dict) or row.get("status") != "PASS"
            for row in sigma_pages
        ):
            png_errors.append("one or more Sigma page renders are unhealthy")
        elif any(
            not valid_png(path_from(row.get("path"), workdir))
            for row in sigma_pages
        ):
            png_errors.append("one or more health-checked Sigma page PNGs are missing or invalid")
        sources = render.get("sources")
        if not isinstance(sources, list):
            png_errors.append("render source health rows are malformed")
        elif not sources and not str(render.get("source_page_waiver") or "").strip():
            png_errors.append("source PNGs are absent without an explicit waiver")
        elif any(
            not isinstance(row, dict) or row.get("status") != "PASS"
            for row in sources
        ):
            png_errors.append("one or more Qlik source PNGs are unhealthy")
        elif any(
            not valid_png(path_from(row.get("path"), workdir))
            for row in sources
        ):
            png_errors.append("one or more health-checked Qlik source PNGs are missing or invalid")
        render_evidence = load_json(workdir / "render-evidence.json")
        evidence_images = (
            render_evidence.get("images")
            if isinstance(render_evidence, dict)
            else None
        )
        expected_paths = {
            path_from(row.get("path"), workdir)
            for row in sigma_pages or []
            if isinstance(row, dict)
        }
        evidence_paths = {
            path_from(row.get("path"), workdir)
            for row in evidence_images or []
            if isinstance(row, dict)
        }
        if (
            not isinstance(render_evidence, dict)
            or render_evidence.get("workbookId") != marker.get("workbookId")
            or str(render_evidence.get("documentVersion") or "")
            != str(readback_version or "")
            or render_evidence.get("run_id") != run_state.get("run_id")
            or expected_paths != evidence_paths
        ):
            png_errors.append("render evidence is stale or belongs to another run/version")
        elif any(
            not path
            or not path.is_file()
            or hashlib.sha256(path.read_bytes()).hexdigest()
            != str(row.get("sha256") or "").lower()
            for row in evidence_images
            for path in [path_from(row.get("path"), workdir)]
        ):
            png_errors.append("render evidence hash no longer matches a page PNG")
    if (
        not isinstance(blank, dict)
        or blank.get("status") != "PASS"
        or integer(blank.get("blank_count")) != 0
        or (blank.get("failures") or [])
    ):
        png_errors.append("blank-risk.json is missing/not PASS or records blanks")
    if not isinstance(similarity, dict) or similarity.get("status") not in {"PASS", "WAIVED"}:
        png_errors.append("visual-similarity.json is missing or failed")
    elif similarity.get("status") == "PASS":
        pages = similarity.get("pages")
        if (
            similarity.get("pass") is not True
            or integer(similarity.get("pages_total")) <= 0
            or integer(similarity.get("pages_compared"))
            != integer(similarity.get("pages_total"))
            or not isinstance(pages, list)
            or any(not isinstance(row, dict) or row.get("pass") is not True for row in pages)
        ):
            png_errors.append("visual similarity does not cover every page")
    elif not str(similarity.get("reason") or "").strip() or similarity.get("pass") is not True:
        png_errors.append("visual similarity waiver has no explicit reason")
    if not (
        isinstance(finalization, dict)
        and finalization.get("status") == "PASS"
        and integer(finalization.get("accounting_exit")) == 0
        and integer(finalization.get("ledger_exit")) == 0
        and integer(finalization.get("report_exit")) == 0
        and integer(finalization.get("report_check_exit")) == 0
        and finalization.get("render_health") == "PASS"
        and finalization.get("visual_similarity") == similarity.get("status")
        and str(finalization.get("report_verdict") or "").upper()
        == str(report.get("verdict") or "").upper()
        and str(finalization.get("report_verdict") or "").upper() != "RED"
        and not (finalization.get("failures") or [])
    ):
        png_errors.append(
            "qlik-finalization.json does not prove all accounting/PNG/report checks passed"
        )
    required_paths = (
        render_path,
        blank_path,
        similarity_path,
        finalization_path,
        ledger_path,
        report_path,
        markdown_path,
    )
    if any(not path.is_file() for path in required_paths):
        png_errors.append("one or more required completion artifacts are missing")
    if not report_check(workdir, census_path):
        png_errors.append("generated migration report is stale or contradictory")
    if png_errors:
        return stop(8, "PNG/finalization/report freshness contract failed.", png_errors)

    stored = load_json(ledger_path)
    derived = degradation_ledger.derive(workdir)
    contradictions = []
    if not (
        isinstance(stored, dict)
        and isinstance(stored.get("entries"), list)
        and isinstance(stored.get("counts"), dict)
        and str(stored.get("derivedAt") or "").strip()
    ):
        contradictions.append("degradation-ledger.json is missing or incomplete")
    else:
        if stored["entries"] != derived:
            contradictions.append("stored degradation entries differ from fresh derivation")
        actual_counts = dict(Counter(row["class"] for row in derived))
        stored_counts = {
            str(key): integer(value) for key, value in stored["counts"].items()
        }
        if stored_counts != actual_counts:
            contradictions.append("stored degradation counts differ from fresh derivation")
    if report.get("degradations") != derived:
        contradictions.append("migration report degradation list differs from fresh derivation")
    accounting_yellow = any(
        status(row) in {"approximated", "needs-review", "skipped"}
        for row in report_rows
    )
    expected_report_verdict = (
        "GREEN"
        if not derived and not accounting_yellow and not (report.get("waivers") or [])
        else "YELLOW"
    )
    if str(report.get("verdict") or "").upper() != expected_report_verdict:
        contradictions.append(
            f"report verdict {report.get('verdict')!r} != {expected_report_verdict}"
        )
    derived_verdict = degradation_ledger.verdict(derived)
    for name, document in (
        ("phase6-success.json", marker),
        ("parity-final.json", parity),
    ):
        claim = str(document.get("verdict") or "")
        if claim and claim != derived_verdict:
            contradictions.append(
                f"{name} verdict {claim!r} != {derived_verdict}"
            )
    if "waiver_count" in parity and integer(parity.get("waiver_count")) != len(
        parity.get("waivers") or []
    ):
        contradictions.append("parity waiver_count differs from its waiver list")
    if isinstance(marker.get("waivers"), list) and isinstance(parity.get("waivers"), list):
        if marker["waivers"] != parity["waivers"]:
            contradictions.append("phase6 and parity waiver lists differ")
    if contradictions:
        return stop(
            9,
            "gate/report/ledger claims disagree.",
            contradictions,
        )

    completion_verdict = (
        "YELLOW"
        if str(report.get("verdict") or "").upper() == "YELLOW"
        and derived_verdict == "GREEN"
        else derived_verdict
    )
    print(
        "DONE: Qlik hard gates, strict parity, PNG health, accounting, "
        f"and report reconcile. VERDICT: {completion_verdict}"
    )
    print(f"  workbook: {marker.get('workbookId')}")
    print(f"  charts: {passed}/{total} strict matches")
    print(f"  objects: {len(census_rows)}/{len(census_rows)} exactly reconciled")
    print(f"  ledger: {'empty' if not derived else f'{len(derived)} degradation(s)'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
