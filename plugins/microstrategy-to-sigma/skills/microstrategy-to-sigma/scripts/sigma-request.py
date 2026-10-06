#!/usr/bin/env python3
"""Make one authenticated Sigma REST request and write the raw response.

This is the browser-OAuth-safe replacement for the hand-driven curl commands in
SKILL.md. Authentication is delegated to the co-located ``lib/sigma_rest.py``:
valid bearer reuse, proactive age refresh, browser refresh, client-credential
fallback, and one retry after HTTP 401.

Usage:
  python3 scripts/sigma-request.py POST /v2/dataModels/spec --body spec.json
  python3 scripts/sigma-request.py GET /v2/dataModels/<id>/spec > readback.yaml
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
import sigma_rest


def api(method, path, body=None):
    """Return response bytes without JSON/YAML parsing or reformatting."""
    if not path.startswith("/v2/"):
        raise ValueError("PATH must be a relative Sigma /v2/... API path")
    return sigma_rest.request(
        method.lower(),
        path,
        body=body,
        accept="*/*",
        binary=True,
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("method", choices=("GET", "POST", "PUT", "PATCH", "DELETE"))
    parser.add_argument("path")
    parser.add_argument("--body", metavar="FILE", help="send FILE verbatim as JSON")
    args = parser.parse_args(argv)

    try:
        body = None
        if args.body:
            with open(args.body, "r", encoding="utf-8") as handle:
                body = handle.read()
        payload = api(args.method, args.path, body)
    except (OSError, ValueError, sigma_rest.SigmaError, SystemExit) as exc:
        print(f"FATAL: Sigma request failed: {exc}", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
