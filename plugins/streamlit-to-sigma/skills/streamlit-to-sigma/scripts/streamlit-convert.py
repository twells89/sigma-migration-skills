#!/usr/bin/env python3
"""Offline Streamlit discovery and Sigma spec conversion CLI."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SKILL))

from converter import analyze_project, build_data_model, build_workbook  # noqa: E402


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", help="Streamlit project directory or main .py file")
    parser.add_argument("--connection", required=True, help="Sigma connection id")
    parser.add_argument("--folder", default="<FOLDER_ID>")
    parser.add_argument("--name")
    parser.add_argument("--out-dir", default="streamlit-migration")
    parser.add_argument(
        "--mode",
        choices=("all", "discover", "data-model", "workbook"),
        default="all",
    )
    parser.add_argument(
        "--source-mode",
        choices=("custom-sql", "data-model"),
        default="custom-sql",
    )
    parser.add_argument("--dm-bindings", type=Path)
    args = parser.parse_args()

    out = Path(args.out_dir).resolve()
    ir = analyze_project(args.source)
    ir_dict = ir.to_dict()
    if args.mode in {"all", "discover"}:
        write_json(out / "streamlit-ir.json", ir_dict)
        write_json(out / "gaps.json", [gap for gap in ir_dict["gaps"]])
        write_json(
            out / "security.json",
            [finding for finding in ir_dict["security"]],
        )

    dm_result = None
    if args.mode in {"all", "data-model"}:
        dm_result = build_data_model(
            ir,
            args.connection,
            args.folder,
            f"{args.name} — Streamlit Source" if args.name else None,
        )
        write_json(out / "dm-result.json", dm_result)
        write_json(out / "dm-spec.json", dm_result["dataModel"])

    workbook_result = None
    if args.mode in {"all", "workbook"}:
        bindings = {}
        if args.dm_bindings:
            bindings = json.loads(args.dm_bindings.read_text(encoding="utf-8"))
        workbook_result = build_workbook(
            ir,
            args.connection,
            args.folder,
            args.name,
            args.source_mode,
            bindings,
        )
        write_json(out / "workbook-result.json", workbook_result)
        write_json(out / "wb-spec.json", workbook_result["workbook"])
        (out / "layout.xml").write_text(
            workbook_result["workbook"]["document"]["layout"],
            encoding="utf-8",
        )

    signature = {
        "source": "streamlit",
        "project": ir.project_name,
        "queries": [
            {
                "function": query.function,
                "columns": query.columns,
                "dynamic": query.dynamic,
                "sql": query.sql,
            }
            for query in ir.queries
        ],
    }
    write_json(out / "source-signature.json", signature)
    write_json(
        out / "parity-plan.json",
        {
            "status": "not-run",
            "required": [
                "source anchors",
                "Sigma element queries",
                "warehouse comparison",
                "control flip tests",
                "page PNG comparison",
            ],
            "elements": [
                {"id": item.id, "kind": item.kind, "label": item.label}
                for item in ir.elements
            ],
            "controls": [
                {
                    "id": item.id,
                    "type": item.control_type,
                    "label": item.label,
                }
                for item in ir.controls
            ],
        },
    )

    print(
        json.dumps(
            {
                "outDir": str(out),
                "pages": len(ir.pages),
                "queries": len(ir.queries),
                "elements": len(ir.elements),
                "controls": len(ir.controls),
                "gaps": len(ir.gaps),
                "dataModelBuilt": dm_result is not None,
                "workbookBuilt": workbook_result is not None,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
