#!/usr/bin/env python3
"""Recreate a Sigma CSV-backed data model over its existing warehouse data.

The source and target organizations use separate API credentials. Planning is
read-only and writes a transformed data-model spec locally. Creating the target
model requires both --apply and --yes.
"""

from __future__ import annotations

import argparse
import base64
import copy
import json
import os
import re
import shlex
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class MigrationError(RuntimeError):
    """A user-actionable migration error."""


class ApiError(MigrationError):
    """A Sigma API error with its HTTP status preserved."""

    def __init__(self, method: str, path: str, status: int, body: str):
        super().__init__(f"{method.upper()} {path} -> {status}: {body}")
        self.status = status


@dataclass(frozen=True)
class Credentials:
    base_url: str
    client_id: str
    client_secret: str


@dataclass(frozen=True)
class ResolvedSource:
    source_element_id: str
    source_connection_id: str
    target_connection_id: str
    physical_relation: str
    statement: str


class SigmaClient:
    """Small stdlib-only client for the data-model endpoints used here."""

    def __init__(self, credentials: Credentials):
        self.credentials = credentials
        self._token: str | None = None
        self._ssl_context = ssl.create_default_context()

    def _mint_token(self) -> str:
        raw = (
            f"{self.credentials.client_id}:{self.credentials.client_secret}"
        ).encode()
        request = urllib.request.Request(
            f"{self.credentials.base_url}/v2/auth/token",
            data=b"grant_type=client_credentials",
            method="POST",
            headers={
                "Authorization": f"Basic {base64.b64encode(raw).decode()}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
        )
        try:
            with urllib.request.urlopen(
                request, timeout=30, context=self._ssl_context
            ) as response:
                payload = json.load(response)
        except urllib.error.HTTPError as error:
            body = error.read().decode(errors="replace")
            raise ApiError("POST", "/v2/auth/token", error.code, body) from error
        token = payload.get("access_token")
        if not token:
            raise MigrationError("Sigma token response did not contain access_token")
        self._token = token
        return token

    def request(
        self, method: str, path: str, body: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        encoded = None if body is None else json.dumps(body).encode()
        for attempt in range(2):
            token = self._token or self._mint_token()
            headers = {
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
            }
            if encoded is not None:
                headers["Content-Type"] = "application/json"
            request = urllib.request.Request(
                f"{self.credentials.base_url}{path}",
                data=encoded,
                method=method.upper(),
                headers=headers,
            )
            try:
                with urllib.request.urlopen(
                    request, timeout=120, context=self._ssl_context
                ) as response:
                    raw = response.read()
                    return {} if not raw else json.loads(raw)
            except urllib.error.HTTPError as error:
                error_body = error.read().decode(errors="replace")
                if error.code == 401 and attempt == 0:
                    self._token = None
                    continue
                raise ApiError(method, path, error.code, error_body) from error
        raise MigrationError("Sigma authentication failed after token refresh")

    def get(self, path: str) -> dict[str, Any]:
        return self.request("GET", path)

    def post(self, path: str, body: dict[str, Any]) -> dict[str, Any]:
        return self.request("POST", path, body)


def load_credentials(path: Path) -> Credentials:
    """Parse a plain KEY=value env file without evaluating shell code."""

    raw = path.read_text(encoding="utf-8-sig")
    if raw.lstrip().startswith(r"{\rtf"):
        raise MigrationError(
            f"{path} is an RTF document, not a plain-text .env file; "
            "resave it as plain text before using it"
        )

    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(raw.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise MigrationError(
                f"{path}:{line_number}: expected KEY=value, found {raw_line!r}"
            )
        key, value = line.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", key):
            raise MigrationError(f"{path}:{line_number}: invalid environment key")
        try:
            parsed = shlex.split(value.strip(), posix=True)
        except ValueError as error:
            raise MigrationError(f"{path}:{line_number}: {error}") from error
        if len(parsed) > 1:
            raise MigrationError(
                f"{path}:{line_number}: quote values containing whitespace"
            )
        values[key] = parsed[0] if parsed else ""

    required = ("SIGMA_BASE_URL", "SIGMA_CLIENT_ID", "SIGMA_CLIENT_SECRET")
    missing = [key for key in required if not values.get(key)]
    if missing:
        raise MigrationError(f"{path} is missing {', '.join(missing)}")
    base_url = values["SIGMA_BASE_URL"].rstrip("/")
    parsed_url = urllib.parse.urlparse(base_url)
    host = (parsed_url.hostname or "").lower()
    if parsed_url.scheme != "https" or not (
        host == "sigmacomputing.com" or host.endswith(".sigmacomputing.com")
    ):
        raise MigrationError(
            "SIGMA_BASE_URL must be an https:// URL on sigmacomputing.com"
        )
    return Credentials(
        base_url=base_url,
        client_id=values["SIGMA_CLIENT_ID"],
        client_secret=values["SIGMA_CLIENT_SECRET"],
    )


def parse_model_ref(value: str) -> str:
    """Accept an API ID, public ID, or full Sigma data-model URL."""

    value = value.strip().rstrip("/")
    if not value:
        raise MigrationError("data-model reference cannot be empty")
    if "://" not in value:
        return value
    parsed = urllib.parse.urlparse(value)
    slug = parsed.path.rsplit("/", 1)[-1]
    public_id = re.search(r"([A-Za-z0-9]{20,})$", slug)
    if not public_id:
        raise MigrationError(f"could not extract a data-model ID from {value!r}")
    return public_id.group(1)


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MigrationError(f"could not read JSON from {path}: {error}") from error
    if not isinstance(value, dict):
        raise MigrationError(f"{path} must contain a JSON object")
    return value


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(
        path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(value, output, indent=2, sort_keys=False)
        output.write("\n")


def iter_elements(spec: dict[str, Any]):
    for page in spec.get("pages", []):
        for element in page.get("elements", []):
            yield element


def csv_elements(spec: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        element
        for element in iter_elements(spec)
        if element.get("source", {}).get("kind") == "csv-table"
    ]


def source_column_name(column_id: str, csv_inode: str) -> str | None:
    prefix = f"{csv_inode}/"
    return column_id[len(prefix) :] if column_id.startswith(prefix) else None


def csv_filename(element: dict[str, Any]) -> str | None:
    for column in element.get("columns", []):
        formula = column.get("formula")
        if not isinstance(formula, str):
            continue
        match = re.match(r"^\[([^/\]]+)/", formula)
        if match:
            return match.group(1)
    name = element.get("name")
    return name if isinstance(name, str) and name else None


def inspect_report(
    spec: dict[str, Any], discovered_queries: dict[str, dict[str, str]] | None = None
) -> dict[str, Any]:
    discovered_queries = discovered_queries or {}
    sources = []
    for element in csv_elements(spec):
        source = element["source"]
        inode = source.get("inodeId", "")
        discovery = discovered_queries.get(element.get("id"), {})
        raw_columns = [
            source_column_name(column.get("id", ""), inode)
            for column in element.get("columns", [])
        ]
        sources.append(
            {
                "sourceElementId": element.get("id"),
                "csvInodeId": inode,
                "csvName": csv_filename(element),
                "connectionId": source.get("connectionId"),
                "columns": [name for name in raw_columns if name is not None],
                "physicalRelation": discovery.get("physicalRelation"),
            }
        )
    return {
        "dataModelId": spec.get("dataModelId"),
        "name": spec.get("name"),
        "folderId": spec.get("folderId"),
        "csvSourceCount": len(sources),
        "csvSources": sources,
    }


_SQL_IDENTIFIER = r'(?:`[^`]+`|"[^"]+"|[A-Za-z_][A-Za-z0-9_$]*)'
_QUALIFIED_RELATION = (
    rf"{_SQL_IDENTIFIER}(?:\s*\.\s*{_SQL_IDENTIFIER}){{1,2}}"
)


def sanitize_generated_sql(sql: str) -> str:
    """Remove Sigma's request comment and preview LIMIT from generated SQL."""

    if not isinstance(sql, str) or not sql.strip():
        raise MigrationError("element query response did not contain SQL")
    statement = re.split(r"\n\s*--\s*Sigma\b", sql, maxsplit=1)[0].strip()
    statement = re.sub(
        r"\s+limit\s+\d+\s*;?\s*$", "", statement, flags=re.IGNORECASE
    ).strip()
    if not re.match(r"^select\b", statement, flags=re.IGNORECASE):
        raise MigrationError("CSV element query is not a SELECT statement")
    if ";" in statement.rstrip(";"):
        raise MigrationError("CSV element query unexpectedly contains multiple statements")
    return statement.rstrip(";").strip()


def physical_relation_from_sql(statement: str) -> str:
    match = re.search(
        rf"\bfrom\s+(?P<relation>{_QUALIFIED_RELATION})(?=\s|$)",
        statement,
        flags=re.IGNORECASE,
    )
    if not match:
        raise MigrationError(
            "could not identify a qualified warehouse relation in CSV element SQL"
        )
    return re.sub(r"\s*\.\s*", ".", match.group("relation"))


def discover_csv_queries(
    source_client: SigmaClient, spec: dict[str, Any]
) -> dict[str, dict[str, str]]:
    data_model_id = spec.get("dataModelId")
    if not isinstance(data_model_id, str) or not data_model_id:
        raise MigrationError("source spec does not contain dataModelId")
    discoveries: dict[str, dict[str, str]] = {}
    for element in csv_elements(spec):
        element_id = element.get("id")
        if not isinstance(element_id, str) or not element_id:
            raise MigrationError("CSV element does not contain an id")
        payload = source_client.get(
            f"/v2/dataModels/{urllib.parse.quote(data_model_id, safe='')}"
            f"/elements/{urllib.parse.quote(element_id, safe='')}/query"
        )
        statement = sanitize_generated_sql(payload.get("sql"))
        discoveries[element_id] = {
            "statement": statement,
            "physicalRelation": physical_relation_from_sql(statement),
        }
    return discoveries


def replace_exact_references(value: Any, replacements: dict[str, str]) -> Any:
    if isinstance(value, dict):
        return {
            key: replace_exact_references(child, replacements)
            for key, child in value.items()
        }
    if isinstance(value, list):
        return [replace_exact_references(child, replacements) for child in value]
    if isinstance(value, str):
        return replacements.get(value, value)
    return value


def plan_spec(
    source_spec: dict[str, Any],
    resolved_sources: list[ResolvedSource],
    target_folder_id: str,
    target_name: str | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Return a create-safe spec and a non-secret planning report."""

    csv_by_id = {
        element.get("id"): element for element in csv_elements(source_spec)
    }
    resolved_by_id = {
        resolved.source_element_id: resolved for resolved in resolved_sources
    }
    missing = sorted(set(csv_by_id) - set(resolved_by_id))
    extra = sorted(set(resolved_by_id) - set(csv_by_id))
    if missing or extra:
        details = []
        if missing:
            details.append(f"unmapped CSV elements: {', '.join(missing)}")
        if extra:
            details.append(f"unknown mapped elements: {', '.join(extra)}")
        raise MigrationError("; ".join(details))

    planned = {
        "name": target_name or source_spec.get("name"),
        "folderId": target_folder_id,
        "schemaVersion": source_spec.get("schemaVersion", 1),
        "pages": copy.deepcopy(source_spec.get("pages", [])),
    }
    replacements: dict[str, str] = {}
    source_reports = []

    for element in iter_elements(planned):
        element_id = element.get("id")
        if element_id not in resolved_by_id:
            continue
        resolved = resolved_by_id[element_id]
        old_source = element.get("source", {})
        csv_inode = old_source.get("inodeId")
        if not isinstance(csv_inode, str) or not csv_inode:
            raise MigrationError(f"CSV element {element_id} has no inodeId")

        migrated_columns = []
        migrated_column_count = 0
        for column_index, column in enumerate(element.get("columns", []), start=1):
            old_id = column.get("id", "")
            raw_source_name = source_column_name(old_id, csv_inode)
            if raw_source_name is None:
                migrated_columns.append(column)
                continue
            new_id = f"sql-{element_id}-{column_index}"
            replacements[old_id] = new_id
            updated_column = copy.deepcopy(column)
            updated_column["id"] = new_id
            updated_column["formula"] = f"[Custom SQL/{raw_source_name}]"
            migrated_columns.append(updated_column)
            migrated_column_count += 1

        element["source"] = {
            "kind": "sql",
            "connectionId": resolved.target_connection_id,
            "statement": resolved.statement,
        }
        element["columns"] = migrated_columns
        source_reports.append(
            {
                "sourceElementId": element_id,
                "sourceCsvInodeId": csv_inode,
                "sourceConnectionId": resolved.source_connection_id,
                "targetConnectionId": resolved.target_connection_id,
                "physicalRelation": resolved.physical_relation,
                "migratedColumnCount": migrated_column_count,
            }
        )

    planned["pages"] = replace_exact_references(planned["pages"], replacements)
    report = {
        "name": planned["name"],
        "targetFolderId": target_folder_id,
        "sourceDataModelId": source_spec.get("dataModelId"),
        "csvSourceCount": len(source_reports),
        "sources": source_reports,
        "readyToCreate": True,
    }
    return planned, report


def load_mapping(path: Path) -> list[dict[str, Any]]:
    payload = read_json(path)
    entries = payload.get("csvSources")
    if not isinstance(entries, list) or not entries:
        raise MigrationError(f"{path} must contain a non-empty csvSources array")
    required = ("sourceElementId", "targetConnectionId")
    seen_element_ids: set[str] = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise MigrationError(f"{path}: csvSources[{index}] must be an object")
        missing = [key for key in required if not entry.get(key)]
        if missing:
            raise MigrationError(
                f"{path}: csvSources[{index}] is missing {', '.join(missing)}"
            )
        element_id = entry["sourceElementId"]
        if element_id in seen_element_ids:
            raise MigrationError(
                f"{path}: duplicate mapping for sourceElementId {element_id}"
            )
        seen_element_ids.add(element_id)
        if "allowDifferentHost" in entry and not isinstance(
            entry["allowDifferentHost"], bool
        ):
            raise MigrationError(
                f"{path}: csvSources[{index}].allowDifferentHost must be boolean"
            )
    return entries


def resolve_sources(
    source_client: SigmaClient,
    target_client: SigmaClient,
    source_spec: dict[str, Any],
    mappings: list[dict[str, Any]],
) -> list[ResolvedSource]:
    resolved = []
    discoveries = discover_csv_queries(source_client, source_spec)
    source_connections: dict[str, dict[str, Any]] = {}
    target_connections: dict[str, dict[str, Any]] = {}
    source_elements = {
        element.get("id"): element for element in csv_elements(source_spec)
    }
    for mapping in mappings:
        element_id = mapping["sourceElementId"]
        element = source_elements.get(element_id)
        if element is None:
            raise MigrationError(f"mapping references unknown CSV element {element_id}")
        source_connection_id = element["source"].get("connectionId")
        if not isinstance(source_connection_id, str) or not source_connection_id:
            raise MigrationError(f"CSV element {element_id} has no connectionId")
        target_connection_id = mapping["targetConnectionId"]

        if source_connection_id not in source_connections:
            source_connections[source_connection_id] = source_client.get(
                "/v2/connections/"
                f"{urllib.parse.quote(source_connection_id, safe='')}"
            )
        if target_connection_id not in target_connections:
            target_connections[target_connection_id] = target_client.get(
                "/v2/connections/"
                f"{urllib.parse.quote(target_connection_id, safe='')}"
            )
        source_connection = source_connections[source_connection_id]
        target_connection = target_connections[target_connection_id]
        if source_connection.get("type") != "databricks":
            raise MigrationError(
                f"source connection {source_connection_id} is not Databricks"
            )
        if target_connection.get("type") != "databricks":
            raise MigrationError(
                f"target connection {target_connection_id} is not Databricks"
            )
        source_host = str(source_connection.get("host", "")).casefold()
        target_host = str(target_connection.get("host", "")).casefold()
        if (
            source_host
            and target_host
            and source_host != target_host
            and not mapping.get("allowDifferentHost", False)
        ):
            raise MigrationError(
                f"CSV element {element_id} resolves on Databricks host "
                f"{source_connection.get('host')}, but the target connection uses "
                f"{target_connection.get('host')}; set allowDifferentHost only "
                "after confirming the physical table is available there"
            )
        discovery = discoveries[element_id]
        resolved.append(
            ResolvedSource(
                source_element_id=element_id,
                source_connection_id=source_connection_id,
                target_connection_id=target_connection_id,
                physical_relation=discovery["physicalRelation"],
                statement=discovery["statement"],
            )
        )
    return resolved


def get_spec(client: SigmaClient, model_ref: str) -> dict[str, Any]:
    model_id = urllib.parse.quote(parse_model_ref(model_ref), safe="")
    return client.get(f"/v2/dataModels/{model_id}/spec")


def print_json(value: dict[str, Any]) -> None:
    json.dump(value, sys.stdout, indent=2)
    sys.stdout.write("\n")


def inspect_command(args: argparse.Namespace) -> None:
    client = SigmaClient(load_credentials(args.source_env))
    spec = get_spec(client, args.model)
    if not csv_elements(spec):
        raise MigrationError("the data model does not contain a CSV source")
    discoveries = discover_csv_queries(client, spec)
    if args.export_spec:
        write_json(args.export_spec, spec)
    report = inspect_report(spec, discoveries)
    print_json(report)


def plan_command(args: argparse.Namespace) -> None:
    source_client = SigmaClient(load_credentials(args.source_env))
    target_client = SigmaClient(load_credentials(args.target_env))
    source_spec = get_spec(source_client, args.model)
    mappings = load_mapping(args.mapping)
    resolved = resolve_sources(
        source_client, target_client, source_spec, mappings
    )
    planned, report = plan_spec(
        source_spec,
        resolved,
        target_folder_id=args.target_folder,
        target_name=args.target_name,
    )
    write_json(args.output, planned)

    report["plannedSpec"] = str(args.output)
    if args.apply:
        if not args.yes:
            raise MigrationError("--apply requires --yes")
        created = target_client.post("/v2/dataModels/spec", planned)
        created_id = created.get("dataModelId")
        if not created_id:
            raise MigrationError(
                "create response did not contain dataModelId; "
                f"response keys: {', '.join(sorted(created))}"
            )
        readback = get_spec(target_client, created_id)
        remaining_csv = len(csv_elements(readback))
        if remaining_csv:
            raise MigrationError(
                f"created model readback still contains {remaining_csv} CSV sources"
            )
        report.update(
            {
                "createdDataModelId": created_id,
                "createdUrl": readback.get("url"),
                "readbackCsvSourceCount": remaining_csv,
            }
        )
        if args.readback:
            write_json(args.readback, readback)
    print_json(report)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Recreate a CSV-backed Sigma data model over its existing "
            "warehouse data"
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    inspect_parser = subparsers.add_parser(
        "inspect", help="read a model and list its CSV source mappings"
    )
    inspect_parser.add_argument("--source-env", required=True, type=Path)
    inspect_parser.add_argument("--model", required=True)
    inspect_parser.add_argument("--export-spec", type=Path)
    inspect_parser.set_defaults(handler=inspect_command)

    plan_parser = subparsers.add_parser(
        "plan",
        help="discover CSV backing tables and write a create-ready SQL spec",
    )
    plan_parser.add_argument("--source-env", required=True, type=Path)
    plan_parser.add_argument("--target-env", required=True, type=Path)
    plan_parser.add_argument("--model", required=True)
    plan_parser.add_argument("--mapping", required=True, type=Path)
    plan_parser.add_argument("--target-folder", required=True)
    plan_parser.add_argument("--target-name")
    plan_parser.add_argument("--output", required=True, type=Path)
    plan_parser.add_argument(
        "--apply",
        action="store_true",
        help="create the target model after writing the planned spec",
    )
    plan_parser.add_argument(
        "--yes",
        action="store_true",
        help="required confirmation for --apply",
    )
    plan_parser.add_argument("--readback", type=Path)
    plan_parser.set_defaults(handler=plan_command)
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        args = build_parser().parse_args(argv)
        args.handler(args)
        return 0
    except (MigrationError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
