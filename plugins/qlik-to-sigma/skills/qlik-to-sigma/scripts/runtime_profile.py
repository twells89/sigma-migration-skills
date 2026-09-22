#!/usr/bin/env python3
"""Resolve a migration skill's executable runtime profile.

The resolver is intentionally stdlib-only. doctor/bootstrap use the same result
so they cannot disagree about whether Ruby is required. A missing capability
manifest is legacy-safe: Ruby + Python + Node + bash remain required.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import sys
from pathlib import Path

PROFILE_NAMES = ("auto", "ruby", "python")
RELEASED_STATUSES = {"supported"}


def legacy_capabilities() -> dict:
    return {
        "schemaVersion": 1,
        "skill": "legacy",
        "profiles": {
            "ruby": {
                "status": "supported",
                "requiredRuntimes": ["ruby", "python", "node", "bash"],
                "entrypoint": ["ruby", "scripts/migrate.rb"],
                "notes": "Implicit legacy profile; no runtime-capabilities.json found.",
            }
        },
    }


def find_capabilities(start: str | os.PathLike[str] | None = None) -> Path | None:
    here = Path(start or __file__).resolve()
    if here.is_file():
        here = here.parent
    for directory in (here, *here.parents):
        candidate = directory / "runtime-capabilities.json"
        if candidate.is_file():
            return candidate
        if directory.name == "skills":
            break
    return None


def load_capabilities(path: str | os.PathLike[str] | None) -> tuple[dict, Path | None]:
    resolved = Path(path).resolve() if path else find_capabilities()
    if resolved is None:
        return legacy_capabilities(), None
    with resolved.open(encoding="utf-8-sig") as handle:
        data = json.load(handle)
    if data.get("schemaVersion") != 1 or not isinstance(data.get("profiles"), dict):
        raise ValueError(f"unsupported runtime capability schema in {resolved}")
    return data, resolved


def observed_runtimes(overrides: dict[str, bool] | None = None) -> dict[str, bool]:
    values = {
        "ruby": shutil.which("ruby") is not None,
        "python": bool(sys.executable),
        "node": shutil.which("node") is not None,
        "bash": shutil.which("bash") is not None,
    }
    values.update(overrides or {})
    return values


def entrypoint_exists(profile: dict, manifest_path: Path | None) -> bool:
    entrypoint = profile.get("entrypoint") or []
    if len(entrypoint) < 2 or manifest_path is None:
        return True
    script = entrypoint[1]
    if not script.startswith(("scripts/", "scripts\\")):
        return True
    return (manifest_path.parent / Path(script)).is_file()


def _eligible(
    profile: dict | None,
    runtimes: dict[str, bool],
    *,
    allow_preview: bool,
    manifest_path: Path | None,
) -> tuple[bool, list[str], str | None]:
    if not profile:
        return False, [], "profile is not declared by this skill"
    status = profile.get("status")
    allowed = set(RELEASED_STATUSES)
    if allow_preview:
        allowed.add("preview")
    if status not in allowed:
        return False, [], f"profile status is {status or 'invalid'}"
    required = list(profile.get("requiredRuntimes") or [])
    missing = [runtime for runtime in required if not runtimes.get(runtime, False)]
    if missing:
        return False, missing, f"missing required runtime(s): {', '.join(missing)}"
    if not entrypoint_exists(profile, manifest_path):
        return False, [], f"entrypoint does not exist: {profile['entrypoint'][1]}"
    return True, [], None


def resolve_profile(
    capabilities: dict,
    requested: str,
    runtimes: dict[str, bool],
    *,
    allow_preview: bool = False,
    manifest_path: Path | None = None,
) -> dict:
    if requested not in PROFILE_NAMES:
        raise ValueError(f"runtime profile must be one of: {', '.join(PROFILE_NAMES)}")

    profiles = capabilities.get("profiles") or {}
    candidates = ["ruby", "python"] if requested == "auto" else [requested]
    failures: dict[str, str] = {}
    selected = None
    required: list[str] = []
    missing: list[str] = []

    for name in candidates:
        ok, absent, reason = _eligible(
            profiles.get(name),
            runtimes,
            allow_preview=allow_preview and requested != "auto",
            manifest_path=manifest_path,
        )
        if ok:
            selected = name
            required = list(profiles[name]["requiredRuntimes"])
            break
        failures[name] = reason or "profile is unavailable"
        missing.extend(runtime for runtime in absent if runtime not in missing)

    fallback_reason = None
    if requested == "auto" and selected == "python":
        fallback_reason = failures.get("ruby", "Ruby profile unavailable")

    return {
        "schemaVersion": 1,
        "skill": capabilities.get("skill", "unknown"),
        "requestedProfile": requested,
        "selectedProfile": selected,
        "requiredRuntimes": required,
        "observedRuntimes": runtimes,
        "fallbackReason": fallback_reason,
        "pass": selected is not None,
        "missingRuntimes": missing,
        "failures": failures if selected is None else {},
    }


def _runtime_override(value: str) -> tuple[str, bool]:
    try:
        name, raw = value.split("=", 1)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("expected NAME=true|false") from exc
    if name not in ("ruby", "python", "node", "bash") or raw not in ("true", "false"):
        raise argparse.ArgumentTypeError("expected ruby|python|node|bash=true|false")
    return name, raw == "true"


def _shell_output(result: dict) -> str:
    values = {
        "RUNTIME_PROFILE_REQUESTED": result["requestedProfile"],
        "RUNTIME_PROFILE_SELECTED": result["selectedProfile"] or "",
        "RUNTIME_PROFILE_REQUIRED": ",".join(result["requiredRuntimes"]),
        "RUNTIME_PROFILE_FALLBACK_REASON": result["fallbackReason"] or "",
        "RUNTIME_PROFILE_PASS": "true" if result["pass"] else "false",
    }
    return "\n".join(f"{key}={shlex.quote(value)}" for key, value in values.items())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capabilities", help="runtime-capabilities.json path")
    parser.add_argument(
        "--requested",
        choices=PROFILE_NAMES,
        default=os.environ.get("SIGMA_RUNTIME_PROFILE", "auto"),
    )
    parser.add_argument(
        "--runtime",
        action="append",
        default=[],
        type=_runtime_override,
        metavar="NAME=true|false",
        help="override an observed runtime (repeatable; intended for doctor/tests)",
    )
    parser.add_argument(
        "--allow-preview",
        action="store_true",
        help="allow an explicitly requested preview profile; auto never selects preview",
    )
    parser.add_argument("--format", choices=("json", "shell"), default="json")
    args = parser.parse_args()

    try:
        capabilities, manifest_path = load_capabilities(args.capabilities)
        result = resolve_profile(
            capabilities,
            args.requested,
            observed_runtimes(dict(args.runtime)),
            allow_preview=args.allow_preview,
            manifest_path=manifest_path,
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"runtime-profile: {exc}", file=sys.stderr)
        return 2

    if args.format == "shell":
        print(_shell_output(result))
    else:
        print(json.dumps(result, sort_keys=True))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
