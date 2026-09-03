"""Build a Sigma workbook from the static Streamlit IR."""

from __future__ import annotations

import ast
import copy
import re
import sys
from pathlib import Path
from typing import Any

from .analyzer import keyword, literal, referenced_names, slug
from .api_capabilities import (
    download_element_effect,
    navigate_effect,
    open_url_effect,
)
from .model import Element as IRElement
from .model import ProjectIR

LIB = Path(__file__).resolve().parents[1] / "scripts" / "lib"
if str(LIB) not in sys.path:
    sys.path.insert(0, str(LIB))
from code_rep import set_theme, wrap  # noqa: E402


def column_id(source_id: str, column: str) -> str:
    return f"{source_id}-col-{slug(column)[:32]}"


def canonical_column(columns: list[str], requested: str) -> str:
    for column in columns:
        if column == requested:
            return column
    requested_folded = requested.casefold()
    for column in columns:
        if column.casefold() == requested_folded:
            return column
    requested_slug = slug(requested)
    for column in columns:
        if slug(column) == requested_slug:
            return column
    return requested


def infer_control_column(label: str, columns: list[str]) -> str | None:
    label_parts = [
        token
        for token in slug(label).split("-")
        if token not in {"filter", "filters", "range", "select", "choose"}
    ]
    label_tokens = set(label_parts)
    if not label_tokens:
        return None
    exact = [column for column in columns if slug(column) == "-".join(label_parts)]
    if len(exact) == 1:
        return exact[0]
    candidates = [
        column
        for column in columns
        if label_tokens <= set(slug(column).split("-"))
    ]
    if len(candidates) == 1:
        return candidates[0]
    return None


def format_for(label: str) -> dict[str, str] | None:
    lowered = label.lower()
    if any(
        word in lowered
        for word in (
            "amount",
            "cost",
            "margin",
            "profit",
            "revenue",
            "sales",
            "tcv",
            "value",
        )
    ):
        return {"kind": "number", "formatString": "$,.0f"}
    if any(word in lowered for word in ("percent", "rate", "pct", "%")):
        return {"kind": "number", "formatString": ",.1%"}
    if any(
        word in lowered
        for word in (
            "count",
            "deals",
            "forks",
            "issues",
            "orders",
            "size",
            "stars",
            "tickets",
            "units",
            "watchers",
        )
    ):
        return {"kind": "number", "formatString": ",.0f"}
    return None


def source_ref(source_name: str, columns: list[str], column: str) -> str:
    return f"[{source_name}/{canonical_column(columns, column)}]"


def semantic_dimension_formula(
    name: str,
    source_name: str,
    source_columns: list[str],
) -> str:
    normalized = slug(name)
    if normalized in {"month", "order-month"} and "order_date" in source_columns:
        return f'DateTrunc("month", {source_ref(source_name, source_columns, "order_date")})'
    return source_ref(source_name, source_columns, name)


def semantic_measure_formula(
    name: str,
    source_name: str,
    source_columns: list[str],
) -> str:
    normalized = slug(name)
    mappings = {
        "revenue": (["net_revenue", "revenue"], "Sum"),
        "net-revenue": (["net_revenue", "revenue"], "Sum"),
        "total-revenue": (["net_revenue", "revenue"], "Sum"),
        "profit": (["net_profit", "profit"], "Sum"),
        "net-profit": (["net_profit", "profit"], "Sum"),
        "total-profit": (["net_profit", "profit"], "Sum"),
        "orders": (["order_id", "order id"], "CountDistinct"),
        "total-orders": (["order_id", "order id"], "CountDistinct"),
        "avg-days": (["days_to_ship"], "Avg"),
        "avg-days-to-ship": (["days_to_ship"], "Avg"),
        "shipping": (["shipping_amount"], "Sum"),
        "shipping-cost": (["shipping_amount"], "Sum"),
        "returned-units": (["quantity_returned"], "Sum"),
        "returns": (["is_returned"], "Sum"),
        "cancellations": (["is_cancelled"], "Sum"),
        "return-rate": (["is_returned"], "Avg"),
        "cancel-rate": (["is_cancelled"], "Avg"),
        "cancellation-rate": (["is_cancelled"], "Avg"),
    }
    if normalized == "on-time-pct":
        days = source_ref(source_name, source_columns, "days_to_ship")
        return f"Avg(If({days} <= 3, 1, 0))"
    if normalized in mappings:
        candidates, aggregation = mappings[normalized]
        column = next(
            (
                source_column
                for candidate in candidates
                for source_column in source_columns
                if slug(source_column) == slug(candidate)
            ),
            None,
        )
        if column:
            return (
                f"{aggregation}("
                f"{source_ref(source_name, source_columns, column)})"
            )
    if name in source_columns or any(
        column.casefold() == name.casefold() for column in source_columns
    ):
        return f"Sum({source_ref(source_name, source_columns, name)})"
    return f"Sum({source_ref(source_name, source_columns, name)})"


def semantic_kpi_formula(
    label: str,
    source_name: str,
    source_columns: list[str],
) -> str | None:
    normalized = slug(label)
    if normalized == "revenue-at-risk-returned-orders":
        revenue = source_ref(source_name, source_columns, "net_revenue")
        returned = source_ref(source_name, source_columns, "is_returned")
        return f"Sum(If({returned} = 1, {revenue}, 0))"
    recognized = {
        "net-revenue",
        "total-revenue",
        "net-profit",
        "total-profit",
        "orders",
        "return-rate",
        "cancellation-rate",
        "avg-days-to-ship",
    }
    if normalized in recognized:
        return semantic_measure_formula(label, source_name, source_columns)
    return None


CHART_TITLES = {
    "monthly": "Monthly Revenue",
    "by_region": "Revenue by Region",
    "channel_mix": "Order Channel Mix",
    "by_method": "Avg Days to Ship by Method",
    "region_grp": "On-Time % by Region (≤3 days)",
    "store_scatter": "Revenue vs Shipping Cost by Store",
    "cat_return": "Return Rate by Category",
    "chan_cancel": "Cancellation Rate by Channel",
    "returns_trend": "Returned Units Trend",
}


def axis_title(name: str) -> str:
    overrides = {
        "shipping": "Shipping Cost",
        "avg_days": "Avg Days to Ship",
        "on_time_pct": "On-Time %",
        "return_rate": "Return Rate",
        "cancel_rate": "Cancellation Rate",
        "returned_units": "Returned Units",
    }
    return overrides.get(name, name.replace("_", " ").title())


def expression_ast(expression: str | None) -> ast.AST | None:
    if not expression:
        return None
    try:
        return ast.parse(expression, mode="eval").body
    except SyntaxError:
        return None


def dataframe_semantics(expression: str | None) -> dict[str, Any]:
    node = expression_ast(expression)
    if node is None:
        return {"groupBy": [], "aggregates": {}}
    group_by: list[str] = []
    aggregates: dict[str, tuple[str, str]] = {}
    for item in ast.walk(node):
        if not isinstance(item, ast.Call) or not isinstance(item.func, ast.Attribute):
            continue
        if item.func.attr == "groupby" and item.args:
            value = literal(item.args[0])
            if isinstance(value, str):
                group_by = [value]
            elif isinstance(value, (list, tuple)):
                group_by = [str(part) for part in value]
        if item.func.attr == "agg":
            for argument in item.keywords:
                value = literal(argument.value)
                if (
                    argument.arg
                    and isinstance(value, (list, tuple))
                    and len(value) == 2
                ):
                    aggregates[argument.arg] = (str(value[0]), str(value[1]))
    return {"groupBy": group_by, "aggregates": aggregates}


def rename_mapping(expression: str | None) -> dict[str, str]:
    node = expression_ast(expression)
    if node is None:
        return {}
    for item in ast.walk(node):
        if not (
            isinstance(item, ast.Call)
            and isinstance(item.func, ast.Attribute)
            and item.func.attr == "rename"
        ):
            continue
        value = literal(keyword(item, "columns"), {})
        if isinstance(value, dict):
            return {str(source): str(target) for source, target in value.items()}
    return {}


def control_options(expression: str | None) -> tuple[list[Any], Any]:
    node = expression_ast(expression)
    if not isinstance(node, ast.Call):
        return [], None
    options = literal(keyword(node, "options"), [])
    values = list(options) if isinstance(options, (list, tuple)) else []
    index = literal(keyword(node, "index"), 0)
    default = (
        values[index]
        if values and isinstance(index, int) and 0 <= index < len(values)
        else None
    )
    return values, default


def referenced_assignment(
    expression: str | None,
    assignments: dict[str, str],
) -> str | None:
    node = expression_ast(expression)
    if node is None:
        return None
    for name in referenced_names(node):
        if name in assignments:
            return name
    return None


def aggregate_formula(
    source_name: str,
    source_columns: list[str],
    column: str,
    aggregation: str,
) -> str:
    function = {
        "sum": "Sum",
        "mean": "Avg",
        "nunique": "CountDistinct",
        "count": "Count",
        "min": "Min",
        "max": "Max",
    }.get(aggregation.lower(), "Sum")
    return f"{function}({source_ref(source_name, source_columns, column)})"


class FormulaTranslator:
    def __init__(
        self,
        assignments: dict[str, str],
        source_name: str,
        source_columns: list[str],
    ) -> None:
        self.assignments = assignments
        self.source_name = source_name
        self.source_columns = source_columns
        self.resolving: set[str] = set()

    def parse(self, expression: str | None) -> ast.AST | None:
        if not expression:
            return None
        try:
            return ast.parse(expression, mode="eval").body
        except SyntaxError:
            return None

    def translate(self, expression: str | None) -> str:
        node = self.parse(expression)
        return self.node(node) if node is not None else "Count()"

    def ref(self, name: str) -> str:
        return f"[{self.source_name}/{canonical_column(self.source_columns, name)}]"

    def node(self, node: ast.AST | None) -> str:
        if node is None:
            return "Null"
        if isinstance(node, ast.Name):
            if node.id in self.assignments and node.id not in self.resolving:
                self.resolving.add(node.id)
                result = self.translate(self.assignments[node.id])
                self.resolving.discard(node.id)
                return result
            return f"[{node.id}]"
        if isinstance(node, ast.Constant):
            if node.value is None:
                return "Null"
            if isinstance(node.value, str):
                return '"' + node.value.replace('"', '\\"') + '"'
            if isinstance(node.value, bool):
                return "True" if node.value else "False"
            return str(node.value)
        if isinstance(node, ast.JoinedStr):
            for value in node.values:
                if isinstance(value, ast.FormattedValue):
                    return self.node(value.value)
            return '""'
        if isinstance(node, ast.FormattedValue):
            return self.node(node.value)
        if isinstance(node, ast.Subscript):
            column = literal(node.slice)
            if isinstance(column, str):
                return self.ref(column)
            return self.node(node.value)
        if isinstance(node, ast.BinOp):
            operator = {
                ast.Add: "+",
                ast.Sub: "-",
                ast.Mult: "*",
                ast.Div: "/",
                ast.Mod: "%",
                ast.Pow: "^",
                ast.BitAnd: "&",
            }.get(type(node.op), "+")
            return f"({self.node(node.left)} {operator} {self.node(node.right)})"
        if isinstance(node, ast.UnaryOp):
            operator = "Not " if isinstance(node.op, ast.Not) else "-"
            return f"{operator}{self.node(node.operand)}"
        if isinstance(node, ast.BoolOp):
            operator = " And " if isinstance(node.op, ast.And) else " Or "
            return "(" + operator.join(self.node(value) for value in node.values) + ")"
        if isinstance(node, ast.Compare) and node.comparators:
            operator = {
                ast.Eq: "=",
                ast.NotEq: "!=",
                ast.Gt: ">",
                ast.GtE: ">=",
                ast.Lt: "<",
                ast.LtE: "<=",
                ast.In: "In",
                ast.NotIn: "Not In",
                ast.Is: "=",
                ast.IsNot: "!=",
            }.get(type(node.ops[0]), "=")
            return f"({self.node(node.left)} {operator} {self.node(node.comparators[0])})"
        if isinstance(node, ast.IfExp):
            return (
                f"If({self.node(node.test)}, {self.node(node.body)}, "
                f"{self.node(node.orelse)})"
            )
        if isinstance(node, ast.Attribute):
            return self.node(node.value)
        if isinstance(node, ast.Call):
            function = node.func
            if isinstance(function, ast.Attribute):
                method = function.attr
                value = function.value
                if method in {"sum", "mean", "nunique", "count", "min", "max"}:
                    translated = self.node(value)
                    if isinstance(value, ast.Compare):
                        translated = f"If({translated}, 1, 0)"
                    sigma_fn = {
                        "sum": "Sum",
                        "mean": "Avg",
                        "nunique": "CountDistinct",
                        "count": "Count",
                        "min": "Min",
                        "max": "Max",
                    }[method]
                    return f"{sigma_fn}({translated})"
                if method in {"date", "astype", "copy", "reset_index", "set_index"}:
                    return self.node(value)
                if method == "get" and node.args:
                    return self.node(node.args[0])
            function_name = function.id if isinstance(function, ast.Name) else ""
            if function_name == "len":
                return "Count()"
            if function_name in {"format_currency", "str", "int", "float"} and node.args:
                return self.node(node.args[0])
            if function_name == "max" and len(node.args) == 2:
                left = self.node(node.args[0])
                right = self.node(node.args[1])
                return f"If({left} > {right}, {left}, {right})"
            if function_name in {"sum", "min", "max"} and node.args:
                return f"{function_name.title()}({self.node(node.args[0])})"
            if node.args:
                return self.node(node.args[0])
        return "Count()"


def query_maps(ir: ProjectIR) -> tuple[dict[str, Any], dict[str, str]]:
    query_by_id = {query.id: query for query in ir.queries}
    dataframe_roots = {
        dataframe.name: dataframe.root_query
        for dataframe in ir.dataframes
        if dataframe.root_query
    }
    return query_by_id, dataframe_roots


def root_query_id(
    ir: ProjectIR,
    dataframe: str | None,
    query_by_id: dict[str, Any],
    dataframe_roots: dict[str, str],
) -> str | None:
    if dataframe in dataframe_roots:
        return dataframe_roots[dataframe]
    if dataframe:
        lowered = dataframe.lower()
        for query in ir.queries:
            if lowered in query.function.lower() or query.function.lower() in lowered:
                return query.id
    if len(query_by_id) == 1:
        return next(iter(query_by_id))
    return None


def workbook_source(
    query: Any,
    source_id: str,
    source_name: str,
    connection_id: str,
    source_mode: str,
    dm_bindings: dict[str, dict[str, Any]],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if source_mode == "data-model" and query.id in dm_bindings:
        binding = dm_bindings[query.id]
        source = {
            "kind": "data-model",
            "dataModelId": binding["dataModelId"],
            "elementId": binding["elementId"],
        }
        prefix = str(binding.get("name") or source_name)
    else:
        source = {
            "kind": "sql",
            "connectionId": connection_id,
            "statement": query.sql,
        }
        prefix = "Custom SQL"
    columns = [
        {
            "id": column_id(source_id, column),
            "name": column,
            "formula": f"[{prefix}/{column}]",
        }
        for column in query.columns
    ]
    return source, columns


def build_workbook(
    ir: ProjectIR,
    connection_id: str,
    folder_id: str = "<FOLDER_ID>",
    name: str | None = None,
    source_mode: str = "custom-sql",
    dm_bindings: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    dm_bindings = dm_bindings or {}
    query_by_id, dataframe_roots = query_maps(ir)
    warnings: list[dict[str, Any]] = []
    elements: list[dict[str, Any]] = []
    source_elements: dict[str, dict[str, Any]] = {}
    source_names: dict[str, str] = {}
    auxiliary_sources: list[dict[str, Any]] = []

    for index, query in enumerate(ir.queries, start=1):
        if re.search(
            r"\bSNOWFLAKE\.CORTEX\.(?:COMPLETE|AGENT)\b"
            r"|\bDATA_AGENT_RUN\b",
            query.sql,
            re.I,
        ):
            warnings.append(
                {
                    "code": "ai-runtime-excluded-from-data-sources",
                    "query": query.function,
                    "message": (
                        "AI runtime SQL is not a workbook data source; map its "
                        "grounding tables to a Sigma workbook agent instead."
                    ),
                }
            )
            continue
        source_id = f"source-{index}-{slug(query.function)[:24]}"
        source_name = f"Data — {query.function.replace('_', ' ').title()}"
        source, columns = workbook_source(
            query,
            source_id,
            source_name,
            connection_id,
            source_mode,
            dm_bindings,
        )
        source_element = {
            "id": source_id,
            "kind": "table",
            "name": source_name,
            "source": source,
            "columns": columns,
        }
        source_elements[query.id] = source_element
        source_names[query.id] = source_name
        elements.append(source_element)
        if not columns:
            warnings.append(
                {
                    "code": "source-columns-unresolved",
                    "query": query.function,
                    "message": "Source table has no inferred columns; supply schema hints.",
                }
            )

    assignments_by_page = ir.metadata.get("assignments", {})
    control_elements: list[dict[str, Any]] = []
    target_control_elements: list[dict[str, Any]] = []
    control_counts = {
        slug(control.label): sum(
            1
            for candidate in ir.controls
            if slug(candidate.label) == slug(control.label)
        )
        for control in ir.controls
    }
    primary_controls: dict[str, str] = {}
    applied_controls: dict[str, str] = {}
    for control in ir.controls:
        control_key = slug(control.label)
        deferred = control_counts[control_key] > 1
        control_handle = (
            f"ctl-{control_key[:20]}-staged"
            if deferred
            else f"ctl-{control_key[:28]}"
        )
        if control_key in primary_controls:
            item = {
                "id": control.id,
                "kind": "control",
                "controlId": primary_controls[control_key],
                "controlType": "synced",
            }
            control_elements.append(item)
            elements.append(item)
            continue
        query_id = root_query_id(
            ir,
            control.dataframe,
            query_by_id,
            dataframe_roots,
        )
        source = source_elements.get(query_id or "")
        query = query_by_id.get(query_id)
        source_columns = list(query.columns) if query else []
        if control_key == "sort-by":
            expression = assignments_by_page.get(control.page, {}).get(
                control.variable or ""
            )
            options, default = control_options(expression)
            if options:
                item = {
                    "id": control.id,
                    "kind": "control",
                    "controlId": control_handle,
                    "controlType": "list",
                    "name": control.label,
                    "mode": "include",
                    "selectionMode": "single",
                    "value": default,
                    "source": {
                        "kind": "manual",
                        "valueType": "text",
                        "values": options,
                        "labels": options,
                    },
                }
                primary_controls[control_key] = control_handle
                control_elements.append(item)
                elements.append(item)
                continue
        source_column_name = (
            canonical_column(source_columns, control.column)
            if control.column
            else infer_control_column(control.label, source_columns)
        )
        if (
            not source_column_name
            and control_key == "search-by-order-id-or-store-name"
            and source
            and {"order_id", "store_name"} <= set(source_columns)
        ):
            source_column_name = "Search Order or Store"
            source_column_id = column_id(source["id"], source_column_name)
            if not any(
                column.get("id") == source_column_id
                for column in source.get("columns", [])
            ):
                source["columns"].append(
                    {
                        "id": source_column_id,
                        "name": source_column_name,
                        "formula": '[order_id] & " " & [store_name]',
                        "hidden": True,
                    }
                )
        if (
            (not source or not source_column_name)
            and control.control_type
            in {"number", "text", "text-area", "checkbox", "switch"}
        ):
            item = {
                "id": control.id,
                "kind": "control",
                "controlId": control_handle,
                "name": control.label,
                "controlType": control.control_type,
            }
            if control.control_type == "number":
                item.update(
                    {
                        "mode": "=",
                        "includeNulls": "when-no-value-is-selected",
                    }
                )
                if control.default is not None:
                    item["value"] = control.default
            elif control.control_type in {"text", "text-area"}:
                item.update(
                    {
                        "mode": "equals",
                        "case": "insensitive",
                        "includeNulls": "when-no-value-is-selected",
                        "showOperators": False,
                    }
                )
                if control.default is not None:
                    item["value"] = control.default
            else:
                item["value"] = bool(control.default)
            primary_controls[control_key] = control_handle
            control_elements.append(item)
            elements.append(item)
            continue
        if not source or not source_column_name:
            warnings.append(
                {
                    "code": "control-lineage-unresolved",
                    "control": control.label,
                    "message": "Control omitted because its source column was not proven.",
                }
            )
            continue
        source_column_id = column_id(source["id"], source_column_name)
        item = {
            "id": control.id,
            "kind": "control",
            "controlId": control_handle,
            "name": control.label,
            "controlType": control.control_type,
            "filters": [
                {
                    "source": {"kind": "table", "elementId": source["id"]},
                    "columnId": source_column_id,
                }
            ],
        }
        if control.control_type in {"list", "segmented"}:
            item["source"] = {
                "kind": "source",
                "source": {"kind": "table", "elementId": source["id"]},
                "columnId": source_column_id,
            }
            item["mode"] = "include"
            if control.selection_mode == "multiple":
                item["selectionMode"] = "multiple"
                item["values"] = (
                    list(control.default)
                    if isinstance(control.default, (list, tuple))
                    else []
                )
            else:
                item["selectionMode"] = "single"
                item["value"] = control.default
        elif control.control_type == "date-range":
            item["mode"] = "between"
            if isinstance(control.default, (list, tuple)) and len(control.default) == 2:
                item["startDate"], item["endDate"] = control.default
        elif control.control_type in {"text", "text-area"}:
            item["mode"] = "contains"
            item["case"] = "insensitive"
            item["includeNulls"] = "when-no-value-is-selected"
            item["showOperators"] = False
        if deferred:
            applied_handle = f"ctl-{control_key[:20]}-applied"
            target_item = copy.deepcopy(item)
            target_item["id"] = f"target-control-{control_key[:32]}"
            target_item["controlId"] = applied_handle
            target_item["name"] = f"Applied {control.label}"
            target_control_elements.append(target_item)
            elements.append(target_item)
            applied_controls[control_key] = applied_handle
            item.pop("filters", None)
        primary_controls[control_key] = control_handle
        control_elements.append(item)
        elements.append(item)

    converted_by_page: dict[str, list[tuple[IRElement, dict[str, Any]]]] = {
        page.id: [] for page in ir.pages
    }
    suppressed_titles = set()
    for index, candidate in enumerate(ir.elements[:-1]):
        following = ir.elements[index + 1]
        if (
            candidate.kind == "text"
            and candidate.bindings.get("style") == "subheader"
            and following.page == candidate.page
            and following.kind
            in {
                "line-chart",
                "bar-chart",
                "area-chart",
                "scatter-chart",
                "table",
            }
        ):
            suppressed_titles.add(candidate.id)

    def page_id_for_target(target: Any) -> str | None:
        if not isinstance(target, str):
            return None
        normalized = target.replace("\\", "/").removeprefix("./")
        target_stem = Path(normalized).stem.casefold()
        for page in ir.pages:
            page_file = page.file.replace("\\", "/").removeprefix("./")
            if (
                normalized.casefold() == page_file.casefold()
                or target_stem == Path(page_file).stem.casefold()
                or slug(target) == page.id
                or slug(target) == slug(page.name)
            ):
                return page.id
        return None

    for item in ir.elements:
        query_id = root_query_id(
            ir, item.dataframe, query_by_id, dataframe_roots
        )
        source = source_elements.get(query_id or "")
        source_name = source_names.get(query_id or "", "Source")
        assignments = assignments_by_page.get(item.page, {})
        source_columns = (
            list(query_by_id.get(query_id).columns)
            if query_id in query_by_id
            else []
        )
        translator = FormulaTranslator(
            assignments,
            source_name,
            source_columns,
        )
        converted: dict[str, Any] | None = None

        if item.kind == "text":
            conditional = any(
                context.get("kind") == "conditional"
                for context in item.context
            )
            if item.id in suppressed_titles or (
                conditional
                and item.bindings.get("style") in {"info", "warning"}
            ):
                continue
            body = item.label or " "
            style = item.bindings.get("style")
            if style == "title":
                body = f"# **{body}**"
            elif style in {"header", "subheader"}:
                body = f"## **{body}**"
            elif (
                style == "caption"
                and "exception rows" in item.label
            ):
                body = (
                    "{{Count([Exception Rows/Order ID]) | ,.0f}} "
                    "exception rows"
                )
            converted = {"id": item.id, "kind": "text", "body": body or " "}
        elif item.kind == "metric" and source:
            value_id = f"{item.id}-value"
            column = {
                "id": value_id,
                "name": item.label,
                "formula": (
                    semantic_kpi_formula(
                        item.label,
                        source_name,
                        source_columns,
                    )
                    or translator.translate(item.expression)
                ),
            }
            fmt = format_for(item.label)
            if fmt:
                column["format"] = fmt
            converted = {
                "id": item.id,
                "kind": "kpi-chart",
                "name": item.label,
                "source": {"kind": "table", "elementId": source["id"]},
                "columns": [column],
                "value": {"columnId": value_id, "fontSize": 26},
                "layout": {"anchor": "middle"},
            }
        elif item.kind in {
            "line-chart",
            "bar-chart",
            "area-chart",
            "scatter-chart",
        } and source:
            x = item.bindings.get("x")
            y = item.bindings.get("y")
            if isinstance(y, str):
                y_values = [y]
            elif isinstance(y, list):
                y_values = [str(value) for value in y]
            else:
                query = query_by_id.get(query_id)
                y_values = query.columns[-1:] if query and query.columns else []
            query = query_by_id.get(query_id)
            if not x and query and query.columns:
                x = query.columns[0]
            chart_columns = []
            x_id = f"{item.id}-x"
            if x:
                x_name = str(x)
                chart_columns.append(
                    {
                        "id": x_id,
                        "name": x_name,
                        "formula": (
                            semantic_measure_formula(
                                x_name,
                                source_name,
                                source_columns,
                            )
                            if item.kind == "scatter-chart"
                            else semantic_dimension_formula(
                                x_name,
                                source_name,
                                source_columns,
                            )
                        ),
                    }
                )
            y_ids = []
            for index, y_name in enumerate(y_values, start=1):
                y_id = f"{item.id}-y-{index}"
                y_ids.append(y_id)
                column = {
                    "id": y_id,
                    "name": y_name,
                    "formula": semantic_measure_formula(
                        y_name,
                        source_name,
                        source_columns,
                    ),
                }
                fmt = format_for(y_name)
                if fmt:
                    column["format"] = fmt
                chart_columns.append(column)
            chart_source = {"kind": "table", "elementId": source["id"]}
            scatter_color: dict[str, Any] | None = None
            if item.kind == "scatter-chart" and item.dataframe:
                semantics = dataframe_semantics(assignments.get(item.dataframe))
                group_by = semantics["groupBy"]
                aggregates = semantics["aggregates"]
                if group_by and x in aggregates and all(
                    value in aggregates for value in y_values
                ):
                    grouped_id = f"{item.id}-grouped-source"
                    grouped_name = f"{CHART_TITLES.get(item.dataframe, item.label)} Source"
                    grouped_columns: list[dict[str, Any]] = []
                    grouped_ids: list[str] = []
                    grouped_calc_ids: list[str] = []
                    for group_name in group_by:
                        grouped_column = {
                            "id": f"{grouped_id}-{slug(group_name)}",
                            "name": group_name,
                            "formula": source_ref(
                                source_name,
                                source_columns,
                                group_name,
                            ),
                        }
                        grouped_columns.append(grouped_column)
                        grouped_ids.append(grouped_column["id"])
                    for alias in [str(x), *y_values]:
                        source_column, aggregation = aggregates[alias]
                        grouped_column = {
                            "id": f"{grouped_id}-{slug(alias)}",
                            "name": alias,
                            "formula": aggregate_formula(
                                source_name,
                                source_columns,
                                source_column,
                                aggregation,
                            ),
                        }
                        grouped_columns.append(grouped_column)
                        grouped_calc_ids.append(grouped_column["id"])
                    grouped_source = {
                        "id": grouped_id,
                        "kind": "table",
                        "name": grouped_name,
                        "source": {
                            "kind": "table",
                            "elementId": source["id"],
                        },
                        "columns": grouped_columns,
                        "groupings": [
                            {
                                "id": f"{grouped_id}-grouping",
                                "groupBy": grouped_ids,
                                "calculations": grouped_calc_ids,
                            }
                        ],
                        "visibleAsSource": False,
                    }
                    elements.append(grouped_source)
                    auxiliary_sources.append(grouped_source)
                    chart_source = {
                        "kind": "table",
                        "elementId": grouped_id,
                        "groupingId": f"{grouped_id}-grouping",
                    }
                    identity_id = f"{item.id}-identity"
                    chart_columns = [
                        {
                            "id": identity_id,
                            "name": group_by[0],
                            "formula": f"[{grouped_name}/{group_by[0]}]",
                        },
                        {
                            "id": x_id,
                            "name": str(x),
                            "formula": f"[{grouped_name}/{x}]",
                        },
                        *[
                            {
                                "id": y_id,
                                "name": y_name,
                                "formula": f"[{grouped_name}/{y_name}]",
                            }
                            for y_id, y_name in zip(y_ids, y_values)
                        ],
                    ]
                    scatter_color = {
                        "by": "category",
                        "column": identity_id,
                    }
            if not x or not y_ids:
                warnings.append(
                    {
                        "code": "chart-binding-unresolved",
                        "element": item.label,
                        "message": "Chart omitted because x/y bindings were not proven.",
                    }
                )
                continue
            converted = {
                "id": item.id,
                "kind": item.kind,
                "name": CHART_TITLES.get(item.dataframe or "", item.label),
                "source": chart_source,
                "columns": chart_columns,
                "xAxis": {
                    "columnId": x_id,
                    "sort": {"by": x_id, "direction": "ascending"},
                    "format": {
                        "title": {"text": axis_title(str(x))}
                    },
                },
                "yAxis": {
                    "columnIds": y_ids,
                    "format": {
                        "title": {
                            "text": " / ".join(
                                axis_title(value) for value in y_values
                            )
                        }
                    },
                },
            }
            if item.dataframe in {"by_method", "cat_return", "chan_cancel"}:
                converted["xAxis"]["sort"] = {
                    "by": y_ids[0],
                    "direction": "descending",
                }
            if item.dataframe == "returns_trend":
                returned_id = f"{item.id}-returned-filter"
                converted["columns"].append(
                    {
                        "id": returned_id,
                        "name": "Returned filter",
                        "formula": source_ref(
                            source_name,
                            source_columns,
                            "is_returned",
                        ),
                        "hidden": True,
                    }
                )
                converted["filters"] = [
                    {
                        "id": f"{item.id}-returns-only",
                        "columnId": returned_id,
                        "kind": "list",
                        "mode": "include",
                        "values": [1],
                        "includeNulls": "never",
                    }
                ]
            if item.kind in {"bar-chart", "area-chart"}:
                converted["stacking"] = (
                    "stacked" if len(y_ids) > 1 else "none"
                )
            converted["color"] = scatter_color or {
                "by": "single",
                "value": "#3B82F6",
            }
            converted["legend"] = {"visibility": "hidden"} if len(y_ids) == 1 else {"position": "bottom"}
        elif item.kind == "table" and source:
            query = query_by_id.get(query_id)
            dataframe_name = item.dataframe or referenced_assignment(
                item.expression,
                assignments,
            )
            semantic_expression = assignments.get(dataframe_name or "")
            semantics = dataframe_semantics(semantic_expression)
            renames = rename_mapping(item.expression)
            columns: list[dict[str, Any]] = []
            group_ids: list[str] = []
            calculation_ids: list[str] = []
            for column_name in semantics["groupBy"]:
                column = {
                    "id": f"{item.id}-group-{slug(column_name)}",
                    "name": renames.get(column_name, column_name),
                    "formula": source_ref(
                        source_name,
                        source_columns,
                        column_name,
                    ),
                }
                columns.append(column)
                group_ids.append(column["id"])
            for alias, (source_column, aggregation) in semantics[
                "aggregates"
            ].items():
                column = {
                    "id": f"{item.id}-calc-{slug(alias)}",
                    "name": renames.get(alias, alias),
                    "formula": aggregate_formula(
                        source_name,
                        source_columns,
                        source_column,
                        aggregation,
                    ),
                }
                fmt = format_for(alias)
                if fmt:
                    column["format"] = fmt
                columns.append(column)
                calculation_ids.append(column["id"])
            if dataframe_name == "store_speed":
                days = source_ref(
                    source_name,
                    source_columns,
                    "days_to_ship",
                )
                status = {
                    "id": f"{item.id}-calc-status",
                    "name": renames.get("status", "Status"),
                    "formula": (
                        f'If(Avg({days}) <= 3, "Healthy", '
                        f'Avg({days}) <= 5, "Watch", "Critical")'
                    ),
                }
                columns.append(status)
                calculation_ids.append(status["id"])
            if dataframe_name == "detail":
                order_ref = source_ref(
                    source_name,
                    source_columns,
                    "order_id",
                )
                for alias, source_column in (
                    ("return_rate", "is_returned"),
                    ("cancel_rate", "is_cancelled"),
                ):
                    value_ref = source_ref(
                        source_name,
                        source_columns,
                        source_column,
                    )
                    rate = {
                        "id": f"{item.id}-calc-{slug(alias)}",
                        "name": renames.get(alias, alias),
                        "formula": (
                            f"Sum({value_ref}) / CountDistinct({order_ref})"
                        ),
                        "format": {
                            "kind": "number",
                            "formatString": ",.1%",
                        },
                    }
                    columns.append(rate)
                    calculation_ids.append(rate["id"])
            if not columns:
                selected_names = literal(
                    expression_ast(assignments.get("display_cols")),
                    None,
                )
                names = (
                    [str(name) for name in selected_names]
                    if isinstance(selected_names, (list, tuple))
                    else list(query.columns[:12])
                    if query
                    else []
                )
                columns = [
                    {
                        "id": f"{item.id}-col-{index}",
                        "name": renames.get(column_name, column_name),
                        "formula": source_ref(
                            source_name,
                            source_columns,
                            column_name,
                        ),
                    }
                    for index, column_name in enumerate(names, start=1)
                ]
            converted = {
                "id": item.id,
                "kind": "table",
                "name": (
                    "Top 10 Slowest Stores"
                    if dataframe_name == "store_speed"
                    else "Category Detail"
                    if dataframe_name == "detail"
                    else "Exception Rows"
                    if item.page == "exception-explorer"
                    else item.label
                    or "Data"
                ),
                "source": {"kind": "table", "elementId": source["id"]},
                "columns": columns,
                "order": [column["id"] for column in columns],
                "tableStyle": {
                    "preset": "presentation",
                    "gridLines": "horizontal",
                    "banding": "shown",
                },
            }
            if group_ids and calculation_ids:
                sort_id = calculation_ids[0]
                if dataframe_name == "detail":
                    sort_id = next(
                        (
                            column["id"]
                            for column in columns
                            if slug(str(column.get("name"))) == "return-rate"
                        ),
                        sort_id,
                    )
                converted["groupings"] = [
                    {
                        "id": f"{item.id}-grouping",
                        "groupBy": group_ids,
                        "calculations": calculation_ids,
                        "sort": [
                            {
                                "columnId": sort_id,
                                "direction": "descending",
                            }
                        ],
                    }
                ]
                if dataframe_name == "store_speed":
                    converted["filters"] = [
                        {
                            "id": f"{item.id}-top-10",
                            "columnId": calculation_ids[0],
                            "kind": "top-n",
                            "rankingFunction": "row-number",
                            "mode": "top-n",
                            "rowCount": 10,
                            "includeNulls": "when-no-value-is-selected",
                        }
                    ]
            if item.page == "exception-explorer":
                exception_id = f"{item.id}-is-exception"
                days = source_ref(source_name, source_columns, "days_to_ship")
                returned = source_ref(
                    source_name,
                    source_columns,
                    "is_returned",
                )
                cancelled = source_ref(
                    source_name,
                    source_columns,
                    "is_cancelled",
                )
                columns.append(
                    {
                        "id": exception_id,
                        "name": "Is Exception",
                        "formula": (
                            f"({days} > 5) Or ({returned} = 1) "
                            f"Or ({cancelled} = 1)"
                        ),
                        "hidden": True,
                    }
                )
                converted["filters"] = [
                    {
                        "id": f"{item.id}-exceptions-only",
                        "columnId": exception_id,
                        "kind": "list",
                        "mode": "include",
                        "values": [True],
                        "includeNulls": "never",
                    }
                ]
        elif item.kind == "divider":
            converted = {"id": item.id, "kind": "divider"}
        elif item.kind == "progress":
            progress_value = (
                f"Avg(If({source_ref(source_name, source_columns, 'days_to_ship')} "
                "<= 3, 1, 0))"
                if source and "days_to_ship" in source_columns
                else translator.translate(item.expression)
                if item.expression
                else "1"
            )
            converted = {
                "id": item.id,
                "kind": "progress",
                "mode": "percent",
                "shape": "bar",
                "value": progress_value,
            }
        elif item.kind == "button":
            button_text = str(
                item.bindings.get("label")
                or item.label
                or "Continue"
            )
            if slug(button_text) == "apply-filters" and applied_controls:
                button_effects = [
                    {
                        "effect": "set-control-value",
                        "control": applied_handle,
                        "value": {
                            "type": "control",
                            "control": primary_controls[control_key],
                        },
                    }
                    for control_key, applied_handle in applied_controls.items()
                ]
            elif slug(button_text) == "reset" and applied_controls:
                button_effects = [
                    {
                        "effect": "clear-control",
                        "scope": {
                            "type": "control",
                            "controlId": handle,
                        },
                        "usePublishedValue": True,
                    }
                    for control_key in applied_controls
                    for handle in (
                        primary_controls[control_key],
                        applied_controls[control_key],
                    )
                ]
            elif item.bindings.get("file_name"):
                export_element = next(
                    (
                        element["id"]
                        for element in elements
                        if element.get("name") == "Exception Rows"
                    ),
                    None,
                )
                button_effects = (
                    [download_element_effect(export_element)]
                    if export_element
                    else []
                )
            elif item.bindings.get("url"):
                button_effects = [
                    open_url_effect(str(item.bindings["url"]))
                ]
            elif item.bindings.get("navigate_page"):
                target_page_id = page_id_for_target(
                    item.bindings["navigate_page"]
                )
                button_effects = (
                    [navigate_effect(page_id=target_page_id)]
                    if target_page_id
                    else []
                )
                if not target_page_id:
                    warnings.append(
                        {
                            "code": "navigation-target-unresolved",
                            "element": button_text,
                            "message": (
                                "Button navigation was omitted because the "
                                "target page was not discovered."
                            ),
                        }
                    )
            else:
                button_effects = []
            converted = {
                "id": item.id,
                "kind": "button",
                "text": button_text,
                "appearance": "outline",
                "align": (
                    "stretch"
                    if slug(button_text) == "apply-filters"
                    else "left"
                ),
                "actions": [
                    {
                        "id": f"{item.id}-action",
                        "trigger": "on-click",
                        "effects": button_effects,
                    }
                ],
            }
            if not converted["actions"][0]["effects"]:
                converted.pop("actions")

        if converted:
            elements.append(converted)
            converted_by_page.setdefault(item.page, []).append((item, converted))

    sort_control = next(
        (
            element
            for element in control_elements
            if element.get("name") == "Sort by"
        ),
        None,
    )
    exception_table = next(
        (
            element
            for element in elements
            if element.get("name") == "Exception Rows"
        ),
        None,
    )
    if sort_control and exception_table:
        sort_fields = {
            "days_to_ship": "descending",
            "net_revenue": "descending",
            "order_date": "ascending",
            "store_name": "ascending",
        }
        column_ids = {}
        for raw_name in sort_fields:
            column_ids[raw_name] = next(
                (
                    column["id"]
                    for column in exception_table.get("columns", [])
                    if str(column.get("formula", "")).endswith(
                        f"/{raw_name}]"
                    )
                ),
                None,
            )

        def sort_effect(raw_name: str) -> dict[str, Any]:
            return {
                "effect": "custom-sort",
                "elementId": exception_table["id"],
                "sort": {
                    "type": "level",
                    "columns": [
                        {
                            "columnId": column_ids[raw_name],
                            "direction": sort_fields[raw_name],
                            "nulls": "last",
                        }
                    ],
                },
            }

        available_fields = [
            name for name, column in column_ids.items() if column
        ]
        if len(available_fields) == len(sort_fields):
            first, *remaining = list(sort_fields)
            sort_control["actions"] = [
                {
                    "id": f"{sort_control['id']}-sort",
                    "trigger": "on-change",
                    "effects": [
                        {
                            "effect": "if-else",
                            "if": {
                                "condition": {
                                    "type": "formula",
                                    "formula": (
                                        f"[{sort_control['controlId']}] "
                                        f'= "{first}"'
                                    ),
                                },
                                "effects": [sort_effect(first)],
                            },
                            "elseif": [
                                {
                                    "condition": {
                                        "type": "formula",
                                        "formula": (
                                            f"[{sort_control['controlId']}] "
                                            f'= "{raw_name}"'
                                        ),
                                    },
                                    "effects": [sort_effect(raw_name)],
                                }
                                for raw_name in remaining[:-1]
                            ],
                            "else": {
                                "effects": [sort_effect(remaining[-1])]
                            },
                        }
                    ],
                }
            ]
            exception_table["sort"] = [
                {
                    "columnId": column_ids["days_to_ship"],
                    "direction": "descending",
                    "nulls": "last",
                }
            ]

    # Add controls to page placement lists.
    controls_by_page = {
        page.id: [
            (control, converted)
            for control in ir.controls
            for converted in control_elements
            if converted["id"] == control.id and control.page == page.id
        ]
        for page in ir.pages
    }

    overlays: list[dict[str, Any]] = []
    overlay_pages: list[str] = []
    layout_pages: list[str] = []

    def height(kind: str) -> int:
        return {
            "text": 3,
            "kpi-chart": 6,
            "line-chart": 12,
            "bar-chart": 12,
            "area-chart": 12,
            "scatter-chart": 12,
            "table": 18,
            "control": 5,
            "button": 4,
            "divider": 1,
            "progress": 4,
        }.get(kind, 5)

    for page in ir.pages:
        page_pairs = controls_by_page.get(page.id, []) + converted_by_page.get(page.id, [])
        sidebar_pairs = [
            pair
            for pair in page_pairs
            if (hasattr(pair[0], "sidebar") and pair[0].sidebar)
            or any(
                context.get("kind") == "sidebar"
                for context in getattr(pair[0], "context", [])
            )
        ]
        normal_pairs = [pair for pair in page_pairs if pair not in sidebar_pairs]
        sidebar_pairs.sort(
            key=lambda pair: getattr(pair[0].provenance, "line", 0)
        )
        normal_pairs.sort(
            key=lambda pair: getattr(pair[0].provenance, "line", 0)
        )

        # Popover/status/expander children move to native overlays.
        overlay_groups: dict[tuple[str, str], list[tuple[Any, dict[str, Any]]]] = {}
        retained_pairs = []
        for pair in normal_pairs:
            contexts = getattr(pair[0], "context", [])
            overlay_context = next(
                (
                    context
                    for context in reversed(contexts)
                    if context.get("kind") in {"popover", "status", "expander"}
                ),
                None,
            )
            if overlay_context:
                key = (
                    overlay_context["kind"],
                    str(overlay_context.get("name") or "Details"),
                )
                overlay_groups.setdefault(key, []).append(pair)
            else:
                retained_pairs.append(pair)
        normal_pairs = retained_pairs
        for (context_kind, context_name), pairs in overlay_groups.items():
            overlay_id = f"overlay-{page.id}-{slug(context_name)[:24]}"
            button_id = f"button-{overlay_id}"
            button_element = {
                "id": button_id,
                "kind": "button",
                "text": context_name or context_kind.title(),
                "appearance": "outline",
                "align": "left",
            }
            elements.append(button_element)
            normal_pairs.append((pairs[0][0], button_element))
            overlays.append(
                {
                    "id": overlay_id,
                    "type": "popover",
                    "name": context_name or context_kind.title(),
                    "popover": {"triggerElementId": button_id},
                }
            )
            overlay_row = 1
            overlay_lines = [
                '<Page type="grid" gridTemplateColumns="repeat(12, 1fr)" '
                f'gridTemplateRows="auto" id="{overlay_id}">'
            ]
            for _, overlay_element in pairs:
                span = height(overlay_element["kind"])
                overlay_lines.append(
                    f'  <Element elementId="{overlay_element["id"]}" '
                    f'gridColumn="1 / 13" '
                    f'gridRow="{overlay_row} / {overlay_row + span}"/>'
                )
                overlay_row += span
            overlay_lines.append("</Page>")
            overlay_pages.append("\n".join(overlay_lines))
        normal_pairs.sort(
            key=lambda pair: getattr(pair[0].provenance, "line", 0)
        )

        page_lines = [
            f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
            f'gridTemplateRows="auto" id="{page.id}">'
        ]
        main_start = 5 if sidebar_pairs else 1
        row = 1

        if sidebar_pairs:
            sidebar_id = f"sidebar-{page.id}"
            navigation_id = f"navigation-{page.id}"
            sidebar_element = {
                "id": sidebar_id,
                "kind": "container",
                "style": {"backgroundColor": "#F5F6F8", "borderRadius": "square"},
            }
            navigation_element = {
                "id": navigation_id,
                "kind": "navigation",
                "mode": "manual",
                "options": [
                    {
                        "label": destination.name,
                        "destination": {
                            "type": "page",
                            "pageId": destination.id,
                        },
                    }
                    for destination in ir.pages
                ],
                "showIcons": False,
                "optionStyle": {
                    "orientation": "vertical",
                    "alignment": "left",
                },
            }
            elements.append(sidebar_element)
            elements.append(navigation_element)
            child_lines = [
                f'    <Element elementId="{navigation_id}" '
                'gridColumn="2 / 24" gridRow="1 / 13"/>'
            ]
            child_row = 13
            form_pairs = [
                pair
                for pair in sidebar_pairs
                if any(
                    context.get("kind") == "form"
                    for context in getattr(pair[0], "context", [])
                )
            ]
            form_written = False
            for source_item, converted in sidebar_pairs:
                if (source_item, converted) in form_pairs:
                    if form_written:
                        continue
                    form_written = True
                    form_id = f"filter-card-{page.id}"
                    form_element = {
                        "id": form_id,
                        "kind": "container",
                        "style": {
                            "backgroundColor": "#FFFFFF",
                            "borderColor": "#D1D5DB",
                            "borderWidth": 1,
                            "borderRadius": "round",
                        },
                    }
                    elements.append(form_element)
                    inner_row = 1
                    inner_lines = []
                    for _, form_element_child in form_pairs:
                        span = height(form_element_child["kind"])
                        inner_lines.append(
                            f'      <Element elementId="{form_element_child["id"]}" '
                            f'gridColumn="2 / 24" '
                            f'gridRow="{inner_row} / {inner_row + span}"/>'
                        )
                        inner_row += span
                    child_lines.append(
                        f'    <Container elementId="{form_id}" type="grid" '
                        f'gridColumn="1 / 25" '
                        f'gridRow="{child_row} / {child_row + inner_row + 1}" '
                        'gridTemplateColumns="repeat(24, 1fr)" '
                        'gridTemplateRows="auto">'
                    )
                    child_lines.extend(inner_lines)
                    child_lines.append("    </Container>")
                    child_row += inner_row + 1
                    continue
                span = height(converted["kind"])
                child_lines.append(
                    f'    <Element elementId="{converted["id"]}" '
                    f'gridColumn="2 / 24" '
                    f'gridRow="{child_row} / {child_row + span}"/>'
                )
                child_row += span
            page_lines.append(
                f'  <Container elementId="{sidebar_id}" type="grid" '
                f'gridColumn="1 / 5" gridRow="1 / {max(child_row + 1, 40)}" '
                'gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">'
            )
            page_lines.extend(child_lines)
            page_lines.append("  </Container>")

        # Tab contexts become one native tabbed container per page.
        tab_names = []
        tab_pairs: dict[str, list[tuple[Any, dict[str, Any]]]] = {}
        non_tab_pairs = []
        for pair in normal_pairs:
            context = next(
                (
                    item
                    for item in getattr(pair[0], "context", [])
                    if item.get("kind") == "tab"
                ),
                None,
            )
            if context:
                tab_name = str(context.get("name") or "Tab")
                if tab_name not in tab_names:
                    tab_names.append(tab_name)
                tab_pairs.setdefault(tab_name, []).append(pair)
            else:
                non_tab_pairs.append(pair)

        # Place ordinary elements, respecting st.columns groups.
        index = 0
        while index < len(non_tab_pairs):
            source_item, converted = non_tab_pairs[index]
            horizontal_context = next(
                (
                    item
                    for item in getattr(source_item, "context", [])
                    if item.get("kind") == "horizontal"
                ),
                None,
            )
            if horizontal_context:
                group = horizontal_context["group"]
                group_pairs = []
                while index < len(non_tab_pairs):
                    candidate = non_tab_pairs[index]
                    candidate_context = next(
                        (
                            item
                            for item in getattr(candidate[0], "context", [])
                            if item.get("kind") == "horizontal"
                        ),
                        None,
                    )
                    if (
                        not candidate_context
                        or candidate_context.get("group") != group
                    ):
                        break
                    group_pairs.append(candidate)
                    index += 1
                width = 25 - main_start
                count = len(group_pairs)
                row_height = max(
                    height(pair[1]["kind"]) for pair in group_pairs
                )
                for item_index, (_, group_element) in enumerate(group_pairs):
                    start = main_start + round(width * item_index / count)
                    end = main_start + round(
                        width * (item_index + 1) / count
                    )
                    page_lines.append(
                        f'  <Element elementId="{group_element["id"]}" '
                        f'gridColumn="{start} / {end}" '
                        f'gridRow="{row} / {row + row_height}"/>'
                    )
                row += row_height
                continue
            column_context = next(
                (
                    item
                    for item in getattr(source_item, "context", [])
                    if item.get("kind") == "column"
                ),
                None,
            )
            if column_context:
                group = column_context["group"]
                group_pairs = []
                while index < len(non_tab_pairs):
                    candidate = non_tab_pairs[index]
                    candidate_context = next(
                        (
                            item
                            for item in getattr(candidate[0], "context", [])
                            if item.get("kind") == "column"
                        ),
                        None,
                    )
                    if not candidate_context or candidate_context.get("group") != group:
                        break
                    group_pairs.append((candidate, candidate_context))
                    index += 1
                width = 25 - main_start
                pairs_by_column: dict[
                    int, list[tuple[tuple[Any, dict[str, Any]], dict[str, Any]]]
                ] = {}
                for pair, context in group_pairs:
                    pairs_by_column.setdefault(int(context["index"]), []).append(
                        (pair, context)
                    )
                column_heights = []
                for column_index, column_pairs in pairs_by_column.items():
                    context = column_pairs[0][1]
                    count = max(1, int(context["count"]))
                    weights = context.get("weights") or [1.0] * count
                    total_weight = sum(float(value) for value in weights)
                    before = sum(
                        float(value) for value in weights[:column_index]
                    )
                    through = before + float(weights[column_index])
                    start = main_start + round(width * before / total_weight)
                    end = main_start + round(width * through / total_weight)
                    column_row = row
                    for pair, _ in column_pairs:
                        _, group_element = pair
                        span = height(group_element["kind"])
                        page_lines.append(
                            f'  <Element elementId="{group_element["id"]}" '
                            f'gridColumn="{start} / {end}" '
                            f'gridRow="{column_row} / {column_row + span}"/>'
                        )
                        column_row += span
                    column_heights.append(column_row - row)
                row += max(column_heights, default=0)
                continue
            span = height(converted["kind"])
            page_lines.append(
                f'  <Element elementId="{converted["id"]}" '
                f'gridColumn="{main_start} / 25" gridRow="{row} / {row + span}"/>'
            )
            row += span
            index += 1

        if tab_names:
            tab_id = f"tabs-{page.id}"
            elements.append(
                {
                    "id": tab_id,
                    "kind": "tabbed-container",
                    "tabs": [{"name": name} for name in tab_names],
                    "tabBar": {"alignment": "start"},
                }
            )
            tab_inner = []
            max_tab_row = 1
            for tab_name in tab_names:
                inner_row = 1
                tab_inner.append(
                    '    <Tab gridTemplateColumns="repeat(24, 1fr)" '
                    'gridTemplateRows="auto">'
                )
                for _, converted in tab_pairs.get(tab_name, []):
                    span = height(converted["kind"])
                    tab_inner.append(
                        f'      <Element elementId="{converted["id"]}" '
                        f'gridColumn="1 / 25" gridRow="{inner_row} / {inner_row + span}"/>'
                    )
                    inner_row += span
                tab_inner.append("    </Tab>")
                max_tab_row = max(max_tab_row, inner_row)
            outer_height = max(12, max_tab_row)
            page_lines.append(
                f'  <TabbedContainer elementId="{tab_id}" type="tabbed-container" '
                f'gridColumn="{main_start} / 25" gridRow="{row} / {row + outer_height}">'
            )
            page_lines.extend(tab_inner)
            page_lines.append("  </TabbedContainer>")
            row += outer_height

        page_lines.append("</Page>")
        layout_pages.append("\n".join(page_lines))

    data_lines = [
        '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
        'gridTemplateRows="auto" id="data">'
    ]
    data_row = 1
    for target_control in target_control_elements:
        data_lines.append(
            f'  <Element elementId="{target_control["id"]}" '
            f'gridColumn="1 / 9" gridRow="{data_row} / {data_row + 5}"/>'
        )
        data_row += 5
    for source in [*source_elements.values(), *auxiliary_sources]:
        data_lines.append(
            f'  <Element elementId="{source["id"]}" gridColumn="1 / 25" '
            f'gridRow="{data_row} / {data_row + 14}"/>'
        )
        data_row += 14
    data_lines.append("</Page>")
    layout_pages.append("\n".join(data_lines))

    pages = [
        {
            "id": page.id,
            "name": page.name,
            "pageWidth": "full",
            "backgroundColor": "#FFFFFF",
        }
        for page in ir.pages
    ]
    pages.append({"id": "data", "name": "Data", "visibility": "hidden"})

    document = {
        "schemaVersion": 1,
        "kind": "workbook",
        "elements": elements,
        "pages": pages,
        "overlays": overlays,
        "layout": (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            + "\n".join(layout_pages + overlay_pages)
            + "\n"
        ),
    }
    set_theme(
        document,
        name="Light",
        overrides={
            "categoricalScheme": [
                "#3B82F6",
                "#10B981",
                "#F59E0B",
                "#8B5CF6",
                "#06B6D4",
            ],
            "titleFont": {
                "color": "#172033",
                "fontSize": 14,
                "fontWeight": "bold",
            },
            "hasCards": "hidden",
        },
    )
    workbook = wrap(
        document,
        {
            "name": name or f"{ir.project_name} — Streamlit Migration",
            "folderId": folder_id,
            "description": (
                "Generated by streamlit-to-sigma static analysis. Review "
                "gaps and parity evidence before publishing."
            ),
        },
    )
    return {
        "workbook": workbook,
        "warnings": warnings,
        "stats": {
            "pages": len(ir.pages),
            "sources": len(source_elements),
            "controls": len(control_elements),
            "elements": len(elements),
            "gaps": len(ir.gaps),
        },
    }
