import base64
import copy
import json, os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import styling
import composition


def _sort(o):
    if isinstance(o, dict):
        return {k: _sort(o[k]) for k in sorted(o)}
    if isinstance(o, list):
        return [_sort(e) for e in o]
    return o


class StylingTest(unittest.TestCase):
    def test_theme_no_args_returns_default_palette(self):
        self.assertEqual(styling.theme(), styling.DEFAULT_THEME)

    def test_theme_accent_none_returns_default_palette(self):
        self.assertEqual(styling.theme(accent=None), styling.DEFAULT_THEME)

    def test_theme_accent_empty_string_returns_default_palette(self):
        self.assertEqual(styling.theme(accent=""), styling.DEFAULT_THEME)

    def test_default_theme_categorical_slot_0_and_accent_are_base_blue(self):
        self.assertEqual(styling.DEFAULT_THEME["categorical"][0], "#2563EB")
        self.assertEqual(styling.DEFAULT_THEME["accent"], "#2563EB")

    def test_theme_accent_tints_categorical_slot_0(self):
        self.assertEqual(styling.theme(accent="#FF6600")["categorical"][0], "#FF6600")

    def test_theme_accent_tints_accent_too(self):
        self.assertEqual(styling.theme(accent="#FF6600")["accent"], "#FF6600")

    def test_accent_override_leaves_categorical_slots_1_7_unchanged(self):
        self.assertEqual(styling.theme(accent="#FF6600")["categorical"][1:], styling.DEFAULT_THEME["categorical"][1:])

    def test_accent_override_does_not_mutate_default_theme(self):
        styling.theme(accent="#FF6600")
        self.assertEqual(styling.DEFAULT_THEME["categorical"][0], "#2563EB")
        self.assertEqual(styling.DEFAULT_THEME["accent"], "#2563EB")

    def test_card_shape_border_fields_no_corner_radius_no_padding(self):
        card = styling.DEFAULT_THEME["card"]
        self.assertEqual(card["borderRadius"], "round")
        self.assertEqual(card["borderColor"], "#E2E8F0")
        self.assertEqual(card["borderWidth"], 1)
        self.assertNotIn("cornerRadius", card)
        self.assertNotIn("padding", card)

    def test_header_shape_background_color_and_border_radius_only(self):
        self.assertEqual(styling.DEFAULT_THEME["header"], {"backgroundColor": "#0F172A", "borderRadius": "round"})


class CompositionBandsTest(unittest.TestCase):
    def test_bands_kpi_and_hero_exec_matches_brief_example(self):
        out = composition.bands([{"id": "k", "role": "kpi"}, {"id": "h", "role": "hero"}], "exec")
        self.assertEqual(out, [
            {"role": "kpi", "ids": ["k"], "r0": 1, "r1": 7},
            {"role": "hero", "ids": ["h"], "r0": 7, "r1": 19},
        ])

    def test_bands_master_detail_with_control_row(self):
        out = composition.bands([
            {"id": "ctl", "role": "control"},
            {"id": "master-chart", "role": "master"},
            {"id": "detail-tbl", "role": "detail"},
        ], "master_detail")
        self.assertEqual(out, [
            {"role": "control", "ids": ["ctl"], "r0": 1, "r1": 3},
            {"role": "master_detail", "ids": ["master-chart", "detail-tbl"], "r0": 3, "r1": 17},
        ])

    def test_bands_unknown_pattern_raises(self):
        with self.assertRaises(ValueError):
            composition.bands([{"id": "k", "role": "kpi"}], "nope")

    def test_bands_role_not_used_by_pattern_raises(self):
        with self.assertRaises(ValueError):
            composition.bands([{"id": "m1", "role": "master"}], "exec")

    def test_bands_page_cols_defaults_to_24(self):
        out = composition.bands([{"id": "h", "role": "hero"}], "exec")
        self.assertEqual(out, [{"role": "hero", "ids": ["h"], "r0": 1, "r1": 13}])


class StylingHelpersTest(unittest.TestCase):
    def setUp(self):
        self.theme = styling.DEFAULT_THEME
        with open(os.path.join(os.path.dirname(__file__), "testdata", "styling_golden.json")) as f:
            self.golden = json.load(f)

    def test_surfaces_all_10_surfaces_are_go(self):
        expected = ["categorical_scheme", "chart_color_by", "container_style",
                    "format_string", "kpi_name_color", "typography",
                    "gradient_header", "motif", "gradient_card", "sparkline"]
        self.assertEqual(sorted(styling.SURFACES.keys()), sorted(expected))
        self.assertTrue(all(styling.SURFACES.values()))

    def test_chart_color_single_series(self):
        self.assertEqual(styling.chart_color(self.theme),
                          {"color": {"by": "single", "value": "#2563EB"}})

    def test_chart_color_categorical(self):
        self.assertEqual(styling.chart_color(self.theme, categorical=True),
                          {"themeOverrides": {"categoricalScheme": self.theme["categorical"]}})

    def test_chart_color_no_go_chart_color_by(self):
        surfaces = dict(styling.SURFACES, chart_color_by=False)
        self.assertEqual(styling.chart_color(self.theme, surfaces=surfaces), {})

    def test_chart_color_no_go_categorical_scheme(self):
        surfaces = dict(styling.SURFACES, categorical_scheme=False)
        self.assertEqual(styling.chart_color(self.theme, categorical=True, surfaces=surfaces), {})

    def test_kpi_accent_merges_into_name_object(self):
        name = dict({"text": "Revenue"}, **styling.kpi_accent(self.theme))
        self.assertEqual(name, {"text": "Revenue", "color": "#2563EB"})

    def test_kpi_accent_no_go(self):
        surfaces = dict(styling.SURFACES, kpi_name_color=False)
        self.assertEqual(styling.kpi_accent(self.theme, surfaces=surfaces), {})

    def test_format_for_currency_integer_percent_decimal(self):
        self.assertEqual(styling.format_for("currency"), {"kind": "number", "formatString": "$,.0f"})
        self.assertEqual(styling.format_for("integer"), {"kind": "number", "formatString": ",.0f"})
        self.assertEqual(styling.format_for("percent"), {"kind": "number", "formatString": ".1%"})
        self.assertEqual(styling.format_for("decimal"), {"kind": "number", "formatString": ",.2f"})

    def test_format_for_unknown_semantic_raises(self):
        with self.assertRaises(ValueError):
            styling.format_for("bogus")

    def test_format_for_no_go(self):
        surfaces = dict(styling.SURFACES, format_string=False)
        self.assertEqual(styling.format_for("currency", surfaces=surfaces), {})

    def test_header_container_style_go(self):
        h = styling.header("hdr", "Dashboard", self.theme)
        self.assertEqual(len(h["element"]), 2)
        self.assertEqual(h["element"][0], {"id": "hdr-bg", "kind": "container", "style": self.theme["header"]})
        self.assertEqual(h["element"][1]["kind"], "text")
        self.assertIn("<GridContainer", h["layout"])
        self.assertIn('gridRow="1 / 3"', h["layout"])
        self.assertIn('elementId="hdr-title"', h["layout"])

    def test_header_no_go_container_style(self):
        surfaces = dict(styling.SURFACES, container_style=False)
        h = styling.header("hdr", "Dashboard", self.theme, surfaces=surfaces)
        self.assertEqual(len(h["element"]), 1)
        self.assertEqual(h["element"][0]["kind"], "text")
        self.assertNotIn("GridContainer", h["layout"])

    def test_section_card_container_style_go(self):
        band = {"role": "kpi", "ids": ["k1", "k2", "k3"], "r0": 7, "r1": 13}
        sc = styling.section_card("card-1", band, self.theme)
        self.assertEqual(sc["element"], {"id": "card-1", "kind": "container", "style": self.theme["card"]})
        self.assertIn('<GridContainer elementId="card-1"', sc["wrap"])
        self.assertIn('gridRow="7 / 13"', sc["wrap"])
        self.assertEqual(sc["wrap"].count("<LayoutElement"), 3)

    def test_section_card_no_go_container_style(self):
        band = {"role": "kpi", "ids": ["k1", "k2"], "r0": 1, "r1": 7}
        surfaces = dict(styling.SURFACES, container_style=False)
        sc = styling.section_card("card-1", band, self.theme, surfaces=surfaces)
        self.assertIsNone(sc["element"])
        self.assertNotIn("GridContainer", sc["wrap"])
        self.assertEqual(sc["wrap"].count("<LayoutElement"), 2)

    def test_helpers_match_styling_golden(self):
        theme = self.theme
        band = {"role": "kpi", "ids": ["k1", "k2", "k3"], "r0": 7, "r1": 13}
        gc_kpi_el = {"id": "kpi-rev", "kind": "kpi-chart", "name": {"text": "Revenue"},
                     "value": {"columnId": "rev-cur"}}
        actual = {
            "chart_color_single": styling.chart_color(theme),
            "chart_color_categorical": styling.chart_color(theme, categorical=True),
            "kpi_accent": styling.kpi_accent(theme),
            "format_for_currency": styling.format_for("currency"),
            "format_for_integer": styling.format_for("integer"),
            "format_for_percent": styling.format_for("percent"),
            "format_for_decimal": styling.format_for("decimal"),
            "header": styling.header("hdr", "Dashboard", theme),
            "section_card": styling.section_card("card-1", band, theme),
            "gradient_header_glow": styling.gradient_header(
                "ghdr", "Command Center", subtitle="Live metrics", logo_url="https://example.com/logo.png"),
            "gradient_header_rings_left": styling.gradient_header(
                "ghdr2", "Ops", motif="rings", motif_side="left"),
            "gradient_header_none": styling.gradient_header("ghdr3", "Plain", motif="none"),
            "gradient_header_byo": styling.gradient_header("ghdr4", "Custom", motif="https://example.com/art.png"),
            "gradient_card": styling.gradient_card("card-1", gc_kpi_el, ["#0F172A", "#2563EB"]),
            "sparkline": styling.sparkline("spark-rev", "tbl", "[Table/Month]", "Sum([Table/Revenue])"),
        }
        self.assertEqual(json.dumps(_sort(actual)), json.dumps(_sort(self.golden)))


class MotifsTest(unittest.TestCase):
    def test_default_theme_header_gradient_is_neutral_2_3_stop_hex_not_red(self):
        hg = styling.DEFAULT_THEME["header_gradient"]
        self.assertIsInstance(hg, list)
        self.assertIn(len(hg), (2, 3))
        for h in hg:
            self.assertRegex(h, r"\A#[0-9A-Fa-f]{6}\Z")
        self.assertNotIn("#E4002B", hg)
        self.assertNotIn("#FF0000", hg)

    def test_motifs_exactly_the_6_menu_keys(self):
        self.assertEqual(sorted(styling.MOTIFS.keys()), sorted(["dots", "glow", "grid", "none", "rings", "waves"]))

    def test_motifs_non_empty_deterministic_fragments(self):
        for k in ["glow", "rings", "grid", "waves", "dots"]:
            frag = styling.MOTIFS[k]()
            self.assertIsInstance(frag, str)
            self.assertNotEqual(frag, "")
            self.assertEqual(frag, styling.MOTIFS[k]())

    def test_motifs_none_returns_empty_string(self):
        self.assertEqual(styling.MOTIFS["none"](), "")


class GradientHeaderTest(unittest.TestCase):
    def _decode(self, h):
        url = h["element"][0]["backgroundImage"]["url"]
        return base64.b64decode(url.replace("data:image/svg+xml;base64,", "")).decode()

    def test_default_glow_right_container_shape(self):
        h = styling.gradient_header("ghdr", "Command Center")
        bg = h["element"][0]
        self.assertEqual(bg["kind"], "container")
        self.assertEqual(bg["style"], {"borderRadius": "round"})
        self.assertTrue(bg["backgroundImage"]["url"].startswith("data:image/svg+xml;base64,"))
        self.assertEqual(bg["backgroundImage"]["style"], {"fit": "cover"})
        self.assertTrue(any(e["kind"] == "text" and e["id"] == "ghdr-title" for e in h["element"]))
        self.assertIn("<GridContainer", h["layout"])
        self.assertIn('elementId="ghdr-title"', h["layout"])

    def test_decoded_svg_carries_gradient_and_requested_motif(self):
        h = styling.gradient_header("ghdr", "X", motif="rings")
        svg = self._decode(h)
        self.assertIn("linearGradient", svg)
        self.assertIn('<circle r="40"/>', svg)
        self.assertIn('<g transform="translate(1440,86)">', svg)

    def test_motif_none_has_no_motif_group(self):
        h = styling.gradient_header("ghdr", "X", motif="none")
        svg = self._decode(h)
        self.assertNotIn("<g transform=", svg)

    def test_motif_side_left_translates_to_x_160(self):
        h = styling.gradient_header("ghdr", "X", motif="rings", motif_side="left")
        svg = self._decode(h)
        self.assertIn("translate(160,86)", svg)

    def test_logo_url_present_adds_logo_element_and_split_layout(self):
        h = styling.gradient_header("ghdr", "X", logo_url="https://example.com/logo.png")
        self.assertEqual(len(h["element"]), 3)
        self.assertEqual(h["element"][1], {"id": "ghdr-logo", "kind": "image",
                                            "url": "https://example.com/logo.png", "style": {"fit": "contain"}})
        self.assertIn('elementId="ghdr-logo" gridColumn="1 / 3"', h["layout"])
        self.assertIn('elementId="ghdr-title" gridColumn="3 / 25"', h["layout"])

    def test_no_logo_url_title_spans_full_width(self):
        h = styling.gradient_header("ghdr", "X")
        self.assertFalse(any(e["kind"] == "image" for e in h["element"]))
        self.assertIn('elementId="ghdr-title" gridColumn="1 / 25"', h["layout"])

    def test_subtitle_adds_separate_element_and_split_rows(self):
        h = styling.gradient_header("ghdr", "X", subtitle="Sub")
        self.assertEqual(len(h["element"]), 3)
        self.assertEqual(h["element"][2]["kind"], "text")
        self.assertEqual(h["element"][2]["id"], "ghdr-subtitle")
        self.assertIn("Sub", h["element"][2]["body"])
        self.assertIn('elementId="ghdr-title" gridColumn="1 / 25" gridRow="1 / 3"', h["layout"])
        self.assertIn('elementId="ghdr-subtitle" gridColumn="1 / 25" gridRow="3 / 4"', h["layout"])

    def test_bring_your_own_http_url_used_verbatim(self):
        h = styling.gradient_header("ghdr", "X", motif="https://example.com/art.png")
        self.assertEqual(h["element"][0]["backgroundImage"]["url"], "https://example.com/art.png")

    def test_bring_your_own_data_url_used_verbatim(self):
        uri = "data:image/png;base64,AAAA"
        h = styling.gradient_header("ghdr", "X", motif=uri)
        self.assertEqual(h["element"][0]["backgroundImage"]["url"], uri)

    def test_gradient_wrong_stop_count_raises(self):
        with self.assertRaises(ValueError):
            styling.gradient_header("ghdr", "X", gradient=["#111111"])

    def test_no_go_gradient_header_falls_back_to_flat_header(self):
        surfaces = dict(styling.SURFACES, gradient_header=False)
        h = styling.gradient_header("ghdr", "X", surfaces=surfaces)
        expected = styling.header("ghdr", "X", styling.DEFAULT_THEME, surfaces=surfaces)
        self.assertEqual(h, expected)

    def test_no_go_motif_menu_key_falls_back_to_plain_gradient(self):
        surfaces = dict(styling.SURFACES, motif=False)
        h = styling.gradient_header("ghdr", "X", motif="rings", surfaces=surfaces)
        bg = h["element"][0]["backgroundImage"]["url"]
        svg = base64.b64decode(bg.replace("data:image/svg+xml;base64,", "")).decode()
        self.assertTrue(bg.startswith("data:image/svg+xml;base64,"))
        self.assertIn("linearGradient", svg)
        self.assertNotIn("<g transform=", svg)

    def test_no_go_motif_does_not_suppress_bring_your_own_url(self):
        surfaces = dict(styling.SURFACES, motif=False)
        h = styling.gradient_header("ghdr", "X", motif="https://example.com/art.png", surfaces=surfaces)
        self.assertEqual(h["element"][0]["backgroundImage"]["url"], "https://example.com/art.png")

    def test_motif_side_center_translates_to_x_800_and_is_valid(self):
        h = styling.gradient_header("ghdr", "X", motif="rings", motif_side="center")
        svg = self._decode(h)
        self.assertIn("translate(800,86)", svg)
        self.assertTrue(any(e["kind"] == "text" and e["id"] == "ghdr-title" for e in h["element"]))
        self.assertIn("<GridContainer", h["layout"])
        self.assertIn('elementId="ghdr-title"', h["layout"])

    def test_unrecognized_motif_symbol_raises_value_error(self):
        with self.assertRaises(ValueError):
            styling.gradient_header("ghdr", "X", motif="sparkles")


class GradientCardSparklineTest(unittest.TestCase):
    """WS4 Task 3: styling.gradient_card + styling.sparkline."""

    GC_KPI_EL = {"id": "kpi-rev", "kind": "kpi-chart", "name": {"text": "Revenue"},
                 "value": {"columnId": "rev-cur"}}

    def test_gradient_card_go_returns_container_child_layout_and_white_patch(self):
        gc = styling.gradient_card("card-1", self.GC_KPI_EL, ["#0F172A", "#2563EB"])
        self.assertEqual(len(gc["element"]), 1)
        self.assertEqual(gc["element"][0]["id"], "card-1")
        self.assertEqual(gc["element"][0]["kind"], "container")
        self.assertEqual(gc["element"][0]["style"], {"borderRadius": "round"})
        self.assertTrue(gc["element"][0]["backgroundImage"]["url"].startswith("data:image/svg+xml;base64,"))
        self.assertEqual(gc["element"][0]["backgroundImage"]["style"], {"fit": "cover"})
        self.assertEqual(gc["child_layout"],
                          '<LayoutElement elementId="kpi-rev" gridColumn="1 / 25" gridRow="1 / 7"/>')
        self.assertEqual(gc["patch"], {"value": {"color": "#FFFFFF"}, "name": {"color": "#FFFFFF"},
                                        "style": {"backgroundColor": "transparent", "padding": "none"}})

    def test_gradient_card_patch_style_is_transparent_padding_none_for_legibility(self):
        """Task 6 live-render fix: value/name color alone renders white-on-white
        because the KPI element keeps its own opaque background. The patch
        must also carry style.backgroundColor=transparent + style.padding=none
        so the gradient shows through and the white text is legible."""
        gc = styling.gradient_card("card-1", self.GC_KPI_EL, ["#0F172A", "#2563EB"])
        self.assertEqual(gc["patch"]["style"], {"backgroundColor": "transparent", "padding": "none"})

    def test_gradient_card_decoded_svg_has_gradient_no_motif_group(self):
        gc = styling.gradient_card("card-1", self.GC_KPI_EL, ["#0F172A", "#2563EB"])
        url = gc["element"][0]["backgroundImage"]["url"]
        svg = base64.b64decode(url.replace("data:image/svg+xml;base64,", "")).decode()
        self.assertIn("linearGradient", svg)
        self.assertNotIn("<g transform=", svg)

    def test_gradient_card_svg_layers_dark_scrim_over_caller_gradient(self):
        """Task 6 live-render fix, user-reported ("can't see the numbers"): the
        composed background must be TWO layers -- the caller's gradient rect,
        THEN a dark scrim rect on top -- so white KPI text stays legible on
        any gradient, bright or dark."""
        gc = styling.gradient_card("card-1", self.GC_KPI_EL, ["#0F172A", "#2563EB"])
        url = gc["element"][0]["backgroundImage"]["url"]
        svg = base64.b64decode(url.replace("data:image/svg+xml;base64,", "")).decode()
        self.assertIn('id="card-scrim"', svg)
        self.assertIn('stop-opacity="%s"' % styling.CARD_SCRIM_TOP_OPACITY, svg)
        self.assertIn('stop-opacity="0"', svg)
        self.assertEqual(svg.count("<rect "), 2)  # the caller's gradient rect, THEN the scrim rect on top

    def test_gradient_card_gradient_defaults_to_dark_slate_pair_when_omitted(self):
        gc = styling.gradient_card("card-1", self.GC_KPI_EL)
        url = gc["element"][0]["backgroundImage"]["url"]
        svg = base64.b64decode(url.replace("data:image/svg+xml;base64,", "")).decode()
        default_gradient = styling.DEFAULT_THEME["card_gradient"]
        self.assertIn(default_gradient[0], svg)
        self.assertIn(default_gradient[1], svg)

    def test_gradient_card_does_not_mutate_kpi_element(self):
        kpi_el = {"id": "kpi-rev2", "kind": "kpi-chart", "name": {"text": "Revenue"},
                  "value": {"columnId": "rev-cur", "fontSize": 32}}
        snapshot = copy.deepcopy(kpi_el)
        styling.gradient_card("card-2", kpi_el, ["#0F172A", "#2563EB"])
        self.assertEqual(kpi_el, snapshot)

    def test_gradient_card_respects_custom_page_cols(self):
        gc = styling.gradient_card("card-1", self.GC_KPI_EL, ["#0F172A", "#2563EB"], page_cols=12)
        self.assertEqual(gc["child_layout"],
                          '<LayoutElement elementId="kpi-rev" gridColumn="1 / 13" gridRow="1 / 7"/>')

    def test_gradient_card_no_go_returns_empty_marker(self):
        surfaces = dict(styling.SURFACES, gradient_card=False)
        gc = styling.gradient_card("card-1", self.GC_KPI_EL, ["#0F172A", "#2563EB"], surfaces=surfaces)
        self.assertEqual(gc, {"element": [], "child_layout": "", "patch": {}})

    def test_sparkline_go_returns_borderless_line_chart(self):
        sp = styling.sparkline("spark-rev", "tbl", "[Table/Month]", "Sum([Table/Revenue])")
        self.assertEqual(sp["id"], "spark-rev")
        self.assertEqual(sp["kind"], "line-chart")
        self.assertEqual(sp["source"], {"kind": "table", "elementId": "tbl"})
        self.assertEqual(len(sp["columns"]), 2)
        self.assertEqual(sp["columns"][0]["formula"], "[Table/Month]")
        self.assertEqual(sp["columns"][0]["format"], {"kind": "datetime", "formatString": "%b %Y"})
        self.assertEqual(sp["columns"][1]["formula"], "Sum([Table/Revenue])")
        self.assertEqual(sp["xAxis"]["format"], {"marks": "none", "labels": "hidden"})
        self.assertEqual(sp["yAxis"]["format"]["labels"], "hidden")
        self.assertEqual(sp["yAxis"]["format"]["marks"], "none")
        self.assertEqual(sp["yAxis"]["format"]["scale"], {"type": "linear", "zero": False, "hideZeroLine": True})
        self.assertEqual(sp["name"], {"visibility": "hidden"})
        self.assertEqual(sp["legend"], {"visibility": "hidden"})
        self.assertEqual(sp["lineAreaStyle"], {"interpolation": "monotone"})
        self.assertEqual(sp["style"], {"backgroundColor": "transparent", "padding": "none"})

    def test_sparkline_custom_period_format(self):
        sp = styling.sparkline("spark-rev", "tbl", "[Table/Month]", "Sum([Table/Revenue])", period_format="%Y-%m")
        self.assertEqual(sp["columns"][0]["format"], {"kind": "datetime", "formatString": "%Y-%m"})

    def test_sparkline_no_go_returns_opt_in_marker(self):
        surfaces = dict(styling.SURFACES, sparkline=False)
        sp = styling.sparkline("spark-rev", "tbl", "[Table/Month]", "Sum([Table/Revenue])", surfaces=surfaces)
        self.assertEqual(sp, {"opt_in": True, "id": "spark-rev"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
