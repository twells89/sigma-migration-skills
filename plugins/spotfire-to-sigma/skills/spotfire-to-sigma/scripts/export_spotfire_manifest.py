# -*- coding: utf-8 -*-
"""Read-only Spotfire Application API -> neutral migration manifest exporter.

Run this file as an IronPython script inside Spotfire Analyst or an Automation
Services action where ``Document`` is supplied as a global. Configure an
``OutputPath`` script parameter (and optionally ``SourceDxpPath``,
``ProvenancePath``, and ``ExecutionContext``).

The exporter only reads public Application API objects and writes JSON. It does
not refresh data, alter the document, run document scripts/data functions, or
emit source bodies or row data. See refs/spotfire-exporter.md.

The syntax intentionally remains compatible with IronPython 2.7.
"""

from __future__ import print_function

import datetime
import hashlib
import io
import json
import os
import re


EXPORTER_NAME = "sigma-spotfire-manifest-exporter"
EXPORTER_VERSION = "1.0.0"
MANIFEST_VERSION = "1.0"
PROVENANCE_MAP_VERSION = "1.0"

try:
    text_type = unicode  # noqa: F821 - available under IronPython 2
except NameError:
    text_type = str

SENSITIVE_NAME_RE = re.compile(
    r"(password|passwd|pwd|secret|token|credential|api.?key|access.?key|private.?key)",
    re.IGNORECASE,
)
URI_USERINFO_RE = re.compile(r"\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@", re.IGNORECASE)
SECRET_ASSIGNMENT_RE = re.compile(
    r"\b(password|passwd|pwd|token|client[_-]?secret|api[_-]?key)\s*[:=]\s*"
    r"(?:(['\"])[^'\"]*\2|[^;,\s]+)",
    re.IGNORECASE,
)
BRACKET_COLUMN_RE = re.compile(r"\[([^\]]+)\]")

AXIS_PROPERTIES = (
    "XAxis",
    "YAxis",
    "CategoryAxis",
    "ValueAxis",
    "ColorAxis",
    "SizeAxis",
    "ShapeAxis",
    "LabelAxis",
    "LineByAxis",
    "TrellisRowAxis",
    "TrellisColumnAxis",
    "HierarchyAxis",
)


def _utc_now():
    if hasattr(datetime, "timezone"):
        return (
            datetime.datetime.now(datetime.timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z")
        )
    return datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def _text(value):
    if value is None:
        return None
    try:
        result = text_type(value)
    except Exception:
        return "<unprintable>"
    return result


def redact_text(value):
    """Remove common URI/connection-string secrets from a text value."""
    if value is None:
        return None
    value = _text(value)
    value = URI_USERINFO_RE.sub(r"\1<redacted>@", value)
    value = SECRET_ASSIGNMENT_RE.sub(lambda match: match.group(1) + "=<redacted>", value)
    return value


def _is_sensitive_name(name):
    return bool(SENSITIVE_NAME_RE.search(_text(name) or ""))


def _hash_bytes(value):
    return hashlib.sha256(value).hexdigest()


def _hash_text(value):
    if value is None:
        return None
    if not isinstance(value, bytes):
        value = _text(value).encode("utf-8")
    return _hash_bytes(value)


def _hash_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _type_name(value):
    if value is None:
        return None
    try:
        return _text(value.GetType().FullName)
    except Exception:
        try:
            return _text(type(value).__name__)
        except Exception:
            return "unknown"


def _error(errors, code, prop, exc):
    errors.append(
        {
            "code": code,
            "message": redact_text("%s read failed (%s)" % (prop, _type_name(exc))),
            "property": prop,
            "recoverable": True,
        }
    )


def _get(obj, name, default=None, errors=None, record_missing=False):
    if obj is None:
        return default
    try:
        return getattr(obj, name)
    except AttributeError:
        if record_missing and errors is not None:
            errors.append(
                {
                    "code": "property_unavailable",
                    "message": "%s is not exposed by this Spotfire API version" % name,
                    "property": name,
                    "recoverable": True,
                }
            )
        return default
    except Exception as exc:
        if errors is not None:
            _error(errors, "property_read_failed", name, exc)
        return default


def _call(obj, method_name, args, errors=None):
    """Call an explicitly allow-listed read-only API method."""
    if obj is None:
        return None
    try:
        method = getattr(obj, method_name)
    except AttributeError:
        return None
    except Exception as exc:
        if errors is not None:
            _error(errors, "method_lookup_failed", method_name, exc)
        return None
    try:
        return method(*args)
    except Exception as exc:
        if errors is not None:
            _error(errors, "read_only_method_failed", method_name, exc)
        return None


def _iter(value, errors=None, label="collection"):
    if value is None:
        return []
    try:
        return list(value)
    except Exception:
        pass
    count = _get(value, "Count", None)
    if isinstance(count, int):
        result = []
        for index in range(count):
            try:
                result.append(value[index])
            except Exception as exc:
                if errors is not None:
                    _error(errors, "collection_item_failed", "%s[%d]" % (label, index), exc)
        return result
    if errors is not None:
        errors.append(
            {
                "code": "collection_unavailable",
                "message": "%s could not be enumerated" % label,
                "property": label,
                "recoverable": True,
            }
        )
    return []


def _collection(obj, properties, methods=(), errors=None, label="collection"):
    for prop in properties:
        sentinel = object()
        value = _get(obj, prop, sentinel, errors)
        if value is not sentinel and value is not None:
            return (_iter(value, errors, label), True, "public_property")
    for method in methods:
        value = _call(obj, method, (), errors)
        if value is not None:
            return (_iter(value, errors, label), True, "public_read_only_method")
    return ([], False, None)


def _public_scalar(value, name=None):
    if _is_sensitive_name(name or ""):
        return ("<redacted>", True)
    if value is None or isinstance(value, (bool, int, float)):
        return (value, False)
    if isinstance(value, (str, text_type)):
        redacted = redact_text(value)
        return (redacted[:4096], redacted != _text(value))
    if isinstance(value, (list, tuple)):
        result = []
        any_redacted = False
        for item in value[:100]:
            converted, was_redacted = _public_scalar(item, name)
            result.append(converted)
            any_redacted = any_redacted or was_redacted
        return (result, any_redacted)
    type_name = (_type_name(value) or "").lower()
    if any(token in type_name for token in ("datetime", "date", "timespan", "decimal", "guid")):
        raw = _text(value)
        clean = redact_text(raw)
        return (clean[:4096], clean != raw)
    # Do not serialize arbitrary .NET objects: ToString implementations can
    # disclose connection settings or trigger expensive behavior.
    return ("<unsupported:%s>" % (_type_name(value) or "object"), False)


def _unsupported(code, message, severity="warning"):
    return {"code": code, "message": message, "severity": severity}


def _source_id(obj, prefix, index):
    for prop in ("Id", "ID", "Guid", "Identifier"):
        value = _get(obj, prop)
        if value is not None:
            text = redact_text(value)
            if text:
                return "%s:%s" % (prefix, text)
    return "%s:index-%d" % (prefix, index)


def _name(obj, fallback):
    for prop in ("Name", "Title", "DisplayName", "Label"):
        value = _get(obj, prop)
        if value is not None:
            return redact_text(value)
    return fallback


def _base(obj, prefix, index, fallback):
    return {
        "source_id": _source_id(obj, prefix, index),
        "name": _name(obj, fallback),
        "unsupported": [],
        "export_errors": [],
    }


def _map(mappings, pointer, item, api_path, evidence):
    mappings.append(
        {
            "manifest_pointer": pointer,
            "source_id": item["source_id"],
            "api_path": api_path,
            "evidence": evidence,
            "authoritative": True,
            "unsupported": [entry["code"] for entry in item.get("unsupported", [])],
            "export_errors": [entry["code"] for entry in item.get("export_errors", [])],
        }
    )


def _neutral_data_type(spotfire_type):
    lowered = (spotfire_type or "").lower()
    if "bool" in lowered:
        return "boolean"
    if any(token in lowered for token in ("int", "long")):
        return "integer"
    if any(token in lowered for token in ("real", "single", "double", "decimal", "currency")):
        return "decimal"
    if "datetime" in lowered:
        return "datetime"
    if "date" in lowered:
        return "date"
    if "time" in lowered:
        return "time"
    if any(token in lowered for token in ("binary", "blob", "byte[]")):
        return "binary"
    if any(token in lowered for token in ("string", "text", "char")):
        return "string"
    return "other"


def _column_expression(column, errors):
    direct = _get(column, "Expression", None, errors)
    if direct is not None:
        return redact_text(direct)
    properties = _get(column, "Properties", None, errors)
    if properties is not None:
        try:
            value = properties["Expression"]
            if value is not None:
                return redact_text(value)
        except (KeyError, IndexError):
            pass
        except Exception as exc:
            _error(errors, "column_expression_failed", "Properties[Expression]", exc)
    return None


def _column_properties(column):
    output = {}
    properties = _get(column, "Properties")
    if properties is None:
        return output
    # This is intentionally an allow-list. Arbitrary property bags can contain
    # connection settings and are not serialized.
    for name in ("Description", "Format", "ContentType", "ExternalName", "Origin"):
        value = _get(properties, name)
        if value is None:
            try:
                value = properties[name]
            except Exception:
                value = None
        if value is not None:
            converted, redacted = _public_scalar(value, name)
            output[name] = "<redacted>" if redacted and _is_sensitive_name(name) else converted
    return output


def _collect_columns(table, table_index, table_id, mappings, api_path):
    errors = []
    raw_columns, found, evidence = _collection(
        table, ("Columns",), errors=errors, label="DataTable.Columns"
    )
    columns = []
    for index, column in enumerate(raw_columns):
        item = _base(column, "column", table_index * 100000 + index, "Column %d" % (index + 1))
        data_type_obj = _get(column, "DataType", None, item["export_errors"])
        spotfire_type = (
            _text(_get(data_type_obj, "DisplayName"))
            or _text(_get(data_type_obj, "Name"))
            or _type_name(data_type_obj)
            or "unknown"
        )
        expression = _column_expression(column, item["export_errors"])
        column_properties = _get(
            column, "Properties", None, item["export_errors"]
        )
        item.update(
            {
                "data_type": _neutral_data_type(spotfire_type),
                "spotfire_data_type": spotfire_type,
                "external_name": redact_text(
                    _get(column_properties, "ExternalName")
                ),
                "calculated": bool(_get(column, "IsCalculated", expression is not None)),
                "expression": expression,
                "properties": _column_properties(column),
            }
        )
        columns.append(item)
        _map(
            mappings,
            "/model/tables/%d/columns/%d" % (table_index, index),
            item,
            "%s.Columns[%d]" % (api_path, index),
            evidence or "public_collection",
        )
    if not found:
        errors.append(
            {
                "code": "columns_unavailable",
                "message": "DataTable.Columns was not exposed",
                "property": "Columns",
                "recoverable": True,
            }
        )
    return columns, errors


def _operation_expression(operation, errors):
    for prop in ("Expression", "Query", "Sql", "SQL", "Formula"):
        value = _get(operation, prop, None, errors)
        if value is not None:
            return redact_text(value)
    return None


def _collect_source_operations(table, table_index, mappings, api_path):
    errors = []
    operations = []
    source_view = _call(table, "GenerateSourceView", (), errors)
    raw_operations = []
    found = False
    if source_view is not None:
        # GetAllOperations<T>() is a generic API and cannot be invoked without
        # a type argument from a portable IronPython script. Traverse the
        # documented LastOperation -> Inputs tree instead.
        last_operation = _get(
            source_view, "LastOperation", None, errors, record_missing=True
        )
        visited = set()

        def visit(operation):
            if operation is None:
                return
            marker = _source_id(operation, "operation", len(visited))
            if marker in visited:
                return
            visited.add(marker)
            for child in _iter(
                    _get(operation, "Inputs", []),
                    errors,
                    "DataOperation.Inputs"):
                visit(child)
            raw_operations.append(operation)

        visit(last_operation)
        found = last_operation is not None
    for index, operation in enumerate(raw_operations):
        item = _base(
            operation,
            "source-operation",
            table_index * 100000 + index,
            "Source operation %d" % (index + 1),
        )
        details = {}
        for prop in ("Provider", "CommandType", "ResultName", "TransformationType"):
            value = _get(operation, prop, None, item["export_errors"])
            if value is not None:
                details[prop[0].lower() + prop[1:]], _ = _public_scalar(value, prop)
        # Script-like operation bodies are represented by hash/length only.
        for prop in ("Script", "ScriptCode", "Code"):
            source = _get(operation, prop)
            if source is not None:
                source_text = _text(source)
                details["source_sha256"] = _hash_text(source_text)
                details["source_length"] = len(source_text)
                details["source_included"] = False
                break
        item.update(
            {
                "operation_type": _type_name(operation) or "unknown",
                "expression": _operation_expression(operation, item["export_errors"]),
                "details": details,
            }
        )
        operations.append(item)
        _map(
            mappings,
            "/model/tables/%d/source_operations/%d" % (table_index, index),
            item,
            "%s.SourceView.Operations[%d]" % (api_path, index),
            "public_read_only_method",
        )
    return operations, errors, found


def _table_source(table):
    source_object = None
    for prop in ("DataSource", "Source", "DataSourceSettings"):
        source_object = _get(table, prop)
        if source_object is not None:
            break
    provider = None
    server = None
    database = None
    if source_object is not None:
        provider = _text(_get(source_object, "Provider")) or _type_name(source_object)
        server = redact_text(_get(source_object, "Server"))
        database = redact_text(_get(source_object, "Database"))
    return {
        "kind": _type_name(source_object) or "unknown",
        "provider": redact_text(provider),
        "server": server,
        "database": database,
    }


def _collect_tables(document, mappings, unsupported):
    data = _get(document, "Data")
    errors = []
    raw_tables, found, evidence = _collection(
        data, ("Tables",), errors=errors, label="Document.Data.Tables"
    )
    if not found:
        unsupported.append(
            _unsupported("tables_unavailable", "Document.Data.Tables is not exposed", "blocking")
        )
    tables = []
    table_objects = []
    for index, table in enumerate(raw_tables):
        api_path = "Document.Data.Tables[%d]" % index
        item = _base(table, "table", index, "Table %d" % (index + 1))
        columns, column_errors = _collect_columns(table, index, item["source_id"], mappings, api_path)
        item["export_errors"].extend(column_errors)
        operations, operation_errors, operations_found = _collect_source_operations(
            table, index, mappings, api_path
        )
        item["export_errors"].extend(operation_errors)
        if not operations_found:
            item["unsupported"].append(
                _unsupported(
                    "source_operations_unavailable",
                    "No public source-operation collection was exposed by this Spotfire version",
                )
            )
        item.update(
            {
                "source": _table_source(table),
                "columns": columns,
                "source_operations": operations,
            }
        )
        tables.append(item)
        table_objects.append((table, item))
        _map(mappings, "/model/tables/%d" % index, item, api_path, evidence or "public_collection")
    return tables, table_objects, errors


def _object_match(value, pairs):
    if value is None:
        return None
    for source_object, item in pairs:
        try:
            if value is source_object or value == source_object:
                return item["source_id"]
        except Exception:
            pass
    value_name = _name(value, None)
    for source_object, item in pairs:
        if value_name and value_name == item["name"]:
            return item["source_id"]
    return None


QUALIFIED_COLUMN_RE = re.compile(
    r"^\s*\[([^\]]+)\]\.\[([^\]]+)\]\s*$"
)


def _relation_pairs(expression):
    """Parse only documented compound equality relations.

    Transformed/non-equi relation expressions remain explicit unsupported
    findings; the exporter never guesses key columns from them.
    """
    pairs = []
    for clause in re.split(r"\s+and\s+", expression or "", flags=re.IGNORECASE):
        sides = re.split(r"\s*=\s*", clause, maxsplit=1)
        if len(sides) != 2:
            return []
        left = QUALIFIED_COLUMN_RE.match(sides[0])
        right = QUALIFIED_COLUMN_RE.match(sides[1])
        if not left or not right:
            return []
        pairs.append((left.groups(), right.groups()))
    return pairs


def _table_item_for(value, table_pairs):
    source_id = _object_match(value, table_pairs)
    for _table_object, table_item in table_pairs:
        if table_item["source_id"] == source_id:
            return table_item
    return None


def _column_id(table_item, name):
    for column in (table_item or {}).get("columns", []):
        candidates = (
            column.get("name"),
            column.get("external_name"),
            (column.get("properties") or {}).get("ExternalName"),
        )
        if any(
                candidate is not None
                and _text(candidate).lower() == _text(name).lower()
                for candidate in candidates):
            return column["source_id"]
    return None


def _collect_relations(document, table_pairs, mappings, unsupported):
    data = _get(document, "Data")
    errors = []
    raw_relations, found, evidence = _collection(
        data, ("Relations", "DataRelations"), errors=errors, label="Document.Data.Relations"
    )
    if not found:
        unsupported.append(
            _unsupported(
                "relations_unavailable",
                "Document.Data.Relations was not exposed; confirm joins manually",
            )
        )
    relations = []
    for index, relation in enumerate(raw_relations):
        item = _base(relation, "relation", index, "Relation %d" % (index + 1))
        expression = redact_text(
            _get(relation, "Expression", None, item["export_errors"])
        )
        left_item = _table_item_for(_get(relation, "LeftTable"), table_pairs)
        right_item = _table_item_for(_get(relation, "RightTable"), table_pairs)
        left_ids = []
        right_ids = []
        simple_pairs = _relation_pairs(expression)
        for left_ref, right_ref in simple_pairs:
            left_table_name, left_column_name = left_ref
            right_table_name, right_column_name = right_ref
            if (
                left_item
                and right_item
                and left_table_name.lower() == left_item["name"].lower()
                and right_table_name.lower() == right_item["name"].lower()
            ):
                left_id = _column_id(left_item, left_column_name)
                right_id = _column_id(right_item, right_column_name)
            elif (
                left_item
                and right_item
                and left_table_name.lower() == right_item["name"].lower()
                and right_table_name.lower() == left_item["name"].lower()
            ):
                left_id = _column_id(left_item, right_column_name)
                right_id = _column_id(right_item, left_column_name)
            else:
                left_id = right_id = None
            if not left_id or not right_id:
                left_ids = []
                right_ids = []
                break
            left_ids.append(left_id)
            right_ids.append(right_id)
        relation_type = (
            _text(_get(relation, "RelationType"))
            or _text(_get(relation, "Cardinality"))
            or _type_name(relation)
            or "unknown"
        )
        item.update(
            {
                "relation_type": relation_type,
                "expression": expression,
                "left": {
                    "table_id": (
                        left_item["source_id"]
                        if left_item else "unresolved:left-table"
                    ),
                    "column_ids": left_ids,
                },
                "right": {
                    "table_id": (
                        right_item["source_id"]
                        if right_item else "unresolved:right-table"
                    ),
                    "column_ids": right_ids,
                },
            }
        )
        if not left_item or not right_item:
            item["unsupported"].append(
                _unsupported("relation_endpoint_unresolved", "One or more relation endpoints could not be resolved")
            )
        if not left_ids or len(left_ids) != len(right_ids):
            item["unsupported"].append(
                _unsupported(
                    "relation_expression_not_simple_equality",
                    "Relation keys were not a complete set of simple qualified-column equalities",
                    "blocking",
                )
            )
        relations.append(item)
        _map(
            mappings,
            "/model/relations/%d" % index,
            item,
            "Document.Data.Relations[%d]" % index,
            evidence or "public_collection",
        )
    return relations, errors


def _visual_content(visual, errors):
    content = _get(visual, "VisualContentObject", None, errors)
    if content is not None:
        return content
    # Spotfire's generic As[VisualContent]() is public and does not execute
    # document code. Keep the import local so this module remains testable
    # outside Spotfire.
    try:
        from Spotfire.Dxp.Application.Visuals import VisualContent

        return visual.As[VisualContent]()
    except Exception as exc:
        _error(errors, "visual_content_unavailable", "As[VisualContent]", exc)
        return None


def _axis_columns(expression):
    if not expression:
        return []
    seen = []
    for value in BRACKET_COLUMN_RE.findall(expression):
        if value not in seen and value not in ("Axis.Default.Names",):
            seen.append(value)
    return seen


def _collect_axes(content, visual_index, page_index, mappings, api_path):
    axes = []
    for axis_index, prop in enumerate(AXIS_PROPERTIES):
        axis = _get(content, prop)
        if axis is None:
            continue
        item = _base(
            axis,
            "axis",
            page_index * 1000000 + visual_index * 100 + axis_index,
            prop,
        )
        expression = redact_text(_get(axis, "Expression", None, item["export_errors"]))
        item.update(
            {
                "axis_type": prop,
                "expression": expression,
                "columns": _axis_columns(expression),
                "aggregation": redact_text(_get(axis, "Aggregation")),
                "sort": redact_text(_get(axis, "SortMode") or _get(axis, "SortOrder")),
            }
        )
        if expression is None:
            item["unsupported"].append(
                _unsupported("axis_expression_unavailable", "%s expression was not exposed" % prop)
            )
        axes.append(item)
        _map(
            mappings,
            "%s/axes/%d" % (api_path[1], len(axes) - 1),
            item,
            "%s.%s" % (api_path[0], prop),
            "public_property",
        )
    return axes


def _filter_item(filter_object, prefix, index, fallback, table_item=None):
    # FilterCollection enumeration can yield FilterHandle objects. The public
    # handle points to the concrete filter through FilterReference; concrete
    # ColumnFilter/HierarchyFilter types expose DataColumnReference.
    filter_reference = _get(filter_object, "FilterReference")
    concrete_filter = (
        filter_reference if filter_reference is not None else filter_object
    )
    item = _base(concrete_filter, prefix, index, fallback)
    column = _get(
        concrete_filter,
        "DataColumnReference",
        None,
        item["export_errors"],
    )
    state_summary = {}
    for prop in ("IncludeAllValues", "IsReset", "SelectionCount"):
        value = _get(concrete_filter, prop)
        if value is not None:
            converted, _ = _public_scalar(value, prop)
            state_summary[prop[0].lower() + prop[1:]] = converted
    item.update(
        {
            "filter_type": _type_name(concrete_filter) or "unknown",
            "expression": redact_text(_get(concrete_filter, "Expression")),
            "column": _name(column, None) if column is not None else None,
            "data_table_id": (
                table_item.get("source_id") if table_item else None
            ),
            "selection_mode": redact_text(
                _get(concrete_filter, "SelectionMode")
                or _get(concrete_filter, "FilteringSelection")
            ),
            "state_summary": state_summary,
        }
    )
    return item


def _visual_filters(content, page_index, visual_index, mappings, api_paths):
    filters = []
    data = _get(content, "Data")
    filtering_ref = _get(data, "FilteringSelectionReference")
    if filtering_ref is not None:
        item = _filter_item(
            filtering_ref,
            "visual-filter",
            page_index * 1000000 + visual_index,
            "Filtering selection reference",
        )
        filters.append(item)
        _map(
            mappings,
            "%s/filters/0" % api_paths[1],
            item,
            "%s.Data.FilteringSelectionReference" % api_paths[0],
            "public_property",
        )
    return filters


def _numeric_member(value, names):
    for name in names:
        member = _get(value, name)
        if isinstance(member, (int, float)) and not isinstance(member, bool):
            return member
    return None


def _layout(page, visual, errors):
    bounds = None
    for owner in (visual, _get(visual, "VisualContentObject")):
        for prop in ("Bounds", "LayoutBounds", "Rectangle"):
            bounds = _get(owner, prop)
            if bounds is not None:
                break
        if bounds is not None:
            break
    if bounds is None:
        for method in ("GetVisualBounds", "GetVisualArea"):
            bounds = _call(page, method, (visual,), errors)
            if bounds is not None:
                break
    if bounds is None:
        return {
            "status": "unavailable",
            "unit": None,
            "x": None,
            "y": None,
            "width": None,
            "height": None,
        }
    x = _numeric_member(bounds, ("X", "Left"))
    y = _numeric_member(bounds, ("Y", "Top"))
    width = _numeric_member(bounds, ("Width",))
    height = _numeric_member(bounds, ("Height",))
    if width is None:
        right = _numeric_member(bounds, ("Right",))
        width = right - x if right is not None and x is not None else None
    if height is None:
        bottom = _numeric_member(bounds, ("Bottom",))
        height = bottom - y if bottom is not None and y is not None else None
    status = "available" if None not in (x, y, width, height) else "unavailable"
    return {
        "status": status,
        "unit": "spotfire_layout_units" if status == "available" else None,
        "x": x,
        "y": y,
        "width": width,
        "height": height,
    }


def _visual_table_id(content, table_pairs):
    data = _get(content, "Data")
    table = _get(data, "DataTableReference") or _get(data, "DataTable")
    return _object_match(table, table_pairs)


def _mod_metadata(visual, visual_item, index):
    visual_type = (visual_item.get("visual_type") or "").lower()
    mod_id = _get(visual, "ModId") or _get(visual, "VisualizationId")
    if mod_id is None and "mod" not in visual_type:
        return None
    item = _base(visual, "mod", index, visual_item["name"])
    item.update(
        {
            "visual_id": visual_item["source_id"],
            "mod_id": redact_text(mod_id),
            "version": redact_text(_get(visual, "ModVersion") or _get(visual, "Version")),
        }
    )
    return item


def _collect_pages(document, table_pairs, mappings, unsupported):
    errors = []
    raw_pages, found, evidence = _collection(
        document, ("Pages",), errors=errors, label="Document.Pages"
    )
    if not found:
        unsupported.append(_unsupported("pages_unavailable", "Document.Pages is not exposed", "blocking"))
    pages = []
    mods = []
    for page_index, page in enumerate(raw_pages):
        page_item = _base(page, "page", page_index, "Page %d" % (page_index + 1))
        page_item["description"] = redact_text(_get(page, "Description"))
        page_item["filters"] = []
        raw_visuals, visuals_found, visuals_evidence = _collection(
            page,
            ("Visuals",),
            errors=page_item["export_errors"],
            label="Page.Visuals",
        )
        if not visuals_found:
            page_item["unsupported"].append(
                _unsupported("visuals_unavailable", "Page.Visuals is not exposed", "blocking")
            )
        visuals = []
        for visual_index, visual in enumerate(raw_visuals):
            visual_item = _base(
                visual,
                "visual",
                page_index * 100000 + visual_index,
                "Visual %d" % (visual_index + 1),
            )
            content = _visual_content(visual, visual_item["export_errors"])
            visual_type = (
                redact_text(_get(visual, "TypeId"))
                or _type_name(content)
                or _type_name(visual)
                or "unknown"
            )
            manifest_pointer = "/presentation/pages/%d/visuals/%d" % (page_index, visual_index)
            api_path = "Document.Pages[%d].Visuals[%d]" % (page_index, visual_index)
            axes = _collect_axes(
                content,
                visual_index,
                page_index,
                mappings,
                (api_path, manifest_pointer),
            )
            filters = _visual_filters(
                content,
                page_index,
                visual_index,
                mappings,
                (api_path, manifest_pointer),
            )
            bounds = _layout(page, visual, visual_item["export_errors"])
            if bounds["status"] == "unavailable":
                visual_item["unsupported"].append(
                    _unsupported(
                        "layout_bounds_unavailable",
                        "This Spotfire API/version did not expose numeric visual bounds",
                    )
                )
            mod_id = redact_text(_get(visual, "ModId") or _get(visual, "VisualizationId"))
            visual_item.update(
                {
                    "visual_type": visual_type,
                    "description": redact_text(_get(visual, "Description")),
                    "data_table_id": _visual_table_id(content, table_pairs),
                    "axes": axes,
                    "filters": filters,
                    "layout": bounds,
                    "mod_id": mod_id,
                }
            )
            visuals.append(visual_item)
            _map(
                mappings,
                manifest_pointer,
                visual_item,
                api_path,
                visuals_evidence or "public_collection",
            )
            mod = _mod_metadata(visual, visual_item, page_index * 100000 + visual_index)
            if mod is not None:
                mods.append(mod)
        page_item["visuals"] = visuals
        pages.append(page_item)
        _map(
            mappings,
            "/presentation/pages/%d" % page_index,
            page_item,
            "Document.Pages[%d]" % page_index,
            evidence or "public_collection",
        )
    return pages, mods, errors


def _scheme_filters(scheme, table_pairs, scheme_index, mappings, pointer, api_path):
    filters = []
    seen_objects = set()
    raw_filters, found, evidence = _collection(
        scheme, ("Filters", "FilterCollection"), label="FilteringScheme.Filters"
    )
    candidates = [(filter_object, None) for filter_object in raw_filters]
    # Many Spotfire versions expose per-table filter collections through the
    # filtering-scheme indexer rather than one flat collection.
    for table_obj, table_item in table_pairs:
        try:
            table_filters = scheme[table_obj]
        except Exception:
            table_filters = None
        for filter_object in _iter(table_filters):
            candidates.append((filter_object, table_item))
    for candidate, table_item in candidates:
        marker = id(candidate)
        if marker in seen_objects:
            continue
        seen_objects.add(marker)
        filter_item = _filter_item(
            candidate,
            "filter",
            scheme_index * 100000 + len(filters),
            "Filter %d" % (len(filters) + 1),
            table_item=table_item,
        )
        filters.append(filter_item)
        _map(
            mappings,
            "%s/filters/%d" % (pointer, len(filters) - 1),
            filter_item,
            "%s.Filters[%d]" % (api_path, len(filters) - 1),
            evidence or "public_collection",
        )
    return filters, found or bool(candidates)


def _collect_filtering_schemes(document, table_pairs, mappings, unsupported):
    errors = []
    raw_schemes, found, evidence = _collection(
        document,
        ("FilteringSchemes",),
        errors=errors,
        label="Document.FilteringSchemes",
    )
    if not found:
        unsupported.append(
            _unsupported(
                "filtering_schemes_unavailable",
                "Document.FilteringSchemes is not exposed; filters require manual inventory",
            )
        )
    schemes = []
    for index, scheme in enumerate(raw_schemes):
        item = _base(scheme, "filtering-scheme", index, "Filtering scheme %d" % (index + 1))
        pointer = "/presentation/filtering_schemes/%d" % index
        api_path = "Document.FilteringSchemes[%d]" % index
        filters, filters_found = _scheme_filters(
            scheme, table_pairs, index, mappings, pointer, api_path
        )
        if not filters_found:
            item["unsupported"].append(
                _unsupported(
                    "filters_unavailable",
                    "No public filter collection was exposed for this filtering scheme",
                )
            )
        item["filters"] = filters
        schemes.append(item)
        _map(mappings, pointer, item, api_path, evidence or "public_collection")
    return schemes, errors


def _property_names(properties):
    names = _call(properties, "GetPropertyNames", ())
    if names is not None:
        return [_text(value) for value in _iter(names)]
    output = []
    for value in _iter(properties):
        name = _get(value, "Name")
        if name is not None:
            output.append(_text(name))
    return output


def _collect_document_properties(document, mappings, unsupported):
    properties = _get(document, "Properties")
    if properties is None:
        unsupported.append(
            _unsupported("document_properties_unavailable", "Document.Properties is not exposed")
        )
        return []
    names = _property_names(properties)
    if not names:
        unsupported.append(
            _unsupported(
                "document_property_names_unavailable",
                "The public property collection did not expose property names",
            )
        )
    output = []
    for index, name in enumerate(sorted(names)):
        item = {
            "source_id": "document-property:%s" % redact_text(name),
            "name": redact_text(name),
            "unsupported": [],
            "export_errors": [],
        }
        try:
            raw_value = properties[name]
        except Exception as exc:
            _error(item["export_errors"], "document_property_read_failed", name, exc)
            raw_value = None
        value, redacted = _public_scalar(raw_value, name)
        if _is_sensitive_name(name):
            value = "<redacted>"
            redacted = True
        item.update(
            {
                "value_type": _type_name(raw_value) or "null",
                "value": value,
                "redacted": redacted,
            }
        )
        output.append(item)
        _map(
            mappings,
            "/document_properties/%d" % index,
            item,
            "Document.Properties[%r]" % redact_text(name),
            "public_property",
        )
    return output


def _source_metadata(owner, property_names):
    for prop in property_names:
        source = _get(owner, prop)
        if source is not None:
            text = _text(source)
            return (_hash_text(text), len(text))
    return (None, None)


def _collect_scripts(document, mappings, unsupported):
    manager = _get(document, "ScriptManager")
    if manager is None:
        manager = _call(document, "GetScriptManager", ())
    if manager is None:
        unsupported.append(_unsupported("script_manager_unavailable", "ScriptManager is not exposed"))
        return []
    raw_scripts, found, evidence = _collection(
        manager, ("Scripts",), ("GetScripts",), label="ScriptManager scripts"
    )
    if not found:
        unsupported.append(_unsupported("scripts_unavailable", "ScriptManager scripts are not enumerable"))
    output = []
    for index, script in enumerate(raw_scripts):
        item = _base(script, "script", index, "Script %d" % (index + 1))
        digest, length = _source_metadata(script, ("ScriptCode", "Source", "Code"))
        if digest is None:
            item["unsupported"].append(
                _unsupported("script_source_unavailable", "Script source hash could not be captured")
            )
        item.update(
            {
                "language": redact_text(_get(script, "Language")),
                "description": redact_text(_get(script, "Description")),
                "enabled": _get(script, "Enabled"),
                "source_sha256": digest,
                "source_length": length,
                "source_included": False,
            }
        )
        output.append(item)
        _map(
            mappings,
            "/automation/scripts/%d" % index,
            item,
            "Document.ScriptManager.Scripts[%d]" % index,
            evidence or "public_collection",
        )
    return output


def _io_parameters(data_function, prop):
    output = []
    for parameter in _iter(_get(data_function, prop)):
        output.append(
            {
                "name": _name(parameter, ""),
                "data_type": redact_text(_get(parameter, "DataType") or _get(parameter, "Type")),
                "binding": redact_text(
                    _get(parameter, "Expression")
                    or _get(parameter, "Binding")
                    or _get(parameter, "DataPropertyName")
                ),
            }
        )
    return output


def _collect_data_functions(document, mappings, unsupported):
    data = _get(document, "Data")
    raw_functions, found, evidence = _collection(
        data,
        ("DataFunctions",),
        ("GetDataFunctions",),
        label="Document.Data.DataFunctions",
    )
    if not found:
        unsupported.append(
            _unsupported("data_functions_unavailable", "Document.Data.DataFunctions is not exposed")
        )
    output = []
    for index, function in enumerate(raw_functions):
        item = _base(function, "data-function", index, "Data function %d" % (index + 1))
        definition = _get(function, "Definition") or function
        digest, length = _source_metadata(definition, ("Script", "Source", "Expression", "Code"))
        item.update(
            {
                "language": redact_text(_get(definition, "Language")),
                "description": redact_text(_get(definition, "Description")),
                "function_type": _type_name(definition),
                "inputs": _io_parameters(function, "Inputs"),
                "outputs": _io_parameters(function, "Outputs"),
                "source_sha256": digest,
                "source_length": length,
                "source_included": False,
            }
        )
        if digest is None:
            item["unsupported"].append(
                _unsupported("data_function_source_unavailable", "Data-function source hash is unavailable")
            )
        output.append(item)
        _map(
            mappings,
            "/automation/data_functions/%d" % index,
            item,
            "Document.Data.DataFunctions[%d]" % index,
            evidence or "public_collection",
        )
    return output


def _collect_bookmarks(application, mappings, unsupported):
    manager = None
    if application is not None:
        try:
            from Spotfire.Dxp.Application.AnalyticItems import BookmarkManager

            try:
                manager = application.GetService[BookmarkManager]()
            except Exception:
                # Some IronPython host versions bind the non-generic Type
                # overload more reliably.
                manager = application.GetService(BookmarkManager)
        except Exception:
            manager = None
    if manager is None:
        unsupported.append(_unsupported(
            "bookmark_manager_unavailable",
            "AnalysisApplication did not expose the BookmarkManager service",
        ))
        return []
    raw_bookmarks, found, evidence = _collection(
        manager, ("Bookmarks",), ("GetBookmarks",), label="BookmarkManager bookmarks"
    )
    if not found:
        unsupported.append(_unsupported("bookmarks_unavailable", "Bookmarks are not enumerable"))
    output = []
    for index, bookmark in enumerate(raw_bookmarks):
        item = _base(bookmark, "bookmark", index, "Bookmark %d" % (index + 1))
        item["description"] = redact_text(_get(bookmark, "Description"))
        output.append(item)
        _map(
            mappings,
            "/bookmarks/%d" % index,
            item,
            "Document.BookmarkManager.Bookmarks[%d]" % index,
            evidence or "public_collection",
        )
    return output


def _security_signal(index, kind, status, detail, evidence):
    return {
        "source_id": "security-signal:%s" % kind,
        "name": kind.replace("_", " "),
        "unsupported": [],
        "export_errors": [],
        "kind": kind,
        "status": status,
        "detail": detail,
        "evidence": evidence,
    }


def _collect_security(scripts, data_functions, filtering_schemes, mappings):
    signals = [
        _security_signal(
            0,
            "row_level_security",
            "unknown",
            "Loaded-document metadata cannot prove all external/user-filtering rules.",
            ["Document.FilteringSchemes exported: %d" % len(filtering_schemes)],
        ),
        _security_signal(
            1,
            "column_level_security",
            "unknown",
            "Column visibility and source-system grants require customer review.",
            [],
        ),
        _security_signal(
            2,
            "library_acl",
            "unknown",
            "Spotfire Library ACLs are outside the loaded Document Application API object.",
            [],
        ),
        _security_signal(
            3,
            "embedded_scripts",
            "detected" if scripts else "not_detected",
            "Script bodies are hashed but never included or executed.",
            [script["source_id"] for script in scripts],
        ),
        _security_signal(
            4,
            "data_functions",
            "detected" if data_functions else "not_detected",
            "Data functions are inventoried but never executed.",
            [function["source_id"] for function in data_functions],
        ),
        _security_signal(
            5,
            "exported_secret_material",
            "not_detected",
            "Known connection strings, URI userinfo, and sensitive document properties are redacted.",
            ["redaction policy applied"],
        ),
    ]
    for index, signal in enumerate(signals):
        _map(
            mappings,
            "/security/signals/%d" % index,
            signal,
            "derived from public Application API values",
            "derived_from_public_values",
        )
    return {"requires_manual_review": True, "signals": signals}


def _spotfire_versions(document, application):
    spotfire_version = None
    if application is not None:
        spotfire_version = _text(_get(application, "Version"))
    api_version = None
    try:
        assembly_name = document.GetType().Assembly.GetName()
        api_version = _text(assembly_name.Version)
        if spotfire_version is None:
            spotfire_version = api_version
    except Exception:
        pass
    return (spotfire_version or "unknown", api_version or "unknown")


def _artifact_hash(source_dxp_path):
    output = {
        "algorithm": "sha256",
        "scope": "dxp_file_bytes",
        "status": "unavailable",
        "value": None,
        "reason": "SourceDxpPath was not supplied or was not readable",
    }
    if not source_dxp_path:
        return output
    try:
        output["value"] = _hash_file(source_dxp_path)
        output["status"] = "available"
        output["reason"] = None
    except Exception as exc:
        output["reason"] = redact_text("DXP byte hash failed (%s)" % _type_name(exc))
    return output


def build_manifest(document, application=None, source_dxp_path=None, execution_context="unknown"):
    """Build (manifest, provenance_map) from a live Spotfire Document global."""
    mappings = []
    unsupported = []
    export_errors = []
    source_hash = _artifact_hash(source_dxp_path)
    spotfire_version, api_version = _spotfire_versions(document, application)

    source = _base(document, "document", 0, "Spotfire document")
    source["document_id"] = _text(_get(document, "Id") or _get(document, "DocumentId"))
    source["artifact_hash"] = source_hash
    _map(mappings, "/source", source, "Document", "public_property")

    tables, table_pairs, table_errors = _collect_tables(document, mappings, unsupported)
    export_errors.extend(table_errors)
    relations, relation_errors = _collect_relations(document, table_pairs, mappings, unsupported)
    export_errors.extend(relation_errors)
    pages, mods, page_errors = _collect_pages(document, table_pairs, mappings, unsupported)
    export_errors.extend(page_errors)
    filtering_schemes, filter_errors = _collect_filtering_schemes(
        document, table_pairs, mappings, unsupported
    )
    export_errors.extend(filter_errors)
    document_properties = _collect_document_properties(document, mappings, unsupported)
    scripts = _collect_scripts(document, mappings, unsupported)
    data_functions = _collect_data_functions(document, mappings, unsupported)
    for index, mod in enumerate(mods):
        _map(
            mappings,
            "/automation/mods/%d" % index,
            mod,
            "Document.Pages.Visuals (Mod metadata)",
            "public_property",
        )
    bookmarks = _collect_bookmarks(application, mappings, unsupported)
    security = _collect_security(scripts, data_functions, filtering_schemes, mappings)

    if source_hash["status"] == "unavailable":
        source["unsupported"].append(
            _unsupported(
                "source_hash_unavailable",
                "Provide SourceDxpPath to bind the manifest to exact DXP file bytes",
            )
        )

    manifest = {
        "$schema": "spotfire-manifest.schema.json",
        "manifest_type": "spotfire_neutral_manifest",
        "manifest_version": MANIFEST_VERSION,
        "authority": {
            "authoritative": True,
            "api_surface": "Spotfire.Dxp.Application",
            "dxp_raw_used": False,
        },
        "export": {
            "exporter": {"name": EXPORTER_NAME, "version": EXPORTER_VERSION},
            "generated_at_utc": _utc_now(),
            "spotfire_version": spotfire_version,
            "api_version": api_version,
            "execution_context": (
                execution_context if execution_context in ("analyst", "automation", "unknown") else "unknown"
            ),
            "redaction": {
                "policy": "connection_secrets_and_sensitive_properties_removed",
                "script_bodies_included": False,
                "row_data_included": False,
            },
            "warnings": [
                "Validate security and all unsupported/export_errors before conversion.",
                "Library ACLs and external source grants require separate customer evidence.",
            ],
        },
        "source": source,
        "model": {"tables": tables, "relations": relations},
        "presentation": {
            "pages": pages,
            "filtering_schemes": filtering_schemes,
        },
        "document_properties": document_properties,
        "automation": {
            "scripts": scripts,
            "data_functions": data_functions,
            "mods": mods,
        },
        "bookmarks": bookmarks,
        "security": security,
        "unsupported": unsupported,
        "export_errors": export_errors,
    }
    provenance_map = {
        "$schema": "spotfire-manifest-provenance.schema.json",
        "provenance_map_type": "spotfire_neutral_manifest_provenance",
        "provenance_map_version": PROVENANCE_MAP_VERSION,
        "manifest_version": MANIFEST_VERSION,
        "exporter_version": EXPORTER_VERSION,
        "source_artifact_sha256": source_hash["value"],
        "mappings": mappings,
    }
    return manifest, provenance_map


def _write_json(path, value):
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        raise IOError("output directory does not exist: %s" % parent)
    text = json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    with io.open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def run_export(
    document,
    application=None,
    output_path=None,
    source_dxp_path=None,
    provenance_path=None,
    execution_context="unknown",
):
    if not output_path:
        raise ValueError("OutputPath script parameter (or SPOTFIRE_MANIFEST_PATH) is required")
    manifest, provenance_map = build_manifest(
        document,
        application=application,
        source_dxp_path=source_dxp_path,
        execution_context=execution_context,
    )
    _write_json(output_path, manifest)
    if provenance_path:
        _write_json(provenance_path, provenance_map)
    return manifest


def _global_value(namespace, names):
    for name in names:
        if name in namespace and namespace[name] not in (None, ""):
            return namespace[name]
    return None


def _run_from_spotfire_globals(namespace):
    document = namespace.get("Document")
    if document is None:
        raise RuntimeError("This exporter must run in Spotfire with a Document global")
    application = namespace.get("Application")
    output_path = _global_value(namespace, ("OutputPath", "ManifestOutputPath"))
    if output_path is None:
        output_path = os.environ.get("SPOTFIRE_MANIFEST_PATH")
    source_path = _global_value(namespace, ("SourceDxpPath", "DxpPath"))
    provenance_path = _global_value(namespace, ("ProvenancePath",))
    context = _global_value(namespace, ("ExecutionContext",)) or "unknown"
    return run_export(
        document,
        application=application,
        output_path=_text(output_path),
        source_dxp_path=_text(source_path),
        provenance_path=_text(provenance_path),
        execution_context=(_text(context) or "unknown").lower(),
    )


if __name__ == "__main__" or "Document" in globals():
    _run_from_spotfire_globals(globals())
