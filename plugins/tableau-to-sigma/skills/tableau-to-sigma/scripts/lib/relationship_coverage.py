"""Evaluate Tableau object-graph relationship coverage fail-closed."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

OBJECT_GRAPH_RE = re.compile(r"<(?:[^<>\s]*\.true\.\.\.)?object-graph[\s>/]")


def snake_key(key: str) -> str:
    return re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", key).lower()


def snakeize(value: Any) -> Any:
    if isinstance(value, dict):
        return {snake_key(str(key)): snakeize(child) for key, child in value.items()}
    if isinstance(value, list):
        return [snakeize(child) for child in value]
    return value


def blocker(entry: dict, index: int, kind: str, reason: str) -> dict:
    row = {
        "kind": kind,
        "index": index,
        "left": entry.get("left"),
        "right": entry.get("right"),
        "derived_via": entry.get("derived_via"),
        "reason": reason,
        "collisions": entry.get("collisions"),
    }
    return {key: value for key, value in row.items() if value is not None}


def evaluate(
    metadata: Any, source_text: str | None = None, model: Any = None
) -> dict:
    coverage = metadata.get("relationshipCoverage") if isinstance(metadata, dict) else None
    object_graph = bool(OBJECT_GRAPH_RE.search(source_text or ""))
    if not isinstance(coverage, dict):
        blockers = (
            [
                {
                    "kind": "coverage-missing",
                    "reason": (
                        "source contains an object-graph but converter metadata "
                        "has no relationshipCoverage ledger"
                    ),
                }
            ]
            if object_graph
            else []
        )
        return {
            "schema_version": 1,
            "applicable": object_graph,
            "status": "fail" if blockers else "not-applicable",
            "serialized": 0,
            "wired": 0,
            "entries": [],
            "blockers": blockers,
        }

    normalized = snakeize(coverage)
    entries = normalized.get("entries")
    entries = entries if isinstance(entries, list) else []
    serialized = int(normalized.get("serialized") or 0)
    wired = int(normalized.get("wired") or 0)
    blockers: list[dict] = []
    if serialized < 0 or wired < 0 or wired > serialized:
        blockers.append(
            {
                "kind": "invalid-counts",
                "reason": (
                    f"invalid relationship counts: serialized={serialized}, wired={wired}"
                ),
            }
        )
    if len(entries) != serialized:
        blockers.append(
            {
                "kind": "ledger-count-mismatch",
                "reason": (
                    f"relationship ledger has {len(entries)} entries for "
                    f"{serialized} serialized relationships"
                ),
            }
        )
    counted_wired = sum(
        isinstance(entry, dict) and entry.get("derived_via") != "unwired"
        for entry in entries
    )
    if wired != counted_wired:
        blockers.append(
            {
                "kind": "wired-count-mismatch",
                "reason": "wired count disagrees with relationship entry dispositions",
            }
        )
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            blockers.append(
                {
                    "kind": "malformed-entry",
                    "index": index,
                    "reason": "relationship entry is not an object",
                }
            )
            continue
        disposition = str(entry.get("derived_via") or "")
        dropped = int(entry.get("dropped_conditions") or 0)
        if not disposition:
            blockers.append(
                blocker(
                    entry,
                    index,
                    "missing-disposition",
                    "relationship entry has no derived_via disposition",
                )
            )
        elif disposition == "unwired":
            blockers.append(
                blocker(
                    entry,
                    index,
                    "unwired",
                    str(entry.get("reason") or "relationship was not wired"),
                )
            )
        elif entry.get("partial") is True or dropped > 0:
            blockers.append(
                blocker(
                    entry,
                    index,
                    "partial",
                    (
                        f"relationship dropped {max(dropped, 1)} source condition(s); "
                        "a widened join cannot pass"
                    ),
                )
            )
    result = {
        "schema_version": 1,
        "applicable": True,
        "status": "pass" if not blockers else "fail",
        "serialized": serialized,
        "wired": wired,
        "entries": entries,
        "blockers": blockers,
    }
    if isinstance(model, dict):
        relationships = [
            relationship
            for page in model.get("pages") or []
            for element in page.get("elements") or []
            for relationship in element.get("relationships") or []
            if isinstance(relationship, dict)
        ]
        empty = sum(not (relationship.get("keys") or []) for relationship in relationships)
        result["model_relationships"] = len(relationships)
        result["model_relationships_without_keys"] = empty
        if result["applicable"] and len(relationships) != serialized:
            result["blockers"].append(
                {
                    "kind": "model-count-mismatch",
                    "reason": (
                        f"data-model has {len(relationships)} relationships for "
                        f"{serialized} serialized Tableau relationships"
                    ),
                }
            )
        if empty:
            result["blockers"].append(
                {
                    "kind": "model-relationship-without-keys",
                    "reason": f"{empty} data-model relationship(s) have no keys",
                }
            )
        if result["blockers"]:
            result["status"] = "fail"
    return result


def from_files(
    metadata_path: Path,
    source_path: Path | None = None,
    model_path: Path | None = None,
) -> dict:
    raw = metadata_path.read_bytes()
    metadata = json.loads(raw.decode("utf-8-sig"))
    source_text = (
        source_path.read_text(encoding="utf-8-sig")
        if source_path is not None and source_path.is_file()
        else None
    )
    model = (
        json.loads(model_path.read_text(encoding="utf-8-sig"))
        if model_path is not None and model_path.is_file()
        else None
    )
    result = evaluate(metadata, source_text, model)
    coverage_source = json.dumps(
        metadata.get("relationshipCoverage") if isinstance(metadata, dict) else None,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    result["source"] = metadata_path.name
    result["source_sha256"] = hashlib.sha256(coverage_source).hexdigest()
    return result
