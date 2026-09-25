#!/usr/bin/env python3
import importlib.util
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "build_workbook_from_signals", HERE / "build-workbook-from-signals.py"
)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

builder = object.__new__(module.WorkbookBuilder)
zone = {
    "rows_shelf": {
        "fields": [
            {
                "guid": "Multiple Values",
                "role": "dim",
                "derivation": None,
            }
        ]
    },
    "cols_shelf": {
        "fields": [
            {
                "guid": "Weekly/Monthly Period",
                "role": "dim",
                "derivation": "none",
            }
        ]
    },
    "measures": [
        {"column": "[Metric A]", "derivation": "Sum"},
        {"column": "[Metric B]", "derivation": "Sum"},
    ],
}

dimensions, measures = builder._shelf_fields(zone)
assert [item["guid"] for item in dimensions] == ["Weekly/Monthly Period"], dimensions
assert [item["guid"] for item in measures] == ["Metric A", "Metric B"], measures
print("ALL PASS — Python Measure Values builder drops pseudo fields and keeps measures")
