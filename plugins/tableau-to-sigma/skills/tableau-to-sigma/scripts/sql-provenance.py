#!/usr/bin/env python3
"""Write or verify Custom SQL element provenance."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import sql_provenance  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--dm-spec")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    workdir = Path(args.workdir).expanduser().resolve()
    dm_spec = (
        Path(args.dm_spec).resolve()
        if args.dm_spec
        else next(
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
    )
    artifact = workdir / "sql-provenance.json"
    if dm_spec is None or not dm_spec.is_file():
        print("SQL PROVENANCE FAIL: no data-model spec is available", file=sys.stderr)
        return 3
    try:
        result = sql_provenance.evaluate(
            dm_spec,
            workdir / "conv-meta.json",
            workdir / "workbook-content.twb",
            workdir / "custom-sql.json",
            workdir / "sql-provenance-overrides.json",
        )
        if args.check:
            actual = json.loads(artifact.read_text(encoding="utf-8-sig"))
            if actual != result:
                print(
                    "SQL PROVENANCE FAIL: sql-provenance.json is stale or was edited",
                    file=sys.stderr,
                )
                return 3
        else:
            artifact.write_text(
                json.dumps(result, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"SQL PROVENANCE FAIL: {exc}", file=sys.stderr)
        return 3
    print(
        f"SQL provenance: {result['status'].upper()} — "
        f"{len(result['sql_elements'])} SQL element(s), "
        f"{len(result['blockers'])} unattributed"
    )
    if result["status"] == "fail":
        for entry in result["blockers"]:
            print(
                f"  - {entry.get('element_name') or entry.get('element_id')}: "
                f"{entry['evidence']}",
                file=sys.stderr,
            )
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
