#!/usr/bin/env python3
"""Unit tests for converter/sigma_ids.py — id generation + the
sigma_display_name() derivation rule this family ports byte-for-byte from
sigma-ids.ts (must match Sigma's OWN internal derivation or cross-element
formula refs compile to type "error" at POST time, beads-sigma-c31q).

Offline, stdlib only. Run: python3 tests/test_sigma_ids.py   (exit 0 = pass)
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
CONVERTER = os.path.join(SKILL, "converter")
sys.path.insert(0, CONVERTER)

import sigma_ids  # noqa: E402


def test_reset_ids_clears_registry():
    sigma_ids.reset_ids()
    sigma_ids.sigma_short_id()
    sigma_ids.sigma_short_id()
    assert len(sigma_ids._used_ids) == 2
    sigma_ids.reset_ids()
    assert len(sigma_ids._used_ids) == 0


def test_sigma_short_id_length_and_charset():
    sigma_ids.reset_ids()
    ident = sigma_ids.sigma_short_id(10)
    assert len(ident) == 10
    assert re.fullmatch(r"[A-Za-z0-9]+", ident)
    ident22 = sigma_ids.sigma_short_id(22)
    assert len(ident22) == 22


def test_sigma_short_id_uniqueness():
    sigma_ids.reset_ids()
    ids = {sigma_ids.sigma_short_id() for _ in range(500)}
    assert len(ids) == 500


def test_sigma_inode_id_format():
    sigma_ids.reset_ids()
    inode = sigma_ids.sigma_inode_id("order_id")
    m = re.fullmatch(r"inode-([A-Za-z0-9]{22})/(.+)", inode)
    assert m, inode
    assert m.group(2) == "ORDER_ID"  # identifier uppercased


def test_sigma_display_name_docstring_examples():
    assert sigma_ids.sigma_display_name("CY_Q1_REVENUE") == "Cy Q 1 Revenue"
    assert sigma_ids.sigma_display_name("FY2024") == "Fy 2024"


def test_sigma_display_name_camel_case():
    assert sigma_ids.sigma_display_name("someFieldName") == "Some Field Name"


def test_sigma_display_name_stopwords_only_mid_name():
    # "of" is a stopword but must capitalize when it's the FIRST or LAST word.
    assert sigma_ids.sigma_display_name("cost_of_goods") == "Cost of Goods"
    assert sigma_ids.sigma_display_name("of_the_people") == "Of the People"


def test_sigma_display_name_idempotent():
    for raw in ("CY_Q1_REVENUE", "someFieldName", "cost_of_goods", "Brand ID"):
        once = sigma_ids.sigma_display_name(raw)
        twice = sigma_ids.sigma_display_name(once)
        assert once == twice, (raw, once, twice)


def test_sigma_display_name_handles_none():
    assert sigma_ids.sigma_display_name(None) == ""


def test_sigma_col_formula():
    assert sigma_ids.sigma_col_formula("ORDERS", "order_id") == "[ORDERS/Order Id]"


def test_sigma_agg_formula_known_and_fallback():
    assert sigma_ids.sigma_agg_formula("sum", "revenue") == "Sum([Revenue])"
    assert sigma_ids.sigma_agg_formula("count_distinct", "customer_id") == "CountDistinct([Customer Id])"
    assert sigma_ids.sigma_agg_formula("SUM", "revenue") == "Sum([Revenue])"  # case-insensitive
    assert sigma_ids.sigma_agg_formula(None, "revenue") == "Sum([Revenue])"  # unset -> Sum
    assert sigma_ids.sigma_agg_formula("nonsense", "revenue") == "Sum([Revenue])"  # unknown -> Sum


def test_infer_sigma_format_currency_percent_number_and_none():
    assert sigma_ids.infer_sigma_format("sum", None) is None
    usd = sigma_ids.infer_sigma_format("sum", {"format": "CURRENCY", "numDecimalDigits": 2})
    assert usd == {"kind": "number", "formatString": "$,.2f", "currencySymbol": "$"}
    eur = sigma_ids.infer_sigma_format("sum", {"format": "CURRENCY", "currency": "EUR", "numDecimalDigits": 0})
    assert eur["currencySymbol"] == "€" and eur["formatString"] == "€,.0f"
    gbp = sigma_ids.infer_sigma_format("sum", {"format": "CURRENCY", "currency": "GBP"})
    assert gbp["currencySymbol"] == "£"
    unknown_currency = sigma_ids.infer_sigma_format("sum", {"format": "CURRENCY", "currency": "ZZZ"})
    assert unknown_currency["currencySymbol"] == "$"  # unrecognized code falls back to $
    pct = sigma_ids.infer_sigma_format("sum", {"format": "PERCENT", "numDecimalDigits": 1})
    assert pct == {"kind": "number", "formatString": ",.1%"}
    num = sigma_ids.infer_sigma_format("sum", {"format": "NUMBER", "numDecimalDigits": -1})
    assert num == {"kind": "number", "formatString": ",.2f"}  # negative decimals clamp to 2
    assert sigma_ids.infer_sigma_format("sum", {"format": "TEXT"}) is None  # unsupported format -> None


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted((n, f) for n, f in globals().items() if n.startswith("test_")):
        try:
            fn()
            print(f"ok  {name}")
        except AssertionError as e:
            fails += 1
            print(f"FAIL {name}: {e}")
    sys.exit(1 if fails else 0)
