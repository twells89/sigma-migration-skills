import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "parse-twb-layout.py"
ROOT = HERE.parents[4]
CORPUS_TWB = ROOT / "corpus" / "tableau" / "orders-overview" / "workbook-content.twb"

TWB = """\
<?xml version='1.0' encoding='utf-8'?>
<workbook xmlns:user='http://www.tableausoftware.com/xml/user'>
  <style>
    <style-rule element='all'>
      <format attr='font-name' value='Inter'/>
    </style-rule>
  </style>
  <preferences>
    <color-palette name='Brand' type='regular'>
      <color>#336699</color><color>#f06719</color><color>#ffffff</color>
    </color-palette>
  </preferences>
  <datasources>
    <datasource caption='Sales Source' name='federated.sales'>
      <column caption='Product' datatype='string' name='[PRODUCT]' role='dimension'>
        <aliases><alias key='&quot;W&quot;' value='Widget'/></aliases>
      </column>
      <column caption='Region' datatype='string' name='[REGION]' role='dimension'/>
      <column caption='Sales' datatype='real' default-format='$#,##0.00' name='[SALES]' role='measure'/>
      <column caption='Order Date' datatype='date' name='[ORDER_DATE]' role='dimension'/>
      <column caption='Metric Choice' datatype='string' name='[Calculation_1]' role='measure'>
        <calculation class='tableau'
          formula='CASE [Parameters].[Metric] WHEN &quot;Sales&quot; THEN [SALES] END'/>
      </column>
      <filter class='categorical' column='[PRODUCT]'>
        <groupfilter function='member' member='&quot;W&quot;'/>
      </filter>
      <extract>
        <filter class='categorical' column='[REGION]'>
          <groupfilter function='except'>
            <groupfilter function='member' member='%null%'/>
          </groupfilter>
        </filter>
      </extract>
    </datasource>
    <datasource caption='Parameters' name='Parameters'>
      <column caption='Metric' datatype='string' name='[Parameter 1]'
              param-domain-type='list' value='&quot;Sales&quot;'>
        <members>
          <member value='&quot;Sales&quot;'/><member value='&quot;Profit&quot;'/>
        </members>
      </column>
    </datasource>
  </datasources>
  <shared-views>
    <shared-view name='Quick Filters'>
      <filter class='categorical' column='[federated.sales].[none:PRODUCT:nk]'>
        <groupfilter function='filter'
          expression='NOT STARTSWITH([none:PRODUCT:nk],&quot;test-&quot;)'/>
      </filter>
    </shared-view>
  </shared-views>
  <worksheets>
    <worksheet name='Monthly Sales'>
      <layout-options><title><formatted-text><run>Revenue Trend</run></formatted-text></title></layout-options>
      <table>
        <view>
          <datasource-dependencies datasource='federated.sales'>
            <column caption='Product' datatype='string' name='[PRODUCT]' role='dimension'/>
            <column caption='Metric Choice' datatype='string' name='[Calculation_1]' role='measure'>
              <calculation class='tableau'
                formula='CASE [Parameters].[Metric] WHEN &quot;Old&quot; THEN [SALES] END'/>
            </column>
          </datasource-dependencies>
          <filter class='categorical' column='[federated.sales].[none:PRODUCT:nk]'>
            <groupfilter function='filter'
              expression='CONTAINS([none:PRODUCT:nk],&quot;widget&quot;)'/>
          </filter>
        </view>
        <rows>[federated.sales].[sum:SALES:qk]</rows>
        <cols>[federated.sales].[mn:ORDER_DATE:ok]</cols>
        <pane>
          <mark class='Automatic'/>
          <encodings>
            <encoding attr='color' field='[federated.sales].[none:PRODUCT:nk]' type='palette'>
              <map to='#336699'><bucket>&quot;Widget&quot;</bucket></map>
            </encoding>
          </encodings>
          <style>
            <style-rule element='mark'><format attr='mark-labels-show' value='true'/></style-rule>
          </style>
        </pane>
        <style>
          <style-rule element='cell'>
            <format attr='text-format' field='[federated.sales].[sum:SALES:qk]' value='$#,##0'/>
          </style-rule>
        </style>
      </table>
    </worksheet>
    <worksheet name='Regional Sales'>
      <table>
        <view>
          <datasource-dependencies datasource='federated.sales'/>
          <filter class='categorical' column='[federated.sales].[none:REGION:nk]'>
            <groupfilter function='member' member='&quot;West&quot;'/>
          </filter>
        </view>
        <rows>[federated.sales].[sum:SALES:qk]</rows>
        <cols>[federated.sales].[none:REGION:nk]</cols>
        <pane><mark class='Bar'/></pane>
      </table>
    </worksheet>
  </worksheets>
  <dashboards>
    <dashboard name='Alpha Sales'>
      <size maxwidth='1200' maxheight='800' sizing-mode='fixed'/>
      <style><style-rule element='dash-title'><format attr='font-size' value='20'/></style-rule></style>
      <zones id='page-alpha'>
        <zone id='root-a' type-v2='layout-flow' param='vert' x='0' y='0' w='100000' h='100000'>
          <zone id='title-a' type-v2='text' x='0' y='0' w='100000' h='10000'>
            <zone-style>
              <format attr='background-color' value='#336699'/>
              <format attr='text-align' value='center'/>
            </zone-style>
            <formatted-text>
              <run bold='true' fontcolor='#ffffff' fontsize='20'>Alpha</run>
              <run>Æ&#10;</run>
            </formatted-text>
          </zone>
          <zone id='chart-a' name='Monthly Sales' show-title='false'
                x='0' y='10000' w='90000' h='90000'/>
          <zone id='filter-a' type-v2='filter'
                param='[federated.sales].[none:PRODUCT:nk]'
                mode='compact' x='90000' y='10000' w='10000' h='30000'/>
        </zone>
      </zones>
      <devicelayouts>
        <devicelayout><zones><zone id='phone-only' name='Monthly Sales'
          x='0' y='0' w='100000' h='100000'/></zones></devicelayout>
      </devicelayouts>
    </dashboard>
    <dashboard name='Beta Sales'>
      <zones id='page-beta'>
        <zone id='chart-b' name='Regional Sales' x='0' y='0' w='100000' h='100000'/>
      </zones>
    </dashboard>
  </dashboards>
  <windows>
    <window class='dashboard' name='Alpha Sales'><simple-id uuid='{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'/></window>
    <window class='dashboard' hidden='true' name='Beta Sales'><simple-id uuid='{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}'/></window>
  </windows>
  <stories>
    <story name='Sales Story'>
      <story-points>
        <story-point id='story-1' caption='Opening' captured-sheet='Alpha Sales'/>
        <story-point id='story-2' caption='Detail' captured-sheet='Regional Sales'/>
      </story-points>
    </story>
  </stories>
</workbook>
"""


class ParseTwbLayoutTest(unittest.TestCase):
    def run_parser(self, *options):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        source = root / "workbook-content.twb"
        output = root / "dashboard-layout.json"
        source.write_text(textwrap.dedent(TWB), encoding="utf-8")
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), str(source), str(output), *options],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        return (
            json.loads(output.read_text(encoding="utf-8")),
            json.loads((root / "dashboard-layout-meta.json").read_text(encoding="utf-8")),
            root,
            completed.stdout,
        )

    def test_cli_artifacts_and_layout_signals_match_ruby_contract(self):
        layout, meta, root, stdout = self.run_parser()
        self.assertEqual(["Alpha Sales", "Beta Sales"], [item["dashboard"] for item in layout])
        self.assertTrue((root / "story-plan.json").is_file())
        self.assertIn("wrote", stdout)

        alpha = layout[0]
        self.assertEqual({"w": 1200, "h": 800, "sizing_mode": "fixed"}, alpha["canvas_px"])
        self.assertTrue(alpha["emit_page"])
        self.assertFalse(layout[1]["emit_page"])
        self.assertNotIn("phone-only", {zone["id"] for zone in alpha["zones"]})
        self.assertEqual("vert", alpha["zone_tree"][0]["direction"])

        title = next(zone for zone in alpha["zones"] if zone["id"] == "title-a")
        self.assertEqual("center", title["text_align"])
        self.assertEqual("Alpha", title["text_runs"][0]["text"])
        self.assertTrue(title["text_runs"][0]["bold"])
        self.assertTrue(title["text_runs"][1]["break"])

        chart = next(zone for zone in alpha["zones"] if zone["id"] == "chart-a")
        self.assertEqual("line", chart["chart_kind"])
        self.assertTrue(chart["chart_kind_inferred"])
        self.assertFalse(chart["show_title"])
        self.assertEqual("Revenue Trend", chart["display_title"])
        self.assertEqual(
            {"mode": "contains", "pattern": "widget"},
            chart["filters"][0]["wildcard"],
        )
        self.assertEqual(
            [{"member": "Widget", "color": "#336699"}],
            chart["series_colors"],
        )
        self.assertEqual("Product", chart["series_color_field"])
        self.assertTrue(chart["mark_labels_show"])

        control = next(zone for zone in alpha["zones"] if zone["id"] == "filter-a")
        self.assertEqual("filter", control["kind"])
        self.assertEqual("Product", control["filter_column_caption"])
        self.assertEqual("compact", control["control_display"])

        worksheet = meta["worksheets"]["Monthly Sales"]
        self.assertEqual(
            "CASE [Parameters].[Metric] WHEN \"Sales\" THEN [SALES] END",
            worksheet["calculations"][0]["formula"],
        )
        self.assertEqual(["Metric"], worksheet["calculations"][0]["parameter_refs"])
        self.assertEqual("$#,##0.00", meta["column_formats"]["Sales"])
        self.assertEqual([{"key": "W", "value": "Widget"}], meta["column_aliases"]["Product"])
        self.assertEqual(["Sales", "Profit"], meta["parameters"][0]["members"])
        self.assertEqual("does-not-start-with", meta["shared_filters"][0]["wildcard"]["mode"])
        self.assertEqual({"datasource", "extract"}, {
            item["filter_scope"] for item in meta["datasource_filters"]
        })
        self.assertEqual(
            ["dashboard", "worksheet"],
            [point["sheet_kind"] for point in meta["stories"][0]["points"]],
        )
        self.assertIn("#336699", alpha["brand_palette"])
        self.assertNotIn("#ffffff", alpha["brand_palette"])

    def test_dashboard_name_scope_narrows_layout_worksheets_and_shared_filters(self):
        layout, meta, _root, stdout = self.run_parser("--dashboard", "alpha")
        self.assertEqual(["Alpha Sales"], [item["dashboard"] for item in layout])
        self.assertEqual(["Monthly Sales"], list(meta["worksheets"]))
        self.assertEqual(1, len(meta["shared_filters"]))
        self.assertIn("[scoped: alpha]", stdout)

    def test_page_scope_is_or_ed_with_repeatable_dashboard_scope(self):
        layout, meta, _root, _stdout = self.run_parser(
            "--dashboard", "does-not-match",
            "--dashboard", "ALPHA",
            "--page", "page-beta",
        )
        self.assertEqual(["Alpha Sales", "Beta Sales"], [item["dashboard"] for item in layout])
        self.assertEqual({"Monthly Sales", "Regional Sales"}, set(meta["worksheets"]))

    def test_beta_scope_drops_unreferenced_shared_filter(self):
        layout, meta, _root, _stdout = self.run_parser("--page", "page-beta")
        self.assertEqual(["Beta Sales"], [item["dashboard"] for item in layout])
        self.assertEqual(["Regional Sales"], list(meta["worksheets"]))
        self.assertEqual([], meta["shared_filters"])

    def test_real_corpus_workbook_parses_without_ruby_or_credentials(self):
        self.assertTrue(CORPUS_TWB.is_file(), CORPUS_TWB)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "dashboard-layout.json"
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), str(CORPUS_TWB), str(output)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(0, completed.returncode, completed.stderr)
            layout = json.loads(output.read_text(encoding="utf-8"))
            meta = json.loads(
                (Path(directory) / "dashboard-layout-meta.json").read_text(encoding="utf-8")
            )
        self.assertEqual(["Orders Overview"], [item["dashboard"] for item in layout])
        charts = [zone for zone in layout[0]["zones"] if zone["kind"] == "chart"]
        self.assertEqual(6, len(charts))
        self.assertIn("pie", {zone["chart_kind"] for zone in charts})
        self.assertIn("line", {zone["chart_kind"] for zone in charts})
        self.assertEqual(6, len(meta["worksheets"]))
        self.assertIn("columns_by_guid", meta)


if __name__ == "__main__":
    unittest.main()
