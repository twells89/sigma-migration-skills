"""Build a Sigma data-model candidate from statically extracted SQL queries."""

from __future__ import annotations

from typing import Any

from .analyzer import slug
from .model import ProjectIR


def build_data_model(
    ir: ProjectIR,
    connection_id: str,
    folder_id: str = "<FOLDER_ID>",
    name: str | None = None,
) -> dict[str, Any]:
    warnings: list[dict[str, Any]] = []
    elements = []
    for index, query in enumerate(ir.queries, start=1):
        element_id = f"query-{index}-{slug(query.function)[:24]}"
        columns = []
        for column_index, column_name in enumerate(query.columns, start=1):
            columns.append(
                {
                    "id": f"{element_id}-col-{column_index}",
                    "name": column_name,
                    "formula": f"[Custom SQL/{column_name}]",
                }
            )
        if not query.columns:
            warnings.append(
                {
                    "code": "query-columns-unresolved",
                    "query": query.function,
                    "message": (
                        "No explicit SQL output columns were inferred. Supply "
                        "schema hints before posting this data model."
                    ),
                }
            )
        if query.dynamic:
            warnings.append(
                {
                    "code": "dynamic-sql",
                    "query": query.function,
                    "message": "Runtime SQL interpolation requires manual review.",
                }
            )
        elements.append(
            {
                "id": element_id,
                "kind": "table",
                "name": query.function.replace("_", " ").title(),
                "source": {
                    "kind": "sql",
                    "connectionId": connection_id,
                    "statement": query.sql,
                },
                "columns": columns,
                "visibleAsSource": True,
            }
        )

    data_model = {
        "name": name or f"{ir.project_name} — Streamlit Source",
        "folderId": folder_id,
        "schemaVersion": 1,
        "pages": [
            {
                "id": "streamlit-sources",
                "name": "Streamlit Sources",
                "elements": elements,
            }
        ],
    }
    return {
        "dataModel": data_model,
        "warnings": warnings,
        "stats": {
            "queries": len(ir.queries),
            "elements": len(elements),
            "columns": sum(len(item["columns"]) for item in elements),
        },
    }
