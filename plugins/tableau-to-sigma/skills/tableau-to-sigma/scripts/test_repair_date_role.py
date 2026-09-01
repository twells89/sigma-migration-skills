import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "repair-date-role.py"
spec = importlib.util.spec_from_file_location("repair_date_role", SCRIPT)
repair_date_role = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair_date_role)


def fixture():
    model = {
        "pages": [
            {
                "elements": [
                    {
                        "id": "fact",
                        "name": "ORDER_FACT",
                        "source": {"path": ["CSA", "TJ", "ORDER_FACT"]},
                        "columns": [
                            {"id": "order-date-key", "name": "Order Date Key", "formula": "[ORDER_FACT/ORDER_DATE_KEY]"}
                        ],
                    },
                    {
                        "id": "date-return",
                        "name": "DATE_DIM (Return Date)",
                        "source": {"path": ["CSA", "TJ", "DATE_DIM"]},
                        "columns": [
                            {"id": "date-key", "name": "Date Key", "formula": "[DATE_DIM/DATE_KEY]"},
                            {"id": "full-date", "name": "Full Date", "formula": "[DATE_DIM/FULL_DATE]"},
                        ],
                        "order": ["date-key", "full-date"],
                    },
                    {
                        "id": "time",
                        "name": "DIM_TIME",
                        "source": {"path": ["CSA", "TJ", "DIM_TIME"]},
                        "columns": [
                            {"id": "time-key", "name": "Date Key", "formula": "[DIM_TIME/DATE_KEY]"}
                        ],
                    },
                ]
            }
        ]
    }
    metadata = {
        "warnings": [
            "⚠ Relationship ORDER_FACT → DIM_TIME joins only on computed key(s) — NOT wired.",
            "⚠ Object-model: logical table \"DIM_TIME\" has NO wired relationship.",
        ],
        "workbookPatterns": [
            {
                "kind": "unsupported",
                "name": "Object-model relationship ORDER_FACT ↔ DIM_TIME (computed-only-key)",
            },
            {
                "kind": "unsupported",
                "name": "Object-model table DIM_TIME disconnected",
            },
        ],
        "relationshipCoverage": {
            "wired": 0,
            "entries": [
                {
                    "left": "ORDER_FACT",
                    "right": "DIM_TIME",
                    "derivedVia": "unwired",
                }
            ],
        },
    }
    return model, metadata


class RepairDateRoleTest(unittest.TestCase):
    def test_repair_requires_measured_match(self):
        model, metadata = fixture()
        with self.assertRaisesRegex(ValueError, "match=true"):
            repair_date_role.repair(
                model,
                metadata,
                {"match": False, "checks": {"rows": "mismatch"}},
                source_element="ORDER_FACT",
                source_key="Order Date Key",
                template_element="DATE_DIM (Return Date)",
                replace_element="DIM_TIME",
                role_name="DATE_DIM (Order Date)",
            )

    def test_repair_reuses_element_id_and_adds_proven_relationship(self):
        model, metadata = fixture()
        repaired, repaired_meta, report = repair_date_role.repair(
            model,
            metadata,
            {"match": True, "checks": {"row_count": [1030, 1030]}},
            source_element="ORDER_FACT",
            source_key="Order Date Key",
            template_element="DATE_DIM (Return Date)",
            replace_element="DIM_TIME",
            role_name="DATE_DIM (Order Date)",
        )
        rows = repair_date_role.elements(repaired)
        order_date = next(row for row in rows if row.get("name") == "DATE_DIM (Order Date)")
        self.assertEqual("time", order_date["id"])
        self.assertEqual(["CSA", "TJ", "DATE_DIM"], order_date["source"]["path"])
        fact = next(row for row in rows if row.get("name") == "ORDER_FACT")
        relationship = fact["relationships"][0]
        self.assertEqual("time", relationship["targetElementId"])
        self.assertEqual("equivalence-proof", relationship["derivedVia"])
        self.assertFalse(repaired_meta["workbookPatterns"])
        self.assertTrue(report["match"])


if __name__ == "__main__":
    unittest.main()
