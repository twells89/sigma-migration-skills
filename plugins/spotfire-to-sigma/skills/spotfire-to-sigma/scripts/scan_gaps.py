#!/usr/bin/env python3
"""Deterministic object census and gap scan for Spotfire manifests."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

import convert
import spotfire_expr


SCHEMA_VERSION = 1
STATUS_ORDER = ("auto", "hint", "manual", "unhandled", "not-applicable")
TYPE_ORDER = (
    "document", "table", "column", "source-operation", "relationship",
    "page", "visual", "axis", "filtering-scheme", "filter",
    "document-property", "bookmark", "security", "script", "data-function",
    "mod", "marking", "unsupported", "export-error",
)


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


def _stable(prefix, value):
    body = json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True)
    return "%s-%s" % (
        prefix, hashlib.sha256(body.encode("utf-8")).hexdigest()[:12]
    )


def _source(artifact, pointer, **extra):
    result = {
        "artifact": os.path.basename(str(artifact)),
        "json_pointer": pointer,
    }
    result.update({key: value for key, value in extra.items()
                   if value is not None})
    return result


def _object(kind, object_id, name, status, evidence, source):
    if status not in STATUS_ORDER:
        raise ValueError("invalid census status %r" % status)
    return {
        "type": kind,
        "id": str(object_id),
        "name": str(name or object_id),
        "status": status,
        "evidence": list(evidence),
        "source": source,
    }


def _gap(obj, category, reason, warning_id=None):
    result = {
        "object_type": obj["type"],
        "object_id": obj["id"],
        "object_name": obj["name"],
        "category": category,
        "reason": reason,
        "evidence": list(obj["evidence"]),
        "source": obj["source"],
    }
    if warning_id:
        result["warning_id"] = warning_id
    return result


def _item_id(value, kind, index):
    if isinstance(value, dict):
        return str(convert._first(
            value, "id", "key", "source_id", "name", "title",
            "display_name", "displayName"
        ) or _stable(kind, value))
    return "%s-%d" % (kind, index)


def _item_name(value, kind, index):
    if isinstance(value, dict):
        return str(convert._first(
            value, "name", "title", "display_name", "displayName", "id",
            "key", "source_id"
        ) or "%s %d" % (kind.replace("-", " ").title(), index + 1))
    return str(value)


def _table_objects(manifest, artifact, source_map):
    objects = []
    gaps = []
    tables = convert._manifest_tables(manifest)
    table_root = "/model/tables" if isinstance(manifest.get("model"), dict) else "/tables"
    table_aliases = {}
    for table_index, table in enumerate(tables):
        pointer = "%s/%d" % (table_root, table_index)
        if not isinstance(table, dict):
            obj = _object(
                "table", "table-%d" % table_index, "Table %d" % (table_index + 1),
                "unhandled", ["table entry is not an object"],
                _source(artifact, pointer),
            )
            objects.append(obj)
            gaps.append(_gap(obj, "unhandled", obj["evidence"][0],
                             "SPOTFIRE-TABLE-SHAPE"))
            continue
        table_id = convert._table_id(table, table_index)
        table_name = convert._table_name(table, table_index)
        kind = convert._source_kind(table)
        _defaults, mapping = convert._mapping_for(table, source_map or {})
        explicit_direct = convert._direct_source_mapping(table)
        if kind in convert.REQUIRES_SOURCE_MAP and mapping is None:
            status = "unhandled"
            evidence = [
                "%s source has no explicit source-map entry" % kind
            ]
        elif mapping is None and explicit_direct is None:
            status = "unhandled"
            evidence = ["table has no explicit source-map or warehouse path"]
        elif kind == "data-function":
            status = "manual"
            evidence = [
                "mapped output can be consumed, but data-function logic is not translated"
            ]
        else:
            status = "auto"
            evidence = ["table resolves through an explicit warehouse target"]
        obj = _object(
            "table", table_id, table_name, status, evidence,
            _source(artifact, pointer, source_kind=kind),
        )
        objects.append(obj)
        table_aliases[table_id.casefold()] = table
        table_aliases[table_name.casefold()] = table
        if status in ("manual", "unhandled"):
            gaps.append(_gap(
                obj, status, evidence[0],
                "SPOTFIRE-SOURCE-MAP-MISSING"
                if status == "unhandled" else
                "SPOTFIRE-DATA-FUNCTION-UNSUPPORTED",
            ))

        for column_index, column in enumerate(convert._table_columns(table)):
            column_pointer = "%s/columns/%d" % (pointer, column_index)
            column_name = convert._column_name(column, column_index)
            column_id = "%s.%s" % (table_id, column_name)
            expression = convert._column_expression(column)
            if expression:
                translated = spotfire_expr.translate(expression)
                if translated.supported:
                    column_status = "auto"
                    column_evidence = [
                        "calculated column expression is in the conservative allowlist"
                    ]
                else:
                    column_status = "unhandled"
                    column_evidence = [translated.reason]
            else:
                translated = None
                column_status = "auto"
                column_evidence = ["physical column maps to the landed table"]
            column_obj = _object(
                "column", column_id, column_name, column_status, column_evidence,
                _source(artifact, column_pointer, table_id=table_id),
            )
            objects.append(column_obj)
            if column_status == "unhandled":
                gaps.append(_gap(
                    column_obj, "unhandled", column_evidence[0],
                    translated.warning_id if translated else None,
                ))
        for operation_index, operation in enumerate(convert._as_list(
                convert._first(table, "source_operations", "sourceOperations",
                               "operations"))):
            operation_pointer = "%s/source_operations/%d" % (
                pointer, operation_index
            )
            operation_id = _item_id(
                operation, "%s-source-operation" % table_id, operation_index
            )
            operation_name = _item_name(
                operation, "source-operation", operation_index
            )
            expression = (
                convert._first(operation, "expression", "formula")
                if isinstance(operation, dict) else None
            )
            operation_status = "manual" if expression else "hint"
            operation_evidence = [
                "source operation expression must be rebuilt upstream"
                if expression else
                "source operation is represented by the explicit landed-table mapping"
            ]
            operation_obj = _object(
                "source-operation", operation_id, operation_name,
                operation_status, operation_evidence,
                _source(artifact, operation_pointer, table_id=table_id),
            )
            objects.append(operation_obj)
            if operation_status == "manual":
                gaps.append(_gap(
                    operation_obj, "manual", operation_evidence[0],
                    "SPOTFIRE-SOURCE-OPERATION-UNSUPPORTED",
                ))

    relation_root = (
        "/model/relations"
        if isinstance(manifest.get("model"), dict) else "/relationships"
    )
    for relation_index, relation in enumerate(
            convert._manifest_relationships(manifest)):
        pointer = "%s/%d" % (relation_root, relation_index)
        relation_id = _item_id(relation, "relationship", relation_index)
        relation_name = _item_name(relation, "relationship", relation_index)
        if isinstance(relation, dict):
            left_table, left_columns = convert._relationship_endpoint_columns(
                relation, "left")
            right_table, right_columns = convert._relationship_endpoint_columns(
                relation, "right")
            complete = (
                bool(left_table)
                and bool(right_table)
                and bool(left_columns)
                and len(left_columns) == len(right_columns)
            )
        else:
            complete = False
        status = "hint" if complete else "unhandled"
        evidence = [
            "relationship endpoints are present; fact/dimension direction still requires review"
            if complete else
            "relationship endpoints are incomplete"
        ]
        obj = _object(
            "relationship", relation_id, relation_name, status, evidence,
            _source(artifact, pointer),
        )
        objects.append(obj)
        if not complete:
            gaps.append(_gap(
                obj, "unhandled", evidence[0],
                "SPOTFIRE-RELATION-UNRESOLVED",
            ))
    return objects, gaps


def _filter_object(value, artifact, pointer, filter_index,
                   parent_id, page_id=None, visual_id=None):
    object_id = _item_id(
        value, "%s-filter" % parent_id, filter_index
    )
    name = _item_name(value, "filter", filter_index)
    if not isinstance(value, dict):
        status = "unhandled"
        evidence = ["filter entry is not an object"]
    elif convert._filter_column(value):
        status = "auto"
        evidence = ["filter has a column binding candidate"]
    else:
        status = "unhandled"
        evidence = ["filter has no resolvable column binding"]
    return _object(
        "filter", object_id, name, status, evidence,
        _source(artifact, pointer, page_id=page_id, visual_id=visual_id),
    )


def _page_objects(manifest, artifact):
    objects = []
    gaps = []
    pages = convert._manifest_pages(manifest)
    page_root = (
        "/presentation/pages"
        if isinstance(manifest.get("presentation"), dict) else "/pages"
    )
    for page_index, page in enumerate(pages):
        pointer = "%s/%d" % (page_root, page_index)
        page = page if isinstance(page, dict) else {}
        page_id = convert._page_id(page, page_index)
        page_name = convert._page_name(page, page_index)
        page_obj = _object(
            "page", page_id, page_name, "not-applicable",
            ["page is a source container; child objects are classified separately"],
            _source(artifact, pointer),
        )
        objects.append(page_obj)

        for filter_index, value in enumerate(convert._as_list(
                convert._first(page, "filters", "filtering", "filter_schemes",
                               "filterSchemes"))):
            obj = _filter_object(
                value, artifact, "%s/filters/%d" % (pointer, filter_index),
                filter_index, page_id, page_id=page_id,
            )
            objects.append(obj)
            if obj["status"] == "unhandled":
                gaps.append(_gap(
                    obj, "unhandled", obj["evidence"][0],
                    "SPOTFIRE-FILTER-BINDING-UNRESOLVED",
                ))

        for visual_index, visual in enumerate(convert._page_visuals(page)):
            visual_pointer = "%s/visuals/%d" % (pointer, visual_index)
            visual_id = (
                convert._visual_id(visual, visual_index)
                if isinstance(visual, dict) else
                "%s-visual-%d" % (page_id, visual_index)
            )
            visual_name = (
                convert._visual_name(visual, visual_index)
                if isinstance(visual, dict) else
                "Visual %d" % (visual_index + 1)
            )
            classification = (
                convert.classify_visual(visual)
                if isinstance(visual, dict) else
                {"source": None, "sigma": None, "status": "unhandled"}
            )
            expression_failures = []
            axis_count = 0
            axis_roles = set()
            dimension_count = 0
            measure_count = 0
            if isinstance(visual, dict):
                for axis_index, (role, axis) in enumerate(
                        convert.iter_axis_fields(visual)):
                    expression = convert._axis_expression(axis)
                    axis_id = _item_id(
                        axis, "%s-axis" % visual_id, axis_index
                    )
                    axis_name = _item_name(axis, "axis", axis_index)
                    if not expression:
                        warning_id = "SPOTFIRE-AXIS-EXPRESSION-MISSING"
                        reason = "axis %s has no expression" % role
                        expression_failures.append((
                            warning_id, reason,
                        ))
                        axis_status = "unhandled"
                        axis_evidence = [reason]
                    else:
                        axis_count += 1
                        axis_roles.add(role)
                        translated = spotfire_expr.translate(expression)
                        if translated.supported:
                            semantic = translated.kind
                            if role in convert.MEASURE_ROLES:
                                semantic = "measure"
                            elif (role in convert.DIMENSION_ROLES
                                  and translated.kind != "measure"):
                                semantic = "dimension"
                            if semantic == "measure":
                                measure_count += 1
                            else:
                                dimension_count += 1
                            axis_status = "auto"
                            axis_evidence = [
                                "axis expression is in the conservative allowlist"
                            ]
                        else:
                            axis_status = "unhandled"
                            axis_evidence = [translated.reason]
                            expression_failures.append((
                                translated.warning_id, translated.reason
                            ))
                    axis_obj = _object(
                        "axis", axis_id, axis_name, axis_status, axis_evidence,
                        _source(
                            artifact,
                            "%s/axes/%d" % (visual_pointer, axis_index),
                            page_id=page_id, visual_id=visual_id,
                        ),
                    )
                    objects.append(axis_obj)
                    if axis_status == "unhandled":
                        gaps.append(_gap(
                            axis_obj, "unhandled", axis_evidence[0],
                            warning_id if not expression
                            else translated.warning_id,
                        ))
            target = classification["sigma"]
            if target == "table":
                binding_complete = axis_count > 0
            elif target == "pivot-table":
                binding_complete = dimension_count > 0 and measure_count > 0
            elif target == "kpi-chart":
                binding_complete = measure_count > 0
            elif target in (
                    "bar-chart", "line-chart", "area-chart", "combo-chart",
                    "pie-chart", "donut-chart"):
                binding_complete = dimension_count > 0 and measure_count > 0
            elif target == "scatter-chart":
                binding_complete = (
                    ("x" in axis_roles or "x-axis" in axis_roles)
                    and ("y" in axis_roles or "y-axis" in axis_roles)
                )
            else:
                binding_complete = False
            if (classification["sigma"] and binding_complete
                    and not expression_failures):
                status = "auto"
                evidence = [
                    "%s maps to %s and every extracted axis expression is supported" %
                    (classification["source"], classification["sigma"])
                ]
            elif classification["sigma"]:
                status = "manual"
                evidence = [
                    "native visual mapping exists, but required axis bindings are incomplete or unsupported"
                ]
            else:
                status = "unhandled"
                evidence = [
                    "custom or unsupported visual type %r has no native mapping" %
                    classification["source"]
                ]
            obj = _object(
                "visual", visual_id, visual_name, status, evidence,
                _source(artifact, visual_pointer, page_id=page_id),
            )
            objects.append(obj)
            if status in ("manual", "unhandled"):
                gaps.append(_gap(
                    obj, status, evidence[0],
                    "SPOTFIRE-VISUAL-UNSUPPORTED"
                    if status == "unhandled" else
                    "SPOTFIRE-VISUAL-REVIEW",
                ))
            for warning_id, reason in expression_failures:
                gaps.append(_gap(obj, "unhandled", reason, warning_id))

            if isinstance(visual, dict):
                markings = []
                for key in ("marking", "markings", "marking_name", "markingName"):
                    if visual.get(key) not in (None, [], {}, False):
                        markings.extend(convert._as_list(visual[key]))
                for marking_index, marking in enumerate(markings):
                    marking_id = "%s-marking-%d" % (visual_id, marking_index)
                    marking_obj = _object(
                        "marking", marking_id, str(marking), "manual",
                        ["Spotfire marking interaction is not converted"],
                        _source(
                            artifact,
                            "%s/markings/%d" %
                            (visual_pointer, marking_index),
                            page_id=page_id, visual_id=visual_id,
                        ),
                    )
                    objects.append(marking_obj)
                    gaps.append(_gap(
                        marking_obj, "manual", marking_obj["evidence"][0],
                        "SPOTFIRE-MARKING-UNSUPPORTED",
                    ))
                for filter_index, value in enumerate(convert._as_list(
                        convert._first(visual, "filters", "filtering"))):
                    filter_obj = _filter_object(
                        value, artifact,
                        "%s/filters/%d" % (visual_pointer, filter_index),
                        filter_index, visual_id, page_id=page_id,
                        visual_id=visual_id,
                    )
                    objects.append(filter_obj)
                    if filter_obj["status"] == "unhandled":
                        gaps.append(_gap(
                            filter_obj, "unhandled",
                            filter_obj["evidence"][0],
                            "SPOTFIRE-FILTER-BINDING-UNRESOLVED",
                        ))
    return objects, gaps


def _top_level_objects(manifest, artifact):
    objects = []
    gaps = []
    source_document = manifest.get("source")
    if isinstance(source_document, dict):
        document_id = _item_id(source_document, "document", 0)
        objects.append(_object(
            "document", document_id,
            _item_name(source_document, "document", 0),
            "not-applicable",
            ["document is the source container for model and presentation objects"],
            _source(artifact, "/source"),
        ))

    presentation = (
        manifest.get("presentation")
        if isinstance(manifest.get("presentation"), dict) else {}
    )
    schemes = convert._as_list(convert._first(
        presentation, "filtering_schemes", "filteringSchemes",
        "filter_schemes", "filterSchemes",
    ))
    for scheme_index, scheme in enumerate(schemes):
        pointer = "/presentation/filtering_schemes/%d" % scheme_index
        scheme_id = _item_id(scheme, "filtering-scheme", scheme_index)
        scheme_obj = _object(
            "filtering-scheme", scheme_id,
            _item_name(scheme, "filtering-scheme", scheme_index),
            "not-applicable",
            ["filtering scheme is a source container; filters are classified separately"],
            _source(artifact, pointer),
        )
        objects.append(scheme_obj)
        for filter_index, value in enumerate(
                convert._as_list(scheme.get("filters"))
                if isinstance(scheme, dict) else []):
            filter_obj = _filter_object(
                value, artifact, "%s/filters/%d" % (pointer, filter_index),
                filter_index, scheme_id,
            )
            objects.append(filter_obj)
            if filter_obj["status"] == "unhandled":
                gaps.append(_gap(
                    filter_obj, "unhandled", filter_obj["evidence"][0],
                    "SPOTFIRE-FILTER-BINDING-UNRESOLVED",
                ))

    flat_filters = convert._as_list(convert._first(
        manifest, "filters", "filtering", "filter_schemes", "filterSchemes"
    ))
    for filter_index, value in enumerate(flat_filters):
        obj = _filter_object(
            value, artifact, "/filters/%d" % filter_index,
            filter_index, "document",
        )
        objects.append(obj)
        if obj["status"] == "unhandled":
            gaps.append(_gap(
                obj, "unhandled", obj["evidence"][0],
                "SPOTFIRE-FILTER-BINDING-UNRESOLVED",
            ))

    for index, value in enumerate(convert._document_properties(manifest)):
        pointer = "/document_properties/%d" % index
        status = "manual"
        evidence = [
            "redacted document property needs an operator-supplied default"
            if isinstance(value, dict) and value.get("redacted") else
            "property maps to a parameter control, but every consumer must be rewired explicitly"
        ]
        obj = _object(
            "document-property", _item_id(value, "document-property", index),
            _item_name(value, "document-property", index), status, evidence,
            _source(artifact, pointer),
        )
        objects.append(obj)
        if status == "manual":
            gaps.append(_gap(
                obj, "manual", evidence[0],
                "SPOTFIRE-PROPERTY-REDACTED"
                if isinstance(value, dict) and value.get("redacted") else
                "SPOTFIRE-DOCUMENT-PROPERTY-CONSUMER-REVIEW",
            ))

    automation = (
        manifest.get("automation")
        if isinstance(manifest.get("automation"), dict) else {}
    )
    automation_groups = (
        (
            convert._as_list(manifest.get("scripts")) +
            convert._as_list(automation.get("scripts")),
            "script", "Spotfire script is not executed or translated",
            "SPOTFIRE-SCRIPT-UNSUPPORTED", "/automation/scripts",
        ),
        (
            convert._as_list(manifest.get("data_functions")) +
            convert._as_list(manifest.get("dataFunctions")) +
            convert._as_list(automation.get("data_functions")) +
            convert._as_list(automation.get("dataFunctions")),
            "data-function", "data-function logic must be rebuilt upstream",
            "SPOTFIRE-DATA-FUNCTION-UNSUPPORTED",
            "/automation/data_functions",
        ),
        (
            convert._as_list(manifest.get("mods")) +
            convert._as_list(automation.get("mods")),
            "mod", "Spotfire Mod requires a manual Sigma rebuild",
            "SPOTFIRE-MOD-UNSUPPORTED", "/automation/mods",
        ),
        (
            convert._as_list(manifest.get("markings")),
            "marking", "Spotfire marking interaction is not converted",
            "SPOTFIRE-MARKING-UNSUPPORTED", "/markings",
        ),
    )
    for values, kind, evidence, warning_id, root in automation_groups:
        for index, value in enumerate(values):
            obj = _object(
                kind, _item_id(value, kind, index),
                _item_name(value, kind, index), "unhandled"
                if kind in ("script", "data-function", "mod") else "manual",
                [evidence], _source(artifact, "%s/%d" % (root, index)),
            )
            objects.append(obj)
            gaps.append(_gap(
                obj, obj["status"], evidence, warning_id
            ))

    for index, bookmark in enumerate(convert._as_list(manifest.get("bookmarks"))):
        obj = _object(
            "bookmark", _item_id(bookmark, "bookmark", index),
            _item_name(bookmark, "bookmark", index), "manual",
            ["Spotfire bookmark state is not converted automatically"],
            _source(artifact, "/bookmarks/%d" % index),
        )
        objects.append(obj)
        gaps.append(_gap(
            obj, "manual", obj["evidence"][0],
            "SPOTFIRE-BOOKMARK-UNSUPPORTED",
        ))

    security = manifest.get("security")
    security_values = (
        convert._as_list(security.get("signals"))
        if isinstance(security, dict) else convert._as_list(security)
    )
    for index, value in enumerate(security_values):
        source_status = (
            str(value.get("status") or "").casefold()
            if isinstance(value, dict) else ""
        )
        status = "auto" if source_status == "not_detected" else "manual"
        evidence = [
            "security signal explicitly reports not detected"
            if status == "auto" else
            "security finding requires explicit Sigma RLS/CLS review"
        ]
        obj = _object(
            "security", _item_id(value, "security", index),
            _item_name(value, "security", index), status, evidence,
            _source(artifact, "/security/signals/%d" % index),
        )
        objects.append(obj)
        if status == "manual":
            gaps.append(_gap(
                obj, "manual", evidence[0], "SPOTFIRE-SECURITY-REVIEW"
            ))
    if (isinstance(security, dict)
            and security.get("requires_manual_review")
            and not security_values):
        obj = _object(
            "security", "manifest-security", "Security review", "manual",
            ["manifest requires manual security review but has no normalized signals"],
            _source(artifact, "/security"),
        )
        objects.append(obj)
        gaps.append(_gap(
            obj, "manual", obj["evidence"][0],
            "SPOTFIRE-SECURITY-REVIEW",
        ))

    def collect_diagnostics(value, pointer=""):
        if isinstance(value, dict):
            for key, child in value.items():
                child_pointer = "%s/%s" % (pointer, key)
                if key in ("unsupported", "export_errors", "exportErrors"):
                    kind = "unsupported" if key == "unsupported" else "export-error"
                    warning_id = (
                        "SPOTFIRE-SOURCE-UNSUPPORTED"
                        if kind == "unsupported" else "SPOTFIRE-EXPORT-ERROR"
                    )
                    for index, item in enumerate(convert._as_list(child)):
                        evidence = str(
                            convert._first(item, "message", "reason", "code")
                            if isinstance(item, dict) else item
                        )
                        diagnostic_id = "%s@%s/%d" % (
                            _item_id(item, kind, index),
                            child_pointer,
                            index,
                        )
                        obj = _object(
                            kind, diagnostic_id,
                            _item_name(item, kind, index), "unhandled",
                            [evidence],
                            _source(
                                artifact, "%s/%d" % (child_pointer, index)
                            ),
                        )
                        objects.append(obj)
                        diagnostic_gap = _gap(
                            obj, "unhandled", evidence, warning_id
                        )
                        if (
                            kind == "unsupported"
                            and isinstance(item, dict)
                            and item.get("severity") == "blocking"
                        ):
                            diagnostic_gap["blocking"] = True
                        gaps.append(diagnostic_gap)
                else:
                    collect_diagnostics(child, child_pointer)
        elif isinstance(value, list):
            for index, child in enumerate(value):
                collect_diagnostics(child, "%s/%d" % (pointer, index))

    collect_diagnostics(manifest)
    document = manifest.get("document")
    if isinstance(document, dict):
        existing = {
            (obj["type"], obj["id"]) for obj in objects
            if obj["type"] == "document-property"
        }
        for index, value in enumerate(convert._as_list(
                convert._first(document, "properties", "document_properties",
                               "documentProperties"))):
            object_id = _item_id(value, "document-property", index)
            if ("document-property", object_id) in existing:
                continue
            objects.append(_object(
                "document-property", object_id,
                _item_name(value, "document-property", index), "auto",
                ["document property maps to a Sigma parameter control"],
                _source(artifact, "/document/properties/%d" % index),
            ))
    return objects, gaps


def build_report(manifest, artifact="manifest.json", source_map=None):
    if not isinstance(manifest, dict):
        raise ValueError("manifest root must be an object")
    table_objects, table_gaps = _table_objects(
        manifest, artifact, source_map
    )
    page_objects, page_gaps = _page_objects(manifest, artifact)
    top_objects, top_gaps = _top_level_objects(manifest, artifact)
    objects = table_objects + page_objects + top_objects
    gaps = table_gaps + page_gaps + top_gaps
    type_rank = {name: index for index, name in enumerate(TYPE_ORDER)}
    objects.sort(key=lambda obj: (
        type_rank.get(obj["type"], len(TYPE_ORDER)),
        obj["id"], obj["source"]["json_pointer"],
    ))
    gaps.sort(key=lambda gap: (
        type_rank.get(gap["object_type"], len(TYPE_ORDER)),
        gap["object_id"], gap["category"], gap["reason"],
    ))
    by_type = {}
    by_status = {status: 0 for status in STATUS_ORDER}
    for obj in objects:
        by_type[obj["type"]] = by_type.get(obj["type"], 0) + 1
        by_status[obj["status"]] += 1
    by_type = {
        key: by_type[key]
        for key in TYPE_ORDER if by_type.get(key)
    }
    by_status = {
        key: by_status[key]
        for key in STATUS_ORDER if by_status.get(key)
    }
    gap_categories = {}
    for gap in gaps:
        gap_categories[gap["category"]] = (
            gap_categories.get(gap["category"], 0) + 1
        )
    security_signals = [
        obj for obj in objects if obj["type"] == "security"
    ]
    security_count = sum(
        obj["status"] in ("manual", "unhandled")
        for obj in security_signals
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "source": {
            "artifact": os.path.basename(str(artifact)),
            "format": (
                convert._first(manifest, "schema", "schema_version",
                               "manifest_version", "manifestVersion")
                or "spotfire-manifest-v1"
            ),
        },
        "summary": {
            "objects": len(objects),
            "by_type": by_type,
            "by_status": by_status,
            "gaps": len(gaps),
            "gap_categories": dict(sorted(gap_categories.items())),
        },
        "security": {
            "findings": security_count,
            "signals": len(security_signals),
            "status": "review-required" if security_count else "none-observed",
        },
        "objects": objects,
        "gaps": gaps,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest")
    parser.add_argument("--source-map")
    parser.add_argument("--out", default="gap-report.json")
    parser.add_argument(
        "--strict", action="store_true",
        help="exit nonzero if any manual or unhandled gap remains",
    )
    arguments = parser.parse_args(argv)
    report = build_report(
        _read_json(arguments.manifest),
        artifact=arguments.manifest,
        source_map=_read_json(arguments.source_map)
        if arguments.source_map else None,
    )
    _write_json(arguments.out, report)
    print(
        "Spotfire->Sigma census: %d object(s), %d gap(s), security=%s" %
        (
            report["summary"]["objects"],
            report["summary"]["gaps"],
            report["security"]["status"],
        )
    )
    print("wrote %s" % arguments.out)
    if arguments.strict and report["gaps"]:
        print(
            "RED: %d unresolved manual/unhandled gap(s)" %
            len(report["gaps"]),
            file=sys.stderr,
        )
        return 1
    print("GREEN" if not report["gaps"] else
          "reported: resolve or explicitly accept every gap before live use")
    return 0


if __name__ == "__main__":
    sys.exit(main())
