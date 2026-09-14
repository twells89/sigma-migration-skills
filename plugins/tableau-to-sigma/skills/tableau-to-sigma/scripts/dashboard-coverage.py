#!/usr/bin/env python3
"""Write or verify visible Tableau dashboard coverage."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import dashboard_coverage  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--source")
    parser.add_argument("--spec")
    parser.add_argument("--scope")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    workdir = Path(args.workdir).expanduser().resolve()
    source = Path(args.source).resolve() if args.source else workdir / "workbook-content.twb"
    if args.spec:
        spec = Path(args.spec).resolve()
    else:
        spec = next(
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
    scope_path = Path(args.scope).resolve() if args.scope else workdir / "dashboard-scope.json"
    artifact = workdir / "dashboard-coverage.json"
    if not source.is_file() or spec is None or not spec.is_file():
        print(
            f"DASHBOARD COVERAGE FAIL: source/spec missing "
            f"(source={source}, spec={spec or '(none)'})",
            file=sys.stderr,
        )
        return 3
    try:
        scope = (
            json.loads(scope_path.read_text(encoding="utf-8-sig"))
            if scope_path.is_file()
            else {"mode": "full"}
        )
        result = dashboard_coverage.evaluate(
            source, spec, scope, workdir / "story-plan.json"
        )
        if args.check:
            actual = json.loads(artifact.read_text(encoding="utf-8-sig"))
            if actual != result:
                print(
                    "DASHBOARD COVERAGE FAIL: dashboard-coverage.json is stale "
                    "or was edited; rerun conversion",
                    file=sys.stderr,
                )
                return 3
        else:
            artifact.write_text(
                json.dumps(result, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"DASHBOARD COVERAGE FAIL: {exc}", file=sys.stderr)
        return 3
    print(
        f"dashboard coverage: {result['status'].upper()} — "
        f"{len(result['built_pages'])}/{len(result['expected_pages'])} "
        f"expected page(s), "
        f"{len(result['missing_dashboards']) + len(result['missing_story_points'])} missing"
    )
    if result["status"] == "fail":
        for blocker in result["blockers"]:
            print(
                f"  - {blocker.get('dashboard') or blocker['kind']}: "
                f"{blocker['reason']}",
                file=sys.stderr,
            )
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
