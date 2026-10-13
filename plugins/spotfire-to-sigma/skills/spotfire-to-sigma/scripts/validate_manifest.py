#!/usr/bin/env python3
"""Validate a Spotfire neutral manifest without third-party packages.

This validator implements the semantic checks that matter to the migration
pipeline in addition to the reference JSON Schema in refs/. It deliberately
rejects raw-DXP inventories: only a public Application API export can be an
authoritative manifest.
"""

import argparse
import datetime
import json
import os
import re
import sys


SUPPORTED_MANIFEST_VERSION = "1.0"
SUPPORTED_PROVENANCE_MAP_VERSION = "1.0"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SENSITIVE_KEY_RE = re.compile(
    r"(^|[_-])(password|passwd|pwd|secret|token|credentials?|api[_-]?key|"
    r"access[_-]?key|private[_-]?key)($|[_-])",
    re.IGNORECASE,
)
URI_USERINFO_RE = re.compile(r"\b[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@", re.IGNORECASE)
ASSIGNMENT_SECRET_RE = re.compile(
    r"\b(password|passwd|pwd|token|client[_-]?secret|api[_-]?key)\s*[:=]\s*"
    r"(?!<redacted>|\*{3,})[^;,\s]+",
    re.IGNORECASE,
)


OBJECT_ARRAY_PATHS = (
    ("model", "tables"),
    ("model", "relations"),
    ("presentation", "pages"),
    ("presentation", "filtering_schemes"),
    ("document_properties",),
    ("automation", "scripts"),
    ("automation", "data_functions"),
    ("automation", "mods"),
    ("bookmarks",),
    ("security", "signals"),
)


def _pointer(path):
    if not path:
        return "/"
    return "/" + "/".join(str(part).replace("~", "~0").replace("/", "~1") for part in path)


def _is_nonempty_string(value):
    return isinstance(value, str) and bool(value.strip())


def _at(data, path):
    current = data
    for key in path:
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def _require_keys(value, keys, path, errors):
    if not isinstance(value, dict):
        errors.append("%s must be an object" % _pointer(path))
        return False
    for key in keys:
        if key not in value:
            errors.append("%s is missing required field %r" % (_pointer(path), key))
    return True


def _check_issue_list(value, path, errors, is_error):
    label = "export_errors" if is_error else "unsupported"
    if not isinstance(value, list):
        errors.append("%s/%s must be an array" % (_pointer(path).rstrip("/"), label))
        return
    required = ("code", "message", "recoverable") if is_error else ("code", "message", "severity")
    for index, item in enumerate(value):
        item_path = path + (label, index)
        if not _require_keys(item, required, item_path, errors):
            continue
        if not _is_nonempty_string(item.get("code")):
            errors.append("%s/code must be a non-empty string" % _pointer(item_path))
        if not _is_nonempty_string(item.get("message")):
            errors.append("%s/message must be a non-empty string" % _pointer(item_path))
        if is_error and not isinstance(item.get("recoverable"), bool):
            errors.append("%s/recoverable must be boolean" % _pointer(item_path))
        if not is_error and item.get("severity") not in ("info", "warning", "blocking"):
            errors.append("%s/severity is invalid" % _pointer(item_path))


def _check_envelope(item, path, errors, seen_ids):
    if not _require_keys(item, ("source_id", "name", "unsupported", "export_errors"), path, errors):
        return
    source_id = item.get("source_id")
    if not _is_nonempty_string(source_id):
        errors.append("%s/source_id must be a non-empty string" % _pointer(path))
    elif source_id in seen_ids:
        errors.append(
            "%s/source_id duplicates %s (first seen at %s)"
            % (_pointer(path), source_id, seen_ids[source_id])
        )
    else:
        seen_ids[source_id] = _pointer(path)
    if not isinstance(item.get("name"), str):
        errors.append("%s/name must be a string" % _pointer(path))
    _check_issue_list(item.get("unsupported"), path, errors, False)
    _check_issue_list(item.get("export_errors"), path, errors, True)


def _walk_nested_objects(item, path, errors, seen_ids):
    """Validate nested conversion objects that carry source_id envelopes."""
    for key in ("columns", "source_operations", "visuals", "axes", "filters"):
        values = item.get(key)
        if values is None:
            continue
        if not isinstance(values, list):
            errors.append("%s/%s must be an array" % (_pointer(path).rstrip("/"), key))
            continue
        for index, child in enumerate(values):
            child_path = path + (key, index)
            if not isinstance(child, dict):
                if key == "columns" and "axis_type" in item and isinstance(child, str):
                    continue
                errors.append("%s must be an object" % _pointer(child_path))
                continue
            _check_envelope(child, child_path, errors, seen_ids)
            _walk_nested_objects(child, child_path, errors, seen_ids)


def _check_layout(visual, path, errors):
    layout = visual.get("layout")
    layout_path = path + ("layout",)
    if not _require_keys(layout, ("status", "unit", "x", "y", "width", "height"), layout_path, errors):
        return
    if layout.get("status") not in ("available", "unavailable"):
        errors.append("%s/status must be available or unavailable" % _pointer(layout_path))
    if layout.get("status") == "available":
        for field in ("x", "y", "width", "height"):
            if not isinstance(layout.get(field), (int, float)) or isinstance(layout.get(field), bool):
                errors.append("%s/%s must be numeric when layout is available" % (_pointer(layout_path), field))
    for field in ("width", "height"):
        value = layout.get(field)
        if isinstance(value, (int, float)) and not isinstance(value, bool) and value < 0:
            errors.append("%s/%s cannot be negative" % (_pointer(layout_path), field))


def _check_type_specific(manifest, errors, warnings):
    tables = _at(manifest, ("model", "tables"))
    tables = tables if isinstance(tables, list) else []
    table_ids = set()
    column_ids = set()
    for ti, table in enumerate(tables):
        path = ("model", "tables", ti)
        _require_keys(table, ("source", "columns", "source_operations"), path, errors)
        if isinstance(table, dict):
            table_ids.add(table.get("source_id"))
            columns = table.get("columns")
            columns = columns if isinstance(columns, list) else []
            for ci, column in enumerate(columns):
                _require_keys(
                    column,
                    ("data_type", "spotfire_data_type", "external_name", "calculated", "expression", "properties"),
                    path + ("columns", ci),
                    errors,
                )
                if isinstance(column, dict):
                    column_ids.add(column.get("source_id"))
            operations = table.get("source_operations")
            operations = operations if isinstance(operations, list) else []
            for oi, operation in enumerate(operations):
                _require_keys(
                    operation,
                    ("operation_type", "expression", "details"),
                    path + ("source_operations", oi),
                    errors,
                )

    relations = _at(manifest, ("model", "relations"))
    relations = relations if isinstance(relations, list) else []
    for ri, relation in enumerate(relations):
        path = ("model", "relations", ri)
        _require_keys(relation, ("relation_type", "left", "right"), path, errors)
        if not isinstance(relation, dict):
            continue
        for side in ("left", "right"):
            endpoint = relation.get(side)
            endpoint_path = path + (side,)
            if not _require_keys(endpoint, ("table_id", "column_ids"), endpoint_path, errors):
                continue
            if endpoint.get("table_id") not in table_ids:
                errors.append("%s/table_id does not reference an exported table" % _pointer(endpoint_path))
            ids = endpoint.get("column_ids")
            if not isinstance(ids, list):
                errors.append("%s/column_ids must be an array" % _pointer(endpoint_path))
            else:
                for ci, column_id in enumerate(ids):
                    if column_id not in column_ids:
                        errors.append(
                            "%s/column_ids/%d does not reference an exported column"
                            % (_pointer(endpoint_path), ci)
                        )

    pages = _at(manifest, ("presentation", "pages"))
    pages = pages if isinstance(pages, list) else []
    visual_ids = set()
    for pi, page in enumerate(pages):
        page_path = ("presentation", "pages", pi)
        _require_keys(page, ("description", "visuals", "filters"), page_path, errors)
        if not isinstance(page, dict):
            continue
        _check_filters(page.get("filters"), page_path + ("filters",), errors)
        visuals = page.get("visuals")
        visuals = visuals if isinstance(visuals, list) else []
        for vi, visual in enumerate(visuals):
            visual_path = page_path + ("visuals", vi)
            _require_keys(
                visual,
                ("visual_type", "description", "data_table_id", "axes", "filters", "layout", "mod_id"),
                visual_path,
                errors,
            )
            if isinstance(visual, dict):
                visual_ids.add(visual.get("source_id"))
                _check_layout(visual, visual_path, errors)
                _check_filters(visual.get("filters"), visual_path + ("filters",), errors)
                table_id = visual.get("data_table_id")
                if table_id is not None and table_id not in table_ids:
                    errors.append("%s/data_table_id does not reference an exported table" % _pointer(visual_path))
                axes = visual.get("axes")
                axes = axes if isinstance(axes, list) else []
                for ai, axis in enumerate(axes):
                    _require_keys(
                        axis,
                        ("axis_type", "expression", "columns", "aggregation", "sort"),
                        visual_path + ("axes", ai),
                        errors,
                    )

    schemes = _at(manifest, ("presentation", "filtering_schemes"))
    schemes = schemes if isinstance(schemes, list) else []
    for si, scheme in enumerate(schemes):
        path = ("presentation", "filtering_schemes", si)
        _require_keys(scheme, ("filters",), path, errors)
        if isinstance(scheme, dict):
            _check_filters(scheme.get("filters"), path + ("filters",), errors)

    properties = manifest.get("document_properties")
    properties = properties if isinstance(properties, list) else []
    for pi, prop in enumerate(properties):
        path = ("document_properties", pi)
        _require_keys(prop, ("value_type", "value", "redacted"), path, errors)
        if isinstance(prop, dict) and not isinstance(prop.get("redacted"), bool):
            errors.append("%s/redacted must be boolean" % _pointer(path))

    automation = manifest.get("automation", {})
    scripts = automation.get("scripts") if isinstance(automation, dict) else []
    scripts = scripts if isinstance(scripts, list) else []
    for si, script in enumerate(scripts):
        path = ("automation", "scripts", si)
        _require_keys(
            script,
            ("language", "description", "enabled", "source_sha256", "source_length", "source_included"),
            path,
            errors,
        )
        _check_hashed_source(script, path, errors)
    functions = automation.get("data_functions") if isinstance(automation, dict) else []
    functions = functions if isinstance(functions, list) else []
    for di, function in enumerate(functions):
        path = ("automation", "data_functions", di)
        _require_keys(
            function,
            (
                "language",
                "description",
                "function_type",
                "inputs",
                "outputs",
                "source_sha256",
                "source_length",
                "source_included",
            ),
            path,
            errors,
        )
        _check_hashed_source(function, path, errors)
        if isinstance(function, dict):
            for field in ("inputs", "outputs"):
                parameters = function.get(field)
                if not isinstance(parameters, list):
                    errors.append("%s/%s must be an array" % (_pointer(path), field))
                    continue
                for ii, parameter in enumerate(parameters):
                    _require_keys(parameter, ("name", "data_type", "binding"), path + (field, ii), errors)
    mods = automation.get("mods") if isinstance(automation, dict) else []
    mods = mods if isinstance(mods, list) else []
    for mi, mod in enumerate(mods):
        path = ("automation", "mods", mi)
        _require_keys(mod, ("visual_id", "mod_id", "version"), path, errors)
        if isinstance(mod, dict) and mod.get("visual_id") not in visual_ids:
            errors.append("%s/visual_id does not reference an exported visual" % _pointer(path))

    bookmarks = manifest.get("bookmarks")
    bookmarks = bookmarks if isinstance(bookmarks, list) else []
    for bi, bookmark in enumerate(bookmarks):
        _require_keys(bookmark, ("description",), ("bookmarks", bi), errors)

    security = manifest.get("security")
    if isinstance(security, dict):
        if security.get("requires_manual_review") is not True:
            warnings.append(
                "/security/requires_manual_review is false; Spotfire library ACL and all external security "
                "rules cannot be proven from a loaded document"
            )
        signals = security.get("signals")
        signals = signals if isinstance(signals, list) else []
        kinds = {
            signal.get("kind")
            for signal in signals
            if isinstance(signal, dict)
        }
        for kind in ("row_level_security", "column_level_security", "library_acl"):
            if kind not in kinds:
                warnings.append("/security/signals has no %s signal" % kind)
        for si, signal in enumerate(signals):
            path = ("security", "signals", si)
            _require_keys(signal, ("kind", "status", "detail", "evidence"), path, errors)
            if isinstance(signal, dict) and signal.get("status") not in (
                "detected",
                "not_detected",
                "unknown",
            ):
                errors.append("%s/status is invalid" % _pointer(path))


def _check_filters(filters, path, errors):
    if not isinstance(filters, list):
        errors.append("%s must be an array" % _pointer(path))
        return
    for index, filter_item in enumerate(filters):
        _require_keys(
            filter_item,
            ("filter_type", "expression", "column", "selection_mode", "state_summary"),
            path + (index,),
            errors,
        )


def _check_hashed_source(item, path, errors):
    if not isinstance(item, dict):
        return
    if item.get("source_included") is not False:
        errors.append("%s/source_included must be false" % _pointer(path))
    for forbidden in ("source", "source_body", "script_body", "script_code", "code"):
        if forbidden in item:
            errors.append("%s/%s is forbidden; executable source bodies must not be exported" % (
                _pointer(path),
                forbidden,
            ))
    digest = item.get("source_sha256")
    length = item.get("source_length")
    if digest is not None and (not isinstance(digest, str) or not SHA256_RE.match(digest)):
        errors.append("%s/source_sha256 must be null or a lowercase SHA-256" % _pointer(path))
    if length is not None and (
        not isinstance(length, int) or isinstance(length, bool) or length < 0
    ):
        errors.append("%s/source_length must be null or a non-negative integer" % _pointer(path))
    if (digest is None) != (length is None):
        errors.append("%s source_sha256 and source_length must both be present or both null" % _pointer(path))


def _check_credentials(value, path, errors):
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = path + (key,)
            if SENSITIVE_KEY_RE.search(str(key)):
                if child not in (None, "<redacted>", "***", "REDACTED"):
                    errors.append("%s contains a sensitive key whose value is not redacted" % _pointer(child_path))
            _check_credentials(child, child_path, errors)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _check_credentials(child, path + (index,), errors)
    elif isinstance(value, str):
        if URI_USERINFO_RE.search(value):
            errors.append("%s contains URI userinfo" % _pointer(path))
        if ASSIGNMENT_SECRET_RE.search(value):
            errors.append("%s appears to contain an assigned secret" % _pointer(path))


def validate_manifest(manifest):
    """Return (errors, warnings) for one decoded manifest."""
    errors = []
    warnings = []
    if not isinstance(manifest, dict):
        return (["/ must be an object"], warnings)

    _require_keys(
        manifest,
        (
            "manifest_type",
            "manifest_version",
            "authority",
            "export",
            "source",
            "model",
            "presentation",
            "document_properties",
            "automation",
            "bookmarks",
            "security",
            "unsupported",
            "export_errors",
        ),
        (),
        errors,
    )
    if manifest.get("manifest_type") != "spotfire_neutral_manifest":
        errors.append("/manifest_type must be 'spotfire_neutral_manifest'")
    if manifest.get("manifest_version") != SUPPORTED_MANIFEST_VERSION:
        errors.append("/manifest_version must be %s" % SUPPORTED_MANIFEST_VERSION)

    authority = manifest.get("authority")
    if _require_keys(authority, ("authoritative", "api_surface", "dxp_raw_used"), ("authority",), errors):
        if authority.get("authoritative") is not True:
            errors.append("/authority/authoritative must be true")
        if authority.get("api_surface") != "Spotfire.Dxp.Application":
            errors.append("/authority/api_surface must be 'Spotfire.Dxp.Application'")
        if authority.get("dxp_raw_used") is not False:
            errors.append("/authority/dxp_raw_used must be false; raw DXP output is never authoritative")

    export = manifest.get("export")
    if _require_keys(
        export,
        ("exporter", "generated_at_utc", "spotfire_version", "api_version", "execution_context", "redaction", "warnings"),
        ("export",),
        errors,
    ):
        exporter = export.get("exporter")
        if _require_keys(exporter, ("name", "version"), ("export", "exporter"), errors):
            if exporter.get("name") != "sigma-spotfire-manifest-exporter":
                errors.append("/export/exporter/name is not the supported exporter")
            if not _is_nonempty_string(exporter.get("version")):
                errors.append("/export/exporter/version must be a non-empty string")
        timestamp = export.get("generated_at_utc")
        if not isinstance(timestamp, str):
            errors.append("/export/generated_at_utc must be a string")
        else:
            try:
                datetime.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
            except ValueError:
                errors.append("/export/generated_at_utc must be an ISO-8601 date-time")
        if export.get("execution_context") not in ("analyst", "automation", "unknown"):
            errors.append("/export/execution_context is invalid")
        redaction = export.get("redaction")
        if _require_keys(
            redaction,
            ("policy", "script_bodies_included", "row_data_included"),
            ("export", "redaction"),
            errors,
        ):
            if redaction.get("script_bodies_included") is not False:
                errors.append("/export/redaction/script_bodies_included must be false")
            if redaction.get("row_data_included") is not False:
                errors.append("/export/redaction/row_data_included must be false")

    source = manifest.get("source")
    seen_ids = {}
    if isinstance(source, dict):
        _check_envelope(source, ("source",), errors, seen_ids)
        artifact_hash = source.get("artifact_hash")
        if _require_keys(
            artifact_hash,
            ("algorithm", "scope", "status", "value"),
            ("source", "artifact_hash"),
            errors,
        ):
            if artifact_hash.get("algorithm") != "sha256":
                errors.append("/source/artifact_hash/algorithm must be sha256")
            if artifact_hash.get("scope") != "dxp_file_bytes":
                errors.append("/source/artifact_hash/scope must be dxp_file_bytes")
            status = artifact_hash.get("status")
            value = artifact_hash.get("value")
            if status == "available":
                if not isinstance(value, str) or not SHA256_RE.match(value):
                    errors.append("/source/artifact_hash/value must be a lowercase SHA-256 when available")
            elif status == "unavailable":
                if value is not None:
                    errors.append("/source/artifact_hash/value must be null when unavailable")
                warnings.append("source DXP byte hash is unavailable; provenance must be confirmed before conversion")
            else:
                errors.append("/source/artifact_hash/status is invalid")
    else:
        errors.append("/source must be an object")

    for object_path in OBJECT_ARRAY_PATHS:
        values = _at(manifest, object_path)
        if not isinstance(values, list):
            errors.append("%s must be an array" % _pointer(object_path))
            continue
        for index, item in enumerate(values):
            path = object_path + (index,)
            if not isinstance(item, dict):
                errors.append("%s must be an object" % _pointer(path))
                continue
            _check_envelope(item, path, errors, seen_ids)
            _walk_nested_objects(item, path, errors, seen_ids)

    _check_issue_list(manifest.get("unsupported"), (), errors, False)
    _check_issue_list(manifest.get("export_errors"), (), errors, True)
    _check_type_specific(manifest, errors, warnings)
    _check_credentials(manifest, (), errors)
    return (errors, warnings)


def validate_provenance_map(provenance_map, manifest=None):
    errors = []
    warnings = []
    if not _require_keys(
        provenance_map,
        (
            "provenance_map_type",
            "provenance_map_version",
            "manifest_version",
            "exporter_version",
            "source_artifact_sha256",
            "mappings",
        ),
        (),
        errors,
    ):
        return (errors, warnings)
    if provenance_map.get("provenance_map_type") != "spotfire_neutral_manifest_provenance":
        errors.append("/provenance_map_type is invalid")
    if provenance_map.get("provenance_map_version") != SUPPORTED_PROVENANCE_MAP_VERSION:
        errors.append(
            "/provenance_map_version must be %s" %
            SUPPORTED_PROVENANCE_MAP_VERSION
        )
    if provenance_map.get("manifest_version") != SUPPORTED_MANIFEST_VERSION:
        errors.append("/manifest_version must be %s" % SUPPORTED_MANIFEST_VERSION)
    digest = provenance_map.get("source_artifact_sha256")
    if digest is not None and (not isinstance(digest, str) or not SHA256_RE.match(digest)):
        errors.append("/source_artifact_sha256 must be null or a lowercase SHA-256")
    mappings = provenance_map.get("mappings")
    if not isinstance(mappings, list):
        errors.append("/mappings must be an array")
        return (errors, warnings)
    pointers = set()
    for index, mapping in enumerate(mappings):
        path = ("mappings", index)
        if not _require_keys(
            mapping,
            ("manifest_pointer", "source_id", "api_path", "evidence", "authoritative", "unsupported", "export_errors"),
            path,
            errors,
        ):
            continue
        pointer = mapping.get("manifest_pointer")
        if not isinstance(pointer, str) or not pointer.startswith("/"):
            errors.append("%s/manifest_pointer must be a JSON pointer" % _pointer(path))
        elif pointer in pointers:
            errors.append("%s/manifest_pointer is duplicated" % _pointer(path))
        else:
            pointers.add(pointer)
        if mapping.get("authoritative") is not True:
            errors.append("%s/authoritative must be true" % _pointer(path))
        if mapping.get("evidence") not in (
            "public_property",
            "public_collection",
            "public_read_only_method",
            "derived_from_public_values",
        ):
            errors.append("%s/evidence is invalid" % _pointer(path))
    if manifest is not None:
        manifest_digest = manifest.get("source", {}).get("artifact_hash", {}).get("value")
        if digest != manifest_digest:
            errors.append("/source_artifact_sha256 does not match the manifest source hash")
        exporter_version = manifest.get("export", {}).get("exporter", {}).get("version")
        if provenance_map.get("exporter_version") != exporter_version:
            errors.append("/exporter_version does not match the manifest")
        for index, mapping in enumerate(mappings):
            if not isinstance(mapping, dict):
                continue
            pointer = mapping.get("manifest_pointer")
            try:
                target = _resolve_json_pointer(manifest, pointer)
            except (KeyError, IndexError, TypeError, ValueError):
                errors.append("/mappings/%d/manifest_pointer does not resolve in the manifest" % index)
                continue
            if not isinstance(target, dict) or target.get("source_id") != mapping.get("source_id"):
                errors.append("/mappings/%d/source_id does not match its manifest target" % index)
    _check_credentials(provenance_map, (), errors)
    return (errors, warnings)


def _resolve_json_pointer(document, pointer):
    if not isinstance(pointer, str) or not pointer.startswith("/"):
        raise ValueError("invalid JSON pointer")
    current = document
    for token in pointer[1:].split("/"):
        token = token.replace("~1", "/").replace("~0", "~")
        if isinstance(current, list):
            current = current[int(token)]
        elif isinstance(current, dict):
            current = current[token]
        else:
            raise TypeError("pointer traverses a scalar")
    return current


def _load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", help="Spotfire neutral manifest JSON")
    parser.add_argument(
        "--provenance-map",
        dest="provenance_map",
        help="optional manifest provenance-map JSON",
    )
    parser.add_argument("--json", action="store_true", help="emit machine-readable validation results")
    parser.add_argument("--quiet", action="store_true", help="print only failures")
    args = parser.parse_args(argv)

    try:
        manifest = _load_json(args.manifest)
        errors, warnings = validate_manifest(manifest)
        provenance_errors = []
        provenance_warnings = []
        if args.provenance_map:
            provenance_map = _load_json(args.provenance_map)
            provenance_errors, provenance_warnings = validate_provenance_map(
                provenance_map, manifest
            )
            errors.extend(
                "provenance map: " + message for message in provenance_errors
            )
            warnings.extend(
                "provenance map: " + message for message in provenance_warnings
            )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        if args.json:
            print(json.dumps({"valid": False, "errors": [str(exc)], "warnings": []}, indent=2))
        else:
            print("ERROR: %s" % exc, file=sys.stderr)
        return 2

    result = {
        "valid": not errors,
        "manifest": os.path.abspath(args.manifest),
        "errors": errors,
        "warnings": warnings,
    }
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    elif errors:
        print("INVALID %s" % args.manifest)
        for error in errors:
            print("  ERROR %s" % error)
        for warning in warnings:
            print("  WARN  %s" % warning)
    elif not args.quiet:
        print("VALID %s" % args.manifest)
        for warning in warnings:
            print("  WARN  %s" % warning)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
