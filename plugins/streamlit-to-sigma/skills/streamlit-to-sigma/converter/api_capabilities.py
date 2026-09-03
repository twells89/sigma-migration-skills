"""Live-verified workbook API fragments used by capability-gated migrations."""

from __future__ import annotations

from typing import Any, Mapping


LIVE_API_CONTRACT_DATE = "2026-08-26"


def run_python_effect(code_element_id: str) -> dict[str, str]:
    """Build the current run-Python action effect."""
    if not code_element_id:
        raise ValueError("code_element_id is required")
    return {
        "effect": "run-python-element",
        "codeElementId": code_element_id,
    }


def code_output_source(code_element_id: str, output: str) -> dict[str, str]:
    """Reference one named sigma.output() result from a Python element."""
    if not code_element_id:
        raise ValueError("code_element_id is required")
    if not output:
        raise ValueError("output is required")
    return {
        "kind": "code-output",
        "elementId": code_element_id,
        "output": output,
    }


def selected_column_value(column_id: str) -> dict[str, str]:
    """Read a selected-row column in an on-select action."""
    if not column_id:
        raise ValueError("column_id is required")
    return {"type": "column", "columnId": column_id}


def selected_column_range_value(
    *,
    min_column_id: str | None = None,
    max_column_id: str | None = None,
) -> dict[str, Any]:
    """Read selected-row range bounds in an on-select action."""
    if not min_column_id and not max_column_id:
        raise ValueError("at least one range column id is required")
    value: dict[str, Any] = {"type": "column-range"}
    if min_column_id:
        value["minColumnId"] = min_column_id
    if max_column_id:
        value["maxColumnId"] = max_column_id
    return value


def download_element_effect(
    element_id: str,
    *,
    file_format: str = "csv",
) -> dict[str, Any]:
    """Build a browser download action for one workbook element."""
    if not element_id:
        raise ValueError("element_id is required")
    if file_format not in {"csv", "excel", "json", "pdf", "png"}:
        raise ValueError(f"unsupported download format: {file_format}")
    return {
        "effect": "export",
        "channel": "download",
        "source": {"type": "element", "element": element_id},
        "format": {"type": file_format},
    }


def form_field_value(field_id: str) -> dict[str, str]:
    """Read one submitted native-form field in an action."""
    if not field_id:
        raise ValueError("field_id is required")
    return {"type": "form-field", "fieldId": field_id}


def native_form_element(
    form_id: str,
    fields: list[dict[str, Any]],
    *,
    primary_label: str = "Submit",
    secondary_label: str = "Reset",
    actions: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Build a public-spec native form with explicit footer actions."""
    if not form_id:
        raise ValueError("form_id is required")
    if not fields:
        raise ValueError("at least one form field is required")
    element: dict[str, Any] = {
        "id": form_id,
        "kind": "form",
        "fields": fields,
        "footer": {
            "align": "stretch",
            "primary": {"label": primary_label, "visibility": "shown"},
            "secondary": {
                "label": secondary_label,
                "visibility": "shown",
            },
        },
    }
    if actions:
        element["actions"] = actions
    return element


def insert_rows_effect(
    table_element_id: str,
    values: Mapping[str, dict[str, Any]],
) -> dict[str, Any]:
    """Insert one row into a non-linked input table."""
    if not table_element_id:
        raise ValueError("table_element_id is required")
    if not values:
        raise ValueError("values are required")
    return {
        "effect": "insert-rows",
        "tableElementId": table_element_id,
        "values": dict(values),
    }


def update_rows_effect(
    table_element_id: str,
    which_rows: dict[str, Any],
    values: Mapping[str, dict[str, Any]],
) -> dict[str, Any]:
    """Update rows in an input table using a public row selector."""
    if not table_element_id:
        raise ValueError("table_element_id is required")
    if not which_rows:
        raise ValueError("which_rows is required")
    if not values:
        raise ValueError("values are required")
    return {
        "effect": "update-rows",
        "tableElementId": table_element_id,
        "whichRows": which_rows,
        "values": dict(values),
    }


def delete_rows_effect(
    table_element_id: str,
    which_rows: dict[str, Any],
) -> dict[str, Any]:
    """Delete rows from a non-linked input table."""
    if not table_element_id:
        raise ValueError("table_element_id is required")
    if not which_rows:
        raise ValueError("which_rows is required")
    return {
        "effect": "delete-rows",
        "tableElementId": table_element_id,
        "whichRows": which_rows,
    }


def navigate_effect(
    *,
    page_id: str | None = None,
    element_id: str | None = None,
) -> dict[str, Any]:
    """Navigate to one page or element in the current workbook."""
    if bool(page_id) == bool(element_id):
        raise ValueError("provide exactly one of page_id or element_id")
    target = (
        {"type": "page", "page": page_id}
        if page_id
        else {"type": "element", "element": element_id}
    )
    return {"effect": "navigate", "target": target}


def open_url_effect(url: str, *, open_target: str = "_blank") -> dict[str, str]:
    """Open a static or dynamic-text URL."""
    if not url:
        raise ValueError("url is required")
    if open_target not in {"_self", "_blank", "_parent"}:
        raise ValueError(f"unsupported open target: {open_target}")
    return {
        "effect": "open-url",
        "url": url,
        "openTarget": open_target,
    }


def select_tab_effect(
    tabbed_container_element_id: str,
    *,
    index: int | None = None,
    direction: str | None = None,
) -> dict[str, Any]:
    """Select a tab by zero-based index or relative direction."""
    if not tabbed_container_element_id:
        raise ValueError("tabbed_container_element_id is required")
    if (index is None) == (direction is None):
        raise ValueError("provide exactly one of index or direction")
    if index is not None and index < 0:
        raise ValueError("index must be non-negative")
    if direction is not None and direction not in {"next", "previous"}:
        raise ValueError(f"unsupported tab direction: {direction}")
    selected = (
        {"type": "tab", "index": index}
        if index is not None
        else {"type": "direction", "direction": direction}
    )
    return {
        "effect": "select-tab",
        "tabbedContainerElementId": tabbed_container_element_id,
        "selectedTab": selected,
    }


def clear_chat_effect(chat_element_id: str) -> dict[str, str]:
    """Clear one chat element's message history."""
    if not chat_element_id:
        raise ValueError("chat_element_id is required")
    return {
        "effect": "clear-chat-element-messages",
        "chatElementId": chat_element_id,
    }


def workbook_agent(
    agent_id: str,
    instructions: str,
    data_source_element_ids: list[str],
    *,
    name: str | None = None,
    description: str | None = None,
    greeting: str | None = None,
) -> dict[str, Any]:
    """Build a workbook-spec-authored Sigma agent."""
    if not agent_id:
        raise ValueError("agent_id is required")
    if not instructions:
        raise ValueError("instructions are required")
    if not data_source_element_ids:
        raise ValueError("at least one data source element id is required")
    agent: dict[str, Any] = {
        "id": agent_id,
        "instructions": instructions,
        "dataSources": [
            {"kind": "table", "elementId": element_id}
            for element_id in data_source_element_ids
        ],
    }
    if name:
        agent["name"] = name
    if description:
        agent["description"] = description
    if greeting:
        agent["greeting"] = {"mode": "static", "message": greeting}
    return agent


def chat_element(
    element_id: str,
    agent_id: str,
) -> dict[str, str]:
    """Build a chat element linked to a workbook agent."""
    if not element_id:
        raise ValueError("element_id is required")
    if not agent_id:
        raise ValueError("agent_id is required")
    return {"id": element_id, "kind": "chat", "agentId": agent_id}
