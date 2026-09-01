#!/usr/bin/env python3
"""Scan a Tableau TWB and emit fail-closed migration gap artifacts.

This is the Python runtime twin of scan-workbook-gaps.rb.  Its stable command
line is:

    python3 scripts/scan-workbook-gaps.py WORKBOOK.twb [OUT.md]

OUT defaults to ``<workbook>-gaps-report.md``.  The scanner also writes the
same-stem JSON report, ``formula-audit.json``, and structural plan sidecars
when applicable.  It uses only the Python standard library; formula
translation is delegated to the existing vendored Node helper.
"""

from __future__ import annotations

import csv
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

HERE = Path(__file__).resolve().parent
FORMULA_AUDIT_HELPER = HERE / "formula-audit.mjs"
FUNCTION_CATALOG = HERE.parent / "refs" / "functions.json"
FORMULA_STATUSES = (
    "spec",
    "verify",
    "chart_only",
    "rls",
    "not_converted",
    "unmapped",
)
TRANSLATED_STATUSES = {"spec", "verify", "chart_only", "rls"}

WAREHOUSE_CONNECTION_CLASSES = {
    "snowflake",
    "redshift",
    "bigquery",
    "postgres",
    "greenplum",
    "sqlserver",
    "mysql",
    "oracle",
    "databricks",
    "azure-sql",
    "synapse",
    "vertica",
    "teradata",
    "presto",
    "trino",
    "athena",
    "saphana",
}
FILE_CONNECTION_CLASSES = {
    "textscan",
    "csv",
    "msexcel",
    "excel-direct",
    "hyper",
    "webdata-direct",
    "google-sheets",
    "googlesheets",
    "salesforce",
    "sqlproxy",
}
ROUTE_RECOMMENDATIONS = {
    "same-warehouse-repoint": (
        "Both sources resolve to the same warehouse. Build one data model with "
        "both sources and a relationship on the linking fields, then verify it."
    ),
    "materialize-via-vds": (
        "The secondary is not in the primary warehouse. Land it with "
        "tableau-vds-to-cdw before conversion, then model the relationship."
    ),
    "flag-unreachable": (
        "The secondary is a different live system. The blend cannot be "
        "converted safely until it is landed or manually remodeled."
    ),
}


@dataclass
class Feature:
    name: str
    status: str
    count: int
    blurb: str
    worksheets: list[str] | None = None

    def as_dict(self) -> dict[str, Any]:
        row: dict[str, Any] = {
            "name": self.name,
            "status": self.status,
            "count": self.count,
            "blurb": self.blurb,
        }
        # Missing attribution means unknown/fail-open to scoped consumers.
        if self.worksheets:
            row["worksheets"] = sorted(set(self.worksheets))
        return row


@dataclass(frozen=True)
class InventoryRule:
    name: str
    pattern: re.Pattern[str]
    status: str
    blurb: str


def rule(name: str, pattern: str, status: str, blurb: str, flags: int = 0) -> InventoryRule:
    return InventoryRule(name, re.compile(pattern, flags), status, blurb)


# The regex inventory intentionally stays raw-text based to match the Ruby
# scanner's behavior even when Tableau serializes extension-tag spellings.
INVENTORY = (
    rule(
        "Bar / line / area / pie / scatter chart",
        r"<mark class=['\"](?:Bar|Line|Area|Pie|Circle|Shape)['\"]",
        "auto",
        "Translated to the corresponding native Sigma chart.",
    ),
    rule(
        "Region / filled map",
        r"<mark class=['\"](?:Multipolygon|Polygon|Filled|Map)['\"]",
        "auto",
        "Translated to a Sigma region map.",
    ),
    rule(
        "Point / symbol map",
        r"<column[^>]+caption=['\"]Latitude['\"]",
        "auto",
        "Translated when both latitude and longitude are available.",
        re.I,
    ),
    rule(
        "Parameter (list domain) + CASE-on-param",
        r"param-domain-type=['\"]list['\"]",
        "auto",
        "List parameters become controls; parameter calculations are translated.",
    ),
    rule(
        "Parameter (numeric range)",
        r"param-domain-type=['\"]range['\"]",
        "auto",
        "Numeric range parameters become number-range controls.",
    ),
    rule(
        "Custom SQL data source",
        r"<relation\s[^>]*\btype=['\"]text['\"]",
        "auto",
        "Inventory the SQL and preserve its semantics in a warehouse source.",
    ),
    rule(
        "Hyper / Tableau extract",
        r"<connection\s[^>]*\bclass=['\"]hyper['\"]|<extract\b",
        "hint",
        "Sigma uses warehouse data; verify extraction and freshness explicitly.",
    ),
    rule(
        "FIXED LOD calc (incl. nested)",
        r"\{\s*FIXED\b",
        "auto",
        "Translated through grouped helper elements; verify chart grain.",
        re.I,
    ),
    rule(
        "INCLUDE/EXCLUDE LOD",
        r"\{\s*(?:INCLUDE|EXCLUDE)\b",
        "manual",
        "Requires chart-grain-aware remodeling and value verification.",
        re.I,
    ),
    rule(
        "Context filters",
        r"\bcontext=['\"]true['\"]",
        "hint",
        "Verify filter ordering and any context-scoped LOD behavior.",
    ),
    rule(
        "Reference lines / bands / trendlines",
        r"<(?:reference-line|reference-band|reference-distribution|trendline-model)\b",
        "hint",
        "Add and verify native Sigma reference marks after conversion.",
    ),
    rule(
        "Dashboard filter / highlight / nav actions",
        r"command=['\"]tsc:tsl-(?:filter|highlight|navigate|set-action|parameter-action|url)",
        "manual",
        "Action behavior requires explicit target and interaction wiring.",
    ),
    rule(
        "Forecast / trendline model",
        r"<forecast\b",
        "manual",
        "No direct Sigma forecast primitive; remodel or use warehouse SQL.",
    ),
    rule(
        "Story points (sequential narrative)",
        r"<story\b",
        "hint",
        "Convert each story point to a separate Sigma page.",
    ),
    rule(
        "Drill hierarchies",
        r"<drill-paths>|<drill-path\b",
        "manual",
        "Map to drill controls and verify target-column alignment.",
    ),
    rule(
        "Window calcs with NO validated Sigma mapping",
        r"\b(?:WINDOW_(?:MEDIAN|PERCENTILE|CORR|COVARP?|VARP|STDEVP)|"
        r"PREVIOUS_VALUE|RANK_MODIFIED)\s*\(|\bSIZE\s*\(\s*\)",
        "manual",
        "No validated chart-formula mapping; use SQL or explicitly re-author.",
        re.I,
    ),
    rule(
        "Tableau SCRIPT_* (R/Python)",
        r"\bSCRIPT_(?:REAL|STR|INT|BOOL)\b",
        "unhandled",
        "No Sigma equivalent. Rewrite in warehouse SQL/Python or external prep.",
        re.I,
    ),
    rule(
        "Phone / mobile-specific layout",
        r"<device-layout\b|<phone-layout\b",
        "unhandled",
        "Sigma has one responsive layout, not a separate mobile layout.",
        re.I,
    ),
    rule(
        "Show/hide containers",
        r"show-hide-container|is-modal=['\"]true['\"]",
        "unhandled",
        "Conditional container visibility requires explicit manual wiring.",
        re.I,
    ),
    rule(
        "Sets (computed / manual)",
        r"<groupfilter function=['\"]set['\"]|<set\s",
        "unhandled",
        "No direct Sigma equivalent; replace with an accounted boolean calculation.",
    ),
    rule(
        "Viz-in-tooltip (embedded chart in tooltip)",
        r"visual-tooltip|show-viz-in-tooltip",
        "manual",
        "No spec-API path for viz-in-tooltip; recreate or explicitly drop it.",
        re.I,
    ),
)

SECURITY_RE = re.compile(
    r"\b(?:USERNAME|FULLNAME|USERDOMAIN|ISMEMBEROF|ISUSERNAME|USERATTRIBUTE)\s*\(",
    re.I,
)


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def children(node: ET.Element, name: str) -> list[ET.Element]:
    return [child for child in node if local_name(child.tag) == name]


def descendants(node: ET.Element, name: str) -> list[ET.Element]:
    return [item for item in node.iter() if local_name(item.tag) == name]


def direct_path(root: ET.Element, *names: str) -> list[ET.Element]:
    current = [root]
    for name in names:
        current = [item for parent in current for item in children(parent, name)]
    return current


def real_datasources(root: ET.Element) -> list[ET.Element]:
    return [
        ds
        for ds in direct_path(root, "datasources", "datasource")
        if ds.get("name")
        and ds.get("name") != "Parameters"
        and not ds.get("name", "").startswith("Parameters ")
    ]


def worksheet_nodes(root: ET.Element) -> list[ET.Element]:
    return direct_path(root, "worksheets", "worksheet")


def dashboard_nodes(root: ET.Element) -> list[ET.Element]:
    return direct_path(root, "dashboards", "dashboard")


def worksheet_source_names(worksheet: ET.Element) -> list[str]:
    names: list[str] = []
    for view in descendants(worksheet, "view"):
        for group in children(view, "datasources"):
            for source in children(group, "datasource"):
                name = source.get("name")
                if name and name not in names:
                    names.append(name)
    return names


def worksheet_bodies(content: str) -> dict[str, str]:
    pattern = re.compile(
        r"<worksheet\s[^>]*?name=(?:'([^']*)'|\"([^\"]*)\")[^>]*>(.*?)</worksheet>",
        re.S,
    )
    return {(single or double): body for single, double, body in pattern.findall(content)}


def categorize(content: str) -> list[Feature]:
    bodies = worksheet_bodies(content)
    features: list[Feature] = []
    for entry in INVENTORY:
        count = len(entry.pattern.findall(content))
        if not count:
            continue
        hits = sorted(name for name, body in bodies.items() if entry.pattern.search(body))
        features.append(
            Feature(entry.name, entry.status, count, entry.blurb, hits or None)
        )
    return features


def datasource_connections(root: ET.Element) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for datasource in real_datasources(root):
        name = datasource.get("name", "")
        connections: list[dict[str, str]] = []
        for connection in descendants(datasource, "connection"):
            connection_class = connection.get("class", "")
            if not connection_class or connection_class == "federated":
                continue
            row = {
                key: value
                for key in ("class", "server", "dbname", "schema", "filename")
                if (value := connection.get(key)) is not None
            }
            if row not in connections:
                connections.append(row)
        result[name] = {
            "name": name,
            "caption": datasource.get("caption", name),
            "connections": connections,
        }
    return result


def route_blend(primary: list[dict[str, str]], secondary: list[dict[str, str]]) -> str:
    for left in primary:
        for right in secondary:
            same_database = (
                not left.get("dbname")
                or not right.get("dbname")
                or left["dbname"].casefold() == right["dbname"].casefold()
            )
            if (
                left.get("class") == right.get("class")
                and left.get("server", "") == right.get("server", "")
                and same_database
            ):
                return "same-warehouse-repoint"
    classes = {row.get("class", "") for row in secondary}
    if not classes or classes & FILE_CONNECTION_CLASSES:
        return "materialize-via-vds"
    if not classes & WAREHOUSE_CONNECTION_CLASSES:
        return "materialize-via-vds"
    return "flag-unreachable"


def detect_blends(root: ET.Element) -> tuple[list[Feature], dict[str, Any] | None]:
    info = datasource_connections(root)
    blends: list[dict[str, Any]] = []
    for worksheet in worksheet_nodes(root):
        used = [name for name in worksheet_source_names(worksheet) if name in info]
        if len(used) < 2:
            continue
        dependencies: dict[str, list[str]] = {}
        for dependency in descendants(worksheet, "datasource-dependencies"):
            source_name = dependency.get("datasource")
            if not source_name:
                continue
            fields = []
            for column in descendants(dependency, "column"):
                caption = column.get("caption")
                name = column.get("name", "").strip("[]")
                value = caption or name
                if value and value not in fields:
                    fields.append(value)
            dependencies[source_name] = fields
        primary = used[0]
        for secondary in used[1:]:
            if not dependencies.get(secondary):
                continue
            route = route_blend(
                info[primary]["connections"], info[secondary]["connections"]
            )
            blends.append(
                {
                    "worksheet": worksheet.get("name"),
                    "primary": primary,
                    "primary_caption": info[primary]["caption"],
                    "secondary": secondary,
                    "secondary_caption": info[secondary]["caption"],
                    "linking_fields": sorted(
                        set(dependencies.get(primary, []))
                        & set(dependencies[secondary])
                    ),
                    "secondary_fields": dependencies[secondary],
                    "route": route,
                    "recommendation": ROUTE_RECOMMENDATIONS[route],
                }
            )
    if not blends:
        return [], None
    features: list[Feature] = []
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for blend in blends:
        grouped[blend["route"]].append(blend)
    for route, rows in grouped.items():
        worksheets = sorted({str(row["worksheet"]) for row in rows if row["worksheet"]})
        # Same-warehouse blends are reviewable. Routes requiring landing or an
        # inaccessible live system block the Python path rather than silently
        # falling through a merely-manual row.
        status = "hint" if route == "same-warehouse-repoint" else "unhandled"
        features.append(
            Feature(
                f"Data blending ({route})",
                status,
                len(rows),
                f"{ROUTE_RECOMMENDATIONS[route]} Full details are in blend-plan.json.",
                worksheets or None,
            )
        )
    return features, {"datasources": list(info.values()), "blends": blends}


def detect_unions(root: ET.Element) -> list[Feature]:
    parent = {child: node for node in root.iter() for child in node}
    sheet_sources = {
        worksheet.get("name", ""): worksheet_source_names(worksheet)
        for worksheet in worksheet_nodes(root)
    }
    emitted: list[dict[str, Any]] = []
    refused: list[dict[str, Any]] = []
    for datasource in real_datasources(root):
        source_name = datasource.get("name", "")
        sheets = sorted(
            name for name, sources in sheet_sources.items() if source_name in sources
        )
        metadata_columns: set[str] = set()
        for record in descendants(datasource, "metadata-record"):
            if record.get("class") != "column":
                continue
            remote_nodes = children(record, "remote-name")
            remote = (remote_nodes[0].text or "").strip() if remote_nodes else ""
            if remote and remote.casefold() not in {"sheet", "table name"}:
                metadata_columns.add(remote.casefold())
        for relation in descendants(datasource, "relation"):
            if relation.get("type") != "union":
                continue
            direct_relations = children(relation, "relation")
            members = sum(
                child.get("type", "table") == "table" and bool(child.get("table"))
                for child in direct_relations
            )
            non_table = sum(
                child.get("type", "table") != "table" for child in direct_relations
            )
            is_root = local_name(parent.get(relation, ET.Element("")).tag) == "connection"
            row = {
                "datasource": source_name,
                "sheets": sheets,
                "nested": not is_root,
                "members": members,
                "columns": len(metadata_columns),
                "non_table": non_table,
            }
            if is_root and non_table == 0 and members >= 2 and metadata_columns:
                emitted.append(row)
            else:
                refused.append(row)
    features: list[Feature] = []
    if emitted:
        features.append(
            Feature(
                "Union datasource (wildcard, converter-emitted)",
                "hint",
                len(emitted),
                "Root wildcard union is emitted; verify member column matching.",
                sorted({sheet for row in emitted for sheet in row["sheets"]}) or None,
            )
        )
    if refused:
        reasons = []
        for row in refused:
            if row["nested"]:
                reason = "nested"
            elif row["non_table"]:
                reason = f"{row['non_table']} non-table member(s)"
            else:
                reason = f"{row['members']} member(s)/{row['columns']} column(s)"
            reasons.append(f"{row['datasource']} ({reason})")
        features.append(
            Feature(
                "Union datasource (underivable / nested — NOT converted)",
                "unhandled",
                len(refused),
                "The converter refuses unions unless every member is a plain table "
                "in a root union with at least two members and one metadata column: "
                + ", ".join(reasons)
                + ".",
                sorted({sheet for row in refused for sheet in row["sheets"]}) or None,
            )
        )
    return features


def calculation_inventory(root: ET.Element, content: str) -> dict[str, Any]:
    after_datasources = content.split("</datasources>", 1)
    reference_region = after_datasources[1] if len(after_datasources) == 2 else content
    inputs: list[dict[str, Any]] = []
    datasource_rows: list[dict[str, Any]] = []

    all_sources = direct_path(root, "datasources", "datasource")
    for datasource_index, datasource in enumerate(all_sources):
        source_name = datasource.get("name", "")
        if source_name == "Parameters" or source_name.startswith("Parameters "):
            continue
        definitions: dict[str, dict[str, Any]] = {}
        calculations: list[dict[str, Any]] = []
        for column in children(datasource, "column"):
            internal = column.get("name", "")
            if not internal or "__tableau_internal_object_id__" in internal:
                continue
            calculation = next(iter(children(column, "calculation")), None)
            formula = calculation.get("formula") if calculation is not None else None
            row = {
                "internal_name": internal,
                "caption": column.get("caption", internal),
                "formula": formula,
            }
            definitions[internal.casefold()] = row
            definitions[f"[{row['caption']}]".casefold()] = row
            if formula is not None:
                calculations.append(row)

        by_internal = {
            row["internal_name"].casefold(): row for row in calculations
        }
        by_caption: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for row in calculations:
            by_caption[f"[{row['caption']}]".casefold()].append(row)
        graph: dict[str, list[str]] = {}
        orphan_refs: list[dict[str, str]] = []
        for calculation_index, calculation in enumerate(calculations):
            key = calculation["internal_name"]
            graph[key] = []
            for reference in formula_field_refs(calculation["formula"] or ""):
                target = by_internal.get(reference.casefold())
                caption_matches = by_caption.get(reference.casefold(), [])
                if target is None and len(caption_matches) == 1:
                    target = caption_matches[0]
                if target is not None:
                    graph[key].append(target["internal_name"])
                elif (
                    re.match(r"\[Calculation[_-]", reference, re.I)
                    and reference.casefold() not in definitions
                ):
                    orphan_refs.append(
                        {
                            "datasource": source_name,
                            "calculation": calculation["caption"],
                            "internal_name": key,
                            "reference": reference,
                        }
                    )
            graph[key] = sorted(set(graph[key]))
            inputs.append(
                {
                    "id": f"{datasource_index}:{calculation_index}",
                    "datasource_index": datasource_index,
                    "datasource": source_name,
                    "datasource_caption": datasource.get("caption", source_name),
                    "internal_name": key,
                    "caption": calculation["caption"],
                    # `calculation` is consumed by source-object-census's
                    # generic matcher; retaining caption preserves Ruby output.
                    "calculation": calculation["caption"],
                    "formula": calculation["formula"],
                }
            )

        cycles = dependency_cycles(graph, calculations)
        used = {
            row["internal_name"]
            for row in calculations
            if row["internal_name"] in reference_region
        }
        changed = True
        while changed:
            changed = False
            for name in list(used):
                for dependency in graph.get(name, []):
                    if dependency not in used:
                        used.add(dependency)
                        changed = True
        unused = [
            {
                "datasource": source_name,
                "calculation": row["caption"],
                "internal_name": row["internal_name"],
            }
            for row in calculations
            if row["internal_name"] not in used
        ]
        datasource_rows.append(
            {
                "datasource_index": datasource_index,
                "name": source_name,
                "caption": datasource.get("caption", source_name),
                "calculation_cycles": cycles,
                "orphan_internal_calculation_references": sorted(
                    orphan_refs, key=lambda row: (row["calculation"], row["reference"])
                ),
                "unused_calculations": sorted(
                    unused, key=lambda row: (row["calculation"], row["internal_name"])
                ),
            }
        )

    return {
        "inputs": inputs,
        "datasources": datasource_rows,
        "calculation_cycles": [
            {"datasource": source["name"], "calculations": cycle}
            for source in datasource_rows
            for cycle in source["calculation_cycles"]
        ],
        "orphan_internal_calculation_references": [
            row
            for source in datasource_rows
            for row in source["orphan_internal_calculation_references"]
        ],
        "unused_calculations": [
            row
            for source in datasource_rows
            for row in source["unused_calculations"]
        ],
    }


def masked_formula(formula: str) -> str:
    result: list[str] = []
    index = 0
    while index < len(formula):
        if formula.startswith("//", index):
            end = formula.find("\n", index + 2)
            index = len(formula) if end < 0 else end
            result.append(" ")
        elif formula.startswith("/*", index):
            depth = 1
            index += 2
            while index < len(formula) and depth:
                if formula.startswith("/*", index):
                    depth += 1
                    index += 2
                elif formula.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            result.append(" ")
        elif formula[index] in {"'", '"'}:
            quote = formula[index]
            index += 1
            while index < len(formula):
                if formula[index] == quote:
                    index += 1
                    if index < len(formula) and formula[index] == quote:
                        index += 1
                        continue
                    break
                index += 1
            result.append(" ")
        else:
            result.append(formula[index])
            index += 1
    return "".join(result)


def formula_field_refs(formula: str) -> list[str]:
    # Preserve bracketed field references while removing strings/comments.
    return sorted(set(re.findall(r"\[[^\]]+\]", masked_formula(formula))))


def formula_function_names(formula: str) -> list[str]:
    text = re.sub(r"\[[^\]]+\]", " ", masked_formula(formula))
    excluded = {
        "IF",
        "CASE",
        "WHEN",
        "THEN",
        "ELSE",
        "ELSEIF",
        "END",
        "FIXED",
        "INCLUDE",
        "EXCLUDE",
    }
    return sorted(
        {
            match.group(1).upper()
            for match in re.finditer(r"\b([A-Za-z][A-Za-z0-9_]*)\s*\(", text)
            if match.group(1).upper() not in excluded
        }
    )


def dependency_cycles(
    graph: dict[str, list[str]], calculations: list[dict[str, Any]]
) -> list[list[str]]:
    index = 0
    indices: dict[str, int] = {}
    low: dict[str, int] = {}
    stack: list[str] = []
    on_stack: set[str] = set()
    components: list[list[str]] = []

    def visit(node: str) -> None:
        nonlocal index
        indices[node] = low[node] = index
        index += 1
        stack.append(node)
        on_stack.add(node)
        for neighbor in graph.get(node, []):
            if neighbor not in indices:
                visit(neighbor)
                low[node] = min(low[node], low[neighbor])
            elif neighbor in on_stack:
                low[node] = min(low[node], indices[neighbor])
        if low[node] != indices[node]:
            return
        component = []
        while True:
            member = stack.pop()
            on_stack.remove(member)
            component.append(member)
            if member == node:
                break
        components.append(component)

    for node in sorted(graph):
        if node not in indices:
            visit(node)
    captions = {row["internal_name"]: row["caption"] for row in calculations}
    cycles = [
        sorted(captions.get(name, name) for name in component)
        for component in components
        if len(component) > 1
        or (component and component[0] in graph.get(component[0], []))
    ]
    return sorted(cycles, key=lambda row: "\0".join(row))


def run_formula_audit(inventory: dict[str, Any]) -> dict[str, Any]:
    node = os.environ.get("NODE_BIN") or "node"
    completed = subprocess.run(
        [node, str(FORMULA_AUDIT_HELPER)],
        input=json.dumps({"formulas": inventory["inputs"]}),
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode:
        detail = completed.stderr.splitlines()[0].strip() if completed.stderr else ""
        suffix = f": {detail}" if detail else ""
        raise RuntimeError(
            f"formula audit helper failed (exit {completed.returncode}){suffix}"
        )
    batch = json.loads(completed.stdout)
    rows_by_source: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for row in batch.get("formulas", []):
        if row.get("status") == "rls" or SECURITY_RE.search(row.get("formula", "")):
            # Preserve status=rls while supplying the existing source-object
            # census with the explicit unresolved accounting signal it uses.
            row["terminal_status"] = "needs-review"
            row["detail"] = (
                "Tableau user/security calculation requires an explicit "
                "port, customize, or loud skip decision"
            )
        rows_by_source[int(row["datasource_index"])].append(row)
    sources = []
    for source in inventory["datasources"]:
        rows = rows_by_source[source["datasource_index"]]
        counts = {status: 0 for status in FORMULA_STATUSES}
        for row in rows:
            counts[row["status"]] += 1
        converted = sum(row["status"] in TRANSLATED_STATUSES for row in rows)
        sources.append(
            {
                "name": source["name"],
                "caption": source["caption"],
                "total": len(rows),
                "counts": counts,
                "converted": converted,
                "coverage_pct": (
                    100.0 if not rows else round(100.0 * converted / len(rows), 1)
                ),
                "calculation_cycles": source["calculation_cycles"],
                "orphan_internal_calculation_references": source[
                    "orphan_internal_calculation_references"
                ],
                "unused_calculations": source["unused_calculations"],
                "formulas": rows,
            }
        )
    batch.update(
        {
            "datasources": sources,
            "calculation_cycles": inventory["calculation_cycles"],
            "orphan_internal_calculation_references": inventory[
                "orphan_internal_calculation_references"
            ],
            "unused_calculations": inventory["unused_calculations"],
        }
    )
    return batch


def formula_gap_results(audit: dict[str, Any]) -> list[Feature]:
    counts = audit.get("counts") or {}
    unsupported = int(counts.get("not_converted", 0)) + int(
        counts.get("unmapped", 0)
    )
    review = int(counts.get("verify", 0)) + int(counts.get("chart_only", 0))
    features: list[Feature] = []
    if unsupported:
        names = [
            f"{row.get('datasource_caption') or row.get('datasource')}: "
            f"{row.get('caption') or row.get('internal_name')}"
            for row in audit.get("formulas", [])
            if row.get("status") in {"not_converted", "unmapped"}
        ]
        features.append(
            Feature(
                "Converter-refused or unmapped calculated fields",
                "unhandled",
                unsupported,
                f"{unsupported} formula(s) failed the vendored converter path: "
                + ", ".join(names[:12])
                + ". Rewrite or explicitly account for each formula.",
            )
        )
    if review:
        features.append(
            Feature(
                "Converter-translated formulas requiring contextual verification",
                "hint",
                review,
                "Build each formula in its required element context and prove value parity.",
            )
        )
    for cycle in audit.get("calculation_cycles", []):
        features.append(
            Feature(
                f"Circular calculated-field dependency — {cycle['datasource']}",
                "unhandled",
                1,
                "Cycle: "
                + " ↔ ".join(cycle["calculations"])
                + ". Break the dependency cycle before conversion.",
            )
        )
    orphan_refs = audit.get("orphan_internal_calculation_references", [])
    if orphan_refs:
        features.append(
            Feature(
                "Missing internal calculated-field dependencies",
                "unhandled",
                len(orphan_refs),
                ", ".join(
                    f"{row['datasource']}/{row['calculation']} → {row['reference']}"
                    for row in orphan_refs[:12]
                ),
            )
        )
    security_rows = [
        row
        for row in audit.get("formulas", [])
        if row.get("status") == "rls" or SECURITY_RE.search(row.get("formula", ""))
    ]
    if security_rows:
        features.append(
            Feature(
                "Tableau row-level security / user calculations",
                "unhandled",
                len(security_rows),
                "Security semantics are never silently translated or dropped. "
                "Choose port/customize/skip explicitly, implement Sigma RLS, and "
                "verify allowed and denied users before conversion can be GREEN. "
                "Calculations: "
                + ", ".join(
                    str(row.get("caption") or row.get("internal_name"))
                    for row in security_rows[:12]
                )
                + ".",
            )
        )
    return features


def field_statistics(
    root: ET.Element, content: str, audit: dict[str, Any], inventory: dict[str, Any]
) -> dict[str, Any]:
    definitions: dict[str, dict[str, Any]] = {}
    parameter_sources = {
        source
        for source in direct_path(root, "datasources", "datasource")
        if source.get("name") == "Parameters"
    }
    for datasource in direct_path(root, "datasources", "datasource"):
        for column in children(datasource, "column"):
            name = column.get("name")
            if not name or "__tableau_internal_object_id__" in name:
                continue
            calculation = next(iter(children(column, "calculation")), None)
            formula = calculation.get("formula") if calculation is not None else None
            is_parameter = (
                datasource in parameter_sources
                or column.get("param-domain-type") is not None
            )
            definitions.setdefault(
                name,
                {
                    "caption": column.get("caption", name),
                    "formula": formula,
                    "is_calc": formula is not None and not is_parameter,
                    "is_param": is_parameter,
                },
            )
    after_datasources = content.split("</datasources>", 1)
    references = after_datasources[1] if len(after_datasources) == 2 else content
    used = {name for name in definitions if name in references}
    changed = True
    while changed:
        changed = False
        for name in list(used):
            formula = definitions[name].get("formula") or ""
            for candidate in definitions:
                if candidate not in used and candidate in formula:
                    used.add(candidate)
                    changed = True
    calc_names = {name for name, row in definitions.items() if row["is_calc"]}

    def calc_kind(name: str) -> str:
        formula = definitions[name]["formula"] or ""
        if re.search(r"\{\s*(?:FIXED|INCLUDE|EXCLUDE)\b", formula, re.I):
            return "lod"
        if re.search(
            r"\b(?:INDEX|LOOKUP|TOTAL|RANK\w*|WINDOW_\w+|RUNNING_\w+|"
            r"FIRST|LAST|SIZE)\s*\(",
            formula,
            re.I,
        ):
            return "tablecalc"
        if any(other != name and other in formula for other in calc_names):
            return "nested"
        return "simple"

    kinds = Counter(calc_kind(name) for name in calc_names)
    functions = Counter()
    for name in calc_names:
        for function in formula_function_names(definitions[name]["formula"] or ""):
            functions[function] += 1
    catalog_names: set[str] = set()
    try:
        catalog = json.loads(FUNCTION_CATALOG.read_text(encoding="utf-8"))
        catalog_names = {
            str(row["tableau_fn"]).upper() for row in catalog.get("functions", [])
        }
    except (OSError, ValueError, KeyError):
        # Formula audit remains authoritative. An unavailable optional census
        # catalog must not claim functions are supported.
        catalog_names = set()
    dashboards_text = content[
        content.find("<dashboards>") : content.rfind("</dashboards>") + 13
    ]
    orphans = [
        worksheet.get("name")
        for worksheet in worksheet_nodes(root)
        if worksheet.get("name") and worksheet.get("name") not in dashboards_text
    ]
    duplicate_captions = sorted(
        caption
        for caption, count in Counter(
            row["caption"] for row in definitions.values()
        ).items()
        if count > 1
    )
    components = []
    for name, row in definitions.items():
        kind = (
            "param"
            if row["is_param"]
            else calc_kind(name)
            if row["is_calc"]
            else "source"
        )
        impact = "high" if kind == "lod" else "medium" if kind in {"nested", "tablecalc"} else "low"
        components.append(
            {
                "category": (
                    "Parameter"
                    if row["is_param"]
                    else "Calculated Field"
                    if row["is_calc"]
                    else "Source Field"
                ),
                "name": row["caption"],
                "kind": kind,
                "used": name in used,
                "impact": impact,
            }
        )
    components.sort(
        key=lambda row: (
            {"high": 0, "medium": 1, "low": 2}[row["impact"]],
            row["category"],
            str(row["name"]),
        )
    )
    unused_names = [
        definitions[name]["caption"] for name in definitions if name not in used
    ]
    return {
        "total_fields": len(definitions),
        "source_fields": len(definitions)
        - len(calc_names)
        - sum(bool(row["is_param"]) for row in definitions.values()),
        "calculated_fields": len(calc_names),
        "parameters": sum(bool(row["is_param"]) for row in definitions.values()),
        "used_fields": len(used),
        "unused_fields": len(definitions) - len(used),
        "pct_used": round(100.0 * len(used) / len(definitions), 1)
        if definitions
        else 0,
        "calc_simple": kinds["simple"],
        "calc_nested": kinds["nested"],
        "calc_lod": kinds["lod"],
        "calc_tablecalc": kinds["tablecalc"],
        "orphan_worksheets": orphans,
        "duplicate_captions": duplicate_captions,
        "unused_field_names": unused_names,
        "function_census": dict(
            sorted(functions.items(), key=lambda pair: (-pair[1], pair[0]))
        ),
        "unknown_functions": sorted(set(functions) - catalog_names),
        "components": components,
        "calculation_cycles": inventory["calculation_cycles"],
        "orphan_internal_calculation_references": inventory[
            "orphan_internal_calculation_references"
        ],
        "unused_calculations": inventory["unused_calculations"],
        "formula_status_counts": audit.get("counts", {}),
        "formula_coverage_pct": audit.get("coverage_pct", 0.0),
    }


def point_map_gap(content: str) -> list[Feature]:
    latitude = re.search(r"geo_role=['\"]latitude['\"]", content, re.I)
    longitude = re.search(r"geo_role=['\"]longitude['\"]", content, re.I)
    circle = re.search(r"<mark class=['\"](?:Circle|Shape)['\"]", content)
    if not circle or bool(latitude) == bool(longitude):
        return []
    return [
        Feature(
            "Point-map missing lat/long column",
            "manual",
            1,
            "Sigma point maps require both latitude and longitude; add the missing column.",
        )
    ]


def write_json(path: Path, value: Any) -> None:
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )


def default_report_path(input_path: Path) -> Path:
    if input_path.suffix.lower() in {".twb", ".twbx", ".xml"}:
        return input_path.with_name(f"{input_path.stem}-gaps-report.md")
    return Path(str(input_path) + "-gaps-report.md")


def json_report_path(markdown_path: Path) -> Path:
    return markdown_path.with_suffix(".json")


def components_path(markdown_path: Path) -> Path:
    name = markdown_path.name
    if name.endswith("-gaps-report.md"):
        name = name[: -len("-gaps-report.md")]
    else:
        name = markdown_path.stem
    return markdown_path.with_name(f"{name}-components.csv")


def render_markdown(
    workbook_name: str,
    summary: dict[str, Any],
    results: list[Feature],
    fields: dict[str, Any] | None,
) -> str:
    lines = [
        f"# Tableau→Sigma gap report — `{workbook_name}`",
        "",
        "Generated by `scan-workbook-gaps.py`. Run before conversion.",
        "",
        "## Workbook summary",
        "",
    ]
    lines.extend(f"- **{key}:** {value}" for key, value in summary.items())
    lines.append("")
    if fields:
        lines.extend(
            [
                "## Field statistics (migration scope)",
                "",
                f"- **{fields['total_fields']} fields** — {fields['source_fields']} source, "
                f"{fields['calculated_fields']} calculated, {fields['parameters']} parameters",
                f"- **{fields['pct_used']}% used** ({fields['used_fields']} used / "
                f"{fields['unused_fields']} dead)",
                f"- **Converter formula coverage:** {fields['formula_coverage_pct']}%",
                "",
            ]
        )
    headings = (
        ("auto", "✅ Fully auto-translated"),
        ("hint", "⚠️ Translation suggested, agent action required"),
        ("manual", "🛠 Post-publish manual setup required"),
        ("unhandled", "❌ Not yet handled — escalation path"),
    )
    for status, heading in headings:
        rows = [row for row in results if row.status == status]
        lines.extend([f"## {heading} ({len(rows)})", ""])
        if not rows:
            lines.extend(["_None detected._", ""])
            continue
        lines.extend(
            [
                "| Feature | Count | What the skill does |",
                "|---|---|---|",
            ]
        )
        for row in sorted(rows, key=lambda item: -item.count):
            lines.append(f"| {row.name} | {row.count} | {row.blurb} |")
        lines.append("")
    lines.extend(
        [
            "## Suggested next steps",
            "",
            "Resolve every unhandled row before conversion; verify all hint/manual rows.",
            "",
            "_Generated by tableau-to-sigma skill._",
            "",
        ]
    )
    return "\n".join(lines)


def error_audit(message: str, formula_count: int = 0) -> dict[str, Any]:
    return {
        "status": "ERROR",
        "error": message,
        "formulas": [],
        "counts": {status: 0 for status in FORMULA_STATUSES},
        "converted": 0,
        "coverage_pct": 0.0,
        "datasources": [],
        "calculation_cycles": [],
        "orphan_internal_calculation_references": [],
        "unused_calculations": [],
        "expected_formula_count": formula_count,
    }


def scan(input_path: Path, output_path: Path) -> dict[str, Any]:
    content = input_path.read_text(encoding="utf-8", errors="replace")
    results = categorize(content)
    results.extend(point_map_gap(content))
    root: ET.Element | None = None
    parse_error: str | None = None
    try:
        root = ET.fromstring(content)
    except ET.ParseError as exc:
        parse_error = str(exc)
        results.append(
            Feature(
                "Workbook XML could not be parsed",
                "unhandled",
                1,
                f"{exc}. Repair or re-export the TWB; structural safety checks did not run.",
            )
        )

    summary: dict[str, Any] = {
        "Workbook": input_path.name,
        "Worksheets": "?",
        "Dashboards": "?",
        "Datasources": "?",
        ".twb size": f"{input_path.stat().st_size / 1024.0:.1f} KB",
    }
    blend_plan = None
    fields = None
    if root is not None:
        summary.update(
            {
                "Worksheets": len(worksheet_nodes(root)),
                "Dashboards": len(dashboard_nodes(root)),
                "Datasources": len(real_datasources(root)),
            }
        )
        blend_features, blend_plan = detect_blends(root)
        results.extend(blend_features)
        results.extend(detect_unions(root))
        inventory = calculation_inventory(root, content)
        try:
            formula_audit = run_formula_audit(inventory)
            results.extend(formula_gap_results(formula_audit))
        except (OSError, ValueError, KeyError, RuntimeError, json.JSONDecodeError) as exc:
            message = str(exc)
            formula_audit = error_audit(message, len(inventory["inputs"]))
            results.append(
                Feature(
                    "Converter-backed formula audit unavailable",
                    "unhandled",
                    max(len(inventory["inputs"]), 1),
                    f"{message}. Restore Node/the vendored converter and re-run; "
                    "token-only detection cannot authorize conversion.",
                )
            )
            print(f"  formula audit FAILED CLOSED: {message}", file=sys.stderr)
        try:
            fields = field_statistics(root, content, formula_audit, inventory)
        except (ValueError, KeyError, TypeError, OSError) as exc:
            results.append(
                Feature(
                    "Calculated-field dependency analysis unavailable",
                    "unhandled",
                    1,
                    f"{exc}. Repair the audit path and re-run before conversion.",
                )
            )
            print(f"  field analysis FAILED CLOSED: {exc}", file=sys.stderr)
    else:
        formula_audit = error_audit(
            f"workbook XML parse failed: {parse_error or 'unknown parse error'}"
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        render_markdown(input_path.name, summary, results, fields), encoding="utf-8"
    )
    payload: dict[str, Any] = {
        "workbook": summary,
        "detected_features": [row.as_dict() for row in results],
        "formula_audit": formula_audit,
    }
    if fields:
        payload["field_statistics"] = {
            key: value for key, value in fields.items() if key != "components"
        }
    json_path = json_report_path(output_path)
    write_json(json_path, payload)

    # Fixed basename is consumed by build-source-object-census and the final
    # completion gate. Keep the exact same audit embedded in gaps JSON too.
    formula_path = output_path.parent / "formula-audit.json"
    write_json(formula_path, formula_audit)
    if blend_plan:
        blend_plan["workbook"] = input_path.name
        blend_path = output_path.parent / "blend-plan.json"
        write_json(blend_path, blend_plan)
        print(
            f"wrote {blend_path} ({len(blend_plan['blends'])} blend(s))",
            file=sys.stderr,
        )
    if fields and fields.get("components"):
        csv_path = components_path(output_path)
        with csv_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(["Category", "Name", "Kind", "Used", "Impact"])
            for row in fields["components"]:
                writer.writerow(
                    [
                        row["category"],
                        row["name"],
                        row["kind"],
                        "used" if row["used"] else "DEAD",
                        row["impact"],
                    ]
                )
        print(f"wrote {csv_path}", file=sys.stderr)
    print(f"wrote {output_path}", file=sys.stderr)
    print(f"wrote {json_path}", file=sys.stderr)
    print(f"wrote {formula_path}", file=sys.stderr)
    grouped = Counter(row.status for row in results)
    print(
        "Summary: " + ", ".join(f"{count} {status}" for status, count in grouped.items()),
        file=sys.stderr,
    )
    return payload


def main(argv: Iterable[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if not arguments or len(arguments) > 2 or arguments[0] in {"-h", "--help"}:
        stream = sys.stdout if arguments and arguments[0] in {"-h", "--help"} else sys.stderr
        print(
            "usage: scan-workbook-gaps.py <workbook.twb> [out.md]",
            file=stream,
        )
        return 0 if stream is sys.stdout else 2
    input_path = Path(arguments[0]).expanduser().resolve()
    if not input_path.is_file():
        print(f"not found: {arguments[0]}", file=sys.stderr)
        return 2
    output_path = (
        Path(arguments[1]).expanduser().resolve()
        if len(arguments) == 2
        else default_report_path(input_path)
    )
    try:
        scan(input_path, output_path)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"scan-workbook-gaps: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
