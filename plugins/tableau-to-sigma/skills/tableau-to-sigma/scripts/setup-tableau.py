#!/usr/bin/env python3
"""Persist Tableau PAT credentials without requiring Ruby."""

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
DEFAULT_CLOUD = "https://us-west-2b.online.tableau.com"


def die(message: str) -> NoReturn:
    print(message, file=sys.stderr)
    raise SystemExit(2)


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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from-env", action="store_true")
    args = parser.parse_args()

    use_env = args.from_env or not sys.stdin.isatty()
    if use_env:
        server = os.environ.get("TABLEAU_SERVER_URL", "")
        site = os.environ.get("TABLEAU_SITE_CONTENT_URL", "")
        name = os.environ.get("TABLEAU_PAT_NAME", "")
        secret = os.environ.get("TABLEAU_PAT_SECRET", "")
        missing = [
            key
            for key, value in (
                ("TABLEAU_SERVER_URL", server),
                ("TABLEAU_PAT_NAME", name),
                ("TABLEAU_PAT_SECRET", secret),
            )
            if not value
        ]
        if missing:
            die(
                "ERROR: missing environment variable(s): "
                + ", ".join(missing)
                + ". Export them and run `python scripts/setup-tableau.py --from-env`."
            )
    else:
        server = input(f"Server URL [{DEFAULT_CLOUD}]: ").strip() or DEFAULT_CLOUD
        site = input(
            "Site contentUrl (blank for the Default site): "
        ).strip()
        name = input("PAT name: ").strip()
        secret = getpass.getpass("PAT secret (hidden): ").strip()

    server = server.rstrip("/")
    parsed = urllib.parse.urlparse(server)
    if parsed.scheme != "https" or not parsed.hostname:
        die("TABLEAU_SERVER_URL must be an absolute https:// URL.")
    if not name or not secret:
        die("Server URL, PAT name, and PAT secret are required.")

    if SETTINGS_PATH.exists():
        try:
            settings = json.loads(SETTINGS_PATH.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError) as exc:
            die(f"Cannot parse {SETTINGS_PATH}: {exc}")
    else:
        settings = {}
    settings.setdefault("env", {})
    pairs = {
        "TABLEAU_SERVER_URL": server,
        "TABLEAU_SITE_CONTENT_URL": site,
        "TABLEAU_PAT_NAME": name,
        "TABLEAU_PAT_SECRET": secret,
    }
    settings["env"].update(pairs)
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS_PATH.write_text(
        json.dumps(settings, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    upsert_neutral_env(pairs)

    print(f"Tableau credentials saved to {SETTINGS_PATH} and {NEUTRAL_PATH}.")
    print(f"TABLEAU_SERVER_URL: {server}")
    print(f"TABLEAU_SITE_CONTENT_URL: {site or '(Default site)'}")
    print(f"TABLEAU_PAT_NAME: {name}")
    print(f"TABLEAU_PAT_SECRET: {'*' * max(0, len(secret) - 4) + secret[-4:]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
