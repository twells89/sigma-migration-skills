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
                if derivation in USER_DERIVATIONS:
                    metric = self.matching_metric(field, translated)
                    if metric is not None:
                        if not self.metric_master_column(field, metric):
                            self.residue(
                                dashboard,
                                zone,
                                "ambiguous-data-model-metric",
                                "matching data-model metric could not be exposed through the Master source",
                                metric=metric.get("name"),
                                **evidence,
                            )
                            return None
                        formula = f"[Master/{field.caption}]"
                if formula is None:
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
