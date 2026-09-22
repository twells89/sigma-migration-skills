#!/usr/bin/env python3
"""Fail fast when a workbook data element has no usable data binding."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterator

SCHEMA_VERSION = 1
STRUCTURAL_KEYS = ("pages", "elements", "children")
BINDING_KEYS = {
    "columns", "column", "xaxis", "yaxis", "color", "value", "values",
    "groupby", "row", "rows", "rowaxis", "rowaxes", "rowgroup", "rowgroups",
    "columnaxis", "columnaxes", "columngroup", "columngroups", "category",
    "categories", "series", "measure", "measures", "dimension", "dimensions",
    "size", "datasource", "datasources", "source", "sources",
}
REFERENCE_KEYS = {
    "column", "columnid", "columnids", "field", "fieldid", "fieldids",
    "elementid", "sourceid", "datasourceid", "datasetid", "tableid",
    "connectionid", "formula", "expression", "sql", "path", "url", "measure",
    "measureid", "dimension", "dimensionid",
}
ID_CONTEXTS = BINDING_KEYS


class InputError(ValueError):
    pass


def normalize_key(value: Any) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value or "").lower())


def unwrap_document(spec: Any) -> dict[str, Any]:
    if not isinstance(spec, dict):
        raise InputError("workbook spec must be a JSON object")
    if "document" not in spec:
        return spec
    document = spec["document"]
    if not isinstance(document, dict):
        raise InputError("workbook spec document wrapper must contain a JSON object")
    return document


def structural_nodes(document: dict[str, Any]) -> Iterator[dict[str, Any]]:
    def visit(node: Any) -> Iterator[dict[str, Any]]:
        if not isinstance(node, dict):
            return
        yield node
        for key in STRUCTURAL_KEYS:
            if key in node:
                yield from visit_collection(node[key])

    def visit_collection(value: Any) -> Iterator[dict[str, Any]]:
        if isinstance(value, list):
            for item in value:
                yield from visit(item)
        elif isinstance(value, dict):
            if "kind" in value or any(key in value for key in STRUCTURAL_KEYS):
                yield from visit(value)
            else:
                for key in sorted(value, key=str):
                    yield from visit(value[key])

    yield from visit(document)


def data_element(element: dict[str, Any]) -> bool:
    kind = normalize_key(element.get("kind"))
    if not kind or "control" in kind or "container" in kind:
        return False
    return (
        kind in {"chart", "kpi", "table", "progress"}
        or kind.endswith("chart")
        or kind.endswith("table")
        or "pivot" in kind
        or "crosstab" in kind
    )


def literal_color(text: str) -> bool:
    return bool(
        re.fullmatch(r"#[0-9a-f]{3,8}", text, re.I)
        or re.match(r"(?:rgb|rgba|hsl|hsla)\s*\(", text, re.I)
        or text.lower()
        in {"black", "white", "red", "green", "blue", "gray", "grey", "transparent", "currentcolor"}
    )


def usable_reference(value: Any) -> bool:
    if isinstance(value, list):
        return any(usable_reference(item) for item in value)
    if isinstance(value, dict):
        return any(usable_reference(item) for item in value.values())
    if isinstance(value, bool) or value is None:
        return False
    if isinstance(value, (int, float)):
        return True
    return bool(str(value).strip())


def usable_binding(value: Any, context: str) -> bool:
    if isinstance(value, list):
        return any(usable_binding(item, context) for item in value)
    if isinstance(value, dict):
        for key, nested in value.items():
            normalized = normalize_key(key)
            if normalized in REFERENCE_KEYS and usable_reference(nested):
                return True
            if normalized == "id" and context in ID_CONTEXTS and usable_reference(nested):
                return True
            if (
                normalized == "name"
                and context in {"source", "sources", "datasource", "datasources"}
                and usable_reference(nested)
            ):
                return True
            if normalized in BINDING_KEYS and usable_binding(nested, normalized):
                return True
            if isinstance(nested, (dict, list)) and usable_binding(nested, context):
                return True
        return False
    if isinstance(value, (str, bytes)):
        text = value.decode(errors="replace") if isinstance(value, bytes) else value
        return bool(text.strip()) and not (context == "color" and literal_color(text.strip()))
    return False


def binding_value(element: dict[str, Any], wanted: str) -> Any:
    for key, value in element.items():
        if normalize_key(key) == wanted:
            return value
    return None


def usable_data_binding(element: dict[str, Any]) -> bool:
    kind = normalize_key(element.get("kind"))
    columns = binding_value(element, "columns")
    if "kpi" in kind or kind == "progress":
        if any(
            usable_binding(binding_value(element, name), name)
            for name in ("value", "values", "yaxis", "measure", "measures")
            if binding_value(element, name) is not None
        ):
            return True
        return isinstance(columns, list) and any(
            usable_binding(item, "columns") for item in columns
        )
    if kind == "chart" or kind.endswith("chart"):
        if any(
            usable_binding(binding_value(element, name), name)
            for name in ("yaxis", "value", "values", "measure", "measures", "size")
            if binding_value(element, name) is not None
        ):
            return True
        return isinstance(columns, list) and sum(
            usable_binding(item, "columns") for item in columns
        ) >= 2
    return any(
        normalize_key(key) in BINDING_KEYS
        and usable_binding(value, normalize_key(key))
        for key, value in element.items()
    )


def scalar_text(value: Any) -> str:
    if value is None:
        return ""
    if not isinstance(value, dict):
        return str(value)
    return scalar_text(value.get("text") or value.get("name") or value.get("title"))


def lint(spec: Any, spec_path: str | None = None) -> dict[str, Any]:
    risks = []
    checked = 0
    for element in structural_nodes(unwrap_document(spec)):
        if not data_element(element):
            continue
        checked += 1
        if usable_data_binding(element):
            continue
        risks.append(
            {
                "id": scalar_text(element.get("id") or element.get("elementId")),
                "name": scalar_text(element.get("name") or element.get("title")),
                "kind": str(element.get("kind") or ""),
                "reasons": ["no usable data bindings"],
            }
        )
    risks.sort(key=lambda row: (row["id"], row["name"], row["kind"]))
    return {
        "schema_version": SCHEMA_VERSION,
        "spec": str(spec_path or ""),
        "status": "PASS" if not risks else "FAIL",
        "elements_checked": checked,
        "blank_risk_count": len(risks),
        "elements": risks,
    }


def lint_file(spec_path: Path, out_path: Path | None = None) -> dict[str, Any]:
    try:
        spec = json.loads(spec_path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise InputError(f"cannot read {spec_path}: {exc}") from exc
    report = lint(spec, str(spec_path))
    output = out_path or spec_path.with_name("blank-risk-elements.json")
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def error_report(spec_path: Path, message: str) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "spec": str(spec_path),
        "status": "FAIL",
        "elements_checked": 0,
        "blank_risk_count": 0,
        "elements": [],
        "error": message,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True)
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    try:
        report = lint_file(Path(args.spec), Path(args.out) if args.out else None)
    except InputError as exc:
        output = Path(args.out) if args.out else Path(args.spec).with_name(
            "blank-risk-elements.json"
        )
        try:
            output.write_text(
                json.dumps(error_report(Path(args.spec), str(exc)), indent=2) + "\n",
                encoding="utf-8",
            )
        except OSError:
            pass
        print(f"lint-render-integrity: {exc}", file=sys.stderr)
        return 2
    output = args.out or str(Path(args.spec).with_name("blank-risk-elements.json"))
    print(
        f"lint-render-integrity: {report['status']} — "
        f"{report['elements_checked']} data element(s) checked, "
        f"{report['blank_risk_count']} blank-risk element(s); evidence: {output}"
    )
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
