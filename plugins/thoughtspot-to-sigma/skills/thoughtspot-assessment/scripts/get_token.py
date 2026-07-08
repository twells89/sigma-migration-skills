#!/usr/bin/env python3
"""get_token.py — shell-neutral Sigma token minting (Python stdlib only).

The cross-shell twin of get-token.sh. Where get-token.sh prints
`export SIGMA_API_TOKEN=...` (a bash idiom that cannot run in PowerShell /
cmd), this writes the token to <WORK>/auth.json so EVERY shell — bash,
PowerShell, cmd, or an agent driving any of them — uses the exact same
invocation:

    python scripts/get_token.py --workdir <WORK>        # writes <WORK>/auth.json (0600)
    python scripts/get_token.py --print-export          # bash: eval "$(...)" compatibility
    python scripts/get_token.py --print-token           # bare token to stdout (for scripting)

auth.json shape:  {"SIGMA_API_TOKEN": "...", "SIGMA_BASE_URL": "..."}
It is read by shared/lib/sigma_rest.rb (env vars still win) and MUST be
covered by .gitignore — it holds a live bearer token.

Credential resolution mirrors get-token.sh exactly:
  explicit env (SIGMA_CLIENT_ID/SECRET/BASE_URL)
    -> ~/.sigma-migration/env  (the neutral cred file setup.rb writes)
    -> actionable error.
"""

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

NEUTRAL_ENV = os.path.expanduser("~/.sigma-migration/env")


def _load_neutral_env():
    """If Sigma creds aren't already in the environment, load them from the
    neutral cred file written by setup.rb. Existing env always wins — mirrors
    the `ENV[key] ||= raw` behaviour of sigma_rest.rb."""
    if os.environ.get("SIGMA_CLIENT_ID") or not os.path.exists(NEUTRAL_ENV):
        return
    line_re = re.compile(r"\A\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)\Z")
    with open(NEUTRAL_ENV, encoding="utf-8") as fh:
        for line in fh:
            m = line_re.match(line.rstrip("\n"))
            if not m:
                continue
            key, raw = m.group(1), m.group(2).strip()
            if len(raw) >= 2 and (
                (raw.startswith("'") and raw.endswith("'"))
                or (raw.startswith('"') and raw.endswith('"'))
            ):
                raw = raw[1:-1]
            os.environ.setdefault(key, raw)


def _die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def mint_token():
    _load_neutral_env()
    base = os.environ.get("SIGMA_BASE_URL")
    cid = os.environ.get("SIGMA_CLIENT_ID")
    secret = os.environ.get("SIGMA_CLIENT_SECRET")
    if not base or not cid or not secret:
        _die(
            "FATAL: Sigma credentials not set.\n"
            "  Run 'ruby scripts/setup.rb' once (writes ~/.sigma-migration/env),\n"
            "  or set SIGMA_BASE_URL / SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET in the environment."
        )

    # Pre-flight sanity (POSTMORTEM 2026-06-18): the #1 hard blocker was a
    # settings.json where SIGMA_CLIENT_SECRET was a COPY of SIGMA_CLIENT_ID.
    # Sigma returns the opaque "client secret provided is invalid" and nothing
    # else runs. Catch that obvious paste-error here with an actionable message.
    if secret == cid:
        _die(
            "FATAL: SIGMA_CLIENT_SECRET is identical to SIGMA_CLIENT_ID — you pasted the\n"
            "client ID into both fields. The secret is a SEPARATE, longer value shown only\n"
            "once when the API key was created. Fix it in ~/.sigma-migration/env (and in\n"
            "~/.claude/settings.json if it lives there too), then re-run."
        )

    creds = base64.b64encode(f"{cid}:{secret}".encode()).decode()
    req = urllib.request.Request(
        f"{base}/v2/auth/token",
        data=b"grant_type=client_credentials",
        headers={
            "Authorization": f"Basic {creds}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as e:
        _die(
            "Token exchange failed — check SIGMA_BASE_URL, SIGMA_CLIENT_ID, SIGMA_CLIENT_SECRET\n"
            f"  base : {base}\n"
            f"  id   : {len(cid)} chars   secret: {len(secret)} chars\n"
            "  (a valid Sigma secret is ~128 chars — if the secret is the same length as\n"
            f"   the id, you likely pasted the id into both fields.)\n"
            f"  server -> {e.code} {e.reason}"
        )
    except urllib.error.URLError as e:
        _die(f"Token exchange failed — could not reach {base}: {e.reason}")

    token = payload.get("access_token")
    if not token:
        _die("Token exchange failed — response did not contain access_token")
    return base, token


def main():
    ap = argparse.ArgumentParser(description="Mint a Sigma bearer token (shell-neutral).")
    ap.add_argument("--workdir", help="write <WORKDIR>/auth.json (mode 0600)")
    ap.add_argument("--print-export", action="store_true",
                    help="print `export SIGMA_API_TOKEN=...` (bash eval compatibility)")
    ap.add_argument("--print-token", action="store_true",
                    help="print the bare token to stdout")
    args = ap.parse_args()

    base, token = mint_token()

    wrote = False
    if args.workdir:
        os.makedirs(args.workdir, exist_ok=True)
        auth_path = os.path.join(args.workdir, "auth.json")
        # Write 0600 atomically-ish: create with restrictive mode from the start.
        fd = os.open(auth_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"SIGMA_API_TOKEN": token, "SIGMA_BASE_URL": base}, fh)
        try:
            os.chmod(auth_path, 0o600)  # no-op on Windows, harmless
        except OSError:
            pass
        print(f"wrote {auth_path} (Sigma token; expires ~1h)", file=sys.stderr)
        wrote = True

    if args.print_export:
        print(f"export SIGMA_API_TOKEN={token}")
    elif args.print_token:
        print(token)
    elif not wrote:
        # Default with no flags: behave like get-token.sh so `eval "$(...)"`
        # keeps working in bash and nobody's muscle memory breaks.
        print(f"export SIGMA_API_TOKEN={token}")


if __name__ == "__main__":
    main()
