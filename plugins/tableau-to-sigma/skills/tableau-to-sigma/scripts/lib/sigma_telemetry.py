"""
Drop-in telemetry client for Sigma migration skills.

Usage:
    from sigma_telemetry import report_migration

    start = time.time()
    # ... do migration ...
    report_migration(
        tool="metabase-to-sigma",
        sigma_base="https://api.au.aws.sigmacomputing.com",
        client_id=os.environ["SIGMA_CLIENT_ID"],
        duration_seconds=int(time.time() - start),
        success=True,
    )
"""

import hashlib
import re
import time
import os
import urllib.request
import urllib.error
import json

TELEMETRY_ENDPOINT = "https://sigma-migration-telemetry.onrender.com/track"
SKILL_VERSION = "1.0"


def _region_from_base(sigma_base: str) -> str:
    """Extract region slug from Sigma API base URL."""
    if ".au." in sigma_base:  return "au"
    if ".eu." in sigma_base:  return "eu"
    if ".uk." in sigma_base:  return "uk"
    if ".ca." in sigma_base:  return "ca"
    return "us"


def _org_hash(client_id: str) -> str:
    """Anonymous org fingerprint: first 8 hex chars of SHA256(client_id)."""
    return hashlib.sha256(client_id.encode()).hexdigest()[:8]


def report_migration(
    tool: str,
    sigma_base: str,
    client_id: str,
    duration_seconds: int,
    success: bool,
    skill_version: str = SKILL_VERSION,
    endpoint: str = TELEMETRY_ENDPOINT,
    timeout: int = 5,
) -> None:
    """
    Fire-and-forget anonymous usage ping. Never raises — a telemetry failure
    must never block or fail a migration.

    What is sent:
      - tool name (e.g. "metabase-to-sigma")
      - Sigma region (derived from API base URL, e.g. "au")
      - org_id_hash: SHA256 of your SIGMA_CLIENT_ID, first 8 chars
          → unique per org, not reversible to your credentials
      - migration duration in seconds
      - success flag
      - skill version

    What is NOT sent:
      - workbook names, IDs, or URLs
      - SQL queries or column names
      - dashboard or card titles
      - user email or name
      - any customer data or warehouse content
    """
    payload = {
        "event":            "migration_complete",
        "tool":             tool,
        "sigma_region":     _region_from_base(sigma_base),
        "org_id_hash":      _org_hash(client_id),
        "duration_seconds": duration_seconds,
        "success":          success,
        "skill_version":    skill_version,
    }

    print("\nReporting anonymous migration telemetry (no customer data sent):")
    for k, v in payload.items():
        if k != "event":
            print(f"  {k}: {v}")

    try:
        body = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            endpoint,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            print(f"  → telemetry sent ({resp.status})\n")
    except Exception:
        # Never surface telemetry errors to the user
        print("  → telemetry unavailable (skipped)\n")
