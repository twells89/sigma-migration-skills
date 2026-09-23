#!/usr/bin/env python3
"""Mechanized layout-quality lint for Sigma workbook code representation."""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

from lib.code_rep import document, workbook_elements_with_pages

RAW_ID_NAME = re.compile(r"^(?:[0-9a-f]{12,}|el-[0-9a-f]+)$", re.I)
GENERIC_HEADER = re.compile(r"^(?:page|sheet|dashboard)\s*\d+$", re.I)
DEAD_ZONE_MAX = 0.25
GRID_COLS = 24
MIN_BAND_FILL = 0.60
KPI_BAND_MAX_TILES = 4
KIND_MIN_ROWS = {
    "kpi-chart": 4,
    "chart": 8,
    "table": 10,
    "pivot-table": 10,
    "control": 2,
    "text": 2,
    "divider": 1,
    "button": 2,
}


def min_rows_for(kind: str) -> int:
    if kind in KIND_MIN_ROWS:
        return KIND_MIN_ROWS[kind]
    if kind.endswith("-chart"):
        return KIND_MIN_ROWS["chart"]
    return KIND_MIN_ROWS["text"]


def _range(value: Any) -> tuple[int, int]:
    match = re.match(r"\s*(\d+)\s*/\s*(\d+)\s*$", str(value or ""))
    return (int(match.group(1)), int(match.group(2))) if match else (0, 0)


def _layout_root(layout: str) -> ET.Element:
    body = re.sub(r"^\s*<\?xml[^>]*\?>", "", layout or "").strip()
    try:
        return ET.fromstring(f"<Root>{body}</Root>")
    except ET.ParseError:
        return ET.Element("Root")


def _grid_columns(node: ET.Element) -> int:
    template = node.attrib.get("gridTemplateColumns", "").strip()
    repeated = re.search(r"repeat\(\s*(\d+)", template)
    if repeated:
        return min(max(int(repeated.group(1)), 1), GRID_COLS * 4)
    if template:
        return max(len(template.split()), 1)
    return GRID_COLS


def _plain_text(body: Any) -> str:
    text = re.sub(r"<[^>]+>", "", str(body or ""))
    text = re.sub(r"^#+\s*", "", text)
    return re.sub(r"[*_`]", "", text).strip()


def _children(container: ET.Element) -> list[tuple[str, int, int, int, int]]:
    rows = []
    for child in list(container):
        if child.tag not in {"Element", "LayoutElement", "Container", "GridContainer"}:
            continue
        c0, c1 = _range(child.attrib.get("gridColumn"))
        r0, r1 = _range(child.attrib.get("gridRow"))
        rows.append((child.attrib.get("elementId", ""), c0, c1, r0, r1))
    return rows


def lint(spec: dict[str, Any]) -> list[str]:
    doc = document(spec)
    violations: list[str] = []
    element_kind: dict[str, str] = {}
    element_body: dict[str, Any] = {}
    for element, page in workbook_elements_with_pages(doc):
        element_id = str(element.get("id") or element.get("elementId") or "")
        element_kind[element_id] = str(element.get("kind") or "")
        element_body[element_id] = element.get("body")
        name = str(element.get("name") or "")
        if name and RAW_ID_NAME.fullmatch(name):
            page_name = (page or {}).get("name") or (page or {}).get("id") or "(unplaced: missing from layout)"
            violations.append(
                f"raw-id display name: element {element_id} ({element.get('kind')}) "
                f"on page '{page_name}' is named {name!r}"
            )

    root = _layout_root(str(doc.get("layout") or ""))
    for page in root.findall(".//Page"):
        page_id = page.attrib.get("id", "")
        if "data" in page_id.lower():
            continue
        entries = [
            node
            for node in list(page)
            if node.tag in {"Container", "GridContainer", "Element", "LayoutElement"}
        ]
        if not entries:
            continue
        bands = [
            node for node in page.iter()
            if node.tag in {"Container", "GridContainer"}
        ]
        if bands:
            band_starts = [_range(node.attrib.get("gridRow"))[0] for node in entries if node.tag in {"Container", "GridContainer"}]
            first_band = min((value for value in band_starts if value > 0), default=None)
            for node in entries:
                element_id = node.attrib.get("elementId", "")
                row_start, _ = _range(node.attrib.get("gridRow"))
                if (
                    node.tag in {"Element", "LayoutElement"}
                    and element_kind.get(element_id) == "control"
                    and (first_band is None or row_start >= first_band)
                ):
                    violations.append(
                        f"orphan control: {element_id} sits OUTSIDE every Container "
                        f"on page {page_id}"
                    )
        header = min(
            (
                node
                for node in bands
                if _range(node.attrib.get("gridRow"))[0] <= 1
            ),
            key=lambda node: _range(node.attrib.get("gridRow"))[0],
            default=None,
        )
        if header is not None:
            for element_id, *_ in _children(header):
                if element_kind.get(element_id) != "text":
                    continue
                visible = _plain_text(element_body.get(element_id))
                if GENERIC_HEADER.fullmatch(visible):
                    violations.append(
                        f"generic header title: the header band "
                        f"({header.attrib.get('elementId')}) on page {page_id} "
                        f"renders {visible!r}"
                    )
        for band in bands:
            children = _children(band)
            child_kinds = [element_kind.get(row[0]) for row in children]
            if (
                children
                and len(children) <= KPI_BAND_MAX_TILES
                and all(kind == "kpi-chart" for kind in child_kinds)
            ):
                continue
            if children and all(kind == "control" for kind in child_kinds):
                continue
            columns = _grid_columns(band)
            covered = set()
            for _, start, end, _, _ in children:
                covered.update(range(max(start, 1), min(end, columns + 1)))
            fill = len(covered) / columns
            if fill < MIN_BAND_FILL:
                child_summary = (
                    f"{len(children)} element(s)"
                    if children
                    else "no children"
                )
                violations.append(
                    f"band under-filled: container {band.attrib.get('elementId')} "
                    f"on page {page_id} — {child_summary} cover "
                    f"{len(covered)} of {columns} grid columns "
                    f"({fill * 100:.0f}% < {MIN_BAND_FILL * 100:.0f}% required)"
                )
        tiles: list[tuple[str, int, int]] = []
        for node in entries:
            if node.tag in {"Element", "LayoutElement"}:
                r0, r1 = _range(node.attrib.get("gridRow"))
                tiles.append((node.attrib.get("elementId", ""), r0, r1))
        for band in bands:
            for element_id, _, _, r0, r1 in _children(band):
                tiles.append((element_id, r0, r1))
        seen_tiles = set()
        for element_id, row_start, row_end in tiles:
            key = (element_id, row_start, row_end)
            if key in seen_tiles:
                continue
            seen_tiles.add(key)
            kind = element_kind.get(element_id)
            if not kind or kind == "container":
                continue
            span = max(row_end - row_start, 0)
            minimum = min_rows_for(kind)
            if span < minimum:
                violations.append(
                    f"tile below minimum height: element {element_id} ({kind}) on "
                    f"page {page_id} spans {span} grid row(s) (< {minimum} required)"
                )
        spans = [
            _range(node.attrib.get("gridRow"))
            for node in entries
            if _range(node.attrib.get("gridRow"))[0] > 0
        ]
        if len(spans) >= 2:
            first = min(row[0] for row in spans)
            last = max(max(row[1], row[0] + 1) for row in spans)
            total = last - first
            covered_rows = {
                row
                for start, end in spans
                for row in range(start, max(end, start + 1))
            }
            empty = total - len(covered_rows)
            if total > 0 and empty / total > DEAD_ZONE_MAX:
                violations.append(
                    f"dead zone: page {page_id} has {empty} of {total} grid rows "
                    f"empty ({empty / total * 100:.0f}% > "
                    f"{DEAD_ZONE_MAX * 100:.0f}% allowed)"
                )
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec")
    parser.add_argument("--json-out")
    args = parser.parse_args(argv)
    try:
        spec = json.loads(Path(args.spec).read_text(encoding="utf-8-sig"))
        violations = lint(spec)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"layout lint: {exc}", file=sys.stderr)
        return 2
    if args.json_out:
        Path(args.json_out).write_text(
            json.dumps(
                {
                    "status": "PASS" if not violations else "FAIL",
                    "violations": violations,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
    if not violations:
        print("layout lint: clean")
        return 0
    print(f"layout lint: {len(violations)} violation(s):", file=sys.stderr)
    for violation in violations:
        print(f"  - {violation}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
