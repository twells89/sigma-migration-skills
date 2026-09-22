#!/usr/bin/env python3
"""Mechanized control-wiring lint and reach analysis for Sigma workbooks."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from lib.code_rep import workbook_elements, workbook_elements_with_pages

QUERYABLE = {
    "table", "pivot-table", "input-table", "bar-chart", "line-chart",
    "pie-chart", "donut-chart", "area-chart", "scatter-chart", "combo-chart",
    "kpi-chart", "box-chart", "funnel-chart", "gauge-chart", "waterfall-chart",
    "sankey-chart", "region-map", "point-map", "viz", "chart", "treemap-chart",
    "heatmap-chart", "word-cloud",
    "progress",
}


def source_element_id(element: dict[str, Any]) -> str | None:
    source = element.get("source")
    if not isinstance(source, dict):
        return None
    if source.get("kind") == "source" and isinstance(source.get("source"), dict):
        source = source["source"]
    return str(source.get("elementId")) if source.get("elementId") else None


def elements(spec: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result = {}
    for element, page in workbook_elements_with_pages(spec):
        element_id = element.get("id") or element.get("elementId")
        if not element_id:
            continue
        result[str(element_id)] = {
            "el": element,
            "page": (page or {}).get("name") or (page or {}).get("id"),
            "page_id": (page or {}).get("id"),
            "kind": str(element.get("kind") or element.get("type") or ""),
            "name": element.get("name"),
            "srcel": source_element_id(element),
        }
    return result


def is_control(info: dict[str, Any]) -> bool:
    return "control" in info["kind"]


def closure(
    element_map: dict[str, dict[str, Any]], roots: list[str]
) -> set[str]:
    reached = set(roots)
    while True:
        before = len(reached)
        for element_id, info in element_map.items():
            if info.get("srcel") in reached:
                reached.add(element_id)
        if len(reached) == before:
            return reached


def formula_refs(
    element_map: dict[str, dict[str, Any]], control_id: str | None
) -> list[str]:
    if not control_id:
        return []
    pattern = re.compile(r"\[" + re.escape(str(control_id)) + r"\]")
    return [
        element_id
        for element_id, info in element_map.items()
        if not is_control(info)
        and pattern.search(json.dumps(info["el"], sort_keys=True))
    ]


def controls_report(spec: dict[str, Any]) -> list[dict[str, Any]]:
    element_map = elements(spec)
    rows = []
    for element_id, info in element_map.items():
        if not is_control(info):
            continue
        element = info["el"]
        control_id = element.get("controlId")
        targets = [
            str((target.get("source") or {}).get("elementId"))
            for target in element.get("filters") or []
            if isinstance(target, dict) and (target.get("source") or {}).get("elementId")
        ]
        live = [target for target in targets if target in element_map]
        references = formula_refs(element_map, control_id)
        reached = closure(element_map, list(dict.fromkeys(live + references))) if live or references else set()
        page_queryable = [
            query_id
            for query_id, query_info in element_map.items()
            if query_id != element_id
            and info.get("page_id")
            and query_info.get("page_id") == info.get("page_id")
            and query_info["kind"] in QUERYABLE
        ]
        rows.append(
            {
                "control_element_id": element_id,
                "control_id": control_id,
                "name": info.get("name"),
                "page": info.get("page"),
                "control_type": element.get("controlType"),
                "filter_targets": live,
                "ghost_targets": [target for target in targets if target not in live],
                "formula_refs": references,
                "reach": reached,
                "page_queryable": page_queryable,
                "uncovered": [
                    query_id for query_id in page_queryable if query_id not in reached
                ],
            }
        )
    return rows


def resolve_ref(
    element_map: dict[str, dict[str, Any]], reference: str
) -> list[str]:
    if reference in element_map:
        return [reference]
    return [
        element_id
        for element_id, info in element_map.items()
        if info.get("name") == reference
    ]


def label(element_map: dict[str, dict[str, Any]], element_id: str) -> str:
    name = (element_map.get(element_id) or {}).get("name")
    return f"{name!r} ({element_id})" if name else element_id


def default_values(element: dict[str, Any]) -> list[Any]:
    if isinstance(element.get("values"), list):
        return element["values"]
    for key in ("value", "defaultValue"):
        if key in element and element[key] is not None:
            return element[key] if isinstance(element[key], list) else [element[key]]
    return []


def column_alias_groups(spec: dict[str, Any]) -> dict[str, dict[str, list[str]]]:
    result = {}
    for element in workbook_elements(spec):
        if element.get("kind") != "table" or not element.get("id"):
            continue
        groups: dict[str, list[str]] = {}
        for column in element.get("columns") or []:
            if not isinstance(column, dict) or not column.get("id") or not isinstance(
                column.get("formula"), str
            ):
                continue
            formula = " ".join(column["formula"].split())
            groups.setdefault(formula, []).append(column["id"])
        result[str(element["id"])] = groups
    return result


def conflicting_default_violations(
    spec: dict[str, Any], element_map: dict[str, dict[str, Any]]
) -> list[str]:
    aliases = column_alias_groups(spec)
    entries = []
    for element_id, info in element_map.items():
        if not is_control(info):
            continue
        element = info["el"]
        defaults = default_values(element)
        if not defaults:
            continue
        for target in element.get("filters") or []:
            if not isinstance(target, dict):
                continue
            target_id = (target.get("source") or {}).get("elementId")
            column_id = target.get("columnId")
            if not target_id or not column_id or str(target_id) not in element_map:
                continue
            alias = str(column_id)
            for formula, ids in aliases.get(str(target_id), {}).items():
                if column_id in ids:
                    alias = formula
                    break
            entries.append(
                {
                    "eid": element_id,
                    "cid": element.get("controlId") or element_id,
                    "page": info.get("page"),
                    "page_id": info.get("page_id"),
                    "target": str(target_id),
                    "alias": alias,
                    "defaults": {str(value) for value in defaults},
                }
            )
    violations = []
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for entry in entries:
        grouped.setdefault((entry["target"], entry["alias"]), []).append(entry)
    for group in grouped.values():
        for index, left in enumerate(group):
            for right in group[index + 1 :]:
                if (
                    not left["page_id"]
                    or not right["page_id"]
                    or left["page_id"] == right["page_id"]
                    or left["defaults"] & right["defaults"]
                ):
                    continue
                violations.append(
                    "conflicting cross-page control defaults: control "
                    f"{label(element_map, left['eid'])} [{left['cid']}] on page "
                    f"{left['page']!r} defaults to {sorted(left['defaults'])!r} and "
                    f"control {label(element_map, right['eid'])} [{right['cid']}] "
                    f"on page {right['page']!r} defaults to "
                    f"{sorted(right['defaults'])!r}, but both filter the same "
                    f"element {label(element_map, left['target'])} and column."
                )
    return list(dict.fromkeys(violations))


def lint(
    spec: dict[str, Any], scope: dict[str, Any] | None = None
) -> list[str]:
    violations: list[str] = []
    element_map = elements(spec)
    rows = controls_report(spec)
    scope_by_control = {
        row.get("controlId"): row
        for row in (scope or {}).get("controls") or []
        if isinstance(row, dict) and row.get("controlId")
    }
    original_scope_ids = set(scope_by_control)
    if isinstance(scope, dict):
        signals = int(scope.get("sourceFilterSignals") or 0)
        scoped = scope.get("controls") or []
        surfaced = bool(scoped) and all(
            isinstance(row, dict)
            and str(row.get("status")) in {"needs-wiring", "needs-materialization"}
            for row in scoped
        )
        if signals > 0 and not rows and not surfaced:
            violations.append(
                f"no controls built: the source artifact reported {signals} "
                "filter signal(s) but the spec contains ZERO controls"
            )
    for row in rows:
        annotation = scope_by_control.pop(row["control_id"], {}) or {}
        annotation_scope = annotation.get("scope") or element_map[
            row["control_element_id"]
        ]["el"].get("controlScope")
        control_id_suffix = (
            f" [{row['control_id']}]" if row["control_id"] else ""
        )
        control_label = (
            f"control {label(element_map, row['control_element_id'])}"
            f"{control_id_suffix} "
            f"on page {row['page']!r}"
        )
        for ghost in row["ghost_targets"]:
            violations.append(
                f"ghost target: {control_label} lists {ghost!r}, which is not in the spec"
            )
        if not row["reach"]:
            violations.append(
                f"dead control: {control_label} has no resolving filter target "
                "and no [controlId] reference"
            )
            continue
        for reference in annotation.get("mustReach") or []:
            ids = resolve_ref(element_map, str(reference))
            if not ids:
                violations.append(
                    f"scope mustReach: {control_label} — {reference!r} does not exist"
                )
            elif not any(element_id in row["reach"] for element_id in ids):
                violations.append(
                    f"scope mustReach: {control_label} does NOT reach {reference!r}"
                )
        if isinstance(annotation_scope, list):
            for reference in annotation_scope:
                ids = resolve_ref(element_map, str(reference))
                if not ids:
                    violations.append(
                        f"controlScope: {control_label} — {reference!r} does not exist"
                    )
                elif not any(element_id in row["reach"] for element_id in ids):
                    violations.append(
                        f"controlScope: {control_label} does NOT reach {reference!r}"
                    )
        elif row["uncovered"]:
            names = ", ".join(label(element_map, item) for item in row["uncovered"])
            violations.append(
                f"partial control: {control_label} affects "
                f"{len(row['page_queryable']) - len(row['uncovered'])} of "
                f"{len(row['page_queryable'])} same-page queryable element(s); "
                f"NOT affected: {names}"
            )
    violations.extend(conflicting_default_violations(spec, element_map))
    surfaced_statuses = {"needs-wiring", "needs-materialization"}
    unmatched = {
        control_id: record
        for control_id, record in scope_by_control.items()
        if str(record.get("status")) not in surfaced_statuses
    }
    spec_ids = {row["control_id"] for row in rows if row["control_id"]}
    if unmatched and spec_ids and not (spec_ids & original_scope_ids):
        violations.append(
            "control-scope drift: NONE of the spec controls match any controlId "
            "in control-scope.json"
        )
    else:
        for control_id, record in unmatched.items():
            source_name = (
                f" (source: {record.get('sourceName')!r})"
                if record.get("sourceName")
                else ""
            )
            violations.append(
                f"missing control: control-scope.json expects {control_id!r}"
                f"{source_name}, but the spec has no matching control"
            )
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec")
    parser.add_argument("scope", nargs="?")
    parser.add_argument("--json-out")
    args = parser.parse_args(argv)
    try:
        spec = json.loads(Path(args.spec).read_text(encoding="utf-8-sig"))
        scope = (
            json.loads(Path(args.scope).read_text(encoding="utf-8-sig"))
            if args.scope and Path(args.scope).is_file()
            else None
        )
        violations = lint(spec, scope)
        checked = len(controls_report(spec))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"control lint: {exc}", file=sys.stderr)
        return 2
    if args.json_out:
        Path(args.json_out).write_text(
            json.dumps(
                {
                    "status": "PASS" if not violations else "FAIL",
                    "controls_checked": checked,
                    "violations": violations,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
    if not violations:
        print(f"control lint: clean ({checked} control(s) checked)")
        return 0
    print(f"control lint: {len(violations)} violation(s):", file=sys.stderr)
    for violation in violations:
        print(f"  - {violation}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
