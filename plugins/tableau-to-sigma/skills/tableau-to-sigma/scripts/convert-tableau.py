#!/usr/bin/env python3
"""Run the vendored Tableau converter without Ruby or network egress."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_CONVERTER = HERE.parent / "converter" / "tableau.mjs"
CASE_VALUE = r'(?:"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'|[-+]?(?:\d+(?:\.\d*)?|\.\d+)|true|false)'


def parameter_case_value(raw: str) -> str:
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return re.sub(r"\\(.)", r"\1", value[1:-1])
    return value


def parameter_switch_pattern(pattern: object) -> dict | None:
    if not isinstance(pattern, dict) or pattern.get("kind") != "param-filter":
        return None
    source = re.sub(r"//[^\r\n]*", "", str(pattern.get("source", "")))
    source = re.sub(r"\s+", " ", source).strip()
    match = re.fullmatch(
        r"CASE\s+\[Parameters?\]\s*\.\s*\[([^\]]+)\]\s+(.+)\s+END",
        source,
        flags=re.IGNORECASE,
    )
    if not match:
        return None
    param_name, body = match.group(1), match.group(2).strip()
    if re.search(r"\b(?:CASE|IF|ELSEIF)\b", body, flags=re.IGNORECASE):
        return None
    pair_re = re.compile(
        rf"\bWHEN\s+({CASE_VALUE})\s+THEN\s+(.+?)(?=\s+\bWHEN\b|\s+\bELSE\b|\Z)",
        flags=re.IGNORECASE,
    )
    cases = [
        {"when": parameter_case_value(item.group(1)), "then": item.group(2).strip()}
        for item in pair_re.finditer(body)
    ]
    if not cases:
        return None
    consumed = pair_re.sub("", body)
    consumed = re.sub(r"\bELSE\s+.+\Z", "", consumed, flags=re.IGNORECASE).strip()
    if consumed:
        return None
    else_match = re.search(r"\bELSE\s+(.+)\Z", body, flags=re.IGNORECASE)
    replacement = dict(pattern)
    replacement.update(
        {
            "kind": "param-switch",
            "paramName": pattern.get("paramName") or param_name,
            "cases": cases,
            "elseExpr": else_match.group(1).strip() if else_match else None,
            "requires": (
                "WORKBOOK element: a single-select control + a Switch formula "
                "on the chart/grouping column; not a data-model control or calculated column."
            ),
            "note": (
                "Tableau parameter field switch -> Sigma workbook "
                f"control-driven Switch ({len(cases)} case(s))."
            ),
        }
    )
    return replacement


def normalize_converter_parameters(result: dict) -> dict:
    model = result.get("model")
    if not isinstance(model, dict):
        return result
    promoted = 0
    patterns = []
    for pattern in result.get("workbookPatterns") or []:
        replacement = parameter_switch_pattern(pattern)
        if replacement:
            promoted += 1
        patterns.append(replacement or pattern)
    result["workbookPatterns"] = patterns

    controls: list[tuple[dict, dict]] = []
    data_elements: list[dict] = []
    for page in model.get("pages") or []:
        for element in page.get("elements") or []:
            if element.get("kind") == "control":
                controls.append((page, element))
            else:
                data_elements.append(element)
    dm_text = json.dumps(data_elements, separators=(",", ":"))
    preserved_ids = {
        id(control)
        for _, control in controls
        if control.get("controlId") and f"[{control['controlId']}]" in dm_text
    }
    for page in model.get("pages") or []:
        page["elements"] = [
            element
            for element in page.get("elements") or []
            if element.get("kind") != "control" or id(element) in preserved_ids
        ]
    removed = len(controls) - len(preserved_ids)
    result.setdefault("stats", {})["controls"] = len(preserved_ids)
    warnings = result.setdefault("warnings", [])
    if promoted:
        warnings.append(
            f"ℹ Promoted {promoted} bare-value Tableau parameter CASE calc(s) "
            "to workbook param-switch patterns; none were emitted as DM fields."
        )
    if removed:
        warnings.append(
            f"ℹ Moved {removed} unreferenced Tableau parameter control(s) out "
            "of the data model; the workbook builder materializes them from parameter metadata."
        )
    return result


def run_converter(args: argparse.Namespace) -> dict:
    converter = Path(args.converter).expanduser().resolve()
    twb = Path(args.twb).expanduser().resolve()
    workdir = Path(args.out).expanduser().resolve()
    if not converter.is_file():
        raise FileNotFoundError(f"converter not found: {converter}")
    if not twb.is_file():
        raise FileNotFoundError(f"Tableau workbook not found: {twb}")
    workdir.mkdir(parents=True, exist_ok=True)

    table_mapping = {}
    if args.table_mapping:
        with Path(args.table_mapping).open(encoding="utf-8-sig") as handle:
            table_mapping = json.load(handle)

    raw_out = workdir / "dm-raw.json"
    meta_out = workdir / "conv-meta.json"
    shim = workdir / "_convert_tableau.mjs"
    options = {
        "connectionId": args.connection,
        "database": args.database,
        "schema": args.schema,
        "tableMapping": table_mapping,
        "factTable": args.fact_table or "",
        "datasourceIndex": args.datasource_index,
    }
    shim.write_text(
        "\n".join(
            [
                "import { readFileSync, writeFileSync } from 'node:fs';",
                f"import {{ convertTableauToSigma }} from {json.dumps(converter.as_uri())};",
                f"const xml = readFileSync({json.dumps(str(twb))}, 'utf8');",
                f"const out = convertTableauToSigma(xml, {json.dumps(options)});",
                "const bare = out.model || out.sigmaDataModel || out;",
                f"writeFileSync({json.dumps(str(raw_out))}, JSON.stringify(bare, null, 2));",
                (
                    f"writeFileSync({json.dumps(str(meta_out))}, JSON.stringify({{"
                    "model: bare, warnings: out.warnings || [], stats: out.stats || {}, "
                    "security: out.security || [], workbookPatterns: out.workbookPatterns || [], "
                    "parameters: out.parameters || [], "
                    "relationshipCoverage: out.relationshipCoverage || null"
                    "}, null, 2));"
                ),
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    completed = subprocess.run(
        ["node", str(shim)],
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode:
        raise RuntimeError(
            f"converter failed ({completed.returncode}): "
            f"{completed.stderr or completed.stdout}"
        )
    with meta_out.open(encoding="utf-8") as handle:
        result = normalize_converter_parameters(json.load(handle))
    meta_out.write_text(
        json.dumps(result, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    raw_out.write_text(
        json.dumps(result["model"], indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--twb", required=True)
    parser.add_argument("--connection", required=True)
    parser.add_argument("--database", required=True)
    parser.add_argument("--schema", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--converter", default=str(DEFAULT_CONVERTER))
    parser.add_argument("--table-mapping")
    parser.add_argument("--fact-table")
    parser.add_argument("--datasource-index", type=int, default=0)
    args = parser.parse_args()
    try:
        result = run_converter(args)
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    print(
        f"wrote {Path(args.out).resolve() / 'dm-raw.json'} and conv-meta.json "
        f"({len(result.get('warnings') or [])} warning(s))"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
