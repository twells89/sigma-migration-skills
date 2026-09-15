#!/usr/bin/env python3

import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import sql_provenance


def element(element_id, name, statement):
    return {
        "id": element_id,
        "name": name,
        "kind": "table",
        "source": {"kind": "sql", "connectionId": "conn", "statement": statement},
    }


class SqlProvenanceTest(unittest.TestCase):
    def test_source_generated_and_unattributed_sql(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            twb = root / "source.twb"
            dm = root / "dm.json"
            metadata = root / "conv-meta.json"
            twb.write_text(
                """
                <workbook><datasources><datasource><connection>
                  <relation type="text">SELECT order_id, amount FROM orders</relation>
                </connection></datasource></datasources></workbook>
                """,
                encoding="utf-8",
            )
            dm.write_text(
                json.dumps(
                    {
                        "pages": [
                            {
                                "elements": [
                                    element(
                                        "source-sql",
                                        "Source SQL",
                                        "SELECT order_id, amount FROM orders",
                                    ),
                                    element(
                                        "lod",
                                        "Revenue LOD Helper",
                                        "SELECT region, SUM(amount) FROM orders GROUP BY region",
                                    ),
                                    element(
                                        "mystery",
                                        "Mystery",
                                        (
                                            "SELECT secret, COUNT(*) FROM nowhere "
                                            "GROUP BY secret"
                                        ),
                                    ),
                                ]
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            metadata.write_text(
                json.dumps(
                    {
                        "sqlProvenance": [
                            {
                                "elementId": "lod",
                                "originType": "generated-lod",
                                "statement": (
                                    "SELECT region, SUM(amount) FROM orders "
                                    "GROUP BY region"
                                ),
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            result = sql_provenance.evaluate(
                dm, metadata_path=metadata, twb_path=twb
            )
            by_id = {row["element_id"]: row for row in result["sql_elements"]}
            self.assertEqual("source-custom-sql", by_id["source-sql"]["origin_type"])
            self.assertEqual("generated-lod", by_id["lod"]["origin_type"])
            self.assertEqual("fail", result["status"])

            overrides = root / "sql-provenance-overrides.json"
            proof = root / "semantic-proof.json"
            proof.write_text(
                json.dumps({"match": True, "checks": [{"name": "row-count", "match": True}]}),
                encoding="utf-8",
            )
            overrides.write_text(
                json.dumps(
                    {
                        "entries": [
                            {
                                "element_id": "mystery",
                                "origin_type": "generated-manual",
                                "reason": "operator-proven semantic rewrite",
                                "proof": str(proof),
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            result = sql_provenance.evaluate(
                dm,
                metadata_path=metadata,
                twb_path=twb,
                overrides_path=overrides,
            )
            self.assertEqual("pass", result["status"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
