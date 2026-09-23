#!/usr/bin/env python3
"""Pre-POST workbook lint for aggregation, control, KPI, and naming traps."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from lib.code_rep import workbook_elements

AGG = re.compile(
    r"^\s*(?:Sum|Avg|Count|CountDistinct|CountIf|SumIf|Min|Max|Median|"
    r"Percentile|StdDev|Variance|VariancePop|GrandTotal)\s*\(",
    re.I,
)
PLAIN_REF = re.compile(r"^\s*\[[^\]]+\]\s*$")
BARE_PREDICATE = re.compile(r"\b(If)\s*\(\s*(\[[^\]]+\])\s*[,)]", re.I)
LISTY = {"list", "segmented", "hierarchy"}
CONTROL_TYPES = {
    "checkbox", "switch", "text", "text-area", "number", "number-range",
    "date", "date-range", "list", "segmented", "hierarchy", "slider",
    "range-slider", "legend", "drill",
}
MODE_REQUIRED = {"switch", "checkbox", "text", "number", "date", "slider"}
INCLUDE_NULLS_OK = {
    "text", "number", "number-range", "date", "date-range", "slider", "range-slider",
}
DROPPED_BY_API = {
    "showNullOption": "filter nulls at the value-list option source",
    "allowMultipleSelection": 'use selectionMode: "single"|"multiple"',
    "excludeValues": 'use mode:"exclude" with values',
    "showClearButton": "configure it in the Sigma UI post-publish",
    "showSearchBox": "configure it in the Sigma UI post-publish",
    "showHistogram": "configure it in the Sigma UI post-publish",
    "showExpandedList": "configure it in the Sigma UI post-publish",
    "required": "configure it in the Sigma UI post-publish",
}
ISO_DATETIME = re.compile(
    r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})$"
)


def _name(element: dict[str, Any]) -> str:
    return str(element.get("name") or element.get("id") or "(unnamed)")


def lint(spec: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    elements = workbook_elements(spec)
    columns_by_id = {
        column.get("id"): column
        for element in elements
        for column in element.get("columns") or []
        if isinstance(column, dict) and column.get("id")
    }
    for element in elements:
        kind = str(element.get("kind") or "")
        name = _name(element)
        columns = [row for row in element.get("columns") or [] if isinstance(row, dict)]
        if "name" in element and not str(element.get("name") or "").strip():
            errors.append(
                f"N1 element '{element.get('id') or '(no id)'}' ({kind}): "
                "`name` is empty/whitespace-only."
            )
        for column in columns:
            if "name" in column and not str(column.get("name") or "").strip():
                errors.append(
                    f"N1 column '{column.get('id') or '(no id)'}' on element "
                    f"'{name}': `name` is empty/whitespace-only."
                )
        if kind == "kpi-chart":
            value_id = (element.get("value") or {}).get("columnId")
            value_column = next((row for row in columns if row.get("id") == value_id), None)
            if value_column and PLAIN_REF.match(str(value_column.get("formula") or "")):
                errors.append(
                    f"K1 kpi-chart '{name}': value column '{value_id}' formula is "
                    f"a bare sibling ref (`{value_column.get('formula')}`) — inline "
                    "the aggregate expression."
                )
        if kind in {"kpi-chart", "bar-chart"} and (
            (element.get("style") or {}).get("backgroundColor")
        ):
            errors.append(
                f"S1 {kind} '{name}': style.backgroundColor blanks the tile in PNG export."
            )
        if kind == "table":
            aggregates = [row for row in columns if AGG.match(str(row.get("formula") or ""))]
            dimensions = [
                row for row in columns if PLAIN_REF.match(str(row.get("formula") or ""))
            ]
            grouped = isinstance(element.get("groupings"), list) and bool(
                element["groupings"]
            )
            if aggregates and dimensions and not grouped:
                errors.append(
                    f"T1 table '{name}': has aggregate column(s) "
                    f"{[row.get('name') for row in aggregates]!r} + dimensions but "
                    "NO `groupings`."
                )
            for grouping in element.get("groupings") or []:
                for column_id in grouping.get("calculations") or []:
                    column = columns_by_id.get(column_id) or {}
                    formula = str(column.get("formula") or "")
                    if PLAIN_REF.match(formula) and re.search(
                        r"total|sum|count|avg|revenue|profit|tcv|amount",
                        str(column.get("name") or ""),
                        re.I,
                    ):
                        errors.append(
                            f"T2 table '{name}': grouping calculation '{column_id}' "
                            f"is a passthrough (`{formula}`), not an aggregate."
                        )
        for index, filter_row in enumerate(element.get("filters") or []):
            if (
                isinstance(filter_row, dict)
                and filter_row.get("kind") == "number-range"
                and ("min" in filter_row or "max" in filter_row)
                and filter_row.get("min") is None
                and filter_row.get("max") is None
            ):
                errors.append(
                    f"C7 element '{name}': number-range filter[{index}] has "
                    "min:null and max:null."
                )
        if kind != "control":
            continue
        for field in ("id", "controlId", "controlType"):
            if not str(element.get(field) or ""):
                errors.append(f"C1 control '{name}': missing required field `{field}`.")
        if element.get("id") and element.get("id") == element.get("controlId"):
            errors.append(f"C1 control '{name}': `id` and `controlId` must be DISTINCT.")
        if isinstance(element.get("value"), dict):
            errors.append(
                f"C2 control '{name}': value fields are nested under a `value` object."
            )
        source = element.get("source")
        if (
            isinstance(source, dict)
            and source.get("kind") == "source"
            and not isinstance(source.get("source"), dict)
        ):
            errors.append(
                f"C2 control '{name}': `source` is not double-nested."
            )
        control_type = str(element.get("controlType") or "")
        if (
            control_type in LISTY
            and not isinstance(source, dict)
            and not (isinstance(element.get("filters"), list) and element["filters"])
        ):
            errors.append(
                f"C3 control '{name}': list-type control has neither `source` nor `filters`."
            )
        if (
            element.get("selectionMode") == "single"
            and isinstance(element.get("values"), list)
        ):
            errors.append(
                f"C5 control '{name}': selectionMode \"single\" carries `values` "
                "(array); use scalar `value`."
            )
        if control_type == "top-n":
            errors.append(
                f"C6 control '{name}': controlType \"top-n\" is not accepted by the live API."
            )
        elif control_type and control_type not in CONTROL_TYPES:
            errors.append(
                f"C6 control '{name}': unknown controlType \"{control_type}\"."
            )
        if control_type in MODE_REQUIRED and not str(element.get("mode") or ""):
            errors.append(
                f"C7 control '{name}': controlType \"{control_type}\" requires a `mode`."
            )
        if control_type == "range-slider" and (
            element.get("low") is None or element.get("high") is None
        ):
            errors.append(
                f"C7 control '{name}': range-slider needs flat `low`/`high` bounds."
            )
        if (
            control_type == "number-range"
            and ("min" in element or "max" in element)
            and element.get("min") is None
            and element.get("max") is None
        ):
            errors.append(
                f"C7 control '{name}': number-range with min:null and max:null is invalid."
            )
        if "includeNulls" in element and control_type not in INCLUDE_NULLS_OK:
            errors.append(
                f"C8 control '{name}': `includeNulls` is off-schema for "
                f"controlType \"{control_type}\"."
            )
    return errors


def lint_warnings(
    spec: dict[str, Any], scope: dict[str, Any] | None = None
) -> list[str]:
    warnings: list[str] = []
    elements = workbook_elements(spec)
    by_id = {
        str(row.get("id") or row.get("elementId")): row
        for row in elements
        if row.get("id") or row.get("elementId")
    }
    scope_by_id = {
        row.get("controlId"): row
        for row in (scope or {}).get("controls") or []
        if isinstance(row, dict) and row.get("controlId")
    }
    for element in elements:
        name = _name(element)
        for index, conditional in enumerate(element.get("conditionalFormats") or []):
            if isinstance(conditional, dict) and conditional.get("includeValues") is False:
                warnings.append(
                    f"P1 {element.get('kind')} '{name}': conditionalFormats[{index}] "
                    "has includeValues:false and is a silent no-op."
                )
        for column in element.get("columns") or []:
            for function, reference in BARE_PREDICATE.findall(
                str(column.get("formula") or "")
            ):
                warnings.append(
                    f"I1 column '{column.get('name') or column.get('id')}' on "
                    f"element '{name}': {function}({reference}, ...) uses a bare predicate."
                )
            if "/" in str(column.get("name") or ""):
                warnings.append(
                    f"N2 column '{column.get('name')}' on element '{name}': "
                    "display name contains '/'."
                )
        if element.get("kind") != "control":
            continue
        for field, workaround in DROPPED_BY_API.items():
            if field in element:
                warnings.append(
                    f"A1 control '{name}': `{field}` is accepted then silently "
                    f"dropped. Workaround: {workaround}."
                )
        if element.get("controlType") == "date-range":
            for field in ("startDate", "endDate"):
                value = element.get(field)
                if isinstance(value, str) and value and not ISO_DATETIME.match(value):
                    warnings.append(
                        f"A2 control '{name}': `{field}` {value!r} is not a "
                        "timezone-qualified timestamp and may be dropped."
                    )
        annotation = scope_by_id.get(element.get("controlId")) or {}
        targets = element.get("filters") or []
        target_columns = []
        for target in targets:
            target_element = by_id.get(str((target.get("source") or {}).get("elementId")))
            if target_element:
                target_columns.extend(
                    column
                    for column in target_element.get("columns") or []
                    if column.get("id") == target.get("columnId")
                )
        has_decode = any(
            re.fullmatch(r"\s*Text\s*\(\s*\[[^\]]+\]\s*\)\s*", str(row.get("formula") or ""), re.I)
            for row in target_columns
        )
        if annotation.get("integer_dim") and not has_decode:
            warnings.append(
                f"A3 control '{name}': integer-coded list dimension has no Text() "
                "decode target; Sigma can silently strip the raw numeric binding."
            )
    return warnings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec")
    parser.add_argument("control_scope", nargs="?")
    args = parser.parse_args(argv)
    try:
        spec = json.loads(Path(args.spec).read_text(encoding="utf-8-sig"))
        scope_path = (
            Path(args.control_scope)
            if args.control_scope
            else Path(args.spec).with_name("control-scope.json")
        )
        scope = (
            json.loads(scope_path.read_text(encoding="utf-8-sig"))
            if scope_path.is_file()
            else None
        )
    except (OSError, json.JSONDecodeError) as exc:
        print(f"preflight lint: {exc}", file=sys.stderr)
        return 2
    errors = lint(spec)
    warnings = lint_warnings(spec, scope)
    if errors:
        print(
            f"preflight lint: {len(errors)} violation(s), "
            f"{len(warnings)} warning(s)",
            file=sys.stderr,
        )
        for error in errors:
            print(f"  ✗ {error}", file=sys.stderr)
        for warning in warnings:
            print(f"  ⚠ {warning}", file=sys.stderr)
        return 1
    print(f"preflight lint: clean" + (f" ({len(warnings)} warning(s))" if warnings else ""))
    for warning in warnings:
        print(f"  ⚠ {warning}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
