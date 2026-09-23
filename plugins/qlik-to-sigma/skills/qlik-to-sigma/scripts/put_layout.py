#!/usr/bin/env python3
"""GET a workbook spec, apply layout XML, inject sidecar elements, and PUT it."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Callable

from lib import sigma_rest
from lib.code_rep import canonicalize_layout, document, metadata, wrap


def apply_layout(
    raw_spec: dict[str, Any],
    xml: str,
    injected: dict[str, list[dict[str, Any]]] | None = None,
    warn: Callable[[str], None] | None = None,
) -> tuple[dict[str, Any], int]:
    if re.search(r'elementId=""', xml):
        raise ValueError("empty elementId in layout XML")
    spec = dict(document(raw_spec))
    spec["layout"] = xml
    count = 0
    if injected:
        spec.setdefault("elements", [])
        existing = {
            element.get("id")
            for element in spec["elements"]
            if isinstance(element, dict) and element.get("id")
        }
        page_ids = {
            page.get("id")
            for page in spec.get("pages") or []
            if isinstance(page, dict)
        }
        for page_id, elements in injected.items():
            if page_id not in page_ids:
                if warn:
                    warn(f"elements sidecar references unknown page {page_id!r} — skipped")
                continue
            for element in elements:
                element_id = element.get("id") if isinstance(element, dict) else None
                if not element_id or element_id in existing:
                    continue
                spec["elements"].append(element)
                existing.add(element_id)
                count += 1
    return wrap(spec), count


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workbook", required=True)
    parser.add_argument("--layout", required=True)
    parser.add_argument("--elements")
    args = parser.parse_args(argv)
    layout_path = Path(args.layout)
    try:
        xml = layout_path.read_text(encoding="utf-8")
        raw_spec = sigma_rest.request(
            "get", f"/v2/workbooks/{args.workbook}/spec"
        )
        sidecar = Path(args.elements) if args.elements else Path(str(layout_path) + ".elements.json")
        injected = (
            json.loads(sidecar.read_text(encoding="utf-8-sig"))
            if sidecar.is_file()
            else None
        )
        payload, count = apply_layout(
            raw_spec,
            xml,
            injected,
            warn=lambda message: print(f"WARN: {message}", file=sys.stderr),
        )
        response = sigma_rest.request(
            "put",
            f"/v2/workbooks/{args.workbook}/spec",
            body=json.dumps(payload),
            accept="*/*",
        )
        check = sigma_rest.request("get", f"/v2/workbooks/{args.workbook}/spec")
        expected_layout = canonicalize_layout(xml)
        if document(check).get("layout") != expected_layout:
            raise ValueError("layout PUT did not survive workbook spec readback")
    except (OSError, ValueError, json.JSONDecodeError, sigma_rest.SigmaError) as exc:
        print(f"put-layout: {exc}", file=sys.stderr)
        return 1
    if injected:
        print(f"injected {count} container/header element(s) from {sidecar}")
    workbook_id = metadata(check).get("workbookId") or args.workbook
    suffix = "" if response else " (empty response; confirmed by readback)"
    print(f"PUT ok: workbookId={workbook_id}{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
