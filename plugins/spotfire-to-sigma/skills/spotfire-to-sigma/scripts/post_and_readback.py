#!/usr/bin/env python3
"""Spotfire-specific Sigma POST/readback gate.

The helper compares logical element/column census by stable names and source
paths, records server ID remaps, and rejects every ``type=error`` column.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path
import re
import sys
from typing import Any
import urllib.parse

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import sigma_rest  # noqa: E402


class ReadbackError(ValueError):
    pass


def _read_json(path: str | Path) -> dict[str, Any]:
    value = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise ReadbackError("%s must contain a JSON object" % path)
    return value


def _write_json(path: str | Path, value: Any) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp.%d" % os.getpid())
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def workbook_document(spec: dict[str, Any]) -> dict[str, Any]:
    candidate = spec.get("spec") if isinstance(spec.get("spec"), dict) else spec
    document = candidate.get("document")
    return document if isinstance(document, dict) else candidate


def iter_elements(spec: dict[str, Any], kind: str):
    if kind == "datamodel":
        candidate = (
            spec.get("spec") if isinstance(spec.get("spec"), dict) else spec
        )
        for page in candidate.get("pages") or []:
            if isinstance(page, dict):
                for element in page.get("elements") or []:
                    if isinstance(element, dict):
                        yield element
        return
    for element in workbook_document(spec).get("elements") or []:
        if isinstance(element, dict):
            yield element


def sanitize_spec(kind: str, spec: dict[str, Any]) -> dict[str, Any]:
    outgoing = copy.deepcopy(spec)
    if kind != "workbook":
        return outgoing
    document = workbook_document(outgoing)
    for element in document.get("elements") or []:
        if isinstance(element, dict):
            element.pop("visibleAsSource", None)
    if "document" not in outgoing:
        metadata = {
            key: value
            for key, value in outgoing.items()
            if key not in (
                "schemaVersion", "pages", "elements", "overlays", "panels",
                "kind", "layout", "settings", "agents",
            )
        }
        outgoing = {**metadata, "document": document}
    return outgoing


def _source_path(element: dict[str, Any]) -> tuple[str, ...]:
    path = (element.get("source") or {}).get("path")
    if isinstance(path, str):
        return tuple(part for part in path.split(".") if part)
    return tuple(str(part) for part in path or [])


def _element_signature(element: dict[str, Any], kind: str) -> tuple:
    return (
        str(element.get("name") or "").casefold(),
        str(element.get("kind") or "").casefold(),
        _source_path(element) if kind == "datamodel" else (),
    )


def _column_signature(column: dict[str, Any]) -> tuple[str, str]:
    return (
        str(column.get("name") or "").strip().casefold(),
        str(column.get("formula") or "").strip().casefold(),
    )


def _normalized_formula(value: Any) -> str:
    return re.sub(r"\s+", "", str(value or "")).casefold()


def _contains_expected(actual: Any, expected: Any, path=()) -> bool:
    """Return true when readback preserves every authored semantic field."""
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(
            key in actual
            and _contains_expected(actual[key], value, path + (key,))
            for key, value in expected.items()
        )
    if isinstance(expected, list):
        return (
            isinstance(actual, list)
            and len(actual) == len(expected)
            and all(
                _contains_expected(actual_value, expected_value, path)
                for actual_value, expected_value
                in zip(actual, expected)
            )
        )
    if path and path[-1] == "formula":
        return _normalized_formula(actual) == _normalized_formula(expected)
    if isinstance(expected, str) and isinstance(actual, str):
        return actual.casefold() == expected.casefold()
    return actual == expected


def _match_column(
    expected: dict[str, Any],
    actual: list[dict[str, Any]],
) -> dict[str, Any] | None:
    """Match a read-back column without requiring formula byte equality.

    Sigma can normalize formula whitespace on readback. Column names are the
    stable census key; formula text is only needed to disambiguate duplicate
    names.
    """
    expected_id = expected.get("id")
    if expected_id:
        direct = [
            value for value in actual
            if str(value.get("id") or "") == str(expected_id)
        ]
        if len(direct) == 1:
            return direct[0]
    expected_name = str(expected.get("name") or "").strip().casefold()
    by_name = [
        value for value in actual
        if str(value.get("name") or "").strip().casefold() == expected_name
    ]
    if len(by_name) == 1:
        return by_name[0]
    wanted = _column_signature(expected)
    exact = [value for value in by_name if _column_signature(value) == wanted]
    return exact[0] if len(exact) == 1 else None


def _match_one(
    expected: dict[str, Any],
    actual: list[dict[str, Any]],
    signature,
) -> dict[str, Any] | None:
    expected_id = expected.get("id")
    if expected_id:
        direct = [
            value for value in actual
            if str(value.get("id") or "") == str(expected_id)
        ]
        if len(direct) == 1:
            return direct[0]
    wanted = signature(expected)
    matches = [value for value in actual if signature(value) == wanted]
    return matches[0] if len(matches) == 1 else None


def _is_error_column(column: dict[str, Any]) -> bool:
    column_type = column.get("type")
    if isinstance(column_type, dict):
        column_type = column_type.get("type")
    return (
        str(column_type or "").casefold() == "error"
        or bool(column.get("error"))
    )


def verify_readback(
    posted: dict[str, Any],
    readback: dict[str, Any],
    kind: str,
    *,
    endpoint_columns: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    expected_elements = list(iter_elements(posted, kind))
    actual_elements = list(iter_elements(readback, kind))
    missing_elements = []
    dropped_columns = {}
    ambiguous_columns = {}
    element_ids = {}
    column_ids = {}
    semantic_mismatches = []
    relationship_checks = []
    matched_actual = []
    available_elements = list(actual_elements)

    for expected in expected_elements:
        actual = _match_one(
            expected,
            available_elements,
            lambda value: _element_signature(value, kind),
        )
        label = str(expected.get("name") or expected.get("id") or "(unnamed)")
        if actual is None:
            missing_elements.append(label)
            continue
        available_elements.remove(actual)
        matched_actual.append(actual)
        local_element_id = str(expected.get("id") or label)
        server_element_id = actual.get("id")
        if not server_element_id:
            missing_elements.append("%s (readback id missing)" % label)
            continue
        element_ids[local_element_id] = str(server_element_id)
        element_ids[label] = str(server_element_id)
        for field in ("name", "kind", "source"):
            if field in expected and not _contains_expected(
                    actual.get(field), expected[field], (field,)):
                semantic_mismatches.append(
                    "%s.%s changed on readback" % (label, field)
                )
        if kind == "datamodel" and "relationships" in expected:
            relationship_checks.append((
                label,
                local_element_id,
                expected.get("relationships") or [],
                actual.get("relationships") or [],
            ))
        if kind == "workbook":
            for field in (
                "groupings", "xAxis", "yAxis", "yAxis2", "color", "size",
                "value", "rowsBy", "columnsBy", "values", "filters",
                "controlId", "controlType", "mode", "selectionMode",
                "includeNulls",
            ):
                if field in expected and not _contains_expected(
                        actual.get(field), expected[field], (field,)):
                    semantic_mismatches.append(
                        "%s.%s changed on readback" % (label, field)
                    )

        actual_columns = [
            value for value in actual.get("columns") or []
            if isinstance(value, dict)
        ]
        missing = []
        ambiguous = []
        for expected_column in expected.get("columns") or []:
            if not isinstance(expected_column, dict):
                continue
            actual_column = _match_column(expected_column, actual_columns)
            column_label = str(
                expected_column.get("name")
                or expected_column.get("id")
                or "(unnamed)"
            )
            if actual_column is None:
                expected_name = str(
                    expected_column.get("name") or ""
                ).strip().casefold()
                same = [
                    value for value in actual_columns
                    if str(value.get("name") or "").strip().casefold()
                    == expected_name
                ]
                (ambiguous if len(same) > 1 else missing).append(column_label)
                continue
            for field in ("name", "formula"):
                if field in expected_column and not _contains_expected(
                        actual_column.get(field),
                        expected_column[field],
                        (field,),
                ):
                    semantic_mismatches.append(
                        "%s/%s.%s changed on readback"
                        % (label, column_label, field)
                    )
            actual_columns.remove(actual_column)
            if actual_column.get("id"):
                column_ids[
                    "%s/%s" % (
                        local_element_id,
                        expected_column.get("id") or column_label,
                    )
                ] = str(actual_column["id"])
        if missing:
            dropped_columns[label] = sorted(missing)
        if ambiguous:
            ambiguous_columns[label] = sorted(ambiguous)

    for (
            label, local_element_id, expected_relationships,
            actual_relationships) in relationship_checks:
        if len(expected_relationships) != len(actual_relationships):
            semantic_mismatches.append(
                "%s.relationships count changed on readback" % label
            )
            continue
        unmatched = list(actual_relationships)
        for expected_relationship in expected_relationships:
            target_local = str(
                expected_relationship.get("targetElementId") or ""
            )
            expected_semantic = {
                "name": expected_relationship.get("name"),
                "targetElementId": element_ids.get(target_local),
                "keys": [],
            }
            for key in expected_relationship.get("keys") or []:
                expected_semantic["keys"].append({
                    "sourceColumnId": column_ids.get(
                        "%s/%s" % (
                            local_element_id,
                            key.get("sourceColumnId"),
                        )
                    ),
                    "targetColumnId": column_ids.get(
                        "%s/%s" % (
                            target_local,
                            key.get("targetColumnId"),
                        )
                    ),
                })
            match = next((
                relationship for relationship in unmatched
                if _contains_expected(
                    relationship,
                    expected_semantic,
                    ("relationships",),
                )
            ), None)
            if match is None:
                semantic_mismatches.append(
                    "%s.relationships changed on readback" % label
                )
            else:
                unmatched.remove(match)

    error_columns = []
    seen_errors = set()
    for element in actual_elements:
        for column in element.get("columns") or []:
            if isinstance(column, dict) and _is_error_column(column):
                row = {
                    "elementId": element.get("id"),
                    "element": element.get("name"),
                    "columnId": column.get("id"),
                    "column": column.get("name"),
                    "error": column.get("error") or column.get("message"),
                }
                signature = json.dumps(row, sort_keys=True, default=str)
                if signature not in seen_errors:
                    seen_errors.add(signature)
                    error_columns.append(row)
    for column in endpoint_columns or []:
        if isinstance(column, dict) and _is_error_column(column):
            row = {
                "elementId": column.get("elementId"),
                "element": column.get("elementName"),
                "columnId": column.get("columnId") or column.get("id"),
                "column": column.get("name"),
                "error": column.get("error") or column.get("message"),
            }
            signature = json.dumps(row, sort_keys=True, default=str)
            if signature not in seen_errors:
                seen_errors.add(signature)
                error_columns.append(row)

    expected_column_count = sum(
        len([column for column in element.get("columns") or []
             if isinstance(column, dict)])
        for element in expected_elements
    )
    actual_column_count = sum(
        len([column for column in element.get("columns") or []
             if isinstance(column, dict)])
        for element in matched_actual
    )
    if kind == "workbook":
        expected_layout = workbook_document(posted).get("layout")
        actual_layout = workbook_document(readback).get("layout")
        if expected_layout:
            expected_layout_ids = sorted(re.findall(
                r'\belementId="([^"]+)"', str(expected_layout)
            ))
            actual_layout_ids = sorted(re.findall(
                r'\belementId="([^"]+)"', str(actual_layout or "")
            ))
            if expected_layout_ids != actual_layout_ids:
                semantic_mismatches.append(
                    "workbook layout element membership changed on readback"
                )
    result = {
        "pass": not (
            missing_elements or dropped_columns
            or ambiguous_columns or error_columns or semantic_mismatches
        ),
        "census": {
            "expected_elements": len(expected_elements),
            "matched_elements": len(matched_actual),
            "readback_elements": len(actual_elements),
            "expected_columns": expected_column_count,
            "matched_element_readback_columns": actual_column_count,
        },
        "missing_elements": sorted(missing_elements),
        "dropped_columns": dropped_columns,
        "ambiguous_columns": ambiguous_columns,
        "error_columns": error_columns,
        "semantic_mismatches": sorted(set(semantic_mismatches)),
        "element_ids": element_ids,
        "column_ids": column_ids,
    }
    return result


def list_entries(api, path: str) -> list[dict[str, Any]]:
    entries = []
    cursor = None
    cursor_name = None
    seen = set()
    while True:
        separator = "&" if "?" in path else "?"
        page_path = path + separator + "limit=1000"
        if cursor:
            page_path += "&%s=%s" % (
                cursor_name,
                urllib.parse.quote(str(cursor), safe=""),
            )
        value = api.request("get", page_path)
        if isinstance(value, list):
            entries.extend(item for item in value if isinstance(item, dict))
            break
        if not isinstance(value, dict):
            raise ReadbackError("GET %s returned no list/object" % page_path)
        entries.extend(
            item for item in value.get("entries") or []
            if isinstance(item, dict)
        )
        if value.get("nextPage"):
            cursor, cursor_name = value["nextPage"], "page"
        elif value.get("nextPageToken"):
            cursor, cursor_name = value["nextPageToken"], "pageToken"
        else:
            break
        marker = (cursor_name, str(cursor))
        if marker in seen:
            raise ReadbackError("GET %s repeated its pagination cursor" % path)
        seen.add(marker)
    return entries


def _paths(kind: str, object_id: str | None = None) -> tuple[str, str]:
    if kind == "datamodel":
        return (
            "/v2/dataModels/%s/spec" % object_id
            if object_id else "/v2/dataModels/spec",
            "dataModelId",
        )
    return (
        "/v2/workbooks/%s/spec" % object_id
        if object_id else "/v2/workbooks/spec",
        "workbookId",
    )


def read_existing(
    kind: str,
    object_id: str,
    expected: dict[str, Any],
    *,
    api=sigma_rest,
) -> tuple[dict[str, Any], dict[str, Any]]:
    path, _id_field = _paths(kind, object_id)
    readback = api.request("get", path)
    if not isinstance(readback, dict):
        raise ReadbackError("GET %s returned no JSON object" % path)
    collection = "dataModels" if kind == "datamodel" else "workbooks"
    endpoint_columns = list_entries(
        api, "/v2/%s/%s/columns" % (collection, object_id)
    )
    verdict = verify_readback(
        sanitize_spec(kind, expected),
        readback,
        kind,
        endpoint_columns=endpoint_columns,
    )
    if not verdict["pass"]:
        raise ReadbackError(
            "%s %s readback failed census/error-column verification" %
            (kind, object_id)
        )
    return readback, verdict


def post_and_readback(
    kind: str,
    spec: dict[str, Any],
    *,
    folder_id: str | None = None,
    api=sigma_rest,
) -> tuple[str, dict[str, Any], dict[str, Any], dict[str, Any]]:
    outgoing = sanitize_spec(kind, spec)
    if folder_id:
        outgoing["folderId"] = folder_id
    if kind == "workbook":
        api.request(
            "post",
            "/v2/workbooks/spec/verify",
            body=json.dumps(outgoing),
        )
    path, id_field = _paths(kind)
    response = api.request(
        "post", path, body=json.dumps(outgoing)
    ) or {}
    if not isinstance(response, dict):
        raise ReadbackError("POST %s returned no JSON object" % path)
    object_id = response.get(id_field) or response.get("id")
    if not object_id:
        raise ReadbackError("POST %s returned no %s" % (path, id_field))
    readback_path, _ = _paths(kind, str(object_id))
    readback = api.request("get", readback_path)
    if not isinstance(readback, dict):
        raise ReadbackError(
            "GET %s returned no JSON object" % readback_path
        )
    collection = "dataModels" if kind == "datamodel" else "workbooks"
    endpoint_columns = list_entries(
        api, "/v2/%s/%s/columns" % (collection, object_id)
    )
    verdict = verify_readback(
        outgoing, readback, kind, endpoint_columns=endpoint_columns
    )
    if not verdict["pass"]:
        raise ReadbackError(
            "%s readback lost elements/columns or contains type=error columns"
            % kind
        )
    return str(object_id), response, readback, verdict


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--type", choices=("datamodel", "workbook"), required=True)
    parser.add_argument("--spec", required=True)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--folder-id")
    parser.add_argument("--reuse-id")
    arguments = parser.parse_args(argv)
    workdir = Path(arguments.workdir)
    try:
        spec = _read_json(arguments.spec)
        if arguments.reuse_id:
            object_id = arguments.reuse_id
            response = {"reused": True}
            readback, verdict = read_existing(
                arguments.type, object_id, spec
            )
        else:
            object_id, response, readback, verdict = post_and_readback(
                arguments.type,
                spec,
                folder_id=arguments.folder_id,
            )
        prefix = "datamodel" if arguments.type == "datamodel" else "workbook"
        _write_json(workdir / ("%s-post-response.json" % prefix), response)
        _write_json(workdir / ("%s-readback.json" % prefix), readback)
        _write_json(workdir / ("%s-readback-verdict.json" % prefix), verdict)
        _write_json(
            workdir / ("%s-ids.json" % prefix),
            {
                ("dataModelId" if arguments.type == "datamodel"
                 else "workbookId"): object_id,
                "elementIds": verdict["element_ids"],
                "columnIds": verdict["column_ids"],
            },
        )
    except (
            OSError, ValueError, json.JSONDecodeError,
            sigma_rest.SigmaError) as error:
        print("post_and_readback: %s" % error, file=sys.stderr)
        return 2
    print(
        "PASS: %s %s posted/read back with clean census" %
        (arguments.type, object_id)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
