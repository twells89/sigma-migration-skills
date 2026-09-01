#!/usr/bin/env python3
"""Parse Tableau workbook dashboard layout and worksheet signals.

This is the Python runtime counterpart of ``parse-twb-layout.rb``.  It keeps the
same positional CLI, dashboard/page scoping, primary JSON artifact, ``-meta``
sidecar, and optional ``story-plan.json`` contract while using only the Python
standard library.
"""

from __future__ import annotations

import html
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from statistics import median
from typing import Any, Iterable
from xml.etree import ElementTree as ET


MEASURE_PREFIXES = {
    "sum", "avg", "min", "max", "count", "countd", "cntd", "ctd",
    "median", "stdev", "stdevp", "var", "varp", "attr", "usr", "pcto", "rtot",
}
DATE_TRUNC_PREFIXES = {
    "tyr", "tqr", "tmn", "twk", "tdy", "thr", "tmi", "tsc",
    "yr", "qr", "mn", "wk", "dy", "hr", "mi", "sc",
    "mdy", "md", "qd", "ymd", "y", "q", "m", "d", "w", "h", "s",
}
TRELLIS_KINDS = {
    "bar", "line", "area", "scatter", "pie", "donut", "map-region", "map-point",
}
WILDCARD_MODE = {
    "CONTAINS": "contains",
    "STARTSWITH": "starts-with",
    "ENDSWITH": "ends-with",
}
WILDCARD_NEG_MODE = {
    "contains": "does-not-contain",
    "starts-with": "does-not-start-with",
    "ends-with": "does-not-end-with",
}


def local_name(name: str) -> str:
    """Return an ElementTree tag/attribute local name."""
    return name.rsplit("}", 1)[-1].split(":", 1)[-1]


def children(node: ET.Element, name: str | None = None) -> list[ET.Element]:
    values = list(node)
    return values if name is None else [item for item in values if local_name(item.tag) == name]


def descendants(node: ET.Element, name: str | None = None) -> Iterable[ET.Element]:
    for item in node.iter():
        if item is node:
            continue
        if name is None or local_name(item.tag) == name:
            yield item


def first_child(node: ET.Element | None, name: str) -> ET.Element | None:
    if node is None:
        return None
    return next((item for item in children(node, name)), None)


def first_desc(node: ET.Element | None, name: str) -> ET.Element | None:
    if node is None:
        return None
    return next(iter(descendants(node, name)), None)


def attr(node: ET.Element | None, name: str) -> str | None:
    if node is None:
        return None
    if name in node.attrib:
        return node.attrib[name]
    return next((value for key, value in node.attrib.items() if local_name(key) == name), None)


def compact(value: dict[str, Any]) -> dict[str, Any]:
    return {key: item for key, item in value.items() if item is not None}


def text_of(node: ET.Element | None) -> str:
    return "" if node is None else "".join(node.itertext())


def pct(value: str | None) -> float | None:
    if value is None:
        return None
    # Ruby Float#round uses half-away-from-zero; Tableau coordinates normally
    # have no half-ties, and format(..., ".1f") avoids binary surprises.
    return float(f"{float(value) / 1000.0:.1f}")


def int_value(value: str | None) -> int:
    try:
        return int(float(value or 0))
    except ValueError:
        return 0


def float_value(value: str | None) -> float:
    try:
        return float(value or 0)
    except ValueError:
        return 0.0


def unquote_value(value: str | None, *, null_is_none: bool = False) -> str | None:
    if value is None:
        return None
    result = html.unescape(str(value)).strip()
    if null_is_none and result == "%null%":
        return None
    if len(result) >= 2 and result[0] == result[-1] == '"':
        result = result[1:-1]
    return result


def json_write(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


class TableauLayoutParser:
    def __init__(
        self,
        twb_path: Path,
        out_path: Path,
        dashboard_filters: list[str] | None = None,
        page_filters: list[str] | None = None,
    ) -> None:
        self.twb_path = twb_path
        self.out_path = out_path
        self.dashboard_filters = dashboard_filters or []
        self.page_filters = page_filters or []
        self.twb_text = twb_path.read_text(encoding="utf-8-sig")
        self.root = ET.fromstring(self.twb_text)
        self.parent = {child: parent for parent in self.root.iter() for child in parent}
        self.columns_by_guid: dict[str, dict[str, Any]] = {}
        self.column_roles: dict[str, str] = {}
        self.column_formats: dict[str, str] = {}
        self.worksheets: dict[str, dict[str, Any]] = {}
        self.workbook_style_rules = self.style_rules_for(self.root)
        self.brand_palette = self.extract_brand_palette()
        self.window_by_uuid: dict[str, dict[str, str | None]] = {}
        self.visible_dashboard_windows: list[str] = []
        self.story_captured_sheets: list[str] = []
        self._index_columns()
        self._index_windows_and_stories()

    @property
    def dashboard_scoping(self) -> bool:
        return bool(self.dashboard_filters or self.page_filters)

    def dashboard_in_scope(self, name: str | None, page_id: str | None) -> bool:
        if not self.dashboard_scoping:
            return True
        lowered = str(name or "").lower()
        name_hit = any(
            lowered == token.lower() or (bool(token) and token.lower() in lowered)
            for token in self.dashboard_filters
        )
        page_hit = any(bool(token) and token == str(page_id or "") for token in self.page_filters)
        return name_hit or page_hit

    def top_level_datasources(self) -> list[ET.Element]:
        holder = first_child(self.root, "datasources")
        return children(holder, "datasource") if holder is not None else []

    def style_rules_for(self, scope: ET.Element | None) -> dict[str, dict[str, str]]:
        result: dict[str, dict[str, str]] = {}
        style = first_child(scope, "style") if scope is not None else None
        for rule in children(style, "style-rule") if style is not None else []:
            element = attr(rule, "element") or ""
            if not element:
                continue
            for fmt in children(rule, "format"):
                key, value = attr(fmt, "attr"), attr(fmt, "value")
                if key is not None and value is not None:
                    result.setdefault(element, {})[key] = value
        return result

    @staticmethod
    def color_neutral(color: str) -> bool:
        raw = color.lstrip("#")
        if len(raw) != 6:
            return True
        red, green, blue = (int(raw[index:index + 2], 16) for index in (0, 2, 4))
        maximum, minimum = max(red, green, blue), min(red, green, blue)
        return maximum - minimum < 24 or minimum > 235 or maximum < 26

    def extract_brand_palette(self) -> list[str]:
        frequencies: Counter[str] = Counter()
        for match in re.finditer(r"<map\s+to=(['\"])(#[0-9a-fA-F]{6})\1", self.twb_text):
            frequencies[match.group(2).lower()] += 1
        palette_re = re.compile(r"<color-palette\b([^>]*)>(.*?)</color-palette>", re.DOTALL)
        for match in palette_re.finditer(self.twb_text):
            if not re.search(r"type=(['\"])regular\1", match.group(1)):
                continue
            frequencies.update(color.lower() for color in re.findall(r"#[0-9a-fA-F]{6}", match.group(2)))
        return [
            color for color, _count in sorted(
                ((color, count) for color, count in frequencies.items() if not self.color_neutral(color)),
                key=lambda item: (-item[1], item[0]),
            )
        ]

    def _index_columns(self) -> None:
        guid_shape = re.compile(r"^(?:[0-9a-f]{8}-[0-9a-f-]{20,}|Calculation_\d+)", re.I)
        for column in descendants(self.root, "column"):
            raw = attr(column, "name") or ""
            if not raw:
                continue
            caption, datatype, role = attr(column, "caption"), attr(column, "datatype"), attr(column, "role")
            calc = first_child(column, "calculation")
            formula = attr(calc, "formula")
            body = re.sub(r"^\[|\]$", "", raw)
            if guid_shape.match(body):
                key = body.split(None, 1)[0]
                if role == "dimension":
                    self.column_roles[key] = "dimension"
                if caption:
                    info = self.columns_by_guid.setdefault(key, {"caption": caption, "datatype": datatype})
                    if formula and not info.get("formula"):
                        info["formula"] = formula
                elif formula:
                    info = self.columns_by_guid.setdefault(key, {"caption": key, "datatype": datatype})
                    info.setdefault("formula", formula)
            else:
                if role == "dimension":
                    self.column_roles[body] = "dimension"
                info = self.columns_by_guid.setdefault(
                    body, {"caption": caption or body, "datatype": datatype}
                )
                if formula and not info.get("formula"):
                    info["formula"] = formula

            display_caption = caption or re.sub(r"^\[|\]$", "", raw)
            default_format = attr(column, "default-format") or ""
            if not default_format:
                for fmt in descendants(column, "format"):
                    if attr(fmt, "field") is None and (attr(fmt, "attr") or "").endswith("-format"):
                        default_format = attr(fmt, "value") or ""
                        if default_format:
                            break
            if display_caption and default_format:
                self.column_formats.setdefault(display_caption, default_format)

    def _index_windows_and_stories(self) -> None:
        for window in descendants(self.root, "window"):
            simple_id = first_child(window, "simple-id")
            if simple_id is not None:
                self.window_by_uuid[attr(simple_id, "uuid") or ""] = {
                    "name": attr(window, "name"), "class": attr(window, "class")
                }
            if attr(window, "class") == "dashboard" and attr(window, "hidden") != "true":
                name = attr(window, "name")
                if name and name not in self.visible_dashboard_windows:
                    self.visible_dashboard_windows.append(name)
        for point in descendants(self.root, "story-point"):
            captured = attr(point, "captured-sheet")
            if captured and captured not in self.story_captured_sheets:
                self.story_captured_sheets.append(captured)

    def guid_from_param(self, param: str | None) -> str | None:
        if not param:
            return None
        token = r"(?:[0-9a-f-]{36}|Calculation_\d+|[A-Za-z_][\w. ()/&-]*)"
        match = re.search(rf"\.\[(?:[a-z-]+:)?({token})(?::[a-z]+)?\]$", param, re.I)
        if match:
            return match.group(1)
        if "].[" not in param:
            match = re.fullmatch(rf"\[(?:[a-z-]+:)?({token})(?::[a-z]+)?\]", param, re.I)
            if match:
                return match.group(1)
        return None

    @staticmethod
    def parse_wildcard_expression(expression: str | None) -> dict[str, str] | None:
        source = html.unescape(str(expression or "")).strip()
        negative = False
        match = re.fullmatch(r"\s*NOT\s+(.*)", source, re.I | re.DOTALL)
        if match:
            negative, source = True, match.group(1).strip()
        pattern = re.fullmatch(
            r"\(?\s*(CONTAINS|STARTSWITH|ENDSWITH)\s*\(\s*"
            r"(?:STR\s*\(\s*)?\[[^\]]+\]\s*\)?\s*,\s*(['\"])(.*)\2\s*\)\s*\)?",
            source,
            re.I | re.DOTALL,
        )
        if not pattern:
            return None
        mode = WILDCARD_MODE[pattern.group(1).upper()]
        return {"mode": WILDCARD_NEG_MODE[mode] if negative else mode, "pattern": pattern.group(3)}

    def normalize_filter(self, node: ET.Element) -> dict[str, Any]:
        filter_class = attr(node, "class") or ""
        parameter = attr(node, "column") or ""
        is_action = "[Action " in parameter or "[Action(" in parameter
        guid = self.guid_from_param(parameter)
        info = self.columns_by_guid.get(guid or "")
        friendly = bool(
            guid and not re.fullmatch(r"(?:[0-9a-f]{8}-[0-9a-f-]{20,}|Calculation_\d+)", guid, re.I)
        )
        fallback = None
        if friendly and guid:
            fallback = re.sub(r"\s*\(copy\)_\d+$", "", guid, flags=re.I)
            fallback = re.sub(r"\s*\(group\)$", " (group)", fallback, flags=re.I).strip()
        result: dict[str, Any] = {
            "raw_class": filter_class,
            "raw_param": parameter,
            "column_guid": guid,
            "column_caption": (info or {}).get("caption") or fallback,
            "datatype": (info or {}).get("datatype"),
            "is_action": is_action,
        }
        if is_action:
            result["kind"] = "action"
            return result
        if filter_class == "categorical":
            members: list[str] = []
            conditions: list[str] = []
            exclude = False
            null_member = False
            wildcard = None
            wildcard_unparsed = None
            topn = None
            order_expression = order_direction = ui_domain = None
            for group_filter in descendants(node, "groupfilter"):
                function = attr(group_filter, "function") or ""
                domain = attr(group_filter, "ui-domain")
                if domain and not ui_domain:
                    ui_domain = domain
                enumeration = attr(group_filter, "ui-enumeration")
                if function == "except" or enumeration == "exclusive":
                    exclude = True
                if function == "member":
                    raw_member = (attr(group_filter, "member") or "").strip()
                    null_member = null_member or raw_member == "%null%"
                    member = unquote_value(raw_member, null_is_none=True)
                    if member is not None:
                        members.append(member)
                if function == "end":
                    topn = topn or {}
                    topn["end"] = (attr(group_filter, "end") or "top").lower()
                    if attr(group_filter, "units") is not None:
                        topn["units"] = attr(group_filter, "units")
                    count = (attr(group_filter, "count") or "").strip()
                    if re.fullmatch(r"\d+", count):
                        topn["n"] = int(count)
                    elif count:
                        topn["count_param"] = count
                if function == "order":
                    order_direction = attr(group_filter, "direction")
                    order_expression = attr(group_filter, "expression")
                    continue
                expression = attr(group_filter, "expression")
                if not expression or not expression.strip():
                    continue
                parsed = self.parse_wildcard_expression(expression) if function == "filter" else None
                if parsed is not None and wildcard is None:
                    wildcard = parsed
                elif function == "filter" and re.search(
                    r"\b(?:CONTAINS|STARTSWITH|ENDSWITH)\s*\(", expression, re.I
                ):
                    wildcard_unparsed = wildcard_unparsed or expression
                else:
                    conditions.append(expression)
            result.update({"kind": "list", "members": members})
            if exclude:
                result["exclude"] = True
            if ui_domain:
                result["ui_domain"] = ui_domain
            if not exclude and len(members) == 1 and members[0].lower() in {
                "true", "false", "1", "0", "yes", "no",
            }:
                result["is_active_flag"] = True
            if exclude and null_member:
                result["excludes_null"] = True
            if topn is not None:
                topn["direction"] = (order_direction or "DESC").upper()
                if order_expression:
                    topn["order_expr"] = order_expression
                result["topn"] = topn
            if wildcard is not None or wildcard_unparsed is not None:
                result["kind"] = "wildcard"
                if wildcard is not None:
                    result["wildcard"] = wildcard
                else:
                    result["wildcard_unparsed"] = wildcard_unparsed
            if conditions:
                result["condition_expressions"] = list(dict.fromkeys(conditions))
                if not members and result["kind"] == "list":
                    result["kind"] = "list+condition"
        elif filter_class == "relative-date":
            result.update({
                "kind": "relative-date",
                "first_period": attr(node, "first-period"),
                "last_period": attr(node, "last-period"),
                "period_type": attr(node, "period-type-v2") or attr(node, "period-type"),
                "include_future": attr(node, "include-future"),
                "include_null": attr(node, "include-null"),
            })
        elif filter_class == "quantitative":
            result.update({"kind": "number-range", "min": attr(node, "min"), "max": attr(node, "max")})
        else:
            result["kind"] = "unknown"
        if (
            str(result.get("datatype") or "").strip().lower() == "integer"
            and (
                result.get("kind") in {"list", "list+condition", "wildcard"}
                or self.column_roles.get(guid or "") == "dimension"
            )
        ):
            result["integer_dim"] = True
        return result

    def classify_shelf_field(self, field: str) -> tuple[str, str | None, bool]:
        if not field or not field.strip():
            return "skip", None, False
        field = field.strip()
        if re.search(r"\bMeasure\s*Names\b", field, re.I):
            return "measure-names", None, False
        match = re.search(r"\[([^\[\]]*)\]\s*$", field)
        spec = match.group(1) if match else field
        parts = re.match(r"^([a-z]+):.*?:([a-z]+)(?::\d+)?$", spec, re.I)
        if parts:
            prefix = parts.group(1).lower()
            discrete = parts.group(2).lower().startswith("n")
            if prefix in MEASURE_PREFIXES:
                return "measure", prefix, discrete
            return "dim", prefix, False
        return "dim", None, False

    def parse_shelf(self, shelf: str | None) -> dict[str, Any]:
        result = {
            "raw": shelf, "fields": [], "dim_count": 0, "measure_count": 0,
            "cont_measure_count": 0, "has_measure_names": False, "has_measure_values": False,
        }
        if not shelf or not shelf.strip():
            return result
        result["has_measure_values"] = bool(
            re.search(r"\[(?:Multiple|Measure)\s+Values\]", shelf, re.I)
        )
        for part in shelf.split("/"):
            raw = re.sub(r"^[\s(]+|[)\s]+$", "", part.strip())
            if not raw:
                continue
            role, derivation, discrete = self.classify_shelf_field(raw)
            if role == "dim":
                result["dim_count"] += 1
                result["fields"].append({
                    "raw": raw, "role": "dim", "derivation": derivation,
                    "guid": self.guid_from_param(raw),
                })
            elif role == "measure":
                result["measure_count"] += 1
                if not discrete:
                    result["cont_measure_count"] += 1
                result["fields"].append({
                    "raw": raw, "role": "measure", "derivation": derivation,
                    "discrete": discrete, "guid": self.guid_from_param(raw),
                })
            elif role == "measure-names":
                result["has_measure_names"] = True
                result["fields"].append({"raw": raw, "role": "measure-names"})
        return result

    def worksheet_display_title(self, worksheet: ET.Element) -> str | None:
        title = first_child(first_child(worksheet, "layout-options"), "title") or first_child(worksheet, "title")
        formatted = first_child(title, "formatted-text")
        if formatted is None:
            return None
        value = "".join(text_of(run).replace("Æ", "") for run in children(formatted, "run")).strip()
        if not value or re.fullmatch(r"<[^<>]+>", value):
            return None
        return value

    def parse_customized_label(self, worksheet: ET.Element) -> dict[str, Any] | None:
        label = first_desc(worksheet, "customized-label")
        if label is None:
            return None
        runs = []
        for run in descendants(label, "run"):
            value = text_of(run).replace("Æ", "")
            runs.append(compact({
                "text": value,
                "color": attr(run, "fontcolor") or None,
                "font_size": int_value(attr(run, "fontsize")) if attr(run, "fontsize") else None,
                "bold": attr(run, "bold") == "true",
                "break": "\n" in value,
                "ref": "<[" in value,
            }))
        if not runs:
            return None
        ban_index = max(range(len(runs)), key=lambda index: runs[index].get("font_size", 0))
        ban_size = runs[ban_index].get("font_size", 0)
        if ban_size < 16:
            return None
        parts = [
            run["text"] for run in runs[:ban_index]
            if not run.get("ref") and run.get("text", "").strip()
            and (run.get("font_size") is None or run["font_size"] >= 6)
        ]
        display = re.sub(r"\s+", " ", " ".join(parts)).strip()
        return compact({
            "label": display or None,
            "value_font_size": ban_size,
            "annotation_runs": runs[ban_index + 1:],
        })

    def _parse_calculations(
        self, worksheet: ET.Element, datasource_formulas: dict[str, str]
    ) -> list[dict[str, Any]]:
        calculations = []
        for column in descendants(worksheet, "column"):
            calculation = first_child(column, "calculation")
            if calculation is None or not attr(calculation, "formula"):
                continue
            entry = {
                "name": attr(column, "name"),
                "caption": attr(column, "caption"),
                "datatype": attr(column, "datatype"),
                "role": attr(column, "role"),
                "class": attr(calculation, "class"),
                "formula": attr(calculation, "formula"),
            }
            if entry["class"] == "bin":
                entry["bin_size"] = attr(calculation, "size") or attr(calculation, "size-parameter")
                entry["bin_peg"] = attr(calculation, "peg")
            current = datasource_formulas.get(attr(column, "name") or "")
            if entry["class"] == "tableau" and current and current != entry["formula"]:
                entry["stale_dependency_formula"] = entry["formula"]
                entry["formula"] = current
            calculations.append(entry)
        return calculations

    def parse_worksheets(self) -> None:
        datasource_formulas: dict[str, str] = {}
        for datasource in self.top_level_datasources():
            label = attr(datasource, "caption") or attr(datasource, "name") or ""
            if label.startswith("Parameter"):
                continue
            for column in children(datasource, "column"):
                calculation = first_child(column, "calculation")
                if (
                    calculation is not None
                    and attr(calculation, "class") == "tableau"
                    and attr(calculation, "formula")
                ):
                    datasource_formulas[attr(column, "name") or ""] = attr(calculation, "formula") or ""

        for worksheet in descendants(self.root, "worksheet"):
            name = attr(worksheet, "name")
            if not name:
                continue
            mark = first_desc(worksheet, "mark")
            mark_class = attr(mark, "class")
            kpi_ban = self.parse_customized_label(worksheet)
            geo_role = None
            has_lat = has_long = False
            for column in descendants(worksheet, "column"):
                role = attr(column, "semantic-role") or attr(column, "semanticRole")
                geo_role = geo_role or role
                column_name = attr(column, "caption") or attr(column, "name") or ""
                has_lat = has_lat or bool(re.search("latitude", column_name, re.I))
                has_long = has_long or bool(re.search("longitude", column_name, re.I))

            sort_info = None
            sort = first_desc(worksheet, "sort")
            if sort is not None:
                sort_info = {"direction": attr(sort, "direction"), "column": attr(sort, "column")}
            if sort_info is None:
                computed = first_desc(worksheet, "computed-sort")
                if computed is not None:
                    sort_info = {
                        "direction": "descending" if re.search("desc", attr(computed, "direction") or "", re.I) else "ascending",
                        "column": attr(computed, "column"), "using": attr(computed, "using"),
                    }
            if sort_info is None:
                alphabetic = first_desc(worksheet, "alphabetic-sort")
                if alphabetic is not None:
                    sort_info = {
                        "direction": "descending" if re.search("desc", attr(alphabetic, "direction") or "", re.I) else "ascending",
                        "column": attr(alphabetic, "column"), "alphabetic": True,
                    }

            filters = [self.normalize_filter(item) for item in descendants(worksheet, "filter")]
            aggregations: dict[str, str] = {}
            measures: list[dict[str, str]] = []
            quick_calc_pcto: list[dict[str, str | None]] = []
            calculations = self._parse_calculations(worksheet, datasource_formulas)
            for instance in descendants(worksheet, "column-instance"):
                column, derivation = attr(instance, "column"), attr(instance, "derivation")
                if column is not None and derivation is not None:
                    aggregations[column] = derivation
                if column and derivation and attr(instance, "type") == "quantitative" and derivation != "None":
                    measure = {"column": column, "derivation": derivation}
                    if measure not in measures:
                        measures.append(measure)
                table_calcs = children(instance, "table-calc")
                table_calc = next((item for item in table_calcs if attr(item, "field") is None), None)
                table_calc = table_calc or (table_calcs[0] if table_calcs else None)
                ordering = attr(table_calc, "ordering-field")
                pct_match = re.fullmatch(
                    r"\[pcto:([a-z]+):([^:\]]+)(?::[a-z0-9]+)*\]",
                    attr(instance, "name") or "",
                    re.I,
                )
                if pct_match:
                    address_match = re.search(
                        r"\.\[(?:[a-z]+:)?([^:\]]+)(?::[a-z0-9]+)*\]$", ordering or "", re.I
                    )
                    quick_calc_pcto.append({
                        "agg": pct_match.group(1).lower(), "col": pct_match.group(2),
                        "addressing": address_match.group(1) if address_match else None,
                        "token": attr(instance, "name"),
                    })
                if ordering:
                    instance_column = re.search(r"\[([^\]]+)\]", column or "")
                    order_match = re.search(
                        r"\.\[(?:[a-z]+:)?([^:\]]+)(?::[a-z0-9]+)*\]$", ordering, re.I
                    )
                    if instance_column and order_match:
                        for calculation in calculations:
                            calc_name = re.sub(r"^\[|\]$", "", str(calculation.get("name") or ""))
                            if calc_name == instance_column.group(1) and not calculation.get("ordering_field"):
                                calculation["ordering_field"] = order_match.group(1)
                                break

            formats = {
                attr(fmt, "field"): attr(fmt, "value")
                for fmt in descendants(worksheet, "format")
                if attr(fmt, "attr") == "text-format"
                and attr(fmt, "field") is not None and attr(fmt, "value") is not None
            }
            axis_synced = False
            axis_formats = []
            for rule in descendants(worksheet, "style-rule"):
                if attr(rule, "element") != "axis":
                    continue
                for encoding in children(rule, "encoding"):
                    axis_synced = axis_synced or attr(encoding, "synchronized") == "true"
                    if attr(encoding, "attr") != "space" or attr(encoding, "scope") not in {"rows", "cols"}:
                        continue
                    axis_format = compact({
                        "scope": attr(encoding, "scope"), "class": attr(encoding, "class") or "",
                        "scale": attr(encoding, "scale"), "range_type": attr(encoding, "range-type"),
                        "field": attr(encoding, "field"),
                    })
                    if attr(encoding, "min") is not None:
                        axis_format["min"] = float_value(attr(encoding, "min"))
                    if attr(encoding, "max") is not None:
                        axis_format["max"] = float_value(attr(encoding, "max"))
                    axis_formats.append(axis_format)

            ref_marks = []
            for tag, kind in (
                ("reference-line", "line"), ("reference-band", "band"),
                ("reference-distribution", "distribution"),
            ):
                for reference in descendants(worksheet, tag):
                    info = compact({
                        "kind": kind, "formula": attr(reference, "formula"),
                        "axis_column": attr(reference, "axis-column"),
                        "value_column": attr(reference, "value-column"),
                        "label": attr(reference, "label"), "label_type": attr(reference, "label-type"),
                        "scope": attr(reference, "scope"),
                        "fill_above": attr(reference, "fill-above"),
                        "fill_below": attr(reference, "fill-below"),
                        "percentage_bands": attr(reference, "percentage-bands"),
                        "symmetric": attr(reference, "symmetric"),
                        "probability": attr(reference, "probability"),
                    })
                    band_values = [
                        attr(value, "percentage") for value in descendants(reference, "reference-line-value")
                        if attr(value, "percentage") is not None
                    ]
                    if band_values:
                        info["band_values"] = band_values
                    ref_marks.append(info)
            for trendline in descendants(worksheet, "trendline-model"):
                ref_marks.append(compact({
                    "kind": "trendline", "model": attr(trendline, "model-type") or attr(trendline, "model") or "linear",
                    "field_x": attr(trendline, "field-x"), "field_y": attr(trendline, "field-y"),
                }))

            channels: dict[str, dict[str, str | None]] = {}
            for encodings in descendants(worksheet, "encodings"):
                for encoding in children(encodings):
                    channel = attr(encoding, "attr") if local_name(encoding.tag) == "encoding" else local_name(encoding.tag)
                    if channel in {"color", "size", "shape", "detail", "label", "tooltip", "text"}:
                        channels.setdefault(channel, {
                            "column": attr(encoding, "column"), "field": attr(encoding, "field")
                        })

            rows_node = next((item for item in descendants(worksheet, "rows")), None)
            cols_node = next((item for item in descendants(worksheet, "cols")), None)
            rows_shelf, cols_shelf = self.parse_shelf(text_of(rows_node) if rows_node is not None else None), self.parse_shelf(text_of(cols_node) if cols_node is not None else None)
            text_mark = str(mark_class or "").lower() in {"text", "square"}
            automatic = str(mark_class or "").lower() == "automatic" or not str(mark_class or "").strip()
            both_dims = rows_shelf["dim_count"] >= 1 and cols_shelf["dim_count"] >= 1
            has_measure_values = rows_shelf["has_measure_values"] or cols_shelf["has_measure_values"]
            names_crosstab = (
                (rows_shelf["has_measure_names"] or cols_shelf["has_measure_names"])
                and rows_shelf["dim_count"] + cols_shelf["dim_count"] >= 1
                and rows_shelf["measure_count"] + cols_shelf["measure_count"] + len(measures) >= 2
            )
            is_crosstab = (
                text_mark and (both_dims or names_crosstab)
            ) or (automatic and names_crosstab and not has_measure_values)
            ban_scorecard = kpi_ban is not None and str(mark_class or "").lower() in {"shape", "circle"}
            kpi_capable = text_mark or automatic or ban_scorecard
            is_kpi = (
                kpi_capable and not is_crosstab
                and rows_shelf["dim_count"] + cols_shelf["dim_count"] == 0
                and rows_shelf["measure_count"] + cols_shelf["measure_count"] + len(measures) >= 1
            )

            calc_names = {str(item.get("name") or "") for item in calculations}
            calc_captions = {str(item.get("caption") or "") for item in calculations if item.get("caption")}
            hidden_filters = []
            for item in filters:
                raw, guid, caption = str(item.get("raw_param") or ""), str(item.get("column_guid") or ""), str(item.get("column_caption") or "")
                targeted = (
                    bool(re.search(r"Calculation_\d+", raw, re.I))
                    or bool(re.search(r"\[Parameters\.", raw, re.I))
                    or bool(re.fullmatch(r"Calculation_\d+", guid, re.I))
                    or bool(caption and (caption in calc_captions or f"[{caption}]" in calc_names))
                )
                if targeted:
                    hidden = compact({
                        "calc_ref": item.get("raw_param"), "caption": item.get("column_caption"),
                        "filter_type": item.get("raw_class"), "kind": item.get("kind"),
                    })
                    for key in ("members", "min", "max"):
                        if item.get(key) is not None and (key != "members" or item.get("kind") == "list"):
                            hidden[key] = item[key]
                    hidden_filters.append(hidden)

            shelf_sorts = []
            for shelf_sort in descendants(worksheet, "shelf-sort-v2"):
                def token(value: str | None) -> str:
                    match = re.search(
                        r"\[[^\]]+\]\.\[(?:[a-z]+:)?([^:\]]+)(?::[a-z0-9]+)*\]", value or "", re.I
                    )
                    return match.group(1) if match else str(value or "")
                shelf_sorts.append({
                    "dimension": token(attr(shelf_sort, "dimension-to-sort")),
                    "measure": token(attr(shelf_sort, "measure-to-sort-by")),
                    "measure_raw": attr(shelf_sort, "measure-to-sort-by"),
                    "direction": "descending" if (attr(shelf_sort, "direction") or "").lower() == "desc" else "ascending",
                    "shelf": attr(shelf_sort, "shelf"),
                })

            heat_scheme = None
            series_colors = series_color_field = None
            for encoding in descendants(worksheet, "encoding"):
                if attr(encoding, "attr") != "color":
                    continue
                encoding_type = attr(encoding, "type") or ""
                if encoding_type == "custom-interpolated":
                    colors = [text_of(item).strip().lower() for item in descendants(encoding, "color")]
                    if len(colors) >= 2:
                        heat_scheme = colors
                elif encoding_type == "interpolated" and heat_scheme is None:
                    palette_name = attr(encoding, "palette") or ""
                    if palette_name:
                        pattern = (
                            r"<color-palette[^>]*name=['\"]" + re.escape(palette_name)
                            + r"['\"][^>]*type=['\"]ordered-(?:sequential|diverging)['\"][^>]*>"
                            + r"(.*?)</color-palette>"
                        )
                        body = re.search(pattern, self.twb_text, re.I | re.DOTALL)
                        colors = re.findall(r"#[0-9a-fA-F]{6}", body.group(1) if body else "")
                        if len(colors) >= 2:
                            heat_scheme = [color.lower() for color in colors]
                if "interpolated" not in encoding_type and series_colors is None:
                    pairs = []
                    for mapping in children(encoding, "map"):
                        color = (attr(mapping, "to") or "").strip().lower()
                        bucket = first_child(mapping, "bucket")
                        member = unquote_value(text_of(bucket) if bucket is not None else None, null_is_none=True)
                        if re.fullmatch(r"#[0-9a-f]{6}", color) and member:
                            pairs.append({"member": member, "color": color})
                    if pairs:
                        series_colors = pairs
                        guid = self.guid_from_param(attr(encoding, "field"))
                        series_color_field = (self.columns_by_guid.get(guid or "") or {}).get("caption") or guid

            mark_labels_show = any(
                attr(fmt, "attr") == "mark-labels-show" and attr(fmt, "value") == "true"
                for rule in descendants(worksheet, "style-rule")
                if attr(rule, "element") == "mark"
                for fmt in children(rule, "format")
            )
            self.worksheets[name] = {
                "mark_class": mark_class, "geo_role": geo_role, "has_lat": has_lat,
                "has_long": has_long, "has_geometry": first_desc(worksheet, "geometry") is not None,
                "sort": sort_info, "shelf_sorts": shelf_sorts, "quick_calc_pcto": quick_calc_pcto,
                "heat_scheme": heat_scheme, "series_colors": series_colors,
                "series_color_field": series_color_field, "filters": filters,
                "hidden_filters": hidden_filters, "aggregations": aggregations,
                "channels": channels, "formats": formats, "calculations": calculations,
                "dual_axis": axis_synced, "measures": measures, "ref_marks": ref_marks,
                "axis_formats": axis_formats, "mark_labels_show": mark_labels_show,
                "rows_shelf": rows_shelf, "cols_shelf": cols_shelf,
                "is_crosstab": is_crosstab, "is_kpi": is_kpi,
                "display_title": self.worksheet_display_title(worksheet),
                "kpi_label": (kpi_ban or {}).get("label"),
                "kpi_value_font_size": (kpi_ban or {}).get("value_font_size"),
                "kpi_annotation_runs": (kpi_ban or {}).get("annotation_runs"),
            }

    @staticmethod
    def infer_automatic_kind(meta: dict[str, Any]) -> str:
        rows, cols = meta.get("rows_shelf") or {}, meta.get("cols_shelf") or {}
        fields = (rows.get("fields") or []) + (cols.get("fields") or [])
        dimensions = [item for item in fields if item.get("role") == "dim"]
        measures = [item for item in fields if item.get("role") == "measure"]
        continuous = [item for item in measures if not item.get("discrete")]
        has_date = any(str(item.get("derivation") or "").lower() in DATE_TRUNC_PREFIXES for item in dimensions)
        has_measure_values = rows.get("has_measure_values") or cols.get("has_measure_values")
        if has_date and continuous:
            return "line"
        if int(rows.get("cont_measure_count", 0)) >= 1 and int(cols.get("cont_measure_count", 0)) >= 1 and len(dimensions) <= 1:
            return "scatter"
        if dimensions and not continuous and not has_measure_values:
            return "table"
        return "bar"

    def chart_kind_for(self, meta: dict[str, Any] | None) -> str | None:
        if meta is None:
            return None
        mark_class = str(meta.get("mark_class") or "").lower()
        if mark_class in {"multipolygon", "polygon", "filled", "map"} or meta.get("has_geometry"):
            return "map-region"
        if meta.get("has_lat") and meta.get("has_long"):
            return "map-point"
        if mark_class == "ganttbar":
            running = any(
                isinstance(item, dict) and re.search(r"\bRUNNING_SUM\s*\(", str(item.get("formula") or ""), re.I)
                for item in meta.get("calculations") or []
            )
            return "waterfall" if running else "other"
        direct = {"bar": "bar", "line": "line", "area": "area", "pie": "pie"}
        if mark_class in direct:
            return direct[mark_class]
        if mark_class in {"circle", "shape"}:
            return "kpi" if meta.get("is_kpi") else "scatter"
        if mark_class in {"square", "text"}:
            return "pivot-table" if meta.get("is_crosstab") else ("kpi" if meta.get("is_kpi") else "table")
        if mark_class == "automatic":
            if meta.get("is_crosstab"):
                return "pivot-table"
            inferred = self.infer_automatic_kind(meta)
            return "scatter" if inferred == "scatter" else ("kpi" if meta.get("is_kpi") else inferred)
        if not mark_class:
            return "pivot-table" if meta.get("is_crosstab") else "other"
        return "other"

    @staticmethod
    def zone_kind(type_v2: str | None, caption: str | None) -> str:
        mapping = {
            "layout-basic": "container", "layout-flow": "container", "text": "text",
            "title": "title", "filter": "filter", "paramctrl": "parameter",
            "color": "legend", "empty": "spacer", "bitmap": "image",
            "dashboard-object": "dashboard-object",
        }
        if type_v2 is None:
            return "chart" if caption else "container"
        return mapping.get(type_v2, type_v2)

    def zone_style_fields(self, zone: ET.Element) -> dict[str, Any]:
        result: dict[str, Any] = {}
        corners: dict[str, int] = {}
        zone_style = first_child(zone, "zone-style")
        for fmt in children(zone_style, "format") if zone_style is not None else []:
            key, value = attr(fmt, "attr"), attr(fmt, "value")
            if not value:
                continue
            if key == "background-color" and value.lower() != "#00000000":
                result["fill_color"] = value
            elif key == "background-transparency":
                result["fill_transparency"] = value
            elif key in {"border-color", "border-style", "border-width"}:
                result[key.replace("-", "_")] = value
            elif key and re.fullmatch(r"border-(color|style|width)-(top|right|bottom|left)", key):
                match = re.fullmatch(r"border-(color|style|width)-(top|right|bottom|left)", key)
                prop, side = match.group(1), match.group(2)
                result.setdefault("border_sides", {}).setdefault(side, {})[prop] = int_value(value) if prop == "width" else value
            elif key == "corner-radius":
                result["corner_radius"] = int_value(value)
            elif key and re.fullmatch(r"corner-radius-(top|bottom)-(left|right)", key):
                corners[key.removeprefix("corner-radius-")] = int_value(value)
            elif key == "rounding":
                result["rounding"] = value
            elif key and re.fullmatch(r"margin(?:-(?:top|right|bottom|left))?", key):
                result.setdefault("margins", {})["all" if key == "margin" else key.removeprefix("margin-")] = int_value(value)
            elif key and re.fullmatch(r"padding(?:-(?:top|right|bottom|left))?", key):
                result.setdefault("paddings", {})["all" if key == "padding" else key.removeprefix("padding-")] = int_value(value)
        if corners:
            result["corner_radii"] = corners
            result.setdefault("corner_radius", max(corners.values()))
        return result

    def zone_text_fields(self, zone: ET.Element) -> dict[str, Any]:
        formatted = first_child(zone, "formatted-text")
        if formatted is None:
            return {}
        runs = []
        for run in children(formatted, "run"):
            value = text_of(run).replace("Æ", "")
            runs.append(compact({
                "text": value, "color": attr(run, "fontcolor") or None,
                "font_size": int_value(attr(run, "fontsize")) if attr(run, "fontsize") else None,
                "bold": attr(run, "bold") == "true", "font": attr(run, "fontname") or None,
                "italic": True if attr(run, "italic") == "true" else None,
                "underline": True if attr(run, "underline") == "true" else None,
                "align": {"1": "center", "2": "right"}.get(attr(run, "fontalignment") or ""),
                "break": "\n" in value,
            }))
        if not runs:
            return {}
        result: dict[str, Any] = {"text_runs": runs}
        zone_style = first_child(zone, "zone-style")
        for fmt in children(zone_style, "format") if zone_style is not None else []:
            if attr(fmt, "attr") == "text-align" and attr(fmt, "value") in {"center", "right"}:
                result["text_align"] = attr(fmt, "value")
        visible = [run for run in runs if str(run.get("text") or "").strip()]
        if "text_align" not in result and visible:
            alignments = list(dict.fromkeys(run.get("align") for run in visible))
            if len(alignments) == 1 and alignments[0] in {"center", "right"}:
                result["text_align"] = alignments[0]
        if len(visible) == 1 and self.zone_style_fields(zone).get("fill_color"):
            result["is_pill"] = True
        return result

    @staticmethod
    def zone_image_fields(zone: ET.Element) -> dict[str, Any]:
        result = {
            "image_path": attr(zone, "param"),
            "is_scaled": str(attr(zone, "is-scaled") or "") in {"1", "true"},
            "is_centered": str(attr(zone, "is-centered") or "") in {"1", "true"},
        }
        if attr(zone, "image-file-url") is not None:
            result["image_file_url"] = attr(zone, "image-file-url")
        return result

    def zone_button_fields(self, zone: ET.Element) -> dict[str, Any]:
        button = first_child(zone, "button")
        if button is None:
            return {}
        action = attr(button, "action") or ""
        if "goto-sheet" in action:
            intent = "navigate"
        elif first_desc(button, "export-button-action") is not None or attr(button, "button-click-action-metadata"):
            intent = f"export-{attr(button, 'button-click-action-metadata') or 'image'}"
        elif first_desc(button, "toggle-action") is not None or "toggle" in action:
            intent = "toggle"
        else:
            intent = "unknown"
        result: dict[str, Any] = {"button_intent": intent}
        target = re.search(r'window-id="?\{([0-9A-Fa-f-]+)\}', action)
        window = self.window_by_uuid.get("{" + target.group(1) + "}") if target else None
        if intent == "navigate" and window:
            result["button_nav_target"] = window.get("name")
            result["button_nav_target_class"] = window.get("class")
        caption = text_of(first_desc(button, "caption")).strip()
        if caption and not re.fullmatch(r"[.\s]+", caption):
            result["button_caption"] = caption
        result["button_tooltip"] = text_of(first_desc(button, "tooltip-text")) or None
        result["button_image_path"] = text_of(first_desc(button, "image-path")) or None
        result["button_type"] = attr(button, "button-type")
        font = first_desc(button, "button-caption-font-style")
        if font is not None:
            result["button_font_color"] = attr(font, "fontcolor")
            result["button_font_size"] = int_value(attr(font, "fontsize")) if attr(font, "fontsize") else None
        return compact(result)

    def build_zone_tree(self, zone: ET.Element) -> dict[str, Any]:
        type_v2, caption, parameter = attr(zone, "type-v2"), attr(zone, "name"), attr(zone, "param")
        kind = self.zone_kind(type_v2, caption)
        node: dict[str, Any] = {
            "id": attr(zone, "id"), "kind": kind, "caption": caption,
            "x_pct": pct(attr(zone, "x")), "y_pct": pct(attr(zone, "y")),
            "w_pct": pct(attr(zone, "w")), "h_pct": pct(attr(zone, "h")),
        }
        if type_v2 == "layout-flow":
            node["direction"] = "vert" if parameter == "vert" else "horz"
        if attr(zone, "is-fixed") == "true":
            node["is_fixed"] = True
        if attr(zone, "fixed-size") is not None:
            node["fixed_size"] = int_value(attr(zone, "fixed-size"))
        if kind == "image":
            node.update(self.zone_image_fields(zone))
            if (node.get("w_pct") or 0) >= 95 and (node.get("h_pct") or 0) >= 95:
                node["is_background"] = True
        node.update(self.zone_style_fields(zone))
        if attr(zone, "mode"):
            node["control_display"] = attr(zone, "mode")
        if kind in {"text", "title"}:
            node.update(self.zone_text_fields(zone))
        if kind == "dashboard-object":
            node.update(self.zone_button_fields(zone))
        if kind in {"filter", "parameter"}:
            info = self.columns_by_guid.get(self.guid_from_param(parameter) or "", {})
            node["filter_column_caption"] = info.get("caption")
            node["filter_column_datatype"] = info.get("datatype")
        nested = [self.build_zone_tree(item) for item in children(zone, "zone") if attr(item, "id") is not None]
        if nested:
            node["children"] = nested
        return node

    @staticmethod
    def trellis_arrangement(zones: list[dict[str, Any]]) -> str | None:
        if len(zones) < 2:
            return None
        xs, ys = [float(item.get("x_pct") or 0) for item in zones], [float(item.get("y_pct") or 0) for item in zones]
        widths, heights = [float(item.get("w_pct") or 0) for item in zones], [float(item.get("h_pct") or 0) for item in zones]
        width_median, height_median = median(widths), median(heights)
        if width_median <= 0 or height_median <= 0:
            return None
        x_aligned = max(xs) - min(xs) <= 0.5 * width_median
        y_aligned = max(ys) - min(ys) <= 0.5 * height_median
        def disjoint(spans: list[tuple[float, float]]) -> bool:
            ordered = sorted(spans)
            return all(left[1] <= right[0] + 1.0 for left, right in zip(ordered, ordered[1:]))
        if y_aligned and not x_aligned:
            return "cols" if disjoint([(x, x + width) for x, width in zip(xs, widths)]) else None
        if x_aligned and not y_aligned:
            return "rows" if disjoint([(y, y + height) for y, height in zip(ys, heights)]) else None
        if not x_aligned and not y_aligned:
            return "grid"
        return None

    def detect_trellis_groups(self, zones: list[dict[str, Any]]) -> list[dict[str, Any]]:
        charts = [
            zone for zone in zones
            if zone.get("kind") == "chart" and zone.get("chart_kind") in TRELLIS_KINDS
        ]
        annotated = []
        for zone in charts:
            measure_columns = sorted(
                str(item.get("column") or "") for item in zone.get("measures") or [] if item.get("column")
            )
            if not measure_columns:
                continue
            facets = {}
            for filter_spec in zone.get("filters") or []:
                members = filter_spec.get("members") or []
                datatype = str(filter_spec.get("datatype") or "")
                if (
                    not filter_spec.get("is_action") and filter_spec.get("kind") == "list"
                    and len(members) == 1 and datatype in {"", "string", "nominal"}
                ):
                    key = str(
                        filter_spec.get("column_caption") or filter_spec.get("column_guid")
                        or filter_spec.get("raw_param") or ""
                    )
                    if key:
                        facets.setdefault(key, {
                            "member": str(members[0]),
                            "caption": str(filter_spec.get("column_caption") or key),
                        })
            if facets:
                annotated.append({
                    "zone": zone, "signature": (zone.get("chart_kind"), tuple(measure_columns)),
                    "facets": facets,
                })
        cohorts: dict[tuple[Any, ...], list[dict[str, Any]]] = defaultdict(list)
        for item in annotated:
            cohorts[item["signature"]].append(item)
        groups, used = [], set()
        for cohort in cohorts.values():
            if len(cohort) < 3:
                continue
            field_keys = list(dict.fromkeys(key for item in cohort for key in item["facets"]))
            for field_key in field_keys:
                seen = set()
                members = []
                for item in cohort:
                    zone_id = item["zone"].get("id")
                    if field_key not in item["facets"] or zone_id in used:
                        continue
                    member = item["facets"][field_key]["member"]
                    if member not in seen:
                        seen.add(member)
                        members.append(item)
                if len(members) < 3:
                    continue
                orientation = self.trellis_arrangement([item["zone"] for item in members])
                if orientation is None:
                    continue
                ordered = sorted(members, key=lambda item: item["facets"][field_key]["member"].lower())
                used.update(item["zone"].get("id") for item in ordered)
                groups.append({
                    "field": ordered[0]["facets"][field_key]["caption"],
                    "chart_kind": ordered[0]["signature"][0], "orientation": orientation,
                    "members": [item["facets"][field_key]["member"] for item in ordered],
                    "zone_ids": [item["zone"].get("id") for item in ordered],
                    "captions": [item["zone"].get("caption") for item in ordered],
                })
        return groups

    def _flat_zone(self, zone: ET.Element) -> dict[str, Any]:
        type_v2, caption, view_ref = attr(zone, "type-v2"), attr(zone, "name"), attr(zone, "param")
        kind = self.zone_kind(type_v2, caption)
        worksheet = self.worksheets.get(caption or "")
        chart_kind = self.chart_kind_for(worksheet) if kind == "chart" else None
        inferred = bool(
            kind == "chart" and str((worksheet or {}).get("mark_class") or "").lower() == "automatic"
            and chart_kind != "kpi"
        )
        info = self.columns_by_guid.get(self.guid_from_param(view_ref) or "", {}) if kind in {"filter", "parameter"} else {}
        style = self.zone_style_fields(zone)
        text = self.zone_text_fields(zone) if kind in {"text", "title"} else {}
        image = self.zone_image_fields(zone) if kind == "image" else {}
        button = self.zone_button_fields(zone) if kind == "dashboard-object" else {}
        if kind == "image" and (pct(attr(zone, "w")) or 0) >= 95 and (pct(attr(zone, "h")) or 0) >= 95:
            image["is_background"] = True
        chart = worksheet or {}
        return {
            "id": attr(zone, "id"), "kind": kind, "caption": caption, "view_ref": view_ref,
            "x_pct": pct(attr(zone, "x")), "y_pct": pct(attr(zone, "y")),
            "w_pct": pct(attr(zone, "w")), "h_pct": pct(attr(zone, "h")),
            "chart_kind": chart_kind, "chart_kind_inferred": inferred,
            "display_title": chart.get("display_title"), "mark_class": chart.get("mark_class"),
            "geo_role": chart.get("geo_role"),
            "sort": chart.get("sort") if kind == "chart" else None,
            "shelf_sorts": chart.get("shelf_sorts") if kind == "chart" else None,
            "quick_calc_pcto": chart.get("quick_calc_pcto") if kind == "chart" else None,
            "heat_scheme": chart.get("heat_scheme") if kind == "chart" else None,
            "series_colors": chart.get("series_colors") if kind == "chart" else None,
            "series_color_field": chart.get("series_color_field") if kind == "chart" else None,
            "show_title": attr(zone, "show-title") != "false",
            "filters": chart.get("filters") if kind == "chart" else None,
            "hidden_filters": (chart.get("hidden_filters") or []) if kind == "chart" else None,
            "aggregations": chart.get("aggregations") if kind == "chart" else None,
            "channels": chart.get("channels") if kind == "chart" else None,
            "formats": chart.get("formats") if kind == "chart" else None,
            "calculations": chart.get("calculations") if kind == "chart" else None,
            "dual_axis": chart.get("dual_axis") if kind == "chart" else None,
            "measures": chart.get("measures") if kind == "chart" else None,
            "ref_marks": chart.get("ref_marks") if kind == "chart" else None,
            "axis_formats": chart.get("axis_formats") if kind == "chart" else None,
            "mark_labels_show": chart.get("mark_labels_show") if kind == "chart" else None,
            "rows_shelf": chart.get("rows_shelf") if kind == "chart" else None,
            "cols_shelf": chart.get("cols_shelf") if kind == "chart" else None,
            "is_crosstab": chart.get("is_crosstab") if kind == "chart" else None,
            "is_kpi": chart.get("is_kpi") if kind == "chart" else None,
            "kpi_label": chart.get("kpi_label") if kind == "chart" else None,
            "kpi_value_font_size": chart.get("kpi_value_font_size") if kind == "chart" else None,
            "kpi_annotation_runs": chart.get("kpi_annotation_runs") if kind == "chart" else None,
            "filter_column_caption": info.get("caption") if kind in {"filter", "parameter"} else None,
            "filter_column_datatype": info.get("datatype") if kind in {"filter", "parameter"} else None,
            "fill_color": style.get("fill_color"), "border_color": style.get("border_color"),
            "control_display": attr(zone, "mode") or None,
            "text_runs": text.get("text_runs"), "text_align": text.get("text_align"),
            "is_pill": text.get("is_pill"), "corner_radius": style.get("corner_radius"),
            "rounding": style.get("rounding"), "border_width": style.get("border_width"),
            "is_fixed": True if attr(zone, "is-fixed") == "true" else None,
            "fixed_size": int_value(attr(zone, "fixed-size")) if attr(zone, "fixed-size") else None,
            "image_path": image.get("image_path"),
            "is_scaled": image.get("is_scaled") if kind == "image" else None,
            "is_centered": image.get("is_centered") if kind == "image" else None,
            "image_file_url": image.get("image_file_url"), "is_background": image.get("is_background"),
            "button_intent": button.get("button_intent"),
            "button_nav_target": button.get("button_nav_target"),
            "button_nav_target_class": button.get("button_nav_target_class"),
            "button_caption": button.get("button_caption"), "button_tooltip": button.get("button_tooltip"),
            "button_image_path": button.get("button_image_path"), "button_type": button.get("button_type"),
            "button_font_color": button.get("button_font_color"), "button_font_size": button.get("button_font_size"),
        }

    def parse_dashboards(self) -> list[dict[str, Any]]:
        dashboards = []
        for dashboard in descendants(self.root, "dashboard"):
            name = attr(dashboard, "name")
            zones_root = first_child(dashboard, "zones")
            page_id = attr(zones_root, "id")
            if not self.dashboard_in_scope(name, page_id):
                continue
            root = zones_root or dashboard
            zones, seen = [], set()
            for zone in descendants(root, "zone"):
                zone_id = attr(zone, "id")
                if zone_id is None or zone_id in seen:
                    continue
                seen.add(zone_id)
                zones.append(self._flat_zone(zone))
            is_story = attr(dashboard, "type-v2") == "storyboard" or first_desc(dashboard, "story-points") is not None
            zone_tree = [
                self.build_zone_tree(zone) for zone in children(zones_root, "zone")
                if zones_root is not None and attr(zone, "id") is not None
            ]
            size = first_child(dashboard, "size")
            width, height = int_value(attr(size, "maxwidth")), int_value(attr(size, "maxheight"))
            canvas = {
                "w": width, "h": height, "sizing_mode": attr(size, "sizing-mode")
            } if width > 0 and height > 0 else None
            result = {
                "dashboard": name, "is_story": is_story,
                "emit_page": (
                    not self.visible_dashboard_windows
                    or name in self.visible_dashboard_windows or name in self.story_captured_sheets
                ),
                "canvas_px": canvas,
                "style_rules": {
                    "workbook": self.workbook_style_rules,
                    "dashboard": self.style_rules_for(dashboard),
                },
                "zones": zones, "zone_tree": zone_tree, "brand_palette": self.brand_palette,
            }
            trellis = self.detect_trellis_groups(zones)
            if trellis:
                result["trellis"] = trellis
            dashboards.append(result)
        return dashboards

    def synthetic_dashboards(self) -> list[dict[str, Any]]:
        result = []
        for name, meta in self.worksheets.items():
            if not self.dashboard_in_scope(name, None):
                continue
            result.append({
                "dashboard": f"[synthetic] {name}",
                "style_rules": {"workbook": self.workbook_style_rules, "dashboard": {}},
                "brand_palette": self.brand_palette, "canvas_px": None,
                "zones": [{
                    "id": "1", "kind": "chart", "caption": name, "view_ref": None,
                    "x_pct": 0.0, "y_pct": 0.0, "w_pct": 100.0, "h_pct": 100.0,
                    "chart_kind": self.chart_kind_for(meta), "mark_class": meta.get("mark_class"),
                    "geo_role": meta.get("geo_role"), "sort": meta.get("sort"),
                    "shelf_sorts": meta.get("shelf_sorts"), "quick_calc_pcto": meta.get("quick_calc_pcto"),
                    "series_colors": meta.get("series_colors"),
                    "series_color_field": meta.get("series_color_field"), "filters": meta.get("filters"),
                    "hidden_filters": meta.get("hidden_filters") or [],
                    "aggregations": meta.get("aggregations"), "channels": meta.get("channels"),
                    "formats": meta.get("formats"), "calculations": meta.get("calculations"),
                    "dual_axis": meta.get("dual_axis"), "measures": meta.get("measures"),
                    "ref_marks": meta.get("ref_marks"), "axis_formats": meta.get("axis_formats"),
                    "mark_labels_show": meta.get("mark_labels_show"),
                    "rows_shelf": meta.get("rows_shelf"), "cols_shelf": meta.get("cols_shelf"),
                    "is_crosstab": meta.get("is_crosstab"), "is_kpi": meta.get("is_kpi"),
                    "kpi_label": meta.get("kpi_label"),
                    "kpi_value_font_size": meta.get("kpi_value_font_size"),
                    "kpi_annotation_runs": meta.get("kpi_annotation_runs"),
                    "filter_column_caption": None, "filter_column_datatype": None,
                }],
            })
        return result

    def parse_parameters(self) -> list[dict[str, Any]]:
        parameters = []
        for column in descendants(self.root, "column"):
            if attr(column, "param-domain-type") is None:
                continue
            name = attr(column, "name") or ""
            range_node = first_child(column, "range")
            parameters.append({
                "name": name, "caption": attr(column, "caption") or re.sub(r"^\[|\]$", "", name),
                "datatype": attr(column, "datatype"), "param_domain": attr(column, "param-domain-type"),
                "default_value": unquote_value(attr(column, "value")),
                "members": [
                    unquote_value(attr(member, "value"))
                    for members in descendants(column, "members")
                    for member in children(members, "member")
                ],
                "min": attr(range_node, "min"), "max": attr(range_node, "max"),
                "step": attr(range_node, "granularity"),
            })
        by_name: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for parameter in parameters:
            by_name[parameter["name"]].append(parameter)
        return [
            max(items, key=lambda item: (len(item.get("members") or []), bool(str(item.get("default_value") or ""))))
            for items in by_name.values()
        ]

    def attach_parameter_refs(self, parameters: list[dict[str, Any]]) -> None:
        aliases = {}
        for parameter in parameters:
            caption = parameter.get("caption")
            if not caption:
                continue
            aliases[str(caption)] = str(caption)
            name = re.sub(r"^\[|\]$", "", str(parameter.get("name") or ""))
            if name:
                aliases[name] = str(caption)
        for worksheet in self.worksheets.values():
            for calculation in worksheet.get("calculations") or []:
                formula = str(calculation.get("formula") or "")
                refs = [
                    aliases.get(value, value)
                    for value in re.findall(
                        r"\[Parameters?(?:\s*\([^)]*\))?\]\s*\.\s*\[([^\]]+)\]", formula, re.I
                    )
                ]
                refs.extend(
                    aliases[value] for value in re.findall(r"\[([^\]/]+)\]", formula) if value in aliases
                )
                refs = list(dict.fromkeys(refs))
                if refs:
                    calculation["parameter_refs"] = refs

    def parse_column_aliases(self) -> dict[str, list[dict[str, str]]]:
        result: dict[str, list[dict[str, str]]] = {}
        for column in descendants(self.root, "column"):
            name = attr(column, "name") or ""
            if not name or name == "[:Measure Names]":
                continue
            caption = attr(column, "caption") or re.sub(r"^\[|\]$", "", name)
            pairs = []
            aliases_node = first_child(column, "aliases")
            for alias in children(aliases_node, "alias") if aliases_node is not None else []:
                key, value = unquote_value(attr(alias, "key")), attr(alias, "value")
                if key is None or value is None or not value:
                    continue
                if re.match(r"^\[(?:federated|usr|sum|ctd|min|max|avg|none):", key, re.I):
                    continue
                if re.match(r"^\[[\w-]+\]\.\[", key):
                    continue
                pairs.append({"key": key, "value": value})
            if pairs and len(pairs) > len(result.get(caption, [])):
                result[caption] = pairs
        return result

    def parse_shared_filters(self) -> list[dict[str, Any]]:
        datasource_names = {attr(item, "name") for item in self.top_level_datasources() if attr(item, "name")}
        result = []
        for shared_view in descendants(self.root, "shared-view"):
            name = attr(shared_view, "name")
            for filter_node in children(shared_view, "filter"):
                spec = self.normalize_filter(filter_node)
                spec["shared_view"] = name
                if spec.get("ui_domain") == "database" or name in datasource_names:
                    spec["is_datasource_filter"] = True
                result.append(spec)
        return result

    def parse_datasource_filters(self) -> list[dict[str, Any]]:
        result = []
        for datasource in self.top_level_datasources():
            label = attr(datasource, "caption") or attr(datasource, "name") or ""
            name = attr(datasource, "name") or ""
            if label.startswith("Parameter"):
                continue
            scoped = [(item, "datasource") for item in children(datasource, "filter")]
            for extract in children(datasource, "extract"):
                scoped.extend((item, "extract") for item in children(extract, "filter"))
            for filter_node, scope in scoped:
                spec = self.normalize_filter(filter_node)
                spec.update({
                    "datasource": label, "datasource_name": name, "filter_scope": scope
                })
                result.append(spec)
        return result

    def parse_stories(self, dashboards: list[dict[str, Any]]) -> list[dict[str, Any]]:
        dashboard_names = {item.get("dashboard") for item in dashboards}
        stories = []
        for story_points in descendants(self.root, "story-points"):
            ancestor = self.parent.get(story_points)
            story_name = None
            while ancestor is not None:
                if attr(ancestor, "name"):
                    story_name = attr(ancestor, "name")
                    break
                ancestor = self.parent.get(ancestor)
            points = []
            for point in children(story_points, "story-point"):
                caption = attr(point, "caption")
                if not caption:
                    caption = text_of(first_child(point, "caption")) or None
                captured = attr(point, "captured-sheet")
                kind = (
                    "dashboard" if captured in dashboard_names
                    else "worksheet" if captured in self.worksheets
                    else "unknown"
                )
                points.append({
                    "id": attr(point, "id"), "caption": caption,
                    "captured_sheet": captured, "sheet_kind": kind,
                })
            if points:
                stories.append({"story": story_name, "points": points})
        return stories

    def run(self) -> tuple[list[dict[str, Any]], dict[str, Any], list[dict[str, Any]]]:
        self.parse_worksheets()
        dashboards = self.parse_dashboards()
        if not dashboards and self.worksheets:
            dashboards = self.synthetic_dashboards()
        parameters = self.parse_parameters()
        self.attach_parameter_refs(parameters)
        shared_filters = self.parse_shared_filters()
        datasource_filters = self.parse_datasource_filters()
        stories = self.parse_stories(dashboards)
        scoped_worksheets = self.worksheets
        scoped_shared_filters = shared_filters
        if self.dashboard_scoping:
            used = {
                zone.get("caption")
                for dashboard in dashboards for zone in dashboard.get("zones", [])
                if zone.get("caption") in self.worksheets
            }
            scoped_worksheets = {name: value for name, value in self.worksheets.items() if name in used}
            used_filter_captions = {
                item.get("column_caption")
                for worksheet in scoped_worksheets.values()
                for item in worksheet.get("filters") or []
                if item.get("column_caption")
            }
            scoped_shared_filters = [
                item for item in shared_filters
                if item.get("column_caption") is None or item.get("column_caption") in used_filter_captions
            ]
        meta = {
            "worksheets": scoped_worksheets, "stories": stories,
            "shared_filters": scoped_shared_filters, "datasource_filters": datasource_filters,
            "parameters": parameters, "column_aliases": self.parse_column_aliases(),
            "column_formats": self.column_formats, "columns_by_guid": self.columns_by_guid,
        }
        return dashboards, meta, stories


def parse_cli(argv: list[str]) -> tuple[Path, Path, list[str], list[str]]:
    dashboard_filters, page_filters, positional = [], [], []
    index = 0
    while index < len(argv):
        value = argv[index]
        if value in {"--dashboard", "--page"}:
            option_value = argv[index + 1] if index + 1 < len(argv) else ""
            (dashboard_filters if value == "--dashboard" else page_filters).append(option_value)
            index += 2
        else:
            positional.append(value)
            index += 1
    usage = (
        'usage: parse-twb-layout.py <workbook-content.twb> <out.json> '
        '[--dashboard "<name>"] [--page <id>]'
    )
    if len(positional) < 2:
        raise SystemExit(usage)
    return Path(positional[0]), Path(positional[1]), dashboard_filters, page_filters


def main(argv: list[str] | None = None) -> int:
    twb_path, out_path, dashboard_filters, page_filters = parse_cli(
        list(sys.argv[1:] if argv is None else argv)
    )
    parser = TableauLayoutParser(twb_path, out_path, dashboard_filters, page_filters)
    dashboards, meta, stories = parser.run()
    if stories:
        story_path = out_path.resolve().parent / "story-plan.json"
        json_write(story_path, stories)
        points = sum(len(story["points"]) for story in stories)
        print(
            f"wrote {story_path} ({len(stories)} story(ies), {points} story point(s)) — "
            "run scripts/build-story-pages.rb to emit one Sigma page per story point"
        )
    meta_path = Path(re.sub(r"\.json$", "-meta.json", str(out_path)))
    json_write(meta_path, meta)
    scope = (
        f" [scoped: {', '.join(dashboard_filters + page_filters)}]"
        if dashboard_filters or page_filters else ""
    )
    print(
        f"wrote {meta_path} ({len(meta['worksheets'])} worksheets, "
        f"{len(meta['shared_filters'])} shared filters){scope}"
    )
    json_write(out_path, dashboards)
    zone_count = sum(len(dashboard["zones"]) for dashboard in dashboards)
    print(f"wrote {out_path} ({len(dashboards)} dashboards, {zone_count} zones total)")
    for dashboard in dashboards:
        print(f"  [{dashboard['dashboard']}]")
        for zone in dashboard["zones"]:
            if zone["kind"] == "container" and zone["caption"] is None:
                continue
            caption = str(zone["caption"] or "(no caption)")[:39].ljust(40)
            extras = []
            if zone.get("chart_kind"):
                extras.append(f"chart_kind={zone['chart_kind']}")
            if zone.get("mark_class"):
                extras.append(f"mark={zone['mark_class']}")
            if zone.get("geo_role"):
                extras.append(f"geo={zone['geo_role']}")
            position = (
                f"x={zone['x_pct']}% y={zone['y_pct']}% "
                f"w={zone['w_pct']}% h={zone['h_pct']}%"
            )
            print(f"    {zone['kind']:<8} {caption} {position:<45} {' '.join(extras)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
