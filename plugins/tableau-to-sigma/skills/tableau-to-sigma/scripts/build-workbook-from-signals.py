#!/usr/bin/env python3
"""Build a customer-local Sigma workbook spec from parsed Tableau signals.

The builder is deliberately conservative.  It emits native text, controls,
KPI, line, and bar elements only when every required field can be resolved
from ``dashboard-layout-meta.json``.  Any unbound or unsupported leaf zone is
written to a structured residues file and blocks the workbook output.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from xml.sax.saxutils import quoteattr


SUPPORTED_CHART_KINDS = {"kpi", "line", "bar"}
STRUCTURAL_ZONE_KINDS = {"container", "spacer", "empty"}
DATE_DERIVATIONS = {
    "tyr": "year",
    "yr": "year",
    "y": "year",
    "tqr": "quarter",
    "qr": "quarter",
    "q": "quarter",
    "tmn": "month",
    "mn": "month",
    "m": "month",
    "twk": "week",
    "wk": "week",
    "w": "week",
    "tdy": "day",
    "dy": "day",
    "d": "day",
    "thr": "hour",
    "hr": "hour",
    "h": "hour",
    "tmi": "minute",
    "mi": "minute",
    "tsc": "second",
    "sc": "second",
}
AGGREGATIONS = {
    "sum": "Sum",
    "avg": "Avg",
    "average": "Avg",
    "min": "Min",
    "max": "Max",
    "count": "Count",
    "countd": "CountDistinct",
    "cntd": "CountDistinct",
    "ctd": "CountDistinct",
    "median": "Median",
}


def read_json(path: Path) -> Any:
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def slug(value: object, fallback: str = "item") -> str:
    clean = re.sub(r"[^a-z0-9]+", "-", str(value or "").lower()).strip("-")
    return clean[:48] or fallback


def stable_id(prefix: str, value: object) -> str:
    raw = str(value or "")
    digest = hashlib.sha1(raw.encode("utf-8")).hexdigest()[:8]
    return f"{prefix}-{slug(raw)}-{digest}"


def strip_brackets(value: object) -> str:
    text = str(value or "").strip()
    return text[1:-1] if len(text) > 1 and text[0] == "[" and text[-1] == "]" else text


def field_key_from_reference(value: object) -> str:
    text = str(value or "").strip()
    match = re.search(r"\[([^\[\]]+)\]\s*$", text)
    key = match.group(1) if match else strip_brackets(text)
    parts = re.match(r"^[a-z]+:(.*?):[a-z]+(?::\d+)?$", key, re.IGNORECASE)
    return parts.group(1) if parts else key


def sigma_format(tableau_format: object) -> dict[str, str] | None:
    value = str(tableau_format or "")
    if not value:
        return None
    if "%" in value or value.lower().startswith("p"):
        decimals = len((re.search(r"\.([0#]+)", value) or [None, ""])[1])
        return {"kind": "percent", "formatString": f",.{decimals}%"}
    if "$" in value:
        decimals = len((re.search(r"\.([0#]+)", value) or [None, ""])[1])
        return {"kind": "number", "formatString": f"$,.{decimals}f"}
    return None


@dataclass(frozen=True)
class Field:
    key: str
    caption: str
    datatype: str


class WorkbookBuilder:
    def __init__(
        self,
        layout: list[dict[str, Any]],
        meta: dict[str, Any],
        *,
        data_model_id: str,
        element_id: str,
        folder_id: str,
        data_model_element_name: str,
        title: str | None = None,
    ) -> None:
        if not isinstance(layout, list):
            raise ValueError("dashboard-layout.json must contain an array")
        if not isinstance(meta, dict):
            raise ValueError("dashboard-layout-meta.json must contain an object")
        self.layout = layout
        self.meta = meta
        self.data_model_id = data_model_id
        self.element_id = element_id
        self.folder_id = folder_id
        self.source_name = data_model_element_name.strip()
        if not all((self.data_model_id, self.element_id, self.folder_id, self.source_name)):
            raise ValueError(
                "data model id, element id/name, and folder id must be non-empty"
            )
        self.title = title or self._default_title()
        self.residues: list[dict[str, Any]] = []
        self.dispositions: list[dict[str, Any]] = []
        self.master_fields: dict[str, Field] = {}
        self.master_ids: dict[str, str] = {}

    def _default_title(self) -> str:
        visible = [
            str(item.get("dashboard") or "").strip()
            for item in self.layout
            if item.get("emit_page") is not False
        ]
        return visible[0] if len(visible) == 1 and visible[0] else "Tableau Migration"

    def residue(
        self,
        dashboard: str,
        zone: dict[str, Any],
        code: str,
        reason: str,
        **signals: Any,
    ) -> None:
        row = {
            "dashboard": dashboard,
            "zoneId": str(zone.get("id") or ""),
            "zoneKind": zone.get("kind"),
            "chartKind": zone.get("chart_kind"),
            "caption": zone.get("caption"),
            "reasonCode": code,
            "reason": reason,
        }
        if signals:
            row["signals"] = signals
        self.residues.append(row)

    def disposition(
        self, dashboard: str, zone: dict[str, Any], status: str, element_id: str | None = None
    ) -> None:
        row = {
            "dashboard": dashboard,
            "zoneId": str(zone.get("id") or ""),
            "zoneKind": zone.get("kind"),
            "status": status,
        }
        if element_id:
            row["elementId"] = element_id
        self.dispositions.append(row)

    def resolve_field(self, reference: object) -> Field | None:
        key = field_key_from_reference(reference)
        columns = self.meta.get("columns_by_guid") or {}
        info = columns.get(key)
        if not isinstance(info, dict):
            matches = [
                (candidate, value)
                for candidate, value in columns.items()
                if isinstance(value, dict)
                and str(value.get("caption") or "").strip().casefold() == key.strip().casefold()
            ]
            if len(matches) == 1:
                key, info = matches[0]
            else:
                return None
        caption = str(info.get("caption") or key).strip()
        if (
            not caption
            or any(token in caption for token in "[]")
            or any(token in self.source_name for token in "[]")
        ):
            return None
        return Field(key=str(key), caption=caption, datatype=str(info.get("datatype") or ""))

    def master_column(self, field: Field) -> str | None:
        existing = self.master_fields.get(field.key)
        if existing:
            return self.master_ids[field.key]
        if any(
            current.caption.casefold() == field.caption.casefold() and current.key != field.key
            for current in self.master_fields.values()
        ):
            return None
        column_id = stable_id("master-col", field.key)
        self.master_fields[field.key] = field
        self.master_ids[field.key] = column_id
        return column_id

    def _shelf_fields(self, zone: dict[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        fields = [
            item
            for shelf in ("cols_shelf", "rows_shelf")
            for item in (zone.get(shelf) or {}).get("fields") or []
            if isinstance(item, dict)
        ]
        dimensions = [item for item in fields if item.get("role") == "dim"]
        measures = [item for item in fields if item.get("role") == "measure"]
        if not measures:
            measures = [
                {
                    "guid": field_key_from_reference(item.get("column")),
                    "role": "measure",
                    "derivation": item.get("derivation"),
                }
                for item in zone.get("measures") or []
                if isinstance(item, dict)
            ]
        return dimensions, measures

    @staticmethod
    def _derivation(zone: dict[str, Any], field: dict[str, Any]) -> str:
        value = str(field.get("derivation") or "").lower()
        if value and value != "none":
            return value
        key = str(field.get("guid") or "")
        aggregations = zone.get("aggregations") or {}
        for candidate in (key, f"[{key}]"):
            if candidate in aggregations:
                return str(aggregations[candidate] or "").lower()
        return value

    def _field_format(self, zone: dict[str, Any], field: Field) -> dict[str, str] | None:
        for reference, value in (zone.get("formats") or {}).items():
            if field_key_from_reference(reference) == field.key:
                return sigma_format(value)
        return sigma_format((self.meta.get("column_formats") or {}).get(field.caption))

    def build_chart(self, dashboard: str, zone: dict[str, Any]) -> dict[str, Any] | None:
        chart_kind = str(zone.get("chart_kind") or "")
        if chart_kind not in SUPPORTED_CHART_KINDS:
            self.residue(
                dashboard,
                zone,
                "unsupported-chart-kind",
                "automatic builder supports only native KPI, line, and bar charts",
                supported=sorted(SUPPORTED_CHART_KINDS),
            )
            return None
        if zone.get("dual_axis"):
            self.residue(
                dashboard,
                zone,
                "unsupported-dual-axis",
                "dual-axis semantics cannot be bound to a single native line/bar shape",
            )
            return None
        filters = zone.get("filters") or []
        if filters:
            self.residue(
                dashboard,
                zone,
                "unsupported-chart-filter",
                "worksheet filters/actions require explicit target and value semantics",
                filters=filters,
            )
            return None

        dimensions, measures = self._shelf_fields(zone)
        expected_dimensions = 0 if chart_kind == "kpi" else 1
        if len(dimensions) != expected_dimensions or not measures:
            self.residue(
                dashboard,
                zone,
                "ambiguous-chart-fields",
                "chart shelves do not provide the required dimension/measure binding",
                dimensionCount=len(dimensions),
                measureCount=len(measures),
            )
            return None
        if chart_kind == "kpi" and len(measures) != 1:
            self.residue(
                dashboard,
                zone,
                "ambiguous-kpi-measure",
                "a KPI requires exactly one mechanically selected measure",
                measureCount=len(measures),
            )
            return None

        resolved_dimensions = [self.resolve_field(item.get("guid")) for item in dimensions]
        resolved_measures = [self.resolve_field(item.get("guid")) for item in measures]
        missing = [
            str(item.get("guid") or item.get("raw") or "")
            for item, resolved in zip(dimensions + measures, resolved_dimensions + resolved_measures)
            if resolved is None
        ]
        derivations = [self._derivation(zone, item) for item in measures]
        unsupported_aggs = sorted(
            {value for value in derivations if value not in AGGREGATIONS}
        )
        if missing or unsupported_aggs:
            self.residue(
                dashboard,
                zone,
                "unbound-chart-field",
                "one or more chart fields or aggregations cannot be bound safely",
                fields=missing,
                aggregations=unsupported_aggs,
            )
            return None

        element_id = stable_id("chart", f"{dashboard}:{zone.get('id')}")
        columns: list[dict[str, Any]] = []
        dimension_column_id = None
        if resolved_dimensions:
            field = resolved_dimensions[0]
            master_id = self.master_column(field)
            if not master_id:
                self.residue(
                    dashboard,
                    zone,
                    "ambiguous-master-column",
                    "two source fields resolve to the same display caption",
                    caption=field.caption,
                )
                return None
            dimension_column_id = f"{element_id}-dimension"
            formula = f"[Master/{field.caption}]"
            grain = DATE_DERIVATIONS.get(str(dimensions[0].get("derivation") or "").lower())
            if grain:
                formula = f'DateTrunc("{grain}", {formula})'
            dimension_column = {
                "id": dimension_column_id,
                "name": field.caption,
                "formula": formula,
            }
            field_format = self._field_format(zone, field)
            if field_format:
                dimension_column["format"] = field_format
            columns.append(dimension_column)

        measure_ids = []
        for index, (field, derivation) in enumerate(zip(resolved_measures, derivations), 1):
            if not self.master_column(field):
                self.residue(
                    dashboard,
                    zone,
                    "ambiguous-master-column",
                    "two source fields resolve to the same display caption",
                    caption=field.caption,
                )
                return None
            column_id = f"{element_id}-measure-{index}"
            measure_ids.append(column_id)
            item = {
                "id": column_id,
                "name": field.caption,
                "formula": f"{AGGREGATIONS[derivation]}([Master/{field.caption}])",
            }
            field_format = self._field_format(zone, field)
            if field_format:
                item["format"] = field_format
            columns.append(item)

        element: dict[str, Any] = {
            "id": element_id,
            "kind": "kpi-chart" if chart_kind == "kpi" else f"{chart_kind}-chart",
            "name": str(zone.get("display_title") or zone.get("caption") or chart_kind.title()),
            "source": {"kind": "table", "elementId": "master"},
            "columns": columns,
        }
        if chart_kind == "kpi":
            element["value"] = {"columnId": measure_ids[0]}
        else:
            element["xAxis"] = {"columnId": dimension_column_id}
            element["yAxis"] = {"columnIds": measure_ids}
            if chart_kind == "bar":
                rows = (zone.get("rows_shelf") or {}).get("fields") or []
                cols = (zone.get("cols_shelf") or {}).get("fields") or []
                if any(item.get("role") == "dim" for item in rows) and any(
                    item.get("role") == "measure" for item in cols
                ):
                    element["orientation"] = "horizontal"
            sort = zone.get("sort") or {}
            direction = str(sort.get("direction") or "").lower()
            if direction in {"asc", "ascending", "desc", "descending"}:
                element["xAxis"]["sort"] = {
                    "by": measure_ids[0],
                    "direction": "descending" if direction.startswith("desc") else "ascending",
                }
            if zone.get("mark_labels_show"):
                element["dataLabel"] = {"labels": "shown"}
        return element

    def build_control(self, dashboard: str, zone: dict[str, Any]) -> dict[str, Any] | None:
        caption = str(zone.get("filter_column_caption") or "").strip()
        field = self.resolve_field(zone.get("view_ref")) or self.resolve_field(caption)
        if not field:
            self.residue(
                dashboard,
                zone,
                "unbound-control-field",
                "filter zone has no unique field in dashboard-layout-meta.json",
                field=caption,
            )
            return None
        master_id = self.master_column(field)
        if not master_id:
            self.residue(
                dashboard,
                zone,
                "ambiguous-master-column",
                "two source fields resolve to the same display caption",
                caption=field.caption,
            )
            return None
        element_id = stable_id("control", f"{dashboard}:{zone.get('id')}")
        control: dict[str, Any] = {
            "id": element_id,
            "kind": "control",
            "controlId": stable_id("filter", f"{dashboard}:{field.key}"),
            "name": field.caption,
            "filters": [
                {
                    "source": {"kind": "table", "elementId": "master"},
                    "columnId": master_id,
                }
            ],
        }
        datatype = field.datatype.lower()
        if datatype in {"date", "datetime"}:
            control.update(
                {
                    "controlType": "date-range",
                    "mode": "between",
                    "includeNulls": "when-no-value-is-selected",
                }
            )
        elif datatype in {"integer", "real", "number", "float"}:
            control.update(
                {
                    "controlType": "number-range",
                    "includeNulls": "when-no-value-is-selected",
                }
            )
        elif datatype in {"string", "nominal", "boolean"}:
            control.update(
                {
                    "controlType": "list",
                    "mode": "include",
                    "selectionMode": "multiple",
                    "values": [],
                    "source": {
                        "kind": "source",
                        "source": {"kind": "table", "elementId": "master"},
                        "columnId": master_id,
                    },
                }
            )
        else:
            self.residue(
                dashboard,
                zone,
                "unsupported-control-datatype",
                "filter datatype cannot be mapped to a Sigma control safely",
                datatype=field.datatype,
            )
            return None
        return control

    def build_text(self, dashboard: str, zone: dict[str, Any]) -> dict[str, Any] | None:
        runs = zone.get("text_runs") or []
        body = "".join(str(item.get("text") or "") for item in runs if isinstance(item, dict))
        body = body.replace("Æ", "").strip()
        if not body or re.search(r"<\[[^>]+]>", body):
            self.residue(
                dashboard,
                zone,
                "unbound-text",
                "text is empty or contains a dynamic Tableau token",
                text=body,
            )
            return None
        if zone.get("kind") == "title" or max(
            [int(item.get("font_size") or 0) for item in runs if isinstance(item, dict)] or [0]
        ) >= 16:
            body = f"# {body}"
        return {
            "id": stable_id("text", f"{dashboard}:{zone.get('id')}"),
            "kind": "text",
            "name": str(zone.get("caption") or "Text"),
            "body": body,
        }

    @staticmethod
    def placement(element_id: str, zone: dict[str, Any]) -> str:
        x = max(0.0, min(100.0, float(zone.get("x_pct") or 0.0)))
        y = max(0.0, min(100.0, float(zone.get("y_pct") or 0.0)))
        width = max(0.1, float(zone.get("w_pct") or 100.0))
        height = max(0.1, float(zone.get("h_pct") or 10.0))
        col_start = max(1, min(24, math.floor(x * 24 / 100) + 1))
        col_end = max(col_start + 1, min(25, math.ceil((x + width) * 24 / 100) + 1))
        row_start = max(1, min(100, math.floor(y) + 1))
        row_end = max(row_start + 1, min(101, math.ceil(y + height) + 1))
        return (
            f"  <Element elementId={quoteattr(element_id)} "
            f'gridColumn="{col_start} / {col_end}" gridRow="{row_start} / {row_end}"/>'
        )

    def build(self) -> tuple[dict[str, Any], dict[str, Any]]:
        content_elements: list[dict[str, Any]] = []
        pages = [
            {
                "id": "page-data",
                "name": "Data",
                "visibility": "hidden",
                "pageWidth": "full",
            }
        ]
        page_layouts: list[str] = []
        visible_dashboards = 0

        for dashboard_index, dashboard in enumerate(self.layout, 1):
            if not isinstance(dashboard, dict) or dashboard.get("emit_page") is False:
                continue
            visible_dashboards += 1
            dashboard_name = str(dashboard.get("dashboard") or f"Dashboard {dashboard_index}")
            page_id = stable_id("page", dashboard_name)
            pages.append({"id": page_id, "name": dashboard_name, "pageWidth": "full"})
            placements = []
            chart_captions = {
                str(zone.get("caption") or "")
                for zone in dashboard.get("zones") or []
                if zone.get("kind") == "chart"
            }
            for zone in dashboard.get("zones") or []:
                if not isinstance(zone, dict):
                    continue
                kind = str(zone.get("kind") or "")
                element = None
                if kind in STRUCTURAL_ZONE_KINDS:
                    self.disposition(dashboard_name, zone, "structural-layout-signal")
                    continue
                if kind == "legend" and str(zone.get("caption") or "") in chart_captions:
                    self.disposition(dashboard_name, zone, "chart-managed-legend")
                    continue
                if kind == "chart":
                    element = self.build_chart(dashboard_name, zone)
                elif kind == "filter":
                    element = self.build_control(dashboard_name, zone)
                elif kind in {"text", "title"}:
                    element = self.build_text(dashboard_name, zone)
                elif kind == "parameter":
                    self.residue(
                        dashboard_name,
                        zone,
                        "unbound-parameter",
                        "parameter control effects require an explicit formula/control binding",
                    )
                else:
                    self.residue(
                        dashboard_name,
                        zone,
                        "unsupported-zone-kind",
                        "zone has no safe native automatic workbook binding",
                        button_intent=zone.get("button_intent"),
                        image_path=zone.get("image_path"),
                    )
                if element is not None:
                    content_elements.append(element)
                    placements.append(self.placement(element["id"], zone))
                    self.disposition(dashboard_name, zone, "emitted", element["id"])
            page_layouts.append(
                "\n".join(
                    [
                        (
                            f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
                            f'gridTemplateRows="auto" id={quoteattr(page_id)}>'
                        ),
                        *placements,
                        "</Page>",
                    ]
                )
            )

        if not visible_dashboards:
            self.residue(
                "",
                {},
                "no-visible-dashboard",
                "layout contains no dashboard eligible for workbook page emission",
            )
        if not self.master_fields:
            self.residue(
                "",
                {},
                "no-bound-source-fields",
                "no zone produced a safe source-field binding",
            )

        master_columns = [
            {
                "id": self.master_ids[key],
                "name": field.caption,
                "formula": f"[{self.source_name}/{field.caption}]",
            }
            for key, field in self.master_fields.items()
        ]
        master = {
            "id": "master",
            "kind": "table",
            "name": "Master",
            "visibleAsSource": False,
            "source": {
                "kind": "data-model",
                "dataModelId": self.data_model_id,
                "elementId": self.element_id,
            },
            "columns": master_columns,
        }
        data_page = "\n".join(
            [
                (
                    '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
                    'gridTemplateRows="auto" id="page-data">'
                ),
                '  <Element elementId="master" gridColumn="1 / 25" gridRow="1 / 20"/>',
                "</Page>",
            ]
        )
        xml = '<?xml version="1.0" encoding="utf-8"?>\n' + "\n".join(
            [data_page, *page_layouts]
        )
        palette = next(
            (
                item.get("brand_palette")
                for item in self.layout
                if isinstance(item.get("brand_palette"), list) and item.get("brand_palette")
            ),
            None,
        )
        settings: dict[str, Any] = {"theme": {"name": "Light"}}
        if palette:
            settings["theme"]["overrides"] = {
                "categoricalScheme": [str(color) for color in palette]
            }

        # Insertion order is intentional: layout is the final document write.
        document = {
            "schemaVersion": 1,
            "kind": "workbook",
            "elements": [master, *content_elements],
            "pages": pages,
            "settings": settings,
            "layout": xml,
        }
        spec = {
            "name": self.title,
            "folderId": self.folder_id,
            "description": "Generated locally from Tableau workbook layout signals.",
            "document": document,
        }
        report = {
            "schemaVersion": 1,
            "status": "blocked" if self.residues else "complete",
            "summary": {
                "emittedElements": len(content_elements),
                "boundSourceFields": len(master_columns),
                "residueCount": len(self.residues),
            },
            "residues": self.residues,
            "dispositions": self.dispositions,
        }
        if not self.residues:
            validate_spec(spec)
        return spec, report


def validate_spec(spec: dict[str, Any]) -> None:
    document = spec.get("document")
    if not spec.get("name") or not spec.get("folderId") or not isinstance(document, dict):
        raise ValueError("workbook spec requires name, folderId, and document")
    if document.get("schemaVersion") != 1 or document.get("kind") != "workbook":
        raise ValueError("workbook document must use schemaVersion=1 and kind=workbook")
    if list(document)[-1] != "layout":
        raise ValueError("document.layout must be the final authored document field")
    elements, pages = document.get("elements"), document.get("pages")
    if not isinstance(elements, list) or not isinstance(pages, list):
        raise ValueError("document requires flat elements and metadata-only pages")
    if any("elements" in page for page in pages):
        raise ValueError("pages must be metadata only; elements belong in document.elements")
    element_ids = [item.get("id") for item in elements]
    if any(not item for item in element_ids) or len(element_ids) != len(set(element_ids)):
        raise ValueError("element IDs must be non-empty and unique")
    column_ids = [
        column.get("id")
        for element in elements
        for column in element.get("columns") or []
    ]
    if any(not item for item in column_ids) or len(column_ids) != len(set(column_ids)):
        raise ValueError("column IDs must be non-empty and unique")
    for element in elements:
        for column in element.get("columns") or []:
            if not column.get("formula"):
                raise ValueError(f"{element['id']}/{column.get('id')} has no formula")
    placed = re.findall(r'\belementId="([^"]+)"', str(document.get("layout") or ""))
    if sorted(placed) != sorted(element_ids):
        raise ValueError("layout must place every flat element exactly once")
    page_ids = set(re.findall(r'<Page\b[^>]*\bid="([^"]+)"', document["layout"]))
    if page_ids != {str(page.get("id")) for page in pages}:
        raise ValueError("layout must contain exactly one Page for every page metadata entry")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--layout", required=True)
    parser.add_argument("--meta", required=True)
    parser.add_argument("--data-model-id", required=True)
    parser.add_argument("--element-id", "--data-model-element-id", dest="element_id", required=True)
    parser.add_argument("--data-model-element-name", required=True)
    parser.add_argument("--folder-id", required=True)
    parser.add_argument("--title")
    parser.add_argument("--out", required=True)
    parser.add_argument("--residues-out")
    args = parser.parse_args(argv)

    layout_path = Path(args.layout).expanduser().resolve()
    meta_path = Path(args.meta).expanduser().resolve()
    output_path = Path(args.out).expanduser().resolve()
    residues_path = (
        Path(args.residues_out).expanduser().resolve()
        if args.residues_out
        else output_path.with_name("workbook-residues.json")
    )
    try:
        builder = WorkbookBuilder(
            read_json(layout_path),
            read_json(meta_path),
            data_model_id=args.data_model_id,
            element_id=args.element_id,
            folder_id=args.folder_id,
            data_model_element_name=args.data_model_element_name,
            title=args.title,
        )
        spec, report = builder.build()
        report["inputs"] = {
            "layout": str(layout_path),
            "meta": str(meta_path),
            "dataModelId": args.data_model_id,
            "elementId": args.element_id,
            "dataModelElementName": args.data_model_element_name,
        }
        report["outputWritten"] = not bool(report["residues"])
        write_json(residues_path, report)
        if report["residues"]:
            output_path.unlink(missing_ok=True)
            print(
                f"FATAL: workbook build blocked by {len(report['residues'])} residue(s); "
                f"see {residues_path}",
                file=sys.stderr,
            )
            return 2
        write_json(output_path, spec)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"FATAL: automatic workbook builder refused: {exc}", file=sys.stderr)
        return 1
    print(
        f"wrote {output_path} ({len(spec['document']['elements'])} flat elements); "
        f"residues: {residues_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
