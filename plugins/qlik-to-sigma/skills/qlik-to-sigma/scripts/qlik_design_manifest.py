#!/usr/bin/env python3
"""Seed, validate, and apply screenshot-reviewed Qlik design manifests."""

from __future__ import annotations

import argparse
import copy
import json
import re
import shutil
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
ALLOWED_KINDS = {
    "keep",
    "kpi-chart",
    "bar-chart",
    "line-chart",
    "area-chart",
    "combo-chart",
    "pie-chart",
    "donut-chart",
    "scatter-chart",
    "table",
    "pivot-table",
    "region-map",
    "point-map",
}
ALLOWED_ORIENTATIONS = {"keep", "horizontal", "vertical"}
ALLOWED_LEGENDS = {"keep", "shown", "hidden"}


class ManifestError(ValueError):
    pass


def fold(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", "-", str(value or "").lower()).strip("-")


def parse_source_specs(values: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        sheet_id, separator, filename = str(value).partition("=")
        if not separator or not sheet_id.strip() or not filename.strip():
            raise ManifestError(
                f"bad --source {value!r}; expected <sheetId>=<image.png>"
            )
        path = Path(filename).expanduser().resolve()
        if not path.is_file():
            raise ManifestError(f"source screenshot does not exist: {path}")
        result[sheet_id.strip()] = path
    return result


def discover_source_images(
    workdir: Path,
    sheets: list[dict[str, Any]],
    explicit: dict[str, Path] | None = None,
) -> dict[str, Path]:
    explicit = explicit or {}
    directories = (
        "source-pages",
        "dashboards",
        "user-screenshots",
        "source-captures",
        "qlik-screenshots",
    )
    images = [
        path.resolve()
        for directory in directories
        for base in [workdir / directory]
        if base.is_dir()
        for path in base.rglob("*")
        if path.is_file() and path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}
    ]
    result: dict[str, Path] = {}
    for sheet in sheets:
        sheet_id = str(sheet.get("sheetId") or "")
        if sheet_id in explicit:
            result[sheet_id] = explicit[sheet_id]
            continue
        keys = {fold(sheet_id), fold(sheet.get("title"))}
        matches = [
            path for path in images
            if fold(path.stem) in keys
            or any(key and key in fold(path.stem) for key in keys)
        ]
        if len(matches) == 1:
            result[sheet_id] = matches[0]
    return result


def seed_manifest(
    charts: list[dict[str, Any]],
    sheets: list[dict[str, Any]],
    source_images: dict[str, Path],
) -> dict[str, Any]:
    by_id = {
        str(chart.get("id")): chart
        for chart in charts
        if isinstance(chart, dict) and chart.get("id")
    }
    pages = []
    for sheet in sheets:
        sheet_id = str(sheet.get("sheetId") or "")
        source = source_images.get(sheet_id)
        if not source:
            continue
        tiles = []
        for cell in sorted(
            sheet.get("cells") or [],
            key=lambda value: (value.get("row", 0), value.get("col", 0)),
        ):
            object_id = str(cell.get("objectId") or "")
            chart = by_id.get(object_id) or {}
            tiles.append(
                {
                    "objectId": object_id,
                    "sourceKind": chart.get("vizType") or cell.get("type"),
                    "kind": "keep",
                    "title": chart.get("title"),
                    "orientation": "keep",
                    "legend": "keep",
                    "grid": {
                        "col": int(cell.get("col", 0)),
                        "row": int(cell.get("row", 0)),
                        "colspan": int(cell.get("colspan", 1)),
                        "rowspan": int(cell.get("rowspan", 1)),
                    },
                    "reviewed": False,
                    "notes": [],
                }
            )
        pages.append(
            {
                "sheetId": sheet_id,
                "title": sheet.get("title") or sheet_id,
                "sourceImage": str(source),
                "columns": int(sheet.get("columns") or 24),
                "rows": int(sheet.get("rows") or 12),
                "reviewed": False,
                "tiles": tiles,
            }
        )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "status": "needs-review",
        "iteration": 0,
        "instructions": (
            "Read each sourceImage before building. Inventory every visible tile, "
            "set kind/title/orientation/legend/grid, mark every page and tile "
            "reviewed=true, then set status=approved."
        ),
        "pages": pages,
    }


def validate_manifest(
    manifest: dict[str, Any],
    charts: list[dict[str, Any]],
    sheets: list[dict[str, Any]],
    *,
    require_approved: bool = True,
) -> None:
    errors = []
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        errors.append(f"schemaVersion must be {SCHEMA_VERSION}")
    if require_approved and manifest.get("status") != "approved":
        errors.append("status must be 'approved' after image review")
    chart_by_id = {
        str(chart.get("id")): chart
        for chart in charts
        if isinstance(chart, dict) and chart.get("id")
    }
    chart_ids = set(chart_by_id)
    sheet_by_id = {
        str(sheet.get("sheetId")): sheet
        for sheet in sheets
        if isinstance(sheet, dict) and sheet.get("sheetId")
    }
    manifest_pages = manifest.get("pages")
    if not isinstance(manifest_pages, list) or not manifest_pages:
        errors.append("pages must contain at least one screenshot-backed page")
        manifest_pages = []
    seen_pages = set()
    seen_tiles = set()
    for page in manifest_pages:
        sheet_id = str((page or {}).get("sheetId") or "")
        if not sheet_id or sheet_id not in sheet_by_id:
            errors.append(f"unknown sheetId {sheet_id!r}")
            continue
        if sheet_id in seen_pages:
            errors.append(f"duplicate sheetId {sheet_id!r}")
        seen_pages.add(sheet_id)
        source = Path(str(page.get("sourceImage") or "")).expanduser()
        if not source.is_file():
            errors.append(f"{sheet_id}: sourceImage is missing: {source}")
        if require_approved and page.get("reviewed") is not True:
            errors.append(f"{sheet_id}: page reviewed must be true")
        columns = int(page.get("columns") or sheet_by_id[sheet_id].get("columns") or 24)
        rows = int(page.get("rows") or sheet_by_id[sheet_id].get("rows") or 12)
        for tile in page.get("tiles") or []:
            object_id = str((tile or {}).get("objectId") or "")
            key = (sheet_id, object_id)
            if object_id not in chart_ids:
                errors.append(f"{sheet_id}: unknown objectId {object_id!r}")
            if key in seen_tiles:
                errors.append(f"{sheet_id}: duplicate objectId {object_id!r}")
            seen_tiles.add(key)
            kind = tile.get("kind")
            if kind not in ALLOWED_KINDS:
                errors.append(f"{sheet_id}/{object_id}: invalid kind {kind!r}")
            chart = chart_by_id.get(object_id) or {}
            dimensions = chart.get("dimensions") or []
            measures = chart.get("measures") or []
            if kind in {"region-map", "point-map"} and chart.get("vizType") != "map":
                errors.append(
                    f"{sheet_id}/{object_id}: map override requires Qlik map metadata"
                )
            if kind in {
                "bar-chart",
                "line-chart",
                "area-chart",
                "combo-chart",
                "pie-chart",
                "donut-chart",
                "scatter-chart",
            } and (not dimensions or not measures):
                errors.append(
                    f"{sheet_id}/{object_id}: {kind} requires dimensions and measures"
                )
            if kind == "combo-chart" and len(measures) < 2:
                errors.append(
                    f"{sheet_id}/{object_id}: combo-chart requires two measures"
                )
            if kind == "kpi-chart" and not measures:
                errors.append(f"{sheet_id}/{object_id}: kpi-chart requires a measure")
            if tile.get("orientation") not in ALLOWED_ORIENTATIONS:
                errors.append(
                    f"{sheet_id}/{object_id}: invalid orientation "
                    f"{tile.get('orientation')!r}"
                )
            if tile.get("legend") not in ALLOWED_LEGENDS:
                errors.append(
                    f"{sheet_id}/{object_id}: invalid legend {tile.get('legend')!r}"
                )
            if require_approved and tile.get("reviewed") is not True:
                errors.append(f"{sheet_id}/{object_id}: reviewed must be true")
            grid = tile.get("grid") or {}
            try:
                col = int(grid["col"])
                row = int(grid["row"])
                colspan = int(grid["colspan"])
                rowspan = int(grid["rowspan"])
                if (
                    col < 0
                    or row < 0
                    or colspan <= 0
                    or rowspan <= 0
                    or col + colspan > columns
                    or row + rowspan > rows
                ):
                    raise ValueError
            except (KeyError, TypeError, ValueError):
                errors.append(
                    f"{sheet_id}/{object_id}: grid must fit within "
                    f"{columns}x{rows}"
                )
    if errors:
        raise ManifestError("; ".join(errors))


def apply_manifest(
    manifest: dict[str, Any],
    charts: list[dict[str, Any]],
    sheets: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[str]]:
    validate_manifest(manifest, charts, sheets, require_approved=True)
    updated_charts = copy.deepcopy(charts)
    updated_sheets = copy.deepcopy(sheets)
    chart_by_id = {str(chart["id"]): chart for chart in updated_charts}
    sheet_by_id = {str(sheet["sheetId"]): sheet for sheet in updated_sheets}
    notes = []
    for page in manifest["pages"]:
        sheet = sheet_by_id[page["sheetId"]]
        sheet["title"] = page.get("title") or sheet.get("title")
        sheet["columns"] = int(page.get("columns") or sheet.get("columns") or 24)
        sheet["rows"] = int(page.get("rows") or sheet.get("rows") or 12)
        cells = {
            str(cell.get("objectId")): cell
            for cell in sheet.get("cells") or []
        }
        for tile in page.get("tiles") or []:
            object_id = tile["objectId"]
            chart = chart_by_id[object_id]
            if tile.get("kind") != "keep":
                chart["designKind"] = tile["kind"]
            if tile.get("title"):
                chart["title"] = tile["title"]
            if tile.get("orientation") != "keep":
                chart.setdefault("presentation", {})["orientation"] = tile[
                    "orientation"
                ]
            if tile.get("legend") != "keep":
                chart["legend"] = {"show": tile["legend"] == "shown"}
            cells[object_id].update(tile["grid"])
            notes.extend(
                f"{page['sheetId']}/{object_id}: {note}"
                for note in tile.get("notes") or []
                if str(note).strip()
            )
    return updated_charts, updated_sheets, notes


def stage_manifest_images(
    manifest: dict[str, Any],
    workdir: Path,
) -> dict[str, Any]:
    """Copy approved page screenshots into the migration evidence directory."""
    staged = copy.deepcopy(manifest)
    directory = workdir / "source-pages"
    directory.mkdir(parents=True, exist_ok=True)
    for page in staged.get("pages") or []:
        source = Path(str(page.get("sourceImage") or "")).expanduser().resolve()
        destination = directory / f"{page['sheetId']}{source.suffix.lower()}"
        if source != destination.resolve():
            shutil.copy2(source, destination)
        page["sourceImage"] = str(destination.resolve())
    return staged


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"cannot read {path}: {exc}") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    seed = subparsers.add_parser("seed")
    seed.add_argument("--charts", required=True)
    seed.add_argument("--layout", required=True)
    seed.add_argument("--workdir", required=True)
    seed.add_argument("--source", action="append", default=[])
    seed.add_argument("--out", required=True)
    seed.add_argument("--force", action="store_true")
    validate = subparsers.add_parser("validate")
    validate.add_argument("--charts", required=True)
    validate.add_argument("--layout", required=True)
    validate.add_argument("--manifest", required=True)
    args = parser.parse_args()
    try:
        charts = load_json(Path(args.charts))
        sheets = load_json(Path(args.layout))
        if args.command == "seed":
            output = Path(args.out)
            if output.exists() and not args.force:
                raise ManifestError(f"{output} already exists; use --force to replace")
            workdir = Path(args.workdir).resolve()
            explicit = parse_source_specs(args.source)
            sources = discover_source_images(workdir, sheets, explicit)
            manifest = seed_manifest(charts, sheets, sources)
            output.write_text(
                json.dumps(manifest, indent=2) + "\n",
                encoding="utf-8",
            )
            print(
                f"seeded {output}: {len(manifest['pages'])} screenshot-backed "
                "page(s); agent image review required"
            )
            return 0
        manifest = load_json(Path(args.manifest))
        validate_manifest(manifest, charts, sheets)
        print(f"design manifest approved: {args.manifest}")
        return 0
    except ManifestError as exc:
        print(f"qlik-design-manifest: {exc}")
        return 10


if __name__ == "__main__":
    raise SystemExit(main())
