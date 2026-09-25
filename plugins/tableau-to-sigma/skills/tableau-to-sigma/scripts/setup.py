#!/usr/bin/env python3
"""Persist Sigma credentials without requiring Ruby.

Writes the same ~/.claude/settings.json and ~/.sigma-migration/env files as
setup.rb. Existing unrelated environment keys are preserved.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import sys
import urllib.parse
from pathlib import Path
from typing import NoReturn

SETTINGS_PATH = Path.home() / ".claude" / "settings.json"
NEUTRAL_PATH = Path.home() / ".sigma-migration" / "env"
DEFAULT_BASE = "https://aws-api.[REDACTED].com"


def die(message: str) -> NoReturn:
    print(message, file=sys.stderr)
    raise SystemExit(2)


def validate_base_url(base: str) -> None:
    if os.environ.get("SIGMA_ALLOW_INSECURE_BASE_URL") == "1":
        print(
            f"WARNING: SIGMA_ALLOW_INSECURE_BASE_URL=1 — skipping "
            f"SIGMA_BASE_URL validation ({base})",
            file=sys.stderr,
        )
        return
    parsed = urllib.parse.urlparse(base)
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https":
        die(f"SIGMA_BASE_URL must use https:// (got {base!r}). Refusing to write credentials.")
    if not (host == "[REDACTED].com" or host.endswith(".[REDACTED].com")):
        die(
            f"SIGMA_BASE_URL host {host!r} is not a [REDACTED].com host. "
            "Set SIGMA_ALLOW_INSECURE_BASE_URL=1 to override."
        )


def shell_single_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def upsert_neutral_env(pairs: dict[str, str]) -> None:
    NEUTRAL_PATH.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    body = NEUTRAL_PATH.read_text(encoding="utf-8") if NEUTRAL_PATH.exists() else ""
    for key, value in pairs.items():
        line = f"export {key}={shell_single_quote(value)}"
        pattern = re.compile(rf"^export {re.escape(key)}=.*$", re.MULTILINE)
        if pattern.search(body):
            body = pattern.sub(line, body, count=1)
        else:
            if body and not body.endswith("\n"):
                body += "\n"
            body += line + "\n"
    NEUTRAL_PATH.write_text(body, encoding="utf-8")
    try:
        NEUTRAL_PATH.chmod(0o600)
    except OSError:
        pass


def load_settings() -> dict:
    if not SETTINGS_PATH.exists():
        return {}
    try:
        return json.loads(SETTINGS_PATH.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        die(f"Cannot parse {SETTINGS_PATH}: {exc}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url")
    parser.add_argument("--client-id")
    parser.add_argument("--client-secret")
    parser.add_argument("--connection-id")
    parser.add_argument("--from-env", action="store_true")
    args = parser.parse_args()

    base = args.base_url or ""
    client_id = args.client_id or ""
    secret = args.client_secret or ""
    connection = args.connection_id or ""

    use_env = args.from_env or (
        not sys.stdin.isatty() and not client_id and not secret
    )
    if use_env:
        base = base or os.environ.get("SIGMA_BASE_URL", "")
        client_id = client_id or os.environ.get("SIGMA_CLIENT_ID", "")
        secret = secret or os.environ.get("SIGMA_CLIENT_SECRET", "")
        connection = connection or os.environ.get("SIGMA_CONNECTION_ID", "")
        if not client_id or not secret:
            die(
                "ERROR: SIGMA_CLIENT_ID and SIGMA_CLIENT_SECRET are required "
                "for --from-env/non-interactive setup."
            )

    if (not client_id or not secret) and not sys.stdin.isatty():
        die(
            "ERROR: stdin is not a TTY and credentials were not supplied. "
            "Export SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET and run "
            "`python scripts/setup.py --from-env`."
        )

    if not client_id:
        client_id = input("Client ID (not a secret — will echo): ").strip()
    if not secret:
        secret = getpass.getpass("Client Secret (hidden): ").strip()
    if not base and sys.stdin.isatty():
        base = input(f"Base URL [{DEFAULT_BASE}]: ").strip()
    base = base or DEFAULT_BASE
    if not connection and sys.stdin.isatty():
        connection = input(
            "Connection ID (full warehouse-connection UUID, optional): "
        ).strip()

    if not client_id or not secret:
        die("Base URL, Client ID, and Client Secret are required.")
    validate_base_url(base)

    settings = load_settings()
    settings.setdefault("env", {})
    settings["env"].update(
        {
            "SIGMA_BASE_URL": base,
            "SIGMA_CLIENT_ID": client_id,
            "SIGMA_CLIENT_SECRET": secret,
        }
    )
    if connection:
        settings["env"]["SIGMA_CONNECTION_ID"] = connection
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS_PATH.write_text(
        json.dumps(settings, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    pairs = {
        "SIGMA_BASE_URL": base,
        "SIGMA_CLIENT_ID": client_id,
        "SIGMA_CLIENT_SECRET": secret,
    }
    if connection:
        pairs["SIGMA_CONNECTION_ID"] = connection
    upsert_neutral_env(pairs)

    masked = "*" * max(0, len(secret) - 4) + secret[-4:]
    print(f"Credentials saved to {SETTINGS_PATH} and {NEUTRAL_PATH}.")
    print(f"SIGMA_BASE_URL: {base}")
    print(f"SIGMA_CLIENT_ID: {client_id}")
    print(f"SIGMA_CLIENT_SECRET: {masked} ({len(secret)} chars)")
    print(f"SIGMA_CONNECTION_ID: {connection or '(skipped)'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
