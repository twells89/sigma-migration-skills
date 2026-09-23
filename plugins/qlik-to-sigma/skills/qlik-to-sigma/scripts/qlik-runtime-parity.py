#!/usr/bin/env python3
"""Compare normalized Qlik dry-run artifacts from Ruby and Python entrypoints."""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
DEFAULT_FIXTURE = SKILL / "fixtures" / "retail-orders"
CONNECTION = "00000000-0000-0000-0000-000000000000"
JSON_ARTIFACTS = (
    "converter-out.json",
    "formula-mapping.json",
    "reconcile.json",
    "denorm.json",
    "dm-spec.json",
    "dm-result.json",
    "wb-spec.json",
    "wb-result.json",
    "workbook-coverage.json",
    "control-scope.json",
    "element-map.json",
)
TEXT_ARTIFACTS = ("layout.xml",)
SECRET_KEYS = {
    "SIGMA_API_TOKEN",
    "SIGMA_CLIENT_ID",
    "SIGMA_CLIENT_SECRET",
}
VOLATILE_KEYS = {
    "createdAt",
    "generatedAt",
    "generated_at",
    "startedAt",
    "updatedAt",
}
ID_KEYS = {
    "id",
    "columnId",
    "controlId",
    "dataModelId",
    "denormElementId",
    "elementId",
    "folderId",
    "sourceColumnId",
    "targetColumnId",
    "targetElementId",
    "workbookId",
}


def read_json(path: Path) -> Any:
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def normalize(value: Any, roots: tuple[Path, ...]) -> Any:
    if isinstance(value, dict):
        return {
            key: normalize(item, roots)
            for key, item in sorted(value.items())
            if key not in VOLATILE_KEYS
        }
    if isinstance(value, list):
        return [normalize(item, roots) for item in value]
    if isinstance(value, str):
        result = value
        for root in roots:
            result = result.replace(str(root), "<WORKDIR>")
        return result
    return value


def normalize_ids(value: Any) -> Any:
    found: dict[str, None] = {}

    def collect(item: Any) -> None:
        if isinstance(item, dict):
            for key in sorted(item):
                child = item[key]
                if key in ID_KEYS and isinstance(child, str):
                    found.setdefault(child, None)
                collect(child)
        elif isinstance(item, list):
            for child in item:
                collect(child)

    collect(value)
    mapping = {
        original: f"<ID-{index:04d}>"
        for index, original in enumerate(found, 1)
    }

    def replace(item: Any) -> Any:
        if isinstance(item, dict):
            return {key: replace(child) for key, child in item.items()}
        if isinstance(item, list):
            return [replace(child) for child in item]
        if isinstance(item, str):
            if item in mapping:
                return mapping[item]
            for original, normalized in mapping.items():
                if item.startswith(original + "/"):
                    return normalized + item[len(original):]
            return item
        return item

    return replace(value)


def normalize_layout_ids(value: str) -> str:
    found: dict[str, str] = {}
    pattern = re.compile(r'(\b(?:id|elementId)=")([^"]+)(")')

    def replace(match: re.Match[str]) -> str:
        original = match.group(2)
        normalized = found.setdefault(
            original, f"<ID-{len(found) + 1:04d}>"
        )
        return f"{match.group(1)}{normalized}{match.group(3)}"

    return pattern.sub(replace, value)


def run_entrypoint(command: list[str], fixture: Path, workdir: Path) -> None:
    environment = {
        key: value for key, value in os.environ.items() if key not in SECRET_KEYS
    }
    completed = subprocess.run(
        command
        + [
            "--from-discovery",
            str(fixture),
            "--connection",
            CONNECTION,
            "--dry-run",
            "--yes",
            "--out",
            str(workdir),
        ],
        cwd=SKILL,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        timeout=180,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"{' '.join(command)} exited {completed.returncode}\n{completed.stdout}"
        )


def compare(left: Any, right: Any, label: str) -> list[str]:
    if left == right:
        print(f"PASS {label}")
        return []
    left_text = json.dumps(left, indent=2, ensure_ascii=False, sort_keys=True)
    right_text = json.dumps(right, indent=2, ensure_ascii=False, sort_keys=True)
    return list(
        difflib.unified_diff(
            left_text.splitlines(),
            right_text.splitlines(),
            fromfile=f"ruby/{label}",
            tofile=f"python/{label}",
            lineterm="",
        )
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", default=str(DEFAULT_FIXTURE))
    args = parser.parse_args(argv)
    fixture = Path(args.fixture).expanduser().resolve()
    ruby = shutil.which("ruby")
    node = shutil.which("node")
    if not ruby:
        print("FATAL: ruby is required for the cross-runtime parity job", file=sys.stderr)
        return 2
    if not node:
        print("FATAL: node is required for the vendored converter", file=sys.stderr)
        return 2
    if not fixture.is_dir():
        print(f"FATAL: fixture directory is missing: {fixture}", file=sys.stderr)
        return 2

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="qlik-runtime-parity-") as temporary:
        root = Path(temporary)
        ruby_workdir = root / "ruby"
        python_workdir = root / "python"
        python_workdir.mkdir()
        runtime_profile = {
            "selected": "python",
            "required_runtimes": ["python", "node"],
        }
        (python_workdir / "doctor.json").write_text(
            json.dumps(
                {
                    "pass": True,
                    "runtime_profile": runtime_profile,
                    "runtimes": {
                        "python": True,
                        "node": True,
                        "ruby": False,
                    },
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        (python_workdir / "bootstrap.json").write_text(
            json.dumps(
                {
                    "doctor_pass": True,
                    "runtime_profile": runtime_profile,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        run_entrypoint([ruby, str(HERE / "migrate-qlik.rb")], fixture, ruby_workdir)
        run_entrypoint(
            [sys.executable, str(HERE / "migrate-qlik.py")],
            fixture,
            python_workdir,
        )
        roots = (ruby_workdir, python_workdir)
        for artifact in JSON_ARTIFACTS:
            left_path = ruby_workdir / artifact
            right_path = python_workdir / artifact
            if not left_path.is_file() or not right_path.is_file():
                failures.append(
                    f"{artifact}: missing "
                    f"(ruby={left_path.is_file()}, python={right_path.is_file()})"
                )
                continue
            failures.extend(
                compare(
                    normalize(normalize_ids(read_json(left_path)), roots),
                    normalize(normalize_ids(read_json(right_path)), roots),
                    artifact,
                )
            )
        for artifact in TEXT_ARTIFACTS:
            left_path = ruby_workdir / artifact
            right_path = python_workdir / artifact
            if not left_path.is_file() or not right_path.is_file():
                failures.append(
                    f"{artifact}: missing "
                    f"(ruby={left_path.is_file()}, python={right_path.is_file()})"
                )
                continue
            left = normalize_layout_ids(
                normalize(left_path.read_text(encoding="utf-8"), roots)
            )
            right = normalize_layout_ids(
                normalize(right_path.read_text(encoding="utf-8"), roots)
            )
            failures.extend(compare(left, right, artifact))

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("ALL PASS: Qlik Ruby/Python normalized fixture parity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
