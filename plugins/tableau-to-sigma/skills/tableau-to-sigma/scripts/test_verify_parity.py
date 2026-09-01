import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "verify-parity.py"
spec = importlib.util.spec_from_file_location("verify_parity", SCRIPT)
verify_parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_parity)


class VerifyParityTest(unittest.TestCase):
    def test_nested_values_match_with_numeric_tolerance(self):
        differences = verify_parity.compare(
            {"kpis": {"rate": 0.017475728}, "rows": [["West", 56803.0]]},
            {"kpis": {"rate": 0.017476}, "rows": [["West", 56803]]},
            abs_tol=1e-6,
        )
        self.assertEqual([], differences)

    def test_missing_and_changed_values_fail(self):
        differences = verify_parity.compare(
            {"kpis": {"orders": 1025, "revenue": 159357.97}},
            {"kpis": {"orders": 1024}},
        )
        self.assertEqual({"missing", "number"}, {item["kind"] for item in differences})


if __name__ == "__main__":
    unittest.main()
