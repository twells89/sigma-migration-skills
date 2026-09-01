#!/usr/bin/env python3
"""Compare creds-free artifacts from the Tableau Ruby and Python runtimes.

The harness invokes the existing production entry points in isolated temporary
directories.  It compares normalized JSON artifacts rather than stdout or
pretty-printing, and never reads migration credentials.
"""

from __future__ import annotations

import argparse
import copy
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
SKILL_DIR = HERE.parent
REPO_ROOT = HERE.parents[4]
DEFAULT_CASES = HERE / "fixtures" / "tableau-runtime-parity-cases.json"
CONVERTER = SKILL_DIR / "converter" / "tableau.mjs"

SECRET_ENV_KEYS = {
    "SIGMA_API_TOKEN",
    "SIGMA_BASE_URL",
    "SIGMA_CLIENT_ID",
    "SIGMA_CLIENT_SECRET",
    "TABLEAU_PAT_NAME",
    "TABLEAU_PAT_SECRET",
    "TABLEAU_SERVER_URL",
    "TABLEAU_SITE_CONTENT_URL",
    "TABLEAU_TOKEN",
}
ID_KEYS = {
    "id",
    "columnId",
    "controlId",
    "dataModelId",
    "elementId",
    "folderId",
    "sourceColumnId",
    "targetColumnId",
    "targetElementId",
}
TIMESTAMP_KEY_RE = re.compile(
    r"(?:^|_)(?:created|generated|started|updated|finished)(?:_?at)?$|timestamp",
    re.IGNORECASE,
)
ISO_TIMESTAMP_RE = re.compile(
    r"^\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$"
)


@dataclass(frozen=True)
class ParityCase:
    case_id: str
    kind: str
    twb: Path
    artifacts: tuple[str, ...]


class HarnessError(RuntimeError):
    """A manifest or harness contract is invalid."""


def read_json(path: Path) -> Any:
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def load_cases(path: Path) -> list[ParityCase]:
    document = read_json(path)
    if not isinstance(document, dict) or document.get("version") != 1:
        raise HarnessError(f"{path}: expected a version 1 object")
    raw_cases = document.get("cases")
    if not isinstance(raw_cases, list) or not raw_cases:
        raise HarnessError(f"{path}: cases must be a non-empty array")

    result: list[ParityCase] = []
    seen: set[str] = set()
    for raw in raw_cases:
        if not isinstance(raw, dict):
            raise HarnessError(f"{path}: every case must be an object")
        case_id = str(raw.get("id") or "")
        kind = str(raw.get("kind") or "")
        if not case_id or case_id in seen:
            raise HarnessError(f"{path}: case ids must be non-empty and unique")
        if kind not in {"layout", "gaps", "conversion"}:
            raise HarnessError(f"{path}: {case_id}: unsupported kind {kind!r}")
        twb = (REPO_ROOT / str(raw.get("twb") or "")).resolve()
        try:
            twb.relative_to(REPO_ROOT)
        except ValueError as exc:
            raise HarnessError(f"{path}: {case_id}: twb escapes the repo") from exc
        if not twb.is_file():
            raise HarnessError(f"{path}: {case_id}: missing fixture {twb}")
        artifacts = raw.get("artifacts")
        if not isinstance(artifacts, list) or not artifacts:
            raise HarnessError(f"{path}: {case_id}: artifacts must be non-empty")
        if any(not isinstance(item, str) or not item for item in artifacts):
            raise HarnessError(f"{path}: {case_id}: invalid artifact name")
        result.append(ParityCase(case_id, kind, twb, tuple(artifacts)))
        seen.add(case_id)
    return result


def clean_environment() -> dict[str, str]:
    """Return the process environment with migration credentials removed."""
    return {
        key: value
        for key, value in os.environ.items()
        if key not in SECRET_ENV_KEYS
    }


def _collect_ids(value: Any, found: dict[str, None]) -> None:
    if isinstance(value, dict):
        for key in sorted(value):
            item = value[key]
            if key in ID_KEYS and isinstance(item, str) and item not in found:
                found[item] = None
            _collect_ids(item, found)
    elif isinstance(value, list):
        for item in value:
            _collect_ids(item, found)


def _replace_ids(value: Any, mapping: dict[str, str]) -> Any:
    if isinstance(value, dict):
        return {key: _replace_ids(item, mapping) for key, item in value.items()}
    if isinstance(value, list):
        return [_replace_ids(item, mapping) for item in value]
    if isinstance(value, str) and value in mapping:
        return mapping[value]
    return value


def normalize_ids(value: Any) -> Any:
    """Normalize generated identifiers while preserving reference topology."""
    found: dict[str, None] = {}
    _collect_ids(value, found)
    mapping: dict[str, str] = {}
    for index, original in enumerate(found, 1):
        suffix = ""
        if original.startswith("inode-") and "/" in original:
            suffix = "/" + original.split("/", 1)[1]
        mapping[original] = f"<ID-{index:04d}>{suffix}"
    return _replace_ids(value, mapping)


def _normalize_scalars(value: Any, roots: tuple[Path, ...], key: str = "") -> Any:
    if isinstance(value, dict):
        normalized = {}
        for child_key, item in value.items():
            if item is None:
                continue
            normalized[child_key] = _normalize_scalars(item, roots, child_key)
        return normalized
    if isinstance(value, list):
        return [_normalize_scalars(item, roots, key) for item in value]
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str):
        if TIMESTAMP_KEY_RE.search(key) or ISO_TIMESTAMP_RE.fullmatch(value):
            return "<TIMESTAMP>"
        rendered = value
        for root in roots:
            rendered = rendered.replace(str(root), "<WORKDIR>")
        rendered = rendered.replace(str(REPO_ROOT), "<REPO>")
        return rendered
    return value


def _sort_semantic_sets(value: Any) -> Any:
    if isinstance(value, dict):
        result = {key: _sort_semantic_sets(item) for key, item in value.items()}
        for key, identity in (
            ("detected_features", ("name", "status")),
            ("formulas", ("internal_name", "caption", "id")),
            ("blends", ("worksheet", "primary", "secondary")),
        ):
            items = result.get(key)
            if isinstance(items, list) and all(isinstance(item, dict) for item in items):
                result[key] = sorted(
                    items,
                    key=lambda item: tuple(str(item.get(field) or "") for field in identity),
                )
        return result
    if isinstance(value, list):
        return [_sort_semantic_sets(item) for item in value]
    return value


def project_artifact(kind: str, artifact: str, value: Any) -> Any:
    """Retain the contract-bearing portion of each generated artifact."""
    if kind == "gaps" and artifact == "gaps.json":
        if not isinstance(value, dict):
            return value
        return {
            key: copy.deepcopy(value[key])
            for key in (
                "workbook",
                "detected_features",
                "formula_audit",
                "field_statistics",
            )
            if key in value
        }
    return copy.deepcopy(value)


def normalize_artifact(
    kind: str,
    artifact: str,
    value: Any,
    roots: tuple[Path, ...],
) -> Any:
    projected = project_artifact(kind, artifact, value)
    normalized = _normalize_scalars(projected, roots)
    normalized = _sort_semantic_sets(normalized)
    if kind == "conversion":
        normalized = normalize_ids(normalized)
    return normalized


def render_json(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n"


def artifact_diff(
    case_id: str,
    artifact: str,
    ruby_value: Any,
    python_value: Any,
    *,
    limit: int,
) -> str:
    lines = list(
        difflib.unified_diff(
            render_json(ruby_value).splitlines(),
            render_json(python_value).splitlines(),
            fromfile=f"{case_id}/ruby/{artifact}",
            tofile=f"{case_id}/python/{artifact}",
            lineterm="",
        )
    )
    if len(lines) > limit:
        omitted = len(lines) - limit
        lines = lines[:limit] + [f"... diff truncated; {omitted} line(s) omitted"]
    return "\n".join(lines)


def run_command(command: list[str], *, cwd: Path, timeout: int) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        cwd=cwd,
        env=clean_environment(),
        text=True,
        capture_output=True,
        check=False,
        timeout=timeout,
    )
    return {
        "command": command,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def ruby_converter_driver(path: Path) -> None:
    mechanical = HERE / "mechanical-specs.rb"
    path.write_text(
        "\n".join(
            [
                "# frozen_string_literal: true",
                "require 'json'",
                f"require {str(mechanical)!r}",
                "options = JSON.parse(File.read(ARGV.fetch(0)))",
                "MechanicalSpecs.run_converter(",
                "  twb_path: options.fetch('twb'),",
                "  conn: options.fetch('connection'),",
                "  db: options.fetch('database'),",
                "  schema: options.fetch('schema'),",
                "  mcp_build: options.fetch('converter'),",
                "  workdir: options.fetch('out'),",
                "  datasource_index: 0,",
                "  table_mapping: {},",
                "  fact_table: nil",
                ")",
            ]
        )
        + "\n",
        encoding="utf-8",
    )


def commands_for_case(
    case: ParityCase,
    ruby_dir: Path,
    python_dir: Path,
) -> tuple[list[str], list[str]]:
    if case.kind == "layout":
        return (
            [
                "ruby",
                str(HERE / "parse-twb-layout.rb"),
                str(case.twb),
                str(ruby_dir / "dashboard-layout.json"),
            ],
            [
                sys.executable,
                str(HERE / "parse-twb-layout.py"),
                str(case.twb),
                str(python_dir / "dashboard-layout.json"),
            ],
        )
    if case.kind == "gaps":
        return (
            [
                "ruby",
                str(HERE / "scan-workbook-gaps.rb"),
                str(case.twb),
                str(ruby_dir / "gaps.md"),
            ],
            [
                sys.executable,
                str(HERE / "scan-workbook-gaps.py"),
                str(case.twb),
                str(python_dir / "gaps.md"),
            ],
        )

    driver = ruby_dir / "_runtime_parity_converter.rb"
    ruby_converter_driver(driver)
    common = {
        "twb": str(case.twb),
        "connection": "parity-connection",
        "database": "PARITY_DB",
        "schema": "PARITY_SCHEMA",
        "converter": str(CONVERTER),
        "out": str(ruby_dir),
    }
    options = ruby_dir / "_runtime_parity_converter.json"
    write_json(options, common)
    return (
        ["ruby", str(driver), str(options)],
        [
            sys.executable,
            str(HERE / "convert-tableau.py"),
            "--twb",
            str(case.twb),
            "--connection",
            common["connection"],
            "--database",
            common["database"],
            "--schema",
            common["schema"],
            "--converter",
            str(CONVERTER),
            "--out",
            str(python_dir),
        ],
    )


def compare_case(
    case: ParityCase,
    root: Path,
    *,
    timeout: int,
    diff_lines: int,
) -> dict[str, Any]:
    case_root = root / case.case_id
    ruby_dir = case_root / "ruby"
    python_dir = case_root / "python"
    ruby_dir.mkdir(parents=True)
    python_dir.mkdir(parents=True)
    ruby_command, python_command = commands_for_case(case, ruby_dir, python_dir)

    runs: dict[str, Any] = {}
    for runtime, command in (("ruby", ruby_command), ("python", python_command)):
        try:
            runs[runtime] = run_command(command, cwd=SKILL_DIR, timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            runs[runtime] = {
                "command": command,
                "returncode": None,
                "stdout": exc.stdout or "",
                "stderr": f"timed out after {timeout}s",
            }
        if runs[runtime]["returncode"] != 0:
            return {
                "id": case.case_id,
                "kind": case.kind,
                "status": "error",
                "runs": runs,
                "comparisons": [],
            }

    comparisons = []
    for artifact in case.artifacts:
        ruby_path = ruby_dir / artifact
        python_path = python_dir / artifact
        if not ruby_path.is_file() or not python_path.is_file():
            missing = [
                runtime
                for runtime, path in (("ruby", ruby_path), ("python", python_path))
                if not path.is_file()
            ]
            comparisons.append(
                {
                    "artifact": artifact,
                    "status": "mismatch",
                    "diff": f"artifact missing from {', '.join(missing)} runtime output",
                }
            )
            continue
        try:
            ruby_value = read_json(ruby_path)
            python_value = read_json(python_path)
        except (OSError, json.JSONDecodeError) as exc:
            comparisons.append(
                {
                    "artifact": artifact,
                    "status": "error",
                    "diff": f"could not parse artifact: {exc}",
                }
            )
            continue
        roots = (ruby_dir, python_dir, case_root, root)
        ruby_normalized = normalize_artifact(
            case.kind, artifact, ruby_value, roots
        )
        python_normalized = normalize_artifact(
            case.kind, artifact, python_value, roots
        )
        if ruby_normalized == python_normalized:
            comparisons.append({"artifact": artifact, "status": "pass"})
        else:
            comparisons.append(
                {
                    "artifact": artifact,
                    "status": "mismatch",
                    "diff": artifact_diff(
                        case.case_id,
                        artifact,
                        ruby_normalized,
                        python_normalized,
                        limit=diff_lines,
                    ),
                }
            )
    status = (
        "pass"
        if comparisons and all(item["status"] == "pass" for item in comparisons)
        else "mismatch"
    )
    return {
        "id": case.case_id,
        "kind": case.kind,
        "status": status,
        "runs": runs,
        "comparisons": comparisons,
    }


def check_runtimes(cases: list[ParityCase]) -> list[str]:
    missing = [
        executable
        for executable in ("ruby", sys.executable)
        if shutil.which(executable) is None
    ]
    if any(case.kind == "conversion" for case in cases):
        if shutil.which("node") is None:
            missing.append("node")
        if not CONVERTER.is_file():
            missing.append(str(CONVERTER))
    return missing


def print_result(result: dict[str, Any]) -> None:
    marker = {"pass": "PASS", "mismatch": "DIFF", "error": "ERROR"}[result["status"]]
    print(f"{marker} {result['id']} ({result['kind']})")
    for comparison in result["comparisons"]:
        print(f"  {comparison['status'].upper():8} {comparison['artifact']}")
        if comparison.get("diff"):
            print(comparison["diff"])
    if result["status"] == "error":
        for runtime, run in result["runs"].items():
            if run["returncode"] != 0:
                print(
                    f"  {runtime} command failed (exit {run['returncode']}): "
                    f"{' '.join(run['command'])}"
                )
                detail = (run.get("stderr") or run.get("stdout") or "").strip()
                if detail:
                    print("\n".join(f"    {line}" for line in detail.splitlines()[-20:]))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_CASES)
    parser.add_argument("--case", action="append", dest="case_ids")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--keep-workdir", action="store_true")
    parser.add_argument("--json-report", type=Path)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--diff-lines", type=int, default=160)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        cases = load_cases(args.manifest.resolve())
    except (HarnessError, OSError, json.JSONDecodeError) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 2
    if args.case_ids:
        selected = set(args.case_ids)
        cases = [case for case in cases if case.case_id in selected]
        unknown = selected - {case.case_id for case in cases}
        if unknown:
            print(f"FATAL: unknown case(s): {', '.join(sorted(unknown))}", file=sys.stderr)
            return 2
    if args.list:
        for case in cases:
            print(f"{case.case_id}\t{case.kind}\t{case.twb.relative_to(REPO_ROOT)}")
        return 0

    missing = check_runtimes(cases)
    if missing:
        print(
            "BLOCKED: runtime parity requires " + ", ".join(missing),
            file=sys.stderr,
        )
        return 2

    if args.keep_workdir:
        root = Path(tempfile.mkdtemp(prefix="tableau-runtime-parity-"))
        cleanup = None
    else:
        cleanup = tempfile.TemporaryDirectory(prefix="tableau-runtime-parity-")
        root = Path(cleanup.name)
    print(f"artifacts: {root}")

    results = [
        compare_case(
            case,
            root,
            timeout=args.timeout,
            diff_lines=args.diff_lines,
        )
        for case in cases
    ]
    for result in results:
        print_result(result)
    totals = {
        status: sum(result["status"] == status for result in results)
        for status in ("pass", "mismatch", "error")
    }
    report = {
        "version": 1,
        "credsFree": True,
        "workdir": str(root) if args.keep_workdir else None,
        "totals": totals,
        "cases": results,
    }
    if args.json_report:
        write_json(args.json_report.resolve(), report)
    print(
        f"summary: {totals['pass']} pass, {totals['mismatch']} diff, "
        f"{totals['error']} error"
    )
    if args.keep_workdir:
        print(f"kept raw artifacts in {root}")
    if cleanup is not None:
        cleanup.cleanup()
    return 0 if totals["mismatch"] == 0 and totals["error"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
