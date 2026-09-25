#!/usr/bin/env python3
import importlib.util
import tempfile
from pathlib import Path


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "parse_twb_layout", HERE / "parse-twb-layout.py"
)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    twb = root / "source.twb"
    twb.write_text("<workbook/>", encoding="utf-8")
    parser = module.TableauLayoutParser(twb, root / "layout.json")

    slash = parser.parse_shelf(
        "[federated.fact].[none:Weekly/Monthly Verification TS EST:ok]"
    )
    assert len(slash["fields"]) == 1, slash
    assert slash["fields"][0]["guid"] == "Weekly/Monthly Verification TS EST", slash

    nested = parser.parse_shelf(
        "([federated.fact].[none:Region:nk] / "
        "[federated.fact].[none:Weekly/Monthly Period:ok])"
    )
    assert [item["guid"] for item in nested["fields"]] == [
        "Region",
        "Weekly/Monthly Period",
    ], nested

    quick = parser.parse_shelf(
        "[federated.fact].[pcto:sum:MEASURE_VALUE:qk:2]"
    )
    assert quick["fields"][0]["role"] == "measure", quick
    assert quick["fields"][0]["guid"] == "MEASURE_VALUE", quick

    percent = parser.parse_shelf(
        "[federated.fact].[usr:% of Docs Exceeding TAT:qk]"
    )
    assert percent["fields"][0]["guid"] == "% of Docs Exceeding TAT", percent

print("ALL PASS — Python shelf tokenization preserves slash and nested-prefix fields")
