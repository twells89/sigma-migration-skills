#!/usr/bin/env python3
"""Record a human source-vs-target visual verdict in parity-final.json."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from lib import blind_grade

VERDICTS = ("pass", "divergent", "not-executable")
CHECKLIST_KEYS = (
    "element_titles_hidden",
    "palette_match",
    "composition_match",
    "chart_shapes_match",
    "labels_legible",
    "numbers_formatted",
)
CHECKLIST_VALUES = {"pass", "fail", "na"}


def parse_checklist(value: str | None) -> dict[str, str] | None:
    if value is None:
        return None
    result = {}
    for item in value.split(","):
        if "=" not in item:
            raise ValueError(f"checklist entry needs key=value: {item!r}")
        key, selected = (part.strip() for part in item.split("=", 1))
        result[key] = selected
    unknown = set(result) - set(CHECKLIST_KEYS)
    invalid = {
        key for key, selected in result.items() if selected not in CHECKLIST_VALUES
    }
    if unknown:
        raise ValueError(f"unknown checklist key(s): {', '.join(sorted(unknown))}")
    if invalid:
        raise ValueError(
            f"checklist values must be pass|fail|na: {', '.join(sorted(invalid))}"
        )
    return result


def validate_blind_grade(path: Path, workdir: Path) -> dict[str, Any]:
    result = blind_grade.validate(path, workdir)
    result["recorded_at"] = (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--verdict", required=True, choices=VERDICTS)
    parser.add_argument("--notes")
    parser.add_argument("--screenshot")
    parser.add_argument("--blind-grade")
    parser.add_argument("--no-vision-waiver")
    parser.add_argument("--agent-vision", choices=("true", "false"))
    parser.add_argument("--checklist")
    args = parser.parse_args(argv)
    try:
        checklist = parse_checklist(args.checklist)
    except ValueError as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 2
    env_vision = os.environ.get("AGENT_VISION")
    vision = args.agent_vision
    if vision is None and env_vision:
        if env_vision.lower() not in {"true", "false"}:
            print("FATAL: AGENT_VISION must be true|false", file=sys.stderr)
            return 2
        vision = env_vision.lower()
    has_vision = vision != "false"
    if args.verdict == "pass" and not has_vision:
        print(
            "REFUSED: a pass verdict requires an agent that read the render.",
            file=sys.stderr,
        )
        return 2
    if args.verdict == "not-executable" and not str(args.notes or "").strip():
        print("FATAL: not-executable requires --notes", file=sys.stderr)
        return 2
    if args.verdict == "pass":
        missing = set(CHECKLIST_KEYS) - set(checklist or {})
        failed = [
            key for key, selected in (checklist or {}).items() if selected == "fail"
        ]
        if missing:
            print(
                "REFUSED: pass requires every checklist key: "
                + ", ".join(sorted(missing)),
                file=sys.stderr,
            )
            return 2
        if failed:
            print(
                "REFUSED: checklist marks failures: " + ", ".join(failed),
                file=sys.stderr,
            )
            return 2
        if bool(args.blind_grade) == bool(args.no_vision_waiver):
            print(
                "REFUSED: pass requires exactly one of --blind-grade or "
                "--no-vision-waiver",
                file=sys.stderr,
            )
            return 2
    workdir = Path(args.workdir).expanduser().resolve()
    parity_path = workdir / "parity-final.json"
    if not parity_path.is_file():
        print(f"FATAL: {parity_path} not found", file=sys.stderr)
        return 1
    try:
        parity = json.loads(parity_path.read_text(encoding="utf-8-sig"))
        anchors_path = workdir / "anchors-verdict.json"
        if args.verdict == "pass" and anchors_path.is_file():
            anchors = json.loads(anchors_path.read_text(encoding="utf-8-sig"))
            if anchors.get("tiles_all_nonempty") is False:
                print(
                    "REFUSED: source-anchor verification found empty displayed tiles.",
                    file=sys.stderr,
                )
                return 2
        blind_stamp = (
            validate_blind_grade(
                Path(args.blind_grade).expanduser().resolve(),
                workdir,
            )
            if args.blind_grade
            else None
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 2
    parity["visual_verdict"] = args.verdict
    parity["visual_checked"] = args.verdict == "pass"
    parity["agent_vision"] = False if args.verdict == "not-executable" else has_vision
    if args.notes:
        parity["visual_notes"] = args.notes
    if args.screenshot:
        parity["screenshot_path"] = args.screenshot
    if checklist:
        parity["style_checklist"] = checklist
    if blind_stamp:
        parity["blind_grade"] = blind_stamp
    if args.no_vision_waiver:
        parity["blind_grade_waiver"] = {
            "kind": "no-vision-grader",
            "reason": args.no_vision_waiver,
            "recorded_at": datetime.now(timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z"),
        }
    parity_path.write_text(
        json.dumps(parity, indent=2) + "\n", encoding="utf-8"
    )
    print(f"[RECORDED] visual comparison: {args.verdict.upper()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
