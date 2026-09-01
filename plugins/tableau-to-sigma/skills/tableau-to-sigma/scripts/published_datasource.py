#!/usr/bin/env python3
"""Resolve and hydrate Tableau published (sqlproxy) datasources without Ruby.

The REST datasource content is authoritative.  Hydration is atomic: every
sqlproxy placeholder must resolve to one datasource, one TDS member, and one
usable relation before a hydrated workbook is written.
"""

from __future__ import annotations

import hashlib
import io
import json
import re
import sys
import time
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import tableau_rest

MAX_TDS_BYTES = 16 * 1024 * 1024
MAX_ZIP_MEMBERS = 10_000
MAX_COMPRESSION_RATIO = 200
PLACEHOLDER_TABLES = {"[sqlproxy]", "[Extract].[Extract]"}


class PublishedDatasourceError(RuntimeError):
    """A published datasource cannot be resolved without guessing."""


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _children(node: ET.Element, name: str) -> list[ET.Element]:
    return [child for child in node if _local_name(child.tag) == name]


def _descendants(node: ET.Element, name: str) -> list[ET.Element]:
    return [child for child in node.iter() if _local_name(child.tag) == name]


def _top_level_datasources(root: ET.Element) -> list[ET.Element]:
    container = next(
        (item for item in root.iter() if _local_name(item.tag) == "datasources"),
        None,
    )
    if container is None:
        return []
    return _children(container, "datasource")


def _connection(datasource: ET.Element) -> ET.Element | None:
    direct = _children(datasource, "connection")
    return direct[0] if direct else None


def _is_placeholder(relation: ET.Element) -> bool:
    return (
        str(relation.get("type") or "table").lower() == "table"
        and str(relation.get("table") or "") in PLACEHOLDER_TABLES
    )


def _is_real_relation(relation: ET.Element) -> bool:
    relation_type = str(relation.get("type") or "table").lower()
    if relation_type == "text":
        return bool(str(relation.text or "").strip())
    return (
        relation_type == "table"
        and bool(str(relation.get("table") or "").strip())
        and not _is_placeholder(relation)
    )


def sqlproxy_datasources(root: ET.Element) -> list[ET.Element]:
    result = []
    for datasource in _top_level_datasources(root):
        connection = _connection(datasource)
        if connection is None or str(connection.get("class") or "").lower() != "sqlproxy":
            continue
        if any(_is_real_relation(item) for item in _descendants(connection, "relation")):
            continue
        result.append(datasource)
    return result


def datasource_identity(datasource: ET.Element, index: int) -> dict[str, Any]:
    connection = _connection(datasource)
    repository = next(iter(_descendants(datasource, "repository-location")), None)
    content_url = (
        str(connection.get("dbname") or "").strip() if connection is not None else ""
    ) or (str(repository.get("id") or "").strip() if repository is not None else "")
    return {
        "index": index,
        "name": str(datasource.get("name") or ""),
        "caption": str(datasource.get("caption") or ""),
        "contentUrl": content_url,
    }


def _safe_tds_from_content(payload: bytes) -> tuple[str, str | None]:
    if len(payload) > MAX_TDS_BYTES and not payload.startswith(b"PK"):
        raise PublishedDatasourceError(
            f"bare TDS exceeds the {MAX_TDS_BYTES}-byte safety limit"
        )
    if not payload.startswith(b"PK"):
        try:
            return payload.decode("utf-8-sig"), None
        except UnicodeDecodeError as exc:
            raise PublishedDatasourceError("downloaded datasource is not UTF-8 TDS") from exc

    try:
        archive = zipfile.ZipFile(io.BytesIO(payload))
    except (OSError, zipfile.BadZipFile) as exc:
        raise PublishedDatasourceError("downloaded TDSX is not a valid ZIP archive") from exc
    with archive:
        members = archive.infolist()
        if len(members) > MAX_ZIP_MEMBERS:
            raise PublishedDatasourceError("TDSX has too many ZIP members")
        tds_members = []
        for member in members:
            normalized = member.filename.replace("\\", "/")
            pieces = [piece for piece in normalized.split("/") if piece]
            if normalized.startswith("/") or ".." in pieces:
                raise PublishedDatasourceError(
                    f"TDSX contains an unsafe member path: {member.filename!r}"
                )
            if not member.is_dir() and normalized.lower().endswith(".tds"):
                if member.flag_bits & 0x1:
                    raise PublishedDatasourceError(
                        f"TDSX contains an encrypted .tds member: {member.filename!r}"
                    )
                if member.file_size > MAX_TDS_BYTES:
                    raise PublishedDatasourceError(
                        f"TDSX .tds member exceeds the {MAX_TDS_BYTES}-byte safety limit"
                    )
                if (
                    member.file_size
                    and member.compress_size
                    and member.file_size / member.compress_size
                    > MAX_COMPRESSION_RATIO
                ):
                    raise PublishedDatasourceError(
                        f"TDSX .tds member has a suspicious compression ratio: {member.filename!r}"
                    )
                tds_members.append(member)
        if len(tds_members) != 1:
            raise PublishedDatasourceError(
                f"TDSX must contain exactly one .tds member; found {len(tds_members)}"
            )
        member = tds_members[0]
        try:
            return archive.read(member).decode("utf-8-sig"), member.filename
        except UnicodeDecodeError as exc:
            raise PublishedDatasourceError("TDSX .tds member is not UTF-8") from exc


def _scan_top_level_words(sql: str) -> list[tuple[str, int, int]]:
    words: list[tuple[str, int, int]] = []
    depth = 0
    index = 0
    while index < len(sql):
        char = sql[index]
        if char in {"'", '"', "`"}:
            quote = char
            index += 1
            while index < len(sql):
                if sql[index] == quote:
                    if index + 1 < len(sql) and sql[index + 1] == quote:
                        index += 2
                        continue
                    index += 1
                    break
                index += 1
            continue
        if char == "[":
            end = sql.find("]", index + 1)
            index = len(sql) if end < 0 else end + 1
            continue
        if sql.startswith("--", index):
            end = sql.find("\n", index + 2)
            index = len(sql) if end < 0 else end + 1
            continue
        if sql.startswith("/*", index):
            end = sql.find("*/", index + 2)
            index = len(sql) if end < 0 else end + 2
            continue
        if char == "(":
            depth += 1
            index += 1
            continue
        if char == ")":
            depth = max(0, depth - 1)
            index += 1
            continue
        if depth == 0 and (char.isalpha() or char == "_"):
            end = index + 1
            while end < len(sql) and (sql[end].isalnum() or sql[end] in {"_", "$"}):
                end += 1
            words.append((sql[index:end].upper(), index, end))
            index = end
            continue
        index += 1
    return words


def _split_projection(projection: str) -> list[str]:
    items = []
    start = 0
    depth = 0
    index = 0
    while index < len(projection):
        char = projection[index]
        if char in {"'", '"', "`"}:
            quote = char
            index += 1
            while index < len(projection):
                if projection[index] == quote:
                    if index + 1 < len(projection) and projection[index + 1] == quote:
                        index += 2
                        continue
                    index += 1
                    break
                index += 1
            continue
        if char == "[":
            end = projection.find("]", index + 1)
            index = len(projection) if end < 0 else end + 1
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth = max(0, depth - 1)
        elif char == "," and depth == 0:
            items.append(projection[start:index].strip())
            start = index + 1
        index += 1
    items.append(projection[start:].strip())
    return [item for item in items if item]


def _unquote_identifier(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and (
        (value[0] == value[-1] and value[0] in {'"', "`"})
        or (value[0] == "[" and value[-1] == "]")
    ):
        return value[1:-1]
    return value


def _output_name(item: str) -> str | None:
    alias = re.search(
        r'(?is)\s+AS\s+(\[[^\]]+\]|"(?:""|[^"])+"|`(?:``|[^`])+`|[A-Za-z_][\w$]*)\s*$',
        item,
    )
    if alias:
        return _unquote_identifier(alias.group(1))
    identifier = r'(?:\[[^\]]+\]|"(?:""|[^"])+"|`(?:``|[^`])+`|[A-Za-z_][\w$]*)'
    if re.fullmatch(rf"{identifier}(?:\s*\.\s*{identifier})*", item.strip()):
        return _unquote_identifier(re.split(r"\s*\.\s*", item.strip())[-1])
    return None


def parse_sql_columns(sql: str) -> list[str]:
    words = _scan_top_level_words(sql)
    select_positions = [row for row in words if row[0] == "SELECT"]
    if len(select_positions) != 1:
        return []
    select = select_positions[0]
    from_word = next(
        (row for row in words if row[0] == "FROM" and row[1] > select[2]),
        None,
    )
    if from_word is None:
        return []
    projection = sql[select[2] : from_word[1]].strip()
    projection = re.sub(r"(?is)^DISTINCT\s+", "", projection, count=1)
    items = _split_projection(projection)
    if not items or any(item.strip() == "*" or item.strip().endswith(".*") for item in items):
        return []
    columns = [_output_name(item) for item in items]
    if any(not column for column in columns):
        return []
    result = [str(column) for column in columns]
    if len({column.casefold() for column in result}) != len(result):
        raise PublishedDatasourceError("Custom SQL exposes duplicate output column names")
    return result


def bare_select_star_table(sql: str) -> str | None:
    normalized = re.sub(r"\s+", " ", sql).strip().rstrip(";").strip()
    match = re.fullmatch(r"(?is)SELECT\s+(?:DISTINCT\s+)?\*\s+FROM\s+(.+)", normalized)
    if not match:
        return None
    remainder = match.group(1).strip()
    if "(" in remainder or "," in remainder:
        return None
    if re.search(
        r"(?i)\b(?:JOIN|WHERE|GROUP\s+BY|ORDER\s+BY|HAVING|UNION|EXCEPT|"
        r"INTERSECT|LIMIT|QUALIFY|ON|USING|CROSS|NATURAL|PIVOT|UNPIVOT|"
        r"TABLESAMPLE)\b",
        remainder,
    ):
        return None
    tokens = remainder.split()
    table = None
    if len(tokens) == 1:
        table = tokens[0]
    elif len(tokens) == 2:
        table = tokens[0]
    elif len(tokens) == 3 and tokens[1].upper() == "AS":
        table = tokens[0]
    if table and re.fullmatch(r'[\[\]"`\w.$]+', table):
        return table
    return None


def canon_warehouse_class(value: str | None) -> str:
    key = re.sub(r"[^a-z0-9]", "", str(value or "").lower())
    if key in {"databricks", "spark", "sparksql", "databrickssql", "delta"}:
        return "databricks"
    return key or "snowflake"


def descriptor_from_tds(tds: str) -> dict[str, Any]:
    try:
        root = ET.fromstring(tds)
    except ET.ParseError as exc:
        raise PublishedDatasourceError(f"downloaded .tds is invalid XML: {exc}") from exc
    relations = [
        item for item in _descendants(root, "relation") if _is_real_relation(item)
    ]
    if len(relations) != 1:
        raise PublishedDatasourceError(
            f"published datasource must expose exactly one usable relation; found {len(relations)}"
        )
    connections = [
        item
        for item in _descendants(root, "connection")
        if str(item.get("class") or "").lower() not in {"", "federated", "sqlproxy"}
    ]
    signatures = {
        (
            str(item.get("class") or ""),
            str(item.get("dbname") or ""),
            str(item.get("schema") or ""),
        )
        for item in connections
    }
    if len(signatures) != 1:
        raise PublishedDatasourceError(
            f"published datasource must expose one warehouse connection; found {len(signatures)}"
        )
    warehouse_class, database, schema = next(iter(signatures))
    relation = relations[0]
    relation_type = str(relation.get("type") or "table").lower()
    descriptor: dict[str, Any] = {
        "db": database,
        "schema": schema,
        "warehouseClass": canon_warehouse_class(warehouse_class),
        "columns": [],
    }
    if relation_type == "text":
        sql = str(relation.text or "").strip()
        columns = parse_sql_columns(sql)
        star_table = bare_select_star_table(sql) if not columns else None
        if star_table:
            descriptor.update(
                {
                    "relationType": "table",
                    "table": star_table,
                    "expandedFrom": "select-star",
                }
            )
        elif columns:
            descriptor.update(
                {"relationType": "text", "sql": sql, "columns": columns}
            )
        else:
            raise PublishedDatasourceError(
                "Custom SQL output columns are unresolved; refusing a zero-column relation"
            )
    else:
        table = str(relation.get("table") or "").strip()
        if not table:
            raise PublishedDatasourceError("physical relation has no table path")
        descriptor.update({"relationType": "table", "table": table})
    return descriptor


def _alias_for(name: str, warehouse_class: str) -> str:
    value = re.sub(r"[^A-Za-z0-9]+", "_", str(name)).strip("_")
    return value if canon_warehouse_class(warehouse_class) == "databricks" else value.upper()


def _quote_ref(name: str, warehouse_class: str) -> str:
    alias = _alias_for(name, warehouse_class)
    if str(name) == alias and not str(name)[:1].isdigit():
        return str(name)
    return '"' + str(name).replace('"', '""') + '"'


def _wrap_sql(sql: str, columns: list[str], warehouse_class: str) -> str:
    if not columns:
        raise PublishedDatasourceError("Custom SQL relation has no output columns")
    projection = ", ".join(
        f"{_quote_ref(column, warehouse_class)} AS {_alias_for(column, warehouse_class)}"
        for column in columns
    )
    return f"SELECT {projection} FROM (\n{sql.strip()}\n) t"


def _qualify_table(table: str, database: str, schema: str) -> str:
    parts = re.findall(r"\[([^\]]*)\]", table)
    if not parts:
        parts = [_unquote_identifier(item) for item in table.split(".")]
    parts = [part for part in parts if part]
    if len(parts) == 1:
        parts = [database, schema, parts[0]]
    elif len(parts) == 2:
        parts = [database, parts[0], parts[1]]
    parts = [part for part in parts if part]
    if len(parts) != 3:
        raise PublishedDatasourceError(
            f"physical table path cannot be fully qualified: {table!r}"
        )
    return "[" + "].[".join(parts) + "]"


def _calculation_snapshot(datasource: ET.Element) -> list[bytes]:
    return [
        ET.tostring(item, encoding="utf-8")
        for item in _descendants(datasource, "calculation")
    ]


def _join_snapshot(datasource: ET.Element) -> list[dict[str, str]]:
    return [
        dict(item.attrib)
        for item in _descendants(datasource, "relation")
        if str(item.get("type") or "").lower() in {"join", "union"}
    ]


def _rebuild_metadata(
    connection: ET.Element, relation_name: str, columns: list[str], warehouse_class: str
) -> None:
    existing = next(iter(_children(connection, "metadata-records")), None)
    cached: dict[str, dict[str, str]] = {}
    if existing is not None:
        for record in _children(existing, "metadata-record"):
            values = {
                _local_name(child.tag): str(child.text or "").strip()
                for child in record
            }
            info = {
                "local-type": values.get("local-type", ""),
                "aggregation": values.get("aggregation", ""),
            }
            remote = values.get("remote-name", "")
            caption = values.get("caption", "")
            if remote:
                cached[_alias_for(remote, warehouse_class)] = info
            if caption:
                cached[caption.casefold()] = info
        connection.remove(existing)
    records = ET.Element("metadata-records")
    for column in columns:
        info = cached.get(_alias_for(column, warehouse_class)) or cached.get(
            column.casefold(), {}
        )
        record = ET.SubElement(records, "metadata-record", {"class": "column"})
        alias = _alias_for(column, warehouse_class)
        fields = [
            ("remote-name", alias),
            ("local-name", f"[{column}]"),
            ("parent-name", f"[{relation_name}]"),
            ("remote-alias", alias),
            ("local-type", info.get("local-type") or "string"),
        ]
        if info.get("aggregation"):
            fields.append(("aggregation", info["aggregation"]))
        fields.append(("caption", column))
        for name, value in fields:
            ET.SubElement(record, name).text = value
    connection.append(records)


def _hydrate_one(datasource: ET.Element, descriptor: dict[str, Any]) -> dict[str, Any]:
    connection = _connection(datasource)
    if connection is None:
        raise PublishedDatasourceError("sqlproxy datasource has no direct connection")
    placeholders = [
        item for item in _descendants(connection, "relation") if _is_placeholder(item)
    ]
    if len(placeholders) != 1:
        raise PublishedDatasourceError(
            f"sqlproxy datasource must contain exactly one placeholder relation; found {len(placeholders)}"
        )
    before_attributes = dict(datasource.attrib)
    before_calculations = _calculation_snapshot(datasource)
    before_joins = _join_snapshot(datasource)
    placeholder = placeholders[0]
    relation_name = str(placeholder.get("name") or "")
    if not relation_name or relation_name.lower() == "sqlproxy":
        relation_name = str(datasource.get("caption") or datasource.get("name") or "PublishedDS")

    warehouse_class = canon_warehouse_class(descriptor.get("warehouseClass"))
    database = str(descriptor.get("db") or "")
    schema = str(descriptor.get("schema") or "")
    replacement = ET.Element("relation", {"name": relation_name})
    if descriptor.get("relationType") == "table":
        replacement.set("type", "table")
        replacement.set(
            "table",
            _qualify_table(str(descriptor.get("table") or ""), database, schema),
        )
    elif descriptor.get("relationType") == "text":
        columns = [str(item) for item in descriptor.get("columns") or []]
        replacement.set("type", "text")
        replacement.text = _wrap_sql(
            str(descriptor.get("sql") or ""), columns, warehouse_class
        )
    else:
        raise PublishedDatasourceError(
            f"unsupported published relation type: {descriptor.get('relationType')!r}"
        )

    parents = {id(child): parent for parent in datasource.iter() for child in parent}
    parent = parents.get(id(placeholder))
    if parent is None:
        raise PublishedDatasourceError("could not locate sqlproxy placeholder parent")
    position = list(parent).index(placeholder)
    parent.remove(placeholder)
    parent.insert(position, replacement)
    connection.set("class", warehouse_class)
    if database:
        connection.set("dbname", database)
    if schema:
        connection.set("schema", schema)
    for attribute in ("channel", "directory", "port", "server"):
        connection.attrib.pop(attribute, None)
    if descriptor.get("relationType") == "text":
        _rebuild_metadata(
            connection,
            relation_name,
            [str(item) for item in descriptor.get("columns") or []],
            warehouse_class,
        )

    if dict(datasource.attrib) != before_attributes:
        raise PublishedDatasourceError("hydration changed Tableau datasource identity")
    if _calculation_snapshot(datasource) != before_calculations:
        raise PublishedDatasourceError("hydration changed Tableau calculations")
    if _join_snapshot(datasource) != before_joins:
        raise PublishedDatasourceError("hydration changed Tableau join/union structure")
    return {
        "identityPreserved": True,
        "calculationsPreserved": len(before_calculations),
        "joinsPreserved": len(before_joins),
        "relationType": descriptor["relationType"],
        "columns": len(descriptor.get("columns") or []),
    }


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )


def _rest_call(api, operation: str, function):
    """Match discovery's outer retry when a 401 escapes the client retry."""
    for attempt in range(1, 4):
        try:
            return function()
        except tableau_rest.TableauError as exc:
            if "401" not in str(exc) or attempt == 3:
                raise PublishedDatasourceError(
                    f"{operation} failed: {str(exc).strip()[:800]}"
                ) from exc
            try:
                api.refresh_token()
            except Exception:
                pass
            time.sleep(attempt)
    raise AssertionError("unreachable")


def resolve_and_hydrate(
    twb_path: str | Path,
    output_path: str | Path,
    *,
    descriptors_path: str | Path,
    lineage_path: str | Path,
    evidence_path: str | Path,
    api=tableau_rest,
) -> dict[str, Any]:
    """Resolve every unresolved sqlproxy datasource and atomically hydrate a copy."""
    source = Path(twb_path)
    output = Path(output_path)
    descriptors_file = Path(descriptors_path)
    lineage_file = Path(lineage_path)
    evidence_file = Path(evidence_path)
    if source.resolve() == output.resolve():
        raise PublishedDatasourceError("hydration output must be a copy, not the source .twb")
    source_bytes = source.read_bytes()
    try:
        root = ET.fromstring(source_bytes)
    except ET.ParseError as exc:
        raise PublishedDatasourceError(f"workbook .twb is invalid XML: {exc}") from exc
    targets = sqlproxy_datasources(root)
    base = {
        "contract_version": 1,
        "source": str(source),
        "sourceSha256": hashlib.sha256(source_bytes).hexdigest(),
        "hydrated": str(output),
        "datasources": [],
    }
    output.unlink(missing_ok=True)
    if not targets:
        result = {**base, "status": "not-required", "resolved": 0}
        _write_json(descriptors_file, [])
        _write_json(lineage_file, result)
        _write_json(
            evidence_file,
            {
                "contract_version": 1,
                "status": "not-required",
                "sourceSha256": base["sourceSha256"],
            },
        )
        return result

    descriptors: list[dict[str, Any]] = []
    by_url: dict[str, dict[str, Any]] = {}
    try:
        for index, datasource in enumerate(targets, 1):
            identity = datasource_identity(datasource, index)
            content_url = identity["contentUrl"]
            if not content_url:
                raise PublishedDatasourceError(
                    f"sqlproxy datasource {identity['name'] or identity['caption']!r} has no content URL"
                )
            descriptor = by_url.get(content_url.casefold())
            if descriptor is None:
                matches = _rest_call(
                    api,
                    f"published datasource lookup for contentUrl={content_url!r}",
                    lambda: api.find_datasources_by_content_url(content_url),
                )
                exact = [
                    item
                    for item in matches
                    if str(item.get("contentUrl") or "") == content_url
                ]
                if len(exact) != 1:
                    raise PublishedDatasourceError(
                        f"contentUrl={content_url!r} resolved to {len(exact)} exact REST datasources"
                    )
                record = exact[0]
                datasource_id = str(record.get("id") or "")
                if not datasource_id:
                    raise PublishedDatasourceError(
                        f"contentUrl={content_url!r} REST result has no datasource id"
                    )
                payload = _rest_call(
                    api,
                    f"published datasource content download for {datasource_id!r}",
                    lambda: api.download_datasource_content(datasource_id),
                )
                tds, member = _safe_tds_from_content(payload)
                descriptor = descriptor_from_tds(tds)
                descriptor.update(
                    {
                        "contentUrl": content_url,
                        "pdsName": record.get("name"),
                        "pdsLuid": datasource_id,
                        "contentSha256": hashlib.sha256(payload).hexdigest(),
                        "tdsMember": member,
                    }
                )
                by_url[content_url.casefold()] = descriptor
                descriptors.append(descriptor)
            hydration = _hydrate_one(datasource, descriptor)
            base["datasources"].append(
                {
                    **identity,
                    "pdsLuid": descriptor["pdsLuid"],
                    "pdsName": descriptor.get("pdsName"),
                    "contentSha256": descriptor["contentSha256"],
                    "tdsMember": descriptor.get("tdsMember"),
                    **hydration,
                }
            )
        unresolved = sqlproxy_datasources(root)
        if unresolved:
            raise PublishedDatasourceError(
                f"{len(unresolved)} sqlproxy datasource(s) remain unresolved after hydration"
            )
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_name(f"{output.name}.tmp")
        ET.ElementTree(root).write(
            temporary, encoding="utf-8", xml_declaration=True
        )
        temporary.replace(output)
        output_sha = hashlib.sha256(output.read_bytes()).hexdigest()
        result = {
            **base,
            "status": "hydrated",
            "resolved": len(targets),
            "publishedObjects": len(descriptors),
            "hydratedSha256": output_sha,
        }
        _write_json(descriptors_file, descriptors)
        _write_json(lineage_file, result)
        _write_json(
            evidence_file,
            {
                "contract_version": 1,
                "status": "pass",
                "sourceSha256": base["sourceSha256"],
                "hydratedSha256": output_sha,
                "resolved": len(targets),
                "allDatasourceIdentitiesPreserved": all(
                    item["identityPreserved"] for item in base["datasources"]
                ),
                "allCalculationsPreserved": True,
                "allJoinStructuresPreserved": True,
                "unresolved": 0,
            },
        )
        return result
    except Exception as exc:
        _write_json(descriptors_file, descriptors)
        failed = {
            **base,
            "status": "failed",
            "resolved": len(base["datasources"]),
            "error": str(exc),
        }
        _write_json(lineage_file, failed)
        _write_json(
            evidence_file,
            {
                "contract_version": 1,
                "status": "failed",
                "sourceSha256": base["sourceSha256"],
                "resolved": len(base["datasources"]),
                "error": str(exc),
                "hydratedWritten": False,
            },
        )
        if isinstance(exc, PublishedDatasourceError):
            raise
        raise PublishedDatasourceError(str(exc)) from exc
