#!/usr/bin/env python3
"""Validate and canonicalize Qlik LOAD sources through Sigma's catalog."""

from __future__ import annotations

import argparse
import copy
import json
import sys
import urllib.parse
from pathlib import Path
from typing import Any, Callable

from lib import sigma_rest


def clean_part(value: Any) -> str:
    return str(value or "").strip().lstrip('"`[').rstrip('"`]')


def expected_path(source: Any, database: str, schema: str) -> list[str]:
    parts = [clean_part(part) for part in str(source or "").split(".")]
    parts = [part for part in parts if part]
    return [database, schema, parts[0]] if len(parts) == 1 else parts


def path_for_table(
    expected: list[str], connection_id: str, catalog_paths: list[dict[str, Any]]
) -> tuple[list[str] | None, str | None]:
    paths = [
        [clean_part(part) for part in row.get("path") or []]
        for row in catalog_paths
        if str(row.get("connectionId")) == str(connection_id)
    ]
    paths = [path for path in paths if path]
    exact = [
        path
        for path in paths
        if len(path) == len(expected)
        and [part.upper() for part in path] == [part.upper() for part in expected]
    ]
    if len(exact) == 1:
        return exact[0], None
    if len(exact) > 1:
        rendered = ", ".join(".".join(path) for path in exact)
        return None, (
            f"multiple case-insensitive catalog paths match "
            f"{'.'.join(expected)}: {rendered}"
        )
    same_table = [
        path for path in paths if path[-1].casefold() == expected[-1].casefold()
    ]
    if len(same_table) == 1:
        return same_table[0], None
    if not same_table:
        return expected, None
    rendered = ", ".join(".".join(path) for path in same_table)
    return None, f"table {expected[-1]} is ambiguous on the connection: {rendered}"


def list_entries(path: str) -> list[dict[str, Any]]:
    """Read every page from token- or page-based Sigma list endpoints."""
    rows: list[dict[str, Any]] = []
    next_value: Any = None
    next_key: str | None = None
    while True:
        separator = "&" if "?" in path else "?"
        current = path
        if next_key and next_value is not None:
            current += separator + urllib.parse.urlencode({next_key: next_value})
        data = sigma_rest.request("get", current) or {}
        page_rows = data.get("entries") or data.get("data") or []
        rows.extend(row for row in page_rows if isinstance(row, dict))
        if data.get("nextPageToken"):
            next_key, next_value = "pageToken", data["nextPageToken"]
        elif data.get("nextPage"):
            next_key, next_value = "page", data["nextPage"]
        else:
            break
    return rows


def preflight_tables(
    reconcile: list[dict[str, Any]],
    *,
    connection_id: str,
    database: str,
    schema: str,
    catalog_paths: list[dict[str, Any]],
    lookup: Callable[[str, list[str]], dict[str, Any]],
    list_columns: Callable[[str], list[dict[str, Any]]],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    report: dict[str, Any] = {
        "connectionId": connection_id,
        "tables": [],
        "errors": [],
    }
    resolved = copy.deepcopy(reconcile)
    for table in resolved:
        source = str(table.get("sourceTable") or "")
        if not source or source.upper().startswith(
            ("RESIDENT ", "INLINE", "AUTOGENERATE", "?")
        ):
            report["errors"].append(
                f"{table.get('qlikTable')}: source {source!r} "
                "is not a physical warehouse table"
            )
            continue
        expected = expected_path(source, database, schema)
        path, path_error = path_for_table(expected, connection_id, catalog_paths)
        if path_error:
            report["errors"].append(f"{table.get('qlikTable')}: {path_error}")
            continue
        assert path is not None
        try:
            found = lookup(connection_id, path)
            inode = found.get("inodeId") if isinstance(found, dict) else None
            kind = found.get("kind") if isinstance(found, dict) else None
            if not inode or kind != "table":
                report["errors"].append(
                    f"{table.get('qlikTable')}: {'.'.join(path)} resolved to "
                    f"{kind or 'no object'} (inode={inode!r}), not a table"
                )
                continue
            columns = list_columns(str(inode))
            by_upper = {
                str(column.get("name")).upper(): str(column.get("name"))
                for column in columns
                if column.get("name")
            }
            simple_aliases = {
                str(field.get("qlikField") or "").upper(): clean_part(
                    field.get("realColumn")
                )
                for field in table.get("fields") or []
                if not field.get("isExpression") and field.get("realColumn") != "*"
            }
            required: list[str] = []
            for field in table.get("fields") or []:
                if field.get("isExpression"):
                    inputs = [
                        simple_aliases.get(clean_part(name).upper(), clean_part(name))
                        for name in field.get("expressionColumns") or []
                    ]
                    field["expressionColumnsResolved"] = inputs
                    required.extend(inputs)
                elif field.get("realColumn") != "*":
                    required.append(str(field.get("realColumn") or ""))
            required = list(dict.fromkeys(name for name in required if name))
            missing = [
                name for name in required if clean_part(name).upper() not in by_upper
            ]
            if missing:
                report["errors"].append(
                    f"{table.get('qlikTable')}: {'.'.join(path)} is missing "
                    f"required column(s): {', '.join(missing)}"
                )
            table["sourceTable"] = ".".join(path)
            table["warehouseColumns"] = by_upper
            for field in table.get("fields") or []:
                if field.get("isExpression") or field.get("realColumn") == "*":
                    continue
                actual = by_upper.get(clean_part(field.get("realColumn")).upper())
                if actual:
                    field["realColumn"] = actual
            report["tables"].append(
                {
                    "qlikTable": table.get("qlikTable"),
                    "path": path,
                    "inodeId": inode,
                    "columnsFound": len(columns),
                    "requiredColumns": required,
                    "missingColumns": missing,
                }
            )
        except sigma_rest.SigmaError as exc:
            first = str(exc).splitlines()[0]
            advice = (
                f"; sync it with POST /v2/connections/{connection_id}/sync "
                f"and body {json.dumps({'path': path})}"
                if "-> 404" in first
                else ""
            )
            report["errors"].append(
                f"{table.get('qlikTable')}: Sigma catalog lookup failed for "
                f"{'.'.join(path)}: {first}{advice}"
            )
        except Exception as exc:  # catalog failures must become evidence, not drops
            report["errors"].append(
                f"{table.get('qlikTable')}: catalog error for {'.'.join(path)}: "
                f"{type(exc).__name__}: {exc}"
            )
    return resolved, report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reconcile", required=True)
    parser.add_argument("--connection", required=True)
    parser.add_argument("--database", required=True)
    parser.add_argument("--schema", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args(argv)
    reconcile = json.loads(Path(args.reconcile).read_text(encoding="utf-8-sig"))
    try:
        catalog_paths = list_entries("/v2/connections/paths")
    except sigma_rest.SigmaError as exc:
        print(
            "warehouse preflight: connection-path browse unavailable "
            f"({str(exc).splitlines()[0]}); trying exact paths",
            file=sys.stderr,
        )
        catalog_paths = []
    resolved, report = preflight_tables(
        reconcile,
        connection_id=args.connection,
        database=args.database,
        schema=args.schema,
        catalog_paths=catalog_paths,
        lookup=lambda connection, path: sigma_rest.request(
            "post",
            f"/v2/connection/{connection}/lookup",
            body=json.dumps({"path": path}),
        ),
        list_columns=lambda inode: list_entries(
            f"/v2/connections/tables/{inode}/columns"
        ),
    )
    Path(args.out).write_text(json.dumps(resolved, indent=2) + "\n", encoding="utf-8")
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if report["errors"]:
        print(
            "FATAL: Sigma connection catalog preflight failed; "
            "no Sigma objects were created:",
            file=sys.stderr,
        )
        for error in report["errors"]:
            print(f"  - {error}", file=sys.stderr)
        return 4
    count = sum(int(table["columnsFound"]) for table in report["tables"])
    print(
        f"warehouse preflight: {len(report['tables'])} table(s), {count} column(s) "
        f"verified via Sigma REST -> {args.report}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
