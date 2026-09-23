#!/usr/bin/env python3
"""Resolve one Sigma connection and cache Qlik migration intake metadata."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from lib import sigma_rest

HERE = Path(__file__).resolve().parent
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    try:
        temporary.write_text(
            json.dumps(value, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def read_json(path: Path) -> Any:
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def normalize(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "connection_id": row.get("connectionId") or row.get("id"),
        "name": row.get("name"),
        "type": row.get("type") or row.get("connectionType"),
        "host": row.get("host"),
        "account": row.get("account"),
        "warehouse": row.get("warehouse"),
    }


def list_connections(fixture: Path | None) -> list[dict[str, Any]]:
    data = read_json(fixture) if fixture else sigma_rest.request(
        "get", "/v2/connections?limit=500"
    )
    rows = (
        data.get("entries") or data.get("connections") or []
        if isinstance(data, dict)
        else data or []
    )
    return [
        normalized
        for row in rows
        if isinstance(row, dict)
        and (normalized := normalize(row)).get("connection_id")
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--tool", default="qlik-to-sigma")
    parser.add_argument("--mode", choices=("live", "file", "both"), default="live")
    parser.add_argument("--connection")
    parser.add_argument("--name")
    parser.add_argument("--source")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--connections-fixture", help=argparse.SUPPRESS)
    parser.add_argument("--skip-bootstrap-gate")
    args = parser.parse_args(argv)
    workdir = Path(args.workdir).expanduser().resolve()
    workdir.mkdir(parents=True, exist_ok=True)

    doctor_command = [
        sys.executable,
        str(HERE / "assert-doctor-ran.py"),
        "--workdir",
        str(workdir),
        "--runtime-profile",
        "python",
    ]
    if args.skip_bootstrap_gate:
        doctor_command += ["--skip-doctor-gate", args.skip_bootstrap_gate]
    doctor = subprocess.run(doctor_command, check=False)
    if doctor.returncode:
        return 6

    cache_path = workdir / "connection.json"
    candidates_path = workdir / "connection-candidates.json"
    resolved: dict[str, Any] | None = None
    resolved_via = ""
    if args.connection:
        if not UUID.fullmatch(args.connection):
            print("intake: --connection must be a full UUID", file=sys.stderr)
            return 2
        resolved = {"connection_id": args.connection}
        resolved_via = "flag"
    elif not args.force and cache_path.is_file():
        try:
            cached = read_json(cache_path)
            if isinstance(cached, dict) and UUID.fullmatch(
                str(cached.get("connection_id") or "")
            ):
                resolved = cached
                resolved_via = "cache"
        except (OSError, ValueError, json.JSONDecodeError):
            pass
    elif UUID.fullmatch(os.environ.get("SIGMA_CONNECTION_ID", "")):
        resolved = {"connection_id": os.environ["SIGMA_CONNECTION_ID"]}
        resolved_via = "environment"

    if resolved is None:
        try:
            connections = list_connections(
                Path(args.connections_fixture).resolve()
                if args.connections_fixture
                else None
            )
        except (OSError, ValueError, json.JSONDecodeError, sigma_rest.SigmaError) as exc:
            print(f"intake: could not list Sigma connections: {exc}", file=sys.stderr)
            return 4
        if not connections:
            print("intake: no Sigma connections found", file=sys.stderr)
            return 4
        matches = connections
        if args.name:
            needle = args.name.casefold()
            matches = [
                row for row in connections
                if needle in str(row.get("name") or "").casefold()
            ]
        if len(matches) == 1:
            resolved = matches[0]
            resolved_via = "name" if args.name else "only-connection"
        else:
            write_json(
                candidates_path,
                {"count": len(matches), "candidates": matches, "ranked": False},
            )
            print(
                f"[ASK] intake: {len(matches)} candidate connection(s); "
                f"review {candidates_path} and rerun with --connection <id>",
                file=sys.stderr,
            )
            return 3

    write_json(cache_path, resolved)
    try:
        candidates_path.unlink()
    except FileNotFoundError:
        pass
    write_json(
        workdir / "intake.json",
        {
            "run_start": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "input_mode": args.mode,
            "tool": args.tool,
            "source": args.source,
        },
    )
    print(
        f"[OK] intake: connection {resolved['connection_id']} "
        f"({resolved.get('name') or '?'}) via {resolved_via} → {cache_path}"
    )
    print(f"[OK] intake: mode={args.mode} tool={args.tool}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
