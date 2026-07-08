#!/usr/bin/env bash
# doctor.sh — environment preflight for the migration skills (macOS / Linux /
# Windows Git-Bash). Run this FIRST: it reports exactly what's installed, flags
# the known footguns (esp. the Windows Python "Store stub" and a missing bash),
# and prints the precise fix for each — so neither you nor the agent has to
# trial-and-error the environment.
#
#   bash scripts/doctor.sh
#
# Exit 0 when all REQUIRED tools are present; 1 when something required is
# missing (each failure prints a remediation line). Windows users without a
# bash at all should run scripts/doctor.ps1 in PowerShell instead.
#
# REQUIRED, by skill family:
#   - ruby   : the *-to-sigma orchestrators (tableau/qlik/powerbi/quicksight, …)
#   - python3: looker/thoughtspot/microstrategy/sisense entrypoints + discovery
#   - node   : the vendored converters (converter/*.mjs) and *.mjs build steps
#   - bash   : get-token.sh / *-auth.sh (Sigma token minting)
set -u

# --workdir DIR: also drop doctor.json here (in addition to the stable
# ~/.sigma-migration/doctor.json). Everything else is positional-agnostic.
WORKDIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workdir) WORKDIR="${2:-}"; shift 2 ;;
    --workdir=*) WORKDIR="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

PASS=0; FAIL=0; WARN=0
FAILURES=()
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n     ↳ %s\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILURES+=("$1"); }
warn() { printf '  \033[33m!\033[0m %s\n     ↳ %s\n' "$1" "$2"; WARN=$((WARN+1)); }

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows-bash ;;
  Darwin) OS=macos ;; Linux) OS=linux ;; *) OS=unknown ;;
esac
echo "Environment doctor — host: $OS"
echo

# --- ruby ------------------------------------------------------------------
if command -v ruby >/dev/null 2>&1; then
  ok "ruby — $(ruby -e 'print RUBY_VERSION' 2>/dev/null)"
else
  if [ "$OS" = "windows-bash" ]; then
    bad "ruby not found" "Install RubyInstaller (https://rubyinstaller.org), tick 'Add Ruby to PATH', reopen the shell."
  else
    bad "ruby not found" "macOS: 'brew install ruby'  •  Linux: 'apt-get install ruby' (or your package manager)."
  fi
fi

# --- python (real interpreter, NOT the Windows Store alias stub) -----------
# Probe py -3 (Windows launcher) first, then python3/python. Reject any that
# resolves under WindowsApps — the App-Execution-Alias stub that silently no-ops.
py_real() {
  local exe="$1"; shift
  command -v "$exe" >/dev/null 2>&1 || return 1
  local ver; ver="$("$exe" "$@" --version 2>&1)" || return 1
  case "$ver" in Python\ [0-9]*) : ;; *) return 1 ;; esac
  local where; where="$("$exe" "$@" -c 'import sys;print(sys.executable)' 2>/dev/null)" || return 1
  case "$(printf '%s' "$where" | tr 'A-Z' 'a-z')" in *windowsapps*) return 1 ;; esac
  PY_DESC="$ver  ($where)"; PY_VER="$ver"; PY_ARGV="$exe${*:+ $*}"; return 0
}
PY_ARGV=""
if   py_real py -3 ; then ok "python — $PY_DESC  [launcher: py -3]"
elif py_real python3; then ok "python — $PY_DESC  [python3]"
elif py_real python ; then ok "python — $PY_DESC  [python]"
else
  if [ "$OS" = "windows-bash" ]; then
    bad "no real Python (the 'python'/'python3' you have is likely the Microsoft Store alias stub)" \
        "Install Python from python.org (tick 'Add to PATH'), then use 'py -3', OR disable the stub: Settings → Apps → Advanced app settings → App execution aliases → turn OFF python.exe/python3.exe. Re-run."
  else
    bad "python3 not found" "macOS: 'brew install python'  •  Linux: 'apt-get install python3'."
  fi
fi

# --- python TLS trust (P1.4) -----------------------------------------------
# Python's OpenSSL 3.x is stricter than curl/Ruby and rejects some valid server
# chains (e.g. Tableau Cloud's intermediate — "Basic Constraints not marked
# critical") under the default CA bundle, so the Python REST path can fail
# CERTIFICATE_VERIFY_FAILED where the Ruby path succeeds. `truststore` (uses the
# OS trust store) fixes it. WARN only when OpenSSL is 3.x AND truststore is
# absent — the exact combination that bites.
if [ -n "$PY_ARGV" ]; then
  TLS_PROBE="$($PY_ARGV -c "import ssl,importlib.util as iu; print('TRUSTWARN' if ssl.OPENSSL_VERSION.startswith('OpenSSL 3') and iu.find_spec('truststore') is None else '')" 2>/dev/null)"
  if [ "$TLS_PROBE" = "TRUSTWARN" ]; then
    warn "python uses OpenSSL 3.x without 'truststore' — TLS verification may fail against some servers (e.g. Tableau Cloud) where curl/Ruby succeed" \
         "Fix: '$PY_ARGV -m pip install truststore' (uses the OS trust store). Do NOT disable TLS verification."
  fi
fi

# --- node (vendored converters are ESM run via node) -----------------------
if command -v node >/dev/null 2>&1; then
  ok "node — $(node --version 2>/dev/null)"
else
  bad "node not found (required — the vendored converters/*.mjs run via node)" "macOS/Linux: install Node 18+ from https://nodejs.org or your package manager. Windows no-admin: 'winget install Schniz.fnm' then 'fnm install --lts && fnm use --lts'. See refs/environment.md #5 — don't auto-download an unpinned Node, ask first."
fi

# --- bash (token minting + *.sh helpers) -----------------------------------
# We're running under bash, so it exists here. The note matters for Windows
# users who might otherwise try to run get-token.sh from cmd/PowerShell.
if [ "$OS" = "windows-bash" ]; then
  ok "bash available (Git Bash / MSYS) — run the *.sh helpers (get-token.sh) from THIS shell"
else
  ok "bash available"
fi

# --- git autocrlf (CRLF mangles shebangs + bash scripts) -------------------
CRLF="$(git config --get core.autocrlf 2>/dev/null || true)"
if [ "$CRLF" = "true" ]; then
  warn "git core.autocrlf=true — may rewrite shipped .sh/.rb/.py to CRLF and break shebangs" \
       "Re-clone with: git config --global core.autocrlf input   (or set 'false' for this repo, then re-checkout)."
else
  ok "git core.autocrlf=${CRLF:-unset} (won't CRLF-mangle scripts)"
fi

# --- CRLF actually present in a shipped shell script? ----------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GT="$HERE/get-token.sh"
if [ -f "$GT" ] && grep -q $'\r' "$GT" 2>/dev/null; then
  bad "get-token.sh has CRLF line endings — bash will fail with '\\r: command not found'" \
      "Fix: 'sed -i \$'s/\\r\$//' scripts/*.sh' (or set core.autocrlf=input and re-checkout)."
fi

# --- Sigma credentials (informational) -------------------------------------
if [ -f "$HOME/.sigma-migration/env" ] || [ -n "${SIGMA_API_TOKEN:-}" ] || [ -n "${SIGMA_CLIENT_ID:-}" ]; then
  ok "Sigma credentials present (env or ~/.sigma-migration/env)"
else
  warn "no Sigma credentials found" "Run 'ruby scripts/setup.rb' once (writes ~/.sigma-migration/env), or export SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET."
fi

# --- skill version drift (v3 §2.1) -----------------------------------------
# A plugin install pins a git SHA and never self-updates; running a stale SHA
# silently ships pre-fidelity-layer output. Record {skill_sha, behind_count};
# the orchestrator preflight FAILs above a threshold. Bounded, best-effort
# fetch (stalled network capped ~6s); skip with SIGMA_SKIP_VERSION_CHECK=1.
SKILL_SHA=""; BEHIND_COUNT="null"
if command -v git >/dev/null 2>&1 && git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
  SKILL_SHA="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || true)"
  if [ -z "${SIGMA_SKIP_VERSION_CHECK:-}" ]; then
    git -C "$HERE" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=6 fetch --quiet origin 2>/dev/null
    _bc="$(git -C "$HERE" rev-list --count HEAD..origin/main 2>/dev/null || true)"
    case "$_bc" in ''|*[!0-9]*) BEHIND_COUNT="null" ;; *) BEHIND_COUNT="$_bc" ;; esac
  fi
  if [ "$BEHIND_COUNT" = "null" ]; then
    [ -n "$SKILL_SHA" ] && ok "skill version $SKILL_SHA (drift check skipped/offline)"
  elif [ "$BEHIND_COUNT" -gt 0 ] 2>/dev/null; then
    warn "skill is ${BEHIND_COUNT} commit(s) behind origin/main (installed $SKILL_SHA) — you may be missing fidelity-layer fixes" \
         "Update: 'git -C \"$HERE\" pull' (or reinstall the plugin). SIGMA_SKIP_VERSION_CHECK=1 skips this probe."
  else
    ok "skill version $SKILL_SHA (current with origin/main)"
  fi
fi

# --- agent capability fingerprint (v3 §2.2) --------------------------------
# The doctor can't introspect the driving agent, so vision is asserted by the
# caller: a vision-capable session exports SIGMA_AGENT_VISION=true. Default
# false so the visual gate (D5) fails LOUDLY rather than accepting a blind
# attestation. model_hint is free-form (e.g. "claude-opus-4-8").
case "${SIGMA_AGENT_VISION:-}" in true|1|yes|TRUE|True) AGENT_VISION=true ;; *) AGENT_VISION=false ;; esac
MODEL_HINT="${SIGMA_MODEL_HINT:-}"

# --- machine-readable fingerprint (doctor.json) ----------------------------
# Written so (a) the run-state / preflight GATE can refuse to proceed on a
# broken environment instead of letting the agent improvise, and (b) telemetry
# can group next event's failures by environment class. Human output above is
# unchanged. Always to ~/.sigma-migration/doctor.json; also to <WORKDIR> if given.
jstr() { local s="${1:-}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

RUBY_OK=false; RUBY_V=""
if command -v ruby >/dev/null 2>&1; then RUBY_OK=true; RUBY_V="$(ruby -e 'print RUBY_VERSION' 2>/dev/null || true)"; fi
NODE_OK=false; NODE_V=""
if command -v node >/dev/null 2>&1; then NODE_OK=true; NODE_V="$(node --version 2>/dev/null || true)"; fi
PY_OK=false; PY_VER="${PY_VER:-}"
if py_real py -3 || py_real python3 || py_real python; then PY_OK=true; fi

case "$OS" in windows-bash) SHELL_KIND="git-bash" ;; *) SHELL_KIND="bash" ;; esac
SANDBOX_HINT="none"
[ -f /.dockerenv ] && SANDBOX_HINT="container"
[ -n "${CLAUDE_CODE_REMOTE:-}${COWORK:-}${CODESPACES:-}" ] && SANDBOX_HINT="remote-sandbox"
[ "$FAIL" -eq 0 ] && PASS_BOOL=true || PASS_BOOL=false

fj=""
for f in "${FAILURES[@]:-}"; do
  [ -z "$f" ] && continue
  fj="${fj:+$fj,}\"$(jstr "$f")\""
done

write_doctor_json() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || return 0
  {
    printf '{'
    printf '"os":"%s",' "$(jstr "$OS")"
    printf '"shell":"%s",' "$(jstr "$SHELL_KIND")"
    printf '"runtimes":{"ruby":%s,"python":%s,"node":%s,"bash":true},' "$RUBY_OK" "$PY_OK" "$NODE_OK"
    printf '"versions":{"ruby":"%s","python":"%s","node":"%s"},' "$(jstr "$RUBY_V")" "$(jstr "$PY_VER")" "$(jstr "$NODE_V")"
    printf '"sandbox_hint":"%s",' "$(jstr "$SANDBOX_HINT")"
    printf '"skill_sha":"%s",' "$(jstr "$SKILL_SHA")"
    printf '"behind_count":%s,' "$BEHIND_COUNT"
    printf '"agent_vision":%s,' "$AGENT_VISION"
    printf '"model_hint":"%s",' "$(jstr "$MODEL_HINT")"
    printf '"pass":%s,' "$PASS_BOOL"
    printf '"failures":[%s]' "$fj"
    printf '}\n'
  } > "$dest" 2>/dev/null || true
}
write_doctor_json "$HOME/.sigma-migration/doctor.json"
[ -n "$WORKDIR" ] && write_doctor_json "$WORKDIR/doctor.json"

echo
echo "Summary: $PASS ok, $WARN warning(s), $FAIL missing/blocking."
[ "$FAIL" -eq 0 ] && { echo "Environment looks good — proceed."; exit 0; }
echo "Fix the ✗ item(s) above, then re-run: bash scripts/doctor.sh"
exit 1
