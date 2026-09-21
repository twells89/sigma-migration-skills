#!/usr/bin/env python3

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "scripts"
    / "migrate_csv_data_model.py"
)
SPEC = importlib.util.spec_from_file_location("migrate_csv_data_model", SCRIPT)
MIGRATE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = MIGRATE
SPEC.loader.exec_module(MIGRATE)


def source_spec():
    csv_inode = "11111111-2222-3333-4444-555555555555"
    return {
        "dataModelId": "source-model-id",
        "name": "Regional Sales",
        "folderId": "source-folder-id",
        "ownerId": "source-owner-id",
        "documentVersion": 7,
        "schemaVersion": 1,
        "kind": "data-model",
        "pages": [
            {
                "id": "page-a",
                "name": "Main",
                "elements": [
                    {
                        "id": "csv-sales",
                        "kind": "table",
                        "source": {
                            "kind": "csv-table",
                            "connectionId": "source-connection",
                            "inodeId": csv_inode,
                        },
                        "columns": [
                            {
                                "id": f"{csv_inode}/order_id",
                                "formula": "[regional_sales.csv/order_id]",
                            },
                            {
                                "id": f"{csv_inode}/net_revenue",
                                "formula": "[regional_sales.csv/net_revenue]",
                            },
                            {
                                "id": "calculated-margin",
                                "name": "Revenue Copy",
                                "formula": "[Net Revenue]",
                            },
                        ],
                        "order": [
                            f"{csv_inode}/order_id",
                            f"{csv_inode}/net_revenue",
                            "calculated-margin",
                        ],
                    },
                    {
                        "id": "control-a",
                        "kind": "control",
                        "control": {
                            "type": "date",
                            "dateColumnId": f"{csv_inode}/order_id",
                        },
                    },
                ],
            }
        ],
    }


def resolved_source():
    return MIGRATE.ResolvedSource(
        source_element_id="csv-sales",
        source_connection_id="source-connection",
        target_connection_id="target-connection",
        physical_relation="analytics.writeback.sigma_df_csv_example",
        statement=(
            "select order_id, net_revenue "
            "from analytics.writeback.sigma_df_csv_example Q1"
        ),
    )


class MigrationTransformTest(unittest.TestCase):
    def test_inspect_reports_csv_source_and_columns(self):
        report = MIGRATE.inspect_report(
            source_spec(),
            {
                "csv-sales": {
                    "statement": resolved_source().statement,
                    "physicalRelation": resolved_source().physical_relation,
                }
            },
        )

        self.assertEqual(report["csvSourceCount"], 1)
        source = report["csvSources"][0]
        self.assertEqual(source["sourceElementId"], "csv-sales")
        self.assertEqual(source["csvName"], "regional_sales.csv")
        self.assertEqual(source["columns"], ["order_id", "net_revenue"])
        self.assertEqual(
            source["physicalRelation"],
            "analytics.writeback.sigma_df_csv_example",
        )

    def test_plan_repoints_source_and_all_exact_id_references(self):
        planned, report = MIGRATE.plan_spec(
            source_spec(),
            [resolved_source()],
            target_folder_id="target-folder",
            target_name="Regional Sales Migrated",
        )

        self.assertEqual(
            set(planned),
            {"name", "folderId", "schemaVersion", "pages"},
        )
        self.assertEqual(planned["folderId"], "target-folder")
        self.assertEqual(planned["name"], "Regional Sales Migrated")
        table = planned["pages"][0]["elements"][0]
        self.assertEqual(
            table["source"],
            {
                "kind": "sql",
                "connectionId": "target-connection",
                "statement": (
                    "select order_id, net_revenue "
                    "from analytics.writeback.sigma_df_csv_example Q1"
                ),
            },
        )
        self.assertEqual(
            table["columns"][0],
            {
                "id": "sql-csv-sales-1",
                "formula": "[Custom SQL/order_id]",
            },
        )
        self.assertEqual(
            table["columns"][1],
            {
                "id": "sql-csv-sales-2",
                "formula": "[Custom SQL/net_revenue]",
            },
        )
        self.assertEqual(
            table["columns"][2],
            {
                "id": "calculated-margin",
                "name": "Revenue Copy",
                "formula": "[Net Revenue]",
            },
        )
        self.assertEqual(
            table["order"],
            [
                "sql-csv-sales-1",
                "sql-csv-sales-2",
                "calculated-margin",
            ],
        )
        control = planned["pages"][0]["elements"][1]
        self.assertEqual(
            control["control"]["dateColumnId"], "sql-csv-sales-1"
        )
        self.assertTrue(report["readyToCreate"])
        self.assertEqual(report["sources"][0]["migratedColumnCount"], 2)
        self.assertEqual(
            report["sources"][0]["physicalRelation"],
            "analytics.writeback.sigma_df_csv_example",
        )

    def test_generated_sql_is_sanitized_and_relation_is_extracted(self):
        generated = (
            "select order_id, net_revenue "
            "from analytics.writeback.sigma_df_csv_example Q1 limit 1000\n\n"
            '-- Sigma Σ {"request-id":"request-id","email":"user@example.com"}'
        )

        statement = MIGRATE.sanitize_generated_sql(generated)

        self.assertEqual(
            statement,
            "select order_id, net_revenue "
            "from analytics.writeback.sigma_df_csv_example Q1",
        )
        self.assertEqual(
            MIGRATE.physical_relation_from_sql(statement),
            "analytics.writeback.sigma_df_csv_example",
        )

    def test_generated_sql_rejects_multiple_statements(self):
        with self.assertRaisesRegex(MIGRATE.MigrationError, "multiple statements"):
            MIGRATE.sanitize_generated_sql(
                "select * from catalog.schema.table; drop table other"
            )

    def test_plan_requires_one_mapping_per_csv_element(self):
        with self.assertRaisesRegex(
            MIGRATE.MigrationError, "unmapped CSV elements: csv-sales"
        ):
            MIGRATE.plan_spec(
                source_spec(), [], target_folder_id="target-folder"
            )

    def test_resolve_sources_discovers_query_and_checks_databricks_host(self):
        class FakeClient:
            def __init__(self, responses):
                self.responses = responses

            def get(self, path):
                return self.responses[path]

        source = FakeClient(
            {
                (
                    "/v2/dataModels/source-model-id/elements/"
                    "csv-sales/query"
                ): {
                    "sql": (
                        "select order_id, net_revenue "
                        "from analytics.writeback.sigma_df_csv_example Q1 "
                        "limit 1000"
                    )
                },
                "/v2/connections/source-connection": {
                    "type": "databricks",
                    "host": "workspace.cloud.databricks.com",
                },
            }
        )
        target = FakeClient(
            {
                "/v2/connections/target-connection": {
                    "type": "databricks",
                    "host": "workspace.cloud.databricks.com",
                }
            }
        )

        resolved = MIGRATE.resolve_sources(
            source,
            target,
            source_spec(),
            [
                {
                    "sourceElementId": "csv-sales",
                    "targetConnectionId": "target-connection",
                }
            ],
        )

        self.assertEqual(resolved, [resolved_source()])

    def test_model_url_extracts_public_id(self):
        result = MIGRATE.parse_model_ref(
            "https://app.sigmacomputing.com/example/data-model/"
            "Regional-Sales-AbCdEf1234567890GhIjKl"
        )
        self.assertEqual(result, "AbCdEf1234567890GhIjKl")

    def test_rtf_credential_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "credentials.env"
            path.write_text(r"{\rtf1\ansi not-an-env-file}", encoding="utf-8")

            with self.assertRaisesRegex(MIGRATE.MigrationError, "RTF document"):
                MIGRATE.load_credentials(path)


if __name__ == "__main__":
    unittest.main()
