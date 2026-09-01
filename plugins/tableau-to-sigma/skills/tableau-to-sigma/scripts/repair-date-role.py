#!/usr/bin/env python3
"""Repair a computed Tableau date relationship using a proven date-key role.

This is deliberately explicit and fail-closed. It only rewrites a disconnected
date element when a warehouse equivalence proof with match=true is supplied.
"""

from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path


def load_object(path: str) -> dict:
    with Path(path).open(encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return value


def elements(model: dict) -> list[dict]:
    return [
        element
        for page in model.get("pages") or []
        for element in page.get("elements") or []
        if isinstance(element, dict)
    ]


def matches_element(element: dict, token: str) -> bool:
    if element.get("name") == token:
        return True
    path = (element.get("source") or {}).get("path") or []
    return bool(path and path[-1] == token)


def find_one(rows: list[dict], token: str, label: str) -> dict:
    found = [row for row in rows if matches_element(row, token)]
    if len(found) != 1:
        raise ValueError(f"expected one {label} matching {token!r}, found {len(found)}")
    return found[0]


def find_column(element: dict, name: str) -> dict:
    found = [
        column
        for column in element.get("columns") or []
        if str(column.get("name", "")).strip().casefold() == name.strip().casefold()
    ]
    if len(found) != 1:
        raise ValueError(
            f"expected one {name!r} column on {element.get('name') or element.get('id')}, "
            f"found {len(found)}"
        )
    return found[0]


def repair(
    model: dict,
    metadata: dict,
    proof: dict,
    *,
    source_element: str,
    source_key: str,
    source_key_formula: str | None,
    template_element: str,
    replace_element: str,
    role_name: str,
) -> tuple[dict, dict, dict]:
    if proof.get("match") is not True:
        raise ValueError("equivalence proof must contain match=true")
    if not proof.get("checks"):
        raise ValueError("equivalence proof must contain measured checks")

    model = copy.deepcopy(model)
    metadata = copy.deepcopy(metadata)
    rows = elements(model)
    source = find_one(rows, source_element, "source element")
    template = find_one(rows, template_element, "date template")
    replaced = find_one(rows, replace_element, "element to replace")
    try:
        source_column = find_column(source, source_key)
    except ValueError:
        if not source_key_formula:
            raise
        source_column = {
            "id": "PyDateKey1",
            "name": source_key,
            "formula": source_key_formula,
        }
        source.setdefault("columns", []).append(source_column)
        source.setdefault("order", []).append(source_column["id"])

    replacement_id = replaced["id"]
    replacement = copy.deepcopy(template)
    replacement["id"] = replacement_id
    replacement["name"] = role_name
    id_map = {}
    for index, column in enumerate(replacement.get("columns") or [], 1):
        old_id = column["id"]
        new_id = f"PyDate{index:04d}"
        id_map[old_id] = new_id
        column["id"] = new_id
    replacement["order"] = [
        id_map[column_id]
        for column_id in template.get("order") or []
        if column_id in id_map
    ]
    target_column = find_column(replacement, "Date Key")

    for page in model.get("pages") or []:
        page["elements"] = [
            replacement if element is replaced else element
            for element in page.get("elements") or []
        ]

    relationships = source.setdefault("relationships", [])
    relationships[:] = [
        relationship
        for relationship in relationships
        if relationship.get("targetElementId") != replacement_id
    ]
    relationships.append(
        {
            "id": "PyDateRel1",
            "targetElementId": replacement_id,
            "keys": [
                {
                    "sourceColumnId": source_column["id"],
                    "targetColumnId": target_column["id"],
                }
            ],
            "name": role_name,
            "derivedVia": "equivalence-proof",
        }
    )

    unsupported_names = {
        f"Object-model relationship {source_element} ↔ {replace_element} (computed-only-key)",
        f"Object-model table {replace_element} disconnected",
    }
    metadata["workbookPatterns"] = [
        pattern
        for pattern in metadata.get("workbookPatterns") or []
        if pattern.get("name") not in unsupported_names
    ]
    warnings = []
    for warning in metadata.get("warnings") or []:
        if (
            source_element in warning
            and replace_element in warning
            and ("computed key" in warning or "NOT wired" in warning)
        ):
            continue
        if replace_element in warning and ("DISCONNECTED" in warning or "NO wired" in warning):
            continue
        warnings.append(warning)
    warnings.append(
        f"ℹ Repaired {role_name}: {source_element}.{source_key} → "
        f"{template_element}.Date Key under measured equivalence proof."
    )
    metadata["warnings"] = warnings
    coverage = metadata.get("relationshipCoverage")
    if isinstance(coverage, dict):
        entries = []
        for entry in coverage.get("entries") or []:
            if {
                entry.get("left"),
                entry.get("right"),
            } == {source_element, replace_element}:
                entries.append(
                    {
                        "left": source_element,
                        "right": role_name,
                        "derivedVia": "equivalence-proof",
                        "keyCount": 1,
                    }
                )
            else:
                entries.append(entry)
        coverage["entries"] = entries
        coverage["wired"] = sum(
            1 for entry in entries if entry.get("derivedVia") != "unwired"
        )
    metadata["model"] = model

    report = {
        "kind": "date-role-repair",
        "source_element": source_element,
        "source_key": source_key,
        "source_key_formula": source_key_formula,
        "replaced_element": replace_element,
        "replacement_role": role_name,
        "template_element": template_element,
        "proof": proof,
        "match": True,
    }
    return model, metadata, report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True)
    parser.add_argument("--meta", required=True)
    parser.add_argument("--proof", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--out-meta", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--source-element", required=True)
    parser.add_argument("--source-key", required=True)
    parser.add_argument(
        "--source-key-formula",
        help="explicit discovered warehouse formula when the converter omitted the key column",
    )
    parser.add_argument("--template-element", required=True)
    parser.add_argument("--replace-element", required=True)
    parser.add_argument("--role-name", required=True)
    args = parser.parse_args()
    try:
        model, metadata, report = repair(
            load_object(args.spec),
            load_object(args.meta),
            load_object(args.proof),
            source_element=args.source_element,
            source_key=args.source_key,
            source_key_formula=args.source_key_formula,
            template_element=args.template_element,
            replace_element=args.replace_element,
            role_name=args.role_name,
        )
        for path, value in (
            (args.out, model),
            (args.out_meta, metadata),
            (args.report, report),
        ):
            Path(path).write_text(
                json.dumps(value, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FATAL: date-role repair refused: {exc}", file=sys.stderr)
        return 1
    print(f"wrote {args.out}, {args.out_meta}, and {args.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
