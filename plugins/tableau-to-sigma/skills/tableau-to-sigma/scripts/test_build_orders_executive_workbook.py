import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "build-orders-executive-workbook.py"
spec = importlib.util.spec_from_file_location("build_orders_workbook", SCRIPT)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class BuildOrdersExecutiveWorkbookTest(unittest.TestCase):
    def setUp(self):
        self.workbook = builder.build("dm-1", "fact-1", "folder-1")
        self.elements = {
            element["id"]: element
            for element in self.workbook["document"]["elements"]
        }

    def test_builds_source_dashboard_inventory(self):
        self.assertEqual(12, len(self.elements))
        self.assertEqual(
            {
                "kpi-chart": 5,
                "line-chart": 1,
                "bar-chart": 3,
                "table": 1,
                "text": 1,
                "container": 1,
            },
            {
                kind: sum(1 for item in self.elements.values() if item["kind"] == kind)
                for kind in {item["kind"] for item in self.elements.values()}
            },
        )

    def test_master_uses_posted_data_model_and_repaired_order_date(self):
        master = self.elements["orders-master"]
        self.assertEqual(
            {
                "kind": "data-model",
                "dataModelId": "dm-1",
                "elementId": "fact-1",
            },
            master["source"],
        )
        formulas = {column["name"]: column["formula"] for column in master["columns"]}
        self.assertEqual(
            "[ORDER_FACT/DATE_DIM (Order Date)/Full Date]",
            formulas["Order Date"],
        )
        self.assertIn("Customer Lifetime Revenue", formulas["Customer Value Tier"])

    def test_kpis_preserve_source_aggregations(self):
        self.assertEqual(
            "CountDistinct([Orders Data/Order Id])",
            self.elements["kpi-total-orders"]["columns"][0]["formula"],
        )
        self.assertEqual(
            "Sum([Orders Data/Is Returned]) / Count([Orders Data/Order Id])",
            self.elements["kpi-return-rate"]["columns"][0]["formula"],
        )

    def test_layout_places_each_element_once(self):
        builder.validate(self.workbook)


if __name__ == "__main__":
    unittest.main()
