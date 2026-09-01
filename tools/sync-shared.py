#!/usr/bin/env python3
"""Propagate canonical shared files into declared plugin targets.

Python twin of sync-shared.rb for contributor environments where Ruby cannot
be installed. Both implementations consume shared/manifest.json and preserve
the canonical file mode.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    with MANIFEST.open(encoding="utf-8") as handle:
        manifest = json.load(handle)

    changed: list[tuple[Path, Path]] = []
    skipped = 0
    for entry in manifest["shared"]:
        canonical = ROOT / entry["canonical"]
        if not canonical.is_file():
            print(f"FATAL: canonical missing: {entry['canonical']}", file=sys.stderr)
            return 1
        for target_entry in entry["targets"]:
            if isinstance(target_entry, dict):
                if target_entry.get("exception"):
                    skipped += 1
                    continue
                target_name = target_entry["path"]
            else:
                target_name = target_entry
            target = ROOT / target_name
            if digest(target) == digest(canonical):
                continue
            changed.append((canonical, target))
            if args.dry_run:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(canonical, target)
            os.chmod(target, canonical.stat().st_mode)

    if not changed:
        action = "change" if args.dry_run else "write"
        print(f"Already in sync — nothing to {action}. ({skipped} exceptions skipped)")
        return 0

    print(
        f"{'Would update' if args.dry_run else 'Updated'} "
        f"{len(changed)} file(s):"
    )
    marker = "~" if args.dry_run else "✓"
    for canonical, target in changed:
        print(f"  {marker} {target.relative_to(ROOT)}  <- {canonical.relative_to(ROOT)}")
    if skipped:
        print(f"Skipped {skipped} allowlisted exception(s).")
    if not args.dry_run:
        print("\nNext: review the diff and commit. CI will verify shared-file parity.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
