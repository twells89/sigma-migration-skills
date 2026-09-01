#!/usr/bin/env python3
"""Bind a validated workbook template to live data-model and folder IDs.

Customer-specific titles, formulas, and layout stay in the workdir template;
the reusable plugin contains only placeholder binding and structural guards.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

PLACEHOLDERS = {
    "__DATA_MODEL_ID__": "data_model_id",
    "__DATA_MODEL_ELEMENT_ID__": "element_id",
    "__FOLDER_ID__": "folder_id",
}


def bind(value, replacements):
    if isinstance(value, dict):
        return {key: bind(item, replacements) for key, item in value.items()}
    if isinstance(value, list):
        return [bind(item, replacements) for item in value]
    if isinstance(value, str):
        for placeholder, replacement in replacements.items():
            value = value.replace(placeholder, replacement)
    return value


def validate(spec: dict) -> None:
    if not spec.get("name") or not spec.get("folderId"):
        raise ValueError("template must produce name and folderId")
    document = spec.get("document")
    if not isinstance(document, dict):
        raise ValueError("template must contain document")
    if document.get("schemaVersion") != 1 or document.get("kind") != "workbook":
        raise ValueError("document must use schemaVersion=1 and kind=workbook")
    elements = document.get("elements")
    pages = document.get("pages")
    layout = document.get("layout")
    if not isinstance(elements, list) or not isinstance(pages, list) or not layout:
        raise ValueError("document requires elements, pages, and layout")
    element_ids = [element.get("id") for element in elements]
    if any(not value for value in element_ids) or len(element_ids) != len(set(element_ids)):
        raise ValueError("element IDs must be non-empty and unique")
    column_ids = [
        column.get("id")
        for element in elements
        for column in element.get("columns") or []
    ]
    if any(not value for value in column_ids) or len(column_ids) != len(set(column_ids)):
        raise ValueError("column IDs must be non-empty and unique")
    for element in elements:
        for column in element.get("columns") or []:
            if not column.get("formula"):
                raise ValueError(f"{element['id']}/{column.get('id')} has no formula")
    placed = re.findall(r'elementId="([^"]+)"', layout)
    if sorted(placed) != sorted(element_ids):
        raise ValueError("layout must place every element exactly once")
    serialized = json.dumps(spec)
    unresolved = sorted(
        placeholder for placeholder in PLACEHOLDERS if placeholder in serialized
    )
    if unresolved:
        raise ValueError("unresolved placeholder(s): " + ", ".join(unresolved))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", required=True)
    parser.add_argument("--data-model-id", required=True)
    parser.add_argument("--element-id", required=True)
    parser.add_argument("--folder-id", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        with Path(args.template).open(encoding="utf-8-sig") as handle:
            template = json.load(handle)
        replacements = {
            placeholder: str(getattr(args, attribute))
            for placeholder, attribute in PLACEHOLDERS.items()
        }
        result = bind(template, replacements)
        validate(result)
        Path(args.out).write_text(
            json.dumps(result, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FATAL: workbook template refused: {exc}", file=sys.stderr)
        return 1
    print(f"wrote {args.out} ({len(result['document']['elements'])} elements)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
