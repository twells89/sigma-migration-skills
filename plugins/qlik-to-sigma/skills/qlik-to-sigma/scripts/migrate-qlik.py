#!/usr/bin/env python3
"""One-command Python orchestrator for Qlik discovery through hard completion."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

os.environ.setdefault("PYTHONUTF8", "1")
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

import control_lint
import flip_gate
import layout_lint
from lib import sigma_rest
from lib.code_rep import document, metadata
from lib.scout_gate import classify as classify_scouts
from lib.scout_gate import record as record_scout

HERE = Path(__file__).resolve().parent
VENDORED_CONVERTER = (HERE.parent / "converter" / "qlik.mjs").resolve()
TOTAL_PHASES = 6
NATIVE = {
    "barchart", "auto-chart", "kpi", "linechart", "table", "piechart",
    "combochart", "scatterplot", "pivot-table", "filterpane", "listbox",
}
SKIP_KINDS = {
    "sheet", "singlepublic", "appprops", "LoadModel", "measure", "dimension",
    "masterobject", "sheetlist",
}
DEGRADE_RE = re.compile(
    r"Set Analysis|Aggr\(\)|Dual\(\)|selection-state|alternate.?state|"
    r"no Sigma equivalent|no direct Sigma|stripped|column dropped",
    re.I,
)


class CommandFailure(RuntimeError):
    def __init__(self, command: list[str], returncode: int, output: str):
        self.command = command
        self.returncode = returncode
        self.output = output
        super().__init__(
            f"command failed ({returncode}): {' '.join(command)}"
        )


class Lane:
    def __init__(self, command: list[str], log: Path):
        self.command = command
        self.log = log
        self.started = time.monotonic()
        self.handle = log.open("w", encoding="utf-8")
        self.process = subprocess.Popen(
            command,
            stdout=self.handle,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.ended: float | None = None

    def join(self, label: str, timeout: int) -> int:
        try:
            returncode = self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            self.process.kill()
            self.process.wait()
            raise RuntimeError(f"FATAL: {label} lane timed out ({timeout}s)") from exc
        finally:
            self.ended = time.monotonic()
            self.handle.close()
        return returncode

    def done(self) -> bool:
        return self.process.poll() is not None

    def print_log(self) -> None:
        if self.log.is_file():
            for line in self.log.read_text(
                encoding="utf-8", errors="replace"
            ).splitlines():
                print(f"   │ {line}")


def python_command(script: str, *arguments: Any) -> list[str]:
    return [sys.executable, str(HERE / script), *(str(item) for item in arguments)]


def is_content_page(page: dict[str, Any]) -> bool:
    page_id = str(page.get("id") or "").strip().casefold()
    return (
        page.get("visibility") != "hidden"
        and page_id not in {"data", "page-data", "pg-data"}
    )


def sigma_entries(path: str) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    page = None
    page_parameter = "page"
    while True:
        separator = "&" if "?" in path else "?"
        request_path = f"{path}{separator}limit=1000"
        if page:
            request_path += f"&{page_parameter}={page}"
        response = sigma_rest.request("get", request_path) or {}
        rows = response.get("entries") or []
        entries.extend(row for row in rows if isinstance(row, dict))
        if response.get("nextPageToken") not in (None, ""):
            page = response["nextPageToken"]
            page_parameter = "pageToken"
        else:
            page = response.get("nextPage")
            page_parameter = "page"
        if page in (None, ""):
            return entries


def resolve_converter(
    development_dir: str | None,
) -> tuple[Path | None, str]:
    development = (
        Path(development_dir).expanduser().resolve() / "build" / "qlik.js"
        if development_dir
        else None
    )
    if development and development.is_file():
        return development, f"DEV BUILD {development} (explicit opt-in via QLIK_MCP_DIR)"
    if VENDORED_CONVERTER.is_file():
        provenance = VENDORED_CONVERTER.parent / "PROVENANCE.json"
        commit = None
        try:
            commit = json.loads(provenance.read_text(encoding="utf-8"))[
                "source_commit"
            ]
        except (OSError, KeyError, json.JSONDecodeError):
            pass
        suffix = f" (pinned {commit})" if commit else ""
        return VENDORED_CONVERTER, f"VENDORED qlik.mjs{suffix} — no data egress"
    return None, (
        "NONE — vendored bundle missing; converter-out.json resume applies"
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app")
    parser.add_argument("--connection", dest="conn")
    parser.add_argument("--database", default="DEMO_DB")
    parser.add_argument("--schema", default="DEMO")
    parser.add_argument("--context", default="sigma-migration")
    parser.add_argument("--folder")
    parser.add_argument("--name")
    parser.add_argument("--out")
    parser.add_argument("--answers")
    parser.add_argument(
        "--security",
        help="parsed Qlik Section Access security JSON override",
    )
    parser.add_argument("--yes", action="store_true")
    parser.add_argument("--from-discovery", dest="from_discovery")
    parser.add_argument("--unbuild")
    parser.add_argument("--prj")
    parser.add_argument("--reuse-dm")
    parser.add_argument("--no-reuse", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--skip-layout-lint", action="store_true")
    parser.add_argument("--skip-control-flip", nargs="?", const=True)
    parser.add_argument("--skip-visual-comparison")
    parser.add_argument("--skip-visual-similarity")
    parser.add_argument("--skip-anchors-gate")
    parser.add_argument(
        "--warehouse-expected",
        help="independently queried expected rows for strict offline parity",
    )
    parser.add_argument("--print-converter", action="store_true")
    return parser.parse_args(argv)


class Migration:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.started = time.monotonic()
        self.marked = self.started
        self.timings: dict[str, float] = {}
        self.snapshot_lane: Lane | None = None
        self.prep: dict[str, Any] = {}
        self.converter, self.converter_description = resolve_converter(
            os.environ.get("QLIK_MCP_DIR")
        )
        self.workdir: Path | None = None
        self.run_id = str(uuid.uuid4())

    def mark(self, name: str) -> None:
        current = time.monotonic()
        self.timings[name] = self.timings.get(name, 0.0) + current - self.marked
        self.marked = current

    def summary(self) -> None:
        if not self.timings:
            return
        detail = "  ".join(
            f"{key}={value:.1f}s" for key, value in self.timings.items()
        )
        print(
            f"\nPHASE TIMINGS  {detail}  "
            f"total={time.monotonic() - self.started:.1f}s"
        )

    @staticmethod
    def header(number: Any, title: str) -> None:
        print(f"\n── Phase {number}/{TOTAL_PHASES} · {title} ──")

    def execute(
        self,
        command: list[Any],
        *,
        check: bool = True,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        rendered = [str(item) for item in command]
        result = subprocess.run(
            rendered,
            env={**os.environ, **(env or {})},
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if result.stdout.strip():
            for line in result.stdout.splitlines():
                print(f"   {line}")
        if check and result.returncode:
            raise CommandFailure(rendered, result.returncode, result.stdout)
        return result

    def prepare_source(self) -> None:
        selected = [
            value
            for value in (
                self.args.unbuild,
                self.args.prj,
                self.args.from_discovery,
            )
            if value
        ]
        if len(selected) > 1:
            raise ValueError(
                "FATAL: choose only one of --unbuild, --prj, or --from-discovery"
            )
        if self.args.unbuild:
            source = Path(self.args.unbuild).expanduser().resolve()
            if not source.is_dir():
                raise ValueError(f"FATAL: --unbuild dir not found: {source}")
            slug = re.sub(
                r"[^A-Za-z0-9_-]", "-", re.sub(r"-unbuild$", "", source.name, flags=re.I)
            )
            destination = (
                Path(self.args.out).expanduser().resolve()
                if self.args.out
                else Path.home() / "qlik-migration" / f"{slug}-unbuild"
            )
            destination.mkdir(parents=True, exist_ok=True)
            print(f"corectl unbuild → discovery artifacts in {destination}", file=sys.stderr)
            self.execute(
                python_command(
                    "qlik-unbuild-discover.py",
                    "--unbuild",
                    source,
                    "--out",
                    destination,
                )
            )
            self.args.from_discovery = str(destination)
            self.args.app = None
        if self.args.prj:
            source = Path(self.args.prj).expanduser().resolve()
            if not source.is_dir():
                raise ValueError(f"FATAL: --prj dir not found: {source}")
            slug = re.sub(
                r"[^A-Za-z0-9_-]", "-", re.sub(r"-prj$", "", source.name, flags=re.I)
            )
            destination = (
                Path(self.args.out).expanduser().resolve()
                if self.args.out
                else Path.home() / "qlik-migration" / f"{slug}-prj"
            )
            destination.mkdir(parents=True, exist_ok=True)
            print(f"QlikView -prj → discovery artifacts in {destination}", file=sys.stderr)
            self.execute(
                python_command(
                    "qlik-prj-discover.py",
                    "--prj",
                    source,
                    "--out",
                    destination,
                )
            )
            self.args.from_discovery = str(destination)
            self.args.app = None

    def validate_front_door(self) -> None:
        if not self.args.dry_run and os.environ.get("SIGMA_OFFLINE_DRY_RUN") == "1":
            raise ValueError(
                "SIGMA_OFFLINE_DRY_RUN=1 is valid only with --dry-run; unset it "
                "and configure Sigma credentials before a live build"
            )
        if not self.args.app and not self.args.from_discovery:
            raise ValueError(
                "missing --app (or --from-discovery/--unbuild/--prj)"
            )
        if self.args.out and not self.args.conn:
            connection_path = (
                Path(self.args.out).expanduser().resolve() / "connection.json"
            )
            try:
                self.args.conn = json.loads(
                    connection_path.read_text(encoding="utf-8-sig")
                ).get("connection_id")
            except (OSError, json.JSONDecodeError):
                pass
        if not self.args.conn:
            raise ValueError(
                "missing --connection (pass --connection <id>, or run intake "
                "first and point --out at its workdir)"
            )
        source_name = self.args.app or Path(
            self.args.from_discovery or ""
        ).name
        slug = re.sub(r"[^A-Za-z0-9_-]", "-", source_name)
        self.workdir = (
            Path(self.args.out).expanduser().resolve()
            if self.args.out
            else Path.home() / "qlik-migration" / slug
        )
        self.workdir.mkdir(parents=True, exist_ok=True)
        os.environ["SIGMA_WORKDIR"] = str(self.workdir)
        self.execute(
            python_command(
                "assert-doctor-ran.py",
                "--workdir",
                self.workdir,
                "--runtime-profile",
                "python",
            )
        )
        (self.workdir / "run-state.json").write_text(
            json.dumps(
                {
                    "run_id": self.run_id,
                    "started_at": utc_now(),
                    "runtime_profile": "python",
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    def sigma_prep(self) -> None:
        assert self.workdir
        try:
            sigma_rest.auth_token()
            print("   ✓ Sigma token ready")
            folders = sigma_rest.request(
                "get", "/v2/files?typeFilters=folder&limit=200"
            ) or {}
            editable = [
                row
                for row in folders.get("entries") or []
                if row.get("type") == "folder"
                and row.get("permission") in (None, "edit", "contribute")
            ]
            picked = next(
                (
                    row
                    for row in editable
                    if re.search(r"TEST|MIGRATION", str(row.get("name") or ""), re.I)
                ),
                editable[0] if editable else None,
            )
            if picked:
                self.prep["folder_id"] = picked.get("id")
                self.prep["folder_name"] = picked.get("name")
                print(
                    f"   ✓ folder resolved: {picked.get('name')!r} "
                    f"({picked.get('id')})"
                )
            all_models, page = [], None
            while len(all_models) < 500:
                path = "/v2/dataModels?limit=100" + (
                    f"&page={page}" if page else ""
                )
                response = sigma_rest.request("get", path) or {}
                found = response.get("entries") or response.get("dataModels") or []
                if not found:
                    break
                all_models.extend(found)
                page = response.get("nextPage")
                if not page:
                    break
            top = sorted(
                all_models,
                key=lambda row: (
                    str(row.get("updatedAt") or ""),
                    str(row.get("name") or ""),
                ),
                reverse=True,
            )[:25]
            specs = {}
            for model in top:
                model_id = model.get("dataModelId") or model.get("id")
                if not model_id:
                    continue
                try:
                    specs[model_id] = sigma_rest.request(
                        "get", f"/v2/dataModels/{model_id}/spec"
                    )
                except sigma_rest.SigmaError:
                    continue
            (self.workdir / "dm-specs-cache.json").write_text(
                json.dumps(
                    {"fetched_at": utc_now(), "dms": all_models, "specs": specs},
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            print(
                f"   ✓ prefetched {len(specs)}/{len(all_models)} DM spec(s) "
                "→ dm-specs-cache.json"
            )
        except Exception as exc:
            print(
                f"   Sigma-side prep degraded ({type(exc).__name__}: "
                f"{str(exc)[:120]}) — later phases resolve inline"
            )

    def discover(self) -> tuple[dict[str, Any], list[Any], list[Any], dict[str, Any], dict[str, Any], list[Any]]:
        assert self.workdir
        self.header(1, "Discover")
        self.marked = time.monotonic()
        if self.args.from_discovery:
            source = Path(self.args.from_discovery).expanduser().resolve()
            for filename in (
                "script.qvs",
                "measures.json",
                "charts.json",
                "converter-input.json",
            ):
                if not (source / filename).is_file():
                    raise ValueError(
                        f"FATAL: --from-discovery dir missing {filename}"
                    )
            if source != self.workdir:
                protected = {
                    "bootstrap.json",
                    "connection.json",
                    "doctor.json",
                    "intake.json",
                    "phase6-success.json",
                    "run-state.json",
                }
                for item in source.iterdir():
                    if item.is_file() and item.name not in protected:
                        shutil.copy2(item, self.workdir / item.name)
            print(f"   reusing discovery artifacts from {source}")
        else:
            command = python_command(
                "qlik-discover.py",
                "--app",
                self.args.app,
                "--context",
                self.args.context,
                "--out",
                self.workdir,
                "--defer-snapshot",
            )
            lane = Lane(command, self.workdir / "phase1-discover.log")
            print(
                f"   Qlik discovery: BACKGROUND lane (pid {lane.process.pid}); "
                "Sigma-side prep runs concurrently."
            )
            if self.args.dry_run:
                print("   Sigma-side prep skipped (--dry-run)")
            else:
                self.sigma_prep()
            self.mark("phase1-prep(fg)")
            returncode = lane.join("discovery", 600)
            lane.print_log()
            if returncode:
                raise RuntimeError(
                    f"FATAL: qlik discovery failed (exit {returncode})"
                )
            self.timings["phase1-discovery(bg)"] = (
                (lane.ended or time.monotonic()) - lane.started
            )
            self.snapshot_lane = Lane(
                python_command(
                    "qlik-discover.py",
                    "--app",
                    self.args.app,
                    "--context",
                    self.args.context,
                    "--out",
                    self.workdir,
                    "--snapshot-only",
                ),
                self.workdir / "phase1-snapshot.log",
            )
            print(
                f"   engine-snapshot lane started "
                f"(pid {self.snapshot_lane.process.pid})"
            )
        self.mark("phase1")
        converter_input = load_json(self.workdir / "converter-input.json")
        charts = load_json(self.workdir / "charts.json")
        measures = load_json(self.workdir / "measures.json")
        app_meta = load_json(self.workdir / "app-meta.json", default={})
        snapshot = load_json(self.workdir / "snapshot.json", default={})
        sheets = load_json(self.workdir / "layout.json", default=[])
        return converter_input, charts, measures, app_meta, snapshot, sheets

    def convert(
        self, converter_input: dict[str, Any]
    ) -> tuple[dict[str, Any], Path]:
        assert self.workdir
        self.header(2, "Convert")
        raw_path = self.workdir / "converter-out.raw.json"
        output_path = self.workdir / "converter-out.json"
        if self.converter is None and (
            raw_path.is_file() or output_path.is_file()
        ):
            resume = raw_path if raw_path.is_file() else output_path
            print(f"   converter bundle not found — reusing {resume}")
            if resume != raw_path:
                shutil.copy2(resume, raw_path)
        elif self.converter is None:
            raise RuntimeError(
                "FATAL: no Qlik converter available and no converter-out.json present"
            )
        else:
            print(f"   converter: {self.converter} (no data leaves this machine)")
            shim = self.workdir / "_convert.mjs"
            specifier = (
                self.converter.as_uri()
                if os.name == "nt"
                else str(self.converter)
            )
            shim.write_text(
                "\n".join(
                    [
                        "import { readFileSync, writeFileSync } from 'node:fs';",
                        f"import {{ convertQlikToSigma }} from {json.dumps(specifier)};",
                        f"const model = JSON.parse(readFileSync({json.dumps(str(self.workdir / 'converter-input.json'))}, 'utf8'));",
                        "const out = convertQlikToSigma(model, "
                        + json.dumps(
                            {
                                "connectionId": self.args.conn,
                                "database": self.args.database,
                                "schema": self.args.schema,
                            }
                        )
                        + ");",
                        f"writeFileSync({json.dumps(str(raw_path))}, JSON.stringify(out, null, 2));",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            self.execute(["node", shim])
        self.execute(
            python_command(
                "normalize-qlik-expressions.py",
                "--input",
                self.workdir / "converter-input.json",
                "--converter-out",
                raw_path,
                "--out",
                output_path,
                "--formula-mapping",
                self.workdir / "formula-mapping.json",
            )
        )
        if not (self.workdir / "formula-mapping.json").is_file():
            raise RuntimeError("normalizer did not write formula-mapping.json")
        converted = load_json(output_path)
        security = converted.get("security") or []
        if self.args.security:
            override = load_json(
                Path(self.args.security).expanduser().resolve()
            )
            security = (
                override.get("security")
                if isinstance(override, dict)
                else override
            )
            if not isinstance(security, list):
                raise ValueError("--security must contain a security-rule array")
            converted["security"] = security
        (self.workdir / "security.json").write_text(
            json.dumps(
                {"security": security},
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        statistics = converted.get("stats") or {}
        warnings = converted.get("warnings") or []
        print(
            f"   {statistics.get('elements')} element(s), "
            f"{statistics.get('columns')} column(s), "
            f"{statistics.get('metrics')} metric(s), "
            f"{statistics.get('relationships')} relationship(s); "
            f"{len(warnings)} converter warning(s)"
        )
        if int(statistics.get("relationships") or 0) >= 2:
            print(
                "   MODELING ADVISORY: this join-heavy model may benefit from "
                "opt-in materialization after parity."
            )
        self.mark("phase2-convert")
        return converted, output_path

    def dm_reuse_scan(self) -> None:
        assert self.workdir
        self.header("2.5", "DM-reuse scan")
        if self.args.dry_run:
            print("   skipped (--dry-run: no Sigma access)")
        elif self.args.reuse_dm:
            print(
                f"   explicit --reuse-dm {self.args.reuse_dm} — scan skipped"
            )
        elif self.args.no_reuse:
            print("   --no-reuse — scan skipped, building new")
        else:
            signature = self.workdir / "dm-signature.json"
            self.execute(
                python_command(
                    "qlik-dm-signature.py",
                    "--model",
                    self.workdir / "converter-input.json",
                    "--database",
                    self.args.database,
                    "--schema",
                    self.args.schema,
                    "--out",
                    signature,
                )
            )
            command = python_command(
                "find_or_pick_dm.py",
                "--workbook-signature",
                signature,
                "--out",
                self.workdir / "dm-match.json",
                "--auto-pick",
                "--auto-pick-threshold",
                "0.5",
            )
            cache = self.workdir / "dm-specs-cache.json"
            if cache.is_file():
                command += ["--specs-cache", str(cache)]
            self.execute(command, check=False)
            match = load_json(self.workdir / "dm-match.json", default={})
            candidates = (match.get("candidates") or [])[:3]
            if match.get("auto_picked") and match.get("recommended_dm_id"):
                self.args.reuse_dm = match["recommended_dm_id"]
                print(f"   DM-REUSE (auto): {match.get('rationale')}")
                if match.get("warning"):
                    print(f"   WARNING: {match['warning']}")
            elif candidates:
                print(
                    "   top candidate(s) — default is BUILD NEW; "
                    "use --reuse-dm to opt in:"
                )
                for row in candidates:
                    print(
                        f"     score {float(row.get('score') or 0):.2f}  "
                        f"{row.get('dm_id')}  {row.get('dm_name')!r}"
                    )
            else:
                print("   no existing DM covers this app — building new")
        self.mark("phase2.5-dm-scan")

    def decisions(
        self,
        app_name: str,
        converted: dict[str, Any],
        app_meta: dict[str, Any],
        real_charts: list[dict[str, Any]],
    ) -> int | None:
        assert self.workdir
        questions: list[dict[str, Any]] = []
        for warning in converted.get("warnings") or []:
            if not DEGRADE_RE.search(str(warning)):
                continue
            detail = " ".join(str(warning).split())
            match = re.search(r'"([^"]+)"', detail)
            questions.append(
                {
                    "id": "measure_no_sigma_equiv",
                    "severity": "review",
                    "measure": match.group(1) if match else None,
                    "detail": detail,
                    "options": [
                        "proceed (measure best-effort/dropped; original Qlik expr kept in DM description)",
                        "abort and re-author this measure manually",
                    ],
                    "default": "proceed (measure best-effort/dropped; original Qlik expr kept in DM description)",
                }
            )
        try:
            load_script = (self.workdir / "script.qvs").read_text(
                encoding="utf-8-sig"
            )
        except OSError:
            load_script = ""
        has_section_access = (
            app_meta.get("hasSectionAccess") is True
            or re.search(r"(?im)^\s*SECTION\s+ACCESS\s*;", load_script)
            is not None
            or bool(converted.get("security") or [])
        )
        if has_section_access:
            questions.append(
                {
                    "id": "section_access",
                    "severity": "required",
                    "detail": (
                        "Qlik app uses Section Access. Port security with "
                        "apply_sigma_rls.py after model creation."
                    ),
                    "options": [
                        "proceed (migrate now; port security via apply_sigma_rls.py after)",
                        "abort until security is designed",
                    ],
                    "default": "abort until security is designed",
                }
            )
        if app_meta.get("isDirectQueryMode") is True:
            questions.append(
                {
                    "id": "directquery_mode",
                    "severity": "review",
                    "detail": "Confirm Sigma uses the same live warehouse.",
                    "options": [
                        f"proceed (Sigma --connection {self.args.conn} IS the same warehouse)",
                        "abort and repoint the connection",
                    ],
                    "default": f"proceed (Sigma --connection {self.args.conn} IS the same warehouse)",
                }
            )
        for chart in real_charts:
            visual_type = chart.get("vizType")
            if visual_type in NATIVE or visual_type in SKIP_KINDS:
                continue
            questions.append(
                {
                    "id": "chart_no_native_kind",
                    "severity": "review",
                    "visual": chart.get("title") or chart.get("id"),
                    "qlik_type": visual_type,
                    "detail": f"Qlik {visual_type!r} has no native Sigma kind",
                    "options": [
                        "approximate-to-bar",
                        "abort and redesign this chart",
                    ],
                    "default": "approximate-to-bar",
                }
            )
        if not self.args.folder and not self.args.dry_run:
            resolved = (
                f"{self.prep.get('folder_name')!r} "
                f"({self.prep.get('folder_id')})"
                if self.prep.get("folder_id")
                else "the first editable folder"
            )
            questions.append(
                {
                    "id": "folder",
                    "severity": "required",
                    "detail": f"No --folder supplied; content lands in {resolved}.",
                    "options": [
                        "supply --folder <id>",
                        "proceed into auto-resolved folder",
                    ],
                    "default": "proceed into auto-resolved folder",
                }
            )
        answers = None
        if self.args.answers:
            try:
                answers = json.loads(self.args.answers)
            except json.JSONDecodeError as exc:
                raise ValueError("FATAL: --answers is not valid JSON") from exc
        scout_questions = [
            row for row in questions if row["id"] == "measure_no_sigma_equiv"
        ]
        gap_ids = list(
            dict.fromkeys(
                "measure:"
                + str(
                    row.get("measure")
                    or re.sub(r"\s+", " ", row["detail"])[:80]
                )
                for row in scout_questions
            )
        )
        if gap_ids:
            buckets = classify_scouts(str(self.workdir), gap_ids)
            if buckets["unscouted"] and (self.args.yes or answers is not None):
                print(
                    f"   gap-scout: {len(buckets['unscouted'])} untranslated "
                    "measure(s) accepted for unattended run",
                    file=sys.stderr,
                )
                for gap_id in buckets["unscouted"]:
                    record_scout(
                        str(self.workdir),
                        gap_id=gap_id,
                        feature="measure",
                        status="accepted",
                    )
            elif buckets["unscouted"]:
                print("\n-------------------- GAP-SCOUT RECOMMENDED --------------------")
                for gap_id in buckets["unscouted"]:
                    print(f"  --gap-id {gap_id!r}")
                print("---------------------------------------------------------------")
        if questions and not self.args.yes and answers is None:
            print("\n==================== OPEN QUESTIONS ====================")
            print(
                json.dumps(
                    {
                        "status": "decisions_needed",
                        "app": app_name,
                        "phases_completed": ["1 Discover", "2 Convert"],
                        "note": (
                            "Re-run with --yes to accept defaults, or "
                            "--answers JSON to override."
                        ),
                        "open_questions": questions,
                    },
                    indent=2,
                )
            )
            print("=======================================================")
            print(
                f"\n{len(questions)} decision(s) need a human. "
                "No Sigma objects were created."
            )
            if self.snapshot_lane and not self.snapshot_lane.done():
                self.snapshot_lane.join("snapshot", 300)
            return 10
        if questions:
            print(
                f"\n   decisions auto-resolved "
                f"({'--yes: defaults' if self.args.yes else '--answers supplied'}):"
            )
            for question in questions:
                chosen = (answers or {}).get(question["id"], question["default"])
                if chosen not in question["options"]:
                    raise ValueError(
                        f"invalid answer for {question['id']!r}: {chosen!r}; "
                        f"choose one of {question['options']!r}"
                    )
                label = question.get("measure") or question.get("visual")
                print(
                    f"     - {question['id']}"
                    f"{f' [{label}]' if label else ''}: {chosen}"
                )
                if str(chosen).startswith("abort"):
                    print(
                        f"   {question['id']!r} answered abort — stopping "
                        "before Sigma object creation."
                    )
                    if self.snapshot_lane:
                        self.snapshot_lane.join("snapshot", 300)
                    return 10
        else:
            print("   no open questions — running straight through")
        return None

    def build(
        self,
        converted_path: Path,
        measures: list[Any],
        base_name: str,
        sheets: list[Any],
    ) -> tuple[dict[str, Any], dict[str, Any], str | None]:
        assert self.workdir
        self.header(3, "Build data model")
        reconcile = self.workdir / "reconcile.json"
        self.execute(
            python_command(
                "reconcile-columns.py",
                "--script",
                self.workdir / "script.qvs",
                "--out",
                reconcile,
            )
        )
        if not self.args.dry_run:
            sigma_rest.auth_token()
            resolved = self.workdir / "reconcile-resolved.json"
            self.execute(
                python_command(
                    "preflight_warehouse.py",
                    "--reconcile",
                    reconcile,
                    "--connection",
                    self.args.conn,
                    "--database",
                    self.args.database,
                    "--schema",
                    self.args.schema,
                    "--out",
                    resolved,
                    "--report",
                    self.workdir / "warehouse-preflight.json",
                )
            )
            reconcile = resolved
        else:
            print(
                "   warehouse catalog preflight skipped "
                "(--dry-run: no Sigma API)"
            )
        denorm = self.workdir / "denorm.json"
        self.execute(
            python_command(
                "gen-denorm-sql.py",
                "--reconcile",
                reconcile,
                "--database",
                self.args.database,
                "--schema",
                self.args.schema,
                "--connection",
                self.args.conn,
                "--out",
                denorm,
            )
        )
        reuse_element, reuse_star_count = None, 0
        if self.args.reuse_dm and not self.args.dry_run:
            response = sigma_rest.request(
                "get", f"/v2/dataModels/{self.args.reuse_dm}/elements"
            ) or {}
            elements = response.get("entries") or []
            custom_sql = next(
                (row for row in elements if row.get("name") == "Custom SQL"),
                None,
            )
            reuse_element = (
                custom_sql.get("elementId") or custom_sql.get("id")
                if custom_sql
                else None
            )
            if reuse_element:
                reuse_star_count = max(len(elements) - 1, 0)
            else:
                print(
                    f"   WARNING: reuse DM {self.args.reuse_dm} has no "
                    "'Custom SQL' denorm element — building fresh"
                )
                self.args.reuse_dm = None
        dm_command = python_command(
            "build-sigma-dm.py",
            "--converter-out",
            converted_path,
            "--reconcile",
            reconcile,
            "--denorm",
            denorm,
            "--measures",
            self.workdir / "measures.json",
            "--name",
            f"{base_name} (Qlik→Sigma)",
            "--spec-out",
            self.workdir / "dm-spec.json",
        )
        folder = self.args.folder or self.prep.get("folder_id")
        if folder:
            dm_command += ["--folder", str(folder)]
        if reuse_element:
            candidate = {
                "dataModelId": self.args.reuse_dm,
                "denormElementId": reuse_element,
                "folderId": folder,
                "starElements": reuse_star_count,
                "metricsKept": None,
                "metricsDropped": [],
                "reused": True,
            }
        else:
            self.execute(
                dm_command
                + [
                    "--out",
                    str(self.workdir / "dm-preflight-result.json"),
                    "--dry-run",
                ]
            )
            candidate = load_json(self.workdir / "dm-preflight-result.json")
        preflight_workbook = python_command(
            "build-sigma-workbook.py",
            "--charts",
            self.workdir / "charts.json",
            "--layout",
            self.workdir / "layout.json",
            "--denorm",
            denorm,
            "--dm-id",
            candidate.get("dataModelId") or "PREWRITE-DM",
            "--denorm-element-id",
            candidate.get("denormElementId"),
            "--name",
            f"{base_name} → Sigma",
            "--out",
            self.workdir / "wb-preflight-result.json",
            "--spec-out",
            self.workdir / "wb-preflight-spec.json",
            "--layout-out",
            self.workdir / "layout-preflight.xml",
            "--element-map",
            self.workdir / "element-map-preflight.json",
            "--control-scope-out",
            self.workdir / "control-scope-preflight.json",
            "--coverage-out",
            self.workdir / "workbook-coverage.json",
            "--dry-run",
        )
        if not reuse_element:
            preflight_workbook += [
                "--dm-spec",
                str(self.workdir / "dm-spec.json"),
            ]
        preflight_folder = folder or candidate.get("folderId")
        if preflight_folder:
            preflight_workbook += ["--folder", str(preflight_folder)]
        self.execute(preflight_workbook)
        self.execute(
            python_command(
                "preflight_lint.py",
                self.workdir / "wb-preflight-spec.json",
                self.workdir / "control-scope-preflight.json",
            )
        )
        self.execute(
            python_command(
                "render_integrity.py",
                "--spec",
                self.workdir / "wb-preflight-spec.json",
                "--out",
                self.workdir / "blank-risk-preflight.json",
            )
        )
        coverage = load_json(self.workdir / "workbook-coverage.json")
        print(
            f"   ✓ pre-write source coverage: "
            f"{coverage.get('queryableElements')}/"
            f"{coverage.get('sourceVisuals')} queryable visual(s)"
        )
        if reuse_element:
            dm_result = candidate
            dm_id = self.args.reuse_dm
            print(
                f"   REUSING DM {dm_id} · denorm element "
                f"'Custom SQL' ({reuse_element})"
            )
        elif self.args.dry_run:
            dm_result = candidate
            shutil.copy2(
                self.workdir / "dm-preflight-result.json",
                self.workdir / "dm-result.json",
            )
            dm_id = None
        else:
            self.execute(
                dm_command
                + ["--out", str(self.workdir / "dm-result.json")]
            )
            dm_result = load_json(self.workdir / "dm-result.json")
            dm_id = dm_result.get("dataModelId")
        if not self.args.dry_run and dm_id:
            (self.workdir / "dm-ids.json").write_text(
                json.dumps({"dataModelId": dm_id}, indent=2) + "\n",
                encoding="utf-8",
            )
            readback = sigma_rest.request(
                "get", f"/v2/dataModels/{dm_id}/spec"
            )
            (self.workdir / "datamodel-readback.json").write_text(
                json.dumps(readback, indent=2) + "\n", encoding="utf-8"
            )
        print(
            f"   dataModelId = {dm_id or '(dry-run)'}  "
            f"denorm element {dm_result.get('denormElementId')}  "
            f"{dm_result.get('starElements')} star element(s), "
            f"{dm_result.get('metricsKept')} metric(s)"
        )
        self.mark("phase3-dm")
        self.header(4, "Build workbook")
        workbook_command = python_command(
            "build-sigma-workbook.py",
            "--charts",
            self.workdir / "charts.json",
            "--layout",
            self.workdir / "layout.json",
            "--denorm",
            denorm,
            "--dm-id",
            dm_id or "DRY-RUN",
            "--denorm-element-id",
            dm_result.get("denormElementId"),
            "--name",
            f"{base_name} → Sigma",
            "--out",
            self.workdir / "wb-result.json",
            "--spec-out",
            self.workdir / "wb-spec.json",
            "--layout-out",
            self.workdir / "layout.xml",
            "--element-map",
            self.workdir / "element-map.json",
            "--control-scope-out",
            self.workdir / "control-scope.json",
            "--coverage-out",
            self.workdir / "workbook-coverage.json",
        )
        if not reuse_element:
            workbook_command += [
                "--dm-spec",
                str(self.workdir / "dm-spec.json"),
            ]
        workbook_folder = folder or dm_result.get("folderId")
        if workbook_folder:
            workbook_command += ["--folder", str(workbook_folder)]
        self.execute(workbook_command + ["--dry-run"])
        self.execute(
            python_command(
                "render_integrity.py",
                "--spec",
                self.workdir / "wb-spec.json",
                "--out",
                self.workdir / "blank-risk-elements.json",
            )
        )
        if not self.args.dry_run:
            self.execute(workbook_command)
        workbook_result = load_json(self.workdir / "wb-result.json")
        workbook_id = workbook_result.get("workbookId")
        if not self.args.dry_run:
            with (self.workdir / "posted-workbooks.jsonl").open(
                "a", encoding="utf-8"
            ) as handle:
                handle.write(
                    json.dumps(
                        {"id": workbook_id, "name": f"{base_name} → Sigma"}
                    )
                    + "\n"
                )
            (self.workdir / "wb-ids.json").write_text(
                json.dumps({"workbookId": workbook_id}, indent=2) + "\n",
                encoding="utf-8",
            )
        print(
            f"   workbookId = {workbook_id or '(dry-run)'} "
            f"({workbook_result.get('pages')} page(s), "
            f"{workbook_result.get('elements')} element(s), "
            f"{workbook_result.get('queryableElements')} queryable, "
            f"{workbook_result.get('kpis')} KPI(s), "
            f"{workbook_result.get('controls') or 0} control(s))"
        )
        self.mark("phase4-wb")
        self.header(5, "Layout")
        if self.args.dry_run:
            print(
                f"   DRY RUN: layout XML -> {self.workdir / 'layout.xml'} "
                f"(from {len(sheets)} Qlik sheet grid(s))"
            )
        else:
            self.execute(
                python_command(
                    "put_layout.py",
                    "--workbook",
                    workbook_id,
                    "--layout",
                    self.workdir / "layout.xml",
                )
            )
            print(
                f"   layout applied ({len(sheets)} Qlik sheet grid(s) "
                "→ 24-col Sigma grid)"
            )
        self.mark("phase5-layout")
        return dm_result, workbook_result, dm_id

    def render_pages(self, workbook_id: str) -> Path | None:
        assert self.workdir
        directory = self.workdir / "visual-qa"
        if directory.exists():
            shutil.rmtree(directory)
        directory.mkdir(parents=True, exist_ok=True)
        live = sigma_rest.request(
            "get", f"/v2/workbooks/{workbook_id}/spec"
        ) or {}
        document_version = live.get("latestDocumentVersion") or live.get(
            "latestVersion"
        )
        if document_version in (None, ""):
            raise RuntimeError("live workbook spec has no document version before render")
        spec = load_json(self.workdir / "wb-spec.json")
        content_pages = [
            page
            for page in document(spec).get("pages") or []
            if isinstance(page, dict) and is_content_page(page)
        ]
        rendered = []
        for page in content_pages:
            output = directory / f"{page.get('id')}.png"
            result = self.execute(
                python_command(
                    "sigma-export-png.py",
                    "--workbook",
                    workbook_id,
                    "--page",
                    page.get("id"),
                    "--out",
                    output,
                    "--w",
                    "1800",
                    "--h",
                    "1000",
                ),
                check=False,
            )
            if result.returncode == 0:
                rendered.append(output)
            else:
                print(
                    f"   [warn] visual-QA render failed for page {page.get('id')}"
                )
        print(
            f"   ✓ rendered {len(rendered)}/{len(content_pages)} "
            f"full-page PNG(s) for visual QA → {directory}"
        )
        (self.workdir / "render-evidence.json").write_text(
            json.dumps(
                {
                    "workbookId": workbook_id,
                    "documentVersion": str(document_version),
                    "run_id": self.run_id,
                    "generatedAt": utc_now(),
                    "images": [
                        {
                            "path": str(path.resolve()),
                            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        }
                        for path in rendered
                    ],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        return rendered[0] if rendered else None

    def qlik_eval(self, expression: str) -> str | None:
        if not self.args.app:
            return None
        result = subprocess.run(
            [
                os.environ.get("QLIK_BIN", "qlik"),
                "app",
                "eval",
                expression,
                "-a",
                self.args.app,
                "--context",
                self.args.context,
            ],
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode:
            return None
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        return lines[1] if len(lines) > 1 else None

    @staticmethod
    def numeric(value: Any) -> float | None:
        if value is None:
            return None
        raw = str(value).strip()
        is_percent = raw.endswith("%")
        text = re.sub(r"[$,%\s]", "", raw)
        try:
            number = float(text)
            return number / 100.0 if is_percent else number
        except ValueError:
            return None

    @classmethod
    def canonical_chart_rows(
        cls, rows: Any, dimension_count: int
    ) -> list[tuple[Any, ...]]:
        normalized = []
        for raw_row in rows or []:
            if not isinstance(raw_row, list):
                continue
            row = []
            for index, value in enumerate(raw_row):
                if index < dimension_count:
                    row.append(("text", str(value or "").strip()))
                    continue
                number = cls.numeric(value)
                row.append(
                    ("number", round(number, 9))
                    if number is not None
                    else ("text", str(value or "").strip())
                )
            normalized.append(tuple(row))
        return sorted(normalized, key=repr)

    @classmethod
    def numbers_match(cls, source: Any, target: Any) -> bool:
        source_number = cls.numeric(source)
        target_number = cls.numeric(target)
        if source_number is None or target_number is None:
            return str(source or "").strip() == str(target or "").strip()
        raw = str(target).strip().replace(",", "").replace("$", "")
        is_percent = raw.endswith("%")
        raw = raw.rstrip("%")
        decimals = len(raw.split(".", 1)[1]) if "." in raw else 0
        tolerance = 0.5 * (10 ** -decimals)
        if is_percent:
            tolerance /= 100.0
        tolerance += max(abs(source_number), abs(target_number)) * 1e-6
        return abs(source_number - target_number) <= tolerance

    @classmethod
    def chart_rows_match(
        cls,
        source_rows: Any,
        target_rows: Any,
        dimension_count: int,
    ) -> bool:
        source = [
            row for row in source_rows or [] if isinstance(row, list)
        ]
        target = [
            row for row in target_rows or [] if isinstance(row, list)
        ]
        source.sort(
            key=lambda row: repr(
                tuple(str(value or "").strip() for value in row[:dimension_count])
            )
        )
        target.sort(
            key=lambda row: repr(
                tuple(str(value or "").strip() for value in row[:dimension_count])
            )
        )
        if len(source) != len(target):
            return False
        for left, right in zip(source, target):
            if len(left) != len(right):
                return False
            if any(
                str(left[index] or "").strip()
                != str(right[index] or "").strip()
                for index in range(dimension_count)
            ):
                return False
            if any(
                not cls.numbers_match(left[index], right[index])
                for index in range(dimension_count, len(left))
            ):
                return False
        return True

    def export_elements(
        self, workbook_id: str, element_map: list[dict[str, Any]]
    ) -> dict[str, str]:
        exports = []
        for element in element_map:
            try:
                response = sigma_rest.request(
                    "post",
                    f"/v2/workbooks/{workbook_id}/export",
                    body=json.dumps(
                        {
                            "elementId": element.get("elementId"),
                            "format": {"type": "csv"},
                        }
                    ),
                ) or {}
            except sigma_rest.SigmaError:
                response = {}
            exports.append((element, response.get("queryId")))
        output: dict[str, str] = {}
        deadline = time.monotonic() + 240
        for element, query_id in exports:
            if not query_id:
                continue
            while time.monotonic() <= deadline:
                try:
                    body = sigma_rest.request(
                        "get",
                        f"/v2/query/{query_id}/download",
                        accept="text/csv",
                    )
                    if body:
                        output[str(element.get("elementId"))] = str(body)
                        break
                except sigma_rest.SigmaError:
                    pass
                time.sleep(2)
        return output

    def parity(
        self,
        workbook_result: dict[str, Any],
        dm_id: str,
        app_meta: dict[str, Any],
        snapshot: dict[str, Any],
        charts: list[dict[str, Any]],
        coverage: dict[str, Any],
    ) -> tuple[bool, bool, bool, bool, dict[str, Any]]:
        assert self.workdir
        workbook_id = workbook_result["workbookId"]
        self.header(6, "Parity")
        if self.snapshot_lane:
            returncode = self.snapshot_lane.join("snapshot", 300)
            self.timings["snapshot-lane(bg)"] = (
                (self.snapshot_lane.ended or time.monotonic())
                - self.snapshot_lane.started
            )
            if returncode == 0:
                snapshot = load_json(self.workdir / "snapshot.json", default={})
                print(
                    f"   engine-snapshot lane joined: "
                    f"{len(snapshot.get('kpis') or [])} KPI(s), "
                    f"{len(snapshot.get('buckets') or [])} bucket count(s)"
                )
            else:
                self.snapshot_lane.print_log()
                print("   snapshot lane FAILED — using live eval fallbacks")
        entries = sigma_entries(f"/v2/workbooks/{workbook_id}/columns")
        errors = [
            row for row in entries if (row.get("type") or {}).get("type") == "error"
        ]
        (self.workdir / "column-scan.json").write_text(
            json.dumps(
                {
                    "status": "complete-clean" if not errors else "complete-errors",
                    "columns_read": len(entries),
                    "errors": errors,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        print(
            f"   columns: {len(entries) - len(errors)}/{len(entries)} resolve"
        )
        element_map = load_json(self.workdir / "element-map.json")
        csv_by_element = self.export_elements(workbook_id, element_map)
        reload_time = app_meta.get("lastReloadTime")
        stale_days = None
        if reload_time:
            try:
                loaded = datetime.fromisoformat(str(reload_time).replace("Z", "+00:00"))
                stale_days = (
                    datetime.now(timezone.utc) - loaded.astimezone(timezone.utc)
                ).total_seconds() / 86400
            except ValueError:
                pass
        snapshot_kpis = {
            row.get("expr"): row.get("value")
            for row in snapshot.get("kpis") or []
        }
        kpi_results, kpi_rows = [], []
        actuals: dict[str, list[list[str]]] = {}
        actuals_by_source: dict[str, list[list[str]]] = {}
        for element in element_map:
            body = csv_by_element.get(str(element.get("elementId")), "")
            parsed = list(csv.reader(body.splitlines())) if body else []
            data_rows = parsed[1:] if parsed else []
            actuals[str(element.get("name") or element.get("elementId"))] = data_rows
            source_object_id = str(
                (element.get("qlik") or {}).get("objectId") or ""
            )
            if source_object_id:
                actuals_by_source[source_object_id] = data_rows
            if element.get("kind") not in {"kpi-chart", "progress"}:
                continue
            expressions = (element.get("qlik") or {}).get("measures") or []
            expression = (expressions or [None])[0]
            qlik_value = snapshot_kpis.get(expression)
            if qlik_value is None and expression:
                qlik_value = self.qlik_eval(expression)
            sigma_value = data_rows[0][0] if data_rows and data_rows[0] else None
            qlik_number, sigma_number = (
                self.numeric(qlik_value),
                self.numeric(sigma_value),
            )
            printed_decimals = None
            if sigma_value is not None:
                printed = re.fullmatch(
                    r"\s*-?\d+\.(\d+)\s*", str(sigma_value)
                )
                printed_decimals = len(printed.group(1)) if printed else None
            rounded_match = bool(
                qlik_number is not None
                and sigma_number is not None
                and printed_decimals is not None
                and abs(round(qlik_number, printed_decimals) - sigma_number)
                <= 1e-9
            )
            if (
                qlik_number is not None
                and sigma_number is not None
                and (
                    abs(qlik_number - sigma_number)
                    <= max(abs(qlik_number), abs(sigma_number)) * 1e-6 + 1e-9
                    or rounded_match
                )
            ):
                state = "MATCH"
            elif (
                qlik_number is not None
                and sigma_number is not None
                and stale_days is not None
                and stale_days >= 1
            ):
                state = "STALE-EXPLAINED"
            else:
                state = "DIVERGENT"
            if len(expressions) > 1:
                state = "SECONDARY-MEASURE-UNBUILT"
            kpi_results.append(state)
            kpi_rows.append(
                {
                    "chart": str(element.get("name") or ""),
                    "source_object_id": (element.get("qlik") or {}).get("objectId"),
                    "kind": element.get("kind"),
                    "qlik_value": qlik_value,
                    "sigma_value": sigma_value,
                    "status": state,
                    "pass": state == "MATCH",
                }
            )
        snapshot_buckets = {
            row.get("expr"): row.get("value")
            for row in snapshot.get("buckets") or []
        }
        snapshot_chart_data = {
            str(row.get("objectId")): row
            for row in snapshot.get("chartData") or []
            if isinstance(row, dict) and row.get("objectId")
        }
        bucket_rows = []
        for element in element_map:
            if element.get("kind") in {"kpi-chart", "progress"}:
                continue
            dimensions = (element.get("qlik") or {}).get("dims") or []
            if not dimensions:
                continue
            expression = (
                f"Count(distinct [{dimensions[0]}])"
                if len(dimensions) == 1
                else "Count(distinct "
                + "&'|'&".join(f"[{item}]" for item in dimensions)
                + ")"
            )
            qlik_value = snapshot_buckets.get(expression)
            if qlik_value is None:
                qlik_value = self.qlik_eval(expression)
            qlik_count = self.numeric(qlik_value)
            qlik_count = int(qlik_count) if qlik_count is not None else None
            body = csv_by_element.get(str(element.get("elementId")), "")
            parsed = list(csv.reader(body.splitlines())) if body else []
            sigma_rows = parsed[1:] if parsed else []
            sigma_count = len(sigma_rows) if body else None
            object_id = str((element.get("qlik") or {}).get("objectId") or "")
            source_data = snapshot_chart_data.get(object_id)
            pivot_data = bool(source_data and source_data.get("pivot") is True)
            if pivot_data:
                # Pivot qData omits a flat coordinate binding between qLeft/qTop
                # hierarchy cells and Sigma's exported grid. A numeric multiset
                # can hide swapped row/column associations, so remain fail-closed
                # until an axis-aware oracle is supplied.
                full_rows_match = False
            else:
                full_rows_match = bool(
                    source_data
                    and source_data.get("complete") is True
                    and self.chart_rows_match(
                        source_data.get("rows"),
                        sigma_rows,
                        int(
                            source_data.get("dimensionCount")
                            or len(dimensions)
                        ),
                    )
                )
            if (
                (pivot_data or (
                    qlik_count is not None
                    and sigma_count == qlik_count
                ))
                and full_rows_match
            ):
                state = "MATCH"
            elif not source_data or source_data.get("complete") is not True:
                state = "SOURCE-DATA-MISSING"
            elif pivot_data:
                state = "PIVOT-UNVERIFIED"
            elif qlik_count is None or sigma_count is None:
                state = "NO-DATA"
            elif qlik_count != sigma_count:
                state = "BUCKET-MISMATCH"
            else:
                state = "VALUE-MISMATCH"
            bucket_rows.append(
                {
                    "chart": str(element.get("name") or ""),
                    "source_object_id": (element.get("qlik") or {}).get("objectId"),
                    "kind": element.get("kind"),
                    "qlik_buckets": qlik_count,
                    "sigma_buckets": sigma_count,
                    "qlik_rows": (
                        len(source_data.get("rows") or [])
                        if source_data
                        else 0
                    ),
                    "status": state,
                    "pass": state == "MATCH",
                }
            )
        chart_rows = kpi_rows + bucket_rows
        source_oracle_available = bool(
            self.args.app
            or (snapshot.get("kpis") or [])
            or (snapshot.get("buckets") or [])
        )
        strict_parity = source_oracle_available
        parity_mode = "live-engine"
        verified_against = "qlik-engine"
        if not source_oracle_available:
            warehouse_rows = []
            error_cell = re.compile(
                r"^\s*(?:Invalid Query|Error\b|#REF|#ERROR|#VALUE|#NAME)",
                re.I,
            )
            for element in element_map:
                body = csv_by_element.get(str(element.get("elementId")), "")
                parsed = list(csv.reader(body.splitlines())) if body else []
                data_rows = parsed[1:] if parsed else []
                bad_cell = next(
                    (
                        cell
                        for row in data_rows
                        for cell in row
                        if error_cell.search(str(cell or ""))
                    ),
                    None,
                )
                has_value = any(
                    str(cell or "").strip()
                    for row in data_rows
                    for cell in row
                )
                passed = bool(data_rows and has_value and bad_cell is None)
                warehouse_rows.append(
                    {
                        "chart": str(
                            element.get("name") or element.get("elementId") or ""
                        ),
                        "source_object_id": (element.get("qlik") or {}).get(
                            "objectId"
                        ),
                        "kind": element.get("kind"),
                        "warehouse_rows": len(data_rows),
                        "status": (
                            "WAREHOUSE-PASS"
                            if passed
                            else "QUERY-ERROR"
                            if bad_cell is not None
                            else "NO-DATA"
                        ),
                        "pass": passed,
                    }
                )
            chart_rows = warehouse_rows
            parity_mode = "warehouse"
            verified_against = "warehouse-executability"
            if self.args.warehouse_expected:
                expected = load_json(
                    Path(self.args.warehouse_expected).expanduser().resolve()
                )
                if not isinstance(expected, dict):
                    raise ValueError("--warehouse-expected must contain a JSON object")

                def normalized_rows(rows: Any) -> list[list[str]]:
                    return [
                        [str(cell) for cell in row]
                        for row in rows or []
                        if isinstance(row, list)
                    ]

                compared_rows = []
                for element in element_map:
                    name = str(
                        element.get("name") or element.get("elementId") or ""
                    )
                    source_object_id = str(
                        (element.get("qlik") or {}).get("objectId") or ""
                    )
                    actual_rows = normalized_rows(
                        actuals_by_source.get(source_object_id)
                    )
                    expected_rows = normalized_rows(
                        expected.get(source_object_id)
                    )
                    matched = bool(expected_rows) and actual_rows == expected_rows
                    compared_rows.append(
                        {
                            "chart": name,
                            "source_object_id": source_object_id,
                            "kind": element.get("kind"),
                            "expected_rows": len(expected_rows),
                            "actual_rows": len(actual_rows),
                            "status": "MATCH" if matched else "MISMATCH",
                            "pass": matched,
                        }
                    )
                unexpected = sorted(
                    set(expected)
                    - {row["source_object_id"] for row in compared_rows}
                )
                if unexpected:
                    raise ValueError(
                        "--warehouse-expected contains unknown chart(s): "
                        + ", ".join(unexpected)
                    )
                chart_rows = compared_rows
                strict_parity = True
                parity_mode = "warehouse-expected"
                verified_against = "independent-warehouse-expected"
        failed_rows = [row for row in chart_rows if not row["pass"]]
        parity_ok = (
            not errors
            and bool(entries)
            and bool(chart_rows)
            and not failed_rows
            and strict_parity
        )
        source_ids = [str(item) for item in coverage.get("sourceVisualIds") or []]
        built_ids = [
            str(item) for item in coverage.get("builtSourceVisualIds") or []
        ]
        names = {
            str(row.get("id")): str(row.get("title") or row.get("id"))
            for row in charts
        }
        unmatched = [item for item in source_ids if item not in built_ids]
        parity_final = {
            "schema_version": 1,
            "source": "qlik",
            "status": (
                "PASS"
                if parity_ok
                else "WAREHOUSE-ONLY"
                if parity_mode == "warehouse" and not failed_rows
                else "FAIL"
            ),
            "strict": strict_parity,
            "mode": parity_mode,
            "verified_against": verified_against,
            "charts_total": len(chart_rows),
            "charts_pass": sum(row["pass"] for row in chart_rows),
            "charts_fail": len(failed_rows),
            "charts_stale_explained": sum(
                row["status"] == "STALE-EXPLAINED" for row in chart_rows
            ),
            "fail_names": sorted({row["chart"] for row in failed_rows}),
            "pending_names": [],
            "divergent": bool(failed_rows),
            "per_chart": chart_rows,
            "column_errors": [
                {
                    "element_id": row.get("elementId"),
                    "label": row.get("label"),
                    "formula": row.get("formula"),
                }
                for row in errors
            ],
            "tile_census": {
                "zones_total": len(source_ids),
                "charts_built": len(built_ids),
                "zones_unmatched": len(unmatched),
                "unmatched_zone_names": sorted(
                    names.get(item, item) for item in unmatched
                ),
            },
            "generated_at": utc_now(),
        }
        if parity_mode == "warehouse":
            parity_final["note"] = (
                "Offline source mode: every built element was verified to "
                "evaluate against the live Sigma warehouse and return real "
                "data, but values were not diffed against an independent "
                "source or warehouse-expected artifact. Completion remains RED."
            )
        (self.workdir / "parity-final.json").write_text(
            json.dumps(parity_final, indent=2) + "\n", encoding="utf-8"
        )
        (self.workdir / "parity-actuals.json").write_text(
            json.dumps(actuals, indent=2) + "\n", encoding="utf-8"
        )
        if (self.workdir / "source-anchors.json").is_file():
            self.execute(
                python_command(
                    "verify_anchors.py",
                    "--workdir",
                    self.workdir,
                    "--actuals",
                    self.workdir / "parity-actuals.json",
                ),
                check=False,
            )
        live = sigma_rest.request(
            "get", f"/v2/workbooks/{workbook_id}/spec"
        ) or {}
        live_spec = {**metadata(live), **document(live)}
        (self.workdir / "wb-readback.json").write_text(
            json.dumps(live, indent=2) + "\n", encoding="utf-8"
        )
        trellis_sidecar = self.workdir / "native-trellis-emitted.json"
        if trellis_sidecar.is_file():
            self.execute(
                python_command(
                    "verify_trellis_survived.py",
                    "--emitted",
                    trellis_sidecar,
                    "--spec",
                    self.workdir / "wb-readback.json",
                )
            )
        if self.args.skip_layout_lint:
            layout_violations = []
            print("     [SKIP] --skip-layout-lint")
        else:
            layout_violations = layout_lint.lint(live_spec)
        layout_ok = not layout_violations
        (self.workdir / "layout-lint.json").write_text(
            json.dumps(
                {
                    "status": "PASS" if layout_ok else "FAIL",
                    "violations": layout_violations,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        scope = load_json(self.workdir / "control-scope.json", default=None)
        control_violations = control_lint.lint(live_spec, scope)
        control_rows = control_lint.controls_report(live_spec)
        control_ok = not control_violations
        (self.workdir / "control-lint.json").write_text(
            json.dumps(
                {
                    "status": "PASS" if control_ok else "FAIL",
                    "controls_checked": len(control_rows),
                    "violations": control_violations,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        flip_ok = True
        if self.args.skip_control_flip:
            print(
                f"     [WAIVED] "
                f"{'(no reason given)' if self.args.skip_control_flip is True else self.args.skip_control_flip}"
            )
        elif not control_rows:
            print("     [OK] no controls — nothing to flip-test")
        else:
            probe = self.execute(
                python_command(
                    "probe_controls.py",
                    "--workbook-id",
                    workbook_id,
                    "--out",
                    self.workdir / "probe-controls",
                ),
                check=False,
            )
            results = load_json(
                self.workdir / "probe-controls" / "probe-results.json",
                default=None,
            )
            decision, information = flip_gate.decide(probe.returncode, results)
            if information["skips"]:
                (self.workdir / "control-flip-unverified.json").write_text(
                    json.dumps(
                        {
                            "workbookId": workbook_id,
                            "status": "ADVISORY",
                            "unprobed": [
                                {"control": control, "reason": note}
                                for control, note in information["skips"]
                            ],
                            "generatedAt": utc_now(),
                        },
                        indent=2,
                    )
                    + "\n",
                    encoding="utf-8",
                )
            if decision in {"fail", "error"}:
                flip_ok = False
                print(
                    f"     [FAIL] control flip gate: {decision}; "
                    f"{len(information['fails'])} failure(s)"
                )
            elif decision == "advisory":
                print("     [WARN] no control auto-probeable")
            else:
                print(
                    f"     [OK] {len(information['passes'])} control(s) proven live"
                )
        self.mark("phase6-parity")
        return parity_ok, layout_ok, control_ok, flip_ok, parity_final

    def terminal(
        self,
        workbook_result: dict[str, Any],
        dm_id: str,
        parity_ok: bool,
        layout_ok: bool,
        control_ok: bool,
        flip_ok: bool,
        render_png: Path | None,
    ) -> int:
        assert self.workdir
        workbook_id = workbook_result["workbookId"]
        queryable = int(workbook_result.get("queryableElements") or 0)
        mechanical_ok = (
            parity_ok
            and layout_ok
            and control_ok
            and flip_ok
            and queryable > 0
            and not (workbook_result.get("unbuiltSourceVisuals") or [])
        )
        print("\n================ RESULT ================")
        print(f"dataModelId : {dm_id}")
        print(f"workbookId  : {workbook_id}")
        print(f"PARITY      : {'GREEN' if parity_ok else 'RED'}")
        print(f"LAYOUT      : {'GREEN' if layout_ok else 'RED'}")
        print(f"CONTROLS    : {'GREEN' if control_ok else 'RED'}")
        print(f"CONTROL-FLIP: {'GREEN' if flip_ok else 'RED'}")
        if not queryable:
            print("ELEMENTS    : 0 queryable elements — NOT done.")
        cleanup = self.execute(
            python_command(
                "cleanup_orphan_workbooks.py",
                "--workdir",
                self.workdir,
                "--keep",
                workbook_id,
            ),
            check=False,
        )
        finalizer_command = python_command(
            "finalize-qlik-report.py", "--workdir", self.workdir
        )
        if self.args.skip_visual_comparison:
            finalizer_command += [
                "--skip-source-pages",
                self.args.skip_visual_comparison,
            ]
        if self.args.skip_visual_similarity:
            finalizer_command += [
                "--skip-visual-similarity",
                self.args.skip_visual_similarity,
            ]
        pre_finalizer = self.execute(finalizer_command, check=False)
        assert_command = python_command(
            "assert-phase6-ran.py",
            "--workdir",
            self.workdir,
            "--workbook-id",
            workbook_id,
            "--control-scope",
            self.workdir / "control-scope.json",
            "--require-control-flip",
        )
        if render_png:
            assert_command += ["--sigma-render", str(render_png)]
        if self.args.skip_control_flip:
            assert_command += [
                "--skip-control-flip",
                (
                    "explicit migrate-qlik --skip-control-flip"
                    if self.args.skip_control_flip is True
                    else str(self.args.skip_control_flip)
                ),
            ]
        if self.args.skip_layout_lint:
            assert_command += [
                "--skip-layout-lint",
                "explicit migrate-qlik --skip-layout-lint",
            ]
        for flag, value in (
            ("--skip-visual-comparison", self.args.skip_visual_comparison),
            ("--skip-visual-similarity", self.args.skip_visual_similarity),
            ("--skip-anchors-gate", self.args.skip_anchors_gate),
        ):
            if value:
                assert_command += [flag, str(value)]
        assertion = self.execute(assert_command, check=False)
        post_finalizer = self.execute(finalizer_command, check=False)
        verification = self.execute(
            python_command(
                "verify-complete.py",
                "--workdir",
                self.workdir,
                "--workbook-id",
                workbook_id,
            ),
            check=False,
        )
        built_ok = (
            mechanical_ok
            and cleanup.returncode == 0
            and pre_finalizer.returncode == 0
            and assertion.returncode == 0
            and post_finalizer.returncode == 0
            and verification.returncode == 0
        )
        print(
            f"TERMINAL    : {'GREEN' if built_ok else 'RED'} — "
            f"accounting/report "
            f"{'current' if post_finalizer.returncode == 0 else 'failed'}, "
            f"shared assert {'passed' if assertion.returncode == 0 else 'failed'}, "
            f"completion verify {'passed' if verification.returncode == 0 else 'failed'}"
        )
        print("=======================================")
        return 0 if built_ok else 3

    def run(self) -> int:
        if self.args.print_converter:
            print(self.converter or "none")
            print(self.converter_description)
            return 0
        self.prepare_source()
        self.validate_front_door()
        assert self.workdir
        print(f"converter: {self.converter_description}", file=sys.stderr)
        (
            converter_input,
            charts,
            measures,
            app_meta,
            snapshot,
            sheets,
        ) = self.discover()
        app_name = (
            app_meta.get("name")
            or converter_input.get("appName")
            or self.args.app
        )
        base_name = (
            f"{self.args.name} {app_name}" if self.args.name else app_name
        )
        real_charts = [
            chart
            for chart in charts
            if chart.get("measures") and chart.get("dimensions")
        ]
        print(
            f"   app {app_name!r}: {len(converter_input.get('tables') or [])} "
            f"table(s), {len(measures)} master measure(s), "
            f"{len(charts)} object(s); {len(real_charts)} rebuildable chart(s); "
            f"{len(sheets)} sheet(s)"
        )
        converted, converted_path = self.convert(converter_input)
        self.dm_reuse_scan()
        decision_exit = self.decisions(
            app_name, converted, app_meta, real_charts
        )
        if decision_exit is not None:
            return decision_exit
        dm_result, workbook_result, dm_id = self.build(
            converted_path, measures, base_name, sheets
        )
        if self.args.dry_run:
            self.header(6, "Parity")
            print("   DRY RUN: skipping live parity. Artifacts:")
            for filename in (
                "dm-spec.json",
                "wb-spec.json",
                "layout.xml",
                "element-map.json",
            ):
                print(f"     {self.workdir / filename}")
            print("\n================ RESULT (dry run) ================")
            print(f"specs       : {self.workdir}")
            print("==================================================")
            return 0
        render_png = self.render_pages(workbook_result["workbookId"])
        coverage = load_json(self.workdir / "workbook-coverage.json")
        parity_ok, layout_ok, control_ok, flip_ok, _ = self.parity(
            workbook_result,
            dm_id,
            app_meta,
            snapshot,
            charts,
            coverage,
        )
        return self.terminal(
            workbook_result,
            dm_id,
            parity_ok,
            layout_ok,
            control_ok,
            flip_ok,
            render_png,
        )


def load_json(path: Path, default: Any = None) -> Any:
    if not path.is_file():
        if default is not None:
            return default
        raise ValueError(f"missing required artifact: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"malformed JSON artifact {path}: {exc}") from exc


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def main(argv: list[str] | None = None) -> int:
    migration: Migration | None = None
    try:
        args = parse_args(argv)
        migration = Migration(args)
        return migration.run()
    except (ValueError, RuntimeError, sigma_rest.SigmaError) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    finally:
        if migration:
            migration.summary()


if __name__ == "__main__":
    raise SystemExit(main())
