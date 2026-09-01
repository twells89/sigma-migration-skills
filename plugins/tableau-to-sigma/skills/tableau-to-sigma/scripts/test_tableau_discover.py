import argparse
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "tableau-discover.py"
spec = importlib.util.spec_from_file_location("tableau_discover", SCRIPT)
tableau_discover = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tableau_discover)

XML = """<?xml version='1.0' encoding='utf-8'?>
<workbook>
  <worksheets>
    <worksheet name='Sales Sheet'/>
  </worksheets>
  <dashboards>
    <dashboard name='Executive Dashboard'>
      <zones><zone name='Sales Sheet'/></zones>
    </dashboard>
  </dashboards>
</workbook>
"""


class TableauDiscoverTest(unittest.TestCase):
    def test_twb_names_extracts_dashboard_membership(self):
        worksheets, dashboards = tableau_discover.twb_names(XML)
        self.assertEqual(["Sales Sheet"], worksheets)
        self.assertEqual(
            {"Executive Dashboard": ["Sales Sheet"]},
            dashboards,
        )

    def test_workbook_xml_extracts_twbx_without_inflating_hyper(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive_path = Path(tmp) / "fixture.twbx"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("Workbook.twb", XML)
                archive.writestr("Data/extract.hyper", b"not-a-real-hyper")
            out = Path(tmp) / "out"
            out.mkdir()
            xml, has_extract = tableau_discover.workbook_xml(
                archive_path.read_bytes(), out
            )
            self.assertIn("<workbook>", xml)
            self.assertTrue(has_extract)
            self.assertTrue((out / "workbook-content.twb").is_file())

    def test_discovery_writes_contract_artifacts(self):
        api = tableau_discover.tableau
        saved = {
            name: getattr(api, name)
            for name in (
                "refresh_token",
                "find_workbook_by_name",
                "get_workbook",
                "download_workbook_content",
                "graphql_workbook_dashboards",
                "view_data",
                "view_image",
            )
        }
        self.addCleanup(
            lambda: [setattr(api, name, value) for name, value in saved.items()]
        )
        api.refresh_token = lambda: "token"
        api.find_workbook_by_name = lambda name: {"id": "wb1", "name": name}
        api.get_workbook = lambda _id: {
            "id": "wb1",
            "name": "Fixture",
            "views": {
                "view": [
                    {"id": "sheet1", "name": "Sales Sheet"},
                    {"id": "dash1", "name": "Executive Dashboard"},
                ]
            },
        }
        api.download_workbook_content = lambda _id: XML.encode()
        api.graphql_workbook_dashboards = lambda _id: [
            {
                "name": "Executive Dashboard",
                "sheets": [{"name": "Sales Sheet", "luid": "sheet1"}],
            }
        ]
        api.view_data = lambda view_id: f"id,value\n{view_id},1\n"
        api.view_image = lambda _id: b"\x89PNG\r\nfixture"

        with tempfile.TemporaryDirectory() as tmp:
            args = argparse.Namespace(
                workbook_name="Fixture",
                workbook_id=None,
                dashboard=["Executive Dashboard"],
                datasource_name=None,
                datasource_luid=None,
                out=tmp,
                pool=2,
                skip_images=False,
                skip_content=False,
            )
            result = tableau_discover.discover(args)
            out = Path(tmp)
            self.assertEqual(1, result["csv_views"])
            self.assertTrue((out / "get-workbook.json").is_file())
            self.assertTrue((out / "workbook-content.twb").is_file())
            self.assertTrue((out / "views" / "sheet1.csv").is_file())
            self.assertTrue(
                (out / "dashboards" / "Executive-Dashboard.png").is_file()
            )
            timings = json.loads((out / "timings.json").read_text())
            self.assertTrue(any(row["task"] == "twb-download" for row in timings))


if __name__ == "__main__":
    unittest.main()
