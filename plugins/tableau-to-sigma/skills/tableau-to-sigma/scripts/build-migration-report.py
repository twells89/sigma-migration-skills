#!/usr/bin/env python3
"""Build a redaction-safe Tableau Python migration report from gate artifacts."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def load(path: Path, default=None):
    if not path.is_file():
        return default
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def report(workdir: Path) -> str:
    mission = load(workdir / "mission.json", {}) or {}
    result = load(workdir / "migration-result.json", {}) or {}
    parity = load(workdir / "parity-final.json", {}) or {}
    visual = load(workdir / "visual-similarity-final.json", {}) or {}
    semantic = load(workdir / "semantic-edits.json", {}) or {}
    metadata = (
        load(workdir / "conv-meta-repaired.json")
        or load(workdir / "conv-meta.json", {})
        or {}
    )
    lines = [
        "# Tableau → Sigma Python Migration Report",
        "",
        f"**Verdict:** {result.get('status', 'BLOCKED')}",
        "",
        "## Mission",
        "",
    ]
    for key in ("source", "sigma_connection", "destination", "landing", "scope"):
        value = mission.get(key) or {}
        lines.append(
            f"- **{key.replace('_', ' ').title()}:** "
            f"{value.get('value', '(missing)')} [{value.get('provenance', 'missing')}]"
        )
    lines += [
        "",
        "## Objects",
        "",
        f"- Data model ID: `{result.get('dataModelId') or '(missing)'}`",
        f"- Workbook ID: `{result.get('workbookId') or '(missing)'}`",
        "",
        "## Gates",
        "",
    ]
    for gate, passed in (result.get("gates") or {}).items():
        lines.append(f"- {'PASS' if passed else 'FAIL'} — {gate.replace('_', ' ')}")
    lines += [
        "",
        "## Evidence",
        "",
        f"- Numeric parity: {parity.get('status', 'MISSING')} "
        f"({len(parity.get('differences') or [])} differences)",
        f"- Machine visual floor: {'PASS' if visual.get('pass') else 'FAIL'} "
        f"(overall={visual.get('score_overall', 'n/a')})",
        f"- Semantic edits proof: {'PASS' if semantic.get('match') else 'FAIL'}",
        "",
        "## Converter findings",
        "",
    ]
    warnings = metadata.get("warnings") or []
    patterns = metadata.get("workbookPatterns") or []
    lines.append(f"- Warnings: {len(warnings)}")
    lines.append(f"- Remaining workbook patterns: {len(patterns)}")
    security = metadata.get("security") or []
    lines.append(f"- Detected security rules: {len(security)}")
    failures = result.get("failures") or []
    if failures:
        lines += ["", "## Blocking findings", ""]
        lines.extend(f"- {failure}" for failure in failures)
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--out")
    args = parser.parse_args()
    workdir = Path(args.workdir).expanduser().resolve()
    out = Path(args.out).expanduser().resolve() if args.out else workdir / "MIGRATION_REPORT.md"
    try:
        out.write_text(report(workdir), encoding="utf-8")
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FATAL: migration report failed: {exc}", file=sys.stderr)
        return 1
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
