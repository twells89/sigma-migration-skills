#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SKILL))

from converter import (  # noqa: E402
    chat_element,
    clear_chat_effect,
    code_output_source,
    delete_rows_effect,
    download_element_effect,
    form_field_value,
    insert_rows_effect,
    native_form_element,
    navigate_effect,
    open_url_effect,
    run_python_effect,
    select_tab_effect,
    selected_column_range_value,
    selected_column_value,
    update_rows_effect,
    workbook_agent,
)


class ApiCapabilitiesTest(unittest.TestCase):
    def test_current_run_python_and_output_shapes(self):
        self.assertEqual(
            run_python_effect("python-1"),
            {
                "effect": "run-python-element",
                "codeElementId": "python-1",
            },
        )
        self.assertEqual(
            code_output_source("python-1", "result"),
            {
                "kind": "code-output",
                "elementId": "python-1",
                "output": "result",
            },
        )

    def test_selected_column_values_use_id_fields(self):
        self.assertEqual(
            selected_column_value("revenue"),
            {"type": "column", "columnId": "revenue"},
        )
        self.assertEqual(
            selected_column_range_value(
                min_column_id="minimum",
                max_column_id="maximum",
            ),
            {
                "type": "column-range",
                "minColumnId": "minimum",
                "maxColumnId": "maximum",
            },
        )

    def test_capability_builders_reject_empty_references(self):
        with self.assertRaises(ValueError):
            run_python_effect("")
        with self.assertRaises(ValueError):
            code_output_source("", "result")
        with self.assertRaises(ValueError):
            selected_column_value("")
        with self.assertRaises(ValueError):
            selected_column_range_value()

    def test_browser_download_targets_one_element(self):
        self.assertEqual(
            download_element_effect("exceptions"),
            {
                "effect": "export",
                "channel": "download",
                "source": {
                    "type": "element",
                    "element": "exceptions",
                },
                "format": {"type": "csv"},
            },
        )
        with self.assertRaises(ValueError):
            download_element_effect("")

    def test_native_form_and_writeback_shapes(self):
        field_value = form_field_value("scenario-name")
        form = native_form_element(
            "scenario-form",
            [
                {
                    "fieldId": "scenario-name",
                    "type": "short-text",
                    "label": "Scenario",
                }
            ],
            primary_label="Save",
        )
        self.assertEqual(field_value, {
            "type": "form-field",
            "fieldId": "scenario-name",
        })
        self.assertEqual(form["kind"], "form")
        self.assertEqual(form["footer"]["primary"]["label"], "Save")
        self.assertEqual(
            insert_rows_effect("scenario-input", {"name": field_value}),
            {
                "effect": "insert-rows",
                "tableElementId": "scenario-input",
                "values": {"name": field_value},
            },
        )
        selector = {"type": "formula", "formula": "False"}
        self.assertEqual(
            update_rows_effect(
                "scenario-input",
                selector,
                {"name": field_value},
            )["whichRows"],
            selector,
        )
        self.assertEqual(
            delete_rows_effect("scenario-input", selector),
            {
                "effect": "delete-rows",
                "tableElementId": "scenario-input",
                "whichRows": selector,
            },
        )

    def test_navigation_tab_url_and_chat_shapes(self):
        self.assertEqual(
            navigate_effect(page_id="details"),
            {
                "effect": "navigate",
                "target": {"type": "page", "page": "details"},
            },
        )
        self.assertEqual(
            open_url_effect("https://example.com"),
            {
                "effect": "open-url",
                "url": "https://example.com",
                "openTarget": "_blank",
            },
        )
        self.assertEqual(
            select_tab_effect("tabs", direction="next"),
            {
                "effect": "select-tab",
                "tabbedContainerElementId": "tabs",
                "selectedTab": {
                    "type": "direction",
                    "direction": "next",
                },
            },
        )
        self.assertEqual(
            clear_chat_effect("chat"),
            {
                "effect": "clear-chat-element-messages",
                "chatElementId": "chat",
            },
        )

    def test_workbook_agent_and_chat_shapes(self):
        self.assertEqual(
            chat_element("retail-chat", "retail-agent"),
            {
                "id": "retail-chat",
                "kind": "chat",
                "agentId": "retail-agent",
            },
        )
        agent = workbook_agent(
            "retail-agent",
            "Answer only from governed retail data.",
            ["retail-orders", "policies"],
            name="Retail Agent",
            greeting="Ask about retail operations.",
        )
        self.assertEqual(agent["id"], "retail-agent")
        self.assertEqual(
            agent["dataSources"],
            [
                {"kind": "table", "elementId": "retail-orders"},
                {"kind": "table", "elementId": "policies"},
            ],
        )
        self.assertEqual(
            agent["greeting"],
            {"mode": "static", "message": "Ask about retail operations."},
        )


if __name__ == "__main__":
    unittest.main()
