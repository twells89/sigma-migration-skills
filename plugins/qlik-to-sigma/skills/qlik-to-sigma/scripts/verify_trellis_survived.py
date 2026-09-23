#!/usr/bin/env python3
"""Fail when a native trellis emitted by the builder is absent on readback."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from lib.code_rep import document, workbook_elements


def load(path: Path) -> Any:
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def verify(emitted: dict[str, Any], readback: dict[str, Any]) -> list[str]:
    raw_spec = readback.get("spec") if isinstance(readback.get("spec"), dict) else readback
    spec = document(raw_spec)
    elements = {
        str(row.get("id") or row.get("elementId")): row
        for row in workbook_elements(spec)
        if row.get("id") or row.get("elementId")
    }
    failures = []
    for row in emitted.get("elements") or []:
        if not isinstance(row, dict):
            failures.append("malformed native-trellis sidecar row")
            continue
        element_id = str(row.get("element_id") or row.get("elementId") or "")
        axis = str(row.get("axis") or "")
        element = elements.get(element_id)
        trellis = element.get("trellis") if isinstance(element, dict) else None
        if not isinstance(trellis, dict):
            failures.append(f"{element_id}: trellis missing from readback")
        elif axis and not trellis.get(axis):
            failures.append(f"{element_id}: trellis.{axis} missing from readback")
    return failures


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emitted", required=True)
    parser.add_argument("--spec", required=True)
    args = parser.parse_args(argv)
    try:
        failures = verify(
            load(Path(args.emitted).expanduser().resolve()),
            load(Path(args.spec).expanduser().resolve()),
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"verify-trellis-survived: {exc}", file=sys.stderr)
        return 2
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print("PASS: every emitted native trellis survived readback")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
