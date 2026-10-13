#!/usr/bin/env python3
"""Offline Spotfire manifest -> Sigma data-model and workbook specifications.

The input is a tolerant ``spotfire-manifest-v1`` object.  Source table
resolution is intentionally strict: embedded, imported, on-demand, and
data-function tables require an explicit source-map entry that names their
landed warehouse target.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
from xml.sax.saxutils import quoteattr

import spotfire_expr


HERE = Path(__file__).resolve().parent
CATALOG_PATH = HERE.parent / "refs" / "catalogs" / "coverage-catalog.json"
REQUIRES_SOURCE_MAP = {"embedded", "imported", "on-demand", "data-function"}
GRID_COLUMNS = 24
CONTROL_ROWS = 3
CANVAS_ROWS = 24
MIN_VISUAL_ROWS = 4


class ConversionError(Exception):
    pass


class SourceMapError(ConversionError):
    pass


def _read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def _write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp.%d" % os.getpid())
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def _as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, tuple):
        return list(value)
    if isinstance(value, dict):
        return list(value.values())
    return [value]


def _first(value, *keys):
    if not isinstance(value, dict):
        return None
    for key in keys:
        if key in value and value[key] is not None:
            return value[key]
    return None


def _slug(value, fallback="item"):
    result = re.sub(r"[^a-z0-9]+", "-", str(value or "").casefold()).strip("-")
    return result or fallback


def _stable_fallback(prefix, value):
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"),
                         ensure_ascii=True)
    return "%s-%s" % (
        prefix,
        hashlib.sha256(payload.encode("utf-8")).hexdigest()[:12],
    )


class _Ids:
    def __init__(self):
        self.used = set()

    def make(self, prefix, value):
        base = "%s-%s" % (prefix, _slug(value))
        candidate = base
        number = 2
        while candidate in self.used:
            candidate = "%s-%d" % (base, number)
            number += 1
        self.used.add(candidate)
        return candidate


class _Gaps:
    def __init__(self):
        self.rows = []
        self._seen = set()

    def add(self, code, reason, object_type, object_id, **extra):
        row = {
            "code": code,
            "object_type": object_type,
            "object_id": str(object_id),
            "reason": reason,
        }
        row.update({key: value for key, value in extra.items()
                    if value is not None})
        signature = json.dumps(row, sort_keys=True, ensure_ascii=True)
        if signature not in self._seen:
            self._seen.add(signature)
            self.rows.append(row)

    def sorted(self):
        return sorted(
            self.rows,
            key=lambda row: (
                row["object_type"], row["object_id"], row["code"],
                row["reason"],
            ),
        )


def _normalize_token(value):
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", str(value or ""))
    return re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")


def _load_visual_catalog():
    raw = _read_json(CATALOG_PATH)
    spec = raw.get("categories", {}).get("visuals", {})
    sigma = spec.get("sigma") or {}
    aliases = spec.get("aliases") or {}
    mapping = {}
    for source, target in sigma.items():
        key = _normalize_token(source)
        if key:
            mapping[key] = target
    for source, canonical in aliases.items():
        key = _normalize_token(source)
        target = sigma.get(canonical)
        if key and target:
            mapping[key] = target
    return mapping


VISUAL_KIND = _load_visual_catalog()


def visual_kind(visual):
    raw = _first(visual, "type", "visual_type", "visualType", "kind",
                 "class", "class_name", "className")
    token = _normalize_token(raw)
    direct = VISUAL_KIND.get(token)
    if direct:
        return direct
    for alias in sorted(VISUAL_KIND, key=len, reverse=True):
        if token.endswith("-" + alias) or token.endswith(alias):
            return VISUAL_KIND[alias]
    return None


def classify_visual(visual):
    raw = _first(visual, "type", "visual_type", "visualType", "kind",
                 "class", "class_name", "className")
    target = visual_kind(visual)
    return {
        "source": raw,
        "sigma": target,
        "status": "auto" if target else "unhandled",
    }


def _manifest_tables(manifest):
    tables = _first(manifest, "tables", "data_tables", "dataTables")
    model = manifest.get("model") if isinstance(manifest, dict) else None
    if tables is None and isinstance(model, dict):
        tables = _first(model, "tables", "data_tables", "dataTables")
    return _as_list(tables)


def _manifest_pages(manifest):
    pages = _first(manifest, "pages", "document_pages", "documentPages")
    presentation = (
        manifest.get("presentation") if isinstance(manifest, dict) else None
    )
    if pages is None and isinstance(presentation, dict):
        pages = _first(presentation, "pages", "document_pages",
                       "documentPages")
    return _as_list(pages)


def _table_name(table, index=None):
    return str(_first(table, "name", "title", "display_name", "displayName",
                      "id", "key", "source_id") or
               "Table %d" % ((index or 0) + 1))


def _table_id(table, index=None):
    return str(_first(table, "id", "key", "source_id", "name", "title") or
               _stable_fallback("table", table))


def _table_columns(table):
    return _as_list(_first(table, "columns", "data_columns", "dataColumns"))


def _column_name(column, index=None):
    if isinstance(column, str):
        return column
    return str(_first(column, "name", "title", "display_name", "displayName",
                      "id", "key", "source_id") or
               "Column %d" % ((index or 0) + 1))


def _column_expression(column):
    if not isinstance(column, dict):
        return None
    value = _first(column, "expression", "formula", "calculation",
                   "calculated_expression", "calculatedExpression")
    if isinstance(value, dict):
        value = _first(value, "expression", "formula", "text")
    return value if isinstance(value, str) and value.strip() else None


def _column_type(column):
    if not isinstance(column, dict):
        return ""
    return str(_first(column, "data_type", "dataType", "type",
                      "storage_type", "storageType") or "").casefold()


def _foreign_qualified_references(references, allowed_tables):
    allowed = {str(value).casefold() for value in allowed_tables if value}
    return sorted({
        reference.rsplit(".", 1)[0]
        for reference in references
        if "." in reference
        and reference.rsplit(".", 1)[0].casefold() not in allowed
    }, key=str.casefold)


def _source_kind(table):
    source = table.get("source") if isinstance(table, dict) else None
    if isinstance(source, dict):
        raw = _first(source, "kind", "type", "mode", "load_mode", "loadMode")
    elif isinstance(source, str):
        raw = source
    else:
        raw = _first(table, "source_type", "sourceType", "storage",
                     "load_mode", "loadMode", "data_source_type")
    token = _normalize_token(raw)
    if "data-function" in token or "datafunction" in token:
        return "data-function"
    if "on-demand" in token or "ondemand" in token:
        return "on-demand"
    if "import" in token:
        return "imported"
    if "embedded" in token or "in-memory" in token:
        return "embedded"
    aliases = {
        "in-memory": "embedded",
        "embedded-data": "embedded",
        "import": "imported",
        "on-demand-data": "on-demand",
        "ondemand": "on-demand",
        "datafunction": "data-function",
        "data-function-output": "data-function",
    }
    return aliases.get(token, token or "unknown")


def _source_map_parts(raw):
    defaults = {}
    entries = raw
    if isinstance(raw, dict):
        defaults = {
            "connectionId": _first(raw, "connectionId", "connection_id"),
            "database": raw.get("database"),
            "schema": raw.get("schema"),
        }
        entries = _first(raw, "tables", "sources", "mappings", "entries")
        if entries is None:
            reserved = {
                "schema_version", "version", "connectionId", "connection_id",
                "database", "schema",
            }
            entries = {key: value for key, value in raw.items()
                       if key not in reserved}
    normalized = []
    if isinstance(entries, dict):
        for key, value in entries.items():
            normalized.append((str(key), value))
    else:
        for value in _as_list(entries):
            if not isinstance(value, dict):
                continue
            key = _first(value, "source", "source_table", "sourceTable",
                         "spotfire_table", "spotfireTable", "source_id",
                         "id", "name")
            target = _first(value, "target", "warehouse")
            normalized.append((str(key or ""), target if target is not None else value))
    return defaults, normalized


def _mapping_for(table, source_map):
    defaults, entries = _source_map_parts(source_map or {})
    candidates = {
        str(_first(table, "id", "key", "source_id") or "").casefold(),
        str(_first(table, "name", "title", "display_name", "displayName") or "").casefold(),
    }
    candidates.discard("")
    target_keys = {
        "target", "warehouse", "path", "table", "table_name",
        "tableName", "target_table", "targetTable", "database",
        "schema", "connectionId", "connection_id",
    }
    for key, value in entries:
        if key.casefold() in candidates:
            if not isinstance(value, dict) or target_keys & set(value):
                return defaults, value
            continue
        if isinstance(value, dict):
            aliases = {
                str(_first(value, "source", "source_table", "sourceTable",
                           "spotfire_table", "spotfireTable",
                           "source_id") or "").casefold()
            }
            if candidates & aliases and target_keys & set(value):
                return defaults, value
    return defaults, None


def _path_from_mapping(mapping, defaults, connection_id, database, schema):
    if isinstance(mapping, str):
        mapping = {"table": mapping}
    elif isinstance(mapping, list):
        mapping = {"path": mapping}
    elif not isinstance(mapping, dict):
        mapping = {}
    target = mapping.get("target")
    if isinstance(target, dict):
        mapping = {**mapping, **target}
    path = mapping.get("path")
    if isinstance(path, str):
        path = [part for part in path.split(".") if part]
    if path:
        path = [str(part) for part in path]
        if len(path) == 1:
            path = [
                mapping.get("database") or database or defaults.get("database"),
                mapping.get("schema") or schema or defaults.get("schema"),
                path[0],
            ]
        elif len(path) == 2:
            path = [
                mapping.get("database") or database or defaults.get("database"),
                path[0], path[1],
            ]
    else:
        target_table = _first(mapping, "table", "table_name", "tableName",
                              "target_table", "targetTable", "name")
        if target_table:
            path = [
                mapping.get("database") or database or defaults.get("database"),
                mapping.get("schema") or schema or defaults.get("schema"),
                str(target_table),
            ]
    connection = (
        _first(mapping, "connectionId", "connection_id")
        or connection_id
        or defaults.get("connectionId")
    )
    return connection, path


def _direct_source_mapping(table):
    source = table.get("source") if isinstance(table, dict) else None
    if not isinstance(source, dict):
        source = {}
    path = source.get("path")
    if path:
        return source
    target_table = _first(source, "table", "table_name", "tableName")
    if target_table:
        return source
    return None


def resolve_sources(manifest, source_map, connection_id=None,
                    database=None, schema=None):
    """Resolve every source table or raise before conversion emits a spec."""
    resolved = {}
    failures = []
    for index, table in enumerate(_manifest_tables(manifest)):
        if not isinstance(table, dict):
            failures.append("table[%d] is not an object" % index)
            continue
        table_id = _table_id(table, index)
        table_name = _table_name(table, index)
        source_kind = _source_kind(table)
        defaults, mapping = _mapping_for(table, source_map)
        if source_kind in REQUIRES_SOURCE_MAP and mapping is None:
            failures.append(
                "%s (%s): %s source requires an explicit source-map entry" %
                (table_name, table_id, source_kind)
            )
            continue
        if mapping is None:
            mapping = _direct_source_mapping(table)
        if mapping is None:
            failures.append(
                "%s (%s): no source-map entry or explicit external warehouse path" %
                (table_name, table_id)
            )
            continue
        connection, path = _path_from_mapping(
            mapping, defaults, connection_id, database, schema
        )
        if not connection:
            failures.append(
                "%s (%s): target connectionId is missing" %
                (table_name, table_id)
            )
        if not path or len(path) != 3 or any(
                not str(part or "").strip() for part in path):
            failures.append(
                "%s (%s): target path must resolve to [database, schema, table]" %
                (table_name, table_id)
            )
        if connection and path and len(path) == 3 and all(
                str(part or "").strip() for part in path):
            resolved[table_id] = {
                "connectionId": str(connection),
                "path": [str(part) for part in path],
                "source_kind": source_kind,
            }
    if failures:
        raise SourceMapError(
            "source-map resolution failed closed:\n  - " +
            "\n  - ".join(sorted(failures, key=str.casefold))
        )
    return resolved


def _relationship_endpoint_columns(value, side):
    nested = value.get(side) if isinstance(value, dict) else None
    aliases = {
        "left": ("from", "source"),
        "right": ("to", "target"),
    }
    if not isinstance(nested, dict):
        for key in aliases.get(side, ()):
            candidate = value.get(key) if isinstance(value, dict) else None
            if isinstance(candidate, dict):
                nested = candidate
                break
    nested = nested or {}
    table = _first(nested, "table", "table_id", "tableId", "name")
    columns = _as_list(_first(nested, "column_ids", "columnIds"))
    column = _first(nested, "column", "column_id", "columnId", "key")
    if column is not None and not columns:
        columns = [column]
    if table is None and isinstance(value, dict):
        prefixes = ("left", "from", "source") if side == "left" else (
            "right", "to", "target")
        for prefix in prefixes:
            table = table or _first(
                value, prefix + "_table", prefix + "Table")
            flat_column = _first(
                value, prefix + "_column", prefix + "Column")
            if flat_column is not None and not columns:
                columns = [flat_column]
    return table, [str(value) for value in columns if value is not None]


def _relationship_endpoint(value, side):
    """Compatibility view of one endpoint for census callers."""
    table, columns = _relationship_endpoint_columns(value, side)
    return table, columns[0] if columns else None


def _manifest_relationships(manifest):
    relationships = _first(manifest, "relationships", "relations", "joins")
    model = manifest.get("model") if isinstance(manifest, dict) else None
    if relationships is None and isinstance(model, dict):
        relationships = _first(model, "relationships", "relations", "joins")
    relationships = list(_as_list(relationships))
    for table in _manifest_tables(manifest):
        if isinstance(table, dict):
            relationships.extend(_as_list(
                _first(table, "relationships", "relations", "joins")
            ))
    return relationships


def _build_data_model(manifest, resolved_sources, gaps, name=None):
    ids = _Ids()
    elements = []
    contexts = {}
    table_aliases = {}
    for table_index, table in enumerate(_manifest_tables(manifest)):
        table_id = _table_id(table, table_index)
        table_name = _table_name(table, table_index)
        source = resolved_sources[table_id]
        element_id = ids.make("dm", table_id)
        target_table = source["path"][-1]
        columns = []
        column_by_name = {}
        for column_index, column in enumerate(_table_columns(table)):
            column_name = _column_name(column, column_index)
            expression = _column_expression(column)
            column_id = ids.make("dmc", "%s-%s" % (table_id, column_name))
            if expression:
                translated = spotfire_expr.translate(expression)
                if not translated.supported:
                    gaps.add(
                        translated.warning_id,
                        translated.reason,
                        "column",
                        "%s.%s" % (table_id, column_name),
                        table=table_name,
                        expression=expression,
                    )
                    continue
                foreign_tables = _foreign_qualified_references(
                    translated.references,
                    (
                        table_id,
                        table_name,
                        _first(
                            table, "key", "source_id", "display_name",
                            "displayName",
                        ),
                    ),
                )
                if foreign_tables:
                    gaps.add(
                        "SPOTFIRE-CROSS-TABLE-CALC-UNSUPPORTED",
                        "calculated column references another Spotfire table: %s"
                        % ", ".join(foreign_tables),
                        "column",
                        "%s.%s" % (table_id, column_name),
                        table=table_name,
                        expression=expression,
                    )
                    continue
                formula = translated.formula
            else:
                external_name = (
                    _first(column, "external_name", "externalName")
                    if isinstance(column, dict) else None
                )
                formula = "[%s/%s]" % (
                    target_table, external_name or column_name
                )
            item = {"id": column_id, "name": column_name, "formula": formula}
            columns.append(item)
            column_by_name[column_name.casefold()] = item
            if isinstance(column, dict):
                for alias in (
                    _first(column, "id", "key", "source_id"),
                    _first(column, "external_name", "externalName"),
                ):
                    if alias:
                        column_by_name[str(alias).casefold()] = item
        if not columns:
            gaps.add(
                "SPOTFIRE-TABLE-NO-COLUMNS",
                "table has no convertible columns",
                "table", table_id, table=table_name,
            )
        for operation_index, operation in enumerate(_as_list(
                _first(table, "source_operations", "sourceOperations",
                       "operations"))):
            if not isinstance(operation, dict):
                continue
            operation_expression = _first(
                operation, "expression", "formula", "script"
            )
            operation_type = _normalize_token(
                _first(operation, "operation_type", "operationType", "type")
            )
            if operation_expression or (
                    operation_type and operation_type not in (
                        "data-source-operation", "datasource-operation",
                        "load", "select-source")):
                gaps.add(
                    "SPOTFIRE-SOURCE-OPERATION-UNSUPPORTED",
                    "source operation must be reproduced in the landed warehouse table",
                    "source-operation",
                    _first(operation, "id", "source_id", "name") or
                    "%s-operation-%d" % (table_id, operation_index),
                    table=table_name,
                )
        element = {
            "id": element_id,
            "kind": "table",
            "name": table_name,
            "source": {
                "kind": "warehouse-table",
                "connectionId": source["connectionId"],
                "path": source["path"],
            },
            "columns": columns,
            "order": [column["id"] for column in columns],
        }
        elements.append(element)
        context = {
            "id": table_id,
            "name": table_name,
            "table": table,
            "element": element,
            "columns": column_by_name,
            "source": source,
        }
        contexts[table_id] = context
        for alias in (table_id, table_name,
                      _first(table, "key", "source_id", "display_name",
                             "displayName")):
            if alias:
                table_aliases[str(alias).casefold()] = context

    for relation_index, relation in enumerate(_manifest_relationships(manifest)):
        if not isinstance(relation, dict):
            gaps.add(
                "SPOTFIRE-RELATION-SHAPE",
                "relationship is not an object",
                "relationship", "relationship-%d" % relation_index,
            )
            continue
        left_table, left_columns = _relationship_endpoint_columns(
            relation, "left"
        )
        right_table, right_columns = _relationship_endpoint_columns(
            relation, "right"
        )
        left = table_aliases.get(str(left_table or "").casefold())
        right = table_aliases.get(str(right_table or "").casefold())
        left_cols = [
            left["columns"].get(str(column).casefold())
            for column in left_columns
        ] if left else []
        right_cols = [
            right["columns"].get(str(column).casefold())
            for column in right_columns
        ] if right else []
        relation_id = str(_first(relation, "id", "source_id", "name") or
                          "relationship-%d" % relation_index)
        if (
                not left or not right or not left_cols or not right_cols
                or len(left_cols) != len(right_cols)
                or any(column is None for column in left_cols + right_cols)):
            gaps.add(
                "SPOTFIRE-RELATION-UNRESOLVED",
                "relationship endpoint column_ids must be non-empty, equal-length "
                "arrays that resolve to converted table columns",
                "relationship", relation_id,
            )
            continue
        left["element"].setdefault("relationships", []).append({
            "id": ids.make("rel", relation_id),
            "name": right["name"],
            "targetElementId": right["element"]["id"],
            "keys": [
                {
                    "sourceColumnId": left_col["id"],
                    "targetColumnId": right_col["id"],
                }
                for left_col, right_col in zip(left_cols, right_cols)
            ],
        })

    document = manifest.get("document") if isinstance(manifest.get("document"), dict) else {}
    manifest_name = _first(
        manifest, "name", "title", "document_name", "documentName"
    ) or _first(document, "name", "title") or _first(
        manifest.get("source") or {}, "name", "title"
    ) or "Spotfire Document"
    spec = {
        "name": name or "%s (Spotfire Model)" % manifest_name,
        "schemaVersion": 1,
        "pages": [{"id": "model", "name": "Model", "elements": elements}],
    }
    return spec, contexts, table_aliases


def _page_name(page, index):
    return str(_first(page, "name", "title", "display_name", "displayName",
                      "id", "key", "source_id") or
               "Page %d" % (index + 1))


def _page_id(page, index):
    return str(_first(page, "id", "key", "source_id", "name", "title") or
               "page-%d" % (index + 1))


def _page_visuals(page):
    return _as_list(_first(page, "visuals", "visualizations", "views"))


def _visual_id(visual, index):
    return str(_first(visual, "id", "key", "source_id", "name", "title") or
               _stable_fallback("visual", visual))


def _visual_name(visual, index):
    return str(_first(visual, "title", "name", "display_name", "displayName",
                      "id", "key", "source_id") or
               "Visual %d" % (index + 1))


AXIS_ORDER = (
    "rows", "columns", "category", "x", "x-axis", "y", "y-axis",
    "value", "values", "color", "series", "size", "label", "labels",
    "trellis",
)
DIMENSION_ROLES = {
    "rows", "columns", "category", "categories", "x", "x-axis",
    "color", "series", "label", "labels", "trellis",
}
MEASURE_ROLES = {"y", "y-axis", "value", "values", "size"}


def _axis_expression(value):
    if isinstance(value, str):
        return value
    if not isinstance(value, dict):
        return None
    expression = _first(
        value, "expression", "formula", "calculation", "column", "field"
    )
    if isinstance(expression, dict):
        expression = _first(expression, "expression", "formula", "text",
                            "name")
    return expression if isinstance(expression, str) else None


def _flatten_axis_value(value):
    if isinstance(value, list):
        result = []
        for item in value:
            result.extend(_flatten_axis_value(item))
        return result
    if isinstance(value, dict):
        # Authoritative exporter axes carry one direct ``expression`` plus a
        # ``columns`` evidence list. The latter is lineage, not a replacement
        # list of axis fields.
        if _axis_expression(value):
            return [value]
        nested = _first(value, "expressions", "fields", "items", "columns")
        if nested is not None:
            result = []
            for item in _as_list(nested):
                if isinstance(item, dict):
                    merged = dict(item)
                    for key in ("name", "title", "role"):
                        if key not in merged and key in value:
                            merged[key] = value[key]
                    result.extend(_flatten_axis_value(merged))
                else:
                    result.extend(_flatten_axis_value(item))
            return result
    return [value]


def iter_axis_fields(visual):
    axes = _first(visual, "axes", "axis")
    found = []
    if isinstance(axes, dict):
        keys = list(axes)
        ordered = [key for wanted in AXIS_ORDER for key in keys
                   if _normalize_token(key) == wanted]
        ordered += sorted(
            [key for key in keys if key not in ordered],
            key=lambda key: str(key).casefold(),
        )
        for key in ordered:
            for value in _flatten_axis_value(axes[key]):
                found.append((_normalize_token(key), value))
    elif isinstance(axes, list):
        for axis in axes:
            if isinstance(axis, dict):
                role = _first(
                    axis, "role", "axis_type", "axisType", "name", "axis",
                    "type",
                ) or "field"
                values = _first(axis, "expressions", "fields", "items")
                for value in _flatten_axis_value(
                        values if values is not None else axis):
                    found.append((_normalize_token(role), value))
    for key in ("columns", "fields"):
        if key in visual and visual[key] is not axes:
            for value in _flatten_axis_value(visual[key]):
                found.append((_normalize_token(key), value))
    return found


def _visual_table(visual, table_aliases, expression_references=()):
    raw = _first(visual, "table", "table_id", "tableId", "data_table",
                 "dataTable", "dataTableName", "data_table_id")
    data = visual.get("data") if isinstance(visual.get("data"), dict) else {}
    raw = raw or _first(data, "table", "table_id", "tableId", "name")
    if raw:
        return table_aliases.get(str(raw).casefold())
    candidates = set()
    for reference in expression_references:
        if "." in reference:
            table_name = reference.rsplit(".", 1)[0]
            context = table_aliases.get(table_name.casefold())
            if context:
                candidates.add(context["id"])
    if len(candidates) == 1:
        wanted = next(iter(candidates))
        return next(context for context in table_aliases.values()
                    if context["id"] == wanted)
    unique = {context["id"]: context for context in table_aliases.values()}
    if len(unique) == 1:
        return next(iter(unique.values()))
    return None


def _masterize(formula, master_name, available):
    missing = []

    def replace(match):
        raw = match.group(1)
        if "/" in raw:
            return match.group(0)
        column = available.get(raw.casefold())
        if column is None:
            missing.append(raw)
            return match.group(0)
        return "[%s/%s]" % (master_name, column["name"])

    return re.sub(r"\[([^\]]+)\]", replace, formula), missing


def _translated_field(role, value, context, master, ids, gaps,
                      visual_id, visual_name):
    expression = _axis_expression(value)
    if not expression:
        gaps.add(
            "SPOTFIRE-AXIS-EXPRESSION-MISSING",
            "visual axis item has no expression",
            "visual", visual_id, visual=visual_name, axis=role,
        )
        return None
    expression = expression.strip()
    if expression.startswith("<") and expression.endswith(">"):
        inner = expression[1:-1].strip()
        if re.fullmatch(r"\[[^\]]+\](?:\.\[[^\]]+\])?", inner):
            expression = inner
    translated = spotfire_expr.translate(expression)
    if not translated.supported:
        gaps.add(
            translated.warning_id,
            translated.reason,
            "visual", visual_id, visual=visual_name, axis=role,
            expression=expression,
        )
        return None
    foreign_tables = _foreign_qualified_references(
        translated.references,
        (
            context["id"],
            context["name"],
            _first(
                context["table"], "key", "source_id", "display_name",
                "displayName",
            ),
        ),
    )
    if foreign_tables:
        gaps.add(
            "SPOTFIRE-CROSS-TABLE-VISUAL-CALC-UNSUPPORTED",
            "visual expression references another Spotfire table: %s"
            % ", ".join(foreign_tables),
            "visual", visual_id, visual=visual_name, axis=role,
            expression=expression,
        )
        return None
    formula, missing = _masterize(
        translated.formula, master["name"], context["columns"]
    )
    if missing:
        gaps.add(
            "SPOTFIRE-AXIS-COLUMN-UNRESOLVED",
            "axis references columns absent from its resolved table: %s" %
            ", ".join(sorted(set(missing), key=str.casefold)),
            "visual", visual_id, visual=visual_name, axis=role,
            expression=expression,
        )
        return None
    name = (
        _first(value, "name", "title", "display_name", "displayName")
        if isinstance(value, dict) else None
    ) or expression
    column = {
        "id": ids.make("vcol", "%s-%s-%s" % (visual_id, role, name)),
        "name": str(name),
        "formula": formula,
    }
    semantic = translated.kind
    if role in MEASURE_ROLES:
        semantic = "measure"
    elif role in DIMENSION_ROLES and translated.kind != "measure":
        semantic = "dimension"
    return {
        "column": column,
        "role": role,
        "semantic": semantic,
        "result": translated,
    }


def _emit_visual(kind, visual_id, name, master, fields, ids, gaps):
    columns = [field["column"] for field in fields]
    dimensions = [field["column"]["id"] for field in fields
                  if field["semantic"] == "dimension"]
    measures = [field["column"]["id"] for field in fields
                if field["semantic"] == "measure"]
    by_role = {}
    field_by_id = {}
    for field in fields:
        column_id = field["column"]["id"]
        by_role.setdefault(field["role"], []).append(column_id)
        field_by_id[column_id] = field
    element = {
        "id": ids.make("viz", visual_id),
        "kind": kind,
        "name": name,
        "source": {"kind": "table", "elementId": master["id"]},
        "columns": columns,
    }
    if kind == "table":
        if dimensions and measures:
            element["groupings"] = [{
                "id": ids.make("group", visual_id),
                "groupBy": dimensions,
                "calculations": measures,
            }]
    elif kind == "pivot-table":
        if not dimensions or not measures:
            gaps.add(
                "SPOTFIRE-VISUAL-BINDING-INCOMPLETE",
                "cross-table requires at least one dimension and one measure",
                "visual", visual_id, visual=name,
            )
            return None, []
        row_ids = by_role.get("rows") or dimensions[:1]
        column_ids = by_role.get("columns") or [
            column_id for column_id in dimensions
            if column_id not in row_ids
        ]
        element["rowsBy"] = [
            {"columnId": column_id} for column_id in row_ids
        ]
        if column_ids:
            element["columnsBy"] = [
                {"columnId": column_id} for column_id in column_ids
            ]
        element["values"] = measures
    elif kind == "kpi-chart":
        if not measures:
            gaps.add(
                "SPOTFIRE-VISUAL-BINDING-INCOMPLETE",
                "KPI requires an aggregate value expression",
                "visual", visual_id, visual=name,
            )
            return None, []
        element["columns"] = [
            column for column in columns if column["id"] == measures[0]
        ]
        element["value"] = {"columnId": measures[0]}
    elif kind in ("bar-chart", "line-chart", "area-chart", "combo-chart"):
        x_values = by_role.get("x") or by_role.get("x-axis") or dimensions
        y_values = by_role.get("y") or by_role.get("y-axis") or measures
        if not x_values or not y_values:
            gaps.add(
                "SPOTFIRE-VISUAL-BINDING-INCOMPLETE",
                "%s requires an x/category field and a value field" % kind,
                "visual", visual_id, visual=name,
            )
            return None, []
        element["xAxis"] = {"columnId": x_values[0]}
        element["yAxis"] = {"columnIds": y_values}
        color = by_role.get("color") or by_role.get("series")
        if color:
            color_id = color[0]
            if color_id in set(x_values + y_values):
                original = field_by_id[color_id]["column"]
                duplicate = {
                    **original,
                    "id": ids.make("vcolor", "%s-%s" % (
                        visual_id, original["name"]
                    )),
                }
                columns.append(duplicate)
                element["columns"] = columns
                color_id = duplicate["id"]
            element["color"] = {
                "by": (
                    "scale"
                    if field_by_id[color[0]]["semantic"] == "measure"
                    else "category"
                ),
                "column": color_id,
            }
    elif kind in ("pie-chart", "donut-chart"):
        color = (by_role.get("color") or by_role.get("category")
                 or dimensions)
        values = by_role.get("value") or by_role.get("values") or measures
        if not color or not values:
            gaps.add(
                "SPOTFIRE-VISUAL-BINDING-INCOMPLETE",
                "%s requires a category and a value" % kind,
                "visual", visual_id, visual=name,
            )
            return None, []
        element["color"] = {"columnId": color[0]}
        element["value"] = {"columnId": values[0]}
    elif kind == "scatter-chart":
        x_values = by_role.get("x") or by_role.get("x-axis")
        y_values = by_role.get("y") or by_role.get("y-axis")
        if not x_values and measures:
            x_values = measures[:1]
        if not y_values and len(measures) > 1:
            y_values = measures[1:2]
        if not x_values or not y_values:
            gaps.add(
                "SPOTFIRE-VISUAL-BINDING-INCOMPLETE",
                "scatter plot requires x and y value expressions",
                "visual", visual_id, visual=name,
            )
            return None, []
        point_dimensions = dimensions
        if not point_dimensions:
            gaps.add(
                "SPOTFIRE-SCATTER-POINT-DIMENSION-MISSING",
                "scatter plot needs a point/category dimension so aggregate "
                "x/y values can be grouped without collapsing to one mark",
                "visual", visual_id, visual=name,
            )
            return None, []

        grouping_id = ids.make("scatter-group", visual_id)
        source_id = ids.make("scatter-source", visual_id)
        source_name = "%s · grouped" % name
        grouped_source = {
            "id": source_id,
            "kind": "table",
            "name": source_name,
            "source": {"kind": "table", "elementId": master["id"]},
            "columns": columns,
            "order": [column["id"] for column in columns],
            "groupings": [{
                "id": grouping_id,
                "groupBy": point_dimensions,
                "calculations": measures,
            }],
            "visibleAsSource": False,
        }
        chart_columns = []
        chart_ids = {}
        for field in fields:
            source_column = field["column"]
            chart_column = {
                "id": ids.make(
                    "scatter-column",
                    "%s-%s" % (visual_id, source_column["name"]),
                ),
                "name": source_column["name"],
                "formula": "[%s/%s]" % (
                    source_name, source_column["name"]
                ),
            }
            chart_columns.append(chart_column)
            chart_ids[source_column["id"]] = chart_column["id"]
        element["source"] = {
            "kind": "table",
            "elementId": source_id,
            "groupingId": grouping_id,
        }
        element["columns"] = chart_columns
        element["xAxis"] = {"columnId": chart_ids[x_values[0]]}
        element["yAxis"] = {"columnIds": [chart_ids[y_values[0]]]}
        size = by_role.get("size")
        color = by_role.get("color")
        if size:
            element["size"] = {"columnId": chart_ids[size[0]]}
        if color:
            element["color"] = {
                "by": (
                    "scale"
                    if field_by_id[color[0]]["semantic"] == "measure"
                    else "category"
                ),
                "column": chart_ids[color[0]],
            }
        return element, [grouped_source]
    return element, []


def _resolve_filter_table(filter_value, table_aliases):
    raw = _first(filter_value, "table", "table_id", "tableId",
                 "data_table", "dataTable", "data_table_id",
                 "dataTableId")
    if raw:
        return table_aliases.get(str(raw).casefold())
    expression = _first(filter_value, "expression", "column", "field")
    if isinstance(expression, str):
        match = re.fullmatch(
            r"\s*\[([^\]]+)\]\.\[([^\]]+)\]\s*", expression
        )
        if match:
            return table_aliases.get(match.group(1).casefold())
    unique = {context["id"]: context for context in table_aliases.values()}
    if len(unique) == 1:
        return next(iter(unique.values()))
    return None


def _filter_column(filter_value):
    raw = _first(filter_value, "column", "field", "column_name",
                 "columnName", "expression")
    if isinstance(raw, dict):
        raw = _first(raw, "name", "column", "expression")
    if not isinstance(raw, str):
        return None
    table_match = re.fullmatch(
        r"\s*\[[^\]]+\]\.\[([^\]]+)\]\s*", raw
    )
    if table_match:
        return table_match.group(1)
    column_match = re.fullmatch(r"\s*\[([^\]]+)\]\s*", raw)
    return column_match.group(1) if column_match else raw.strip()


def _emit_filter_control(filter_value, context, master, ids, gaps,
                         filter_id, page_name):
    if not isinstance(filter_value, dict):
        gaps.add(
            "SPOTFIRE-FILTER-SHAPE",
            "filter is not an object",
            "filter", filter_id, page=page_name,
        )
        return None
    column_name = _filter_column(filter_value)
    column = context and context["columns"].get(str(column_name or "").casefold())
    master_column = (
        master["columns_by_name"].get(str(column_name or "").casefold())
        if master else None
    )
    name = str(_first(filter_value, "name", "title", "label") or
               column_name or filter_id)
    if not (context and column and master_column):
        gaps.add(
            "SPOTFIRE-FILTER-BINDING-UNRESOLVED",
            "filter table/column cannot be resolved unambiguously",
            "filter", filter_id, page=page_name, filter=name,
        )
        return None
    target = {
        "source": {"kind": "table", "elementId": master["id"]},
        "columnId": master_column["id"],
    }
    kind = _normalize_token(
        _first(filter_value, "filter_type", "filterType", "type", "kind")
    )
    data_type = _column_type(next(
        (source_column for source_column in _table_columns(context["table"])
         if _column_name(source_column).casefold() == column_name.casefold()),
        {},
    ))
    control_base = re.sub(r"[^A-Za-z0-9]", "", name.title()) or "Filter"
    base = {
        "id": ids.make("ctrl", filter_id),
        "kind": "control",
        "controlId": control_base +
                     hashlib.sha1(filter_id.encode()).hexdigest()[:8],
        "name": name,
        "filters": [target],
    }
    values = _as_list(_first(filter_value, "values", "selected_values",
                             "selectedValues", "selection"))
    if "date" in kind or any(token in data_type for token in (
            "date", "time", "timestamp")):
        return {
            **base,
            "controlType": "date-range",
            "mode": "between",
            "includeNulls": "when-no-value-is-selected",
        }
    if any(token in kind for token in ("range", "slider")) or any(
            token in data_type for token in (
                "int", "number", "numeric", "decimal", "double", "real", "float")):
        return {
            **base,
            "controlType": "number-range",
            "includeNulls": "when-no-value-is-selected",
        }
    return {
        **base,
        "controlType": "list",
        "mode": "exclude" if filter_value.get("exclude") else "include",
        "selectionMode": "multiple",
        "values": values,
        "source": {
            "kind": "source",
            "source": {"kind": "table", "elementId": master["id"]},
            "columnId": master_column["id"],
        },
    }


def _document_properties(manifest):
    properties = list(_as_list(
        _first(manifest, "document_properties", "documentProperties",
               "properties")
    ))
    document = manifest.get("document")
    if isinstance(document, dict):
        properties.extend(_as_list(
            _first(document, "properties", "document_properties",
                   "documentProperties")
        ))
    return properties


def _manifest_filters(manifest):
    filters = list(_as_list(
        _first(manifest, "filters", "filtering", "filter_schemes",
               "filterSchemes")
    ))
    presentation = (
        manifest.get("presentation") if isinstance(manifest, dict) else None
    )
    if isinstance(presentation, dict):
        schemes = _as_list(_first(
            presentation, "filtering_schemes", "filteringSchemes",
            "filter_schemes", "filterSchemes",
        ))
        for scheme in schemes:
            if isinstance(scheme, dict):
                filters.extend(_as_list(scheme.get("filters")))
    return filters


def _emit_property_control(property_value, ids, gaps, index):
    if isinstance(property_value, str):
        property_value = {"name": property_value}
    if not isinstance(property_value, dict):
        gaps.add(
            "SPOTFIRE-PROPERTY-SHAPE",
            "document property is not an object",
            "document-property", "property-%d" % index,
        )
        return None
    name = str(_first(property_value, "name", "title", "id", "key",
                      "source_id") or
               "Property %d" % (index + 1))
    property_id = str(_first(property_value, "id", "key", "source_id",
                             "name") or
                      "property-%d" % index)
    control_base = re.sub(r"[^A-Za-z0-9]", "", name.title()) or "Property"
    control_id = control_base + hashlib.sha1(
        property_id.encode()).hexdigest()[:8]
    base = {
        "id": ids.make("prop", property_id),
        "kind": "control",
        "controlId": control_id,
        "name": name,
    }
    gaps.add(
        "SPOTFIRE-DOCUMENT-PROPERTY-CONSUMER-REVIEW",
        "document property is emitted as a Sigma parameter control, but its "
        "script/data-function/expression consumers must be rewired explicitly",
        "document-property", property_id, property=name,
    )
    kind = _normalize_token(
        _first(property_value, "data_type", "dataType", "value_type",
               "valueType", "type")
    )
    value = _first(property_value, "value", "default", "default_value",
                   "defaultValue")
    if property_value.get("redacted"):
        gaps.add(
            "SPOTFIRE-PROPERTY-REDACTED",
            "document property value was redacted; set a Sigma default manually",
            "document-property", property_id, property=name,
        )
        value = None
    values = _as_list(_first(property_value, "values", "allowed_values",
                             "allowedValues", "choices"))
    if values:
        return {
            **base,
            "controlType": "list",
            "mode": "include",
            "selectionMode": "single",
            "value": value if value is not None else values[0],
            "source": {
                "kind": "manual",
                "valueType": "text",
                "values": values,
                "labels": [str(item) for item in values],
            },
        }
    if kind in ("integer", "real", "number", "numeric", "decimal", "double"):
        return {
            **base, "controlType": "number", "mode": "=",
            **({"value": value} if value is not None else {}),
        }
    if kind in ("date", "datetime", "timestamp"):
        return {
            **base, "controlType": "date", "mode": "=",
            **({"value": value} if value is not None else {}),
        }
    if kind in ("boolean", "bool"):
        return {
            **base, "controlType": "switch", "mode": "True/False",
            **({"value": value} if value is not None else {}),
        }
    return {
        **base, "controlType": "text", "mode": "equals",
        "value": "" if value is None else value,
    }


def _raw_bounds(value):
    if not isinstance(value, dict):
        return None
    bounds = _first(value, "bounds", "position", "layout", "normalized_bounds",
                    "normalizedBounds")
    if isinstance(bounds, list) and len(bounds) >= 4:
        return tuple(float(item) for item in bounds[:4])
    if not isinstance(bounds, dict):
        bounds = value
    try:
        x = float(_first(bounds, "x", "left"))
        y = float(_first(bounds, "y", "top"))
        width = _first(bounds, "width", "w")
        height = _first(bounds, "height", "h")
        if width is None and bounds.get("right") is not None:
            width = float(bounds["right"]) - x
        if height is None and bounds.get("bottom") is not None:
            height = float(bounds["bottom"]) - y
        return x, y, float(width), float(height)
    except (TypeError, ValueError):
        return None


def _page_dimensions(page, visuals):
    width = _first(page, "width", "canvas_width", "canvasWidth")
    height = _first(page, "height", "canvas_height", "canvasHeight")
    page_bounds = _raw_bounds(page)
    if page_bounds:
        width = width or page_bounds[2]
        height = height or page_bounds[3]
    raw = [_raw_bounds(visual) for visual in visuals]
    raw = [bounds for bounds in raw if bounds]
    if not width and raw:
        width = max(bounds[0] + bounds[2] for bounds in raw)
    if not height and raw:
        height = max(bounds[1] + bounds[3] for bounds in raw)
    try:
        return float(width or 1), float(height or 1)
    except (TypeError, ValueError):
        return 1.0, 1.0


def normalized_grid_bounds(value, page_width=1.0, page_height=1.0,
                           row_offset=0):
    """Convert normalized or pixel bounds into a clipped 24-column grid box."""
    bounds = _raw_bounds(value)
    if not bounds:
        return None
    x, y, width, height = bounds
    if max(abs(x), abs(width), abs(x + width)) > 1.000001:
        x, width = x / max(page_width, 1.0), width / max(page_width, 1.0)
    if max(abs(y), abs(height), abs(y + height)) > 1.000001:
        y, height = y / max(page_height, 1.0), height / max(page_height, 1.0)
    x = min(1.0, max(0.0, x))
    y = min(1.0, max(0.0, y))
    width = min(1.0 - x, max(0.0, width))
    height = min(1.0 - y, max(0.0, height))
    column_start = min(GRID_COLUMNS, int(math.floor(x * GRID_COLUMNS)) + 1)
    column_end = min(
        GRID_COLUMNS + 1,
        max(column_start + 1, int(math.ceil((x + width) * GRID_COLUMNS)) + 1),
    )
    row_start = row_offset + int(math.floor(y * CANVAS_ROWS)) + 1
    row_span = max(MIN_VISUAL_ROWS, int(math.ceil(height * CANVAS_ROWS)))
    return column_start, column_end, row_start, row_start + row_span


def _layout_element(element_id, box):
    c0, c1, r0, r1 = box
    return (
        "    <Element elementId=%s gridColumn=%s gridRow=%s/>" %
        (quoteattr(str(element_id)), quoteattr("%d / %d" % (c0, c1)),
         quoteattr("%d / %d" % (r0, r1)))
    )


def _layout_page(page_id, placements):
    body = "\n".join(_layout_element(element_id, box)
                     for element_id, box in placements)
    if body:
        body = "\n" + body + "\n"
    return (
        "  <Page type=\"grid\" gridTemplateColumns=\"repeat(24, 1fr)\" "
        "gridTemplateRows=\"auto\" id=%s>%s  </Page>" %
        (quoteattr(str(page_id)), body)
    )


def _add_manifest_feature_gaps(manifest, gaps):
    automation = (
        manifest.get("automation")
        if isinstance(manifest.get("automation"), dict) else {}
    )
    security = manifest.get("security")
    security_values = (
        _as_list(security.get("signals"))
        if isinstance(security, dict) else _as_list(security)
    )
    groups = (
        (_as_list(manifest.get("mods")) + _as_list(automation.get("mods")),
         "mod", "SPOTFIRE-MOD-UNSUPPORTED",
         "Spotfire Mod visuals require a manual Sigma rebuild"),
        (_as_list(manifest.get("scripts")) + _as_list(automation.get("scripts")),
         "script", "SPOTFIRE-SCRIPT-UNSUPPORTED",
         "Spotfire scripts are not executed or translated"),
        (_as_list(manifest.get("data_functions")) +
         _as_list(manifest.get("dataFunctions")) +
         _as_list(automation.get("data_functions")) +
         _as_list(automation.get("dataFunctions")),
         "data-function", "SPOTFIRE-DATA-FUNCTION-UNSUPPORTED",
         "Spotfire data-function logic must be rebuilt upstream; only its explicitly mapped output table is consumed"),
        (_as_list(manifest.get("markings")),
         "marking", "SPOTFIRE-MARKING-UNSUPPORTED",
         "Spotfire marking interactions are not converted automatically"),
        (_as_list(manifest.get("bookmarks")),
         "bookmark", "SPOTFIRE-BOOKMARK-UNSUPPORTED",
         "Spotfire bookmark state is not converted automatically"),
        (security_values, "security", "SPOTFIRE-SECURITY-REVIEW",
         "Spotfire security metadata requires explicit RLS/CLS review"),
    )
    for values, object_type, code, reason in groups:
        for index, value in enumerate(values):
            object_id = (
                _first(value, "id", "source_id", "name", "title", "key")
                if isinstance(value, dict) else None
            ) or "%s-%d" % (object_type, index)
            gaps.add(code, reason, object_type, object_id)
    if isinstance(security, dict) and security.get("requires_manual_review") and not security_values:
        gaps.add(
            "SPOTFIRE-SECURITY-REVIEW",
            "manifest requires a manual security review but supplies no normalized signals",
            "security", "manifest-security",
        )

    def walk(value, pointer=""):
        if isinstance(value, dict):
            for key, child in value.items():
                child_pointer = "%s/%s" % (pointer, key)
                if key in ("unsupported", "export_errors", "exportErrors"):
                    for index, item in enumerate(_as_list(child)):
                        item_id = (
                            _first(item, "id", "source_id", "code", "name")
                            if isinstance(item, dict) else None
                        ) or "%s/%d" % (child_pointer, index)
                        if key == "unsupported":
                            gaps.add(
                                "SPOTFIRE-SOURCE-UNSUPPORTED",
                                str(_first(item, "message", "reason", "code")
                                    if isinstance(item, dict) else item),
                                "unsupported", item_id,
                                json_pointer=child_pointer,
                            )
                        else:
                            gaps.add(
                                "SPOTFIRE-EXPORT-ERROR",
                                str(_first(item, "message", "reason", "code")
                                    if isinstance(item, dict) else item),
                                "export-error", item_id,
                                json_pointer=child_pointer,
                            )
                else:
                    walk(child, child_pointer)
        elif isinstance(value, list):
            for index, child in enumerate(value):
                walk(child, "%s/%d" % (pointer, index))

    walk(manifest)


def _build_workbook(manifest, contexts, table_aliases, gaps,
                    data_model_id=None, dm_element_ids=None, name=None):
    ids = _Ids()
    all_elements = []
    pages = [{"id": "data", "name": "Data", "visibility": "hidden"}]
    dm_element_ids = dm_element_ids or {}
    master_by_table = {}
    auxiliary_elements = []

    for table_id in sorted(contexts, key=lambda key: contexts[key]["name"].casefold()):
        context = contexts[table_id]
        master_id = ids.make("source", table_id)
        master_name = "Source · %s" % context["name"]
        columns = []
        columns_by_name = {}
        for dm_column in context["element"]["columns"]:
            column = {
                "id": ids.make("src", "%s-%s" % (table_id, dm_column["name"])),
                "name": dm_column["name"],
                "formula": "[%s/%s]" % (context["name"], dm_column["name"]),
            }
            columns.append(column)
            columns_by_name[column["name"].casefold()] = column
        element_id = (
            dm_element_ids.get(context["name"])
            or dm_element_ids.get(context["id"])
            or context["element"]["id"]
        )
        master = {
            "id": master_id,
            "kind": "table",
            "name": master_name,
            "source": {
                "kind": "data-model",
                "dataModelId": data_model_id or "{{DATA_MODEL_ID}}",
                "elementId": element_id,
            },
            "columns": columns,
            "order": [column["id"] for column in columns],
            "visibleAsSource": False,
            "columns_by_name": columns_by_name,
        }
        master_by_table[table_id] = master
        all_elements.append({key: value for key, value in master.items()
                             if key != "columns_by_name"})

    source_pages = _manifest_pages(manifest)
    if not source_pages:
        source_pages = [{"id": "overview", "name": "Overview", "visuals": []}]
    page_records = []
    used_page_ids = {"data"}
    for page_index, source_page in enumerate(source_pages):
        if not isinstance(source_page, dict):
            source_page = {"name": "Page %d" % (page_index + 1), "visuals": []}
        base_page_id = _slug(_page_id(source_page, page_index), "page")
        page_id = base_page_id
        counter = 2
        while page_id in used_page_ids:
            page_id = "%s-%d" % (base_page_id, counter)
            counter += 1
        used_page_ids.add(page_id)
        page_name = _page_name(source_page, page_index)
        pages.append({"id": page_id, "name": page_name})
        page_records.append({
            "source": source_page,
            "id": page_id,
            "name": page_name,
            "elements": [],
            "visual_pairs": [],
            "controls": [],
        })

    global_controls = []
    global_filters = _manifest_filters(manifest)
    for filter_index, filter_value in enumerate(global_filters):
        context = (
            _resolve_filter_table(filter_value, table_aliases)
            if isinstance(filter_value, dict) else None
        )
        master = context and master_by_table.get(context["id"])
        control = _emit_filter_control(
            filter_value, context, master, ids, gaps,
            "global-filter-%d" % filter_index, page_records[0]["name"],
        )
        if control:
            global_controls.append(control)
    for property_index, property_value in enumerate(_document_properties(manifest)):
        # A source document property is not a live control until every consumer
        # (expression/script/data function) has been proven and rewired. Emitting
        # an unbound parameter creates dead UI furniture and fails control lint.
        _emit_property_control(property_value, ids, gaps, property_index)
    page_records[0]["controls"].extend(global_controls)

    for page_record in page_records:
        source_page = page_record["source"]
        page_filters = _as_list(
            _first(source_page, "filters", "filtering", "filter_schemes",
                   "filterSchemes")
        )
        for filter_index, filter_value in enumerate(page_filters):
            context = (
                _resolve_filter_table(filter_value, table_aliases)
                if isinstance(filter_value, dict) else None
            )
            master = context and master_by_table.get(context["id"])
            control = _emit_filter_control(
                filter_value, context, master, ids, gaps,
                "%s-filter-%d" % (page_record["id"], filter_index),
                page_record["name"],
            )
            if control:
                page_record["controls"].append(control)

        for visual_index, visual in enumerate(_page_visuals(source_page)):
            if not isinstance(visual, dict):
                gaps.add(
                    "SPOTFIRE-VISUAL-SHAPE",
                    "visual is not an object",
                    "visual", "%s-visual-%d" %
                    (page_record["id"], visual_index),
                    page=page_record["name"],
                )
                continue
            visual_id = _visual_id(visual, visual_index)
            visual_name = _visual_name(visual, visual_index)
            kind = visual_kind(visual)
            raw_type = _first(visual, "type", "visual_type", "visualType",
                              "kind", "class", "className")
            if not kind:
                gaps.add(
                    "SPOTFIRE-VISUAL-UNSUPPORTED",
                    "custom or unsupported visual type %r was not fabricated as a native chart" %
                    raw_type,
                    "visual", visual_id, visual=visual_name,
                    page=page_record["name"],
                )
                continue
            if any(key in visual and visual[key] not in (None, [], {}, False)
                   for key in ("marking", "markings", "marking_name",
                               "markingName")):
                gaps.add(
                    "SPOTFIRE-MARKING-UNSUPPORTED",
                    "visual marking interaction requires manual recreation",
                    "visual", visual_id, visual=visual_name,
                    page=page_record["name"],
                )
            if _first(visual, "mod_id", "modId"):
                gaps.add(
                    "SPOTFIRE-MOD-UNSUPPORTED",
                    "visual is backed by a Spotfire Mod and requires manual recreation",
                    "visual", visual_id, visual=visual_name,
                    page=page_record["name"],
                )
            axis_values = iter_axis_fields(visual)
            preliminary = [
                spotfire_expr.translate(_axis_expression(value))
                for _role, value in axis_values
                if _axis_expression(value)
            ]
            references = [
                reference for result in preliminary if result.supported
                for reference in result.references
            ]
            context = _visual_table(visual, table_aliases, references)
            if not context:
                gaps.add(
                    "SPOTFIRE-VISUAL-TABLE-UNRESOLVED",
                    "visual data table is absent or ambiguous",
                    "visual", visual_id, visual=visual_name,
                    page=page_record["name"],
                )
                continue
            master = master_by_table[context["id"]]
            fields = []
            for role, value in axis_values:
                field = _translated_field(
                    role, value, context, master, ids, gaps,
                    visual_id, visual_name,
                )
                if field:
                    fields.append(field)
            if not fields:
                gaps.add(
                    "SPOTFIRE-VISUAL-NO-FIELDS",
                    "visual has no convertible axis fields",
                    "visual", visual_id, visual=visual_name,
                    page=page_record["name"],
                )
                continue
            element, auxiliaries = _emit_visual(
                kind, visual_id, visual_name, master, fields, ids, gaps
            )
            auxiliary_elements.extend(auxiliaries)
            if element:
                page_record["visual_pairs"].append((element, visual))

            for filter_index, filter_value in enumerate(
                    _as_list(_first(visual, "filters", "filtering"))):
                filter_context = (
                    _resolve_filter_table(filter_value, table_aliases)
                    if isinstance(filter_value, dict) else context
                ) or context
                filter_master = master_by_table[filter_context["id"]]
                control = _emit_filter_control(
                    filter_value, filter_context, filter_master, ids, gaps,
                    "%s-filter-%d" % (visual_id, filter_index),
                    page_record["name"],
                )
                if control:
                    page_record["controls"].append(control)

    for page_record in page_records:
        for control in page_record["controls"]:
            page_record["elements"].append(control)
            all_elements.append(control)
        for element, _visual in page_record["visual_pairs"]:
            page_record["elements"].append(element)
            all_elements.append(element)
    all_elements.extend(auxiliary_elements)

    layout_pages = []
    data_placements = []
    data_row = 1
    for table_id in sorted(master_by_table,
                           key=lambda key: contexts[key]["name"].casefold()):
        master = master_by_table[table_id]
        data_placements.append((master["id"], (1, 25, data_row, data_row + 10)))
        data_row += 10
    for auxiliary in auxiliary_elements:
        data_placements.append((
            auxiliary["id"], (1, 25, data_row, data_row + 10)
        ))
        data_row += 10
    layout_pages.append(_layout_page("data", data_placements))

    for page_record in page_records:
        placements = []
        controls = page_record["controls"]
        if controls:
            width = GRID_COLUMNS // len(controls)
            for index, control in enumerate(controls):
                start = 1 + index * width
                end = 25 if index == len(controls) - 1 else start + width
                placements.append(
                    (control["id"], (start, end, 1, 1 + CONTROL_ROWS))
                )
        row_offset = CONTROL_ROWS if controls else 0
        visuals = [visual for _element, visual in page_record["visual_pairs"]]
        page_width, page_height = _page_dimensions(
            page_record["source"], visuals
        )
        auto_index = 0
        for element, source_visual in page_record["visual_pairs"]:
            box = normalized_grid_bounds(
                source_visual, page_width, page_height, row_offset
            )
            if box is None:
                column_start = 1 if auto_index % 2 == 0 else 13
                row_start = row_offset + 1 + (auto_index // 2) * 8
                box = (column_start, column_start + 12,
                       row_start, row_start + 8)
                auto_index += 1
            placements.append((element["id"], box))
        layout_pages.append(_layout_page(page_record["id"], placements))

    layout = (
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
        "\n".join(layout_pages)
    )
    placed = re.findall(r'\belementId="([^"]+)"', layout)
    declared = [element["id"] for element in all_elements]
    if sorted(placed) != sorted(declared) or len(placed) != len(set(placed)):
        raise ConversionError(
            "authoritative layout is incomplete: missing=%s duplicate=%s orphan=%s" %
            (
                sorted(set(declared) - set(placed)),
                sorted({item for item in placed if placed.count(item) > 1}),
                sorted(set(placed) - set(declared)),
            )
        )

    document = {
        "schemaVersion": 1,
        "kind": "workbook",
        "pages": pages,
        "elements": all_elements,
        "overlays": [],
        "panels": [],
        "layout": layout,
    }
    manifest_document = (
        manifest.get("document")
        if isinstance(manifest.get("document"), dict) else {}
    )
    manifest_name = _first(
        manifest, "name", "title", "document_name", "documentName"
    ) or _first(manifest_document, "name", "title") or _first(
        manifest.get("source") or {}, "name", "title"
    ) or "Spotfire Document"
    return {
        "name": name or "%s (from Spotfire)" % manifest_name,
        "document": document,
    }


def convert_manifest(manifest, source_map, connection_id=None,
                     database=None, schema=None, data_model_id=None,
                     dm_element_ids=None, dm_name=None, workbook_name=None):
    if not isinstance(manifest, dict):
        raise ConversionError("manifest root must be an object")
    tables = _manifest_tables(manifest)
    if not tables:
        raise ConversionError("manifest contains no tables array")
    gaps = _Gaps()
    resolved = resolve_sources(
        manifest, source_map, connection_id=connection_id,
        database=database, schema=schema,
    )
    data_model, contexts, table_aliases = _build_data_model(
        manifest, resolved, gaps, name=dm_name
    )
    _add_manifest_feature_gaps(manifest, gaps)
    for table_index, table in enumerate(tables):
        if isinstance(table, dict) and _source_kind(table) == "data-function":
            gaps.add(
                "SPOTFIRE-DATA-FUNCTION-UNSUPPORTED",
                "data-function output is read from its mapped warehouse table; "
                "the function logic itself is not translated",
                "table", _table_id(table, table_index),
                table=_table_name(table, table_index),
            )
    workbook = _build_workbook(
        manifest, contexts, table_aliases, gaps,
        data_model_id=data_model_id,
        dm_element_ids=dm_element_ids,
        name=workbook_name,
    )
    return {
        "data_model": data_model,
        "workbook": workbook,
        "gaps": gaps.sorted(),
        "resolved_sources": {
            key: {
                "connectionId": value["connectionId"],
                "path": value["path"],
                "source_kind": value["source_kind"],
            }
            for key, value in sorted(resolved.items())
        },
    }


def convert(*args, **kwargs):
    """Short compatibility alias used by offline callers and tests."""
    return convert_manifest(*args, **kwargs)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--source-map", required=True)
    parser.add_argument("--connection-id")
    parser.add_argument("--database")
    parser.add_argument("--schema")
    parser.add_argument("--data-model-id")
    parser.add_argument("--dm-element-ids",
                        help="JSON map from Spotfire table name/id to readback DM element id")
    parser.add_argument("--dm-name")
    parser.add_argument("--workbook-name")
    parser.add_argument("--out-dm", default="sigma_dm_spec.json")
    parser.add_argument("--out-workbook", default="sigma_workbook_spec.json")
    parser.add_argument("--out-gaps", default="conversion-gaps.json")
    parser.add_argument("--out-resolved-sources", default="resolved-sources.json")
    arguments = parser.parse_args(argv)
    dm_element_ids = (
        _read_json(arguments.dm_element_ids)
        if arguments.dm_element_ids else None
    )
    try:
        result = convert_manifest(
            _read_json(arguments.manifest),
            _read_json(arguments.source_map),
            connection_id=arguments.connection_id,
            database=arguments.database,
            schema=arguments.schema,
            data_model_id=arguments.data_model_id,
            dm_element_ids=dm_element_ids,
            dm_name=arguments.dm_name,
            workbook_name=arguments.workbook_name,
        )
    except ConversionError as error:
        parser.exit(2, "convert: %s\n" % error)
    _write_json(arguments.out_dm, result["data_model"])
    _write_json(arguments.out_workbook, result["workbook"])
    _write_json(arguments.out_gaps, {
        "schema_version": 1,
        "source": "spotfire",
        "gaps": result["gaps"],
        "summary": {"gaps": len(result["gaps"])},
    })
    _write_json(arguments.out_resolved_sources, result["resolved_sources"])
    print(
        "wrote %s, %s (%d loud gap(s))" %
        (arguments.out_dm, arguments.out_workbook, len(result["gaps"]))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
