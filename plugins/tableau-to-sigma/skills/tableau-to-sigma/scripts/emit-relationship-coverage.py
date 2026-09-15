#!/usr/bin/env python3
"""Write and optionally enforce Tableau relationship coverage."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import relationship_coverage  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--converter-out", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--source")
    parser.add_argument("--dm-spec")
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()
    try:
        result = relationship_coverage.from_files(
            Path(args.converter_out),
            Path(args.source) if args.source else None,
            Path(args.dm_spec) if args.dm_spec else None,
        )
        Path(args.out).write_text(
            json.dumps(result, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FATAL: relationship coverage could not be emitted: {exc}", file=sys.stderr)
        return 2

    print(
        f"emit-relationship-coverage: {result['status'].upper()} — "
        f"{result['serialized']} serialized, {result['wired']} wired, "
        f"{len(result['blockers'])} blocker(s) -> {args.out}"
    )
    if args.strict and result["status"] == "fail":
        for blocker in result["blockers"]:
            pair = " ↔ ".join(
                str(value)
                for value in (blocker.get("left"), blocker.get("right"))
                if value is not None
            )
            print(
                f"  - {pair or blocker['kind']}: {blocker['reason']}",
                file=sys.stderr,
            )
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
