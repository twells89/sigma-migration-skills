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

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n     ↳ %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
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
  PY_DESC="$ver  ($where)"; return 0
}
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

echo
echo "Summary: $PASS ok, $WARN warning(s), $FAIL missing/blocking."
[ "$FAIL" -eq 0 ] && { echo "Environment looks good — proceed."; exit 0; }
echo "Fix the ✗ item(s) above, then re-run: bash scripts/doctor.sh"
exit 1
