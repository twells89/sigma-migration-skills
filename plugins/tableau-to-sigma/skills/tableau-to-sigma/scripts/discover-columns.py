#!/usr/bin/env python3
"""Discover a warehouse table's columns through Sigma's catalog API.

Python replacement for the runtime path covered by discover-columns.rb and
discover-warehouse-columns.rb. The columns endpoint has its own pagination
contract: nextPageToken/pageToken (with nextPage/page compatibility), not the
generic list pagination used by other Sigma endpoints.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.parse
from pathlib import Path
from typing import Callable

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))

import sigma_rest  # noqa: E402


class DiscoveryError(RuntimeError):
    """Catalog data was incomplete or internally inconsistent."""


class CatalogNotFound(DiscoveryError):
    """The requested table is not indexed in Sigma's catalog."""


def table_path_parts(table_path: str) -> list[str]:
    parts = table_path.split(".", 2)
    if len(parts) != 3:
        raise DiscoveryError(
            f"table-path must be DB.SCHEMA.TABLE (got {table_path!r})"
        )
    return parts


def _is_http_status(error: sigma_rest.SigmaError, method: str, path: str, status: int) -> bool:
    return re.match(
        rf"^{re.escape(method.upper())} {re.escape(path)} -> {status}(?:\s|$)",
        str(error),
    ) is not None


def list_warehouse_columns(
    inode_id: str,
    *,
    limit: int = 1000,
    on_page: Callable[[dict], None] | None = None,
) -> list[dict]:
    """Return every raw column entry for an inode, or raise before returning.

    Column order and entry values are retained exactly as Sigma returns them.
    Malformed pages and repeated cursors are fatal so callers can never consume
    a silently truncated catalog.
    """
    if not inode_id:
        raise DiscoveryError("inodeId must not be empty")
    if limit <= 0:
        raise DiscoveryError("column page limit must be positive")

    endpoint = f"/v2/connections/tables/{inode_id}/columns"
    entries: list[dict] = []
    cursor = None
    cursor_param = None
    seen_cursors: set[tuple[str, str]] = set()

    while True:
        query: dict[str, object] = {"limit": limit}
        if cursor is not None and cursor_param is not None:
            query[cursor_param] = cursor
        path = f"{endpoint}?{urllib.parse.urlencode(query)}"
        page = sigma_rest.request("get", path)

        if not isinstance(page, dict):
            raise DiscoveryError(
                f"columns endpoint returned {type(page).__name__}, expected object"
            )
        page_entries = page.get("entries")
        if not isinstance(page_entries, list):
            raise DiscoveryError("columns endpoint response has no entries array")
        if any(not isinstance(entry, dict) for entry in page_entries):
            raise DiscoveryError("columns endpoint entries must all be objects")

        entries.extend(page_entries)
        if on_page is not None:
            on_page(page)

        if "nextPageToken" in page:
            next_cursor = page["nextPageToken"]
            next_cursor_param = "pageToken"
        elif "nextPage" in page:
            next_cursor = page["nextPage"]
            next_cursor_param = "page"
        else:
            break

        if next_cursor is None or str(next_cursor) == "":
            break
        marker = (next_cursor_param, str(next_cursor))
        if marker in seen_cursors:
            raise DiscoveryError(
                f"{endpoint}: server repeated {next_cursor_param} cursor "
                f"{next_cursor!r}; refusing a partial column list"
            )
        seen_cursors.add(marker)
        cursor = next_cursor
        cursor_param = next_cursor_param

    return entries


def _column_contract(entry: dict) -> dict:
    if "name" not in entry or not isinstance(entry["name"], str):
        raise DiscoveryError("column entry has no string name")

    column_type = entry.get("type")
    if isinstance(column_type, dict):
        if "type" not in column_type:
            raise DiscoveryError(
                f"column {entry['name']!r} has a malformed nested type"
            )
        column_type = column_type["type"]
    if column_type is None:
        column_type = ""
    elif not isinstance(column_type, str):
        column_type = str(column_type)

    return {"name": entry["name"], "type": column_type}


def discover(
    connection_id: str,
    table_path: str,
    *,
    on_page: Callable[[dict], None] | None = None,
) -> dict:
    parts = table_path_parts(table_path)
    lookup_path = f"/v2/connection/{connection_id}/lookup"
    try:
        lookup = sigma_rest.request(
            "post",
            lookup_path,
            body=json.dumps({"path": parts}, separators=(",", ":")),
        )
    except sigma_rest.SigmaError as exc:
        if _is_http_status(exc, "post", lookup_path, 404):
            raise CatalogNotFound(
                f"Table {table_path} not found in Sigma's catalog for "
                f"connection {connection_id}."
            ) from exc
        raise

    if not isinstance(lookup, dict):
        raise DiscoveryError(
            f"lookup returned {type(lookup).__name__}, expected object"
        )
    inode_id = lookup.get("inodeId")
    if not isinstance(inode_id, str) or not inode_id:
        raise DiscoveryError("lookup returned no inodeId")
    if lookup.get("kind") != "table":
        raise DiscoveryError(
            f"path resolved to {lookup.get('kind')!r}, not a table"
        )

    raw_columns = list_warehouse_columns(
        inode_id,
        on_page=on_page,
    )
    columns = [_column_contract(column) for column in raw_columns]
    return {
        "connection_id": connection_id,
        "path": parts,
        "inode_id": inode_id,
        "columns": columns,
    }


def _write_result(result: dict, out_path: str | None) -> None:
    rendered = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if out_path:
        Path(out_path).write_text(rendered, encoding="utf-8")
        print(f"wrote {out_path} ({len(result['columns'])} columns)")
    else:
        print(rendered, end="")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connection-id", required=True)
    parser.add_argument(
        "--table-path",
        required=True,
        help="fully-qualified, case-sensitive DB.SCHEMA.TABLE path",
    )
    parser.add_argument("--out")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    pages = 0

    def count_page(_page: dict) -> None:
        nonlocal pages
        pages += 1

    try:
        result = discover(
            args.connection_id,
            args.table_path,
            on_page=count_page,
        )
        _write_result(result, args.out)
    except CatalogNotFound as exc:
        print(str(exc), file=sys.stderr)
        print(
            "Sync the table path with POST /v2/connections/"
            f"{args.connection_id}/sync, then retry.",
            file=sys.stderr,
        )
        return 4
    except (DiscoveryError, sigma_rest.SigmaError, OSError, ValueError) as exc:
        print(f"FATAL: column discovery failed: {exc}", file=sys.stderr)
        return 1

    if pages > 1:
        print(
            f"columns list spanned {pages} pages "
            f"({len(result['columns'])} columns total) — "
            "wide table, all pages fetched",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
