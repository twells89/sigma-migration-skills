#!/usr/bin/env python3
"""Verify every shared manifest target is byte-identical to its canonical file."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "shared" / "manifest.json"


def digest(path: Path) -> str | None:
    if not path.is_file():
        return None
    sha = hashlib.sha1()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def main() -> int:
    with MANIFEST.open(encoding="utf-8") as handle:
        manifest = json.load(handle)

    drift: list[tuple[str, str]] = []
    missing: list[tuple[str, str]] = []
    exceptions: list[tuple[str, str]] = []
    checked = 0

    for entry in manifest["shared"]:
        canonical_name = entry["canonical"]
        canonical = ROOT / canonical_name
        canonical_sha = digest(canonical)
        if canonical_sha is None:
            print(f"FATAL: canonical missing: {canonical_name}", file=sys.stderr)
            return 1
        for target_entry in entry["targets"]:
            if isinstance(target_entry, dict):
                target_name = target_entry["path"]
                reason = target_entry.get("exception")
            else:
                target_name, reason = target_entry, None
            if reason:
                exceptions.append((target_name, reason))
                continue
            target_sha = digest(ROOT / target_name)
            if target_sha is None:
                missing.append((canonical_name, target_name))
            elif target_sha != canonical_sha:
                drift.append((canonical_name, target_name))
            checked += 1

    if exceptions:
        print("Allowlisted exceptions (not checked):")
        for path, reason in exceptions:
            print(f"  - {path}\n      {reason}")
        print()

    if not drift and not missing:
        print(
            f"OK: {checked} shared-file copies all match canonical "
            f"({len(exceptions)} allowlisted exceptions)."
        )
        return 0

    print("SHARED-LIB DRIFT DETECTED")
    print("Fix: edit the canonical copy, then run `python3 tools/sync-shared.py`.")
    print(
        "(If a fork is intentional, add an exception to its "
        "shared/manifest.json target.)\n"
    )
    for canonical, target in drift:
        print(f"  DRIFT  {target}\n         != {canonical}")
    for canonical, target in missing:
        print(f"  MISSING {target}  (declared target of {canonical})")
    print(f"\ndrift: {len(drift)}, missing: {len(missing)}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
