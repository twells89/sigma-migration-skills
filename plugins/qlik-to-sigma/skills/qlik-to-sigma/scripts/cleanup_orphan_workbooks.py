#!/usr/bin/env python3
"""Safely review and delete retry workbooks recorded in a migration ledger."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from lib import sigma_rest

ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")


def now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def load_ledger(path: Path) -> list[dict[str, Any]]:
    records = []
    for index, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"{path.name} line {index}: {exc}") from exc
        if (
            not isinstance(record, dict)
            or not isinstance(record.get("id"), str)
            or not ID_PATTERN.fullmatch(record["id"])
        ):
            raise ValueError(
                f"{path.name} line {index} must contain a safe string id"
            )
        records.append(record)
    return records


def inspect_workbook(
    workbook_id: str, requester: Callable[[str, str], Any]
) -> dict[str, Any]:
    workbook = requester("get", f"/v2/workbooks/{workbook_id}") or {}
    file_row = requester("get", f"/v2/files/{workbook_id}") or {}
    if workbook.get("workbookId") != workbook_id:
        raise ValueError(
            f"workbook API returned {workbook.get('workbookId')!r}, "
            f"expected {workbook_id}"
        )
    if file_row.get("id") != workbook_id:
        raise ValueError(
            f"file API returned {file_row.get('id')!r}, expected {workbook_id}"
        )
    if file_row.get("type") != "workbook":
        raise ValueError(
            f"file {workbook_id} is type {file_row.get('type')!r}, not workbook"
        )
    if (
        workbook.get("workbookUrlId")
        and file_row.get("urlId")
        and workbook["workbookUrlId"] != file_row["urlId"]
    ):
        raise ValueError(f"workbook/file URL identifiers disagree for {workbook_id}")
    return {
        "id": workbook_id,
        "name": file_row.get("name") or workbook.get("name"),
        "path": file_row.get("path") or workbook.get("path"),
        "parentId": file_row.get("parentId"),
        "ownerId": file_row.get("ownerId") or workbook.get("ownerId"),
        "createdBy": file_row.get("createdBy") or workbook.get("createdBy"),
        "createdAt": file_row.get("createdAt") or workbook.get("createdAt"),
        "updatedAt": file_row.get("updatedAt") or workbook.get("updatedAt"),
    }


def same_context(candidate: dict[str, Any], kept: dict[str, Any]) -> bool:
    return all(
        candidate.get(key)
        and kept.get(key)
        and candidate[key] == kept[key]
        for key in ("parentId", "ownerId", "createdBy")
    )


def write_marker(workdir: Path, value: dict[str, Any]) -> None:
    (workdir / "cleanup-marker.json").write_text(
        json.dumps(value, indent=2) + "\n", encoding="utf-8"
    )


def cleanup(
    workdir: Path,
    keep_id: str | None,
    *,
    dry_run: bool,
    requester: Callable[[str, str], Any],
    input_stream: Any = sys.stdin,
    output_stream: Any = sys.stdout,
    error_stream: Any = sys.stderr,
) -> int:
    ledger_path = workdir / "posted-workbooks.jsonl"
    if not ledger_path.is_file():
        print(
            f"[OK] no posted-workbooks.jsonl at {ledger_path} — nothing to clean up",
            file=output_stream,
        )
        return 0
    try:
        records = load_ledger(ledger_path)
    except (OSError, ValueError) as exc:
        print(f"REFUSED: {exc}", file=error_stream)
        return 2
    unique_ids = list(dict.fromkeys(row["id"] for row in records))
    if not unique_ids:
        print("[OK] posted-workbooks.jsonl is empty — nothing to clean up", file=output_stream)
        return 0
    if len(unique_ids) == 1:
        if keep_id and keep_id != unique_ids[0]:
            print(
                f"REFUSED: --keep {keep_id} is not the ledger workbook {unique_ids[0]}",
                file=error_stream,
            )
            return 2
        kept = keep_id or unique_ids[0]
        write_marker(
            workdir,
            {
                "ran_at": now(),
                "kept": kept,
                "deleted": [],
                "failed": [],
                "skipped": [],
                "dry_run": dry_run,
            },
        )
        print(
            f"[OK] only one POSTed workbook ({kept}) — no orphans to clean up",
            file=output_stream,
        )
        return 0
    if (
        not keep_id
        or not ID_PATTERN.fullmatch(keep_id)
        or keep_id not in unique_ids
    ):
        print(
            "REFUSED: --keep must be a safe ID present in posted-workbooks.jsonl",
            file=error_stream,
        )
        return 2
    if not dry_run and not getattr(input_stream, "isatty", lambda: False)():
        print(
            "REFUSED: workbook deletion requires an interactive terminal.",
            file=error_stream,
        )
        return 2
    try:
        kept = inspect_workbook(keep_id, requester)
    except (ValueError, sigma_rest.SigmaError) as exc:
        print(
            f"REFUSED: could not validate the workbook to keep: {exc}",
            file=error_stream,
        )
        return 2
    print(f"KEEPING (explicit --keep): {kept.get('name')!r}", file=output_stream)
    deleted, failed, skipped, would_delete = [], [], [], []
    for workbook_id in (value for value in unique_ids if value != keep_id):
        try:
            candidate = inspect_workbook(workbook_id, requester)
            if not same_context(candidate, kept):
                raise ValueError(
                    "folder, owner, or creator differs from the kept workbook"
                )
        except (ValueError, sigma_rest.SigmaError) as exc:
            print(f"  [REFUSED] {workbook_id}: {exc}", file=error_stream)
            failed.append({"id": workbook_id, "reason": str(exc)})
            continue
        print(
            f"\nCANDIDATE:\n  name: {candidate.get('name')!r}\n"
            f"  id: {workbook_id}\n  path: {candidate.get('path')}\n"
            f"  created: {candidate.get('createdAt')}\n"
            f"  updated: {candidate.get('updatedAt')}",
            file=output_stream,
        )
        if dry_run:
            print("  [DRY-RUN] validated; no deletion performed", file=output_stream)
            would_delete.append(candidate)
            continue
        print(
            "Type the full workbook ID to delete this candidate, "
            "or press Enter to keep it:\n> ",
            end="",
            file=output_stream,
            flush=True,
        )
        if input_stream.readline().strip() != workbook_id:
            skipped.append(
                {"id": workbook_id, "reason": "user did not type the full workbook ID"}
            )
            print(f"  [KEPT] {workbook_id}", file=output_stream)
            continue
        try:
            requester("delete", f"/v2/files/{workbook_id}")
            deleted.append({"id": workbook_id, "status": 200})
            print(f"  [deleted] {workbook_id}", file=output_stream)
        except sigma_rest.SigmaError as exc:
            if "-> 404" in str(exc).splitlines()[0]:
                deleted.append({"id": workbook_id, "status": 404})
                print(
                    f"  [deleted] {workbook_id} (already absent)",
                    file=output_stream,
                )
            else:
                failed.append({"id": workbook_id, "reason": str(exc)})
                print(f"  [FAIL] {workbook_id}: {exc}", file=error_stream)
    marker = {
        "ran_at": now(),
        "kept": keep_id,
        "deleted": deleted,
        "failed": failed,
        "skipped": skipped,
        "dry_run": dry_run,
    }
    if dry_run:
        marker["would_delete"] = would_delete
    write_marker(workdir, marker)
    return 0 if not failed and (dry_run or not skipped) else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--keep")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--allow-empty-log", action="store_true")
    args = parser.parse_args(argv)
    return cleanup(
        Path(args.workdir).expanduser().resolve(),
        args.keep,
        dry_run=args.dry_run,
        requester=lambda method, path: sigma_rest.request(method, path),
    )


if __name__ == "__main__":
    raise SystemExit(main())
