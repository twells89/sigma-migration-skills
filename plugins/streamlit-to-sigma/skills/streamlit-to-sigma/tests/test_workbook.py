#!/usr/bin/env python3
import re
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SKILL))
sys.path.insert(0, str(SKILL / "scripts" / "lib"))

from converter import analyze_project, build_data_model, build_workbook  # noqa: E402
from converter.workbook import (  # noqa: E402
    dataframe_semantics,
    semantic_dimension_formula,
    semantic_measure_formula,
)
from code_rep import document, workbook_elements  # noqa: E402


class WorkbookTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture = SKILL / "fixtures" / "simple-retail"
        cls.ir = analyze_project(fixture)
        cls.result = build_workbook(
            cls.ir,
            "connection-1",
            "folder-1",
            "Retail Fixture",
        )
        cls.spec = cls.result["workbook"]

    def test_wrapped_workbook_shape(self):
        self.assertEqual(self.spec["name"], "Retail Fixture")
        self.assertEqual(self.spec["folderId"], "folder-1")
        doc = document(self.spec)
        self.assertEqual(doc["kind"], "workbook")
        self.assertEqual(doc["schemaVersion"], 1)
        self.assertNotIn("elements", doc["pages"][0])
        self.assertTrue(any(page.get("visibility") == "hidden" for page in doc["pages"]))

    def test_layout_is_authoritative_and_complete(self):
        doc = document(self.spec)
        ids = [item["id"] for item in workbook_elements(self.spec)]
        placed = re.findall(r'\belementId="([^"]+)"', doc["layout"])
        self.assertEqual(sorted(ids), sorted(placed))
        self.assertEqual(len(placed), len(set(placed)))
        self.assertNotIn("LayoutElement", doc["layout"])
        self.assertNotIn("GridContainer", doc["layout"])

    def test_source_control_and_kpi_formulas(self):
        elements = {item["id"]: item for item in workbook_elements(self.spec)}
        source = next(item for item in elements.values() if item["name"].startswith("Data —"))
        self.assertEqual(source["source"]["kind"], "sql")
        self.assertEqual(source["source"]["connectionId"], "connection-1")
        self.assertEqual(len(source["columns"]), 6)

        control = next(item for item in elements.values() if item["kind"] == "control")
        self.assertEqual(control["controlType"], "list")
        self.assertEqual(control["selectionMode"], "multiple")
        self.assertEqual(control["filters"][0]["columnId"], f"{source['id']}-col-region")

        kpis = [item for item in elements.values() if item["kind"] == "kpi-chart"]
        formulas = [item["columns"][0]["formula"] for item in kpis]
        self.assertIn(f"Sum([{source['name']}/Revenue])", formulas)
        self.assertIn(f"Sum([{source['name']}/Profit])", formulas)
        self.assertIn(f"CountDistinct([{source['name']}/Order Id])", formulas)

    def test_common_pandas_semantics_lower_to_sigma_formulas(self):
        expression = (
            "df.groupby('region', as_index=False)"
            ".agg(revenue=('net_revenue', 'sum'), orders=('order_id', 'nunique'))"
        )
        self.assertEqual(
            dataframe_semantics(expression),
            {
                "groupBy": ["region"],
                "aggregates": {
                    "revenue": ("net_revenue", "sum"),
                    "orders": ("order_id", "nunique"),
                },
            },
        )
        columns = ["order_date", "net_revenue", "order_id", "days_to_ship"]
        self.assertEqual(
            semantic_dimension_formula("month", "Orders", columns),
            'DateTrunc("month", [Orders/order_date])',
        )
        self.assertEqual(
            semantic_measure_formula("revenue", "Orders", columns),
            "Sum([Orders/net_revenue])",
        )
        self.assertEqual(
            semantic_measure_formula("on_time_pct", "Orders", columns),
            "Avg(If([Orders/days_to_ship] <= 3, 1, 0))",
        )

    def test_data_model_candidate(self):
        result = build_data_model(self.ir, "connection-1", "folder-1")
        model = result["dataModel"]
        self.assertEqual(model["schemaVersion"], 1)
        element = model["pages"][0]["elements"][0]
        self.assertEqual(element["source"]["kind"], "sql")
        self.assertEqual(len(element["columns"]), 6)

    def test_raw_snake_case_column_references_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "streamlit_app.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    conn = st.connection("snowflake")
                    def load_data():
                        return conn.query(
                            "SELECT order_date, net_revenue FROM db.s.orders"
                        )
                    df = load_data()
                    revenue = df["net_revenue"].sum()
                    st.metric("Revenue", revenue)
                    st.line_chart(df, x="order_date", y="net_revenue")
                    """
                ),
                encoding="utf-8",
            )
            ir = analyze_project(root)
            result = build_workbook(ir, "connection-1", "folder-1")
            elements = workbook_elements(result["workbook"])
            formulas = [
                column["formula"]
                for item in elements
                for column in item.get("columns", [])
            ]
            source_name = next(
                item["name"] for item in elements if item["kind"] == "table"
            )
            self.assertIn(f"[{source_name}/order_date]", formulas)
            self.assertIn(f"Sum([{source_name}/net_revenue])", formulas)
            chart = next(
                item for item in elements if item["kind"] == "line-chart"
            )
            self.assertEqual(
                chart["xAxis"]["format"]["title"]["text"],
                "Order Date",
            )
            self.assertEqual(
                chart["yAxis"]["format"]["title"]["text"],
                "Net Revenue",
            )

    def test_multiple_elements_in_one_streamlit_column_stack(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "streamlit_app.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    conn = st.connection("snowflake")
                    def load_data():
                        return conn.query(
                            "SELECT region, revenue FROM db.s.orders"
                        )
                    df = load_data()
                    left, right = st.columns([2, 1])
                    with left:
                        st.caption("Left note")
                        st.bar_chart(df, x="region", y="revenue")
                    with right:
                        st.caption("Right note")
                        st.bar_chart(df, x="region", y="revenue")
                    """
                ),
                encoding="utf-8",
            )
            ir = analyze_project(root)
            result = build_workbook(ir, "connection-1", "folder-1")
            layout = document(result["workbook"])["layout"]
            left_text = next(
                item.id for item in ir.elements if item.label == "Left note"
            )
            left_chart = next(
                item.id
                for item in ir.elements
                if item.kind == "bar-chart"
                and any(
                    context.get("kind") == "column"
                    and context.get("index") == 0
                    for context in item.context
                )
            )

            def row_range(element_id):
                match = re.search(
                    rf'elementId="{re.escape(element_id)}"[^>]+gridRow="(\d+) / (\d+)"',
                    layout,
                )
                self.assertIsNotNone(match)
                return int(match.group(1)), int(match.group(2))

            _, title_end = row_range(left_text)
            chart_start, _ = row_range(left_chart)
            self.assertLessEqual(title_end, chart_start)
            left_placement = re.search(
                rf'elementId="{re.escape(left_chart)}"[^>]+'
                rf'gridColumn="(\d+) / (\d+)"',
                layout,
            )
            right_chart = next(
                item.id
                for item in ir.elements
                if item.kind == "bar-chart"
                and any(
                    context.get("kind") == "column"
                    and context.get("index") == 1
                    for context in item.context
                )
            )
            right_placement = re.search(
                rf'elementId="{re.escape(right_chart)}"[^>]+'
                rf'gridColumn="(\d+) / (\d+)"',
                layout,
            )
            self.assertIsNotNone(left_placement)
            self.assertIsNotNone(right_placement)
            left_width = int(left_placement.group(2)) - int(
                left_placement.group(1)
            )
            right_width = int(right_placement.group(2)) - int(
                right_placement.group(1)
            )
            self.assertGreater(left_width, right_width)

    def test_horizontal_kpis_and_conditional_empty_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "streamlit_app.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    conn = st.connection("snowflake")
                    def load_data():
                        return conn.query(
                            "SELECT order_id, revenue, profit FROM db.s.orders"
                        )
                    df = load_data()
                    if df.empty:
                        st.info("No data matches the current filters.")
                    with st.container(horizontal=True):
                        st.metric("Revenue", df["revenue"].sum())
                        st.metric("Profit", df["profit"].sum())
                    """
                ),
                encoding="utf-8",
            )
            ir = analyze_project(root)
            result = build_workbook(ir, "connection-1", "folder-1")
            doc = document(result["workbook"])
            text_bodies = [
                item["body"]
                for item in workbook_elements(result["workbook"])
                if item["kind"] == "text"
            ]
            self.assertNotIn(
                "No data matches the current filters.",
                text_bodies,
            )
            kpi_ids = [
                item["id"]
                for item in workbook_elements(result["workbook"])
                if item["kind"] == "kpi-chart"
            ]
            placements = [
                re.search(
                    rf'elementId="{re.escape(kpi_id)}"[^>]+'
                    rf'gridColumn="([^"]+)" gridRow="([^"]+)"',
                    doc["layout"],
                )
                for kpi_id in kpi_ids
            ]
            self.assertTrue(all(placements))
            self.assertEqual(
                len({placement.group(2) for placement in placements}),
                1,
            )
            self.assertEqual(
                len({placement.group(1) for placement in placements}),
                2,
            )

    def test_deferred_shared_filter_uses_hidden_target_control(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "app_pages").mkdir()
            (root / "lib").mkdir()
            (root / "streamlit_app.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    from lib.filters import render_filters
                    render_filters(df)
                    page = st.navigation([
                        st.Page("app_pages/one.py", title="One"),
                        st.Page("app_pages/two.py", title="Two"),
                    ])
                    page.run()
                    """
                ),
                encoding="utf-8",
            )
            for page in ("one", "two"):
                (root / "app_pages" / f"{page}.py").write_text(
                    "import streamlit as st\nst.title('Page')\n",
                    encoding="utf-8",
                )
            (root / "lib" / "data.py").write_text(
                textwrap.dedent(
                    """
                    def load_data(conn):
                        return conn.query(
                            "SELECT region, revenue FROM db.s.orders"
                        )
                    """
                ),
                encoding="utf-8",
            )
            (root / "lib" / "filters.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    def render_filters(df):
                        regions = sorted(df["region"].unique().tolist())
                        with st.sidebar:
                            with st.form("filters"):
                                st.multiselect("Region", options=regions)
                                st.form_submit_button("Apply Filters")
                            if st.sidebar.button("Reset"):
                                st.rerun()
                    """
                ),
                encoding="utf-8",
            )
            ir = analyze_project(root)
            result = build_workbook(ir, "connection-1", "folder-1")
            elements = workbook_elements(result["workbook"])
            controls = [item for item in elements if item["kind"] == "control"]
            target = next(
                item
                for item in controls
                if item["controlId"] == "ctl-region-applied"
            )
            staging = next(
                item
                for item in controls
                if item["controlId"] == "ctl-region-staged"
                and item["controlType"] == "list"
            )
            synced = next(
                item for item in controls if item["controlType"] == "synced"
            )
            self.assertIn("filters", target)
            self.assertNotIn("filters", staging)
            self.assertEqual(synced["controlId"], staging["controlId"])
            apply_button = next(
                item
                for item in elements
                if item.get("text") == "Apply Filters"
            )
            self.assertEqual(
                apply_button["actions"][0]["effects"][0],
                {
                    "effect": "set-control-value",
                    "control": "ctl-region-applied",
                    "value": {
                        "type": "control",
                        "control": "ctl-region-staged",
                    },
                },
            )
            reset_button = next(
                item for item in elements if item.get("text") == "Reset"
            )
            scopes = [
                effect["scope"]
                for effect in reset_button["actions"][0]["effects"]
            ]
            self.assertIn(
                {"type": "control", "controlId": "ctl-region-staged"},
                scopes,
            )
            self.assertIn(
                {"type": "control", "controlId": "ctl-region-applied"},
                scopes,
            )
            navigation = [
                item for item in elements if item["kind"] == "navigation"
            ]
            self.assertEqual(len(navigation), 2)
            self.assertEqual(
                navigation[0]["optionStyle"]["orientation"],
                "vertical",
            )
            self.assertEqual(
                [option["label"] for option in navigation[0]["options"]],
                ["One", "Two"],
            )
            filter_cards = [
                item
                for item in elements
                if item["kind"] == "container"
                and item["id"].startswith("filter-card-")
            ]
            self.assertEqual(len(filter_cards), 2)
            self.assertRegex(
                document(result["workbook"])["layout"],
                rf'<Page[^>]+id="data">[\s\S]*elementId="{target["id"]}"',
            )

    def test_link_and_switch_page_buttons_use_public_actions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pages").mkdir()
            (root / "streamlit_app.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    page = st.navigation([
                        st.Page("pages/overview.py", title="Overview"),
                        st.Page("pages/detail.py", title="Detail"),
                    ])
                    page.run()
                    """
                ),
                encoding="utf-8",
            )
            (root / "pages" / "overview.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    st.link_button("Documentation", "https://example.com/docs")
                    if st.button("Open detail"):
                        st.switch_page("pages/detail.py")
                    """
                ),
                encoding="utf-8",
            )
            (root / "pages" / "detail.py").write_text(
                "import streamlit as st\nst.title('Detail')\n",
                encoding="utf-8",
            )
            result = build_workbook(
                analyze_project(root),
                "connection-1",
                "folder-1",
            )
            buttons = {
                item["text"]: item
                for item in workbook_elements(result["workbook"])
                if item["kind"] == "button"
            }
            self.assertEqual(
                buttons["Documentation"]["actions"][0]["effects"],
                [
                    {
                        "effect": "open-url",
                        "url": "https://example.com/docs",
                        "openTarget": "_blank",
                    }
                ],
            )
            self.assertEqual(
                buttons["Open detail"]["actions"][0]["effects"],
                [
                    {
                        "effect": "navigate",
                        "target": {"type": "page", "page": "detail"},
                    }
                ],
            )

    def test_standalone_form_controls_do_not_require_column_lineage(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "streamlit_app.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    name = st.text_input("Scenario name")
                    adjustment = st.number_input("Adjustment", value=2)
                    approved = st.checkbox("Approved")
                    """
                ),
                encoding="utf-8",
            )
            result = build_workbook(
                analyze_project(root),
                "connection-1",
                "folder-1",
            )
            controls = [
                item
                for item in workbook_elements(result["workbook"])
                if item["kind"] == "control"
            ]
            self.assertEqual(
                {item["controlType"] for item in controls},
                {"text", "number", "checkbox"},
            )
            self.assertFalse(
                any(
                    warning["code"] == "control-lineage-unresolved"
                    for warning in result["warnings"]
                )
            )

    def test_cortex_complete_query_is_not_emitted_as_data_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "streamlit_app.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    conn = st.connection("snowflake")
                    def call_agent():
                        return conn.query(
                            "SELECT SNOWFLAKE.CORTEX.COMPLETE('model', 'prompt') "
                            "AS response"
                        )
                    st.title("Copilot")
                    """
                ),
                encoding="utf-8",
            )
            result = build_workbook(
                analyze_project(root),
                "connection-1",
                "folder-1",
            )
            self.assertFalse(
                any(
                    item.get("source", {}).get("kind") == "sql"
                    for item in workbook_elements(result["workbook"])
                )
            )
            self.assertIn(
                "ai-runtime-excluded-from-data-sources",
                {warning["code"] for warning in result["warnings"]},
            )


if __name__ == "__main__":
    unittest.main()
