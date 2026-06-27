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
import subprocess
import uuid
import urllib.request
import urllib.error
import json

TELEMETRY_ENDPOINT = "https://sigma-migration-telemetry.onrender.com/track"

# Fallback only — the real value is resolved at runtime by _skill_version()
# (git describe of the skills checkout). A constant here would make every event
# look identical regardless of which build actually ran.
SKILL_VERSION_FALLBACK = "unknown"


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


def _skill_version() -> str:
    """Real build identifier, best-effort and non-identifying:
      1. SIGMA_SKILL_VERSION env override (set by a release/packaging step)
      2. `git describe` of the checkout this file lives in (e.g. "v1.3.0-2-gabc1234")
      3. "unknown"
    Replaces the old hardcoded "1.0" so telemetry can distinguish builds."""
    env = os.environ.get("SIGMA_SKILL_VERSION")
    if env:
        return env[:32]
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        out = subprocess.run(
            ["git", "-C", here, "describe", "--tags", "--always", "--dirty"],
            capture_output=True, timeout=3,
        )
        v = (out.stdout or b"").decode("ascii", "ignore").strip()
        if v:
            return v[:32]
    except Exception:
        pass
    return SKILL_VERSION_FALLBACK


def _environment() -> str:
    """Coarse run environment — no host names, no PII. Lets us tell an automated
    CI/benchmark loop apart from a human running a one-off migration."""
    ci_vars = ("CI", "GITHUB_ACTIONS", "GITLAB_CI", "CIRCLECI", "JENKINS_URL",
               "BUILDKITE", "TF_BUILD", "TEAMCITY_VERSION")
    if any(os.environ.get(v) for v in ci_vars):
        return "ci"
    cloud_vars = ("CODESPACES", "GITPOD_WORKSPACE_ID", "KUBERNETES_SERVICE_HOST",
                  "AWS_EXECUTION_ENV", "RENDER", "FLY_APP_NAME", "K_SERVICE")
    if any(os.environ.get(v) for v in cloud_vars) or os.path.exists("/.dockerenv"):
        return "cloud"
    return "local"


def _client_agent() -> str:
    """Which harness is driving the skill — no PII. Helps explain usage shape."""
    e = os.environ
    if e.get("CLAUDECODE") or e.get("CLAUDE_CODE_ENTRYPOINT") or e.get("CLAUDE_CODE"):
        return "claude-code"
    if e.get("CURSOR_TRACE_ID") or (e.get("TERM_PROGRAM") or "").lower() == "cursor":
        return "cursor"
    if e.get("CORTEX_AGENT") or e.get("SNOWFLAKE_CORTEX") or "cortex" in (e.get("TERM_PROGRAM") or "").lower():
        return "cortex"
    return "cli" if hasattr(__import__("sys").stdin, "isatty") and __import__("sys").stdin.isatty() else "unknown"


def report_migration(
    tool: str,
    sigma_base: str,
    client_id: str,
    duration_seconds: int,
    success: bool,
    mode: str = "unknown",
    outcome: str = None,
    failure_stage: str = None,
    skill_version: str = None,
    environment: str = None,
    client_agent: str = None,
    run_id: str = None,
    endpoint: str = TELEMETRY_ENDPOINT,
    timeout: int = 5,
) -> bool:
    """
    Fire-and-forget anonymous usage ping. Never raises — a telemetry failure
    must never block or fail a migration.

    What is sent:
      - tool name (e.g. "metabase-to-sigma")
      - Sigma region (derived from API base URL, e.g. "au")
      - org_id_hash: SHA256 of your SIGMA_CLIENT_ID, first 8 chars
          → unique per org, not reversible to your credentials
      - migration duration in seconds
      - success flag + outcome ("success" / "partial" / "failed")
      - failure_stage when not successful: a coarse enum
          ("auth" / "convert" / "spec_post" / "query_validate" / "other"),
          never a stack trace or message
      - input mode: "live" / "file" / "both" / "unknown" — coarse, no file names
      - skill_version: build identifier (git describe), no longer a constant
      - environment: "ci" / "cloud" / "local" — run context, no host names
      - client_agent: "claude-code" / "cursor" / "cortex" / "cli" / "unknown"
      - run_id: a random per-run UUID (dedupe + retry-vs-distinct-run grouping)

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
        "outcome":          outcome or ("success" if success else "failed"),
        "failure_stage":    failure_stage,
        "mode":             mode or "unknown",
        "skill_version":    skill_version or _skill_version(),
        "environment":      environment or _environment(),
        "client_agent":     client_agent or _client_agent(),
        "run_id":           run_id or uuid.uuid4().hex,
    }

    print("\nReporting anonymous migration telemetry (no customer data sent):")
    for k, v in payload.items():
        if k != "event":
            print(f"  {k}: {v}")

    body = json.dumps(payload).encode("utf-8")
    # Returns True on HTTP 2xx, False on any skip/failure. NEVER raises — telemetry
    # must never block or fail a migration. The caller writes an honest marker
    # ("sent" vs "skipped") based on this return (handoff FIX 3).
    return _post(endpoint, body, timeout)


def _ssl_context():
    """Prefer certifi's CA bundle — stock macOS / homebrew-python urllib often
    fails CERTIFICATE_VERIFY_FAILED against the endpoint where curl succeeds
    (handoff FIX 4). Fall back to the default context if certifi isn't present."""
    try:
        import ssl
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        try:
            import ssl
            return ssl.create_default_context()
        except Exception:
            return None


def _post(endpoint, body, timeout):
    # 1) urllib with a certifi-backed SSL context.
    try:
        req = urllib.request.Request(
            endpoint, data=body,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        ctx = _ssl_context()
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            if 200 <= resp.status < 300:
                print(f"  → telemetry sent ({resp.status})\n")
                return True
            print(f"  → telemetry endpoint returned {resp.status} — skipped\n")
            return False
    except Exception as e:
        first = str(e).splitlines()[0] if str(e) else type(e).__name__
        # 2) Fall back to curl — succeeds on boxes where python's CA store is broken.
        try:
            r = subprocess.run(
                ["curl", "-sS", "-m", str(timeout), "-o", "/dev/null",
                 "-w", "%{http_code}", "-X", "POST",
                 "-H", "Content-Type: application/json", "--data-binary", "@-", endpoint],
                input=body, capture_output=True, timeout=timeout + 5,
            )
            code = (r.stdout or b"").decode("ascii", "ignore").strip()
            if code.startswith("2"):
                print(f"  → telemetry sent ({code}, via curl)\n")
                return True
            print(f"  → telemetry unavailable (urllib: {first}; curl HTTP {code or 'n/a'}) — skipped\n")
            return False
        except Exception as e2:
            print(f"  → telemetry unavailable (urllib: {first}; curl: {str(e2).splitlines()[0]}) — skipped\n")
            return False
