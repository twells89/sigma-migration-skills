"""Validate blind visual grades and cross-check their chart-family census."""

from __future__ import annotations

import hashlib
import json
from collections import Counter
from pathlib import Path
from typing import Any

from .code_rep import workbook_elements_with_pages

DIMENSION_KEYS = (
    "element_titles_hidden",
    "palette_match",
    "composition_match",
    "chart_shapes_match",
    "labels_legible",
    "numbers_formatted",
)
FAMILY_MAP = {
    "bar-chart": "bar",
    "column": "bar",
    "column-chart": "bar",
    "line-chart": "line",
    "sparkline": "line",
    "area-chart": "area",
    "combo-chart": "combo",
    "dual-axis": "combo",
    "scatter-chart": "scatter",
    "scatterplot": "scatter",
    "bubble": "scatter",
    "pie-chart": "pie",
    "donut": "pie",
    "donut-chart": "pie",
    "kpi-chart": "kpi",
    "single-value": "kpi",
    "big-number": "kpi",
    "progress": "kpi",
    "progress-chart": "kpi",
    "gauge-chart": "kpi",
    "region-map": "map",
    "point-map": "map",
    "waterfall-chart": "bar",
    "funnel-chart": "bar",
    "box-chart": "other",
    "sankey-chart": "other",
    "treemap-chart": "other",
    "heatmap-chart": "other",
    "word-cloud": "other",
    "text": "text",
    "control": "control",
    "image": "image",
    "container": "container",
    "tabbed-container": "container",
    "divider": "divider",
    "spacer": "spacer",
    "navigation": "navigation",
    "pivot-table": "table",
    "pivot": "table",
    "crosstab": "table",
    "text-table": "table",
    "grid": "table",
    "table": "table",
}
CHART_FAMILIES = {
    "bar", "line", "area", "combo", "scatter", "pie", "kpi", "map", "table",
    "other",
}
NON_CHART_FAMILIES = {
    "text", "control", "image", "container", "divider", "spacer", "navigation",
}


def family(value: Any) -> str:
    normalized = str(value or "").strip().casefold()
    return FAMILY_MAP.get(
        normalized,
        normalized
        if normalized in CHART_FAMILIES | NON_CHART_FAMILIES
        else "other",
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_object(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path.name} must contain a JSON object")
    return value


def resolve_image(value: Any, grade_path: Path) -> Path:
    path = Path(str(value or "")).expanduser()
    if not str(value or "").strip():
        raise ValueError("blind grade must record both image paths")
    return path.resolve() if path.is_absolute() else (grade_path.parent / path).resolve()


def built_families(readback: dict[str, Any]) -> list[str]:
    result = []
    for element, page in workbook_elements_with_pages(readback):
        if element.get("visibleAsSource") is False:
            continue
        if isinstance(page, dict) and (
            page.get("visibility") == "hidden"
            or str(page.get("id") or "").strip().casefold()
            in {"data", "page-data", "pg-data"}
        ):
            continue
        normalized = family(element.get("kind"))
        if normalized in CHART_FAMILIES:
            result.append(normalized)
    return result


def source_families(png_read: dict[str, Any]) -> list[str]:
    return [
        normalized
        for row in png_read.get("tiles") or []
        if isinstance(row, dict)
        and (normalized := family(row.get("kind"))) in CHART_FAMILIES
    ]


def require_same_census(
    label: str, observed: list[str], expected: list[str]
) -> None:
    if Counter(observed) != Counter(expected):
        raise ValueError(
            f"blind grade {label} tile families disagree with mechanical census "
            f"(blind={dict(Counter(observed))}, census={dict(Counter(expected))})"
        )


def validate(
    grade_path: Path,
    workdir: Path,
    *,
    readback_path: Path | None = None,
    png_read_path: Path | None = None,
) -> dict[str, Any]:
    grade_path = grade_path.expanduser().resolve()
    grade = read_object(grade_path)
    if grade.get("verdict") != "pass":
        raise ValueError("blind grade verdict is not pass")
    dimensions = grade.get("dimensions")
    bad_dimensions = [
        key
        for key in DIMENSION_KEYS
        if not isinstance(dimensions, dict)
        or not isinstance(dimensions.get(key), dict)
        or dimensions[key].get("verdict") != "pass"
    ]
    if bad_dimensions:
        raise ValueError(
            "blind grade dimension(s) missing or not passing: "
            + ", ".join(bad_dimensions)
        )
    per_tile = grade.get("per_tile")
    if (
        not isinstance(per_tile, list)
        or not per_tile
        or any(
            not isinstance(row, dict)
            or not str(row.get("source_family") or "").strip()
            or not str(row.get("target_family") or "").strip()
            for row in per_tile
        )
    ):
        raise ValueError(
            "blind grade per_tile must record source_family and target_family "
            "for every observed tile"
        )
    source_path = resolve_image(grade.get("source_png"), grade_path)
    target_path = resolve_image(grade.get("target_png"), grade_path)
    for path, hash_key in (
        (source_path, "source_sha256"),
        (target_path, "target_sha256"),
    ):
        expected = str(grade.get(hash_key) or "").lower()
        if not path.is_file() or len(expected) != 64 or sha256(path) != expected:
            raise ValueError(f"blind grade {hash_key} is missing or stale")

    readback_path = readback_path or workdir / "wb-readback.json"
    readback = read_object(readback_path)
    expected_target = built_families(readback)
    if not expected_target:
        raise ValueError("workbook readback has no chart-family census")
    require_same_census(
        "target",
        [family(row["target_family"]) for row in per_tile],
        expected_target,
    )
    png_read_path = png_read_path or workdir / "png-read.json"
    if png_read_path.is_file():
        expected_source = source_families(read_object(png_read_path))
        if expected_source:
            require_same_census(
                "source",
                [family(row["source_family"]) for row in per_tile],
                expected_source,
            )
    return {
        "path": str(grade_path),
        "source_sha256": str(grade["source_sha256"]).lower(),
        "target_sha256": str(grade["target_sha256"]).lower(),
        "verdict": "pass",
        "dimensions": {
            key: dimensions[key]["verdict"] for key in DIMENSION_KEYS
        },
        "per_tile_count": len(per_tile),
    }
