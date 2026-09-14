#!/usr/bin/env python3
"""Fail when Tableau relationship coverage is missing, stale, unwired, or partial."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import relationship_coverage  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--metadata")
    parser.add_argument("--source")
    args = parser.parse_args()
    workdir = Path(args.workdir).expanduser().resolve()
    metadata = (
        Path(args.metadata).expanduser().resolve()
        if args.metadata
        else workdir / "conv-meta.json"
    )
    source = (
        Path(args.source).expanduser().resolve()
        if args.source
        else workdir / "workbook-content.twb"
    )
    artifact = workdir / "relationship-coverage.json"
    model = next(
        (
            path
            for path in (
                workdir / "datamodel-readback.json",
                workdir / "dm-remapped.json",
                workdir / "dm-raw.json",
                workdir / "dm-spec.json",
            )
            if path.is_file()
        ),
        None,
    )

    if not artifact.is_file():
        source_has_graph = (
            source.is_file()
            and relationship_coverage.OBJECT_GRAPH_RE.search(
                source.read_text(encoding="utf-8-sig")
            )
        )
        if not source_has_graph:
            print("relationship coverage: N/A — source has no object-graph")
            return 0
        print(
            f"RELATIONSHIP COVERAGE FAIL: {artifact} is missing for an object-graph source",
            file=sys.stderr,
        )
        return 3
    if not metadata.is_file():
        source_has_graph = (
            source.is_file()
            and relationship_coverage.OBJECT_GRAPH_RE.search(
                source.read_text(encoding="utf-8-sig")
            )
        )
        if source_has_graph:
            print(
                "RELATIONSHIP COVERAGE FAIL: source has an object-graph but "
                f"{metadata} is missing",
                file=sys.stderr,
            )
            return 3
        print("relationship coverage: N/A — no converter metadata and no source object-graph")
        return 0
    try:
        expected = relationship_coverage.from_files(metadata, source, model)
        actual = json.loads(artifact.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"RELATIONSHIP COVERAGE FAIL: {exc}", file=sys.stderr)
        return 3
    if actual != expected:
        print(
            "RELATIONSHIP COVERAGE FAIL: relationship-coverage.json is stale or "
            "was edited; re-run emit-relationship-coverage.py",
            file=sys.stderr,
        )
        return 3
    if expected["status"] == "fail":
        print(
            "RELATIONSHIP COVERAGE FAIL: "
            f"{len(expected['blockers'])} incomplete source relationship(s)",
            file=sys.stderr,
        )
        for blocker in expected["blockers"]:
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
    print(
        f"relationship coverage: {expected['status'].upper()} — "
        f"{expected['wired']}/{expected['serialized']} source relationship(s) "
        "wired completely"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
