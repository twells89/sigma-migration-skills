#!/usr/bin/env python3
"""Build terminal source-object accounting for the Tableau Python path."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

TERMINAL = {"migrated", "approximated", "needs-review", "skipped", "not-applicable"}


def load(path: Path, default=None):
    if not path.is_file():
        return default
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def formula_status(row: dict) -> str:
    direct = row.get("terminal_status")
    if direct in TERMINAL:
        return direct
    status = row.get("status")
    if status in {"spec", "chart_only"}:
        return "migrated"
    if status in {"verify", "rls"}:
        return "needs-review"
    if status in {"not_converted", "unmapped"}:
        return "skipped"
    return "needs-review"


def build(workdir: Path) -> dict:
    audit = load(workdir / "formula-audit.json", {}) or {}
    builder = load(workdir / "workbook-residues.json", {}) or {}
    layout = load(workdir / "dashboard-layout.json", []) or []
    objects = []
    for index, formula in enumerate(audit.get("formulas") or []):
        objects.append(
            {
                "type": "formula",
                "id": formula.get("internal_name") or f"formula-{index + 1}",
                "name": formula.get("calculation") or formula.get("caption") or f"Formula {index + 1}",
                "status": formula_status(formula),
                "evidence": [
                    {
                        "artifact": "formula-audit.json",
                        "translation_status": formula.get("status"),
                    }
                ],
            }
        )
    for index, disposition in enumerate(builder.get("dispositions") or []):
        status = (
            "migrated"
            if disposition.get("status") == "emitted"
            else "not-applicable"
        )
        objects.append(
            {
                "type": "dashboard-zone",
                "id": disposition.get("zoneId") or f"zone-{index + 1}",
                "name": (
                    disposition.get("elementId")
                    or disposition.get("zoneKind")
                    or f"Zone {index + 1}"
                ),
                "status": status,
                "evidence": [
                    {
                        "artifact": "workbook-residues.json",
                        "builder_status": disposition.get("status"),
                    }
                ],
            }
        )
    for index, residue in enumerate(builder.get("residues") or []):
        objects.append(
            {
                "type": "dashboard-zone",
                "id": residue.get("zoneId") or f"residue-{index + 1}",
                "name": residue.get("caption") or residue.get("reasonCode") or f"Residue {index + 1}",
                "status": "needs-review",
                "evidence": [
                    {
                        "artifact": "workbook-residues.json",
                        "reason": residue.get("reason"),
                    }
                ],
            }
        )
    accounted_zones = {
        str(item.get("zoneId"))
        for item in [
            *(builder.get("dispositions") or []),
            *(builder.get("residues") or []),
        ]
        if item.get("zoneId")
    }
    unaccounted_count = 0
    for dashboard in layout:
        for zone in dashboard.get("zones") or []:
            zone_id = str(zone.get("id") or "")
            if not zone_id or zone_id in accounted_zones:
                continue
            unaccounted_count += 1
            objects.append(
                {
                    "type": "dashboard-zone",
                    "id": zone_id,
                    "name": zone.get("caption") or zone.get("kind") or zone_id,
                    "status": "needs-review",
                    "evidence": [
                        {
                            "artifact": "dashboard-layout.json",
                            "reason": "zone has no builder disposition",
                        }
                    ],
                }
            )
    identities = {
        (str(item["type"]), str(item["id"]), str(item["name"])) for item in objects
    }
    complete = (
        len(identities) == len(objects)
        and all(item["status"] in TERMINAL and item["evidence"] for item in objects)
        and not (builder.get("residues") or [])
        and unaccounted_count == 0
    )
    counts = {
        status: sum(item["status"] == status for item in objects)
        for status in sorted(TERMINAL)
    }
    return {
        "schema_version": 1,
        "summary": {
            "complete": complete,
            "total": len(objects),
            "counts": counts,
        },
        "objects": objects,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--out")
    args = parser.parse_args()
    workdir = Path(args.workdir).expanduser().resolve()
    out = Path(args.out).resolve() if args.out else workdir / "source-object-census.json"
    try:
        result = build(workdir)
        out.write_text(
            json.dumps(result, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FATAL: source census failed: {exc}", file=sys.stderr)
        return 2
    if not result["summary"]["complete"]:
        print(f"BLOCKED: source accounting is incomplete; see {out}", file=sys.stderr)
        return 1
    print(f"PASS: {result['summary']['total']} source objects accounted -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
