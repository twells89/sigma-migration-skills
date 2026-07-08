#!/usr/bin/env python3
"""get-tableau-token.py — shell-neutral Tableau token minting (stdlib only).

The cross-shell twin of get-tableau-token.sh (Windows/PowerShell token fix). The bash
version signs in via curl + sources ~/.sigma-migration/env, which fails on
Windows (PowerShell env vars don't reach the bash subprocess and $HOME isn't
set). This mints the same PAT signin token over pure Python (via the
tableau_rest twin) so it works identically in bash, PowerShell, and cmd:

    python scripts/get-tableau-token.py --print-token     # bare token to stdout
    python scripts/get-tableau-token.py --print-export    # bash: eval "$(...)"
    python scripts/get-tableau-token.py                   # default: bash exports

NOTE: the migrate-tableau.rb orchestrator no longer needs this — it mints the
Tableau token IN-PROCESS (Ruby tableau_rest) and injects it into child env, the
Windows-safe path. This script is for hand-driven Tableau REST calls.

Requires TABLEAU_SERVER_URL + PAT creds (TABLEAU_PAT_NAME / TABLEAU_PAT_SECRET /
TABLEAU_SITE_CONTENT_URL) in the env or ~/.sigma-migration/env (setup-tableau.rb).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import tableau_rest as tr  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description="Mint a Tableau REST token (shell-neutral).")
    ap.add_argument("--print-token", action="store_true", help="print the bare auth token")
    ap.add_argument("--print-export", action="store_true",
                    help='print `export TABLEAU_AUTH_TOKEN=...` lines (bash eval compatibility)')
    args = ap.parse_args()

    try:
        tr.refresh_token()  # PAT signin, in-process
        token, site, server, ver = tr.auth_token(), tr.site_id(), tr.server_url(), tr.api_version()
    except tr.TableauError as e:
        print(f"FATAL: Tableau signin failed — {e}\n"
              "  Check TABLEAU_SERVER_URL + PAT creds (run: ruby scripts/setup-tableau.rb).",
              file=sys.stderr)
        sys.exit(1)

    if args.print_token:
        print(token)
        return
    # default + --print-export: bash-eval-compatible exports (matches get-tableau-token.sh)
    print(f"export TABLEAU_AUTH_TOKEN='{token}'")
    print(f"export TABLEAU_SITE_ID='{site}'")
    print(f"export TABLEAU_SERVER_URL='{server}'")
    print(f"export TABLEAU_API_VERSION='{ver}'")


if __name__ == "__main__":
    main()
