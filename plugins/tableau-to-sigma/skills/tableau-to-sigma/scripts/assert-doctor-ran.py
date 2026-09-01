#!/usr/bin/env python3
"""Fail-closed Python gate for doctor.json and bootstrap.json."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
from pathlib import Path


def warn(message: str) -> None:
    print(message, file=sys.stderr)


def remediate(profile: str | None = None) -> None:
    suffix = f" --runtime-profile {profile}" if profile else ""
    warn("       Run the ONE bootstrap command FIRST, then retry:")
    warn(f"         macOS/Linux/Git-Bash: bash scripts/bootstrap.sh{suffix}")
    warn(
        "         Windows PowerShell: powershell -ExecutionPolicy Bypass "
        f"-File scripts\\bootstrap.ps1{(' -RuntimeProfile ' + profile) if profile else ''}"
    )


def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("top-level value must be an object")
    return value


def append_waiver(workdir: Path, reason: str) -> None:
    workdir.mkdir(parents=True, exist_ok=True)
    record = {
        "kind": "skip-flag-waived",
        "reason": reason,
        "detail": "--skip-doctor-gate",
        "recorded_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    with (workdir / "offramps.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


def first_existing(paths: list[Path]) -> Path | None:
    return next((path for path in paths if path.is_file()), None)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", "--tableau", dest="workdir")
    parser.add_argument("--runtime-profile", choices=("ruby", "python"))
    parser.add_argument("--skip-doctor-gate")
    args = parser.parse_args()

    workdir = Path(args.workdir).expanduser().resolve() if args.workdir else None
    if args.skip_doctor_gate:
        print(
            f"[SKIP] environment gate WAIVED ({args.skip_doctor_gate}) "
            "— name this in your report."
        )
        if workdir:
            append_waiver(workdir, args.skip_doctor_gate)
        return 0

    doctor_candidates = []
    if workdir:
        doctor_candidates.append(workdir / "doctor.json")
    doctor_candidates.append(Path.home() / ".sigma-migration" / "doctor.json")
    doctor_path = first_existing(doctor_candidates)
    if doctor_path is None:
        warn("[FAIL] environment gate — no doctor.json found.")
        remediate(args.runtime_profile)
        return 1

    try:
        doctor = load_json(doctor_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        warn(f"[FAIL] environment gate — doctor.json at {doctor_path} is unreadable: {exc}")
        remediate(args.runtime_profile)
        return 1

    threshold = int(os.environ.get("SIGMA_MAX_BEHIND", "50"))
    behind = doctor.get("behind_count")
    if isinstance(behind, int) and behind > threshold:
        warn(
            f"[FAIL] environment gate — skill is {behind} commit(s) behind "
            f"origin/main (> {threshold})."
        )
        return 1

    profile = doctor.get("runtime_profile") or {}
    selected = profile.get("selected")
    if args.runtime_profile and selected != args.runtime_profile:
        warn(
            "[FAIL] environment gate — doctor runtime profile mismatch: "
            f"expected {args.runtime_profile!r}, selected {selected!r}."
        )
        remediate(args.runtime_profile)
        return 1

    if not doctor.get("pass"):
        warn("[FAIL] environment gate — the doctor reported blocking failures:")
        for failure in doctor.get("failures") or []:
            warn(f"         ✗ {failure}")
        remediate(args.runtime_profile)
        return 1

    sentinel_candidates = []
    if workdir:
        sentinel_candidates.append(workdir / "bootstrap.json")
    sentinel_candidates.append(Path.home() / ".sigma-migration" / "bootstrap.json")
    sentinel_path = first_existing(sentinel_candidates)
    if sentinel_path is None:
        warn("[FAIL] environment gate — doctor passes but bootstrap.json is missing.")
        remediate(args.runtime_profile)
        return 1
    try:
        sentinel = load_json(sentinel_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        warn(f"[FAIL] environment gate — bootstrap.json at {sentinel_path} is unreadable: {exc}")
        return 1
    if not sentinel.get("doctor_pass"):
        warn("[FAIL] environment gate — bootstrap sentinel records doctor_pass=false.")
        return 1
    sentinel_profile = (sentinel.get("runtime_profile") or {}).get("selected")
    if selected and sentinel_profile != selected:
        warn(
            "[FAIL] environment gate — doctor/bootstrap runtime profiles differ: "
            f"{selected!r} vs {sentinel_profile!r}."
        )
        return 1

    runtimes = doctor.get("runtimes") or {}
    present = ",".join(name for name, available in runtimes.items() if available)
    print(
        f"[PASS] environment gate — profile={selected or 'legacy'} "
        f"runtimes=[{present}]; bootstrap sentinel {sentinel_path}. "
        f"Source: {doctor_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
