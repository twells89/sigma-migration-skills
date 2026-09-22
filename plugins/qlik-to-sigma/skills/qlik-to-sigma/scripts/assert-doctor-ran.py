#!/usr/bin/env python3
"""Fail closed unless bootstrap and doctor selected a healthy runtime profile."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def read_object(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("top-level JSON value must be an object")
    return value


def first_artifact(workdir: Path, name: str) -> Path | None:
    candidates = (
        workdir / name,
        Path.home() / ".sigma-migration" / name,
    )
    return next((path for path in candidates if path.is_file()), None)


def profile(document: dict[str, Any]) -> tuple[str | None, list[str]]:
    value = document.get("runtime_profile") or document.get("runtimeProfile") or {}
    if not isinstance(value, dict):
        return None, []
    selected = value.get("selected") or value.get("selectedProfile")
    required = value.get("required_runtimes") or value.get("requiredRuntimes") or []
    return selected, list(required) if isinstance(required, list) else []


def record_waiver(workdir: Path, reason: str) -> None:
    workdir.mkdir(parents=True, exist_ok=True)
    row = {
        "kind": "skip-flag-waived",
        "detail": "--skip-doctor-gate",
        "reason": reason,
        "recorded_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    with (workdir / "offramps.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, sort_keys=True) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--runtime-profile", choices=("ruby", "python"), default="python")
    parser.add_argument("--skip-doctor-gate")
    args = parser.parse_args(argv)
    workdir = Path(args.workdir).expanduser().resolve()
    if args.skip_doctor_gate:
        record_waiver(workdir, args.skip_doctor_gate)
        print(f"[SKIP] environment gate WAIVED ({args.skip_doctor_gate})")
        return 0

    doctor_path = first_artifact(workdir, "doctor.json")
    bootstrap_path = first_artifact(workdir, "bootstrap.json")
    if not doctor_path or not bootstrap_path:
        missing = "doctor.json" if not doctor_path else "bootstrap.json"
        print(
            f"[FAIL] environment gate — {missing} is missing. Run "
            f"`bash scripts/bootstrap.sh --runtime-profile {args.runtime_profile} "
            f"--workdir {workdir}` first.",
            file=sys.stderr,
        )
        return 1
    try:
        doctor = read_object(doctor_path)
        bootstrap = read_object(bootstrap_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"[FAIL] environment gate — unreadable evidence: {exc}", file=sys.stderr)
        return 1

    doctor_profile, required = profile(doctor)
    bootstrap_profile, bootstrap_required = profile(bootstrap)
    failures = []
    if doctor.get("pass") is not True:
        failures.append("doctor.json does not report pass=true")
    if bootstrap.get("doctor_pass") is not True:
        failures.append("bootstrap.json does not report doctor_pass=true")
    if doctor_profile != args.runtime_profile or bootstrap_profile != args.runtime_profile:
        failures.append(
            "doctor/bootstrap profile mismatch "
            f"(doctor={doctor_profile!r}, bootstrap={bootstrap_profile!r}, "
            f"expected={args.runtime_profile!r})"
        )
    if required != bootstrap_required:
        failures.append("doctor/bootstrap required runtime lists disagree")
    if args.runtime_profile == "python" and (
        "python" not in required or "node" not in required or "ruby" in required
    ):
        failures.append(f"invalid Python required runtime list: {required!r}")
    runtimes = doctor.get("runtimes") or doctor.get("observedRuntimes") or {}
    missing_runtimes = [
        runtime
        for runtime in required
        if not isinstance(runtimes, dict) or runtimes.get(runtime) is not True
    ]
    if missing_runtimes:
        failures.append("required runtime(s) not observed: " + ", ".join(missing_runtimes))
    if failures:
        print("[FAIL] environment gate:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(
        f"[PASS] environment gate — profile={doctor_profile} "
        f"runtimes={','.join(required)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
