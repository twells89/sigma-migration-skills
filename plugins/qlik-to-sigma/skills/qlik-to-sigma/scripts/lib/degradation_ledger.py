#!/usr/bin/env python3
"""Qlik-local deterministic degradation-ledger derivation.

The completion path cannot trust a reported verdict on its own.  This module
re-derives scope cuts and quality waivers from their source artifacts so the
finalizer, report builder, and verifier all compare the same ordered entries.
Tableau-only LOD, RCF, and extract artifacts are intentionally out of scope.
"""

from __future__ import annotations

import json
import os
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

VERSION = 1
CLASSES = (
    "scope-cut",
    "quality-waiver",
    "recorded-escape",
    "fidelity-residual",
    "resolution-waived",
)
CENSUS_ESCAPE_FLAGS = {
    "--force-new-workbook",
    "--force-route-switch",
    "--allow-manual-spec",
}
CENSUS_DERIVED_FLAGS = {"visual-divergent"}
ESCAPE_OFFRAMP_KINDS = {
    "cred-gate-waived",
    "doctor-gate-waived",
    "qlik-gate-waived",
    "stale-skill-waived",
    "degraded-fastpath",
    "skip-flag-waived",
}


def _read_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8-sig") as handle:
            return json.load(handle)
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def _entry(kind: str, item: Any, reason: Any, source: str) -> dict[str, str]:
    return {
        "class": kind,
        "item": str(item),
        "reason": str(reason),
        "source_artifact": str(source),
    }


def _norm(value: Any) -> str:
    return str(value or "").strip().casefold()


def _control_scope_drops(workdir: Path) -> dict[str, str]:
    document = _read_json(workdir / "control-scope.json")
    result: dict[str, str] = {}
    if not isinstance(document, dict):
        return result
    for row in document.get("dropped") or []:
        name = row.get("name") if isinstance(row, dict) else row
        if not str(name or "").strip():
            continue
        reason = row.get("reason") if isinstance(row, dict) else None
        result[_norm(name)] = str(reason or "dropped — recorded in control-scope.json")
    return result


def _control_waivers(workdir: Path) -> dict[str, str]:
    document = _read_json(workdir / "controls-waivers.json")
    if isinstance(document, dict):
        document = document.get("waivers")
    result: dict[str, str] = {}
    for row in document if isinstance(document, list) else []:
        if not isinstance(row, dict):
            continue
        name = row.get("control") or row.get("name")
        reason = str(row.get("reason") or "").strip()
        if str(name or "").strip() and reason:
            result[_norm(name)] = f"waived: {reason}"
    return result


def _scope_cuts(workdir: Path) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    coverage = _read_json(workdir / "coverage.json")
    unresolved = coverage.get("unresolved") if isinstance(coverage, dict) else []
    for row in unresolved if isinstance(unresolved, list) else []:
        if not isinstance(row, dict) or row.get("severity") not in {"dropped", "degraded"}:
            continue
        label = (
            "dropped visual"
            if row.get("severity") == "dropped"
            else "degraded visual (lost column/field)"
        )
        result.append(
            _entry(
                "scope-cut",
                f"{label}: {row.get('visual')}",
                row.get("detail") or row.get("severity"),
                "coverage.json",
            )
        )

    parity = _read_json(workdir / "parity-final.json")
    tile_census = parity.get("tile_census") if isinstance(parity, dict) else None
    if isinstance(tile_census, dict):
        unmatched = [str(value) for value in tile_census.get("unmatched_zone_names") or []]
        manifest = _read_json(workdir / "visual-verify" / "manifest.json")
        verified = {
            str(row.get("worksheet"))
            for row in (manifest if isinstance(manifest, list) else [])
            if isinstance(row, dict) and row.get("visual_verified") is True
        }
        for name in unmatched:
            if name not in verified:
                result.append(
                    _entry(
                        "scope-cut",
                        f"dropped tile: {name}",
                        "source dashboard zone with no matching chart (tile census)",
                        "parity-final.json tile_census",
                    )
                )

    dropped = _control_scope_drops(workdir)
    control_waivers = _control_waivers(workdir)
    coverage_paths = sorted(workdir.glob("*-controls-coverage.json"))
    seen: set[str] = set()
    if coverage_paths:
        document = _read_json(coverage_paths[0])
        details = document.get("detail") if isinstance(document, dict) else []
        for row in details if isinstance(details, list) else []:
            if not isinstance(row, dict) or row.get("status") == "emitted":
                continue
            name = str(row.get("name") or "")
            kind_name = f"{row.get('kind')}:{name}"
            key = _norm(name)
            combined_key = _norm(kind_name)
            reason = (
                dropped.get(key)
                or control_waivers.get(key)
                or control_waivers.get(combined_key)
                or f"census status: {row.get('status')}"
            )
            seen.update((key, combined_key))
            result.append(
                _entry(
                    "scope-cut",
                    f"dropped control: {kind_name}",
                    reason,
                    coverage_paths[0].name,
                )
            )
    for key, reason in dropped.items():
        if key not in seen:
            result.append(
                _entry("scope-cut", f"dropped control: {key}", reason, "control-scope.json")
            )
    for key, reason in control_waivers.items():
        if key not in seen and key not in dropped:
            result.append(
                _entry(
                    "scope-cut",
                    f"dropped control: {key}",
                    reason,
                    "controls-waivers.json",
                )
            )

    deferred = _read_json(workdir / "deferred-elements.json")
    rows = deferred.get("deferred") if isinstance(deferred, dict) else deferred
    for row in rows if isinstance(rows, list) else []:
        name = (
            row.get("name") or row.get("id") or "unnamed element"
            if isinstance(row, dict)
            else str(row)
        )
        result.append(
            _entry(
                "scope-cut",
                f"dropped DM element: {name}",
                "quarantined at DM POST (deferred-elements.json still non-empty)",
                "deferred-elements.json",
            )
        )
    return result


def _quality_waivers(workdir: Path) -> list[dict[str, str]]:
    parity = _read_json(workdir / "parity-final.json")
    if not isinstance(parity, dict) or not isinstance(parity.get("waivers"), list):
        return []
    reasons = dict(parity.get("waiver_reasons") or {})
    waiver_document = _read_json(workdir / "waivers.json")
    if isinstance(waiver_document, dict):
        waiver_document = waiver_document.get("waivers")
    for row in waiver_document if isinstance(waiver_document, list) else []:
        if isinstance(row, dict) and row.get("flag") and row.get("reason"):
            reasons.setdefault(str(row["flag"]), str(row["reason"]))

    result = []
    for flag in dict.fromkeys(str(value) for value in parity["waivers"]):
        if flag in CENSUS_DERIVED_FLAGS or flag in CENSUS_ESCAPE_FLAGS:
            continue
        reason = str(reasons.get(flag) or "")
        if flag == "--skip-visual-comparison" and "verifier" in reason.casefold():
            continue
        result.append(
            _entry(
                "quality-waiver",
                flag,
                reason or "budget-counted quality waiver (no reason recorded)",
                "parity-final.json waivers",
            )
        )
    return result


def _column_scan_skips(workdir: Path) -> list[dict[str, str]]:
    scan = _read_json(workdir / "column-scan.json")
    if not isinstance(scan, dict) or not str(scan.get("status") or "").startswith("skipped-"):
        return []
    reason = scan.get("reason") or scan.get("status")
    detail = (
        f" ({scan['columns_read']} column(s) read before the stop)"
        if "columns_read" in scan
        else ""
    )
    return [
        _entry(
            "quality-waiver",
            "gate-3-column-scan",
            f"live column type=error audit {scan.get('status')}: {reason}{detail}",
            "column-scan.json",
        )
    ]


def _recorded_escapes(workdir: Path) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    parity = _read_json(workdir / "parity-final.json")
    waiver_flags = (
        [str(value) for value in parity.get("waivers") or []]
        if isinstance(parity, dict)
        else []
    )
    for flag in waiver_flags:
        if flag in CENSUS_ESCAPE_FLAGS:
            result.append(
                _entry(
                    "recorded-escape",
                    flag,
                    "run off-ramp honored mid-run (see offramps.jsonl)",
                    "parity-final.json waivers",
                )
            )

    trail = workdir / "offramps.jsonl"
    try:
        lines = trail.read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        lines = []
    for line in lines:
        try:
            row = json.loads(line)
        except (ValueError, json.JSONDecodeError):
            continue
        if not isinstance(row, dict) or row.get("kind") not in ESCAPE_OFFRAMP_KINDS:
            continue
        item = (
            row.get("detail")
            if row.get("kind") == "skip-flag-waived" and row.get("detail")
            else row.get("kind")
        )
        result.append(
            _entry(
                "recorded-escape",
                item,
                row.get("reason") or "NO REASON GIVEN",
                "offramps.jsonl",
            )
        )
    unique: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for row in result:
        key = (row["item"], row["reason"])
        if key not in seen:
            seen.add(key)
            unique.append(row)
    return unique


def _fidelity_residuals(workdir: Path) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    parity = _read_json(workdir / "parity-final.json")
    if isinstance(parity, dict) and parity.get("visual_verdict") == "divergent":
        result.append(
            _entry(
                "fidelity-residual",
                "visual verdict: divergent",
                "recorded source-vs-target visual gaps ship in the render",
                "parity-final.json",
            )
        )
    arrangement = _read_json(workdir / "layout-arrangement.json")
    pages = arrangement.get("pages") if isinstance(arrangement, dict) else []
    for page in pages if isinstance(pages, list) else []:
        if not isinstance(page, dict):
            continue
        for violation in page.get("violations") or []:
            result.append(
                _entry(
                    "fidelity-residual",
                    f"arrangement: {page.get('page')}",
                    violation,
                    "layout-arrangement.json",
                )
            )
    png_read = _read_json(workdir / "png-read.json")
    kind_waivers = png_read.get("kind_waivers") if isinstance(png_read, dict) else []
    for row in kind_waivers if isinstance(kind_waivers, list) else []:
        if isinstance(row, dict):
            result.append(
                _entry(
                    "fidelity-residual",
                    f"chart-kind substitution: {row.get('tile')}",
                    row.get("reason") or "recorded at read time",
                    "png-read.json kind_waivers",
                )
            )
    return result


def _resolution_waived(workdir: Path) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    residues = _read_json(workdir / "manual-residues.json")
    rows = residues.get("residues") if isinstance(residues, dict) else residues
    for row in rows if isinstance(rows, list) else []:
        if isinstance(row, dict) and row.get("status") == "unbuilt":
            result.append(
                _entry(
                    "resolution-waived",
                    f"unbuilt custom-SQL residue: {row.get('calc')}",
                    "accepted unbuilt — its tile renders a magnitude proxy",
                    "manual-residues.json",
                )
            )
    for filename, default_reason in (
        ("source-anchors.json", "no anchor watched this tile"),
        ("ground-truth-plan.json", "no numeric oracle verified this tile"),
    ):
        document = _read_json(workdir / filename)
        waivers = document.get("coverage_waivers") if isinstance(document, dict) else []
        for row in waivers if isinstance(waivers, list) else []:
            if not isinstance(row, dict):
                continue
            suffix = f" — {row.get('reason')}" if row.get("reason") else ""
            result.append(
                _entry(
                    "resolution-waived",
                    f"coverage waiver: {row.get('tile')}",
                    default_reason + suffix,
                    f"{filename} coverage_waivers",
                )
            )
    return result


def derive(workdir: str | Path) -> list[dict[str, str]]:
    """Return stable, de-duplicated ledger entries for *workdir*."""

    root = Path(workdir).expanduser().resolve()
    rows = (
        _scope_cuts(root)
        + _quality_waivers(root)
        + _column_scan_skips(root)
        + _recorded_escapes(root)
        + _fidelity_residuals(root)
        + _resolution_waived(root)
    )
    result: list[dict[str, str]] = []
    seen: set[tuple[str, str, str, str]] = set()
    for row in rows:
        key = (
            row["class"],
            row["item"],
            row["reason"],
            row["source_artifact"],
        )
        if key not in seen:
            seen.add(key)
            result.append(row)
    return result


def ledger_path(workdir: str | Path) -> Path:
    return Path(workdir).expanduser().resolve() / "degradation-ledger.json"


def write(workdir: str | Path, entries: list[dict[str, str]] | None = None) -> bool:
    """Atomically persist a freshly derived ledger."""

    root = Path(workdir).expanduser().resolve()
    entries = derive(root) if entries is None else entries
    document = {
        "version": VERSION,
        "derivedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
            "+00:00", "Z"
        ),
        "counts": dict(Counter(row["class"] for row in entries)),
        "entries": entries,
    }
    path = ledger_path(root)
    temporary = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    try:
        temporary.write_text(
            json.dumps(document, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, path)
        return True
    except OSError:
        return False
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def verdict(entries: list[dict[str, str]], budget_exceeded: bool = False) -> str:
    partial = any(row.get("class") == "scope-cut" for row in entries)
    yellow = budget_exceeded or any(row.get("class") != "scope-cut" for row in entries)
    if partial and yellow:
        return "PARTIAL+YELLOW"
    if partial:
        return "PARTIAL"
    if yellow:
        return "YELLOW"
    return "GREEN"


def report_lines(entries: list[dict[str, str]]) -> list[str]:
    return [
        f"  - [{row['class']}] {row['item']} — {row['reason']} "
        f"({row['source_artifact']})"
        for row in entries
    ]
