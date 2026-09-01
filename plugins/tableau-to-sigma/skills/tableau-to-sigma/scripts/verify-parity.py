#!/usr/bin/env python3
"""Compare source and Sigma parity artifacts and emit a fail-closed verdict."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path


def load(path: str):
    with Path(path).open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def compare(expected, actual, path="$", *, abs_tol=1e-6, rel_tol=1e-9):
    differences = []
    if (
        isinstance(expected, (int, float))
        and not isinstance(expected, bool)
        and isinstance(actual, (int, float))
        and not isinstance(actual, bool)
    ):
        if not math.isclose(float(expected), float(actual), abs_tol=abs_tol, rel_tol=rel_tol):
            differences.append(
                {"path": path, "expected": expected, "actual": actual, "kind": "number"}
            )
        return differences
    if isinstance(expected, dict) and isinstance(actual, dict):
        for key in sorted(set(expected) | set(actual)):
            child = f"{path}.{key}"
            if key not in expected:
                differences.append({"path": child, "kind": "unexpected"})
            elif key not in actual:
                differences.append({"path": child, "kind": "missing"})
            else:
                differences.extend(
                    compare(
                        expected[key],
                        actual[key],
                        child,
                        abs_tol=abs_tol,
                        rel_tol=rel_tol,
                    )
                )
        return differences
    if isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            differences.append(
                {
                    "path": path,
                    "kind": "length",
                    "expected": len(expected),
                    "actual": len(actual),
                }
            )
        for index, (left, right) in enumerate(zip(expected, actual)):
            differences.extend(
                compare(
                    left,
                    right,
                    f"{path}[{index}]",
                    abs_tol=abs_tol,
                    rel_tol=rel_tol,
                )
            )
        return differences
    if expected != actual:
        differences.append(
            {"path": path, "expected": expected, "actual": actual, "kind": "value"}
        )
    return differences


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected", required=True)
    parser.add_argument("--actual", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--abs-tol", type=float, default=1e-6)
    parser.add_argument("--rel-tol", type=float, default=1e-9)
    args = parser.parse_args()
    try:
        expected = load(args.expected)
        actual = load(args.actual)
        differences = compare(
            expected,
            actual,
            abs_tol=args.abs_tol,
            rel_tol=args.rel_tol,
        )
        verdict = {
            "status": "PASS" if not differences else "FAIL",
            "match": not differences,
            "abs_tolerance": args.abs_tol,
            "rel_tolerance": args.rel_tol,
            "differences": differences,
        }
        Path(args.out).write_text(
            json.dumps(verdict, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FATAL: parity comparison failed: {exc}", file=sys.stderr)
        return 2
    print(
        f"parity: {verdict['status']} "
        f"({len(differences)} difference(s)) -> {args.out}"
    )
    return 0 if not differences else 1


if __name__ == "__main__":
    raise SystemExit(main())
