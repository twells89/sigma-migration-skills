#!/usr/bin/env python3

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import relationship_coverage


def metadata(entries):
    return {
        "relationshipCoverage": {
            "serialized": len(entries),
            "wired": sum(row.get("derivedVia") != "unwired" for row in entries),
            "entries": entries,
        }
    }


class RelationshipCoverageTest(unittest.TestCase):
    def test_non_object_graph_without_ledger_is_not_applicable(self):
        result = relationship_coverage.evaluate({}, "<workbook/>")
        self.assertEqual("not-applicable", result["status"])

    def test_object_graph_without_ledger_fails(self):
        result = relationship_coverage.evaluate({}, "<object-graph/>")
        self.assertEqual("fail", result["status"])
        self.assertEqual("coverage-missing", result["blockers"][0]["kind"])

    def test_complete_relationships_pass(self):
        result = relationship_coverage.evaluate(
            metadata(
                [
                    {
                        "left": "FACT",
                        "right": "DIM",
                        "derivedVia": "serialized",
                        "keyCount": 1,
                    }
                ]
            )
        )
        self.assertEqual("pass", result["status"])
        self.assertEqual([], result["blockers"])

    def test_unwired_and_partial_relationships_fail(self):
        result = relationship_coverage.evaluate(
            metadata(
                [
                    {
                        "left": "FACT",
                        "right": "DIM_A",
                        "derivedVia": "unwired",
                        "reason": "no key",
                    },
                    {
                        "left": "FACT",
                        "right": "DIM_B",
                        "derivedVia": "serialized",
                        "partial": True,
                        "droppedConditions": 1,
                    },
                ]
            )
        )
        self.assertEqual("fail", result["status"])
        self.assertEqual(["unwired", "partial"], [row["kind"] for row in result["blockers"]])

    def test_data_model_relationship_count_and_keys_must_match(self):
        meta = metadata(
            [
                {
                    "left": "FACT",
                    "right": "DIM",
                    "derivedVia": "serialized",
                    "keyCount": 1,
                }
            ]
        )
        missing = relationship_coverage.evaluate(
            meta, "<object-graph/>", {"pages": [{"elements": []}]}
        )
        self.assertEqual("fail", missing["status"])
        self.assertIn(
            "model-count-mismatch",
            [row["kind"] for row in missing["blockers"]],
        )
        complete = relationship_coverage.evaluate(
            meta,
            "<object-graph/>",
            {
                "pages": [
                    {
                        "elements": [
                            {
                                "relationships": [
                                    {
                                        "targetElementId": "dim",
                                        "keys": [
                                            {
                                                "sourceColumnId": "fact-key",
                                                "targetColumnId": "dim-key",
                                            }
                                        ],
                                    }
                                ]
                            }
                        ]
                    }
                ]
            },
        )
        self.assertEqual("pass", complete["status"])

    def test_strict_emitter_and_assertion_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            meta = workdir / "conv-meta.json"
            source = workdir / "workbook-content.twb"
            out = workdir / "relationship-coverage.json"
            meta.write_text(
                json.dumps(
                    metadata(
                        [
                            {
                                "left": "FACT",
                                "right": "DIM",
                                "derivedVia": "serialized",
                                "partial": True,
                                "droppedConditions": 1,
                            }
                        ]
                    )
                ),
                encoding="utf-8",
            )
            source.write_text("<object-graph/>", encoding="utf-8")
            emitted = subprocess.run(
                [
                    sys.executable,
                    str(HERE / "emit-relationship-coverage.py"),
                    "--converter-out",
                    str(meta),
                    "--source",
                    str(source),
                    "--out",
                    str(out),
                    "--strict",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(3, emitted.returncode)
            self.assertTrue(out.is_file())
            asserted = subprocess.run(
                [
                    sys.executable,
                    str(HERE / "assert-relationship-coverage.py"),
                    "--workdir",
                    str(workdir),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(3, asserted.returncode)
            self.assertIn("incomplete source relationship", asserted.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
