import json
import tempfile
import unittest
from pathlib import Path

import tableau_source


MIXED_TWB = """\
<workbook>
  <datasources>
    <datasource caption="Sample Extract" name="federated.extract">
      <connection class="federated">
        <named-connections>
          <named-connection name="embedded">
            <connection class="hyper" dbname="Data/Sample.hyper"/>
          </named-connection>
          <named-connection name="basemap">
            <connection class="MapBox"/>
          </named-connection>
        </named-connections>
        <relation name="Orders" table="[Extract].[Extract]" type="table"/>
      </connection>
    </datasource>
    <datasource caption="Published Finance" name="sqlproxy.finance">
      <connection class="sqlproxy" dbname="FinancePDS">
        <relation name="sqlproxy" table="[sqlproxy]" type="table"/>
      </connection>
    </datasource>
  </datasources>
</workbook>
"""


def converted_model():
    def element(element_id, columns):
        return {
            "id": element_id,
            "name": "Extract",
            "source": {
                "kind": "warehouse-table",
                "connectionId": "conn",
                "path": ["OLD", "PUBLIC", "EXTRACT"],
            },
            "columns": [
                {
                    "id": f"{element_id}-{index}",
                    "name": name,
                    "formula": f"[EXTRACT/{name}]",
                }
                for index, name in enumerate(columns)
            ],
        }

    return {
        "pages": [
            {
                "elements": [
                    element("sales", ["Region", "Sales"]),
                    element("people", ["Employee", "Department"]),
                ]
            }
        ]
    }


class TableauSourceTest(unittest.TestCase):
    def classify(self, xml=MIXED_TWB):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "workbook.twb"
        path.write_text(xml, encoding="utf-8")
        return tableau_source.classify_workbook(path)

    def test_sqlproxy_sibling_does_not_suppress_embedded_sibling(self):
        result = self.classify()
        self.assertEqual("mixed", result["classification"])
        by_name = {item["name"]: item for item in result["datasources"]}
        embedded = by_name["federated.extract"]
        published = by_name["sqlproxy.finance"]
        self.assertEqual("embedded-file-extract", embedded["classification"])
        self.assertEqual(["hyper"], embedded["effective_classes"])
        self.assertIn("mapbox", embedded["ignored_classes"])
        self.assertEqual(["Sample.hyper"], embedded["hyper_files"])
        self.assertEqual("published-sqlproxy", published["classification"])

    def test_live_warehouse_and_unsupported_have_evidence(self):
        live = self.classify(
            """<workbook><datasources>
            <datasource name="live"><connection class="snowflake"
              server="acct.snowflakecomputing.com" dbname="ANALYTICS">
              <relation type="table" table="[ANALYTICS].[PUBLIC].[ORDERS]"/>
            </connection></datasource>
            <datasource name="unknown"><connection class="federated"/></datasource>
            </datasources></workbook>"""
        )
        by_name = {item["name"]: item for item in live["datasources"]}
        self.assertEqual("live-warehouse", by_name["live"]["classification"])
        self.assertEqual(["snowflake"], by_name["live"]["live_classes"])
        self.assertTrue(by_name["live"]["evidence"]["has_real_relation"])
        self.assertEqual("unsupported", by_name["unknown"]["classification"])

    def test_empty_or_unattributed_manifest_never_satisfies_coverage(self):
        result = self.classify()
        self.assertFalse(
            tableau_source.validate_manifest_coverage(result, [])["valid"]
        )
        wrong = [
            {
                "datasource": "some-other-source",
                "sf_table": "DB.S.LANDED",
                "columns": {"Region": "REGION"},
            }
        ]
        coverage = tableau_source.validate_manifest_coverage(result, wrong)
        self.assertFalse(coverage["valid"])
        self.assertEqual(["federated.extract"], coverage["missing_datasources"])

    def test_manifest_remap_attributes_distinct_elements_and_rewrites_refs(self):
        model = converted_model()
        manifest = [
            {
                "datasource": "federated.sales",
                "caption": "Sales",
                "sf_table": "DB.LANDING.SALES_FACT",
                "columns": {"Region": "REGION", "Sales": "SALES"},
            },
            {
                "datasource": "federated.people",
                "caption": "People",
                "sf_table": "DB.LANDING.PEOPLE_DIM",
                "columns": {
                    "Employee": "EMPLOYEE",
                    "Department": "DEPARTMENT",
                },
            },
        ]
        result = tableau_source.remap_from_manifest(model, manifest)
        self.assertEqual(2, result["elements"])
        elements = model["pages"][0]["elements"]
        self.assertEqual(
            ["DB", "LANDING", "SALES_FACT"],
            elements[0]["source"]["path"],
        )
        self.assertEqual("[SALES_FACT/SALES]", elements[0]["columns"][1]["formula"])
        self.assertEqual(
            ["DB", "LANDING", "PEOPLE_DIM"],
            elements[1]["source"]["path"],
        )
        self.assertEqual(
            {"federated.sales", "federated.people"},
            {
                entry["datasource"]
                for entry in result["used_manifest_entries"]
            },
        )

    def test_manifest_remap_rewrites_single_table_sql_columns(self):
        model = converted_model()
        model["pages"][0]["elements"] = [
            model["pages"][0]["elements"][0],
            {
                "id": "helper",
                "name": "Fixed Sales",
                "source": {
                    "kind": "sql",
                    "statement": (
                        'SELECT "Region", SUM("Sales") FROM "Extract" '
                        'GROUP BY "Region"'
                    ),
                },
                "columns": [],
            },
        ]
        manifest = [
            {
                "datasource": "federated.sales",
                "sf_table": "DB.LANDING.SALES_FACT",
                "columns": {"Region": "REGION", "Sales": "SALES"},
            }
        ]
        result = tableau_source.remap_from_manifest(model, manifest)
        statement = model["pages"][0]["elements"][1]["source"]["statement"]
        self.assertEqual(1, result["sql_elements"])
        self.assertIn("FROM DB.LANDING.SALES_FACT", statement)
        self.assertIn("SUM(SALES)", statement)
        self.assertIn("GROUP BY REGION", statement)

    def test_classifier_cli_contract_is_json_serializable(self):
        result = self.classify()
        self.assertIsInstance(json.dumps(result), str)


if __name__ == "__main__":
    unittest.main()
