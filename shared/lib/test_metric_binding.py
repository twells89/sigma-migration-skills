#!/usr/bin/env python3
"""Unit test for metric_binding.py — the shared workbook↔DM-metric binder.
Stdlib only; run directly:  python3 shared/lib/test_metric_binding.py

Semantics mirror the looker reference (PR #484) that this helper was extracted
from: a measure whose inline aggregate matches a metric on (or inherited by) the
source element binds to [Metrics/<name>]; everything else — ratios, filtered,
custom, no match, empty metrics, non-string input — falls back to inline.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import metric_binding as mb  # noqa: E402


class MetricRefOrInlineTest(unittest.TestCase):
    METRICS = [
        {"name": "Net Revenue", "formula": "Sum([Net Revenue])"},
        {"name": "Orders", "formula": "CountDistinct([Order Id])"},
    ]

    def test_matched_aggregate_binds_to_metric(self):
        self.assertEqual(
            mb.metric_ref_or_inline("Sum([Data/Net Revenue])", "Data", self.METRICS),
            "[Metrics/Net Revenue]")
        self.assertEqual(
            mb.metric_ref_or_inline("CountDistinct([Data/Order Id])", "Data", self.METRICS),
            "[Metrics/Orders]")

    def test_whitespace_insensitive_match(self):
        # extra whitespace on either side must not defeat the match
        self.assertEqual(
            mb.metric_ref_or_inline("Sum( [Data/Net Revenue] )", "Data", self.METRICS),
            "[Metrics/Net Revenue]")

    def test_strips_every_master_prefix(self):
        # a ratio of two master refs, matched against a metric with no prefix
        mets = [{"name": "AOV", "formula": "Sum([Net Revenue]) / Sum([Order Id])"}]
        self.assertEqual(
            mb.metric_ref_or_inline("Sum([Data/Net Revenue]) / Sum([Data/Order Id])", "Data", mets),
            "[Metrics/AOV]")

    def test_ratio_without_metric_falls_back(self):
        got = mb.metric_ref_or_inline("1.0 * Sum([Data/Net Revenue]) / Count([Data/Order Id])",
                                      "Data", self.METRICS)
        self.assertEqual(got, "1.0 * Sum([Data/Net Revenue]) / Count([Data/Order Id])")

    def test_nonmatching_metric_ignored(self):
        mets = [{"name": "Unrelated", "formula": "Sum([Something Else])"}]
        self.assertEqual(
            mb.metric_ref_or_inline("Sum([Data/Net Revenue])", "Data", mets),
            "Sum([Data/Net Revenue])")

    def test_empty_metrics_is_noop(self):
        self.assertEqual(mb.metric_ref_or_inline("Sum([Data/x])", "Data", []),
                         "Sum([Data/x])")
        self.assertEqual(mb.metric_ref_or_inline("Sum([Data/x])", "Data", None),
                         "Sum([Data/x])")

    def test_non_string_inline_passthrough(self):
        self.assertIsNone(mb.metric_ref_or_inline(None, "Data", self.METRICS))
        self.assertEqual(mb.metric_ref_or_inline(42, "Data", self.METRICS), 42)

    def test_metric_missing_formula_or_name_skipped(self):
        mets = [{"name": "NoFormula"}, {"formula": "Sum([Data/x])"},
                {"name": "Good", "formula": "Sum([x])"}]
        self.assertEqual(mb.metric_ref_or_inline("Sum([Data/x])", "Data", mets),
                         "[Metrics/Good]")


class AvailableMetricsTest(unittest.TestCase):
    def test_own_metrics(self):
        els = {"a": {"metrics": [{"name": "M1", "formula": "Sum([x])"}]}}
        got = mb.available_metrics("a", els)
        self.assertEqual(got, [{"name": "M1", "formula": "Sum([x])"}])

    def test_inherited_via_source_chain(self):
        # denorm 'View' element carries 0 own metrics but inherits its base fact's
        els = {
            "view": {"metrics": [], "source": {"elementId": "fact"}},
            "fact": {"metrics": [{"name": "Net Revenue", "formula": "Sum([Net Revenue])"}]},
        }
        got = mb.available_metrics("view", els)
        self.assertEqual(got, [{"name": "Net Revenue", "formula": "Sum([Net Revenue])"}])

    def test_nearest_wins_on_name_collision(self):
        els = {
            "view": {"metrics": [{"name": "M", "formula": "OWN"}], "source": {"elementId": "fact"}},
            "fact": {"metrics": [{"name": "M", "formula": "INHERITED"}]},
        }
        got = mb.available_metrics("view", els)
        self.assertEqual(got, [{"name": "M", "formula": "OWN"}])

    def test_skips_metrics_missing_fields(self):
        els = {"a": {"metrics": [{"name": "OnlyName"}, {"formula": "OnlyFormula"},
                                 {"name": "Ok", "formula": "Sum([x])"}]}}
        self.assertEqual(mb.available_metrics("a", els),
                         [{"name": "Ok", "formula": "Sum([x])"}])

    def test_cycle_safe(self):
        els = {"a": {"metrics": [{"name": "A", "formula": "f"}], "source": {"elementId": "b"}},
               "b": {"metrics": [{"name": "B", "formula": "g"}], "source": {"elementId": "a"}}}
        got = mb.available_metrics("a", els)
        self.assertEqual([m["name"] for m in got], ["A", "B"])

    def test_missing_element_and_none(self):
        self.assertEqual(mb.available_metrics("nope", {"a": {}}), [])
        self.assertEqual(mb.available_metrics(None, {"a": {}}), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
