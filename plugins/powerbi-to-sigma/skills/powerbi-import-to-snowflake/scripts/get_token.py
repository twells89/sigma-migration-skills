#!/usr/bin/env python3
"""Mint and verify Sigma API tokens with browser-first dual authentication.

This stdlib-only provider is the protocol/runtime source of truth for Sigma
authentication. Callers should keep using a valid SIGMA_API_TOKEN they already
hold. When they need a new token, this provider resolves credentials in this
order:

  auto (default): browser keychain cache/refresh, then client credentials
  browser:        browser keychain cache/refresh only
  client-credentials: OAuth client credentials only

SIGMA_AUTH_MODE selects the mode; --auth-mode overrides it. Browser refresh
tokens are read from and written to the OS keychain only. They are never put in
auth.json or printed.

CLI compatibility:
  python3 scripts/get_token.py --workdir <DIR>  # writes auth.json (0600)
  python3 scripts/get_token.py --print-export   # shell export statements
  python3 scripts/get_token.py --print-token    # bare access token
"""

import argparse
import base64
import datetime
import getpass
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import NamedTuple


SIGMA_DOMAIN = "sigma" "computing.com"
PUBLISHED_API_HOSTS = frozenset(
    (
        f"aws-api.{SIGMA_DOMAIN}",
        f"api.us-a.aws.{SIGMA_DOMAIN}",
        f"api.ca.aws.{SIGMA_DOMAIN}",
        f"api.eu.aws.{SIGMA_DOMAIN}",
        f"api.au.aws.{SIGMA_DOMAIN}",
        f"api.uk.aws.{SIGMA_DOMAIN}",
        f"api.us.azure.{SIGMA_DOMAIN}",
        f"api.eu.azure.{SIGMA_DOMAIN}",
        f"api.ca.azure.{SIGMA_DOMAIN}",
        f"api.uk.azure.{SIGMA_DOMAIN}",
        f"api.au.azure.{SIGMA_DOMAIN}",
        f"api.{SIGMA_DOMAIN}",
        f"api.sa.gcp.{SIGMA_DOMAIN}",
    )
)
AUTH_MODES = ("auto", "browser", "client-credentials")
_BEARER_RE = re.compile(r"^[A-Za-z0-9._~+/=-]+$")
_MINTED_AT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
_NEUTRAL_ENV = os.path.expanduser("~/.sigma-migration/env")
_NEUTRAL_KEYS = frozenset(
    ("SIGMA_BASE_URL", "SIGMA_CLIENT_ID", "SIGMA_CLIENT_SECRET", "SIGMA_AUTH_MODE")
)


class TokenProviderError(RuntimeError):
    """A token could not be minted safely."""


class SecurityError(TokenProviderError):
    """Untrusted host or unsafe token data."""


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    """Keep bearer credentials on the explicitly validated API origin."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class BrowserUnavailable(TokenProviderError):
    """No usable browser-keychain session is available."""

    def __init__(self, message, warn=False):
        super().__init__(message)
        self.warn = warn


class TokenResult(NamedTuple):
    base_url: str
    token: str
    minted_at: str
    auth_method: str


def _load_neutral_env(path=None):
    """Load missing non-token settings written by migration setup helpers."""
    env_path = path or _NEUTRAL_ENV
    if not os.path.isfile(env_path):
        return
    with open(env_path, encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].strip()
            if "=" not in line:
                continue
            key, raw_value = line.split("=", 1)
            key = key.strip()
            if key not in _NEUTRAL_KEYS or os.environ.get(key):
                continue
            try:
                values = shlex.split(raw_value, posix=True)
            except ValueError as exc:
                raise TokenProviderError(
                    f"{env_path}: invalid shell quoting for {key}"
                ) from exc
            if len(values) != 1:
                raise TokenProviderError(
                    f"{env_path}: {key} must contain one literal value"
                )
            os.environ[key] = values[0]


def _iso_z(timestamp=None):
    if timestamp is None:
        timestamp = time.time()
    value = datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc)
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _validate_minted_at(value, fallback_timestamp):
    if value and _MINTED_AT_RE.fullmatch(value):
        return value
    return _iso_z(fallback_timestamp)


def _validate_access_token(token):
    if not isinstance(token, str) or not token:
        raise TokenProviderError("token response did not contain access_token")
    if not _BEARER_RE.fullmatch(token):
        raise SecurityError(
            "token contains unexpected characters; refusing to cache or emit it"
        )
    return token


def _assert_sigma_url(url, label="OAuth endpoint", base_url=False):
    """Validate an HTTPS Sigma URL and return a normalized base URL if asked."""
    try:
        parsed = urllib.parse.urlsplit(url)
    except (TypeError, ValueError) as exc:
        raise SecurityError(f"{label} is not a valid URL") from exc

    host = (parsed.hostname or "").lower().rstrip(".")
    if parsed.scheme.lower() != "https":
        raise SecurityError(f"{label} must use https://")
    if parsed.username is not None or parsed.password is not None:
        raise SecurityError(f"{label} must not contain user information")
    if not (host == SIGMA_DOMAIN or host.endswith("." + SIGMA_DOMAIN)):
        raise SecurityError(
            f"refusing {label} on non-Sigma host: {host or '<none>'}"
        )
    if base_url and host not in PUBLISHED_API_HOSTS:
        raise SecurityError(
            f"SIGMA_BASE_URL host is not a published Sigma API host: {host}"
        )
    try:
        port = parsed.port
    except ValueError as exc:
        raise SecurityError(f"{label} contains an invalid port") from exc
    if port not in (None, 443):
        raise SecurityError(f"{label} must not use a non-HTTPS port")

    if base_url:
        if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
            raise SecurityError(
                "SIGMA_BASE_URL must be the API origin without a path, query, or fragment"
            )
        return f"https://{host}"
    return url


def _json_response(req, failure_prefix):
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        raise TokenProviderError(
            f"{failure_prefix}: server returned {exc.code} {exc.reason}"
        ) from exc
    except urllib.error.URLError as exc:
        raise TokenProviderError(
            f"{failure_prefix}: could not reach endpoint: {exc.reason}"
        ) from exc
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as exc:
        raise TokenProviderError(
            f"{failure_prefix}: response was not valid JSON"
        ) from exc


def _verify_token(result):
    """Require a non-redirecting, JSON /v2/whoami response before success."""
    req = urllib.request.Request(
        f"{result.base_url}/v2/whoami",
        headers={
            "Authorization": f"Bearer {result.token}",
            "Accept": "application/json",
        },
        method="GET",
    )
    opener = urllib.request.build_opener(_RejectRedirects())
    try:
        with opener.open(req, timeout=30) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as exc:
        if 300 <= exc.code < 400:
            raise TokenProviderError(
                "token verification failed: GET /v2/whoami refused "
                f"HTTP {exc.code} redirect"
            ) from exc
        raise TokenProviderError(
            "token verification failed: GET /v2/whoami returned "
            f"HTTP {exc.code}"
        ) from exc
    except urllib.error.URLError as exc:
        raise TokenProviderError(
            "token verification failed: could not reach GET /v2/whoami"
        ) from exc
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as exc:
        raise TokenProviderError(
            "token verification failed: GET /v2/whoami response was not "
            "valid JSON"
        ) from exc

    if not isinstance(payload, dict):
        raise TokenProviderError(
            "token verification failed: GET /v2/whoami response was not "
            "a JSON object"
        )
    return result


def _mint_client_credentials(base, client_id, client_secret, now=None):
    if not client_id or not client_secret:
        raise TokenProviderError(
            "client-credentials auth requires both SIGMA_CLIENT_ID and "
            "SIGMA_CLIENT_SECRET"
        )
    if client_secret == client_id:
        raise TokenProviderError(
            "SIGMA_CLIENT_SECRET is identical to SIGMA_CLIENT_ID; the secret is "
            "a separate value shown when the API key is created"
        )

    _assert_sigma_url(base, "SIGMA_BASE_URL", base_url=True)
    credentials = base64.b64encode(
        f"{client_id}:{client_secret}".encode("utf-8")
    ).decode("ascii")
    req = urllib.request.Request(
        f"{base}/v2/auth/token",
        data=b"grant_type=client_credentials",
        headers={
            "Authorization": f"Basic {credentials}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    payload = _json_response(req, "client-credentials token exchange failed")
    token = _validate_access_token(payload.get("access_token"))
    return TokenResult(
        base, token, _iso_z(time.time() if now is None else now), "client-credentials"
    )


def _keychain_backend(platform=None):
    """Return the native keychain backend for this platform, if installed."""
    platform = sys.platform if platform is None else platform
    if platform == "darwin" and shutil.which("security"):
        return "macos"
    if platform.startswith("linux") and shutil.which("secret-tool"):
        return "libsecret"
    return None


def _kc_get(backend, name):
    try:
        if backend == "macos":
            proc = subprocess.run(
                [
                    "security",
                    "find-generic-password",
                    "-a",
                    getpass.getuser(),
                    "-s",
                    f"sigma-api:{name}",
                    "-w",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        else:
            proc = subprocess.run(
                ["secret-tool", "lookup", "service", "sigma-api", "key", name],
                capture_output=True,
                text=True,
                check=False,
            )
    except OSError:
        return ""
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _kc_set(backend, name, value):
    try:
        if backend == "macos":
            proc = subprocess.run(
                [
                    "security",
                    "add-generic-password",
                    "-U",
                    "-a",
                    getpass.getuser(),
                    "-s",
                    f"sigma-api:{name}",
                    "-w",
                    value,
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        else:
            proc = subprocess.run(
                [
                    "secret-tool",
                    "store",
                    "--label",
                    f"sigma-api {name}",
                    "service",
                    "sigma-api",
                    "key",
                    name,
                ],
                input=value,
                capture_output=True,
                text=True,
                check=False,
            )
    except OSError:
        return False
    return proc.returncode == 0


def _cache_access_token(backend, token, minted_at, expiry):
    """Commit expiry last so a partial keychain write can never bless old data."""
    if not _kc_set(backend, "access-token", token):
        return False
    if not _kc_set(backend, "access-minted-at", minted_at):
        return False
    return _kc_set(backend, "access-expiry", str(expiry))


def _mint_browser_refresh(base, now=None):
    """Return a browser TokenResult or raise BrowserUnavailable."""
    backend = _keychain_backend()
    if backend is None:
        raise BrowserUnavailable(
            "no supported OS keychain is available "
            "(macOS security or Linux secret-tool)"
        )

    refresh = _kc_get(backend, "refresh-token")
    if not refresh:
        raise BrowserUnavailable(
            "no browser-login refresh token was found in the OS keychain"
        )

    now_value = time.time() if now is None else now
    now_epoch = int(now_value)
    cached = _kc_get(backend, "access-token")
    expiry = _kc_get(backend, "access-expiry")
    if cached and expiry.isdigit() and int(expiry) > now_epoch:
        token = _validate_access_token(cached)
        minted_at = _validate_minted_at(
            _kc_get(backend, "access-minted-at"), now_value
        )
        return TokenResult(base, token, minted_at, "browser")

    client_id = _kc_get(backend, "client-id")
    token_url = _kc_get(backend, "token-url")
    if not client_id or not token_url:
        raise BrowserUnavailable(
            "stored browser login is incomplete; re-run browser-login.sh",
            warn=True,
        )
    _assert_sigma_url(token_url, "stored browser token endpoint")

    body = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": client_id,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        token_url,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        payload = _json_response(req, "browser token refresh failed")
    except SecurityError:
        raise
    except TokenProviderError as exc:
        raise BrowserUnavailable(
            f"{exc}; re-run browser-login.sh if the refresh token expired",
            warn=True,
        ) from exc

    try:
        token = _validate_access_token(payload.get("access_token"))
    except SecurityError:
        raise
    except TokenProviderError as exc:
        raise BrowserUnavailable(
            f"browser token refresh failed: {exc}; re-run browser-login.sh",
            warn=True,
        ) from exc
    minted_at = _iso_z(now_value)
    try:
        expires_in = int(payload.get("expires_in") or 3600)
    except (TypeError, ValueError):
        expires_in = 3600
    cache_expiry = now_epoch + max(0, expires_in - 60)

    # Rotating refresh tokens may be single-use. Persist the replacement before
    # returning the access token; silently keeping the spent token would make
    # the next refresh fail with no recoverable credential.
    new_refresh = payload.get("refresh_token")
    if new_refresh and new_refresh != refresh:
        if not isinstance(new_refresh, str) or not _kc_set(
            backend, "refresh-token", new_refresh
        ):
            raise BrowserUnavailable(
                "the refresh token rotated but its replacement could not be "
                "stored safely; re-run browser-login.sh",
                warn=True,
            )

    _cache_access_token(backend, token, minted_at, cache_expiry)
    return TokenResult(base, token, minted_at, "browser")


def _resolve_auth_mode(cli_mode=None):
    mode = cli_mode or os.environ.get("SIGMA_AUTH_MODE", "auto")
    if mode not in AUTH_MODES:
        raise TokenProviderError(
            "SIGMA_AUTH_MODE must be one of: auto, browser, client-credentials"
        )
    return mode


def mint_token(auth_mode=None):
    _load_neutral_env()
    base_value = os.environ.get("SIGMA_BASE_URL")
    if not base_value:
        raise TokenProviderError(
            "SIGMA_BASE_URL is not set; set it to your Sigma cloud API host"
        )
    base = _assert_sigma_url(base_value, "SIGMA_BASE_URL", base_url=True)
    mode = _resolve_auth_mode(auth_mode)

    if mode in ("auto", "browser"):
        try:
            result = _mint_browser_refresh(base)
        except SecurityError:
            raise
        except BrowserUnavailable as exc:
            if mode == "browser":
                raise TokenProviderError(f"browser auth unavailable: {exc}") from exc
            browser_error = exc
        else:
            browser_error = None
        if browser_error is None:
            return _verify_token(result)
    else:
        browser_error = None

    client_id = os.environ.get("SIGMA_CLIENT_ID")
    client_secret = os.environ.get("SIGMA_CLIENT_SECRET")
    if mode == "client-credentials" or client_id or client_secret:
        if browser_error is not None and browser_error.warn:
            print(
                f"Browser auth unavailable ({browser_error}); "
                "falling back to client credentials.",
                file=sys.stderr,
            )
        result = _mint_client_credentials(base, client_id, client_secret)
        return _verify_token(result)

    raise TokenProviderError(
        "no Sigma authentication is available: run browser-login.sh once, or "
        "set both SIGMA_CLIENT_ID and SIGMA_CLIENT_SECRET"
    )


def _write_auth_json(workdir, result):
    os.makedirs(workdir, exist_ok=True)
    auth_path = os.path.join(workdir, "auth.json")
    payload = {
        "SIGMA_API_TOKEN": result.token,
        "SIGMA_BASE_URL": result.base_url,
        "SIGMA_TOKEN_MINTED_AT": result.minted_at,
        "SIGMA_AUTH_METHOD": result.auth_method,
    }

    fd, temp_path = tempfile.mkstemp(prefix=".auth.json.", dir=workdir)
    try:
        try:
            os.chmod(temp_path, 0o600)
        except OSError:
            pass
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
            handle.flush()
            try:
                os.fsync(handle.fileno())
            except OSError:
                pass
        os.replace(temp_path, auth_path)
        try:
            os.chmod(auth_path, 0o600)
        except OSError:
            pass
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise
    return auth_path


def _print_exports(result):
    print(f"export SIGMA_API_TOKEN={result.token}")
    print(f"export SIGMA_TOKEN_MINTED_AT={result.minted_at}")
    print(f"export SIGMA_AUTH_METHOD={result.auth_method}")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Mint a Sigma bearer token (browser-first by default)."
    )
    parser.add_argument("--workdir", help="write <WORKDIR>/auth.json (mode 0600)")
    parser.add_argument(
        "--print-export",
        action="store_true",
        help="print shell export statements (eval compatibility)",
    )
    parser.add_argument(
        "--print-token", action="store_true", help="print the bare access token"
    )
    parser.add_argument(
        "--auth-mode",
        choices=AUTH_MODES,
        help="override SIGMA_AUTH_MODE (auto, browser, client-credentials)",
    )
    args = parser.parse_args(argv)

    try:
        result = mint_token(args.auth_mode)
        wrote = False
        if args.workdir:
            auth_path = _write_auth_json(args.workdir, result)
            print(
                f"wrote {auth_path} (Sigma access token; refresh token remains "
                "in the OS keychain)",
                file=sys.stderr,
            )
            wrote = True

        if args.print_export:
            _print_exports(result)
        elif args.print_token:
            print(result.token)
        elif not wrote:
            _print_exports(result)
        return 0
    except TokenProviderError as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
