#!/usr/bin/env python3
"""Live export flip test proving Sigma workbook controls affect their targets."""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import time
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

import control_lint
from lib import sigma_rest
from lib.code_rep import document
from preflight_warehouse import list_entries


def export_csv(
    workbook_id: str,
    element_id: str,
    parameters: dict[str, Any] | None,
    timeout: int,
) -> str:
    body: dict[str, Any] = {
        "elementId": element_id,
        "format": {"type": "csv"},
    }
    if parameters:
        body["parameters"] = parameters
    response = sigma_rest.request(
        "post",
        f"/v2/workbooks/{workbook_id}/export",
        body=json.dumps(body),
    ) or {}
    query_id = response.get("queryId")
    if not query_id:
        raise RuntimeError(f"export request returned no queryId for {element_id}")
    deadline = time.monotonic() + timeout
    while time.monotonic() <= deadline:
        try:
            payload = sigma_rest.request(
                "get",
                f"/v2/query/{query_id}/download",
                accept="text/csv",
                binary=True,
            )
            if payload:
                text = (
                    payload.decode("utf-8-sig", errors="replace")
                    if isinstance(payload, bytes)
                    else str(payload)
                )
                if text.lstrip().startswith("<"):
                    raise RuntimeError(
                        f"export returned HTML behind a 200 (queryId={query_id})"
                    )
                return text
        except sigma_rest.SigmaError as exc:
            if "-> 404" not in str(exc).splitlines()[0]:
                raise
        time.sleep(1)
    raise TimeoutError(f"export timed out after {timeout}s (queryId={query_id})")


def csv_signature(text: str) -> list[str]:
    return sorted(text.splitlines())


def parse_rows(text: str) -> tuple[list[str], list[dict[str, str]]]:
    reader = csv.DictReader(io.StringIO(text))
    return list(reader.fieldnames or []), list(reader)


def _value_source(element: dict[str, Any]) -> dict[str, Any] | None:
    source = element.get("source")
    if (
        isinstance(source, dict)
        and source.get("kind") == "source"
        and isinstance(source.get("source"), dict)
    ):
        return {**source["source"], "columnId": source.get("columnId")}
    if isinstance(source, dict) and source.get("elementId") and source.get("columnId"):
        return source
    for target in element.get("filters") or []:
        if isinstance(target, dict) and isinstance(target.get("source"), dict):
            return {**target["source"], "columnId": target.get("columnId")}
    return None


def parse_date_value(value: Any) -> date | None:
    text = str(value or "").strip()
    if not text:
        return None
    candidates = (text[:10], text.split(" ", 1)[0], text)
    for candidate in dict.fromkeys(candidates):
        try:
            return date.fromisoformat(candidate)
        except ValueError:
            pass
        for pattern in ("%m/%d/%Y", "%d/%m/%Y", "%Y/%m/%d", "%b %d, %Y", "%B %d, %Y"):
            try:
                return datetime.strptime(candidate, pattern).date()
            except ValueError:
                continue
    return None


def pick_value(
    row: dict[str, Any],
    element_map: dict[str, dict[str, Any]],
    explicit: dict[str, str],
    column_labels: dict[tuple[str, str], str],
    baseline: Any,
) -> tuple[str | None, str]:
    element = element_map[row["control_element_id"]]["el"]
    control_id = str(row.get("control_id") or "")
    if control_id in explicit:
        return explicit[control_id], "explicit --value"
    defaults = {str(value) for value in element.get("values") or []}
    control_type = str(element.get("controlType") or "")
    if control_type == "switch":
        first_default = next(iter(element.get("values") or []), None)
        return (
            "false" if str(first_default).lower() == "true" else "true"
        ), "switch flip"
    if control_type not in {"list", "segmented", "text", "date-range", "date"}:
        return None, f"controlType={control_type!r} has no auto flip value — pass --value"
    source = _value_source(element)
    if not source or not source.get("elementId") or not source.get("columnId"):
        return None, "no value-source column resolvable — pass --value"
    source_element = str(source["elementId"])
    label = column_labels.get((source_element, str(source["columnId"])))
    if not label:
        return None, f"no /columns label for {source_element}/{source.get('columnId')}"
    headers, rows = parse_rows(baseline(source_element))
    if label not in headers:
        return None, f"column {label!r} not in export of {source_element}"
    values = list(
        dict.fromkeys(
            str(record.get(label) or "")
            for record in rows
            if str(record.get(label) or "")
        )
    )
    if control_type in {"date-range", "date"}:
        days = sorted(
            {
                parsed
                for value in values
                if (parsed := parse_date_value(value)) is not None
            }
        )
        if len(days) < 2:
            return None, f"fewer than 2 distinct dates in {label!r}"
        middle = days[(len(days) - 1) // 2]
        if middle >= days[-1]:
            middle = days[-2]
        return (
            f"min:{days[0].isoformat()},max:{middle.isoformat()}",
            f"auto-picked earlier-half date range from {label!r}",
        )
    value = next((item for item in values if item not in defaults), None)
    return (
        (value, f"auto-picked from {label!r}")
        if value is not None
        else (None, "no non-default value found — pass --value")
    )


def run_probe(
    workbook_id: str,
    *,
    selected_controls: list[str],
    explicit_values: dict[str, str],
    check_out: bool,
    output: Path,
    timeout: int,
) -> tuple[int, list[dict[str, Any]]]:
    raw_spec = sigma_rest.request("get", f"/v2/workbooks/{workbook_id}/spec") or {}
    spec = document(raw_spec)
    element_map = control_lint.elements(spec)
    rows = control_lint.controls_report(spec)
    if selected_controls:
        rows = [row for row in rows if row["control_id"] in selected_controls]
    if not rows:
        raise ValueError(
            f"no controls found in workbook {workbook_id}"
            + (f" matching {selected_controls!r}" if selected_controls else "")
        )
    columns = list_entries(f"/v2/workbooks/{workbook_id}/columns")
    labels = {
        (str(row["elementId"]), str(row["columnId"])): str(row["label"])
        for row in columns
        if row.get("elementId") and row.get("columnId") and row.get("label")
    }
    baseline_cache: dict[str, str] = {}

    def baseline(element_id: str) -> str:
        if element_id not in baseline_cache:
            baseline_cache[element_id] = export_csv(
                workbook_id, element_id, None, timeout
            )
        return baseline_cache[element_id]

    output.mkdir(parents=True, exist_ok=True)
    hashes: dict[str, str] = {}

    def evidence(filename: str, text: str) -> None:
        (output / filename).write_text(text, encoding="utf-8")
        hashes[filename] = hashlib.sha256(text.encode("utf-8")).hexdigest()

    failures = 0
    probed = 0
    results: list[dict[str, Any]] = []
    for row in rows:
        control_id = str(row.get("control_id") or "")
        if not row["reach"]:
            failures += 1
            results.append(
                {
                    "control": control_id,
                    "result": "FAIL",
                    "note": "dead control — empty reach (run the control lint)",
                }
            )
            continue
        in_element = next(
            (
                element_id
                for element_id in row["page_queryable"]
                if element_id in row["reach"]
            ),
            None,
        ) or next(
            (
                element_id
                for element_id in row["reach"]
                if element_map.get(element_id, {}).get("kind")
                in control_lint.QUERYABLE
            ),
            None,
        )
        if not in_element:
            results.append(
                {
                    "control": control_id,
                    "result": "SKIP",
                    "note": "no queryable element in closure",
                }
            )
            continue
        value, note = pick_value(
            row, element_map, explicit_values, labels, baseline
        )
        if value is None:
            results.append(
                {
                    "control": control_id,
                    "result": "SKIP",
                    "note": note,
                }
            )
            continue
        probed += 1
        base = baseline(in_element)
        flipped = export_csv(
            workbook_id, in_element, {control_id: value}, timeout
        )
        evidence(f"{control_id}--{in_element}--base.csv", base)
        evidence(f"{control_id}--{in_element}--flip.csv", flipped)
        if csv_signature(base) != csv_signature(flipped):
            results.append(
                {
                    "control": control_id,
                    "result": "PASS",
                    "element": in_element,
                    "value": value,
                    "note": f"{note}; in-closure export differs",
                }
            )
        else:
            failures += 1
            results.append(
                {
                    "control": control_id,
                    "result": "FAIL",
                    "element": in_element,
                    "value": value,
                    "note": f"{note}; in-closure export IDENTICAL — control is inert",
                }
            )
        if check_out:
            out_element = next(
                (
                    item
                    for item in row["uncovered"]
                    if element_map.get(item, {}).get("kind")
                    in control_lint.QUERYABLE
                ),
                None,
            )
            if out_element:
                out_base = baseline(out_element)
                out_flip = export_csv(
                    workbook_id, out_element, {control_id: value}, timeout
                )
                evidence(f"{control_id}--{out_element}--out-base.csv", out_base)
                evidence(f"{control_id}--{out_element}--out-flip.csv", out_flip)
                if csv_signature(out_base) == csv_signature(out_flip):
                    results.append(
                        {
                            "control": control_id,
                            "result": "OK",
                            "element": out_element,
                            "note": "out-of-closure export unchanged",
                        }
                    )
                else:
                    failures += 1
                    results.append(
                        {
                            "control": control_id,
                            "result": "FAIL",
                            "element": out_element,
                            "note": "out-of-closure export CHANGED — reach graph missed an edge",
                        }
                    )
    (output / "probe-results.json").write_text(
        json.dumps(results, indent=2) + "\n", encoding="utf-8"
    )
    doc_version = (
        raw_spec.get("latestDocumentVersion") or raw_spec.get("latestVersion")
        if isinstance(raw_spec, dict)
        else None
    )
    (output / "probe-evidence.json").write_text(
        json.dumps(
            {
                "workbook_id": workbook_id,
                "doc_version": str(doc_version) if doc_version is not None else None,
                "transport": "serial-python",
                "probed_at": datetime.now(timezone.utc)
                .replace(microsecond=0)
                .isoformat()
                .replace("+00:00", "Z"),
                "contract": "raw wire CSVs; verdicts recomputed every run",
                "exports": hashes,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return (1 if failures else 2 if not probed else 0), results


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workbook-id", required=True)
    parser.add_argument("--control", action="append", default=[])
    parser.add_argument("--value", action="append", default=[])
    parser.add_argument("--check-out-of-closure", action="store_true")
    parser.add_argument("--out")
    parser.add_argument("--timeout", type=int, default=90)
    parser.add_argument("--pool", type=int, default=5)  # CLI-compatible; serial transport
    parser.add_argument("--no-pool", action="store_true")
    args = parser.parse_args(argv)
    values = {}
    for value in args.value:
        if "=" not in value:
            parser.error(f"bad --value {value!r}; expected <controlId>=<value>")
        control_id, selected = value.split("=", 1)
        values[control_id] = selected
    output = (
        Path(args.out)
        if args.out
        else Path(f"/tmp/probe-controls-{args.workbook_id}")
    )
    try:
        rc, results = run_probe(
            args.workbook_id,
            selected_controls=args.control,
            explicit_values=values,
            check_out=args.check_out_of_closure,
            output=output,
            timeout=args.timeout,
        )
    except (ValueError, RuntimeError, TimeoutError, sigma_rest.SigmaError) as exc:
        print(f"probe-controls: {exc}")
        return 1
    print(f"{'CONTROL':22} {'RESULT':6} {'ELEMENT':34} NOTE")
    for row in results:
        print(
            f"{str(row.get('control') or ''):22} {str(row.get('result')):6} "
            f"{str(row.get('element') or '-'):34} {row.get('note') or ''}"
        )
    print(f"evidence: {output}/")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
