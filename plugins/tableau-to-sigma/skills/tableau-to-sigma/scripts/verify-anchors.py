#!/usr/bin/env python3
"""Verify rendered-source anchors against pre-collected Sigma actuals.

This is the credentials-free Python counterpart of the measured core in
verify-anchors.rb. It does not collect live exports. The input accepted from
the Python path is either the normal parity-actuals mapping:

    {"Tile name": [[dimension, measure], ...]}

or an explicit tile envelope:

    {"tiles": [{"id": "el-1", "name": "Tile", "displayed": true,
                "rows": [[...]]}]}

Default matching uses the precision printed in each source anchor. A wider
tolerance is used only when explicitly supplied and is recorded in the
verdict.
"""

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
NAME_ONLY_KINDS = {"text", "roster", "member"}
VALUED_PROVENANCE = {"view-csv", "vds"}
SUFFIXES = {"k": 1e3, "m": 1e6, "b": 1e9, "t": 1e12}
CURRENCY_SYMBOLS = {"$", "€", "£", "¥"}


class InputError(ValueError):
    """An input violated the anchor-verification contract."""


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_json(path: Path) -> Any:
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + "\n",
        encoding="utf-8",
    )


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_anchor_map(anchors: list[dict[str, Any]]) -> dict[str, str]:
    return {str(anchor["id"]): str(anchor["raw"]) for anchor in anchors}


def anchor_map_sha256(anchor_map: dict[str, str]) -> str:
    encoded = json.dumps(
        anchor_map, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def parse_printed(raw: Any) -> dict[str, Any] | None:
    """Parse a rendered number into value, printed-precision tolerance, and kind."""
    text = str(raw).strip() if raw is not None else ""
    if not text:
        return None

    negative = False
    if text.startswith("(") and text.endswith(")"):
        negative = True
        text = text[1:-1].strip()
    if text.startswith(("-", "−", "–")):
        negative = True
        text = text[1:].strip()

    kind = "number"
    if text and text[0] in CURRENCY_SYMBOLS:
        kind = "currency"
        text = text[1:].strip()
        if text.startswith(("-", "−", "–")):
            negative = True
            text = text[1:].strip()

    percent = text.endswith("%")
    if percent:
        kind = "percent"
        text = text[:-1].strip()

    multiplier = 1.0
    suffix = None
    if not percent:
        suffix_match = re.fullmatch(r"(.*?)\s*([kKmMbBtT])", text)
        if suffix_match and suffix_match.group(1).strip():
            text = suffix_match.group(1).strip()
            suffix = suffix_match.group(2).lower()
            multiplier = SUFFIXES[suffix]

    digits = text.replace(",", "")
    if not re.fullmatch(r"(?:\d+(?:\.\d+)?|\.\d+)", digits):
        return None
    decimals = len(digits.split(".", 1)[1]) if "." in digits else 0
    value = float(digits) * multiplier
    if negative:
        value = -value
    return {
        "value": value,
        "tolerance": (10.0 ** -decimals / 2.0) * multiplier,
        "kind": kind,
        "negative": negative,
        "suffix": suffix,
    }


def printed_candidates(raw: Any) -> list[tuple[float, float]]:
    parsed = parse_printed(raw)
    if parsed is None:
        return []
    candidates = [(parsed["value"], parsed["tolerance"])]
    if parsed["kind"] == "percent":
        candidates.append((parsed["value"] / 100.0, parsed["tolerance"] / 100.0))
    elif parsed["suffix"]:
        multiplier = SUFFIXES[parsed["suffix"]]
        candidates.append((parsed["value"] / multiplier, parsed["tolerance"] / multiplier))
    return candidates


def numeric_actual(value: Any) -> list[float]:
    """Return useful numeric interpretations of one Sigma actual cell."""
    if isinstance(value, bool) or value is None:
        return []
    if isinstance(value, (int, float)):
        number = float(value)
        return [number] if math.isfinite(number) else []

    text = str(value).strip()
    if not text:
        return []
    negative = text.startswith("(") and text.endswith(")")
    if negative:
        text = text[1:-1].strip()
    body = re.sub(r"[,$€£¥\s]", "", text)
    percent = body.endswith("%")
    if percent:
        body = body[:-1]
    try:
        number = float(body)
    except ValueError:
        parsed = parse_printed(value)
        if parsed is None:
            return []
        number = parsed["value"]
        return [number]
    if negative:
        number = -number
    return [number, number / 100.0] if percent else [number]


def printed_match(raw: Any, actual: float) -> bool:
    for expected, tolerance in printed_candidates(raw):
        epsilon = 1e-9 * max(abs(expected), 1.0)
        if abs(actual - expected) <= tolerance + epsilon:
            return True
    return False


def relative_distance(raw: Any, actual: float) -> float:
    candidates = printed_candidates(raw)
    if not candidates:
        return math.inf
    return min(
        abs(actual - expected) / max(abs(expected), 1e-9)
        for expected, _ in candidates
    )


def tokens(value: Any) -> list[str]:
    return [
        token
        for token in re.findall(r"[a-z0-9]+", str(value).lower())
        if token not in STOPWORDS
    ]


def element_score(anchor: dict[str, Any], name: str) -> int:
    name_tokens = set(tokens(name))
    if not name_tokens:
        return 0
    hint = str(anchor.get("sigma_element_hint") or "").strip()
    if hint:
        if hint.casefold() == name.strip().casefold():
            return 1000
        return len(set(tokens(hint)) & name_tokens)
    anchor_tokens = set(tokens(anchor.get("panel"))) | set(tokens(anchor.get("label")))
    return len(anchor_tokens & name_tokens)


def ranked_tile_names(anchor: dict[str, Any], names: list[str]) -> list[str]:
    scored = [(name, element_score(anchor, name)) for name in names]
    hits = [
        name
        for name, score in sorted(scored, key=lambda pair: (-pair[1], pair[0]))
        if score > 0
    ]
    return hits + [name for name in names if name not in hits]


def _tile_rows(payload: Any) -> tuple[Any, bool]:
    """Return tile data and whether an explicit data field was present."""
    if not isinstance(payload, dict):
        return payload, True
    for key in ("rows", "actual", "data", "values"):
        if key in payload:
            nested = payload[key]
            if key == "actual" and isinstance(nested, dict):
                return _tile_rows(nested)
            return nested, True
    return None, False


def _data_row_count(data: Any, available: bool) -> int | None:
    if not available or data is None:
        return None
    if isinstance(data, list):
        return len(data)
    return 1


def normalize_actuals(document: Any) -> list[dict[str, Any]]:
    """Normalize parity actuals or an explicit tile envelope."""
    records: list[tuple[str | None, Any]] = []
    if isinstance(document, dict) and "tiles" in document:
        tiles = document["tiles"]
        if isinstance(tiles, dict):
            records = [(str(name), payload) for name, payload in tiles.items()]
        elif isinstance(tiles, list):
            records = [(None, payload) for payload in tiles]
        else:
            raise InputError("actuals.tiles must be an object or array")
    elif isinstance(document, dict) and "elements" in document:
        elements = document["elements"]
        if isinstance(elements, dict):
            records = [(str(name), payload) for name, payload in elements.items()]
        elif isinstance(elements, list):
            records = [(None, payload) for payload in elements]
        else:
            raise InputError("actuals.elements must be an object or array")
    elif isinstance(document, dict):
        ignored = {"metadata", "_metadata", "export_status", "collected_at", "workbook_id"}
        records = [
            (str(name), payload)
            for name, payload in document.items()
            if name not in ignored
        ]
    else:
        raise InputError("Sigma actuals must be a JSON object")

    result = []
    seen_names = set()
    for index, (mapping_name, payload) in enumerate(records):
        metadata = payload if isinstance(payload, dict) else {}
        name = str(metadata.get("name") or metadata.get("title") or mapping_name or "").strip()
        if not name:
            raise InputError(f"Sigma actual tile at index {index} has no name")
        if name in seen_names:
            raise InputError(f"Sigma actual tile name is duplicated: {name!r}")
        seen_names.add(name)
        data, available = _tile_rows(payload)
        result.append(
            {
                "id": str(metadata.get("id") or metadata.get("element_id") or name),
                "name": name,
                "kind": str(metadata.get("kind") or "unknown"),
                "displayed": metadata.get("displayed", True) is not False,
                "is_feeder": metadata.get("is_feeder", False) is True,
                "data_rows": _data_row_count(data, available),
                "actuals_available": available,
                "_data": data,
            }
        )
    if not result:
        raise InputError("Sigma actuals contain no tiles")
    return result


def flatten_cells(value: Any) -> list[Any]:
    if isinstance(value, dict):
        return [cell for nested in value.values() for cell in flatten_cells(nested)]
    if isinstance(value, (list, tuple)):
        return [cell for nested in value for cell in flatten_cells(nested)]
    return [value]


def tile_numbers(tile: dict[str, Any]) -> list[float]:
    return [
        number
        for cell in flatten_cells(tile["_data"])
        for number in numeric_actual(cell)
    ]


def tile_texts(tile: dict[str, Any]) -> set[str]:
    return {
        str(cell).strip().casefold()
        for cell in flatten_cells(tile["_data"])
        if cell is not None and str(cell).strip()
    }


def _explicit_tolerance(
    anchor: dict[str, Any],
    relative_tolerance: float | None,
    absolute_tolerance: float | None,
) -> tuple[float | None, float | None]:
    rel = relative_tolerance
    absolute = absolute_tolerance
    value = anchor.get("tolerance")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        rel = float(value)
    elif isinstance(value, dict):
        if value.get("relative") is not None:
            rel = float(value["relative"])
        if value.get("absolute") is not None:
            absolute = float(value["absolute"])
    if anchor.get("relative_tolerance") is not None:
        rel = float(anchor["relative_tolerance"])
    if anchor.get("absolute_tolerance") is not None:
        absolute = float(anchor["absolute_tolerance"])
    for label, candidate in (("relative", rel), ("absolute", absolute)):
        if candidate is not None and (not math.isfinite(candidate) or candidate < 0):
            raise InputError(f"anchor {anchor.get('id')!r} has invalid {label} tolerance")
    return rel, absolute


def _tolerance_match(
    raw: Any, actual: float, relative: float | None, absolute: float | None
) -> tuple[bool, dict[str, float] | None]:
    for expected, _ in printed_candidates(raw):
        delta = abs(actual - expected)
        allowed = 0.0
        used: dict[str, float] = {}
        if relative is not None:
            allowed += relative * abs(expected)
            used["relative"] = relative
        if absolute is not None:
            allowed += absolute
            used["absolute"] = absolute
        if used and delta <= allowed + 1e-12:
            return True, used
    return False, None


def validate_anchors(document: Any) -> list[dict[str, Any]]:
    if not isinstance(document, dict):
        raise InputError("source anchors must be a JSON object")
    anchors = document.get("anchors")
    if not isinstance(anchors, list) or not anchors:
        raise InputError("source anchors must contain a non-empty anchors array")
    normalized = []
    ids = set()
    for index, anchor in enumerate(anchors):
        if not isinstance(anchor, dict):
            raise InputError(f"anchor at index {index} must be an object")
        anchor_id = str(anchor.get("id") or "").strip()
        if not anchor_id:
            raise InputError(f"anchor at index {index} has no id")
        if anchor_id in ids:
            raise InputError(f"anchor id is duplicated: {anchor_id!r}")
        ids.add(anchor_id)
        raw_value = anchor.get("raw")
        raw = str(raw_value).strip() if raw_value is not None else ""
        if not raw:
            raise InputError(f"anchor {anchor_id!r} has an empty raw value")
        if str(anchor.get("kind") or "") not in NAME_ONLY_KINDS and parse_printed(raw) is None:
            raise InputError(
                f"anchor {anchor_id!r} raw={raw!r} is not a rendered numeric value"
            )
        normalized.append(anchor)
    return normalized


def verify(
    anchors: list[dict[str, Any]],
    tiles: list[dict[str, Any]] | dict[str, Any],
    *,
    relative_tolerance: float | None = None,
    absolute_tolerance: float | None = None,
) -> dict[str, Any]:
    if isinstance(tiles, dict):
        tiles = normalize_actuals(tiles)
    names = [tile["name"] for tile in tiles]
    by_name = {tile["name"]: tile for tile in tiles}
    numbers = {name: tile_numbers(by_name[name]) for name in names}
    texts = {name: tile_texts(by_name[name]) for name in names}
    detail = []
    missing = []

    for anchor in anchors:
        raw = str(anchor["raw"])
        order = ranked_tile_names(anchor, names)
        hint = str(anchor.get("sigma_element_hint") or "").strip()
        scoped = [name for name in order if element_score(anchor, name) > 0] if hint else order
        search_order = scoped or order
        base = {"id": anchor["id"], "raw": raw}
        for key in ("kind", "provenance"):
            if anchor.get(key) is not None:
                base[key] = anchor[key]

        name_only = str(anchor.get("kind") or "") in NAME_ONLY_KINDS
        if name_only:
            wanted = raw.strip().casefold()
            found = next((name for name in search_order if wanted in texts[name]), None)
            if found:
                detail.append({**base, "matched_in": found, "valued": False})
                continue
            miss = {
                **base,
                "label": anchor.get("label"),
                "best_candidate": {
                    "note": "text anchor: label not present in any in-scope Sigma tile"
                },
            }
        else:
            found = next(
                (
                    name
                    for name in search_order
                    if any(printed_match(raw, value) for value in numbers[name])
                ),
                None,
            )
            tolerance_used = None
            if found is None:
                rel, absolute = _explicit_tolerance(
                    anchor, relative_tolerance, absolute_tolerance
                )
                for name in search_order:
                    for value in numbers[name]:
                        matched, used = _tolerance_match(raw, value, rel, absolute)
                        if matched:
                            found = name
                            tolerance_used = used
                            break
                    if found:
                        break
            if found:
                row = {
                    **base,
                    "matched_in": found,
                    "valued": (
                        str(anchor.get("provenance") or "") in VALUED_PROVENANCE
                    ),
                }
                if found != order[0]:
                    row["note"] = f"found outside best-match tile {order[0]!r}"
                if tolerance_used:
                    row["tolerance_used"] = tolerance_used
                    row["drift"] = round(
                        min(relative_distance(raw, value) for value in numbers[found]), 6
                    )
                detail.append(row)
                continue

            best = None
            for name in order:
                if numbers[name]:
                    value = min(numbers[name], key=lambda item: relative_distance(raw, item))
                    best = {
                        "value": value,
                        "element": name,
                        "distance": round(relative_distance(raw, value), 6),
                    }
                    break
            miss = {
                **base,
                "label": anchor.get("label"),
                "best_candidate": best,
            }

        if hint:
            miss["sigma_element_hint"] = hint
        missing.append(miss)

    tile_census = [
        {key: value for key, value in tile.items() if key != "_data"} for tile in tiles
    ]
    displayed_names = {
        tile["name"] for tile in tiles if tile["displayed"] and not tile["is_feeder"]
    }
    empty = [
        tile
        for tile in tile_census
        if tile["displayed"] and not tile["is_feeder"] and tile["data_rows"] == 0
    ]
    unavailable = [
        tile
        for tile in tile_census
        if tile["displayed"]
        and not tile["is_feeder"]
        and not tile["actuals_available"]
    ]
    for row in detail:
        row["in_displayed_tile"] = row["matched_in"] in displayed_names

    matched = len(anchors) - len(missing)
    provenance_census: dict[str, int] = {}
    for anchor in anchors:
        provenance = str(anchor.get("provenance") or "unspecified")
        provenance_census[provenance] = provenance_census.get(provenance, 0) + 1

    matched_names = {
        row["matched_in"]
        for row in detail
        if row.get("kind") not in NAME_ONLY_KINDS
        and row.get("provenance") != "png-eyeball"
    }
    eligible_hints = [
        anchor
        for anchor in anchors
        if anchor.get("sigma_element_hint")
        and str(anchor.get("kind") or "") not in NAME_ONLY_KINDS
        and anchor.get("provenance") != "png-eyeball"
    ]
    covered = {
        name
        for name in displayed_names
        if name in matched_names
        or any(element_score(anchor, name) > 0 for anchor in eligible_hints)
    }

    values_pass = not missing
    tiles_pass = not empty and not unavailable
    return {
        "checked": len(anchors),
        "matched": matched,
        "missing": missing,
        "inconclusive": [],
        "pass": values_pass and tiles_pass,
        "anchor_values_pass": values_pass,
        "matched_via_tolerance": sum(
            1 for row in detail if row.get("tolerance_used")
        ),
        "valued_matched": sum(1 for row in detail if row.get("valued")),
        "provenance_census": provenance_census,
        "detail": detail,
        "tiles": tile_census,
        "dashboard_tiles_empty": [
            {"id": tile["id"], "name": tile["name"], "kind": tile["kind"]}
            for tile in empty
        ],
        "dashboard_tiles_unavailable": [
            {"id": tile["id"], "name": tile["name"], "kind": tile["kind"]}
            for tile in unavailable
        ],
        "tiles_all_nonempty": tiles_pass,
        "anchors_matched_in_displayed": sum(
            1 for row in detail if row["in_displayed_tile"]
        ),
        "anchors_only_in_feeders": [
            row["id"] for row in detail if not row["in_displayed_tile"]
        ],
        "anchor_coverage": {
            "covered": len(covered),
            "displayed": len(displayed_names),
            "uncovered": sorted(displayed_names - covered),
        },
    }


def check_and_stamp_lock(
    lock_path: Path,
    anchors_path: Path,
    anchors: list[dict[str, Any]],
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    current = canonical_anchor_map(anchors)
    changed = []
    if lock_path.is_file():
        lock = read_json(lock_path)
        if not isinstance(lock, dict) or not isinstance(lock.get("anchors"), dict):
            raise InputError(f"source anchor lock is malformed: {lock_path}")
        previous = lock["anchors"]
        changed = [
            {"id": anchor_id, "from": str(previous[anchor_id]), "to": raw}
            for anchor_id, raw in current.items()
            if anchor_id in previous and str(previous[anchor_id]) != raw
        ]
        if changed:
            return lock, changed

    lock = {
        "content_sha256": file_sha256(anchors_path),
        "anchors_sha256": anchor_map_sha256(current),
        "stamped_at": utc_now(),
        "anchor_count": len(anchors),
        "anchors": current,
    }
    write_json(lock_path, lock)
    return lock, changed


def failure_verdict(
    anchors_path: Path, actuals_path: Path, error: str
) -> dict[str, Any]:
    return {
        "checked": 0,
        "matched": 0,
        "missing": [],
        "inconclusive": [],
        "pass": False,
        "errors": [error],
        "source_anchors": str(anchors_path),
        "sigma_actuals": str(actuals_path),
        "verified_at": utc_now(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir")
    parser.add_argument("--anchors", help="default: <workdir>/source-anchors.json")
    parser.add_argument("--actuals", help="default: <workdir>/parity-actuals.json")
    parser.add_argument("--out", help="default: <workdir>/anchors-verdict.json")
    parser.add_argument(
        "--tolerance",
        "--relative-tolerance",
        dest="relative_tolerance",
        type=float,
        help="explicit relative tolerance (0.02 means 2%%); recorded per match",
    )
    parser.add_argument(
        "--absolute-tolerance",
        type=float,
        help="explicit absolute tolerance in actual-value units; recorded per match",
    )
    args = parser.parse_args(argv)

    workdir = Path(args.workdir).expanduser().resolve() if args.workdir else None
    if not workdir and not (args.anchors and args.actuals and args.out):
        parser.error("--workdir is required unless --anchors, --actuals, and --out are all set")
    anchors_path = (
        Path(args.anchors).expanduser().resolve()
        if args.anchors
        else workdir / "source-anchors.json"
    )
    actuals_path = (
        Path(args.actuals).expanduser().resolve()
        if args.actuals
        else workdir / "parity-actuals.json"
    )
    out_path = (
        Path(args.out).expanduser().resolve()
        if args.out
        else workdir / "anchors-verdict.json"
    )
    lock_path = (workdir or anchors_path.parent) / "source-anchors.lock.json"

    if args.relative_tolerance is not None and (
        not math.isfinite(args.relative_tolerance) or args.relative_tolerance < 0
    ):
        parser.error("--tolerance must be a finite non-negative number")
    if args.absolute_tolerance is not None and (
        not math.isfinite(args.absolute_tolerance) or args.absolute_tolerance < 0
    ):
        parser.error("--absolute-tolerance must be a finite non-negative number")

    try:
        source_document = read_json(anchors_path)
        anchors = validate_anchors(source_document)
        lock, changed = check_and_stamp_lock(lock_path, anchors_path, anchors)
        if changed:
            verdict = failure_verdict(
                anchors_path,
                actuals_path,
                "source anchor values changed after they were hash-locked",
            )
            verdict.update(
                {
                    "checked": len(anchors),
                    "source_anchor_lock": str(lock_path),
                    "source_anchors_sha256": file_sha256(anchors_path),
                    "locked_anchors_sha256": lock.get("anchors_sha256"),
                    "anchor_lock_valid": False,
                    "changed_anchors": changed,
                }
            )
            write_json(out_path, verdict)
            print(
                "FAIL: source anchor values changed after first verification",
                file=sys.stderr,
            )
            return 1

        tiles = normalize_actuals(read_json(actuals_path))
        verdict = verify(
            anchors,
            tiles,
            relative_tolerance=args.relative_tolerance,
            absolute_tolerance=args.absolute_tolerance,
        )
        verdict.update(
            {
                "source_anchors": str(anchors_path),
                "source_anchors_sha256": file_sha256(anchors_path),
                "source_anchor_values_sha256": lock["anchors_sha256"],
                "source_anchor_lock": str(lock_path),
                "anchor_lock_valid": True,
                "sigma_actuals": str(actuals_path),
                "sigma_actuals_sha256": file_sha256(actuals_path),
                "verified_at": utc_now(),
            }
        )
        if args.relative_tolerance is not None or args.absolute_tolerance is not None:
            verdict["explicit_tolerance"] = {
                "relative": args.relative_tolerance,
                "absolute": args.absolute_tolerance,
            }
        write_json(out_path, verdict)
    except (OSError, InputError, ValueError, json.JSONDecodeError) as exc:
        verdict = failure_verdict(anchors_path, actuals_path, str(exc))
        try:
            write_json(out_path, verdict)
        except OSError:
            pass
        print(f"FATAL: anchor verification failed: {exc}", file=sys.stderr)
        return 2

    print(
        f"verify-anchors: {verdict['matched']}/{verdict['checked']} anchor(s) "
        f"matched across {len(verdict['tiles'])} Sigma tile(s) -> {out_path}"
    )
    if verdict["pass"]:
        return 0
    for missing in verdict["missing"]:
        print(
            f"MISSING {missing['id']} raw={missing['raw']!r} "
            f"closest={missing.get('best_candidate')!r}",
            file=sys.stderr,
        )
    for tile in verdict["dashboard_tiles_empty"]:
        print(
            f"EMPTY displayed tile {tile['id']} {tile['name']!r}",
            file=sys.stderr,
        )
    for tile in verdict["dashboard_tiles_unavailable"]:
        print(
            f"UNAVAILABLE displayed tile {tile['id']} {tile['name']!r}",
            file=sys.stderr,
        )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
