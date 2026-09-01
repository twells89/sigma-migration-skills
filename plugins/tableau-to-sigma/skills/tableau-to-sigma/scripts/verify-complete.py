#!/usr/bin/env python3
"""Fail-closed completion gate for the Tableau Python migration path."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


def load(path: Path) -> dict:
    with path.open(encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def evaluate(workdir: Path, blind_grade: Path) -> dict:
    failures = []
    required = {
        "mission": workdir / "mission.json",
        "data_model_readback": workdir / "datamodel-readback-verdict.json",
        "workbook_readback": workdir / "workbook-readback-verdict.json",
        "parity": workdir / "parity-final.json",
        "visual_similarity": workdir / "visual-similarity-final.json",
        "semantic_edits": workdir / "semantic-edits.json",
        "data_model_ids": workdir / "dm-ids.json",
        "workbook_ids": workdir / "wb-ids.json",
        "blind_grade": blind_grade,
    }
    documents = {}
    for name, path in required.items():
        if not path.is_file():
            failures.append(f"{name}: missing {path.name}")
            continue
        try:
            documents[name] = load(path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            failures.append(f"{name}: unreadable ({exc})")

    mission = documents.get("mission") or {}
    inferred = [
        key
        for key, value in mission.items()
        if isinstance(value, dict) and value.get("provenance") != "stated"
    ]
    if inferred:
        failures.append("mission has unstated field(s): " + ", ".join(inferred))

    for key in ("data_model_readback", "workbook_readback"):
        if documents.get(key, {}).get("pass") is not True:
            failures.append(f"{key}: readback verdict is not pass")
    if documents.get("parity", {}).get("match") is not True:
        failures.append("parity: numeric source/target comparison failed")
    if documents.get("visual_similarity", {}).get("status") != "PASS":
        failures.append("visual_similarity: machine floor failed")
    if documents.get("semantic_edits", {}).get("match") is not True:
        failures.append("semantic_edits: structural proof missing or failed")
    blind = documents.get("blind_grade") or {}
    for path_key, hash_key in (
        ("source_png", "source_sha256"),
        ("target_png", "target_sha256"),
    ):
        image_path = Path(str(blind.get(path_key) or ""))
        expected_hash = blind.get(hash_key)
        if not image_path.is_file() or not expected_hash:
            failures.append(f"blind_grade: missing bound {path_key}")
        elif sha256(image_path) != expected_hash:
            failures.append(f"blind_grade: stale {path_key} hash")
    failed_dimensions = [
        name
        for name, value in (blind.get("dimensions") or {}).items()
        if value.get("verdict") != "pass"
    ]
    if blind.get("verdict") != "pass" or failed_dimensions:
        failures.append(
            "blind_grade: visual fidelity failed"
            + (f" ({', '.join(failed_dimensions)})" if failed_dimensions else "")
        )

    dm_ids = documents.get("data_model_ids") or {}
    wb_ids = documents.get("workbook_ids") or {}
    return {
        "status": "GREEN" if not failures else "BLOCKED",
        "complete": not failures,
        "dataModelId": dm_ids.get("dataModelId"),
        "workbookId": wb_ids.get("workbookId"),
        "failures": failures,
        "gates": {
            "mission": not inferred and "mission" in documents,
            "data_model_readback": documents.get("data_model_readback", {}).get("pass") is True,
            "workbook_readback": documents.get("workbook_readback", {}).get("pass") is True,
            "numeric_parity": documents.get("parity", {}).get("match") is True,
            "visual_floor": documents.get("visual_similarity", {}).get("status") == "PASS",
            "blind_visual_grade": blind.get("verdict") == "pass" and not failed_dimensions,
            "semantic_edit_proof": documents.get("semantic_edits", {}).get("match") is True,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--blind-grade", required=True)
    args = parser.parse_args()
    workdir = Path(args.workdir).expanduser().resolve()
    try:
        result = evaluate(workdir, Path(args.blind_grade).expanduser().resolve())
        (workdir / "migration-result.json").write_text(
            json.dumps(result, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FATAL: completion gate could not run: {exc}", file=sys.stderr)
        return 2
    if not result["complete"]:
        print("BLOCKED: Tableau Python migration is not complete", file=sys.stderr)
        for failure in result["failures"]:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(
        f"DONE: GREEN dataModelId={result['dataModelId']} "
        f"workbookId={result['workbookId']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
