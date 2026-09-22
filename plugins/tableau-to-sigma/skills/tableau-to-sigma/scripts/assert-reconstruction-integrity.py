#!/usr/bin/env python3
"""Tableau-local completion gate for reconstructed dashboard residue."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


FAMILY_MAP = {
    "bar": "bar",
    "bar-chart": "bar",
    "column": "bar",
    "column-chart": "bar",
    "line": "line",
    "line-chart": "line",
    "sparkline": "line",
    "area": "area",
    "area-chart": "area",
    "combo": "combo",
    "combo-chart": "combo",
    "dual-axis": "combo",
    "scatter": "scatter",
    "scatter-chart": "scatter",
    "bubble": "scatter",
    "pie": "pie",
    "pie-chart": "pie",
    "donut": "pie",
    "donut-chart": "pie",
    "kpi": "kpi",
    "kpi-chart": "kpi",
    "single-value": "kpi",
    "big-number": "kpi",
    "map": "map",
    "region-map": "map",
    "point-map": "map",
    "table": "table",
    "pivot-table": "table",
    "pivot": "table",
    "crosstab": "table",
    "text-table": "table",
    "grid": "table",
}


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path} is not valid JSON: {exc}") from exc


def norm(value: Any) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value or "").strip().lower())


def workbook_elements(readback: Any) -> list[dict[str, Any]]:
    if not isinstance(readback, dict):
        return []
    document = readback.get("document")
    document = document if isinstance(document, dict) else readback
    elements = document.get("elements")
    if isinstance(elements, list):
        return [element for element in elements if isinstance(element, dict)]
    return [
        element
        for page in document.get("pages", [])
        if isinstance(page, dict)
        for element in page.get("elements", [])
        if isinstance(element, dict)
    ]


def evaluate(workdir: Path) -> dict[str, Any]:
    control_blockers: list[dict[str, Any]] = []
    census_paths = sorted(workdir.glob("*-controls-coverage.json"))
    census_path = census_paths[0] if census_paths else None
    if census_path:
        census = read_json(census_path)
        rows = census.get("detail") if isinstance(census, dict) else None
        if not isinstance(rows, list):
            raise ValueError(f"{census_path} is malformed (expected detail array)")
        waivers_path = workdir / "controls-waivers.json"
        waivers = read_json(waivers_path) if waivers_path.exists() else []
        waivers = waivers.get("waivers", []) if isinstance(waivers, dict) else waivers
        valid_waivers = [
            waiver
            for waiver in waivers
            if isinstance(waiver, dict)
            and str(waiver.get("control") or waiver.get("name") or "").strip()
            and str(waiver.get("reason") or "").strip()
        ]
        for row in rows:
            if not isinstance(row, dict) or row.get("status") not in {
                "needs-wiring",
                "needs-materialization",
            }:
                continue
            kind = str(row.get("kind") or "")
            name = str(row.get("name") or "")
            waived = any(
                norm(waiver.get("control") or waiver.get("name"))
                in {norm(name), norm(f"{kind}:{name}")}
                for waiver in valid_waivers
            )
            if not waived:
                control_blockers.append(
                    {"kind": kind, "name": name, "status": row.get("status")}
                )

    kind_blockers: list[dict[str, Any]] = []
    png_path = workdir / "png-read.json"
    readback_path = workdir / "wb-readback.json"
    renames_path = workdir / "layout-renames.json"
    if png_path.exists() and readback_path.exists() and renames_path.exists():
        png = read_json(png_path)
        readback = read_json(readback_path)
        renames = read_json(renames_path)
        if (
            isinstance(png, dict)
            and png.get("verified") is not False
            and isinstance(png.get("tiles"), list)
            and isinstance(renames, dict)
        ):
            elements_by_name: dict[str, list[dict[str, Any]]] = {}
            for element in workbook_elements(readback):
                if element.get("visibleAsSource") is False:
                    continue
                built_family = FAMILY_MAP.get(
                    str(element.get("kind") or "").strip().lower()
                )
                if not built_family:
                    continue
                name = element.get("name")
                name = name.get("text") if isinstance(name, dict) else name
                name = name or element.get("title") or element.get("id")
                key = norm(name)
                if key:
                    elements_by_name.setdefault(key, []).append(
                        {
                            "id": element.get("id"),
                            "kind": element.get("kind"),
                            "family": built_family,
                        }
                    )
            rename_by_source = {
                norm(source_name): built_name
                for source_name, built_name in renames.items()
            }
            kind_waivers = [
                waiver
                for waiver in png.get("kind_waivers", [])
                if isinstance(waiver, dict)
                and str(waiver.get("tile") or "").strip()
                and str(waiver.get("reason") or "").strip()
            ]
            for tile in png["tiles"]:
                if not isinstance(tile, dict):
                    continue
                expected = FAMILY_MAP.get(
                    str(tile.get("kind") or tile.get("chart_kind") or "")
                    .strip()
                    .lower()
                )
                source_name = str(tile.get("title") or "")
                built_name = rename_by_source.get(norm(source_name))
                if not expected or not built_name:
                    continue
                actuals = elements_by_name.get(norm(built_name), [])
                if not actuals or any(
                    element["family"] == expected for element in actuals
                ):
                    continue
                if any(
                    norm(waiver.get("tile")) == norm(source_name)
                    for waiver in kind_waivers
                ):
                    continue
                kind_blockers.append(
                    {
                        "source_tile": source_name,
                        "renamed_element": built_name,
                        "expected_family": expected,
                        "built_families": sorted(
                            {element["family"] for element in actuals}
                        ),
                        "built_kinds": sorted(
                            {str(element["kind"]) for element in actuals}
                        ),
                    }
                )

    return {
        "version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "status": (
            "PASS" if not control_blockers and not kind_blockers else "FAIL"
        ),
        "controls_census": census_path.name if census_path else None,
        "unresolved_controls": control_blockers,
        "renamed_chart_family_mismatches": kind_blockers,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workdir", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = evaluate(args.workdir)
    except (OSError, ValueError) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1

    output_path = args.workdir / "reconstruction-integrity.json"
    output_path.write_text(
        json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    for blocker in result["unresolved_controls"]:
        print(
            f"[FAIL] unfinished control: {blocker['kind']}:{blocker['name']} "
            f"({blocker['status']})",
            file=sys.stderr,
        )
    for blocker in result["renamed_chart_family_mismatches"]:
        print(
            f"[FAIL] renamed chart family: {blocker['source_tile']!r} -> "
            f"{blocker['renamed_element']!r}: expected "
            f"{blocker['expected_family']}, built "
            f"{'/'.join(blocker['built_families'])}",
            file=sys.stderr,
        )
    if result["status"] == "PASS":
        print(
            "[OK] reconstruction integrity: controls terminal, renamed chart "
            "families faithful or explicitly waived"
        )
        print(f"wrote {output_path}")
        return 0
    print(f"wrote {output_path}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
