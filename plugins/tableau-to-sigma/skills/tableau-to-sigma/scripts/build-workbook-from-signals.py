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
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from xml.sax.saxutils import quoteattr


SUPPORTED_CHART_KINDS = {
    "kpi",
    "line",
    "bar",
    "area",
    "pie",
    "donut",
    "scatter",
    "map-region",
    "map-point",
    "pivot-table",
    "table",
}
STRUCTURAL_ZONE_KINDS = {"container", "spacer", "empty"}
DEFAULT_PAGE_ROW_UNITS = 28
MIN_PAGE_ROW_UNITS = 20
MAX_PAGE_ROW_UNITS = 36
REFERENCE_CANVAS_HEIGHT_PX = 800
KPI_TITLE_HORIZONTAL_TOLERANCE_PCT = 0.5
KPI_TITLE_VERTICAL_TOLERANCE_PCT = 1.0
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
USER_DERIVATIONS = {"user", "usr"}
TRANSLATED_FORMULA_STATUSES = {"spec", "verify", "chart_only"}


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
        return {"kind": "number", "formatString": f",.{decimals}%"}
    if "$" in value:
        decimals = len((re.search(r"\.([0#]+)", value) or [None, ""])[1])
        return {"kind": "number", "formatString": f"$,.{decimals}f"}
    return None


@dataclass(frozen=True)
class Field:
    key: str
    caption: str
    datatype: str
    tableau_formula: str | None = None


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
        formula_audit: dict[str, Any] | None = None,
        dm_spec: dict[str, Any] | None = None,
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
        if formula_audit is not None and not isinstance(formula_audit, dict):
            raise ValueError("formula-audit input must contain an object")
        if dm_spec is not None and not isinstance(dm_spec, dict):
            raise ValueError("dm-spec input must contain an object")
        self.formula_audit = formula_audit or {}
        self.dm_spec = dm_spec or {}
        self.has_dm_spec = dm_spec is not None
        self.residues: list[dict[str, Any]] = []
        self.dispositions: list[dict[str, Any]] = []
        self.master_fields: dict[str, Field] = {}
        self.master_ids: dict[str, str] = {}
        self.master_formulas: dict[str, str] = {}
        self.master_resolution_errors: dict[str, dict[str, Any]] = {}
        self.support_elements: list[dict[str, Any]] = []
        self.formula_rows = self._formula_audit_rows()
        self.data_model_elements = self._data_model_elements(self.dm_spec)
        self.data_model_source = self._selected_data_model_element()
        self.data_model_metrics = self._data_model_metrics()

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
        tableau_formula = str(info.get("formula") or "").strip() or None
        return Field(
            key=str(key),
            caption=caption,
            datatype=str(info.get("datatype") or ""),
            tableau_formula=tableau_formula,
        )

    def master_column(self, field: Field, formula: str | None = None) -> str | None:
        existing = self.master_fields.get(field.key)
        if existing:
            if formula and self.master_formulas[field.key] != formula:
                return None
            return self.master_ids[field.key]
        if any(
            current.caption.casefold() == field.caption.casefold() and current.key != field.key
            for current in self.master_fields.values()
        ):
            self.master_resolution_errors[field.key] = {
                "reasonCode": "ambiguous-master-source-field",
                "field": field.caption,
                "match": "workbook-column-caption",
            }
            return None
        if formula is None:
            formula, error = self.derive_master_source_formula(field)
            if formula is None:
                self.master_resolution_errors[field.key] = error
                return None
        column_id = stable_id("master-col", field.key)
        self.master_fields[field.key] = field
        self.master_ids[field.key] = column_id
        self.master_formulas[field.key] = formula
        return column_id

    def _formula_audit_rows(self) -> list[dict[str, Any]]:
        rows = self.formula_audit.get("formulas")
        if not isinstance(rows, list):
            rows = [
                row
                for datasource in self.formula_audit.get("datasources") or []
                if isinstance(datasource, dict)
                for row in datasource.get("formulas") or []
            ]
        return [row for row in rows if isinstance(row, dict)]

    @staticmethod
    def _data_model_elements(spec: dict[str, Any]) -> list[dict[str, Any]]:
        root = spec
        for wrapper in ("sigmaDataModel", "model", "document"):
            if isinstance(root.get(wrapper), dict):
                root = root[wrapper]
        elements = [
            element
            for page in root.get("pages") or []
            if isinstance(page, dict)
            for element in page.get("elements") or []
            if isinstance(element, dict)
        ]
        elements.extend(
            element
            for element in root.get("elements") or []
            if isinstance(element, dict)
        )
        return elements

    @staticmethod
    def _element_names(element: dict[str, Any]) -> set[str]:
        values = [element.get("name")]
        path = (element.get("source") or {}).get("path")
        if isinstance(path, list) and path:
            values.append(path[-1])
        return {
            str(value).strip().casefold()
            for value in values
            if str(value or "").strip()
        }

    def _selected_data_model_element(self) -> dict[str, Any] | None:
        by_id = [
            element
            for element in self.data_model_elements
            if str(element.get("id") or "") == self.element_id
        ]
        if len(by_id) == 1:
            return by_id[0]
        by_name = [
            element
            for element in self.data_model_elements
            if self.source_name.casefold() in self._element_names(element)
        ]
        return by_name[0] if len(by_name) == 1 else None

    def _data_model_metrics(self) -> list[dict[str, Any]]:
        if self.data_model_source is None:
            return []
        return [
            metric
            for metric in self.data_model_source.get("metrics") or []
            if isinstance(metric, dict)
        ]

    @staticmethod
    def _guid_tokens(value: object) -> list[str]:
        return [
            match.group(0).lower()
            for match in re.finditer(
                r"[0-9a-f]{8}(?:-[0-9a-f]{4}){2,3}(?:-[0-9a-f]{1,12})?",
                str(value or ""),
                re.IGNORECASE,
            )
        ]

    @classmethod
    def _column_id_matches_field(cls, field: Field, column: dict[str, Any]) -> bool:
        field_key = strip_brackets(field.key).strip().casefold()
        column_id = str(column.get("id") or "").strip().casefold()
        if not field_key or not column_id:
            return False
        if field_key == column_id:
            return True
        field_guids = cls._guid_tokens(field_key)
        column_guids = cls._guid_tokens(column_id)
        return any(
            left.startswith(right) or right.startswith(left)
            for left in field_guids
            for right in column_guids
            if min(len(left), len(right)) >= 8
        )

    @staticmethod
    def _column_name(column: dict[str, Any]) -> str:
        return str(column.get("name") or "").strip()

    @staticmethod
    def _candidate(
        element: dict[str, Any],
        column: dict[str, Any],
        relationship: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        return {
            "elementId": element.get("id"),
            "elementName": element.get("name"),
            "columnId": column.get("id"),
            "columnName": column.get("name"),
            "relationshipId": relationship.get("id") if relationship else None,
            "relationshipName": relationship.get("name") if relationship else None,
        }

    def _related_candidates(
        self,
        predicate,
    ) -> list[dict[str, Any]]:
        if self.data_model_source is None:
            return []
        by_id = {
            str(element.get("id") or ""): element
            for element in self.data_model_elements
            if element.get("id") is not None
        }
        candidates = []
        for relationship in self.data_model_source.get("relationships") or []:
            if not isinstance(relationship, dict):
                continue
            target = by_id.get(str(relationship.get("targetElementId") or ""))
            relationship_name = str(relationship.get("name") or "").strip()
            if target is None or not relationship_name or any(
                token in relationship_name for token in "[]/"
            ):
                continue
            for column in target.get("columns") or []:
                if (
                    isinstance(column, dict)
                    and self._column_name(column)
                    and predicate(relationship, target, column)
                ):
                    candidates.append(
                        self._candidate(target, column, relationship)
                    )
        return candidates

    def _formula_from_candidate(self, candidate: dict[str, Any]) -> str | None:
        column_name = str(candidate.get("columnName") or "").strip()
        relationship_name = str(candidate.get("relationshipName") or "").strip()
        if not column_name or any(token in column_name for token in "[]"):
            return None
        if relationship_name:
            return f"[{self.source_name}/{relationship_name}/{column_name}]"
        return f"[{self.source_name}/{column_name}]"

    @staticmethod
    def _relationship_matches_date_role(
        relationship: dict[str, Any], caption: str
    ) -> bool:
        name = str(relationship.get("name") or "").strip().casefold()
        if name == caption:
            return True
        parenthetical_role = re.search(r"\(([^()]*)\)\s*$", name)
        return bool(
            parenthetical_role
            and parenthetical_role.group(1).strip().casefold() == caption
        )

    def derive_master_source_formula(
        self, field: Field
    ) -> tuple[str | None, dict[str, Any]]:
        if not self.has_dm_spec:
            return f"[{self.source_name}/{field.caption}]", {}
        if self.data_model_source is None:
            return None, {
                "reasonCode": "unbound-data-model-source",
                "field": field.caption,
                "sourceElementId": self.element_id,
                "sourceElementName": self.source_name,
            }

        direct_columns = [
            column
            for column in self.data_model_source.get("columns") or []
            if isinstance(column, dict) and self._column_name(column)
        ]
        direct_guid = [
            self._candidate(self.data_model_source, column)
            for column in direct_columns
            if self._column_id_matches_field(field, column)
        ]
        if len(direct_guid) == 1:
            return f"[{self.source_name}/{field.caption}]", {
                "match": "direct-column-id",
                "candidate": direct_guid[0],
            }
        if len(direct_guid) > 1:
            return None, {
                "reasonCode": "ambiguous-master-source-field",
                "field": field.caption,
                "match": "direct-column-id",
                "candidates": direct_guid,
            }

        related_guid = self._related_candidates(
            lambda _relationship, _target, column: self._column_id_matches_field(
                field, column
            ),
        )
        if len(related_guid) == 1:
            return self._formula_from_candidate(related_guid[0]), {
                "match": "related-column-id",
                "candidate": related_guid[0],
            }
        if len(related_guid) > 1:
            return None, {
                "reasonCode": "ambiguous-master-source-field",
                "field": field.caption,
                "match": "related-column-id",
                "candidates": related_guid,
            }

        caption = field.caption.casefold()
        direct_caption = [
            self._candidate(self.data_model_source, column)
            for column in direct_columns
            if self._column_name(column).casefold() == caption
        ]
        related_caption = self._related_candidates(
            lambda _relationship, _target, column: (
                self._column_name(column).casefold() == caption
            ),
        )
        caption_candidates = direct_caption + related_caption
        if len(caption_candidates) == 1:
            candidate = caption_candidates[0]
            formula = (
                self._formula_from_candidate(candidate)
                if candidate.get("relationshipName")
                else f"[{self.source_name}/{field.caption}]"
            )
            return formula, {
                "match": (
                    "related-caption"
                    if candidate.get("relationshipName")
                    else "direct-caption"
                ),
                "candidate": candidate,
            }
        if len(caption_candidates) > 1:
            return None, {
                "reasonCode": "ambiguous-master-source-field",
                "field": field.caption,
                "match": "caption",
                "candidates": caption_candidates,
            }

        if field.datatype.strip().casefold() in {"date", "datetime"}:
            date_roles = self._related_candidates(
                lambda relationship, _target, column: (
                    self._relationship_matches_date_role(relationship, caption)
                    and self._column_name(column).casefold() == "full date"
                ),
            )
            if len(date_roles) == 1:
                return self._formula_from_candidate(date_roles[0]), {
                    "match": "semantic-date-role",
                    "candidate": date_roles[0],
                }
            if len(date_roles) > 1:
                return None, {
                    "reasonCode": "ambiguous-master-source-field",
                    "field": field.caption,
                    "match": "semantic-date-role",
                    "candidates": date_roles,
                }

        return None, {
            "reasonCode": "unbound-master-source-field",
            "field": field.caption,
            "fieldKey": field.key,
        }

    def add_master_resolution_residue(
        self, dashboard: str, zone: dict[str, Any], field: Field
    ) -> None:
        evidence = dict(
            self.master_resolution_errors.get(field.key)
            or {
                "reasonCode": "ambiguous-master-source-field",
                "field": field.caption,
            }
        )
        code = str(evidence.pop("reasonCode", "unbound-master-source-field"))
        self.residue(
            dashboard,
            zone,
            code,
            "field cannot be resolved uniquely from the selected data-model source graph",
            **evidence,
        )

    @staticmethod
    def _audit_names(row: dict[str, Any]) -> set[str]:
        return {
            strip_brackets(row.get(key)).strip().casefold()
            for key in ("internal_name", "caption", "calculation", "name")
            if str(row.get(key) or "").strip()
        }

    def translated_formula(self, field: Field) -> tuple[str | None, dict[str, Any]]:
        key = field.key.strip().casefold()
        caption = field.caption.strip().casefold()
        key_matches = [
            row for row in self.formula_rows if key in self._audit_names(row)
        ]
        matches = key_matches or [
            row for row in self.formula_rows if caption in self._audit_names(row)
        ]
        if len(matches) != 1:
            return None, {
                "formulaAuditMatches": len(matches),
                "field": field.caption,
            }
        row = matches[0]
        formula = str(row.get("sigma_formula") or "").strip()
        status = str(row.get("status") or "")
        if (
            not formula
            or status not in TRANSLATED_FORMULA_STATUSES
            or formula.startswith("/*")
        ):
            return None, {
                "field": field.caption,
                "formulaStatus": status or None,
                "hasSigmaFormula": bool(formula),
            }
        return formula, {
            "field": field.caption,
            "formulaStatus": status,
            "formulaAuditId": row.get("id"),
        }

    @staticmethod
    def _formula_reference_spans(formula: str) -> list[tuple[int, int, str]] | None:
        spans: list[tuple[int, int, str]] = []
        quote = None
        index = 0
        while index < len(formula):
            char = formula[index]
            if quote:
                if char == "\\":
                    index += 2
                    continue
                if char == quote:
                    if index + 1 < len(formula) and formula[index + 1] == quote:
                        index += 2
                        continue
                    quote = None
                index += 1
                continue
            if char in {'"', "'"}:
                quote = char
                index += 1
                continue
            if char != "[":
                index += 1
                continue
            end = formula.find("]", index + 1)
            if end < 0:
                return None
            spans.append((index, end + 1, formula[index + 1 : end]))
            index = end + 1
        return spans if quote is None else None

    def map_formula_references(
        self, formula: str, current_field: Field, *, qualify: bool
    ) -> tuple[str | None, list[str]]:
        spans = self._formula_reference_spans(formula)
        if spans is None:
            return None, ["malformed-formula"]
        missing = []
        replacements: list[tuple[int, int, str]] = []
        for start, end, reference in spans:
            mapped = self.resolve_field(reference)
            if (
                mapped is None
                or mapped.key == current_field.key
                or mapped.tableau_formula is not None
                or (
                    mapped.caption.casefold() == current_field.caption.casefold()
                    and mapped.key != current_field.key
                )
            ):
                missing.append(reference)
                continue
            if qualify and not self.master_column(mapped):
                missing.append(reference)
                continue
            replacement = (
                f"[Master/{mapped.caption}]" if qualify else f"[{mapped.caption}]"
            )
            replacements.append((start, end, replacement))
        if missing:
            return None, sorted(set(missing))
        output = formula
        for start, end, replacement in reversed(replacements):
            output = output[:start] + replacement + output[end:]
        return output, []

    def formula_signature(self, formula: str, current_field: Field) -> str | None:
        mapped, missing = self.map_formula_references(
            formula, current_field, qualify=False
        )
        if missing or mapped is None:
            return None
        return re.sub(r"\s+", "", mapped).casefold()

    def matching_metric(
        self, field: Field, translated_formula: str
    ) -> dict[str, Any] | None:
        translated_signature = self.formula_signature(translated_formula, field)
        if translated_signature is None:
            return None
        matches = []
        for metric in self.data_model_metrics:
            name = str(metric.get("name") or "").strip()
            formula = str(metric.get("formula") or "").strip()
            if not name or any(token in name for token in "[]") or not formula:
                continue
            metric_signature = self.formula_signature(formula, field)
            if metric_signature != translated_signature:
                continue
            matches.append(metric)
        named = [
            metric
            for metric in matches
            if str(metric.get("name") or "").strip().casefold()
            == field.caption.casefold()
        ]
        selected = named if named else matches
        return selected[0] if len(selected) == 1 else None

    def metric_master_column(self, field: Field, metric: dict[str, Any]) -> str | None:
        metric_name = str(metric.get("name") or "").strip()
        metric_field = Field(
            key=f"metric:{metric_name}",
            caption=field.caption,
            datatype=field.datatype,
        )
        return self.master_column(metric_field, f"[Metrics/{metric_name}]")

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

    def require_translated_calculation(
        self,
        dashboard: str,
        zone: dict[str, Any],
        field: Field,
    ) -> tuple[str | None, dict[str, Any]]:
        translated, evidence = self.translated_formula(field)
        if translated is None:
            self.residue(
                dashboard,
                zone,
                "unbound-user-calculation",
                "user calculation has no unique usable translated Sigma formula",
                **evidence,
            )
            return None, evidence
        return translated, evidence

    def qualify_user_calculation(
        self,
        dashboard: str,
        zone: dict[str, Any],
        field: Field,
    ) -> tuple[str | None, str | None, dict[str, Any]]:
        translated, evidence = self.require_translated_calculation(
            dashboard, zone, field
        )
        if translated is None:
            return None, None, evidence
        qualified, missing = self.map_formula_references(
            translated, field, qualify=True
        )
        if qualified is None:
            self.residue(
                dashboard,
                zone,
                "unmapped-user-calculation-reference",
                "translated Sigma formula contains a reference that cannot be mapped through dashboard metadata",
                references=missing,
                **evidence,
            )
            return None, None, evidence
        return translated, qualified, evidence

    def dimension_formula(
        self,
        dashboard: str,
        zone: dict[str, Any],
        item: dict[str, Any],
        field: Field,
    ) -> str | None:
        derivation = str(item.get("derivation") or "").lower()
        if field.tableau_formula or derivation in USER_DERIVATIONS:
            _translated, formula, _evidence = self.qualify_user_calculation(
                dashboard, zone, field
            )
            if formula is None:
                return None
        else:
            if not self.master_column(field):
                self.add_master_resolution_residue(dashboard, zone, field)
                return None
            formula = f"[Master/{field.caption}]"
        grain = DATE_DERIVATIONS.get(derivation)
        return f'DateTrunc("{grain}", {formula})' if grain else formula

    def measure_formula(
        self,
        dashboard: str,
        zone: dict[str, Any],
        item: dict[str, Any],
        field: Field,
    ) -> str | None:
        derivation = self._derivation(zone, item)
        if field.tableau_formula or derivation in USER_DERIVATIONS:
            translated, evidence = self.require_translated_calculation(
                dashboard, zone, field
            )
            if translated is None:
                return None
            qualified, missing = self.map_formula_references(
                translated, field, qualify=True
            )
            if qualified is None:
                self.residue(
                    dashboard,
                    zone,
                    "unmapped-user-calculation-reference",
                    "translated Sigma formula contains a reference that cannot be mapped through dashboard metadata",
                    references=missing,
                    **evidence,
                )
                return None
            if derivation in USER_DERIVATIONS:
                # User aggregate formulas must remain in the consuming
                # element's grouping context.
                return qualified
            if derivation in AGGREGATIONS:
                return f"{AGGREGATIONS[derivation]}({qualified})"
            self.residue(
                dashboard,
                zone,
                "unsupported-user-aggregation",
                "translated row calculation still has an unsupported shelf aggregation",
                aggregation=derivation,
                **evidence,
            )
            return None
        if derivation not in AGGREGATIONS:
            self.residue(
                dashboard,
                zone,
                "unbound-chart-field",
                "one or more chart fields or aggregations cannot be bound safely",
                fields=[],
                aggregations=[derivation],
            )
            return None
        if not self.master_column(field):
            self.add_master_resolution_residue(dashboard, zone, field)
            return None
        return f"{AGGREGATIONS[derivation]}([Master/{field.caption}])"

    def dimension_column(
        self,
        dashboard: str,
        zone: dict[str, Any],
        item: dict[str, Any],
        field: Field,
        column_id: str,
    ) -> dict[str, Any] | None:
        formula = self.dimension_formula(dashboard, zone, item, field)
        if formula is None:
            return None
        column: dict[str, Any] = {
            "id": column_id,
            "name": field.caption,
            "formula": formula,
        }
        field_format = self._field_format(zone, field)
        if field_format:
            column["format"] = field_format
        return column

    def measure_column(
        self,
        dashboard: str,
        zone: dict[str, Any],
        item: dict[str, Any],
        field: Field,
        column_id: str,
    ) -> dict[str, Any] | None:
        formula = self.measure_formula(dashboard, zone, item, field)
        if formula is None:
            return None
        column: dict[str, Any] = {
            "id": column_id,
            "name": field.caption,
            "formula": formula,
        }
        field_format = self._field_format(zone, field)
        if field_format:
            column["format"] = field_format
        return column

    def channel_field(self, zone: dict[str, Any], channel: str) -> Field | None:
        signal = (zone.get("channels") or {}).get(channel)
        if not isinstance(signal, dict):
            return None
        return self.resolve_field(signal.get("column")) or self.resolve_field(
            signal.get("field")
        )

    @staticmethod
    def channel_has_signal(zone: dict[str, Any], channel: str) -> bool:
        signal = (zone.get("channels") or {}).get(channel)
        return isinstance(signal, dict) and any(
            str(signal.get(key) or "").strip() for key in ("column", "field")
        )

    def unsupported_channels(
        self,
        dashboard: str,
        zone: dict[str, Any],
        allowed: set[str],
        chart_name: str,
    ) -> bool:
        channels = sorted(
            channel
            for channel in (zone.get("channels") or {})
            if channel not in allowed and self.channel_has_signal(zone, channel)
        )
        if not channels:
            return False
        self.residue(
            dashboard,
            zone,
            "unsupported-chart-encoding",
            f"{chart_name} contains encoding channels without a verified Sigma mapping",
            channels=channels,
        )
        return True

    @staticmethod
    def shelf_items(
        zone: dict[str, Any], shelf_name: str, role: str
    ) -> list[dict[str, Any]]:
        return [
            item
            for item in (zone.get(shelf_name) or {}).get("fields") or []
            if isinstance(item, dict) and item.get("role") == role
        ]

    def resolve_items(
        self,
        dashboard: str,
        zone: dict[str, Any],
        items: list[dict[str, Any]],
    ) -> list[tuple[dict[str, Any], Field]] | None:
        resolved = [(item, self.resolve_field(item.get("guid"))) for item in items]
        missing = [
            str(item.get("guid") or item.get("raw") or "")
            for item, field in resolved
            if field is None
        ]
        if missing:
            self.residue(
                dashboard,
                zone,
                "unbound-chart-field",
                "one or more chart fields or aggregations cannot be bound safely",
                fields=missing,
                aggregations=[],
            )
            return None
        return [(item, field) for item, field in resolved if field is not None]

    def build_circular_chart(
        self, dashboard: str, zone: dict[str, Any], chart_kind: str
    ) -> dict[str, Any] | None:
        if self.unsupported_channels(
            dashboard, zone, {"color"}, f"{chart_kind} chart"
        ):
            return None
        dimensions, measures = self._shelf_fields(zone)
        color_field = self.channel_field(zone, "color")
        if self.channel_has_signal(zone, "color") and color_field is None:
            self.residue(
                dashboard,
                zone,
                "unbound-chart-field",
                "circular chart color encoding cannot be bound through dashboard metadata",
                fields=["color"],
                aggregations=[],
            )
            return None
        dimension_pairs = self.resolve_items(dashboard, zone, dimensions)
        if dimension_pairs is None:
            return None
        dimension_fields = {
            field.key: (item, field) for item, field in dimension_pairs
        }
        if color_field is not None:
            dimension_fields.setdefault(
                color_field.key,
                (
                    {
                        "guid": color_field.key,
                        "role": "dim",
                        "derivation": "none",
                    },
                    color_field,
                ),
            )
        if len(dimension_fields) != 1 or len(measures) != 1:
            self.residue(
                dashboard,
                zone,
                "ambiguous-chart-fields",
                "pie and donut charts require exactly one dimension and one measure",
                dimensionCount=len(dimension_fields),
                measureCount=len(measures),
            )
            return None
        measure_pairs = self.resolve_items(dashboard, zone, measures)
        if measure_pairs is None:
            return None
        element_id = stable_id("chart", f"{dashboard}:{zone.get('id')}")
        dimension_item, dimension_field = next(iter(dimension_fields.values()))
        measure_item, measure_field = measure_pairs[0]
        dimension = self.dimension_column(
            dashboard,
            zone,
            dimension_item,
            dimension_field,
            f"{element_id}-dimension",
        )
        measure = self.measure_column(
            dashboard,
            zone,
            measure_item,
            measure_field,
            f"{element_id}-measure-1",
        )
        if dimension is None or measure is None:
            return None
        element = {
            "id": element_id,
            "kind": f"{chart_kind}-chart",
            "name": str(
                zone.get("display_title")
                or zone.get("caption")
                or chart_kind.title()
            ),
            "source": {"kind": "table", "elementId": "master"},
            "columns": [dimension, measure],
            "value": {"id": measure["id"]},
            "color": {"id": dimension["id"]},
        }
        sort = zone.get("sort") or {}
        direction = str(sort.get("direction") or "").lower()
        if direction in {"asc", "ascending", "desc", "descending"}:
            element["color"]["sort"] = {
                "by": measure["id"],
                "direction": (
                    "descending" if direction.startswith("desc") else "ascending"
                ),
            }
        if zone.get("mark_labels_show"):
            element["dataLabel"] = {"labels": "shown"}
        return element

    def build_tabular_chart(
        self, dashboard: str, zone: dict[str, Any], chart_kind: str
    ) -> dict[str, Any] | None:
        row_dimensions = self.shelf_items(zone, "rows_shelf", "dim")
        column_dimensions = self.shelf_items(zone, "cols_shelf", "dim")
        dimensions, measures = self._shelf_fields(zone)
        if not dimensions and not measures:
            self.residue(
                dashboard,
                zone,
                "ambiguous-chart-fields",
                "table signals contain no bindable dimensions or measures",
                dimensionCount=0,
                measureCount=0,
            )
            return None
        if chart_kind == "pivot-table" and (not dimensions or not measures):
            self.residue(
                dashboard,
                zone,
                "ambiguous-pivot-fields",
                "pivot tables require at least one dimension and one value",
                rowCount=len(row_dimensions),
                columnCount=len(column_dimensions),
                valueCount=len(measures),
            )
            return None
        if chart_kind == "table" and measures and not dimensions:
            self.residue(
                dashboard,
                zone,
                "unsafe-aggregate-table",
                "an aggregate table requires at least one grouping dimension",
                valueCount=len(measures),
            )
            return None
        dimension_pairs = self.resolve_items(dashboard, zone, dimensions)
        measure_pairs = self.resolve_items(dashboard, zone, measures)
        if dimension_pairs is None or measure_pairs is None:
            return None
        dimension_keys = [field.key for _item, field in dimension_pairs]
        if len(dimension_keys) != len(set(dimension_keys)):
            self.residue(
                dashboard,
                zone,
                "ambiguous-pivot-fields",
                "a dimension appears on more than one table shelf",
                dimensions=dimension_keys,
            )
            return None

        element_id = stable_id("chart", f"{dashboard}:{zone.get('id')}")
        columns = []
        dimension_ids: dict[str, str] = {}
        for index, (item, field) in enumerate(dimension_pairs, 1):
            column_id = f"{element_id}-dimension-{index}"
            column = self.dimension_column(
                dashboard, zone, item, field, column_id
            )
            if column is None:
                return None
            columns.append(column)
            dimension_ids[field.key] = column_id
        measure_ids = []
        for index, (item, field) in enumerate(measure_pairs, 1):
            column = self.measure_column(
                dashboard,
                zone,
                item,
                field,
                f"{element_id}-measure-{index}",
            )
            if column is None:
                return None
            columns.append(column)
            measure_ids.append(column["id"])

        element: dict[str, Any] = {
            "id": element_id,
            "kind": chart_kind,
            "name": str(
                zone.get("display_title")
                or zone.get("caption")
                or ("Pivot Table" if chart_kind == "pivot-table" else "Table")
            ),
            "source": {"kind": "table", "elementId": "master"},
            "columns": columns,
        }
        if chart_kind == "pivot-table":
            element["rowsBy"] = [
                {"id": dimension_ids[field.key]}
                for _item, field in dimension_pairs
                if any(
                    row.get("guid") == _item.get("guid")
                    for row in row_dimensions
                )
            ]
            element["columnsBy"] = [
                {"id": dimension_ids[field.key]}
                for _item, field in dimension_pairs
                if any(
                    column.get("guid") == _item.get("guid")
                    for column in column_dimensions
                )
            ]
            element["values"] = measure_ids
        else:
            element["order"] = [column["id"] for column in columns]
            if measure_ids:
                element["groupings"] = [
                    {
                        "id": f"{element_id}-grouping",
                        "groupBy": list(dimension_ids.values()),
                        "calculations": measure_ids,
                    }
                ]
        return element

    @staticmethod
    def region_type(geo_role: object) -> str | None:
        role = re.sub(r"[^a-z0-9]+", "-", str(geo_role or "").casefold()).strip("-")
        aliases = {
            "country": "country",
            "nation": "country",
            "geo-country": "country",
            "state": "us-state",
            "geo-state": "us-state",
            "us-state": "us-state",
            "county": "us-county",
            "geo-county": "us-county",
            "us-county": "us-county",
            "zip": "us-zipcode",
            "zipcode": "us-zipcode",
            "postal-code": "us-zipcode",
            "geo-zip-code": "us-zipcode",
            "cbsa": "us-cbsa",
            "metro": "us-cbsa",
            "city": "us-postal-place",
            "geo-city": "us-postal-place",
            "postal-place": "us-postal-place",
            "province": "ca-province",
            "ca-province": "ca-province",
        }
        return aliases.get(role)

    def build_region_map(
        self, dashboard: str, zone: dict[str, Any]
    ) -> dict[str, Any] | None:
        if self.unsupported_channels(
            dashboard, zone, {"detail", "color"}, "region map"
        ):
            return None
        dimensions, measures = self._shelf_fields(zone)
        dimension_pairs = self.resolve_items(dashboard, zone, dimensions)
        if dimension_pairs is None:
            return None
        detail_field = self.channel_field(zone, "detail")
        color_field = self.channel_field(zone, "color")
        if self.channel_has_signal(zone, "detail") and detail_field is None:
            self.residue(
                dashboard,
                zone,
                "unverified-region-map",
                "region map detail encoding cannot be bound to a verified geography field",
                geoRole=zone.get("geo_role"),
            )
            return None
        if self.channel_has_signal(zone, "color") and color_field is None:
            self.residue(
                dashboard,
                zone,
                "unverified-region-map",
                "region map color encoding cannot be bound through dashboard metadata",
                geoRole=zone.get("geo_role"),
            )
            return None
        dimension_fields = {
            field.key: (item, field) for item, field in dimension_pairs
        }
        if detail_field is not None:
            dimension_fields.setdefault(
                detail_field.key,
                (
                    {
                        "guid": detail_field.key,
                        "role": "dim",
                        "derivation": "none",
                    },
                    detail_field,
                ),
            )
        region_type = self.region_type(zone.get("geo_role"))
        if (
            len(dimension_fields) != 1
            or len(measures) > 1
            or region_type is None
        ):
            self.residue(
                dashboard,
                zone,
                "unverified-region-map",
                "region maps require one dimension, at most one measure, and a recognized Tableau geography role",
                dimensionCount=len(dimension_fields),
                measureCount=len(measures),
                geoRole=zone.get("geo_role"),
            )
            return None
        measure_pairs = self.resolve_items(dashboard, zone, measures)
        if measure_pairs is None:
            return None
        element_id = stable_id("chart", f"{dashboard}:{zone.get('id')}")
        region_item, region_field = next(iter(dimension_fields.values()))
        region = self.dimension_column(
            dashboard,
            zone,
            region_item,
            region_field,
            f"{element_id}-region",
        )
        if region is None:
            return None
        columns = [region]
        element: dict[str, Any] = {
            "id": element_id,
            "kind": "region-map",
            "name": str(
                zone.get("display_title") or zone.get("caption") or "Region Map"
            ),
            "source": {"kind": "table", "elementId": "master"},
            "columns": columns,
            "region": {"id": region["id"], "regionType": region_type},
        }
        if measures:
            measure_item, measure_field = measure_pairs[0]
            if color_field is not None and color_field.key != measure_field.key:
                self.residue(
                    dashboard,
                    zone,
                    "unsupported-chart-encoding",
                    "region map color field does not match its single measure",
                    colorField=color_field.caption,
                    measureField=measure_field.caption,
                )
                return None
            measure = self.measure_column(
                dashboard,
                zone,
                measure_item,
                measure_field,
                f"{element_id}-measure-1",
            )
            if measure is None:
                return None
            columns.append(measure)
            element["color"] = {"by": "scale", "column": measure["id"]}
        elif color_field is not None:
            if color_field.key != region_field.key:
                self.residue(
                    dashboard,
                    zone,
                    "unsupported-chart-encoding",
                    "region map color field is neither its region nor a measure",
                    colorField=color_field.caption,
                    regionField=region_field.caption,
                )
                return None
            element["color"] = {"by": "category", "column": region["id"]}
        return element

    @staticmethod
    def coordinate_kind(field: Field) -> str | None:
        name = re.sub(r"[^a-z]+", " ", field.caption.casefold()).strip()
        if re.search(r"\blat(?:itude)?\b", name):
            return "latitude"
        if re.search(r"\b(?:lon|lng|longitude)\b", name):
            return "longitude"
        return None

    def build_point_map(
        self, dashboard: str, zone: dict[str, Any]
    ) -> dict[str, Any] | None:
        if self.unsupported_channels(dashboard, zone, set(), "point map"):
            return None
        shelf_fields = [
            item
            for shelf_name in ("cols_shelf", "rows_shelf")
            for item in (zone.get(shelf_name) or {}).get("fields") or []
            if isinstance(item, dict) and item.get("role") in {"dim", "measure"}
        ]
        pairs = self.resolve_items(dashboard, zone, shelf_fields)
        if pairs is None:
            return None
        coordinates: dict[str, list[tuple[dict[str, Any], Field]]] = {
            "latitude": [],
            "longitude": [],
        }
        extras = []
        for pair in pairs:
            coordinate = self.coordinate_kind(pair[1])
            if coordinate:
                coordinates[coordinate].append(pair)
            else:
                extras.append(pair)
        if (
            len(coordinates["latitude"]) != 1
            or len(coordinates["longitude"]) != 1
            or extras
        ):
            self.residue(
                dashboard,
                zone,
                "unverified-point-map",
                "point maps require unique latitude and longitude shelf fields without ambiguous extras",
                latitudeCount=len(coordinates["latitude"]),
                longitudeCount=len(coordinates["longitude"]),
                extraFields=[field.caption for _item, field in extras],
            )
            return None
        element_id = stable_id("chart", f"{dashboard}:{zone.get('id')}")
        columns = []
        bindings = {}
        for coordinate in ("latitude", "longitude"):
            item, field = coordinates[coordinate][0]
            column_id = f"{element_id}-{coordinate}"
            column = (
                self.measure_column(
                    dashboard, zone, item, field, column_id
                )
                if item.get("role") == "measure"
                else self.dimension_column(
                    dashboard, zone, item, field, column_id
                )
            )
            if column is None:
                return None
            columns.append(column)
            bindings[coordinate] = {"id": column_id}
        return {
            "id": element_id,
            "kind": "point-map",
            "name": str(
                zone.get("display_title") or zone.get("caption") or "Point Map"
            ),
            "source": {"kind": "table", "elementId": "master"},
            "columns": columns,
            **bindings,
        }

    def build_scatter_chart(
        self, dashboard: str, zone: dict[str, Any]
    ) -> dict[str, Any] | None:
        if self.unsupported_channels(
            dashboard, zone, {"detail", "color"}, "scatter chart"
        ):
            return None
        x_items = self.shelf_items(zone, "cols_shelf", "measure")
        y_items = self.shelf_items(zone, "rows_shelf", "measure")
        shelf_dimensions = (
            self.shelf_items(zone, "cols_shelf", "dim")
            + self.shelf_items(zone, "rows_shelf", "dim")
        )
        if len(x_items) != 1 or len(y_items) != 1:
            self.residue(
                dashboard,
                zone,
                "ambiguous-scatter-axes",
                "scatter charts require exactly one measure on each axis",
                xMeasureCount=len(x_items),
                yMeasureCount=len(y_items),
            )
            return None
        axis_pairs = self.resolve_items(dashboard, zone, x_items + y_items)
        if axis_pairs is None:
            return None
        identity_fields = []
        for channel in ("detail", "color"):
            field = self.channel_field(zone, channel)
            if self.channel_has_signal(zone, channel) and field is None:
                self.residue(
                    dashboard,
                    zone,
                    "unbound-chart-field",
                    "scatter point-identity encoding cannot be bound through dashboard metadata",
                    fields=[channel],
                    aggregations=[],
                )
                return None
            if field and field.key not in {pair[1].key for pair in axis_pairs}:
                identity_fields.append(field)
        shelf_pairs = self.resolve_items(dashboard, zone, shelf_dimensions)
        if shelf_pairs is None:
            return None
        identity_fields.extend(field for _item, field in shelf_pairs)
        identities = {
            field.key: field for field in identity_fields
        }
        if len(identities) != 1:
            self.residue(
                dashboard,
                zone,
                "unsafe-scatter-source",
                "scatter charts require one unambiguous point dimension for a grouped source",
                identityCount=len(identities),
                identities=[field.caption for field in identities.values()],
            )
            return None
        identity = next(iter(identities.values()))
        x_item, x_field = axis_pairs[0]
        y_item, y_field = axis_pairs[1]
        if len({identity.caption, x_field.caption, y_field.caption}) != 3:
            self.residue(
                dashboard,
                zone,
                "ambiguous-scatter-fields",
                "scatter grouping and axis columns require unique display names",
            )
            return None

        element_id = stable_id("chart", f"{dashboard}:{zone.get('id')}")
        source_id = f"{element_id}-grouped-source"
        grouping_id = f"{source_id}-grouping"
        source_name = f"Scatter Source {element_id[-8:]}"
        identity_item = next(
            (
                item
                for item, field in shelf_pairs
                if field.key == identity.key
            ),
            {"guid": identity.key, "role": "dim", "derivation": "none"},
        )
        source_columns = [
            self.dimension_column(
                dashboard,
                zone,
                identity_item,
                identity,
                f"{source_id}-identity",
            ),
            self.measure_column(
                dashboard, zone, x_item, x_field, f"{source_id}-x"
            ),
            self.measure_column(
                dashboard, zone, y_item, y_field, f"{source_id}-y"
            ),
        ]
        if any(column is None for column in source_columns):
            return None
        grouped_columns = [column for column in source_columns if column is not None]
        grouped_source = {
            "id": source_id,
            "kind": "table",
            "name": source_name,
            "visibleAsSource": False,
            "source": {"kind": "table", "elementId": "master"},
            "columns": grouped_columns,
            "groupings": [
                {
                    "id": grouping_id,
                    "groupBy": [grouped_columns[0]["id"]],
                    "calculations": [
                        grouped_columns[1]["id"],
                        grouped_columns[2]["id"],
                    ],
                }
            ],
        }
        self.support_elements.append(grouped_source)
        chart_columns = [
            {
                "id": f"{element_id}-{suffix}",
                "name": source_column["name"],
                "formula": f"[{source_name}/{source_column['name']}]",
            }
            for suffix, source_column in zip(
                ("identity", "x", "y"), grouped_columns
            )
        ]
        return {
            "id": element_id,
            "kind": "scatter-chart",
            "name": str(
                zone.get("display_title") or zone.get("caption") or "Scatter"
            ),
            "source": {
                "kind": "table",
                "elementId": source_id,
                "groupingId": grouping_id,
            },
            "columns": chart_columns,
            "xAxis": {"columnId": chart_columns[1]["id"]},
            "yAxis": {"columnIds": [chart_columns[2]["id"]]},
            "color": {
                "by": "category",
                "column": chart_columns[0]["id"],
            },
        }

    def build_chart(self, dashboard: str, zone: dict[str, Any]) -> dict[str, Any] | None:
        chart_kind = str(zone.get("chart_kind") or "")
        if chart_kind not in SUPPORTED_CHART_KINDS:
            self.residue(
                dashboard,
                zone,
                "unsupported-chart-kind",
                "automatic builder has no safe native binding for this chart kind",
                supported=sorted(SUPPORTED_CHART_KINDS),
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

        if chart_kind in {"pie", "donut"}:
            return self.build_circular_chart(dashboard, zone, chart_kind)
        if chart_kind in {"table", "pivot-table"}:
            return self.build_tabular_chart(dashboard, zone, chart_kind)
        if chart_kind == "scatter":
            return self.build_scatter_chart(dashboard, zone)
        if chart_kind == "map-region":
            return self.build_region_map(dashboard, zone)
        if chart_kind == "map-point":
            return self.build_point_map(dashboard, zone)

        dual_axis = bool(zone.get("dual_axis"))
        if dual_axis and chart_kind not in {"line", "bar", "area"}:
            self.residue(
                dashboard,
                zone,
                "unsupported-dual-axis",
                "dual-axis signals are safe only for cartesian chart shelves",
                chartKind=chart_kind,
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
        if dual_axis and len(measures) != 2:
            self.residue(
                dashboard,
                zone,
                "ambiguous-dual-axis",
                "dual-axis conversion requires exactly two ordered measures",
                measureCount=len(measures),
            )
            return None
        if (
            dual_axis
            and self.shelf_items(zone, "rows_shelf", "dim")
            and self.shelf_items(zone, "cols_shelf", "measure")
        ):
            self.residue(
                dashboard,
                zone,
                "unsupported-dual-axis",
                "horizontal dual-axis orientation has no verified automatic combo mapping",
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
            {
                value
                for value, field in zip(derivations, resolved_measures)
                if value not in AGGREGATIONS
                and value not in USER_DERIVATIONS
                and not (field and field.tableau_formula)
            }
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
            dimension_column_id = f"{element_id}-dimension"
            dimension_derivation = str(
                dimensions[0].get("derivation") or ""
            ).lower()
            if field.tableau_formula or dimension_derivation in USER_DERIVATIONS:
                _translated, formula, _evidence = self.qualify_user_calculation(
                    dashboard, zone, field
                )
                if formula is None:
                    return None
            else:
                master_id = self.master_column(field)
                if not master_id:
                    self.add_master_resolution_residue(dashboard, zone, field)
                    return None
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
            formula = None
            if field.tableau_formula or derivation in USER_DERIVATIONS:
                translated, evidence = self.require_translated_calculation(
                    dashboard, zone, field
                )
                if translated is None:
                    return None
                qualified, missing = self.map_formula_references(
                    translated, field, qualify=True
                )
                if qualified is None:
                    self.residue(
                        dashboard,
                        zone,
                        "unmapped-user-calculation-reference",
                        "translated Sigma formula contains a reference that cannot be mapped through dashboard metadata",
                        references=missing,
                        **evidence,
                    )
                    return None
                if derivation in USER_DERIVATIONS:
                    # Aggregate DM metrics evaluate to NULL when first exposed
                    # as columns on an ungrouped Master table. Keep the
                    # translated aggregate in the chart's grouping context.
                    formula = qualified
                elif derivation in AGGREGATIONS:
                    formula = f"{AGGREGATIONS[derivation]}({qualified})"
                else:
                    self.residue(
                        dashboard,
                        zone,
                        "unsupported-user-aggregation",
                        "translated row calculation still has an unsupported shelf aggregation",
                        aggregation=derivation,
                        **evidence,
                    )
                    return None
            else:
                if not self.master_column(field):
                    self.add_master_resolution_residue(dashboard, zone, field)
                    return None
                formula = f"{AGGREGATIONS[derivation]}([Master/{field.caption}])"
            column_id = f"{element_id}-measure-{index}"
            measure_ids.append(column_id)
            item = {
                "id": column_id,
                "name": field.caption,
                "formula": formula,
            }
            field_format = self._field_format(zone, field)
            if field_format:
                item["format"] = field_format
            columns.append(item)

        element: dict[str, Any] = {
            "id": element_id,
            "kind": (
                "kpi-chart"
                if chart_kind == "kpi"
                else ("combo-chart" if dual_axis else f"{chart_kind}-chart")
            ),
            "name": str(zone.get("display_title") or zone.get("caption") or chart_kind.title()),
            "source": {"kind": "table", "elementId": "master"},
            "columns": columns,
        }
        if chart_kind == "kpi":
            element["value"] = {"columnId": measure_ids[0]}
        else:
            element["xAxis"] = {"columnId": dimension_column_id}
            element["yAxis"] = {
                "columnIds": (
                    [
                        {"columnId": column_id, "type": chart_kind}
                        for column_id in measure_ids
                    ]
                    if dual_axis
                    else measure_ids
                )
            }
            if dual_axis:
                element["yAxis2"] = {"columnIds": [measure_ids[1]]}
            if chart_kind == "bar" and not dual_axis:
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
            self.add_master_resolution_residue(dashboard, zone, field)
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
    def dashboard_row_units(dashboard: dict[str, Any]) -> int:
        canvas = dashboard.get("canvas_px")
        if not isinstance(canvas, dict):
            return DEFAULT_PAGE_ROW_UNITS
        try:
            height = float(canvas.get("h") or 0)
        except (TypeError, ValueError):
            return DEFAULT_PAGE_ROW_UNITS
        if height <= 0:
            return DEFAULT_PAGE_ROW_UNITS
        scaled = round(
            DEFAULT_PAGE_ROW_UNITS * height / REFERENCE_CANVAS_HEIGHT_PX
        )
        return max(MIN_PAGE_ROW_UNITS, min(MAX_PAGE_ROW_UNITS, scaled))

    @staticmethod
    def normalized_title(value: object) -> str:
        return re.sub(r"\s+", " ", str(value or "").replace("Æ", " ")).strip().casefold()

    @classmethod
    def zone_text(cls, zone: dict[str, Any]) -> str:
        return cls.normalized_title(
            "".join(
                str(item.get("text") or "")
                for item in zone.get("text_runs") or []
                if isinstance(item, dict)
            )
        )

    @staticmethod
    def _zone_edges(zone: dict[str, Any]) -> tuple[float, float, float, float]:
        x = float(zone.get("x_pct") or 0)
        y = float(zone.get("y_pct") or 0)
        width = float(zone.get("w_pct") or 0)
        height = float(zone.get("h_pct") or 0)
        return x, y, x + width, y + height

    @classmethod
    def kpi_managed_title_zones(
        cls, dashboard: dict[str, Any], dashboard_name: str
    ) -> dict[int, dict[str, Any]]:
        zones = dashboard.get("zones") or []
        kpis = [
            zone
            for zone in zones
            if isinstance(zone, dict)
            and zone.get("kind") == "chart"
            and zone.get("chart_kind") == "kpi"
        ]
        managed: dict[int, dict[str, Any]] = {}
        dashboard_title = cls.normalized_title(dashboard_name)
        for index, zone in enumerate(zones):
            if not isinstance(zone, dict) or zone.get("kind") != "text":
                continue
            text = cls.zone_text(zone)
            if not text or text == dashboard_title:
                continue
            try:
                text_left, text_top, text_right, text_bottom = cls._zone_edges(zone)
            except (TypeError, ValueError):
                continue
            matches = []
            for chart in kpis:
                titles = {
                    cls.normalized_title(chart.get("display_title")),
                    cls.normalized_title(chart.get("caption")),
                }
                titles.discard("")
                if text not in titles:
                    continue
                try:
                    chart_left, chart_top, chart_right, _chart_bottom = cls._zone_edges(
                        chart
                    )
                except (TypeError, ValueError):
                    continue
                if (
                    abs(text_left - chart_left)
                    <= KPI_TITLE_HORIZONTAL_TOLERANCE_PCT
                    and abs(text_right - chart_right)
                    <= KPI_TITLE_HORIZONTAL_TOLERANCE_PCT
                    and text_top <= chart_top
                    and abs(text_bottom - chart_top)
                    <= KPI_TITLE_VERTICAL_TOLERANCE_PCT
                ):
                    matches.append(chart)
            if len(matches) == 1:
                managed[index] = matches[0]
        return managed

    @staticmethod
    def placement(
        element_id: str,
        zone: dict[str, Any],
        row_units: int = DEFAULT_PAGE_ROW_UNITS,
    ) -> str:
        x = max(0.0, min(100.0, float(zone.get("x_pct") or 0.0)))
        y = max(0.0, min(100.0, float(zone.get("y_pct") or 0.0)))
        width = max(0.1, float(zone.get("w_pct") or 100.0))
        height = max(0.1, float(zone.get("h_pct") or 10.0))
        row_units = max(
            MIN_PAGE_ROW_UNITS, min(MAX_PAGE_ROW_UNITS, int(row_units))
        )
        # Adjacent Tableau zones share the same percentage boundary. Map that
        # boundary with the same rounding rule on both sides so they share one
        # grid line after conversion.
        col_start = max(1, min(24, round(x * 24 / 100) + 1))
        col_end = max(col_start + 1, min(25, round((x + width) * 24 / 100) + 1))
        row_start = max(
            1, min(row_units, round(y * row_units / 100) + 1)
        )
        row_end = max(
            row_start + 1,
            min(
                row_units + 1,
                round((y + height) * row_units / 100) + 1,
            ),
        )
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
            row_units = self.dashboard_row_units(dashboard)
            managed_kpi_titles = self.kpi_managed_title_zones(
                dashboard, dashboard_name
            )
            chart_captions = {
                str(zone.get("caption") or "")
                for zone in dashboard.get("zones") or []
                if zone.get("kind") == "chart"
            }
            for zone_index, zone in enumerate(dashboard.get("zones") or []):
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
                if zone_index in managed_kpi_titles:
                    chart = managed_kpi_titles[zone_index]
                    chart_id = stable_id(
                        "chart", f"{dashboard_name}:{chart.get('id')}"
                    )
                    self.disposition(
                        dashboard_name, zone, "chart-managed-title", chart_id
                    )
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
                    placements.append(
                        self.placement(element["id"], zone, row_units)
                    )
                    self.disposition(dashboard_name, zone, "emitted", element["id"])
            page_layouts.append(
                "\n".join(
                    [
                        (
                            f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
                            f'gridTemplateRows="repeat({row_units}, auto)" '
                            f'id={quoteattr(page_id)}>'
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
                "formula": self.master_formulas[key],
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
        support_placements = [
            (
                f'  <Element elementId={quoteattr(element["id"])} '
                f'gridColumn="1 / 25" gridRow="{20 * index} / {20 * (index + 1)}"/>'
            )
            for index, element in enumerate(self.support_elements, 1)
        ]
        data_page = "\n".join(
            [
                (
                    '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
                    'gridTemplateRows="auto" id="page-data">'
                ),
                '  <Element elementId="master" gridColumn="1 / 25" gridRow="1 / 20"/>',
                *support_placements,
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
            "elements": [master, *self.support_elements, *content_elements],
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
                "emittedElements": len(content_elements) + len(self.support_elements),
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
    parser.add_argument("--formula-audit")
    parser.add_argument("--dm-spec")
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
        formula_audit_path = (
            Path(args.formula_audit).expanduser().resolve()
            if args.formula_audit
            else None
        )
        dm_spec_path = (
            Path(args.dm_spec).expanduser().resolve() if args.dm_spec else None
        )
        builder = WorkbookBuilder(
            read_json(layout_path),
            read_json(meta_path),
            data_model_id=args.data_model_id,
            element_id=args.element_id,
            folder_id=args.folder_id,
            data_model_element_name=args.data_model_element_name,
            title=args.title,
            formula_audit=(
                read_json(formula_audit_path) if formula_audit_path else None
            ),
            dm_spec=read_json(dm_spec_path) if dm_spec_path else None,
        )
        spec, report = builder.build()
        report["inputs"] = {
            "layout": str(layout_path),
            "meta": str(meta_path),
            "dataModelId": args.data_model_id,
            "elementId": args.element_id,
            "dataModelElementName": args.data_model_element_name,
            "formulaAudit": str(formula_audit_path) if formula_audit_path else None,
            "dmSpec": str(dm_spec_path) if dm_spec_path else None,
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
