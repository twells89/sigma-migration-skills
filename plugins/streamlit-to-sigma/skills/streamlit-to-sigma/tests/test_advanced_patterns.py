#!/usr/bin/env python3
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SKILL))

from converter import analyze_project  # noqa: E402


class AdvancedPatternsTest(unittest.TestCase):
    def write(self, root: Path, relative: str, body: str) -> None:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(body), encoding="utf-8")

    def test_multipage_state_and_form_gaps(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(
                root,
                "snowflake.yml",
                """
                definition_version: 2
                entities:
                  app:
                    type: streamlit
                    main_file: streamlit_app.py
                    artifacts:
                      - streamlit_app.py
                      - app_pages/overview.py
                      - app_pages/detail.py
                      - lib/data.py
                """,
            )
            self.write(
                root,
                "streamlit_app.py",
                """
                import streamlit as st
                page = st.navigation([
                    st.Page("app_pages/overview.py", title="Overview"),
                    st.Page("app_pages/detail.py", title="Detail"),
                ])
                page.run()
                """,
            )
            self.write(
                root,
                "lib/data.py",
                """
                import streamlit as st
                conn = st.connection("snowflake")
                def load_orders():
                    return conn.query('SELECT ORDER_ID, REGION, REVENUE FROM DB.S.ORDERS')
                """,
            )
            self.write(
                root,
                "app_pages/overview.py",
                """
                import streamlit as st
                from lib.data import load_orders
                df = load_orders()
                with st.form("filters"):
                    regions = st.multiselect("Region", df["REGION"].unique())
                    st.form_submit_button("Apply")
                if st.button("Detail"):
                    st.session_state.selected = "x"
                    st.switch_page("app_pages/detail.py")
                """,
            )
            self.write(
                root,
                "app_pages/detail.py",
                """
                import streamlit as st
                import streamlit.components.v1 as components
                widget = components.declare_component("custom_widget")
                st.title("Detail")
                """,
            )
            ir = analyze_project(root)
            self.assertEqual([page.name for page in ir.pages], ["Overview", "Detail"])
            self.assertEqual(len(ir.queries), 1)
            codes = {gap.code for gap in ir.gaps}
            self.assertIn("deferred-form-state", codes)
            self.assertIn("session-state", codes)
            self.assertIn("streamlit-switch_page", codes)
            self.assertIn("custom-component", codes)
            switch_gap = next(
                gap
                for gap in ir.gaps
                if gap.code == "streamlit-switch_page"
            )
            self.assertTrue(switch_gap.resolved)
            detail_button = next(
                element
                for element in ir.elements
                if element.kind == "button" and element.label == "Detail"
            )
            self.assertEqual(
                detail_button.bindings["navigate_page"],
                "app_pages/detail.py",
            )

    def test_config_driven_kpis_and_charts_expand(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(
                root,
                "streamlit_app.py",
                """
                import streamlit as st
                KPI_CONFIG = [
                    {"label": "Stars", "column": "STARS"},
                    {"label": "Forks", "column": "FORKS"},
                ]
                CHART_TABS = [
                    {"label": "Traffic", "charts": [
                        {"type": "plotly_line", "data_key": "traffic",
                         "config": {"x": "DATE", "y": "VIEWS",
                                    "title": "Views Over Time"}}
                    ]}
                ]
                for item in KPI_CONFIG:
                    render_kpi(item)
                for tab in CHART_TABS:
                    render_chart(tab)
                """,
            )
            ir = analyze_project(root)
            metrics = [item for item in ir.elements if item.kind == "metric"]
            charts = [item for item in ir.elements if item.kind.endswith("-chart")]
            self.assertEqual([item.label for item in metrics], ["Stars", "Forks"])
            self.assertEqual(len(charts), 1)
            self.assertEqual(charts[0].label, "Views Over Time")
            self.assertIn({"kind": "tab", "name": "Traffic"}, charts[0].context)

    def test_duplicate_loaders_and_unlowered_pandas_stay_loud(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(
                root,
                "snowflake.yml",
                """
                definition_version: 2
                entities:
                  app:
                    type: streamlit
                    main_file: streamlit_app.py
                    artifacts:
                      - streamlit_app.py
                      - lib/a.py
                      - lib/b.py
                """,
            )
            self.write(
                root,
                "streamlit_app.py",
                """
                import logging
                import streamlit as st
                from lib.a import load_data
                logger = logging.getLogger(__name__)
                df = load_data()
                merged = df.merge(df, on="ID")
                top = merged.sort_values("VALUE").head(10)
                logger.info("not workbook text")
                st.dataframe(top)
                """,
            )
            for module, table in (("a", "A"), ("b", "B")):
                self.write(
                    root,
                    f"lib/{module}.py",
                    f"""
                    def load_data():
                        conn = get_connection()
                        return conn.query("SELECT ID, VALUE FROM DB.S.{table}")
                    """,
                )
            ir = analyze_project(root)
            codes = {gap.code for gap in ir.gaps}
            self.assertIn("ambiguous-query-function", codes)
            self.assertIn("dataframe-restructure-required", codes)
            self.assertFalse(
                any(item.label == "not workbook text" for item in ir.elements)
            )

    def test_scenario_planner_boundaries_are_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(
                root,
                "snowflake.yml",
                """
                definition_version: 2
                entities:
                  app:
                    type: streamlit
                    main_file: streamlit_app.py
                    artifacts:
                      - streamlit_app.py
                      - lib/data.py
                """,
            )
            self.write(
                root,
                "lib/data.py",
                """
                def load_data(_conn):
                    return _conn.query(
                        "SELECT ORDER_ID, NET_REVENUE FROM DB.S.ORDERS"
                    )
                """,
            )
            self.write(
                root,
                "streamlit_app.py",
                """
                import streamlit as st
                from lib.data import load_data
                conn = st.connection("snowflake")
                df = load_data(conn)
                with st.form("assumptions"):
                    st.session_state.pending["volume"] = st.number_input(
                        "Volume Change %", value=0.0
                    )
                    st.form_submit_button("Apply")
                scenario = apply_scenario(df, st.session_state.pending)
                edited = st.data_editor(scenario)
                st.plotly_chart(build_chart(edited))
                """,
            )
            ir = analyze_project(root)
            self.assertEqual(len(ir.queries), 1)
            self.assertEqual(ir.queries[0].function, "load_data")
            self.assertTrue(
                any(control.label == "Volume Change %" for control in ir.controls)
            )
            codes = {gap.code for gap in ir.gaps}
            self.assertIn("session-state", codes)
            self.assertIn("deferred-form-state", codes)
            self.assertIn("python-transform", codes)
            self.assertIn("data-editor", codes)
            self.assertIn("opaque-chart-object", codes)

    def test_chat_app_is_a_workbook_agent_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(
                root,
                "streamlit_app.py",
                """
                import streamlit as st
                from openai import OpenAI

                prompt = st.chat_input("Ask about revenue")
                if prompt:
                    client = OpenAI()
                    response = client.chat.completions.create(
                        model="example",
                        messages=[{"role": "user", "content": prompt}],
                    )
                    with st.chat_message("assistant"):
                        st.write(response)
                """,
            )
            ir = analyze_project(root)
            candidates = [
                gap for gap in ir.gaps if gap.code == "workbook-agent-candidate"
            ]
            self.assertEqual(len(candidates), 1)
            self.assertEqual(candidates[0].severity, "restructure")

    def test_cortex_complete_is_not_misclassified_as_cortex_agent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(
                root,
                "snowflake.yml",
                """
                definition_version: 2
                entities:
                  app:
                    type: streamlit
                    main_file: streamlit_app.py
                    artifacts:
                      - streamlit_app.py
                      - lib/agent.py
                      - lib/agent_config.py
                      - sql/agent_setup.sql
                """,
            )
            self.write(
                root,
                "streamlit_app.py",
                """
                import streamlit as st
                prompt = st.chat_input("Ask")
                with st.chat_message("assistant"):
                    st.write(prompt)
                """,
            )
            self.write(
                root,
                "lib/agent.py",
                """
                def call_agent(conn):
                    return conn.query(
                        "SELECT SNOWFLAKE.CORTEX.COMPLETE('model', 'prompt')"
                    )
                """,
            )
            self.write(
                root,
                "lib/agent_config.py",
                """
                AGENT_FQN = "DB.SCHEMA.AGENT"
                AGENT_INSTRUCTIONS = "Use governed retail data."
                SUGGESTED_QUESTIONS = ["How many orders?"]
                """,
            )
            self.write(
                root,
                "sql/agent_setup.sql",
                "CREATE OR REPLACE CORTEX AGENT DB.SCHEMA.AGENT;",
            )
            ir = analyze_project(root)
            codes = {gap.code for gap in ir.gaps}
            self.assertIn("llm-complete-not-agent", codes)
            self.assertIn("agent-runtime-mismatch", codes)
            self.assertEqual(ir.metadata["agentRuntime"], "cortex-complete")
            self.assertEqual(
                ir.metadata["agentConfig"]["AGENT_FQN"],
                "DB.SCHEMA.AGENT",
            )

    def test_external_sql_and_shared_sidebar_filters_expand(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(
                root,
                "snowflake.yml",
                """
                definition_version: 2
                entities:
                  app:
                    type: streamlit
                    main_file: streamlit_app.py
                    artifacts:
                      - streamlit_app.py
                      - app_pages/one.py
                      - app_pages/two.py
                      - lib/data.py
                      - lib/filters.py
                      - sql/orders.sql
                """,
            )
            self.write(
                root,
                "streamlit_app.py",
                """
                import streamlit as st
                from lib.filters import render_sidebar_filters
                render_sidebar_filters(raw_df)
                page = st.navigation([
                    st.Page("app_pages/one.py", title="One"),
                    st.Page("app_pages/two.py", title="Two"),
                ])
                page.run()
                """,
            )
            self.write(root, "app_pages/one.py", "import streamlit as st\nst.title('One')")
            self.write(root, "app_pages/two.py", "import streamlit as st\nst.title('Two')")
            self.write(
                root,
                "lib/data.py",
                """
                import os
                def load_orders(_conn):
                    sql_path = os.path.join(
                        os.path.dirname(__file__), "..", "sql", "orders.sql"
                    )
                    with open(sql_path, "r") as handle:
                        sql = handle.read()
                    return _conn.query(sql)
                """,
            )
            self.write(
                root,
                "lib/filters.py",
                """
                import streamlit as st
                def render_sidebar_filters(df):
                    regions = sorted(df["region"].unique().tolist())
                    with st.sidebar:
                        with st.form("filters"):
                            st.date_input("Date Range")
                            st.multiselect("Region", options=regions)
                            st.form_submit_button("Apply")
                """,
            )
            self.write(
                root,
                "sql/orders.sql",
                "SELECT ORDER_DATE AS order_date, REGION AS region FROM DB.S.ORDERS",
            )
            ir = analyze_project(root)
            self.assertEqual(len(ir.queries), 1)
            self.assertFalse(ir.queries[0].dynamic)
            self.assertEqual(ir.queries[0].columns, ["order_date", "region"])
            labels = [control.label for control in ir.controls]
            self.assertEqual(labels.count("Date Range"), 2)
            self.assertEqual(labels.count("Region"), 2)
            self.assertEqual(len({control.id for control in ir.controls}), 4)
            self.assertTrue(all(control.sidebar for control in ir.controls))
            self.assertTrue(
                all(len(control.id) <= 52 for control in ir.controls)
            )
            self.assertTrue(
                all(
                    any(
                        context.get("kind") == "form"
                        for context in control.context
                    )
                    for control in ir.controls
                )
            )

    def test_empty_result_stop_is_resolved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(
                root,
                "streamlit_app.py",
                """
                import streamlit as st
                if df.empty:
                    st.warning("No rows")
                    st.stop()
                st.dataframe(df)
                """,
            )
            ir = analyze_project(root)
            gap = next(gap for gap in ir.gaps if gap.code == "streamlit-stop")
            self.assertTrue(gap.resolved)
            self.assertIn("empty Sigma elements", gap.resolution)


if __name__ == "__main__":
    unittest.main()
