#!/usr/bin/env python3
"""Read-only Spotfire estate assessment.

Offline inputs:
  --from-fixtures DIR   Select manifest.json, library-items.json, or inventory.json
  --manifest FILE       Full exported analysis manifest
  --inventory FILE      Normalized raw-DXP inventory or Library API item response

Live mode (no input flag) uses only Library REST API v2 GETs. OAuth token
minting may POST to the token endpoint, but no Spotfire content is written.
The live transport is intentionally marked LIVE-UNVALIDATED.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import importlib.util
import json
import math
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


SKILL_DIR = Path(__file__).resolve().parent.parent
CATALOG_PATH = (
    SKILL_DIR.parent
    / "spotfire-to-sigma"
    / "refs"
    / "catalogs"
    / "coverage-catalog.json"
)
CATEGORIES = ("visuals", "formulas", "security", "scripts", "data_functions", "mods")
TIER_ORDER = ("auto", "hint", "manual", "unhandled")
TAG_PRIORITY = {
    "migrate-first": 0,
    "easy-win": 1,
    "moderate": 2,
    "needs-gap-scout": 3,
    "retire": 4,
}
LIBRARY_TYPES = {
    "analysis": "spotfire.dxp",
    "folder": "spotfire.folder",
    "data_function": "spotfire.datafunction",
    "script": "spotfire.dxpscript",
    "mod": "spotfire.visualizationmod",
    "data_connection": "spotfire.dataconnection",
    "information_link": "spotfire.query",
}


def read_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError as exc:
        raise SystemExit(f"input not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON in {path}: {exc}") from exc


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def load_catalog(path: Path = CATALOG_PATH) -> dict[str, Any]:
    catalog = read_json(path)
    missing = [category for category in CATEGORIES if category not in catalog.get("categories", {})]
    if missing:
        raise SystemExit(f"coverage catalog missing categories: {', '.join(missing)}")
    return catalog


def token(value: Any) -> str:
    """Normalize names without guessing across semantically distinct features."""
    return re.sub(r"[^a-z0-9]+", "_", str(value or "").strip().lower()).strip("_")


def first_present(mapping: dict[str, Any], *names: str, default: Any = None) -> Any:
    for name in names:
        if name in mapping and mapping[name] is not None:
            return mapping[name]
    return default


def as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def display_principal(value: Any) -> str | None:
    if not isinstance(value, dict):
        return str(value) if value else None
    return first_present(value, "displayName", "name", "userName", "id")


def normalize_feature(value: Any, category: str, index: int) -> dict[str, Any]:
    if isinstance(value, str):
        if category == "formulas":
            return {"name": f"formula-{index + 1}", "expression": value}
        return {"type": value}
    if not isinstance(value, dict):
        return {"type": str(value)}
    return dict(value)


def flatten_features(analysis: dict[str, Any], category: str) -> list[dict[str, Any]]:
    values = list(as_list(analysis.get(category)))
    if category == "scripts":
        values += as_list(analysis.get("custom_scripts"))
    if category == "mods":
        values += as_list(analysis.get("visualization_mods"))
    if category == "formulas":
        values += as_list(analysis.get("calculated_columns"))
    for page in as_list(analysis.get("pages")):
        if isinstance(page, dict):
            values += as_list(page.get(category))
    return [normalize_feature(value, category, index) for index, value in enumerate(values)]


def normalize_analysis(
    analysis: dict[str, Any], index: int, capability_tier: str
) -> dict[str, Any]:
    aid = str(first_present(analysis, "id", "analysis_id", "document_id", default=f"analysis-{index + 1}"))
    title = str(first_present(analysis, "title", "name", default=aid))
    pages = [dict(page) for page in as_list(analysis.get("pages")) if isinstance(page, dict)]
    features = {category: flatten_features(analysis, category) for category in CATEGORIES}

    evidence = analysis.get("evidence") if isinstance(analysis.get("evidence"), dict) else {}
    available = evidence.get("available_categories")
    if available is None:
        available = [category for category in CATEGORIES if category in analysis]
        if pages:
            for category in CATEGORIES:
                if any(category in page for page in pages):
                    available.append(category)
        if capability_tier == "full-exported-manifest":
            available = list(CATEGORIES)
    available = sorted({category for category in available if category in CATEGORIES})

    source_values = first_present(
        analysis, "source_ids", "sources", "data_sources", "dataSources", default=[]
    )
    sources = []
    for source in as_list(source_values):
        if isinstance(source, dict):
            source = first_present(source, "id", "name", "table", "connection")
        if source is not None:
            sources.append(str(source))

    fields = {str(field) for field in as_list(analysis.get("fields")) if field is not None}
    for visual in features["visuals"]:
        fields.update(str(field) for field in as_list(visual.get("fields")) if field is not None)

    usage = analysis.get("usage") if isinstance(analysis.get("usage"), dict) else {}
    normalized_usage = {
        key: usage[key]
        for key in ("views", "distinct_viewers", "last_accessed", "favorite_count")
        if key in usage and usage[key] is not None
    }
    return {
        "id": aid,
        "title": title,
        "path": first_present(analysis, "path", "library_path", "folder"),
        "owner": display_principal(first_present(analysis, "owner", "createdBy", "created_by")),
        "created": first_present(analysis, "created", "created_at"),
        "modified": first_present(analysis, "modified", "modified_at", "last_modified"),
        "pages": pages,
        "source_ids": sorted(set(sources)),
        "fields": sorted(fields),
        **features,
        "usage": normalized_usage,
        "evidence": {
            "available_categories": available,
            "missing_categories": [category for category in CATEGORIES if category not in available],
        },
    }


def library_items_from(data: Any) -> list[dict[str, Any]] | None:
    if isinstance(data, list) and all(isinstance(item, dict) for item in data):
        return data
    if not isinstance(data, dict):
        return None
    for key in ("items", "library_items", "libraryItems"):
        value = data.get(key)
        if isinstance(value, list):
            return [item for item in value if isinstance(item, dict)]
    return None


def normalize_library(
    data: Any, instance: dict[str, Any], source_mode: str
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    items = library_items_from(data)
    if items is None:
        raise SystemExit("Library metadata input must be an array or an object with items[]")

    analyses = []
    usage_by_analysis: dict[str, Any] = {}
    type_counts = Counter(str(item.get("type") or "unknown") for item in items)
    for index, item in enumerate(items):
        if item.get("type") != LIBRARY_TYPES["analysis"]:
            continue
        permissions = as_list(item.get("permissions"))
        security = []
        if permissions:
            security.append(
                {
                    "type": "library_acl",
                    "entry_count": len(permissions),
                    "explicit_entry_count": sum(
                        1
                        for entry in permissions
                        if isinstance(entry, dict) and not entry.get("inheritedFromId")
                    ),
                }
            )
        usage = {
            "last_accessed": item.get("accessed"),
            "favorite_count": item.get("favoriteCount"),
        }
        usage = {key: value for key, value in usage.items() if value is not None}
        analysis = normalize_analysis(
            {
                "id": item.get("id") or f"library-analysis-{index + 1}",
                "title": item.get("title"),
                "path": item.get("path"),
                "createdBy": item.get("createdBy"),
                "created": item.get("created"),
                "modified": item.get("modified"),
                "security": security,
                "usage": usage,
                "evidence": {
                    "available_categories": ["security"] if "permissions" in item else [],
                },
            },
            index,
            "library-metadata-only",
        )
        analyses.append(analysis)
        if usage:
            usage_by_analysis[analysis["id"]] = usage

    gaps = [
        "Library REST API v2 exposes item metadata, not analysis internals; "
        "visuals, formulas, custom scripts, data functions, and analysis-linked mods are unknown."
    ]
    if not any(item.get("permissions") is not None for item in items):
        gaps.append("Library ACLs were not returned; security complexity is unknown.")
    inventory = {
        "schema_version": "spotfire-assessment-inventory-v1",
        "instance": instance,
        "source_mode": source_mode,
        "capability_tier": "library-metadata-only",
        "analyses": analyses,
        "data_sources": [],
        "users": [],
        "library": {
            "item_count": len(items),
            "item_type_counts": dict(sorted(type_counts.items())),
        },
        "evidence_gaps": gaps,
        "warnings": [],
    }
    usage_doc = None
    if usage_by_analysis:
        usage_doc = {
            "schema_version": "spotfire-assessment-usage-v1",
            "evidence_kind": "library-metadata-signals",
            "quantitative_views": False,
            "by_analysis": usage_by_analysis,
        }
    return inventory, usage_doc


def is_authoritative_manifest(data: Any) -> bool:
    return (
        isinstance(data, dict)
        and data.get("manifest_type") == "spotfire_neutral_manifest"
        and data.get("manifest_version") == "1.0"
        and isinstance(data.get("model"), dict)
        and isinstance(data.get("presentation"), dict)
        and isinstance(data.get("automation"), dict)
        and isinstance(data.get("security"), dict)
    )


def validate_authoritative_manifest(data: dict[str, Any]) -> list[str]:
    validator_path = (
        SKILL_DIR.parent
        / "spotfire-to-sigma"
        / "scripts"
        / "validate_manifest.py"
    )
    spec = importlib.util.spec_from_file_location(
        "spotfire_assessment_manifest_validator", validator_path
    )
    if not spec or not spec.loader:
        raise SystemExit(
            "could not load the sibling Spotfire manifest validator"
        )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    errors, warnings = module.validate_manifest(data)
    if errors:
        raise SystemExit(
            "authoritative Spotfire manifest validation failed:\n  - "
            + "\n  - ".join(errors)
        )
    return warnings


def canonical_manifest_analysis(data: dict[str, Any]) -> dict[str, Any]:
    """Project one converter-grade manifest into one assessment analysis."""
    source = data.get("source") if isinstance(data.get("source"), dict) else {}
    model = data.get("model") if isinstance(data.get("model"), dict) else {}
    presentation = (
        data.get("presentation")
        if isinstance(data.get("presentation"), dict)
        else {}
    )
    automation = (
        data.get("automation")
        if isinstance(data.get("automation"), dict)
        else {}
    )
    security = (
        data.get("security") if isinstance(data.get("security"), dict) else {}
    )

    tables = [
        table
        for table in as_list(model.get("tables"))
        if isinstance(table, dict)
    ]
    pages = []
    fields = set()
    formulas = []
    for page in as_list(presentation.get("pages")):
        if not isinstance(page, dict):
            continue
        normalized_page = dict(page)
        visuals = []
        for visual in as_list(page.get("visuals")):
            if not isinstance(visual, dict):
                continue
            normalized_visual = dict(visual)
            normalized_visual.setdefault(
                "type",
                first_present(visual, "visual_type", "visualType", "name"),
            )
            for axis in as_list(visual.get("axes")):
                if isinstance(axis, dict):
                    fields.update(
                        str(value)
                        for value in as_list(axis.get("columns"))
                        if value is not None
                    )
                    expression = axis.get("expression")
                    if isinstance(expression, str) and expression.strip():
                        formulas.append({
                            "name": str(first_present(
                                axis, "name", "axis_type", "source_id",
                                default="visual-formula-%d" %
                                (len(formulas) + 1),
                            )),
                            "expression": expression,
                        })
            visuals.append(normalized_visual)
        normalized_page["visuals"] = visuals
        pages.append(normalized_page)

    source_ids = []
    for table in tables:
        source_id = first_present(table, "source_id", "id", "name")
        if source_id is not None:
            source_ids.append(str(source_id))
        for column in as_list(table.get("columns")):
            if not isinstance(column, dict):
                continue
            name = first_present(column, "name", "source_id")
            if name is not None:
                fields.add(str(name))
            expression = column.get("expression")
            if isinstance(expression, str) and expression.strip():
                formulas.append(
                    {
                        "name": str(name or f"formula-{len(formulas) + 1}"),
                        "expression": expression,
                    }
                )

    security_features = []
    for signal in as_list(security.get("signals")):
        if isinstance(signal, dict):
            feature = dict(signal)
            feature.setdefault("type", signal.get("kind"))
            security_features.append(feature)

    mods = []
    for mod in as_list(automation.get("mods")):
        if isinstance(mod, dict):
            feature = dict(mod)
            feature.setdefault("type", "spotfire_mod")
            mods.append(feature)

    return {
        "id": str(
            first_present(
                source,
                "document_id",
                "source_id",
                default="analysis-1",
            )
        ),
        "title": str(first_present(source, "name", default="Spotfire analysis")),
        "pages": pages,
        "source_ids": source_ids,
        "fields": sorted(fields),
        "formulas": formulas,
        "security": security_features,
        "scripts": [
            dict(value)
            for value in as_list(automation.get("scripts"))
            if isinstance(value, dict)
        ],
        "data_functions": [
            dict(value)
            for value in as_list(automation.get("data_functions"))
            if isinstance(value, dict)
        ],
        "mods": mods,
        "evidence": {"available_categories": list(CATEGORIES)},
    }


def normalize_structured(
    data: Any, source_mode: str, forced_tier: str
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    if not isinstance(data, dict):
        raise SystemExit("manifest/inventory input must be a JSON object")
    canonical = is_authoritative_manifest(data)
    raw_analyses = (
        [canonical_manifest_analysis(data)]
        if canonical
        else first_present(
            data, "analyses", "dashboards", "documents", default=[]
        )
    )
    if not isinstance(raw_analyses, list):
        raise SystemExit("manifest/inventory analyses must be an array")
    export = data.get("export") if canonical else {}
    instance_raw = (
        {
            "name": "manifest:%s" % first_present(
                data.get("source") or {}, "name", default="Spotfire"
            ),
            "server_version": (
                export.get("spotfire_version")
                if isinstance(export, dict)
                else None
            ),
        }
        if canonical
        else data.get("instance", {})
    )
    if isinstance(instance_raw, str):
        instance = {"name": instance_raw}
    elif isinstance(instance_raw, dict):
        instance = dict(instance_raw)
    else:
        instance = {"name": "unknown"}
    instance.setdefault("name", "unknown")
    analyses = [
        normalize_analysis(analysis, index, forced_tier)
        for index, analysis in enumerate(raw_analyses)
        if isinstance(analysis, dict)
    ]

    top_usage = data.get("usage") if isinstance(data.get("usage"), dict) else {}
    top_usage_by_analysis = first_present(top_usage, "by_analysis", "byAnalysis", default={})
    if not isinstance(top_usage_by_analysis, dict):
        top_usage_by_analysis = {}
    usage_by_analysis = {}
    for analysis in analyses:
        merged = {}
        external = top_usage_by_analysis.get(analysis["id"])
        if isinstance(external, dict):
            merged.update(external)
        merged.update(analysis.get("usage") or {})
        merged = {
            key: merged[key]
            for key in ("views", "distinct_viewers", "last_accessed", "favorite_count")
            if key in merged and merged[key] is not None
        }
        if merged:
            usage_by_analysis[analysis["id"]] = merged

    evidence_gaps = list(as_list(data.get("evidence_gaps")))
    missing = sorted(
        {
            category
            for analysis in analyses
            for category in analysis["evidence"]["missing_categories"]
        }
    )
    if missing:
        evidence_gaps.append(
            "The input did not assert evidence for these feature categories on every analysis: "
            + ", ".join(missing)
            + ". Empty and not-exported are intentionally different."
        )
    if forced_tier == "raw-dxp-inventory":
        evidence_gaps.append(
            "Raw-DXP inventory is accepted only as normalized JSON produced by an authorized "
            "local exporter; the assessment does not introspect opaque DXP bytes."
        )

    canonical_sources = (
        [
            {
                "id": first_present(table, "source_id", "id", "name"),
                "name": first_present(table, "name", "source_id"),
                "source": table.get("source"),
            }
            for table in as_list((data.get("model") or {}).get("tables"))
            if isinstance(table, dict)
        ]
        if canonical
        else []
    )
    inventory = {
        "schema_version": "spotfire-assessment-inventory-v1",
        "instance": instance,
        "source_mode": source_mode,
        "capability_tier": forced_tier,
        "analyses": analyses,
        "data_sources": canonical_sources or list(
            as_list(
                first_present(
                    data, "data_sources", "dataSources", default=[]
                )
            )
        ),
        "users": list(as_list(data.get("users"))),
        "library": data.get("library") if isinstance(data.get("library"), dict) else {},
        "evidence_gaps": list(dict.fromkeys(str(gap) for gap in evidence_gaps if gap)),
        "warnings": list(as_list(data.get("warnings"))),
    }
    usage_doc = None
    if usage_by_analysis:
        quantitative = any("views" in value for value in usage_by_analysis.values())
        usage_doc = {
            "schema_version": "spotfire-assessment-usage-v1",
            "evidence_kind": "exported-usage" if quantitative else "metadata-signals",
            "quantitative_views": quantitative,
            "by_analysis": usage_by_analysis,
        }
    return inventory, usage_doc


def classify_formula(feature: dict[str, Any], spec: dict[str, Any]) -> tuple[str, str]:
    expression = str(first_present(feature, "expression", "formula", default=""))
    for tier in ("unhandled", "manual", "hint"):
        for pattern in spec.get("patterns", {}).get(tier, []):
            if re.search(pattern, expression, re.IGNORECASE):
                return tier, f"formula matches {tier} rule: {pattern}"
    functions = {token(name) for name in re.findall(r"\b([A-Za-z_][A-Za-z0-9_.]*)\s*\(", expression)}
    known = {token(name) for name in spec.get("auto_functions", [])}
    if not functions or functions.issubset(known):
        return "auto", "operators/literals or cataloged core functions"
    unknown = ", ".join(sorted(functions - known))
    return spec.get("default", "manual"), f"uncataloged formula function(s): {unknown}"


def classify_feature(
    category: str, feature: dict[str, Any], catalog: dict[str, Any]
) -> tuple[str, str]:
    spec = catalog["categories"][category]
    if category == "formulas":
        return classify_formula(feature, spec)
    raw_name = first_present(feature, "type", "kind", "language", "name", default="")
    name = token(raw_name)
    aliases = {token(key): token(value) for key, value in spec.get("aliases", {}).items()}
    name = aliases.get(name, name)
    for tier in TIER_ORDER:
        values = {token(value) for value in spec.get(tier, [])}
        if name in values:
            return tier, f"{raw_name or '(missing type)'} is cataloged {tier}"
    default = spec.get("default", "unhandled")
    return default, f"{raw_name or '(missing type)'} is not cataloged; safe default is {default}"


def usage_value(usage: dict[str, Any] | None, feature_count: int) -> tuple[float, str, bool]:
    usage = usage or {}
    if "views" in usage:
        views = max(int(usage.get("views") or 0), 0)
        viewers = max(int(usage.get("distinct_viewers") or 0), 0)
        return views * math.sqrt(max(viewers, 1)), "views", True
    if "favorite_count" in usage:
        favorites = max(int(usage.get("favorite_count") or 0), 0)
        return 10.0 * (1 + favorites), "favorite-count-proxy", False
    return 10.0 * (1 + feature_count / 4.0), "complexity-proxy", False


def score_inventory(
    inventory: dict[str, Any], usage_doc: dict[str, Any] | None, catalog: dict[str, Any]
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    usage_by_analysis = (usage_doc or {}).get("by_analysis", {})
    artifacts = []
    category_rollup = {
        category: {tier: 0 for tier in TIER_ORDER} for category in CATEGORIES
    }

    for analysis in inventory["analyses"]:
        counts = Counter({tier: 0 for tier in TIER_ORDER})
        category_counts = {
            category: {tier: 0 for tier in TIER_ORDER} for category in CATEGORIES
        }
        details = []
        for category in CATEGORIES:
            for feature in analysis.get(category, []):
                tier, reason = classify_feature(category, feature, catalog)
                counts[tier] += 1
                category_counts[category][tier] += 1
                category_rollup[category][tier] += 1
                details.append(
                    {
                        "category": category,
                        "name": first_present(
                            feature, "title", "name", "type", "language", default="(unnamed)"
                        ),
                        "tier": tier,
                        "reason": reason,
                    }
                )
        feature_count = sum(counts.values())
        cost = 10 * counts["unhandled"] + 3 * counts["manual"] + counts["hint"]
        usage = usage_by_analysis.get(analysis["id"], analysis.get("usage") or {})
        value, value_basis, quantitative_views = usage_value(usage, feature_count)
        score = value / (1.0 + cost)
        views = int(usage.get("views") or 0) if quantitative_views else None
        viewers = int(usage.get("distinct_viewers") or 0) if quantitative_views else None
        if quantitative_views and views == 0:
            tag = "retire"
        elif counts["unhandled"] >= 1:
            tag = "needs-gap-scout"
        elif score >= 20 and counts["manual"] == 0:
            tag = "migrate-first"
        elif score >= 10:
            tag = "easy-win"
        else:
            tag = "moderate"
        artifacts.append(
            {
                "id": analysis["id"],
                "title": analysis["title"],
                "path": analysis.get("path"),
                "source_ids": analysis.get("source_ids", []),
                "n_auto": counts["auto"],
                "n_hint": counts["hint"],
                "n_manual": counts["manual"],
                "n_unhandled": counts["unhandled"],
                "category_counts": category_counts,
                "feature_details": details,
                "views": views,
                "distinct_viewers": viewers,
                "value_basis": value_basis,
                "value": round(value, 3),
                "cost": cost,
                "score": round(score, 3),
                "tag": tag,
                "evidence": analysis["evidence"],
            }
        )

    by_tag = Counter(artifact["tag"] for artifact in artifacts)
    totals = {
        "n_artifacts": len(artifacts),
        **{
            f"n_{tier}": sum(artifact[f"n_{tier}"] for artifact in artifacts)
            for tier in TIER_ORDER
        },
        "total_views": sum(artifact["views"] or 0 for artifact in artifacts),
    }
    feature_total = sum(totals[f"n_{tier}"] for tier in TIER_ORDER)
    totals["pct_auto"] = (
        round(100.0 * (totals["n_auto"] + totals["n_hint"]) / feature_total, 1)
        if feature_total
        else 0.0
    )
    complexity = {
        "schema_version": "spotfire-assessment-complexity-v1",
        "capability_tier": inventory["capability_tier"],
        "catalog_version": catalog["version"],
        "artifacts": artifacts,
        "rollup": {
            "by_tag": dict(sorted(by_tag.items())),
            "totals": totals,
            "by_category": category_rollup,
        },
        "evidence_gaps": inventory["evidence_gaps"],
    }
    shortlist = {
        "schema_version": "spotfire-assessment-shortlist-v1",
        "capability_tier": inventory["capability_tier"],
        "artifacts": sorted(
            artifacts,
            key=lambda artifact: (
                TAG_PRIORITY.get(artifact["tag"], 99),
                -artifact["score"],
                artifact["title"].lower(),
            ),
        ),
    }
    plan = build_migration_plan(inventory, shortlist)
    return complexity, shortlist, plan


def detect_duplicates(analyses: list[dict[str, Any]], artifacts: list[dict[str, Any]]) -> dict[str, Any]:
    try:
        script = SKILL_DIR / "scripts" / "dup-dashboards.py"
        spec = importlib.util.spec_from_file_location("spotfire_dup_dashboards", script)
        if not spec or not spec.loader:
            raise RuntimeError("could not load duplicate detector")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        artifact_by_id = {artifact["id"]: artifact for artifact in artifacts}
        return module.detect(
            [
                {
                    "id": analysis["id"],
                    "name": analysis["title"],
                    "sources": analysis.get("source_ids", []),
                    "fields": analysis.get("fields", []),
                    "viz": [
                        first_present(visual, "type", "kind")
                        for visual in analysis.get("visuals", [])
                    ],
                    "usage": artifact_by_id.get(analysis["id"], {}).get("views"),
                }
                for analysis in analyses
            ]
        )
    except Exception as exc:  # best-effort enrichment must never block assessment
        return {"groups": [], "summary": {}, "warning": f"duplicate detector failed: {exc}"}


def build_migration_plan(
    inventory: dict[str, Any], shortlist: dict[str, Any]
) -> dict[str, Any]:
    clusters: dict[str, Any] = {}
    for artifact in shortlist["artifacts"]:
        sources = artifact.get("source_ids") or ["unknown"]
        key = "|".join(sorted(sources))
        cluster = clusters.setdefault(
            key,
            {
                "source_ids": sorted(sources),
                "analysis_ids": [],
                "analysis_count": 0,
                "by_tag": defaultdict(int),
            },
        )
        cluster["analysis_ids"].append(artifact["id"])
        cluster["analysis_count"] += 1
        cluster["by_tag"][artifact["tag"]] += 1
    for cluster in clusters.values():
        cluster["by_tag"] = dict(cluster["by_tag"])

    waves = defaultdict(list)
    for artifact in shortlist["artifacts"]:
        path = (
            "retire"
            if artifact["tag"] == "retire"
            else "gap-scout"
            if artifact["tag"] == "needs-gap-scout"
            else "convert"
        )
        waves[path].append(artifact["id"])
    return {
        "schema_version": "spotfire-assessment-migration-plan-v1",
        "capability_tier": inventory["capability_tier"],
        "clusters": list(clusters.values()),
        "waves": dict(waves),
        "duplicate_dashboards": detect_duplicates(inventory["analyses"], shortlist["artifacts"]),
        "evidence_gaps": inventory["evidence_gaps"],
        "handoff": {
            "converter": "spotfire-to-sigma",
            "note": "Reconfirm every evidence-limited classification during converter discovery.",
        },
    }


def md_cell(value: Any) -> str:
    return str(value if value is not None else "—").replace("|", "\\|").replace("\n", " ")


def render_readout(
    inventory: dict[str, Any],
    usage_doc: dict[str, Any] | None,
    complexity: dict[str, Any],
    shortlist: dict[str, Any],
    plan: dict[str, Any],
) -> str:
    instance = inventory.get("instance", {}).get("name", "unknown")
    tier = inventory["capability_tier"]
    totals = complexity["rollup"]["totals"]
    gaps = inventory["evidence_gaps"]
    lines = [
        f"# Spotfire → Sigma migration readiness — {instance}",
        "",
        f"**Capability tier:** `{tier}` · **Generated:** {dt.date.today().isoformat()}",
        "",
        "> Read-only pre-scoping output. Nothing was written to Spotfire or Sigma. "
        "Scores are directional heuristics, not effort estimates.",
        "",
    ]
    if tier == "library-metadata-only":
        lines += [
            "> **Evidence-limited:** Library REST API v2 metadata cannot reveal visuals, "
            "formulas, scripts, data functions, mods, or DXP internals. Rankings must not "
            "be treated as conversion coverage.",
            "",
        ]
    lines += [
        "## Estate overview",
        "",
        "| Measure | Count |",
        "|---|---:|",
        f"| Analyses | {len(inventory['analyses'])} |",
        f"| Data sources | {len(inventory['data_sources'])} |",
        f"| Users | {len(inventory['users'])} |",
        f"| Counted features | {sum(totals[f'n_{tier_name}'] for tier_name in TIER_ORDER)} |",
        f"| Auto / hint / manual / unhandled | {totals['n_auto']} / {totals['n_hint']} / {totals['n_manual']} / {totals['n_unhandled']} |",
        f"| Auto + hint share | {totals['pct_auto']:.1f}% |",
        "",
        "## Migration shortlist",
        "",
        "| Analysis | Tag | Score | Value basis | A/H/M/U | Evidence gaps |",
        "|---|---|---:|---|---:|---|",
    ]
    for artifact in shortlist["artifacts"]:
        missing = ", ".join(artifact["evidence"]["missing_categories"]) or "none"
        counts = "/".join(str(artifact[f"n_{name}"]) for name in TIER_ORDER)
        lines.append(
            "| "
            + " | ".join(
                md_cell(value)
                for value in (
                    artifact["title"],
                    artifact["tag"],
                    f"{artifact['score']:.2f}",
                    artifact["value_basis"],
                    counts,
                    missing,
                )
            )
            + " |"
        )
    if not shortlist["artifacts"]:
        lines.append("| _No analyses found_ | — | — | — | — | — |")

    lines += ["", "## Feature coverage", ""]
    for category in CATEGORIES:
        counts = complexity["rollup"]["by_category"][category]
        lines.append(
            f"- **{category.replace('_', ' ').title()}:** "
            + " / ".join(f"{name} {counts[name]}" for name in TIER_ORDER)
        )
    lines += ["", "## Evidence gaps", ""]
    if gaps:
        lines.extend(f"- {gap}" for gap in gaps)
    else:
        lines.append("- No category-level gaps declared by the input. Converter discovery must still verify the export.")

    dup = plan.get("duplicate_dashboards", {})
    summary = dup.get("summary", {})
    lines += [
        "",
        "## Migration plan",
        "",
        f"- Source clusters: **{len(plan['clusters'])}**",
        f"- Gap-scout analyses: **{len(plan.get('waves', {}).get('gap-scout', []))}**",
        f"- Retire candidates: **{len(plan.get('waves', {}).get('retire', []))}**",
        f"- Duplicate groups: **{summary.get('duplicate_groups', 0)}** "
        f"(potential conversions avoided: {summary.get('conversions_avoided', 0)})",
        "",
        "## Output and handoff",
        "",
        "- `probe.json` — mode/tier decision and evidence boundaries",
        "- `inventory.json` — normalized local inventory",
    ]
    if usage_doc:
        lines.append("- `usage.json` — usage or Library metadata signals actually present")
    else:
        lines.append("- `usage.json` — not written because no usage evidence existed")
    lines += [
        "- `complexity.json` — category classifications and scoring",
        "- `shortlist.json` — ranked analyses",
        "- `migration-plan.json` — source clusters, waves, duplicates, and evidence gaps",
        "",
        "Hand `migration-plan.json` to `spotfire-to-sigma`; reconfirm evidence-limited "
        "features before any conversion.",
        "",
    ]
    return "\n".join(lines)


class LibraryClient:
    """Small stdlib-only, read-only Library REST API v2 client."""

    def __init__(
        self,
        base_url: str,
        access_token: str,
        timeout: int = 60,
        context: ssl.SSLContext | None = None,
    ) -> None:
        root = base_url.rstrip("/")
        spotfire_root = root if root.endswith("/spotfire") else root + "/spotfire"
        self.api_root = spotfire_root + "/api/rest/library/v2"
        self.access_token = access_token
        self.timeout = timeout
        self.context = context or ssl.create_default_context()

    def get(self, path: str, query: dict[str, Any] | None = None) -> Any:
        url = self.api_root + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        request = urllib.request.Request(
            url,
            method="GET",
            headers={
                "Authorization": f"Bearer {self.access_token}",
                "Accept": "application/json",
                "User-Agent": "sigma-migration-skills/spotfire-assessment",
            },
        )
        try:
            with urllib.request.urlopen(
                request, timeout=self.timeout, context=self.context
            ) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            raise RuntimeError(f"Library API GET {path} failed with HTTP {exc.code}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"Library API GET {path} failed: {exc.reason}") from exc

    def info(self) -> dict[str, Any]:
        value = self.get("/info")
        return value if isinstance(value, dict) else {}

    def items(self, max_results: int) -> dict[str, Any]:
        value = self.get(
            "/items",
            {
                "maxResults": max_results,
                "attributes": "all",
            },
        )
        if isinstance(value, list):
            return {"items": value}
        return value if isinstance(value, dict) else {"items": []}


def token_url_for(base_url: str) -> str:
    root = base_url.rstrip("/")
    spotfire_root = root if root.endswith("/spotfire") else root + "/spotfire"
    return spotfire_root + "/oauth2/token"


def mint_access_token(
    token_url: str,
    client_id: str,
    client_secret: str,
    auth_method: str,
    timeout: int = 60,
) -> str:
    form = {"grant_type": "client_credentials", "scope": "api.library.read"}
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
    }
    if auth_method == "post":
        form.update({"client_id": client_id, "client_secret": client_secret})
    else:
        basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
        headers["Authorization"] = f"Basic {basic}"
    request = urllib.request.Request(
        token_url,
        data=urllib.parse.urlencode(form).encode(),
        method="POST",
        headers=headers,
    )
    try:
        with urllib.request.urlopen(
            request, timeout=timeout, context=ssl.create_default_context()
        ) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"OAuth token request failed with HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"OAuth token request failed: {exc.reason}") from exc
    access_token = payload.get("access_token") if isinstance(payload, dict) else None
    if not access_token:
        raise SystemExit("OAuth token response did not contain access_token")
    return str(access_token)


def parse_major(version: str | None) -> int | None:
    match = re.match(r"\s*(\d+)", version or "")
    return int(match.group(1)) if match else None


def select_fixture(directory: Path) -> tuple[Path, str]:
    candidates = (
        ("manifest.json", "manifest"),
        ("library-items.json", "library"),
        ("inventory.json", "inventory"),
    )
    found = [(directory / name, mode) for name, mode in candidates if (directory / name).is_file()]
    if len(found) != 1:
        expected = ", ".join(name for name, _ in candidates)
        raise SystemExit(
            f"{directory} must contain exactly one of {expected}; found {len(found)}"
        )
    return found[0]


def probe_document(
    inventory: dict[str, Any],
    usage_doc: dict[str, Any] | None,
    live: bool,
    input_label: str,
    library_info: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "schema_version": "spotfire-assessment-probe-v1",
        "source_mode": inventory["source_mode"],
        "input": input_label,
        "capability_tier": inventory["capability_tier"],
        "read_only": True,
        "live_validation": "LIVE-UNVALIDATED" if live else "offline-validated",
        "usage_evidence": usage_doc is not None,
        "analysis_count": len(inventory["analyses"]),
        "library_info": library_info or {},
        "evidence_gaps": inventory["evidence_gaps"],
        "boundaries": {
            "live_api": "Library REST API v2 (Spotfire 14+)",
            "oauth_scope": "api.library.read",
            "pre_14_fallback": "--manifest or --inventory from an authorized offline export",
            "cloud": "Deployment/tenant support is unverified; confirm API client registration and endpoint access.",
        },
        "network_writes": [],
        "notes": [
            "Live assessment issues GET /info and GET /items only.",
            "If client credentials are used, POST /spotfire/oauth2/token is authentication, not a content write.",
            "No Sigma credentials or APIs are used.",
        ],
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--from-fixtures", type=Path)
    inputs.add_argument("--manifest", type=Path)
    inputs.add_argument("--inventory", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--base-url", default=os.environ.get("SPOTFIRE_BASE_URL"))
    parser.add_argument("--access-token", default=os.environ.get("SPOTFIRE_ACCESS_TOKEN"))
    parser.add_argument("--client-id", default=os.environ.get("SPOTFIRE_CLIENT_ID"))
    parser.add_argument("--client-secret", default=os.environ.get("SPOTFIRE_CLIENT_SECRET"))
    parser.add_argument("--token-url", default=os.environ.get("SPOTFIRE_TOKEN_URL"))
    parser.add_argument(
        "--token-auth-method",
        choices=("basic", "post"),
        default=os.environ.get("SPOTFIRE_TOKEN_AUTH_METHOD", "basic"),
    )
    parser.add_argument("--server-version", default=os.environ.get("SPOTFIRE_SERVER_VERSION"))
    parser.add_argument("--max-results", type=int, default=0)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    args.out.mkdir(parents=True, exist_ok=True)
    catalog = load_catalog()
    live = not (args.from_fixtures or args.manifest or args.inventory)
    library_info = None

    if args.from_fixtures:
        if not args.from_fixtures.is_dir():
            raise SystemExit(f"fixture directory not found: {args.from_fixtures}")
        input_path, mode = select_fixture(args.from_fixtures)
        data = read_json(input_path)
        label = str(input_path)
        if mode == "library":
            inventory, usage_doc = normalize_library(
                data,
                {"name": f"fixtures:{args.from_fixtures.name}"},
                "fixtures-library-metadata",
            )
        elif mode == "manifest":
            inventory, usage_doc = normalize_structured(
                data, "fixtures-full-manifest", "full-exported-manifest"
            )
        else:
            inventory, usage_doc = normalize_structured(
                data, "fixtures-raw-dxp-inventory", "raw-dxp-inventory"
            )
    elif args.manifest:
        label = str(args.manifest)
        manifest_data = read_json(args.manifest)
        if not is_authoritative_manifest(manifest_data):
            raise SystemExit(
                "--manifest requires a spotfire_neutral_manifest v1 exported "
                "through Spotfire.Dxp.Application; use --inventory for "
                "evidence-limited normalized JSON"
            )
        validation_warnings = validate_authoritative_manifest(manifest_data)
        inventory, usage_doc = normalize_structured(
            manifest_data, "manifest", "full-exported-manifest"
        )
        inventory["warnings"].extend(validation_warnings)
    elif args.inventory:
        if args.inventory.suffix.lower() == ".dxp":
            raise SystemExit(
                "A DXP is opaque under the public API. Supply normalized JSON from an "
                "authorized local exporter, not the .dxp binary."
            )
        data = read_json(args.inventory)
        label = str(args.inventory)
        if library_items_from(data) is not None and not (
            isinstance(data, dict)
            and any(key in data for key in ("analyses", "dashboards", "documents"))
        ):
            inventory, usage_doc = normalize_library(
                data, {"name": args.inventory.stem}, "library-metadata-input"
            )
        else:
            inventory, usage_doc = normalize_structured(
                data, "raw-dxp-inventory", "raw-dxp-inventory"
            )
    else:
        print(
            "WARNING: Spotfire live transport is LIVE-UNVALIDATED. It is based on the "
            "official Spotfire 14+ Library REST API v2 contract; verify against the "
            "target deployment before relying on completeness.",
            file=sys.stderr,
        )
        if not args.base_url:
            raise SystemExit("live mode requires --base-url or SPOTFIRE_BASE_URL")
        major = parse_major(args.server_version)
        if major is not None and major < 14:
            raise SystemExit(
                "Library REST API v2 is a Spotfire 14+ boundary. For pre-14, use "
                "--manifest or --inventory with an authorized offline export."
            )
        access_token = args.access_token
        if not access_token:
            if not (args.client_id and args.client_secret):
                raise SystemExit(
                    "live mode requires SPOTFIRE_ACCESS_TOKEN or "
                    "SPOTFIRE_CLIENT_ID/SPOTFIRE_CLIENT_SECRET"
                )
            access_token = mint_access_token(
                args.token_url or token_url_for(args.base_url),
                args.client_id,
                args.client_secret,
                args.token_auth_method,
            )
        client = LibraryClient(args.base_url, access_token)
        library_info = client.info()
        data = client.items(args.max_results)
        instance = {
            "name": urllib.parse.urlparse(args.base_url).netloc or args.base_url,
            "base_url": args.base_url,
            "server_version": args.server_version,
        }
        inventory, usage_doc = normalize_library(data, instance, "live-library-rest-v2")
        inventory["evidence_gaps"].append(
            "LIVE-UNVALIDATED transport: response shape and tenant completeness have not "
            "been confirmed against a real Spotfire 14+ environment."
        )
        if major is None:
            inventory["evidence_gaps"].append(
                "Server version was not supplied; successful v2 calls prove endpoint "
                "reachability but not an independently reported product version."
            )
        label = args.base_url

    complexity, shortlist, plan = score_inventory(inventory, usage_doc, catalog)
    probe = probe_document(inventory, usage_doc, live, label, library_info)
    write_json(args.out / "probe.json", probe)
    write_json(args.out / "inventory.json", inventory)
    usage_path = args.out / "usage.json"
    if usage_doc:
        write_json(usage_path, usage_doc)
    elif usage_path.exists():
        usage_path.unlink()
    write_json(args.out / "complexity.json", complexity)
    write_json(args.out / "shortlist.json", shortlist)
    write_json(args.out / "migration-plan.json", plan)
    (args.out / "readout.md").write_text(
        render_readout(inventory, usage_doc, complexity, shortlist, plan),
        encoding="utf-8",
    )
    print(
        f"spotfire-assessment: tier={inventory['capability_tier']} "
        f"analyses={len(inventory['analyses'])} usage={'yes' if usage_doc else 'no'} "
        f"-> {args.out}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
