#!/usr/bin/env python3
"""Score existing Sigma data models for safe reuse without mutating them."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from lib import sigma_rest

RANKING_VERSION = 2
CACHE_MAX_AGE = 24 * 3600
STOP_TOKENS = {
    "DM", "DATA", "MODEL", "FROM", "THE", "AND", "FOR", "TEST", "TMP", "TEMP",
    "COPY", "OF", "V1", "V2", "NEW", "OLD", "FACT", "DIM", "TABLE", "VIEW",
    "PROD", "DEV", "RAW", "STG", "PUBLIC",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def signature_sha(signature: dict[str, Any]) -> str:
    canonical = {
        "tables": sorted(str(value) for value in signature.get("warehouse_tables") or []),
        "columns": sorted(str(value) for value in signature.get("referenced_columns") or []),
        "measures": sorted(
            f"{row.get('col')}/{row.get('derivation')}"
            for row in signature.get("measures") or []
        ),
    }
    return hashlib.sha256(
        json.dumps(canonical, separators=(",", ":"), sort_keys=True).encode()
    ).hexdigest()


def normalize_fqn(value: Any) -> str | None:
    if value is None or not str(value):
        return None
    return ".".join(part.upper() for part in str(value).split(".") if part)


def normalize_column(value: Any) -> str:
    return re.sub(r"[^A-Z0-9]", "", str(value or "").upper())


def fqn_covers(dm_fqn: str | None, source_fqn: str | None) -> bool:
    if not dm_fqn or not source_fqn:
        return False
    if dm_fqn == "CUSTOM_SQL" or source_fqn == "CUSTOM_SQL":
        return dm_fqn == source_fqn
    left, right = dm_fqn.split("."), source_fqn.split(".")
    count = min(len(left), len(right))
    return left[-count:] == right[-count:]


def name_tokens(value: Any) -> set[str]:
    return {
        token
        for token in re.split(r"[^A-Z0-9]+", str(value or "").upper())
        if len(token) >= 3 and token not in STOP_TOKENS
    }


def signature_tokens(signature: dict[str, Any]) -> set[str]:
    result = set()
    for fqn in signature.get("warehouse_tables") or []:
        result |= name_tokens(str(fqn).split(".")[-1])
    result |= name_tokens(
        signature.get("tableau_workbook")
        or signature.get("workbook")
        or signature.get("app")
        or ""
    )
    return result


def affinity(name: Any, tokens: set[str]) -> float:
    candidate = name_tokens(name)
    return len(candidate & tokens) / len(tokens) if tokens and candidate else 0.0


def _timestamp(value: Any) -> float:
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return 0.0


def extract_dm_signature(
    dm: dict[str, Any], spec: dict[str, Any]
) -> dict[str, Any]:
    tables, columns, metrics = [], [], []
    captions: dict[str, str] = {}
    elements = spec.get("elements") or [
        element
        for page in spec.get("pages") or []
        if isinstance(page, dict)
        for element in page.get("elements") or []
        if isinstance(element, dict)
    ]
    for element in elements:
        source = element.get("source") or {}
        if source.get("kind") in {"warehouse-table", "table"}:
            raw = source.get("path")
            if isinstance(raw, list):
                raw = ".".join(str(part) for part in raw)
            raw = raw or ".".join(
                str(source[key])
                for key in ("database", "schema", "name")
                if source.get(key)
            )
            normalized = normalize_fqn(raw)
            if normalized:
                tables.append(normalized)
        elif source.get("kind") == "sql":
            tables.append("CUSTOM_SQL")
        for column in element.get("columns") or []:
            name = column.get("name")
            if not name:
                match = re.search(r"\[.*?([^/\]]+)\]", str(column.get("formula") or ""))
                name = match.group(1) if match else None
            if name:
                normalized = normalize_column(name)
                columns.append(normalized)
                captions.setdefault(normalized, str(name))
        for metric in element.get("metrics") or []:
            metrics.append(
                f"{metric.get('name')}/"
                f"{metric.get('aggregation') or metric.get('derivation')}"
            )
    return {
        "dm_id": dm.get("dataModelId") or dm.get("id"),
        "dm_name": dm.get("name"),
        "tables": list(dict.fromkeys(tables)),
        "columns": list(dict.fromkeys(columns)),
        "column_captions": captions,
        "metrics": list(dict.fromkeys(metrics)),
        "raw_element_count": len(elements),
    }


def score_candidates(
    signature: dict[str, Any], dm_signatures: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    source_tables = [
        value
        for value in (
            normalize_fqn(item) for item in signature.get("warehouse_tables") or []
        )
        if value
    ]
    original_columns = [str(value) for value in signature.get("referenced_columns") or []]
    source_columns = [normalize_column(value) for value in original_columns]
    source_captions = dict(zip(source_columns, original_columns))
    source_metrics = [
        f"{normalize_column(row.get('col'))}/{row.get('derivation')}"
        for row in signature.get("measures") or []
    ]
    candidates = []
    for dm in dm_signatures:
        shared_tables = [
            source
            for source in source_tables
            if any(fqn_covers(candidate, source) for candidate in dm["tables"])
        ]
        if not source_tables:
            table_match = 0.0
        elif len(shared_tables) == len(source_tables):
            table_match = 1.0
        elif shared_tables:
            table_match = 0.5 + 0.5 * len(shared_tables) / len(source_tables)
        else:
            table_match = 0.0
        shared_columns = [item for item in source_columns if item in dm["columns"]]
        column_match = (
            len(set(shared_columns)) / len(set(source_columns))
            if source_columns
            else 0.0
        )
        shared_metrics = [item for item in source_metrics if item in dm["metrics"]]
        metric_match = (
            len(set(shared_metrics)) / len(set(source_metrics))
            if source_metrics
            else 0.0
        )
        extras = [item for item in dm["columns"] if item not in source_columns]
        caption = lambda item: dm["column_captions"].get(item, item)
        candidates.append(
            {
                "dm_id": dm["dm_id"],
                "dm_name": dm["dm_name"],
                "score": round(
                    0.2 * table_match + 0.7 * column_match + 0.1 * metric_match,
                    3,
                ),
                "table_match": round(table_match, 2),
                "column_match": round(column_match, 2),
                "metric_match": round(metric_match, 2),
                "shared_tables": shared_tables,
                "missing_tables": [
                    item for item in source_tables if item not in shared_tables
                ],
                "shared_columns": list(
                    dict.fromkeys(caption(item) for item in shared_columns)
                ),
                "missing_columns": [
                    source_captions.get(item, item)
                    for item in source_columns
                    if item not in dm["columns"]
                ],
                "extra_columns": len(extras),
                "extra_columns_sample": [caption(item) for item in extras[:5]],
                "raw_element_count": dm["raw_element_count"],
            }
        )
    source_name = normalize_column(
        signature.get("tableau_workbook")
        or signature.get("workbook")
        or signature.get("app")
        or ""
    )
    return sorted(
        candidates,
        key=lambda row: (
            -row["score"],
            0 if source_name and normalize_column(row["dm_name"]) == source_name else 1,
            row["extra_columns"],
            str(row["dm_name"]),
        ),
    )


def decide(
    signature: dict[str, Any],
    candidates: list[dict[str, Any]],
    *,
    min_score: float,
    auto_pick: bool,
    auto_pick_threshold: float,
    tie_window: float,
    pool_total: int,
    pool_fetched: int,
) -> dict[str, Any]:
    best = candidates[0] if candidates else None
    second = candidates[1] if len(candidates) > 1 else None
    source_name = normalize_column(
        signature.get("tableau_workbook")
        or signature.get("workbook")
        or signature.get("app")
        or ""
    )
    tie_count = (
        sum(best["score"] - row["score"] < tie_window for row in candidates)
        if best
        else 0
    )
    covers = bool(best and best["table_match"] >= 1.0)
    superset = bool(covers and best["column_match"] >= 1.0)
    name_matches = bool(
        best and source_name and normalize_column(best["dm_name"]) == source_name
    )
    ambiguous = bool(
        best
        and best["score"] >= min_score
        and tie_count >= 3
        and not name_matches
        and not superset
    )
    auto_picked = bool(
        auto_pick
        and best
        and best["score"] >= auto_pick_threshold
        and superset
        and not ambiguous
    )
    recommended = (
        best["dm_id"]
        if best and (auto_picked or (best["score"] >= min_score and not ambiguous))
        else None
    )
    if not best:
        rationale = "no DMs in org"
    elif auto_picked:
        tie = (
            f" (collapsing a {best['score']}-score tie — duplicate-DM sprawl)"
            if second and best["score"] - second["score"] < tie_window
            else ""
        )
        rationale = (
            f"AUTO-PICKED at score {best['score']} — column-superset{tie}. "
            f"{len(best['shared_columns'])}/{len(signature.get('referenced_columns') or [])} "
            f"cols, {len(best['shared_tables'])}/"
            f"{len(signature.get('warehouse_tables') or [])} tables matched."
        )
    elif ambiguous:
        rationale = (
            f"AMBIGUOUS: {tie_count} near-identical DMs tie at ~{best['score']}; "
            "not auto-reusing a look-alike"
        )
    elif best["score"] >= min_score:
        rationale = "ambiguous match — ASK USER before reusing"
    else:
        rationale = (
            f"no candidate above min-score across the {pool_fetched} DM(s) scored; "
            "build a new DM"
        )
    if recommended is None and pool_fetched < pool_total:
        rationale += (
            f" [scanned {pool_fetched} of {pool_total}; "
            f"{pool_total - pool_fetched} NOT scored]"
        )
    return {
        "recommended_dm_id": recommended,
        "auto_picked": auto_picked,
        "ambiguous_wide_tie": ambiguous,
        "tie_count": tie_count,
        "score": best["score"] if best else 0.0,
        "rationale": rationale,
        "warning": (
            f"Reusing inherits {best['extra_columns']} extra columns "
            f"(sample: {', '.join(best['extra_columns_sample'])})"
            if best and best["extra_columns"]
            else None
        ),
        "candidates": candidates[:5],
    }


def _parse_spec(value: Any) -> dict[str, Any] | None:
    if isinstance(value, dict):
        return value
    if not isinstance(value, str):
        return None
    try:
        parsed = json.loads(value)
        return parsed if isinstance(parsed, dict) else None
    except json.JSONDecodeError:
        return None


def scan(
    signature: dict[str, Any],
    *,
    cache: dict[str, Any] | None,
    limit: int,
    max_fetch: int,
    min_score: float,
    auto_pick: bool,
    auto_pick_threshold: float,
    tie_window: float,
) -> dict[str, Any]:
    if cache:
        all_dms = [row for row in cache.get("dms") or [] if isinstance(row, dict)]
        cached_specs = cache.get("specs") or {}
    else:
        all_dms = []
        page = None
        while len(all_dms) < 500:
            path = "/v2/dataModels?limit=100" + (
                f"&page={page}" if page else ""
            )
            response = sigma_rest.request("get", path) or {}
            rows = response.get("entries") or response.get("dataModels") or []
            if not rows:
                break
            all_dms.extend(row for row in rows if isinstance(row, dict))
            page = response.get("nextPage")
            if not page:
                break
        cached_specs = {}
    tokens = signature_tokens(signature)
    all_dms.sort(
        key=lambda row: (
            -affinity(row.get("name"), tokens),
            -_timestamp(row.get("updatedAt")),
            str(row.get("name") or ""),
        )
    )
    affine = sum(affinity(row.get("name"), tokens) > 0 for row in all_dms)
    fetch_count = min(max(limit, affine), max_fetch, len(all_dms))
    selected = all_dms[:fetch_count]
    specs: dict[str, dict[str, Any]] = {}
    missing = []
    for dm in selected:
        dm_id = str(dm.get("dataModelId") or dm.get("id") or "")
        parsed = _parse_spec(cached_specs.get(dm_id))
        if parsed:
            specs[dm_id] = parsed
        elif dm_id:
            missing.append((dm_id, dm))

    def fetch(dm_id: str) -> tuple[str, Any]:
        for attempt in range(4):
            try:
                return dm_id, sigma_rest.request(
                    "get", f"/v2/dataModels/{dm_id}/spec"
                )
            except sigma_rest.SigmaError as exc:
                transient = any(
                    marker in str(exc)
                    for marker in ("-> 429 ", "-> 500 ", "-> 502 ", "-> 503 ", "-> 504 ")
                )
                if not transient or attempt == 3:
                    raise
                time.sleep(0.5 * (2**attempt))
        raise AssertionError("unreachable")

    if missing:
        with ThreadPoolExecutor(max_workers=min(5, len(missing))) as executor:
            futures = {executor.submit(fetch, dm_id): dm_id for dm_id, _ in missing}
            for future in as_completed(futures):
                try:
                    dm_id, value = future.result()
                    parsed = _parse_spec(value)
                    if parsed:
                        specs[dm_id] = parsed
                except (
                    sigma_rest.SigmaError,
                    json.JSONDecodeError,
                    TypeError,
                    ValueError,
                ):
                    continue
    dm_signatures = [
        extract_dm_signature(dm, specs[dm_id])
        for dm in selected
        if (dm_id := str(dm.get("dataModelId") or dm.get("id") or "")) in specs
    ]
    candidates = score_candidates(signature, dm_signatures)
    result = decide(
        signature,
        candidates,
        min_score=min_score,
        auto_pick=auto_pick,
        auto_pick_threshold=auto_pick_threshold,
        tie_window=tie_window,
        pool_total=len(all_dms),
        pool_fetched=fetch_count,
    )
    result.update(
        {
            "ranking_version": RANKING_VERSION,
            "scanned_at": utc_now(),
            "scanned_dm_count": len(candidates),
            "candidate_pool": {
                "total_in_org": len(all_dms),
                "scored": fetch_count,
                "truncated": fetch_count < len(all_dms),
                "ranked_by": (
                    "name-affinity to signature tables, then updatedAt desc, "
                    "then name asc"
                ),
            },
        }
    )
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workbook-signature", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--limit", type=int, default=25)
    parser.add_argument("--max-fetch", type=int, default=120)
    parser.add_argument("--min-score", type=float, default=0.6)
    parser.add_argument("--force-new", action="store_true")
    parser.add_argument("--auto-pick", action="store_true")
    parser.add_argument("--auto-pick-threshold", type=float, default=0.55)
    parser.add_argument("--auto-pick-tie-window", type=float, default=0.05)
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--specs-cache")
    args = parser.parse_args(argv)
    signature = json.loads(
        Path(args.workbook_signature).read_text(encoding="utf-8-sig")
    )
    output = Path(args.out)
    digest = signature_sha(signature)
    if output.is_file() and not args.refresh and not args.force_new:
        try:
            previous = json.loads(output.read_text(encoding="utf-8-sig"))
            scanned = datetime.fromisoformat(
                str(previous.get("scanned_at")).replace("Z", "+00:00")
            )
            age = datetime.now(timezone.utc).timestamp() - scanned.timestamp()
            if (
                previous.get("signature_sha256") == digest
                and previous.get("ranking_version") == RANKING_VERSION
                and age < CACHE_MAX_AGE
            ):
                print(f"dm-match REUSED (signature unchanged; {previous['scanned_at']})")
                return 0 if previous.get("recommended_dm_id") else 1
        except (ValueError, json.JSONDecodeError):
            pass
    if args.force_new:
        result = {
            "recommended_dm_id": None,
            "score": 0.0,
            "rationale": "--force-new: bypassed DM-reuse scan",
            "candidates": [],
        }
    else:
        cache = None
        if args.specs_cache and Path(args.specs_cache).is_file():
            cache = json.loads(Path(args.specs_cache).read_text(encoding="utf-8-sig"))
        result = scan(
            signature,
            cache=cache,
            limit=args.limit,
            max_fetch=args.max_fetch,
            min_score=args.min_score,
            auto_pick=args.auto_pick,
            auto_pick_threshold=args.auto_pick_threshold,
            tie_window=args.auto_pick_tie_window,
        )
    result["workbook_signature_path"] = args.workbook_signature
    result["signature_sha256"] = digest
    output.write_text(
        json.dumps({key: value for key, value in result.items() if value is not None}, indent=2)
        + "\n",
        encoding="utf-8",
    )
    print(f"best score: {result.get('score', 0)} -> {result.get('rationale')}")
    return 0 if result.get("recommended_dm_id") else 1


if __name__ == "__main__":
    raise SystemExit(main())
