import importlib.util
import io
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import published_datasource as pds
import tableau_source

HERE = Path(__file__).resolve().parent
MIGRATE_SCRIPT = HERE / "migrate-tableau.py"
spec = importlib.util.spec_from_file_location("migrate_tableau_pds_test", MIGRATE_SCRIPT)
migrate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migrate)


def workbook(datasources: str) -> str:
    return f"""<?xml version="1.0" encoding="utf-8"?>
<workbook>
  <datasources>{datasources}</datasources>
  <worksheets>
    <worksheet name="Sheet"><table><view datasource="federated.pub"/></table></worksheet>
  </worksheets>
</workbook>
"""


PUBLISHED = """
    <datasource name="federated.pub" caption="Published Orders" inline="true">
      <repository-location id="orders-content"/>
      <connection class="sqlproxy" dbname="orders-content" server="tableau">
        <relation name="sqlproxy" type="table" table="[sqlproxy]"/>
        <metadata-records>
          <metadata-record class="column">
            <remote-name>Order ID</remote-name>
            <local-name>[Order ID]</local-name>
            <local-type>integer</local-type>
            <caption>Order ID</caption>
          </metadata-record>
        </metadata-records>
      </connection>
      <column name="[Profit Ratio]" caption="Profit Ratio">
        <calculation formula="[Profit] / [Sales]"/>
      </column>
    </datasource>
"""


TABLE_TDS = b"""<datasource>
  <connection class="snowflake" dbname="ANALYTICS" schema="PUBLIC">
    <relation name="ORDERS" type="table" table="[PUBLIC].[ORDERS]"/>
  </connection>
</datasource>"""


CUSTOM_SQL_TDS = b"""<datasource>
  <connection class="snowflake" dbname="RAW" schema="INGEST">
    <relation name="Orders SQL" type="text">SELECT "Order ID", SUM(amount) AS "Total Sales" FROM raw.orders GROUP BY "Order ID"</relation>
  </connection>
</datasource>"""


class FakeTableau:
    def __init__(self, payload=TABLE_TDS, matches=None):
        self.payload = payload
        self.matches = (
            [{"id": "pds-1", "name": "Published Orders", "contentUrl": "orders-content"}]
            if matches is None
            else matches
        )
        self.lookups = []
        self.downloads = []

    def find_datasources_by_content_url(self, content_url):
        self.lookups.append(content_url)
        return self.matches

    def download_datasource_content(self, datasource_id):
        self.downloads.append(datasource_id)
        return self.payload


class PublishedDatasourceTest(unittest.TestCase):
    def workdir(self, xml=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "workbook-content.twb").write_text(
            xml or workbook(PUBLISHED), encoding="utf-8"
        )
        return root

    def hydrate(self, root, api):
        return pds.resolve_and_hydrate(
            root / "workbook-content.twb",
            root / "workbook-hydrated.twb",
            descriptors_path=root / "pds.json",
            lineage_path=root / "published-datasource-lineage.json",
            evidence_path=root / "published-datasource-hydration.json",
            api=api,
        )

    def test_physical_table_resolves_by_rest_and_preserves_identity_and_calculation(self):
        root = self.workdir()
        api = FakeTableau()
        with mock.patch("subprocess.run", side_effect=AssertionError("subprocess forbidden")):
            result = self.hydrate(root, api)
        self.assertEqual("hydrated", result["status"])
        self.assertEqual(["orders-content"], api.lookups)
        self.assertEqual(["pds-1"], api.downloads)

        hydrated = ET.parse(root / "workbook-hydrated.twb").getroot()
        datasource = hydrated.find("./datasources/datasource")
        connection = datasource.find("./connection")
        relation = connection.find("./relation")
        self.assertEqual("federated.pub", datasource.get("name"))
        self.assertEqual("Published Orders", datasource.get("caption"))
        self.assertEqual("snowflake", connection.get("class"))
        self.assertEqual("[ANALYTICS].[PUBLIC].[ORDERS]", relation.get("table"))
        self.assertEqual(
            "[Profit] / [Sales]",
            datasource.find("./column/calculation").get("formula"),
        )
        self.assertEqual("pass", migrate.load(root / "published-datasource-hydration.json")["status"])
        self.assertEqual("pds-1", migrate.load(root / "pds.json")[0]["pdsLuid"])

    def test_custom_sql_is_wrapped_and_cached_metadata_is_rebuilt(self):
        root = self.workdir()
        result = self.hydrate(root, FakeTableau(payload=CUSTOM_SQL_TDS))
        self.assertEqual("hydrated", result["status"])
        hydrated = ET.parse(root / "workbook-hydrated.twb").getroot()
        datasource = hydrated.find("./datasources/datasource")
        connection = datasource.find("./connection")
        relation = connection.find("./relation")
        self.assertEqual("text", relation.get("type"))
        self.assertIn('"Order ID" AS ORDER_ID', relation.text)
        self.assertIn('"Total Sales" AS TOTAL_SALES', relation.text)
        self.assertIn('SUM(amount) AS "Total Sales"', relation.text)
        records = connection.findall("./metadata-records/metadata-record")
        self.assertEqual(
            ["ORDER_ID", "TOTAL_SALES"],
            [record.findtext("remote-name") for record in records],
        )
        self.assertEqual("integer", records[0].findtext("local-type"))
        self.assertEqual("string", records[1].findtext("local-type"))
        self.assertEqual(
            "[Profit] / [Sales]",
            datasource.find("./column/calculation").get("formula"),
        )

    def test_tdsx_is_read_in_memory_and_records_member_lineage(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("Data/Connections/orders.tds", TABLE_TDS)
            archive.writestr("Data/extract.hyper", b"not-read")
        root = self.workdir()
        result = self.hydrate(root, FakeTableau(payload=stream.getvalue()))
        self.assertEqual("hydrated", result["status"])
        self.assertEqual(
            "Data/Connections/orders.tds",
            result["datasources"][0]["tdsMember"],
        )

    def test_multiple_rest_matches_fail_closed_without_hydrated_output(self):
        root = self.workdir()
        matches = [
            {"id": "one", "name": "One", "contentUrl": "orders-content"},
            {"id": "two", "name": "Two", "contentUrl": "orders-content"},
        ]
        with self.assertRaisesRegex(pds.PublishedDatasourceError, "resolved to 2"):
            self.hydrate(root, FakeTableau(matches=matches))
        self.assertFalse((root / "workbook-hydrated.twb").exists())
        evidence = migrate.load(root / "published-datasource-hydration.json")
        self.assertEqual("failed", evidence["status"])
        self.assertFalse(evidence["hydratedWritten"])

    def test_multiple_relations_and_unresolved_content_url_fail_closed(self):
        ambiguous = b"""<datasource><connection class="snowflake" dbname="DB" schema="S">
          <relation type="table" table="[S].[A]"/>
          <relation type="table" table="[S].[B]"/>
        </connection></datasource>"""
        root = self.workdir()
        with self.assertRaisesRegex(pds.PublishedDatasourceError, "exactly one usable relation"):
            self.hydrate(root, FakeTableau(payload=ambiguous))
        self.assertFalse((root / "workbook-hydrated.twb").exists())

        other = self.workdir()
        with self.assertRaisesRegex(pds.PublishedDatasourceError, "resolved to 0"):
            self.hydrate(other, FakeTableau(matches=[]))
        self.assertFalse((other / "workbook-hydrated.twb").exists())

    def test_tdsx_with_multiple_tds_members_is_ambiguous(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            archive.writestr("one.tds", TABLE_TDS)
            archive.writestr("nested/two.tds", TABLE_TDS)
        root = self.workdir()
        with self.assertRaisesRegex(pds.PublishedDatasourceError, "exactly one .tds"):
            self.hydrate(root, FakeTableau(payload=stream.getvalue()))
        self.assertFalse((root / "workbook-hydrated.twb").exists())

    def test_mixed_sqlproxy_and_embedded_sibling_runs_both_independent_gates(self):
        embedded = """
    <datasource name="federated.extract" caption="Sample Extract">
      <connection class="federated">
        <named-connections><named-connection name="embedded">
          <connection class="hyper" dbname="Data/Sample.hyper"/>
        </named-connection></named-connections>
        <relation name="Extract" type="table" table="[Extract].[Extract]"/>
      </connection>
    </datasource>
"""
        root = self.workdir(workbook(PUBLISHED + embedded))
        classification = tableau_source.classify_workbook(root / "workbook-content.twb")
        conversion_twb, hydration = migrate.published_datasource_gate(
            root, classification, api=FakeTableau()
        )
        self.assertEqual(root / "workbook-hydrated.twb", conversion_twb)
        self.assertEqual("hydrated", hydration["status"])
        self.assertEqual("mixed", classification["classification"])

        migrate.write(
            root / "landing-manifest.json",
            [
                {
                    "datasource": "federated.extract",
                    "caption": "Sample Extract",
                    "hyper": "Sample.hyper",
                    "sf_table": "DB.LANDING.SAMPLE",
                    "columns": {"Region": "REGION"},
                }
            ],
        )
        landing = migrate.extract_landing_gate(
            SimpleNamespace(
                skip_extract_landing=None,
                no_auto_land=True,
                db="DB",
                schema="LANDING",
                connection="sigma-connection",
                name="Mixed",
            ),
            root,
            classification,
        )
        self.assertEqual("landed", landing["status"])
        self.assertEqual(
            ["federated.extract"],
            landing["embedded_datasources"],
        )
        hydrated_xml = (root / "workbook-hydrated.twb").read_text(encoding="utf-8")
        self.assertIn("Data/Sample.hyper", hydrated_xml)
        self.assertNotIn('table="[sqlproxy]"', hydrated_xml)

    def test_python_runtime_contains_no_ruby_subprocess(self):
        source = (HERE / "published_datasource.py").read_text(encoding="utf-8")
        orchestrator = MIGRATE_SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn('["ruby"', source + orchestrator)
        self.assertNotIn("resolve-published-ds.rb", source + orchestrator)
        self.assertNotIn("hydrate-custom-sql.rb", source + orchestrator)


if __name__ == "__main__":
    unittest.main()
