import json, os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import actions


def _sort(o):
    if isinstance(o, dict):
        return {k: _sort(o[k]) for k in sorted(o)}
    if isinstance(o, list):
        return [_sort(e) for e in o]
    return o


class SurfacesTest(unittest.TestCase):
    def test_surfaces_all_4_actions_surfaces_are_go(self):
        expected = ["button", "effects", "input_table_empty", "input_table_linked"]
        self.assertEqual(sorted(actions.SURFACES.keys()), sorted(expected))
        self.assertTrue(all(actions.SURFACES.values()))


class ButtonTest(unittest.TestCase):
    def test_default_appearance_trigger_and_default_action_id(self):
        el = actions.button(id="btn-log", text="Log note",
                             effects=[{"effect": "insert-rows", "table": "annotations", "values": {}}])
        self.assertEqual(el, {
            "id": "btn-log", "kind": "button", "text": "Log note", "appearance": "filled",
            "actions": [{"id": "a-btn-log", "trigger": "on-click",
                         "effects": [{"effect": "insert-rows", "table": "annotations", "values": {}}]}],
        })

    def test_custom_appearance_and_trigger_are_honored(self):
        el = actions.button(id="btn-reset", text="Reset filters", appearance="outline", trigger="on-load",
                             effects=[])
        self.assertEqual(el["appearance"], "outline")
        self.assertEqual(el["actions"][0]["trigger"], "on-load")

    def test_explicit_action_id_overrides_default(self):
        el = actions.button(id="btn-reset", text="Reset filters", action_id="a-reset", effects=[])
        self.assertEqual(el["actions"][0]["id"], "a-reset")

    def test_effects_list_is_passed_through_verbatim(self):
        effects = [{"effect": "insert-rows", "table": "t", "values": {"c": 1}},
                   {"effect": "clear-control", "scope": {"type": "page", "page": "pg"}, "usePublishedValue": True}]
        el = actions.button(id="btn-log", text="Log note", effects=effects)
        self.assertEqual(el["actions"][0]["effects"], effects)
        self.assertEqual(len(el["actions"][0]["effects"]), 2)

    def test_id_required(self):
        with self.assertRaises(ValueError):
            actions.button(id="", text="x", effects=[])

    def test_text_required(self):
        with self.assertRaises(ValueError):
            actions.button(id="btn-x", text="", effects=[])

    def test_no_go_surface_returns_opt_in_marker(self):
        surfaces = dict(actions.SURFACES, button=False)
        el = actions.button(id="btn-log", text="Log note", effects=[], surfaces=surfaces)
        self.assertEqual(el, {"opt_in": True, "id": "btn-log"})


ANNOTATION_COLUMNS = [
    {"id": "an-note", "type": "text", "name": "Review note"},
    {"id": "CREATED_AT"}, {"id": "CREATED_BY"},
]


class InputTableEmptyTest(unittest.TestCase):
    def test_input_mode_edit_present_and_source_kind_empty(self):
        el = actions.input_table_empty(id="annotations", connection_id="write-conn-1", columns=ANNOTATION_COLUMNS)
        self.assertEqual(el, {
            "id": "annotations", "kind": "input-table", "inputMode": "edit",
            "source": {"kind": "empty", "connectionId": "write-conn-1"},
            "columns": ANNOTATION_COLUMNS,
        })

    def test_name_omitted_entirely_when_not_given(self):
        el = actions.input_table_empty(id="annotations", connection_id="write-conn-1", columns=ANNOTATION_COLUMNS)
        self.assertNotIn("name", el)

    def test_name_passed_through_verbatim_when_given(self):
        name = {"text": "Review log (append-only)", "fontWeight": "bold", "fontSize": 15, "color": "#1A1A1A"}
        el = actions.input_table_empty(id="annotations", connection_id="write-conn-1", columns=ANNOTATION_COLUMNS,
                                        name=name)
        self.assertEqual(el["name"], name)

    def test_id_required(self):
        with self.assertRaises(ValueError):
            actions.input_table_empty(id="", connection_id="c", columns=ANNOTATION_COLUMNS)

    def test_connection_id_required(self):
        with self.assertRaises(ValueError):
            actions.input_table_empty(id="x", connection_id="", columns=ANNOTATION_COLUMNS)

    def test_columns_required_none(self):
        with self.assertRaises(ValueError):
            actions.input_table_empty(id="x", connection_id="c", columns=None)

    def test_columns_required_empty_list(self):
        with self.assertRaises(ValueError):
            actions.input_table_empty(id="x", connection_id="c", columns=[])

    def test_no_go_surface_returns_opt_in_marker(self):
        surfaces = dict(actions.SURFACES, input_table_empty=False)
        el = actions.input_table_empty(id="annotations", connection_id="write-conn-1", columns=ANNOTATION_COLUMNS,
                                        surfaces=surfaces)
        self.assertEqual(el, {"opt_in": True, "id": "annotations"})


TARGET_COLUMNS = [
    {"id": "tg-fam", "key": "fp-fam"},
    {"id": "tg-actual", "key": "fp-rev", "name": "Actual Revenue"},
    {"id": "tg-target", "type": "number", "name": "Target Revenue"},
    {"id": "tg-var", "name": "Variance vs Target", "formula": "[Actual Revenue] - [Target Revenue]"},
]


class InputTableLinkedTest(unittest.TestCase):
    def test_source_kind_linked_carries_from_and_connection_id(self):
        el = actions.input_table_linked(id="targets", from_="fam-pivot", connection_id="write-conn-1",
                                         columns=TARGET_COLUMNS)
        self.assertEqual(el, {
            "id": "targets", "kind": "input-table", "inputMode": "edit",
            "source": {"kind": "linked", "from": "fam-pivot", "connectionId": "write-conn-1"},
            "columns": TARGET_COLUMNS,
        })

    def test_id_required(self):
        with self.assertRaises(ValueError):
            actions.input_table_linked(id="", from_="f", connection_id="c", columns=TARGET_COLUMNS)

    def test_from_required(self):
        with self.assertRaises(ValueError):
            actions.input_table_linked(id="x", from_="", connection_id="c", columns=TARGET_COLUMNS)

    def test_connection_id_required(self):
        with self.assertRaises(ValueError):
            actions.input_table_linked(id="x", from_="f", connection_id="", columns=TARGET_COLUMNS)

    def test_columns_required_empty_list(self):
        with self.assertRaises(ValueError):
            actions.input_table_linked(id="x", from_="f", connection_id="c", columns=[])

    def test_no_go_surface_returns_opt_in_marker(self):
        surfaces = dict(actions.SURFACES, input_table_linked=False)
        el = actions.input_table_linked(id="targets", from_="fam-pivot", connection_id="write-conn-1",
                                         columns=TARGET_COLUMNS, surfaces=surfaces)
        self.assertEqual(el, {"opt_in": True, "id": "targets"})


class InsertRowsEffectTest(unittest.TestCase):
    def test_shape_values_passed_through_verbatim(self):
        values = {"an-note": {"type": "control", "control": "NoteCtl"}}
        self.assertEqual(actions.insert_rows_effect(table="annotations", values=values),
                          {"effect": "insert-rows", "table": "annotations", "values": values})

    def test_table_required(self):
        with self.assertRaises(ValueError):
            actions.insert_rows_effect(table="", values={})

    def test_no_go_surface_returns_empty_dict(self):
        surfaces = dict(actions.SURFACES, effects=False)
        self.assertEqual(actions.insert_rows_effect(table="annotations", values={}, surfaces=surfaces), {})


class ClearControlEffectTest(unittest.TestCase):
    def test_shape(self):
        self.assertEqual(actions.clear_control_effect(page="pg"),
                          {"effect": "clear-control", "scope": {"type": "page", "page": "pg"},
                           "usePublishedValue": True})

    def test_page_required(self):
        with self.assertRaises(ValueError):
            actions.clear_control_effect(page="")

    def test_no_go_surface_returns_empty_dict(self):
        surfaces = dict(actions.SURFACES, effects=False)
        self.assertEqual(actions.clear_control_effect(page="pg", surfaces=surfaces), {})


class SetControlValueEffectTest(unittest.TestCase):
    def test_shape(self):
        self.assertEqual(actions.set_control_value_effect(control="RegionF", text="West"), {
            "effect": "set-control-value", "control": "RegionF",
            "value": {"type": "constant", "value": {"type": "text", "value": "West"}},
        })

    def test_control_required(self):
        with self.assertRaises(ValueError):
            actions.set_control_value_effect(control="", text="West")

    def test_text_required(self):
        with self.assertRaises(ValueError):
            actions.set_control_value_effect(control="RegionF", text="")

    def test_no_go_surface_returns_empty_dict(self):
        surfaces = dict(actions.SURFACES, effects=False)
        self.assertEqual(actions.set_control_value_effect(control="RegionF", text="West", surfaces=surfaces), {})


class GoldenTest(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(os.path.dirname(__file__), "testdata", "actions_golden.json")) as f:
            self.golden = json.load(f)

    def test_helpers_match_actions_golden(self):
        button_effects = [
            actions.insert_rows_effect(table="annotations",
                                        values={"an-note": {"type": "control", "control": "NoteCtl"}}),
            actions.clear_control_effect(page="pg"),
        ]
        actual = {
            "button": actions.button(id="btn-log", text="Log note", appearance="filled", effects=button_effects),
            "input_table_empty": actions.input_table_empty(
                id="annotations", connection_id="write-conn-1", columns=ANNOTATION_COLUMNS,
                name={"text": "Review log (append-only)", "fontWeight": "bold", "fontSize": 15, "color": "#1A1A1A"}),
            "input_table_linked": actions.input_table_linked(
                id="targets", from_="fam-pivot", connection_id="write-conn-1", columns=TARGET_COLUMNS),
            "insert_rows_effect": actions.insert_rows_effect(
                table="annotations", values={"an-note": {"type": "control", "control": "NoteCtl"}}),
            "clear_control_effect": actions.clear_control_effect(page="pg"),
            "set_control_value_effect": actions.set_control_value_effect(control="RegionF", text="West"),
        }
        self.assertEqual(json.dumps(_sort(actual)), json.dumps(_sort(self.golden)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
