#!/usr/bin/env python3
"""Deterministically project parity-plan expected rows for verify-parity.py."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


class TransformError(ValueError):
    pass


def transform(plan) -> dict[str, list]:
    if not isinstance(plan, dict) or not isinstance(plan.get("charts"), list):
        raise TransformError("parity plan must contain a charts array")
    if not plan["charts"]:
        raise TransformError("parity plan charts array is empty")
    result = {}
    for index, chart in enumerate(plan["charts"]):
        if not isinstance(chart, dict):
            raise TransformError(f"chart at index {index} must be an object")
        name = str(chart.get("chart") or chart.get("name") or "").strip()
        if not name:
            raise TransformError(f"chart at index {index} has no name")
        if name in result:
            raise TransformError(f"duplicate chart name {name!r}")
        expected = chart.get("expected")
        if not isinstance(expected, list) or not expected:
            raise TransformError(f"chart {name!r} has no expected rows")
        if any(not isinstance(row, list) or not row for row in expected):
            raise TransformError(f"chart {name!r} has malformed expected rows")
        result[name] = expected
    return result


def atomic_write(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        with Path(args.plan).open(encoding="utf-8-sig") as handle:
            plan = json.load(handle)
        expected = transform(plan)
        atomic_write(Path(args.out), expected)
    except (OSError, ValueError, json.JSONDecodeError, TransformError) as exc:
        print(f"FATAL: parity expected transform failed: {exc}", file=sys.stderr)
        return 1
    print(f"wrote {args.out} ({len(expected)} chart(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
