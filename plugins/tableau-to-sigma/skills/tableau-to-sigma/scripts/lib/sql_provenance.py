"""Account every Tableau data-model SQL element by source or generated purpose."""

from __future__ import annotations

import hashlib
import html
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

ALLOWED_ORIGINS = {
    "source-custom-sql",
    "generated-lod",
    "generated-top-n",
    "generated-window",
    "generated-blend",
    "generated-manual",
}


def normalize_sql(value: Any) -> str:
    text = html.unescape(str(value or "")).strip()
    text = re.sub(r"^\s*<!\[CDATA\[", "", text)
    text = re.sub(r"\]\]>\s*$", "", text)
    return re.sub(r"\s+", " ", text).strip().rstrip(";").lower()


def source_queries(twb_path: Path | None, custom_sql_path: Path | None) -> list[str]:
    queries = []
    if twb_path is not None and twb_path.is_file():
        root = ET.fromstring(twb_path.read_text(encoding="utf-8-sig"))
        for node in root.iter():
            if node.tag.rsplit("}", 1)[-1].split(".")[-1] == "relation" and node.attrib.get("type") == "text":
                queries.append(normalize_sql("".join(node.itertext())))
    if custom_sql_path is not None and custom_sql_path.is_file():
        document = json.loads(custom_sql_path.read_text(encoding="utf-8-sig"))

        def walk(value):
            if isinstance(value, dict):
                for key in ("query", "sql", "statement"):
                    if isinstance(value.get(key), str):
                        queries.append(normalize_sql(value[key]))
                for child in value.values():
                    walk(child)
            elif isinstance(value, list):
                for child in value:
                    walk(child)

        walk(document)
    return list(dict.fromkeys(query for query in queries if query))


def load_overrides(path: Path | None) -> dict[str, dict]:
    if path is None or not path.is_file():
        return {}
    document = json.loads(path.read_text(encoding="utf-8-sig"))
    rows = document.get("entries") if isinstance(document, dict) else document
    result = {}
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        key = str(row.get("element_id") or row.get("element_name") or "")
        proof_path = str(row.get("proof") or "")
        proof_file = (
            (path.parent / proof_path).resolve()
            if proof_path and not Path(proof_path).is_absolute()
            else Path(proof_path)
        )
        try:
            proof = (
                json.loads(proof_file.read_text(encoding="utf-8-sig"))
                if proof_path
                else None
            )
        except (OSError, ValueError, json.JSONDecodeError):
            proof = None
        if (
            key
            and row.get("origin_type") in ALLOWED_ORIGINS
            and str(row.get("reason") or "").strip()
            and isinstance(proof, dict)
            and proof.get("match") is True
        ):
            result[key] = row
    return result


def evaluate(
    dm_spec_path: Path,
    metadata_path: Path | None = None,
    twb_path: Path | None = None,
    custom_sql_path: Path | None = None,
    overrides_path: Path | None = None,
) -> dict:
    spec_raw = dm_spec_path.read_bytes()
    spec = json.loads(spec_raw.decode("utf-8-sig"))
    metadata = (
        json.loads(metadata_path.read_text(encoding="utf-8-sig"))
        if metadata_path is not None and metadata_path.is_file()
        else {}
    )
    source_sql = source_queries(twb_path, custom_sql_path)
    overrides = load_overrides(overrides_path)
    converter_entries = metadata.get("sqlProvenance") or []
    elements = [
        element
        for page in spec.get("pages") or []
        for element in page.get("elements") or []
        if isinstance(element, dict)
    ]
    entries = []
    for element in elements:
        if (element.get("source") or {}).get("kind") != "sql":
            continue
        statement = str((element.get("source") or {}).get("statement") or "")
        normalized = normalize_sql(statement)
        override = overrides.get(str(element.get("id") or "")) or overrides.get(
            str(element.get("name") or "")
        )
        converter_entry = next(
            (
                row
                for row in converter_entries
                if isinstance(row, dict)
                and str(row.get("elementId") or "") == str(element.get("id") or "")
            ),
            None,
        )
        converter_origin = (
            str(converter_entry.get("originType") or "")
            if converter_entry is not None
            else ""
        )
        converter_statement_matches = (
            converter_entry is not None
            and normalize_sql(converter_entry.get("statement")) == normalized
        )
        if override:
            origin = str(override["origin_type"])
            evidence = f"override: {override['reason']}"
        elif (
            converter_statement_matches and converter_origin in ALLOWED_ORIGINS
        ):
            origin, evidence = (
                converter_origin,
                "converter-emitted SQL provenance ledger",
            )
        elif any(normalized == query for query in source_sql):
            origin, evidence = (
                "source-custom-sql",
                "statement matches Tableau source Custom SQL",
            )
        else:
            origin, evidence = (
                "unattributed",
                "no exact source-SQL match, statement-bound converter ledger, or proven override",
            )
        entries.append(
            {
                "element_id": element.get("id"),
                "element_name": element.get("name"),
                "origin_type": origin,
                "status": "fail" if origin == "unattributed" else "attributed",
                "evidence": evidence,
                "statement_sha256": hashlib.sha256(
                    normalized.encode("utf-8")
                ).hexdigest(),
            }
        )
    blockers = [entry for entry in entries if entry["status"] == "fail"]
    return {
        "schema_version": 1,
        "status": "pass" if not blockers else "fail",
        "sql_elements": entries,
        "blockers": blockers,
        "dm_spec_sha256": hashlib.sha256(spec_raw).hexdigest(),
    }
