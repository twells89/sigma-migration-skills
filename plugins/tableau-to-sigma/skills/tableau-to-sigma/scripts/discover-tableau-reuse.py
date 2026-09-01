#!/usr/bin/env python3
"""Discover reusable Sigma data models and workbooks without mutating Sigma.

The command derives one signature from Tableau conversion/layout artifacts,
then performs GET-only Sigma discovery. Automatic reuse is deliberately strict:
exactly one candidate must cover every required table, column, page, and visual.
Partial matches and ties are emitted for review but never selected.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.parse
from collections import Counter
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import sigma_rest  # noqa: E402

DEFAULT_MAX_CANDIDATES = 500
STOP_TOKENS = {
    "AND", "COPY", "DATA", "DEV", "DM", "FACT", "FOR", "FROM", "MODEL",
    "NEW", "OLD", "PROD", "PUBLIC", "RAW", "STG", "TABLE", "TEMP", "TEST",
    "THE", "TMP", "VIEW",
}


class DiscoveryError(ValueError):
    """An input or API contract prevented safe discovery."""


def load_object(path: Path) -> dict:
    with path.open(encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise DiscoveryError(f"{path}: expected a JSON object")
    return value


def load_array(path: Path) -> list:
    with path.open(encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, list):
        raise DiscoveryError(f"{path}: expected a JSON array")
    return value


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def normalize_name(value: Any) -> str:
    return re.sub(r"[^A-Z0-9]", "", str(value or "").upper())


def normalize_fqn(value: Any) -> str | None:
    if isinstance(value, list):
        parts = value
    else:
        parts = str(value or "").split(".")
    normalized = [str(part).strip().upper() for part in parts if str(part).strip()]
    return ".".join(normalized) or None


def fqn_covers(candidate: str | None, required: str | None) -> bool:
    """Match warehouse names from the right, preserving known qualifiers."""
    if not candidate or not required:
        return False
    if candidate == "CUSTOM_SQL" or required == "CUSTOM_SQL":
        return candidate == required
    candidate_parts = candidate.split(".")
    required_parts = required.split(".")
    width = min(len(candidate_parts), len(required_parts))
    return candidate_parts[-width:] == required_parts[-width:]


def iter_dm_elements(spec: dict):
    elements = spec.get("elements")
    if isinstance(elements, list):
        yield from (item for item in elements if isinstance(item, dict))
    for page in spec.get("pages") or []:
        if isinstance(page, dict):
            yield from (
                item for item in page.get("elements") or [] if isinstance(item, dict)
            )


def workbook_document(spec: dict) -> dict:
    document = spec.get("document")
    return document if isinstance(document, dict) else spec


def iter_workbook_elements(spec: dict):
    document = workbook_document(spec)
    elements = document.get("elements")
    if isinstance(elements, list):
        yield from (item for item in elements if isinstance(item, dict))
        return
    for page in document.get("pages") or []:
        if isinstance(page, dict):
            yield from (
                item for item in page.get("elements") or [] if isinstance(item, dict)
            )


def _raw_model_columns(model: dict) -> dict[str, str]:
    result: dict[str, str] = {}
    for element in iter_dm_elements(model):
        for column in element.get("columns") or []:
            if not isinstance(column, dict):
                continue
            for value in (column.get("name"), column.get("label")):
                key = normalize_name(value)
                if key:
                    result.setdefault(key, str(column.get("name") or value))
    return result


def _layout_field_rows(layout: list) -> list[dict]:
    rows: list[dict] = []
    for dashboard in layout:
        if not isinstance(dashboard, dict):
            continue
        for zone in dashboard.get("zones") or []:
            if not isinstance(zone, dict):
                continue
            for shelf_name in ("rows_shelf", "cols_shelf"):
                shelf = zone.get(shelf_name) or {}
                rows.extend(
                    item for item in shelf.get("fields") or [] if isinstance(item, dict)
                )
            for item in zone.get("filters") or []:
                if isinstance(item, dict):
                    rows.append(
                        {
                            "guid": item.get("column_guid"),
                            "caption": item.get("column_caption"),
                            "role": "dim",
                        }
                    )
            if zone.get("filter_column_caption") or zone.get("filter_column_guid"):
                rows.append(
                    {
                        "guid": zone.get("filter_column_guid"),
                        "caption": zone.get("filter_column_caption"),
                        "role": "dim",
                    }
                )
    return rows


def _canonical_visual(kind: Any, name: Any) -> str | None:
    normalized_kind = str(kind or "").lower().replace("_", "-")
    if normalized_kind.endswith("-chart"):
        normalized_kind = normalized_kind[:-6]
    aliases = {"crosstab": "table", "text-table": "table", "filter": "control"}
    normalized_kind = aliases.get(normalized_kind, normalized_kind)
    normalized_name = normalize_name(name)
    if not normalized_kind or not normalized_name:
        return None
    return f"{normalized_kind}:{normalized_name}"


def derive_signature(model: dict, layout: list, layout_meta: dict) -> dict:
    """Derive DM requirements and workbook shape from existing local artifacts."""
    model_columns = _raw_model_columns(model)
    columns_by_guid = layout_meta.get("columns_by_guid") or {}
    required_columns: dict[str, str] = {}
    measures: dict[tuple[str, str], dict] = {}

    for field in _layout_field_rows(layout):
        guid = str(field.get("guid") or "").strip()
        metadata = columns_by_guid.get(guid) if isinstance(columns_by_guid, dict) else {}
        caption = field.get("caption") or (metadata or {}).get("caption")
        resolved = None
        for value in (guid, caption):
            key = normalize_name(value)
            if key and key in model_columns:
                resolved = model_columns[key]
                break
        if not resolved:
            resolved = str(caption or guid or "").strip() or None
        if not resolved:
            continue
        required_columns.setdefault(normalize_name(resolved), resolved)
        if field.get("role") == "measure":
            derivation = str(field.get("derivation") or "").strip()
            measures[(normalize_name(resolved), derivation.upper())] = {
                "col": resolved,
                "derivation": derivation,
            }

    # A layout with no usable shelf metadata is not allowed to erase DM
    # requirements. Falling back to converter columns is conservative.
    column_basis = "layout"
    if not required_columns:
        required_columns = dict(model_columns)
        column_basis = "conversion-fallback"

    tables: set[str] = set()
    for element in iter_dm_elements(model):
        source = element.get("source") or {}
        if source.get("kind") in {"warehouse-table", "table"}:
            fqn = normalize_fqn(
                source.get("path")
                or [source.get("database"), source.get("schema"), source.get("name")]
            )
            if fqn:
                tables.add(fqn)
        elif source.get("kind") == "sql":
            tables.add("CUSTOM_SQL")
        for metric in element.get("metrics") or []:
            if not isinstance(metric, dict) or not metric.get("name"):
                continue
            derivation = str(
                metric.get("aggregation") or metric.get("derivation") or ""
            )
            key = (normalize_name(metric["name"]), derivation.upper())
            measures.setdefault(
                key, {"col": metric["name"], "derivation": derivation}
            )

    dashboard_names: list[str] = []
    visuals: list[str] = []
    for dashboard in layout:
        if not isinstance(dashboard, dict):
            continue
        dashboard_name = str(dashboard.get("dashboard") or "").strip()
        if dashboard_name:
            dashboard_names.append(dashboard_name)
        for zone in dashboard.get("zones") or []:
            if not isinstance(zone, dict):
                continue
            zone_kind = zone.get("kind")
            if zone_kind == "chart":
                visual = _canonical_visual(
                    zone.get("chart_kind"),
                    zone.get("display_title") or zone.get("caption"),
                )
            elif zone_kind in {"filter", "parameter"}:
                visual = _canonical_visual(
                    "control",
                    zone.get("filter_column_caption")
                    or zone.get("caption")
                    or zone.get("parameter_caption"),
                )
            else:
                visual = None
            if visual:
                visuals.append(visual)

    workbook_name = (
        str(model.get("tableau_workbook") or model.get("workbook") or "").strip()
        or (dashboard_names[0] if len(dashboard_names) == 1 else "")
        or str(model.get("name") or "").strip()
    )
    return {
        "schema_version": 1,
        "tableau_workbook": workbook_name,
        "warehouse_tables": sorted(tables),
        "referenced_columns": sorted(required_columns.values(), key=normalize_name),
        "measures": sorted(
            measures.values(),
            key=lambda item: (normalize_name(item["col"]), item["derivation"]),
        ),
        "dashboard_names": list(dict.fromkeys(dashboard_names)),
        "visuals": sorted(visuals),
        "evidence": {
            "column_basis": column_basis,
            "conversion_element_count": sum(1 for _ in iter_dm_elements(model)),
            "layout_dashboard_count": len(dashboard_names),
        },
    }


def dm_signature(spec: dict) -> dict:
    tables: set[str] = set()
    columns: dict[str, str] = {}
    metrics: set[str] = set()
    for element in iter_dm_elements(spec):
        source = element.get("source") or {}
        if source.get("kind") in {"warehouse-table", "table"}:
            fqn = normalize_fqn(
                source.get("path")
                or [source.get("database"), source.get("schema"), source.get("name")]
            )
            if fqn:
                tables.add(fqn)
        elif source.get("kind") == "sql":
            tables.add("CUSTOM_SQL")
        for column in element.get("columns") or []:
            if isinstance(column, dict):
                value = column.get("name") or column.get("label")
                if normalize_name(value):
                    columns.setdefault(normalize_name(value), str(value))
        for metric in element.get("metrics") or []:
            if isinstance(metric, dict) and metric.get("name"):
                metrics.add(
                    f"{normalize_name(metric['name'])}/"
                    f"{str(metric.get('aggregation') or metric.get('derivation') or '').upper()}"
                )
    return {"tables": tables, "columns": columns, "metrics": metrics}


def score_data_model(signature: dict, candidate: dict, spec: dict) -> dict:
    actual = dm_signature(spec)
    required_tables = [
        value for value in map(normalize_fqn, signature["warehouse_tables"]) if value
    ]
    required_columns = {
        normalize_name(value): value for value in signature["referenced_columns"]
    }
    required_metrics = {
        f"{normalize_name(item.get('col'))}/"
        f"{str(item.get('derivation') or '').upper()}"
        for item in signature.get("measures") or []
    }
    shared_tables = [
        table
        for table in required_tables
        if any(fqn_covers(other, table) for other in actual["tables"])
    ]
    shared_columns = set(required_columns) & set(actual["columns"])
    shared_metrics = required_metrics & actual["metrics"]
    table_match = len(shared_tables) / len(required_tables) if required_tables else 0.0
    column_match = (
        len(shared_columns) / len(required_columns) if required_columns else 0.0
    )
    metric_match = (
        len(shared_metrics) / len(required_metrics) if required_metrics else 1.0
    )
    score = 0.2 * table_match + 0.7 * column_match + 0.1 * metric_match
    compatible = bool(required_tables and required_columns) and (
        table_match == 1.0 and column_match == 1.0
    )
    exact = compatible and (
        len(actual["tables"]) == len(required_tables)
        and set(actual["columns"]) == set(required_columns)
        and (not required_metrics or required_metrics == actual["metrics"])
    )
    candidate_id = candidate.get("dataModelId") or candidate.get("id")
    return {
        "id": candidate_id,
        "name": candidate.get("name"),
        "score": round(score, 3),
        "match": "exact" if exact else ("compatible" if compatible else "partial"),
        "high_confidence": compatible,
        "table_match": round(table_match, 3),
        "column_match": round(column_match, 3),
        "metric_match": round(metric_match, 3),
        "missing_tables": sorted(set(required_tables) - set(shared_tables)),
        "missing_columns": sorted(
            (required_columns[key] for key in set(required_columns) - set(actual["columns"])),
            key=normalize_name,
        ),
        "extra_columns": len(set(actual["columns"]) - set(required_columns)),
    }


def _collect_data_model_ids(value: Any, found: set[str]) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if key == "dataModelId" and item:
                found.add(str(item))
            else:
                _collect_data_model_ids(item, found)
    elif isinstance(value, list):
        for item in value:
            _collect_data_model_ids(item, found)


def workbook_signature(spec: dict) -> dict:
    document = workbook_document(spec)
    pages = {
        normalize_name(page.get("name")): str(page.get("name"))
        for page in document.get("pages") or []
        if isinstance(page, dict)
        and page.get("name")
        and str(page.get("visibility") or "").lower() != "hidden"
        and normalize_name(page.get("name")) != "DATA"
    }
    visuals: list[str] = []
    for element in iter_workbook_elements(spec):
        kind = str(element.get("kind") or "")
        if kind.endswith("-chart"):
            visual = _canonical_visual(kind, element.get("name"))
        elif kind in {"control", "filter", "date-range-control", "list-control"}:
            visual = _canonical_visual("control", element.get("name"))
        else:
            visual = None
        if visual:
            visuals.append(visual)
    dm_ids: set[str] = set()
    _collect_data_model_ids(document, dm_ids)
    return {"pages": pages, "visuals": visuals, "data_model_ids": dm_ids}


def score_workbook(
    signature: dict,
    candidate: dict,
    spec: dict,
    selected_data_model_id: str,
) -> dict:
    actual = workbook_signature(spec)
    required_pages = {
        normalize_name(value): value for value in signature.get("dashboard_names") or []
    }
    required_visuals = Counter(signature.get("visuals") or [])
    actual_visuals = Counter(actual["visuals"])
    shared_pages = set(required_pages) & set(actual["pages"])
    shared_visuals = required_visuals & actual_visuals
    page_match = len(shared_pages) / len(required_pages) if required_pages else 0.0
    visual_match = (
        sum(shared_visuals.values()) / sum(required_visuals.values())
        if required_visuals
        else 0.0
    )
    dm_match = selected_data_model_id in actual["data_model_ids"]
    source_names = {
        normalize_name(signature.get("tableau_workbook")),
        *(normalize_name(value) for value in signature.get("dashboard_names") or []),
    }
    source_names.discard("")
    name_match = normalize_name(candidate.get("name") or spec.get("name")) in source_names
    score = (
        0.4 * float(dm_match)
        + 0.25 * page_match
        + 0.25 * visual_match
        + 0.1 * float(name_match)
    )
    compatible = bool(required_pages and required_visuals) and (
        dm_match and page_match == 1.0 and visual_match == 1.0
    )
    exact = compatible and name_match and (
        set(actual["pages"]) == set(required_pages)
        and actual_visuals == required_visuals
    )
    candidate_id = candidate.get("workbookId") or candidate.get("id")
    return {
        "id": candidate_id,
        "name": candidate.get("name") or spec.get("name"),
        "score": round(score, 3),
        "match": "exact" if exact else ("compatible" if compatible else "partial"),
        "high_confidence": compatible,
        "data_model_match": dm_match,
        "page_match": round(page_match, 3),
        "visual_match": round(visual_match, 3),
        "name_match": name_match,
        "missing_pages": sorted(
            required_pages[key] for key in set(required_pages) - set(actual["pages"])
        ),
        "missing_visuals": sorted((required_visuals - actual_visuals).elements()),
        "referenced_data_model_ids": sorted(actual["data_model_ids"]),
    }


def list_objects(
    endpoint: str,
    collection_keys: tuple[str, ...],
    *,
    api=sigma_rest,
    max_candidates: int = DEFAULT_MAX_CANDIDATES,
) -> tuple[list[dict], dict]:
    rows: list[dict] = []
    page = None
    truncated = False
    while True:
        query = {"limit": 100}
        if page:
            query["page"] = page
        payload = api.request("get", f"{endpoint}?{urllib.parse.urlencode(query)}") or {}
        batch = next(
            (
                payload.get(key)
                for key in collection_keys
                if isinstance(payload, dict) and isinstance(payload.get(key), list)
            ),
            [],
        )
        rows.extend(item for item in batch if isinstance(item, dict))
        if len(rows) >= max_candidates:
            truncated = len(rows) > max_candidates or bool(payload.get("nextPage"))
            rows = rows[:max_candidates]
            break
        page = payload.get("nextPage") if isinstance(payload, dict) else None
        if not page:
            break
    return rows, {
        "listed": len(rows),
        "max_candidates": max_candidates,
        "truncated": truncated,
    }


def _selection(
    candidates: list[dict],
    pool: dict,
    *,
    explicit_id: str | None,
    min_score: float,
) -> tuple[dict | None, str]:
    eligible = [
        item
        for item in candidates
        if item.get("high_confidence") and item.get("score", 0) >= min_score
    ]
    if pool.get("truncated") or pool.get("spec_failures"):
        return None, "incomplete candidate pool; uniqueness cannot be proven"
    if explicit_id:
        if len(eligible) == 1 and eligible[0]["id"] == explicit_id:
            return eligible[0], "explicit ID read back and compatibility verified"
        return None, "explicit ID is unreadable or not fully compatible"
    if len(eligible) == 1:
        return eligible[0], "unique high-confidence compatible match"
    if not eligible:
        return None, "no high-confidence compatible match"
    return None, f"{len(eligible)} high-confidence matches; refusing to break the tie"


def discover_kind(
    kind: str,
    signature: dict,
    *,
    selected_data_model_id: str | None = None,
    explicit_id: str | None = None,
    min_score: float = 0.9,
    max_candidates: int = DEFAULT_MAX_CANDIDATES,
    api=sigma_rest,
) -> dict:
    if kind == "data_model":
        endpoint = "/v2/dataModels"
        list_keys = ("entries", "dataModels")
        id_keys = ("dataModelId", "id")
    elif kind == "workbook":
        if not selected_data_model_id:
            raise DiscoveryError(
                "workbook discovery requires a selected or explicit data model ID"
            )
        endpoint = "/v2/workbooks"
        list_keys = ("entries", "workbooks")
        id_keys = ("workbookId", "id")
    else:
        raise DiscoveryError(f"unsupported discovery kind: {kind}")

    if explicit_id:
        listed = [{id_keys[0]: explicit_id, "name": explicit_id}]
        pool = {
            "listed": 1,
            "max_candidates": max_candidates,
            "truncated": False,
            "explicit": True,
        }
    else:
        listed, pool = list_objects(
            endpoint, list_keys, api=api, max_candidates=max_candidates
        )
        archived = [item for item in listed if item.get("isArchived")]
        listed = [item for item in listed if not item.get("isArchived")]
        pool["excluded_archived"] = len(archived)
        pool["explicit"] = False

    candidates: list[dict] = []
    failures: list[dict] = []
    for item in listed:
        object_id = next((item.get(key) for key in id_keys if item.get(key)), None)
        if not object_id:
            failures.append({"id": None, "error": "list entry has no object ID"})
            continue
        try:
            spec = api.request("get", f"{endpoint}/{object_id}/spec")
            if not isinstance(spec, dict):
                raise DiscoveryError("spec endpoint returned no JSON object")
            if kind == "data_model":
                scored = score_data_model(signature, item, spec)
            else:
                scored = score_workbook(
                    signature, item, spec, selected_data_model_id
                )
            candidates.append(scored)
        except Exception as exc:  # API wrapper errors vary; preserve every failure.
            failures.append({"id": object_id, "name": item.get("name"), "error": str(exc)})

    pool["scored"] = len(candidates)
    pool["spec_failures"] = failures
    candidates.sort(
        key=lambda item: (
            -float(item.get("score") or 0),
            0 if item.get("match") == "exact" else 1,
            str(item.get("name") or ""),
            str(item.get("id") or ""),
        )
    )
    selected, rationale = _selection(
        candidates,
        pool,
        explicit_id=explicit_id,
        min_score=min_score,
    )
    return {
        "status": "selected" if selected else "no_selection",
        "selected_id": selected["id"] if selected else None,
        "selection": selected,
        "rationale": rationale,
        "minimum_score": min_score,
        "pool": pool,
        "candidates": candidates,
    }


def discover(
    signature: dict,
    *,
    mode: str = "both",
    data_model_id: str | None = None,
    workbook_id: str | None = None,
    min_score: float = 0.9,
    max_candidates: int = DEFAULT_MAX_CANDIDATES,
    api=sigma_rest,
) -> dict:
    result = {
        "contract_version": 1,
        "read_only": True,
        "signature": signature,
    }
    requested: list[str] = []
    selected_dm = data_model_id
    if mode in {"data-model", "both"}:
        requested.append("data_model")
        result["data_model"] = discover_kind(
            "data_model",
            signature,
            explicit_id=data_model_id,
            min_score=min_score,
            max_candidates=max_candidates,
            api=api,
        )
        selected_dm = result["data_model"]["selected_id"]
    if mode in {"workbook", "both"}:
        requested.append("workbook")
        if not selected_dm:
            result["workbook"] = {
                "status": "no_selection",
                "selected_id": None,
                "selection": None,
                "rationale": "data model selection is unresolved; workbook scan not run",
                "minimum_score": min_score,
                "pool": {"listed": 0, "scored": 0, "truncated": False},
                "candidates": [],
            }
        else:
            result["workbook"] = discover_kind(
                "workbook",
                signature,
                selected_data_model_id=selected_dm,
                explicit_id=workbook_id,
                min_score=min_score,
                max_candidates=max_candidates,
                api=api,
            )
    result["status"] = (
        "selected"
        if all(result[kind]["status"] == "selected" for kind in requested)
        else "no_selection"
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--dm-spec", help="default: <workdir>/dm-raw.json")
    parser.add_argument("--layout", help="default: <workdir>/dashboard-layout.json")
    parser.add_argument(
        "--layout-meta", help="default: <workdir>/dashboard-layout-meta.json"
    )
    parser.add_argument(
        "--signature-out",
        help="default: <workdir>/workbook-signature-python.json",
    )
    parser.add_argument("--out", help="default: <workdir>/reuse-discovery.json")
    parser.add_argument(
        "--mode",
        choices=("data-model", "workbook", "both"),
        default="both",
    )
    parser.add_argument("--data-model-id")
    parser.add_argument("--workbook-id")
    parser.add_argument("--min-score", type=float, default=0.9)
    parser.add_argument(
        "--max-candidates", type=int, default=DEFAULT_MAX_CANDIDATES
    )
    args = parser.parse_args()
    workdir = Path(args.workdir).expanduser().resolve()
    output = Path(args.out).expanduser().resolve() if args.out else (
        workdir / "reuse-discovery.json"
    )
    try:
        if not 0 <= args.min_score <= 1:
            raise DiscoveryError("--min-score must be between 0 and 1")
        if args.max_candidates < 1:
            raise DiscoveryError("--max-candidates must be positive")
        model = load_object(
            Path(args.dm_spec).expanduser().resolve()
            if args.dm_spec
            else workdir / "dm-raw.json"
        )
        layout = load_array(
            Path(args.layout).expanduser().resolve()
            if args.layout
            else workdir / "dashboard-layout.json"
        )
        layout_meta_path = (
            Path(args.layout_meta).expanduser().resolve()
            if args.layout_meta
            else workdir / "dashboard-layout-meta.json"
        )
        layout_meta = load_object(layout_meta_path) if layout_meta_path.is_file() else {}
        signature = derive_signature(model, layout, layout_meta)
        signature_output = (
            Path(args.signature_out).expanduser().resolve()
            if args.signature_out
            else workdir / "workbook-signature-python.json"
        )
        write_json(signature_output, signature)
        result = discover(
            signature,
            mode=args.mode,
            data_model_id=args.data_model_id,
            workbook_id=args.workbook_id,
            min_score=args.min_score,
            max_candidates=args.max_candidates,
        )
    except (OSError, ValueError, json.JSONDecodeError, sigma_rest.SigmaError) as exc:
        result = {
            "contract_version": 1,
            "read_only": True,
            "status": "error",
            "error": str(exc),
        }
        write_json(output, result)
        print(f"FATAL: {exc}; wrote {output}", file=sys.stderr)
        return 1
    write_json(output, result)
    if result["status"] == "selected":
        print(f"PASS: unique reusable target(s) selected; wrote {output}")
        return 0
    print(f"STOP: no unique reusable target; review candidates in {output}")
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
