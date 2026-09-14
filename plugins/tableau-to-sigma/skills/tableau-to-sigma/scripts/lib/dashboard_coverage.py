"""Census visible Tableau dashboards against built Sigma workbook pages."""

from __future__ import annotations

import hashlib
import json
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

import code_rep


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1].split(".")[-1]


def source_dashboards(path: Path) -> tuple[list[str], str]:
    raw = path.read_bytes()
    root = ET.fromstring(raw.decode("utf-8-sig"))
    dashboards = []
    for node in root.iter():
        if local_name(node.tag) != "dashboard":
            continue
        name = str(node.attrib.get("name") or "")
        if not name:
            continue
        if not any(local_name(child.tag) == "zone" for child in node.iter()):
            continue
        dashboards.append(name)
    visible_windows = [
        str(node.attrib.get("name"))
        for node in root.iter()
        if local_name(node.tag) == "window"
        and node.attrib.get("class") == "dashboard"
        and str(node.attrib.get("hidden") or "").lower() != "true"
        and node.attrib.get("name")
    ]
    visible = (
        [
            name
            for name in dashboards
            if any(name.casefold() == window.casefold() for window in visible_windows)
        ]
        if visible_windows
        else dashboards
    )
    return list(dict.fromkeys(visible)), hashlib.sha256(raw).hexdigest()


def evaluate(twb_path: Path, spec_path: Path, scope: Any) -> dict:
    visible, source_sha = source_dashboards(twb_path)
    spec_raw = spec_path.read_bytes()
    spec = json.loads(spec_raw.decode("utf-8-sig"))
    pages = code_rep.document(spec).get("pages") or []
    built_pages = [
        str(page.get("name"))
        for page in pages
        if isinstance(page, dict)
        and page.get("name")
        and str(page.get("name")).casefold() != "data"
    ]
    scope = scope if isinstance(scope, dict) else {}
    mode = str(scope.get("mode") or "full")
    provenance = str(scope.get("provenance") or "")
    requested = list(
        dict.fromkeys(
            str(value)
            for value in (scope.get("dashboards") or [])
            if str(value)
        )
    )
    blockers = []
    if mode == "selected" and provenance not in {"stated", "cli"}:
        blockers.append(
            {
                "kind": "unstated-scope",
                "reason": (
                    f"selected dashboard scope has provenance {provenance!r}, "
                    "not stated/cli"
                ),
            }
        )
    expected = []
    if mode == "selected":
        for asked in requested:
            match = next(
                (name for name in visible if name.casefold() == asked.casefold()), None
            )
            if match is None:
                blockers.append(
                    {
                        "kind": "scope-mismatch",
                        "dashboard": asked,
                        "reason": "selected dashboard is not a visible source dashboard",
                    }
                )
            else:
                expected.append(match)
    else:
        expected = visible
    missing = [
        name
        for name in expected
        if not any(name.casefold() == built.casefold() for built in built_pages)
    ]
    blockers.extend(
        {
            "kind": "missing-dashboard",
            "dashboard": name,
            "reason": (
                "visible in Tableau and in stated scope, but no Sigma workbook page "
                "was built"
            ),
        }
        for name in missing
    )
    return {
        "schema_version": 1,
        "status": "pass" if not blockers else "fail",
        "mode": mode,
        "provenance": provenance or ("full-workbook" if mode == "full" else ""),
        "visible_source_dashboards": visible,
        "expected_dashboards": expected,
        "built_pages": built_pages,
        "scope_excluded_dashboards": [
            name for name in visible if name not in expected
        ],
        "missing_dashboards": missing,
        "blockers": blockers,
        "source_sha256": source_sha,
        "spec_sha256": hashlib.sha256(spec_raw).hexdigest(),
    }
