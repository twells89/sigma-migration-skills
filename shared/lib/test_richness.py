import json, os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import richness


def _sort(o):
    if isinstance(o, dict):
        return {k: _sort(o[k]) for k in sorted(o)}
    if isinstance(o, list):
        return [_sort(e) for e in o]
    return o


FILTER_CONTROLS = [
    {"id": "ctl-region", "control_id": "RegionCtl", "name": "Region", "source_element_id": "src",
     "column_id": "col-region", "filter_targets": [{"element_id": "detail-tbl", "column_id": "dt-region"}]},
    {"id": "ctl-category", "control_id": "CategoryCtl", "name": "Category", "source_element_id": "src",
     "column_id": "col-category", "filter_targets": [
         {"element_id": "detail-tbl", "column_id": "dt-category"},
         {"element_id": "master-chart", "column_id": "mc-category"},
     ]},
]


class SurfacesTest(unittest.TestCase):
    def test_surfaces_all_5_richness_surfaces_are_go(self):
        expected = ["agent", "ai_insight", "dynamic_grain", "filter_row", "wide_pivot"]
        self.assertEqual(sorted(richness.SURFACES.keys()), sorted(expected))
        self.assertTrue(all(richness.SURFACES.values()))


class AiInsightTest(unittest.TestCase):
    def test_default_model_body_contains_calltext_formula(self):
        el = richness.ai_insight(id="ai-rev", prompt="Summarize revenue trends for the period.")
        self.assertEqual(el["id"], "ai-rev")
        self.assertEqual(el["kind"], "text")
        self.assertIn(
            '{{ Replace(CallText("SNOWFLAKE.CORTEX.COMPLETE", "llama3.1-8b", '
            '"Summarize revenue trends for the period.") , \'"\', "") }}',
            el["body"])

    def test_custom_model_used_verbatim(self):
        el = richness.ai_insight(id="ai-rev2", model="mistral-large2", prompt="Say hi.")
        self.assertIn('CallText("SNOWFLAKE.CORTEX.COMPLETE", "mistral-large2", "Say hi.")', el["body"])

    def test_no_separate_connection_argument(self):
        el = richness.ai_insight(id="ai-rev3", prompt="x")
        self.assertRegex(el["body"], r'CallText\("SNOWFLAKE\.CORTEX\.COMPLETE",\s*"[^"]+",\s*"[^"]*"\)')

    def test_id_required(self):
        with self.assertRaises(ValueError):
            richness.ai_insight(id="", prompt="x")

    def test_prompt_required(self):
        with self.assertRaises(ValueError):
            richness.ai_insight(id="x", prompt="")

    def test_no_go_surface_returns_opt_in_marker(self):
        surfaces = dict(richness.SURFACES, ai_insight=False)
        el = richness.ai_insight(id="ai-rev", prompt="x", surfaces=surfaces)
        self.assertEqual(el, {"opt_in": True, "id": "ai-rev"})


class GrainControlTest(unittest.TestCase):
    def test_segmented_control_week_month_day_default_month(self):
        ctl = richness.grain_control(id="GrainCtl")
        self.assertEqual(ctl, {
            "id": "GrainCtl", "kind": "control", "controlId": "GrainCtl-ctl",
            "name": "Grain", "controlType": "segmented", "selectionMode": "single",
            "value": "Month",
            "source": {"kind": "manual", "valueType": "text", "values": ["Week", "Month", "Day"]},
        })

    def test_element_id_and_control_id_are_distinct(self):
        ctl = richness.grain_control(id="GrainCtl")
        self.assertNotEqual(ctl["id"], ctl["controlId"])
        self.assertEqual(ctl["id"], "GrainCtl")
        self.assertEqual(ctl["controlId"], "GrainCtl-ctl")

    def test_control_id_override_is_honored_and_still_distinct(self):
        ctl = richness.grain_control(id="GrainCtl", control_id="GrainCtlHandle")
        self.assertEqual(ctl["id"], "GrainCtl")
        self.assertEqual(ctl["controlId"], "GrainCtlHandle")

    def test_id_required(self):
        with self.assertRaises(ValueError):
            richness.grain_control(id="")

    def test_no_go_surface_returns_opt_in_marker(self):
        surfaces = dict(richness.SURFACES, dynamic_grain=False)
        ctl = richness.grain_control(id="GrainCtl", surfaces=surfaces)
        self.assertEqual(ctl, {"opt_in": True, "id": "GrainCtl"})


class TrendDimensionTest(unittest.TestCase):
    def test_exact_switch_string_task1_verified_pattern(self):
        self.assertEqual(
            richness.trend_dimension(grain_control_id="GrainCtl-ctl", date_ref="[Src/Date]"),
            'Switch([GrainCtl-ctl],"Week",DateTrunc("week",[Src/Date]),'
            '"Month",DateTrunc("month",[Src/Date]),DateTrunc("day",[Src/Date]))')

    def test_references_grain_controls_control_id_not_element_id(self):
        ctl = richness.grain_control(id="GrainCtl")
        dim = richness.trend_dimension(grain_control_id=ctl["controlId"], date_ref="[Src/Date]")
        self.assertIn("[%s]" % ctl["controlId"], dim)
        self.assertNotIn("[%s]" % ctl["id"], dim)

    def test_grain_control_id_required(self):
        with self.assertRaises(ValueError):
            richness.trend_dimension(grain_control_id="", date_ref="[Src/Date]")

    def test_date_ref_required(self):
        with self.assertRaises(ValueError):
            richness.trend_dimension(grain_control_id="GrainCtl-ctl", date_ref="")

    def test_no_go_surface_returns_empty_string(self):
        surfaces = dict(richness.SURFACES, dynamic_grain=False)
        self.assertEqual(
            richness.trend_dimension(grain_control_id="GrainCtl-ctl", date_ref="[Src/Date]", surfaces=surfaces), "")


class FilterRowTest(unittest.TestCase):
    def test_emits_one_list_control_element_per_descriptor_bound_to_base(self):
        rows = richness.filter_row(controls=FILTER_CONTROLS)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0], {
            "id": "ctl-region", "kind": "control", "controlId": "RegionCtl",
            "name": "Region", "controlType": "list", "mode": "include",
            "selectionMode": "single", "values": [],
            "source": {"kind": "source", "source": {"kind": "table", "elementId": "src"},
                       "columnId": "col-region"},
            "filters": [{"source": {"kind": "table", "elementId": "detail-tbl"}, "columnId": "dt-region"}],
        })

    def test_control_can_filter_multiple_target_elements(self):
        rows = richness.filter_row(controls=FILTER_CONTROLS)
        self.assertEqual(rows[1]["filters"], [
            {"source": {"kind": "table", "elementId": "detail-tbl"}, "columnId": "dt-category"},
            {"source": {"kind": "table", "elementId": "master-chart"}, "columnId": "mc-category"},
        ])

    def test_empty_controls_list_returns_empty_array(self):
        self.assertEqual(richness.filter_row(controls=[]), [])

    def test_no_go_surface_returns_empty_array(self):
        surfaces = dict(richness.SURFACES, filter_row=False)
        self.assertEqual(richness.filter_row(controls=FILTER_CONTROLS, surfaces=surfaces), [])


PIVOT_COLUMNS = [
    {"id": "piv-region", "name": "Region", "formula": "[Src/Region]"},
    {"id": "piv-category", "name": "Category", "formula": "[Src/Category]"},
    {"id": "piv-revenue", "name": "Revenue", "formula": "Sum([Src/Revenue])"},
    {"id": "piv-orders", "name": "Orders", "formula": "Sum([Src/Orders])"},
    {"id": "piv-margin", "name": "Margin", "formula": "Avg([Src/Margin])"},
]


class WidePivotTest(unittest.TestCase):
    def test_pivot_table_with_columns_rowsby_columnsby_empty_values(self):
        piv = richness.wide_pivot(id="piv-1", source_element_id="src",
                                   columns=PIVOT_COLUMNS,
                                   rows_by=[{"id": "piv-region"}, {"id": "piv-category"}],
                                   values=["piv-revenue", "piv-orders", "piv-margin"])
        self.assertEqual(piv, {
            "id": "piv-1", "kind": "pivot-table",
            "source": {"kind": "table", "elementId": "src"},
            "columns": PIVOT_COLUMNS,
            "rowsBy": [{"id": "piv-region"}, {"id": "piv-category"}],
            "columnsBy": [],
            "values": ["piv-revenue", "piv-orders", "piv-margin"],
        })

    def test_columns_is_a_non_empty_array(self):
        piv = richness.wide_pivot(id="piv-1", source_element_id="src", columns=PIVOT_COLUMNS,
                                   rows_by=[{"id": "piv-region"}, {"id": "piv-category"}],
                                   values=["piv-revenue", "piv-orders", "piv-margin"])
        self.assertIsInstance(piv["columns"], list)
        self.assertTrue(len(piv["columns"]) > 0)

    def test_columnsby_is_always_empty(self):
        piv = richness.wide_pivot(id="piv-2", source_element_id="src",
                                   columns=[{"id": "c1", "formula": "[Src/C1]"}],
                                   rows_by=[{"id": "c1"}], values=["c2"])
        self.assertEqual(piv["columnsBy"], [])

    def test_id_required(self):
        with self.assertRaises(ValueError):
            richness.wide_pivot(id="", source_element_id="src", columns=PIVOT_COLUMNS, rows_by=[], values=[])

    def test_source_element_id_required(self):
        with self.assertRaises(ValueError):
            richness.wide_pivot(id="p", source_element_id="", columns=PIVOT_COLUMNS, rows_by=[], values=[])

    def test_columns_required_none(self):
        with self.assertRaises(ValueError):
            richness.wide_pivot(id="p", source_element_id="src", columns=None, rows_by=[], values=[])

    def test_columns_required_empty_list(self):
        with self.assertRaises(ValueError):
            richness.wide_pivot(id="p", source_element_id="src", columns=[], rows_by=[], values=[])

    def test_no_go_surface_returns_opt_in_marker(self):
        surfaces = dict(richness.SURFACES, wide_pivot=False)
        piv = richness.wide_pivot(id="piv-1", source_element_id="src", columns=PIVOT_COLUMNS,
                                   rows_by=[], values=[], surfaces=surfaces)
        self.assertEqual(piv, {"opt_in": True, "id": "piv-1"})


AGENT_TOOLS = [
    {"toolId": "t-log-note", "kind": "action", "name": "Log note", "description": "Insert a review note.",
     "steps": [{"kind": "effect", "effect": "insert-rows", "table": "annotations",
                "value": {"type": "agent-input", "inputName": "note"}}]},
]


class AgentTest(unittest.TestCase):
    def test_read_only_analyst_omits_tools_key_entirely(self):
        el = richness.agent(id="ag-1", name="Analyst", instructions="Be a helpful retail analyst.",
                             data_source_ids=["src"])
        self.assertEqual(el, {
            "id": "ag-1", "name": "Analyst", "instructions": "Be a helpful retail analyst.",
            "dataSources": [{"kind": "table", "elementId": "src"}],
        })
        self.assertNotIn("tools", el)

    def test_multiple_data_source_ids_map_to_multiple_data_sources_in_order(self):
        el = richness.agent(id="ag-1", name="Analyst", instructions="x", data_source_ids=["src-a", "src-b"])
        self.assertEqual(el["dataSources"], [
            {"kind": "table", "elementId": "src-a"}, {"kind": "table", "elementId": "src-b"},
        ])

    def test_non_empty_tools_is_added_verbatim(self):
        el = richness.agent(id="ag-2", name="Assistant", instructions="Act on my behalf.",
                             data_source_ids=["src"], tools=AGENT_TOOLS)
        self.assertEqual(el["tools"], AGENT_TOOLS)
        self.assertIn("tools", el)

    def test_id_required(self):
        with self.assertRaises(ValueError):
            richness.agent(id="", name="A", instructions="x", data_source_ids=["src"])

    def test_name_required(self):
        with self.assertRaises(ValueError):
            richness.agent(id="ag-1", name="", instructions="x", data_source_ids=["src"])

    def test_instructions_required(self):
        with self.assertRaises(ValueError):
            richness.agent(id="ag-1", name="A", instructions="", data_source_ids=["src"])

    def test_no_go_surface_returns_opt_in_marker(self):
        surfaces = dict(richness.SURFACES, agent=False)
        el = richness.agent(id="ag-1", name="A", instructions="x", data_source_ids=["src"], surfaces=surfaces)
        self.assertEqual(el, {"opt_in": True, "id": "ag-1"})


class ChatTest(unittest.TestCase):
    def test_id_kind_chat_agent_id_shape(self):
        self.assertEqual(richness.chat(id="chat-1", agent_id="ag-1"),
                          {"id": "chat-1", "kind": "chat", "agentId": "ag-1"})

    def test_id_required(self):
        with self.assertRaises(ValueError):
            richness.chat(id="", agent_id="ag-1")

    def test_agent_id_required(self):
        with self.assertRaises(ValueError):
            richness.chat(id="chat-1", agent_id="")

    def test_no_go_surface_returns_opt_in_marker(self):
        surfaces = dict(richness.SURFACES, agent=False)
        el = richness.chat(id="chat-1", agent_id="ag-1", surfaces=surfaces)
        self.assertEqual(el, {"opt_in": True, "id": "chat-1"})


class GoldenTest(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(os.path.dirname(__file__), "testdata", "richness_golden.json")) as f:
            self.golden = json.load(f)

    def test_helpers_match_richness_golden(self):
        actual = {
            "agent": richness.agent(id="ag-1", name="Analyst", instructions="Be a helpful retail analyst.",
                                     data_source_ids=["src"]),
            "agent_with_tools": richness.agent(id="ag-2", name="Assistant", instructions="Act on my behalf.",
                                                data_source_ids=["src"], tools=AGENT_TOOLS),
            "chat": richness.chat(id="chat-1", agent_id="ag-1"),
            "ai_insight": richness.ai_insight(id="ai-rev", prompt="Summarize revenue trends for the period."),
            "ai_insight_custom_model": richness.ai_insight(
                id="ai-rev2", model="mistral-large2", prompt="Say one nice thing about the data."),
            "grain_control": richness.grain_control(id="GrainCtl"),
            "trend_dimension": richness.trend_dimension(grain_control_id="GrainCtl-ctl", date_ref="[Src/Date]"),
            "filter_row": richness.filter_row(controls=FILTER_CONTROLS),
            "wide_pivot": richness.wide_pivot(id="piv-1", source_element_id="src",
                                               columns=PIVOT_COLUMNS,
                                               rows_by=[{"id": "piv-region"}, {"id": "piv-category"}],
                                               values=["piv-revenue", "piv-orders", "piv-margin"]),
        }
        self.assertEqual(json.dumps(_sort(actual)), json.dumps(_sort(self.golden)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
