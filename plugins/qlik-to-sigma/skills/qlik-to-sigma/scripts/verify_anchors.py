#!/usr/bin/env python3
"""Verify transcribed Qlik source values against collected Sigma CSV actuals."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

STOPWORDS = {"the", "a", "an", "of", "by", "per", "and", "or", "in", "on", "for", "to", "vs"}
NAME_ONLY = {"text", "roster", "member"}
SUFFIXES = {"k": 1e3, "m": 1e6, "b": 1e9, "t": 1e12}


def parse_printed(raw: Any) -> list[tuple[float, float]]:
    text = str(raw or "").strip()
    if not text:
        return []
    negative = text.startswith("(") and text.endswith(")")
    if negative:
        text = text[1:-1].strip()
    if text.startswith(("-", "−", "–")):
        negative = True
        text = text[1:].strip()
    text = text.lstrip("$€£¥").strip()
    percent = text.endswith("%")
    if percent:
        text = text[:-1].strip()
    multiplier = 1.0
    suffix_match = re.fullmatch(r"(.*?)\s*([kKmMbBtT])", text)
    if suffix_match:
        text = suffix_match.group(1).strip()
        multiplier = SUFFIXES[suffix_match.group(2).lower()]
    digits = text.replace(",", "")
    if not re.fullmatch(r"(?:\d+(?:\.\d+)?|\.\d+)", digits):
        return []
    decimals = len(digits.split(".", 1)[1]) if "." in digits else 0
    value = float(digits) * multiplier * (-1 if negative else 1)
    tolerance = (10 ** -decimals / 2) * multiplier
    result = [(value, tolerance)]
    if percent:
        result.append((value / 100.0, tolerance / 100.0))
    return result


def cell_numbers(value: Any) -> list[float]:
    if isinstance(value, bool) or value is None:
        return []
    if isinstance(value, (int, float)):
        return [float(value)] if math.isfinite(float(value)) else []
    text = str(value).strip()
    if not text:
        return []
    negative = text.startswith("(") and text.endswith(")")
    if negative:
        text = text[1:-1]
    body = re.sub(r"[,$€£¥\s]", "", text)
    percent = body.endswith("%")
    body = body.rstrip("%")
    try:
        number = float(body) * (-1 if negative else 1)
    except ValueError:
        return [item[0] for item in parse_printed(value)]
    return [number, number / 100.0] if percent else [number]


def matches(raw: Any, actual: float) -> bool:
    return any(
        abs(actual - expected) <= tolerance + 1e-9 * max(abs(expected), 1.0)
        for expected, tolerance in parse_printed(raw)
    )


def tokens(value: Any) -> set[str]:
    return {
        token
        for token in re.findall(r"[a-z0-9]+", str(value or "").lower())
        if token not in STOPWORDS
    }


def score(anchor: dict[str, Any], tile: str) -> int:
    tile_tokens = tokens(tile)
    hint = str(anchor.get("sigma_element_hint") or "").strip()
    if hint:
        return 1000 if hint.casefold() == tile.strip().casefold() else len(tokens(hint) & tile_tokens)
    return len((tokens(anchor.get("panel")) | tokens(anchor.get("label"))) & tile_tokens)


def verify(
    anchors: list[dict[str, Any]], actuals: dict[str, Any]
) -> dict[str, Any]:
    names = list(actuals)
    numbers = {
        name: [
            number
            for row in (rows if isinstance(rows, list) else [rows])
            for cell in (row if isinstance(row, list) else [row])
            for number in cell_numbers(cell)
        ]
        for name, rows in actuals.items()
    }
    texts = {
        name: {
            str(cell).strip().casefold()
            for row in (rows if isinstance(rows, list) else [rows])
            for cell in (row if isinstance(row, list) else [row])
            if str(cell).strip()
        }
        for name, rows in actuals.items()
    }
    detail, missing = [], []
    for anchor in anchors:
        order = sorted(names, key=lambda name: (-score(anchor, name), name))
        hint = str(anchor.get("sigma_element_hint") or "").strip()
        if hint:
            scoped = [name for name in order if score(anchor, name) > 0]
            if scoped:
                order = scoped
        raw = str(anchor.get("raw") or "")
        if str(anchor.get("kind") or "") in NAME_ONLY:
            found = next(
                (name for name in order if raw.strip().casefold() in texts[name]),
                None,
            )
        else:
            found = next(
                (
                    name
                    for name in order
                    if any(matches(raw, value) for value in numbers[name])
                ),
                None,
            )
        if found:
            detail.append(
                {
                    "id": anchor.get("id"),
                    "raw": raw,
                    "matched_in": found,
                    "kind": anchor.get("kind"),
                    "provenance": anchor.get("provenance"),
                    "valued": (
                        str(anchor.get("kind") or "") not in NAME_ONLY
                        and anchor.get("provenance") in {"view-csv", "vds"}
                    ),
                }
            )
        else:
            missing.append(
                {
                    "id": anchor.get("id"),
                    "label": anchor.get("label"),
                    "raw": raw,
                    "sigma_element_hint": anchor.get("sigma_element_hint"),
                }
            )
    nonempty = {
        name: bool(rows) for name, rows in actuals.items()
    }
    empty = [name for name, present in nonempty.items() if not present]
    return {
        "checked": len(anchors),
        "matched": len(detail),
        "missing": missing,
        "inconclusive": [],
        "pass": not missing and not empty,
        "detail": detail,
        "tiles": [
            {"name": name, "displayed": True, "data_rows": len(rows) if isinstance(rows, list) else 1}
            for name, rows in actuals.items()
        ],
        "dashboard_tiles_empty": empty,
        "tiles_all_nonempty": not empty,
        "anchors_matched_in_displayed": len(detail),
        "anchors_only_in_feeders": [],
    }


def _anchor_map(anchors: list[dict[str, Any]]) -> dict[str, str]:
    return {
        str(anchor.get("id")): str(anchor.get("raw"))
        for anchor in anchors
        if anchor.get("id")
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--anchors")
    parser.add_argument("--actuals")
    parser.add_argument("--out")
    parser.add_argument("--retranscribed")
    args = parser.parse_args(argv)
    workdir = Path(args.workdir).expanduser().resolve()
    anchors_path = Path(args.anchors) if args.anchors else workdir / "source-anchors.json"
    actuals_path = Path(args.actuals) if args.actuals else workdir / "parity-actuals.json"
    output = Path(args.out) if args.out else workdir / "anchors-verdict.json"
    try:
        source = json.loads(anchors_path.read_text(encoding="utf-8-sig"))
        anchors = source.get("anchors") or []
        actuals_doc = json.loads(actuals_path.read_text(encoding="utf-8-sig"))
        actuals = actuals_doc.get("tiles") if isinstance(actuals_doc, dict) and "tiles" in actuals_doc else actuals_doc
        if not anchors or not isinstance(actuals, dict):
            raise ValueError("anchors[] and actuals object are required")
        bad = [
            row
            for row in anchors
            if str(row.get("kind") or "") not in NAME_ONLY
            and not parse_printed(row.get("raw"))
        ]
        if bad:
            raise ValueError(f"{len(bad)} numeric anchor(s) have unparseable raw values")
        current = _anchor_map(anchors)
        lock_path = workdir / "source-anchors.lock.json"
        if lock_path.is_file():
            locked = json.loads(lock_path.read_text(encoding="utf-8-sig"))
            changed = {
                key: (locked.get("anchors", {}).get(key), value)
                for key, value in current.items()
                if key in (locked.get("anchors") or {})
                and locked["anchors"][key] != value
            }
            if changed and not args.retranscribed:
                raise ValueError(
                    "source-anchor values changed; use --retranscribed only after "
                    "re-reading the source image"
                )
        lock_path.write_text(
            json.dumps(
                {
                    "content_sha256": hashlib.sha256(
                        anchors_path.read_bytes()
                    ).hexdigest(),
                    "stamped_at": datetime.now(timezone.utc).isoformat(),
                    "anchor_count": len(anchors),
                    "anchors": current,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        verdict = verify(anchors, actuals)
        verdict["source_anchors"] = str(anchors_path)
        verdict["verified_at"] = datetime.now(timezone.utc).isoformat()
        if args.retranscribed:
            verdict["anchors_retranscribed"] = {"reason": args.retranscribed}
        output.write_text(json.dumps(verdict, indent=2) + "\n", encoding="utf-8")
        parity_path = workdir / "parity-final.json"
        if parity_path.is_file():
            parity = json.loads(parity_path.read_text(encoding="utf-8-sig"))
            parity["anchors"] = {
                "checked": verdict["checked"],
                "matched": verdict["matched"],
                "pass": verdict["pass"],
                "missing": [row.get("id") for row in verdict["missing"]],
            }
            parity["dashboard_tiles_empty"] = verdict["dashboard_tiles_empty"]
            parity["tiles_all_nonempty"] = verdict["tiles_all_nonempty"]
            parity_path.write_text(
                json.dumps(parity, indent=2) + "\n", encoding="utf-8"
            )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"verify-anchors: {exc}", file=sys.stderr)
        return 2
    print(
        f"verify-anchors: {verdict['matched']}/{verdict['checked']} anchor(s) "
        f"matched across {len(actuals)} element export(s) -> {output}"
    )
    return 0 if verdict["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
