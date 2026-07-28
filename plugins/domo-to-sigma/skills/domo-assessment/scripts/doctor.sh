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
WORKDIR="${DOCTOR_WORKDIR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    # Value-taking flags MUST verify $2 exists (bootstrap.sh's parser rule):
    # with $#=1, `shift 2` shifts nothing in bash and this loop would
    # reprocess `--workdir` forever — a silent zero-output hang.
    --workdir)
      [ $# -ge 2 ] || { echo "doctor.sh: missing value for --workdir" >&2; exit 2; }
      WORKDIR="$2"; shift 2 ;;
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
    bad "ruby not found" "Run the bootstrap: bash scripts/bootstrap.sh   — no-admin install/activation; it re-runs this doctor when done."
  else
    bad "ruby not found" "Run the bootstrap: bash scripts/bootstrap.sh   — installs only what's missing (macOS: brew; Linux: apt-get only when already root — never sudo; otherwise it names the exact admin ask)."
  fi
fi

# --- python (real interpreter, NOT the Windows Store alias stub) -----------
# Probe py -3 (Windows launcher) first, then python3/python. Reject any that
# resolves under WindowsApps — the App-Execution-Alias stub that silently no-ops.
# bootstrap.sh duplicates this probe — KEEP IN LOCKSTEP (the tableau skill's
# test-bootstrap-lockstep.sh diffs the two bodies and fails on drift).
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
        "Run the bootstrap: 'powershell -ExecutionPolicy Bypass -File scripts\\bootstrap.ps1' (user-scoped install, never admin; the stub is rejected by its probe). Manual alternative: disable the stub under Settings → Apps → Advanced app settings → App execution aliases."
  else
    bad "python3 not found" "Run the bootstrap: bash scripts/bootstrap.sh   — installs python3 (brew, or apt-get when already root — never sudo)."
  fi
fi

# --- Windows Store-stub shim ------------------------------------------------
# On windows-bash the REAL interpreter is usually `py -3`, but bare `python` /
# `python3` resolve to the Microsoft Store App-Execution-Alias stub — which
# silently no-ops and floods every tool call (and any PreToolUse hook that shells
# `python`) with "Python was not found; run … Microsoft Store" (field-observed:
# ~15 spurious errors in the first two minutes). The skill's own scripts resolve
# Python internally, so this only bites bare `python` callers. When `py -3` is
# real but `python` is the stub, drop a shim in ~/bin (git-bash auto-prepends
# ~/bin to PATH at login) so `python`/`python3` resolve to `py -3`.
if [ "$OS" = "windows-bash" ] && py_real py -3 && ! py_real python; then
  if mkdir -p "$HOME/bin" 2>/dev/null; then
    printf '#!/usr/bin/env bash\nexec py -3 "$@"\n' > "$HOME/bin/python"  2>/dev/null && chmod +x "$HOME/bin/python"  2>/dev/null
    printf '#!/usr/bin/env bash\nexec py -3 "$@"\n' > "$HOME/bin/python3" 2>/dev/null && chmod +x "$HOME/bin/python3" 2>/dev/null
    if [ -x "$HOME/bin/python" ]; then
      case ":$PATH:" in
        *":$HOME/bin:"*) ok "python Store-stub shim installed (~/bin/python → py -3; ~/bin already on PATH)" ;;
        *) warn "python Store-stub shim installed (~/bin/python → py -3)" \
                "Add ~/bin to PATH for this shell so bare 'python' stops hitting the Store stub: export PATH=\"\$HOME/bin:\$PATH\"  (git-bash auto-adds ~/bin on next login)" ;;
      esac
    fi
  fi
fi

# --- visual-similarity deps (gate 14's measured floor) ----------------------
# visual-similarity.py needs Pillow + numpy; without them the gate exits
# "SKIPPED: dep missing" instead of measuring (A/B-report field-caught: the
# deps were undeclared and the floor silently could not run on a fresh box).
# Probes the interpreter py_real just RESOLVED ($PY_ARGV — on windows-bash
# that is `py -3`, while bare `python3` may be the Store stub or absent), and
# SELF-GATES on the render scripts existing next to this doctor — the same
# adjacency gate bootstrap's payload step uses, so assessment-skill twins that
# ship neither script don't warn users into a payload the bootstrap
# (correctly) declines to install there.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "$PY_ARGV" ] && { [ -f "$HERE/visual-similarity.py" ] || [ -f "$HERE/sigma-export-png.py" ]; }; then
  if $PY_ARGV -c "import PIL, numpy, requests" >/dev/null 2>&1; then
    ok "python render deps (Pillow + numpy + requests) — sigma-export-png + visual-similarity can run"
  else
    # requests: sigma-export-png.py needs it — without it the Phase-5b/6f render
    # SILENTLY fails on a fresh env (v5.5 e2e field-caught). Pillow/numpy: the
    # gate-14 visual floor. One check, one fix line.
    warn "Pillow/numpy/requests missing — sigma-export-png (renders) and the visual-similarity floor (gate 14) cannot run" \
         "Run the bootstrap: bash scripts/bootstrap.sh   — installs the pinned render payload (pillow, numpy>=2.3, requests) with a TLS-proxy-safe pip (no admin; the 2.2.x histogram regression is also worked around in-script)."
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
    warn "python uses OpenSSL 3.x without 'truststore' — TLS verification may fail against some servers (e.g. Looker or Tableau Cloud) where curl/Ruby succeed" \
         "Run the bootstrap: bash scripts/bootstrap.sh   — installs 'truststore' and wires pip to the OS trust store. Do NOT disable TLS verification."
  fi
fi

# --- node (vendored converters are ESM run via node) -----------------------
if command -v node >/dev/null 2>&1; then
  ok "node — $(node --version 2>/dev/null)"
else
  # G1 (field-caught TWICE on the same machine): node was INSTALLED via a version
  # manager (~/.fnm) the whole time — only PATH activation was missing, because
  # version managers activate via interactive-shell profile hooks that a non-login
  # agent shell never sources. Probe the standard version-manager install dirs
  # BEFORE declaring node missing; found => print the exact PATH prepend
  # (WARN-activatable) instead of sending the user to install a runtime they have.
  # bootstrap.sh's node activation duplicates this candidate list — KEEP IN
  # LOCKSTEP (test-bootstrap-lockstep.sh Part A diffs the two glob lists;
  # bootstrap may activate additional brew opt dirs, never fewer dirs).
  NODE_VM_BIN=""
  for cand in "$HOME"/.fnm/node-versions/*/installation/bin/node \
              "$HOME"/.local/share/fnm/node-versions/*/installation/bin/node \
              "$HOME/Library/Application Support/fnm/node-versions"/*/installation/bin/node \
              "$HOME"/.nvm/versions/node/*/bin/node \
              "$HOME"/.asdf/installs/nodejs/*/bin/node \
              "$HOME"/.local/node/bin/node; do
    [ -x "$cand" ] && NODE_VM_BIN="$cand"
  done
  if [ -n "$NODE_VM_BIN" ]; then
    warn "node is INSTALLED but not on PATH ($("$NODE_VM_BIN" --version 2>/dev/null) at $NODE_VM_BIN) — a version manager that activates via interactive-shell hooks this shell never ran" \
         "Prepend it for this session: export PATH=\"$(dirname "$NODE_VM_BIN"):\$PATH\"  — no install needed. (Or run the bootstrap: bash scripts/bootstrap.sh — it activates this install and persists PATH via ~/.sigma-migration/path.sh.)"
  else
    bad "node not found (required — the vendored converters/*.mjs run via node)" "Run the bootstrap: bash scripts/bootstrap.sh   — activates a version-manager Node when one exists, else installs Node 22 LTS pinned (brew / portable ~/.local/node / the fnm route — no admin, nothing unpinned). Details: refs/environment.md #5."
  fi
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
GT="$HERE/get-token.sh"
if [ -f "$GT" ] && grep -q $'\r' "$GT" 2>/dev/null; then
  bad "get-token.sh has CRLF line endings — bash will fail with '\\r: command not found'" \
      "Fix: 'sed -i \$'s/\\r\$//' scripts/*.sh' (or set core.autocrlf=input and re-checkout)."
fi

# --- Sigma credentials (REQUIRED — fail-closed) + live token-mint smoke ----
# Missing creds used to be a WARN, so a run could start doomed and die at its
# first API call with an opaque auth error the agent improvises around. Now:
# absent creds = ✗ REQUIRED failure. When creds ARE present and the sibling
# Ruby lib exists (lib/sigma_rest.rb — the same in-process mint path the
# orchestrators use), a live token mint (bounded ~20s) proves they WORK:
# present-but-broken creds are ✗ too. SIGMA_SKIP_CRED_SMOKE=1 skips the live
# probe (genuinely offline runs). Recorded in doctor.json
# {cred_smoke:{sigma: pass|fail|skipped}}.
SMOKE_SIGMA="skipped"
_SIGMA_CREDS=false
# Content-based presence (the Tableau twin's pattern below): bare
# file-existence would misread an env file holding only non-credential lines
# (anything a future writer persists there) as "credentials present".
if grep -Eq 'SIGMA_(API_TOKEN|CLIENT_ID)' "$HOME/.sigma-migration/env" 2>/dev/null \
   || [ -n "${SIGMA_API_TOKEN:-}" ] || [ -n "${SIGMA_CLIENT_ID:-}" ]; then
  _SIGMA_CREDS=true
fi
if [ "$_SIGMA_CREDS" != true ]; then
  bad "no Sigma credentials found (REQUIRED — the run would die at its first Sigma API call)" \
      "Run 'ruby scripts/setup.rb' once (writes ~/.sigma-migration/env), or export SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET (+ SIGMA_BASE_URL)."
elif [ -n "${SIGMA_SKIP_CRED_SMOKE:-}" ]; then
  ok "Sigma credentials present (live token-mint smoke SKIPPED: SIGMA_SKIP_CRED_SMOKE)"
elif [ -f "$HERE/lib/sigma_rest.rb" ] && command -v ruby >/dev/null 2>&1; then
  if ruby -e '$LOAD_PATH.unshift File.join(ARGV[0], "lib"); require "timeout"; require "sigma_rest"; Timeout.timeout(20) { Sigma.refresh_token! }' "$HERE" >/dev/null 2>&1; then
    ok "Sigma credentials present + live token mint OK"
    SMOKE_SIGMA="pass"
  else
    bad "Sigma credentials present but the live token mint FAILED (bad/stale client id/secret, or wrong SIGMA_BASE_URL)" \
        "Re-run 'ruby scripts/setup.rb' with fresh values (Sigma: Administration → APIs & Embed Secrets). Genuinely offline? SIGMA_SKIP_CRED_SMOKE=1 skips this probe."
    SMOKE_SIGMA="fail"
  fi
else
  ok "Sigma credentials present (mint smoke skipped — no ruby lib next to this doctor)"
fi

# --- Tableau credentials (self-gated: tableau skill only) --------------------
# Plugin-aware like the hyperapi check: only speaks up where the sibling
# Tableau scripts exist (setup-tableau.rb + lib/tableau_rest.rb). ABSENT
# Tableau creds stay a WARN — Sigma-only skills share this doctor and must not
# fail on them. PRESENT-but-broken creds are ✗: a live PAT signin smoke
# (bounded ~20s) catches the expired-PAT / wrong-site class before a run
# starts doomed. SIGMA_SKIP_CRED_SMOKE=1 skips. Recorded in doctor.json
# {cred_smoke:{tableau: pass|fail|skipped}}.
SMOKE_TABLEAU="skipped"
if [ -f "$HERE/setup-tableau.rb" ] && [ -f "$HERE/lib/tableau_rest.rb" ]; then
  _TAB_CREDS=false
  if { [ -n "${TABLEAU_PAT_NAME:-}" ] && [ -n "${TABLEAU_PAT_SECRET:-}" ]; } || \
     grep -q 'TABLEAU_PAT_SECRET' "$HOME/.sigma-migration/env" 2>/dev/null; then
    _TAB_CREDS=true
  fi
  if [ "$_TAB_CREDS" != true ]; then
    warn "no Tableau credentials found (needed for Tableau discovery)" \
         "Run 'ruby scripts/setup-tableau.rb' once (PAT), or export TABLEAU_PAT_NAME/TABLEAU_PAT_SECRET/TABLEAU_SITE_CONTENT_URL (+ TABLEAU_SERVER_URL)."
  elif [ -n "${SIGMA_SKIP_CRED_SMOKE:-}" ]; then
    ok "Tableau credentials present (live PAT signin smoke SKIPPED: SIGMA_SKIP_CRED_SMOKE)"
  elif command -v ruby >/dev/null 2>&1; then
    # Two attempts, 30s bound each: a single 20s-bounded probe false-negatived
    # in a real field run (parallel-agent load) while get-tableau-token.sh
    # minted fine seconds later — a doctor that cries wolf trains agents to
    # ignore it.
    _TAB_SMOKE_RB='$LOAD_PATH.unshift File.join(ARGV[0], "lib"); require "timeout"; require "tableau_rest"; Timeout.timeout(30) { Tableau.refresh_token! }'
    if ruby -e "$_TAB_SMOKE_RB" "$HERE" >/dev/null 2>&1 || ruby -e "$_TAB_SMOKE_RB" "$HERE" >/dev/null 2>&1; then
      ok "Tableau credentials present + live PAT signin OK"
      SMOKE_TABLEAU="pass"
    else
      bad "Tableau credentials present but the live PAT signin FAILED twice (expired/revoked PAT, wrong site or server URL)" \
          "Re-run 'ruby scripts/setup-tableau.rb' with a fresh PAT. Genuinely offline? SIGMA_SKIP_CRED_SMOKE=1 skips this probe."
      SMOKE_TABLEAU="fail"
    fi
  fi
fi

# --- Looker API reachability (self-gated: looker skills only) ----------------
# Plugin-aware like the Tableau checks: only speaks up where the sibling Looker
# client exists (looker_api.py) and a ~/.looker/looker.ini is present. Modern
# Google-hosted Looker serves the API on 443; the legacy :19999 port is often
# unreachable. The client self-heals (looker_api falls back to 443), but flag a
# stale ini so the user can fix it. Uses the UNAUTHENTICATED /api/4.0/versions
# endpoint via curl (OS trust store — isolates the PORT question from the TLS
# one above). Recorded in doctor.json {cred_smoke:{looker: pass|fallback|fail|skipped}}.
LOOKER_PROBE="skipped"
LK_INI="$HOME/.looker/looker.ini"
if [ -f "$HERE/looker_api.py" ] && [ -f "$LK_INI" ] && command -v curl >/dev/null 2>&1; then
  LK_BASE="$(sed -n 's/^[[:space:]]*base_url[[:space:]]*=[[:space:]]*//p' "$LK_INI" | head -1 | tr -d '\r')"
  LK_BASE="${LK_BASE%/}"
  if [ -n "$LK_BASE" ]; then
    LK_NOPORT="$(printf '%s' "$LK_BASE" | sed -E 's#^(https?://[^/:]+)(:[0-9]+)?.*#\1#')"
    if curl -sS -m 8 -o /dev/null "$LK_BASE/api/4.0/versions" 2>/dev/null; then
      ok "Looker API reachable at $LK_BASE"
      LOOKER_PROBE="pass"
    elif [ "$LK_NOPORT" != "$LK_BASE" ] && curl -sS -m 8 -o /dev/null "$LK_NOPORT/api/4.0/versions" 2>/dev/null; then
      warn "Looker base_url ($LK_BASE) is unreachable but $LK_NOPORT (443) answers — looker_api will self-heal to 443 at run time" \
           "Update base_url in ~/.looker/looker.ini to '$LK_NOPORT' (drop the legacy :19999 API port), or set LOOKER_BASE_URL."
      LOOKER_PROBE="fallback"
    else
      warn "Looker API not reachable at $LK_BASE (network / VPN / instance URL?)" \
           "Confirm the Looker instance URL and that this host can reach its API 4.0 endpoint."
      LOOKER_PROBE="fail"
    fi
  fi
fi

# --- tableauhyperapi (informational — embedded-extract workbooks only) -----
# Embedded-extract (.twbx) workbooks land their frozen data via
# land-extracts.py, which needs the Hyper API. Not REQUIRED: warn-level only,
# with the exact remediation. The human check SELF-GATES on land-extracts.py
# existing next to this script, so this shared doctor stays byte-identical
# across plugins and only speaks up where the landing path exists (tableau).
# The JSON field is emitted everywhere for a uniform schema.
HYPERAPI=false
for _pyx in python3 python; do
  if command -v "$_pyx" >/dev/null 2>&1 && "$_pyx" -c 'import tableauhyperapi' >/dev/null 2>&1; then HYPERAPI=true; break; fi
done
if [ "$HYPERAPI" != true ] && command -v py >/dev/null 2>&1 && py -3 -c 'import tableauhyperapi' >/dev/null 2>&1; then HYPERAPI=true; fi
if [ -f "$HERE/land-extracts.py" ]; then
  if [ "$HYPERAPI" = true ]; then
    ok "tableauhyperapi present — embedded-extract workbooks can land via scripts/land-extracts.py"
  else
    warn "tableauhyperapi not installed (only needed for embedded-extract workbooks)" \
         "pip install tableauhyperapi pandas snowflake-connector-python — see refs/extract-landing.md"
  fi
fi

# --- skill version drift + build-age stamp (v3 §2.1, v5.6 item 4) ----------
# A plugin install pins a git SHA and never self-updates; running a stale SHA
# silently ships pre-fidelity-layer output. Record {skill_sha, behind_count,
# days_since_commit}; the orchestrator preflight FAILs above a threshold.
# Bounded, best-effort fetch (stalled network capped ~6s); skip the drift
# fetch with SIGMA_SKIP_VERSION_CHECK=1 (the local age stamp still runs — it
# needs no network). No git at all (a mirror/plugin file-copy install) stamps
# skill_sha 'unknown (no git — mirror/plugin install)' so downstream tooling
# and bug reports can always say WHICH build (or that nobody can tell).
SKILL_SHA=""; BEHIND_COUNT="null"; DAYS_SINCE_COMMIT="null"
if command -v git >/dev/null 2>&1 && git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
  SKILL_SHA="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || true)"
  _cts="$(git -C "$HERE" log -1 --format=%ct 2>/dev/null || true)"
  case "$_cts" in
    ''|*[!0-9]*) : ;;
    *) DAYS_SINCE_COMMIT=$(( ($(date +%s) - _cts) / 86400 )) ;;
  esac
  # Skip on a SHALLOW clone (CI checkout, some installs): rev-list against a
  # grafted origin/main returns a bogus count (a false "hundreds behind").
  _shallow="$(git -C "$HERE" rev-parse --is-shallow-repository 2>/dev/null)"
  if [ "$_shallow" != "true" ] && [ -z "${SIGMA_SKIP_VERSION_CHECK:-}" ]; then
    git -C "$HERE" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=6 fetch --quiet origin 2>/dev/null
    _bc="$(git -C "$HERE" rev-list --count HEAD..origin/main 2>/dev/null || true)"
    case "$_bc" in ''|*[!0-9]*) BEHIND_COUNT="null" ;; *) BEHIND_COUNT="$_bc" ;; esac
  fi
  _age_note=""
  [ "$DAYS_SINCE_COMMIT" != "null" ] && _age_note=", last commit ${DAYS_SINCE_COMMIT} day(s) ago"
  if [ "$BEHIND_COUNT" = "null" ]; then
    [ -n "$SKILL_SHA" ] && ok "skill build $SKILL_SHA (drift check skipped/offline$_age_note)"
  elif [ "$BEHIND_COUNT" -gt 0 ] 2>/dev/null; then
    warn "skill is ${BEHIND_COUNT} commit(s) behind origin/main (installed $SKILL_SHA$_age_note) — you may be missing fidelity-layer fixes" \
         "Update: 'git -C \"$HERE\" pull' (or reinstall the plugin). SIGMA_SKIP_VERSION_CHECK=1 skips this probe."
  else
    ok "skill build $SKILL_SHA (current with origin/main$_age_note)"
  fi
  # Age WARN is independent of the network drift check: a >14-day-old build on
  # a fast-moving skill is the field failure class where a run re-hits bugs
  # fixed weeks earlier and nobody realizes the install is stale.
  if [ "$DAYS_SINCE_COMMIT" != "null" ] && [ "$DAYS_SINCE_COMMIT" -gt 14 ] 2>/dev/null; then
    warn "skill build $SKILL_SHA is ${DAYS_SINCE_COMMIT} days old — your build may predate current fixes" \
         "Update your mirror/plugin: 'git -C \"$HERE\" pull' (or reinstall). Re-run doctor after."
  fi
else
  SKILL_SHA="unknown (no git — mirror/plugin install)"
  warn "skill build SHA unknown (no git — mirror/plugin install)" \
       "Build age cannot be measured; if behavior looks pre-fix, refresh the mirror / reinstall the plugin and re-run doctor."
fi

# --- agent capability fingerprint (v3 §2.2) --------------------------------
# The doctor can't introspect the driving agent, so vision is asserted by the
# caller: a vision-capable session exports SIGMA_AGENT_VISION=true. When that is
# UNSET, auto-assert true iff the model_hint is a known vision-capable Claude
# (Opus/Sonnet/Haiku/Fable/claude-3+), so a genuinely vision-capable session
# isn't forced to hand-flip the flag before the visual gate will accept a
# verdict. A model hint that does NOT match still defaults false, so the visual
# gate (D5) still fails LOUDLY rather than accepting a blind attestation.
# model_hint is free-form (e.g. "claude-opus-4-8").
MODEL_HINT="${SIGMA_MODEL_HINT:-}"
# W1.8 env-var hygiene: the flag is SIGMA_AGENT_VISION (UPPERCASE). A lowercase
# `sigma_agent_vision` (copied verbatim from a task brief) is a silent no-op — it
# was exactly why the 2026-07 run's visual gates reported "cannot legitimately
# pass" and the agent then hand-edited doctor.json to force the flag. Detect the
# common miscase, warn loudly, and HONOR it so no hand-edit is tempted.
if [ -z "${SIGMA_AGENT_VISION:-}" ] && [ -n "${sigma_agent_vision:-}" ]; then
  warn "env var 'sigma_agent_vision' is set (=${sigma_agent_vision}) but IGNORED — the flag is SIGMA_AGENT_VISION (uppercase)" \
       "The visual gates read only the uppercase name; a lowercase copy is a silent no-op. Honoring it this run — fix your export to: SIGMA_AGENT_VISION=${sigma_agent_vision}"
  SIGMA_AGENT_VISION="${sigma_agent_vision}"
fi
case "${SIGMA_AGENT_VISION:-}" in
  true|1|yes|TRUE|True) AGENT_VISION=true ;;
  '')
    case "$(printf '%s' "$MODEL_HINT" | tr '[:upper:]' '[:lower:]')" in
      *opus*|*sonnet*|*haiku*|*fable*|claude-3*|claude-4*|claude-5*) AGENT_VISION=true ;;
      *) AGENT_VISION=false ;;
    esac ;;
  *) AGENT_VISION=false ;;
esac

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
    printf '"cred_smoke":{"sigma":"%s","tableau":"%s","looker":"%s"},' "$SMOKE_SIGMA" "$SMOKE_TABLEAU" "$LOOKER_PROBE"
    printf '"hyperapi_present":%s,' "$HYPERAPI"
    printf '"skill_sha":"%s",' "$(jstr "$SKILL_SHA")"
    printf '"behind_count":%s,' "$BEHIND_COUNT"
    printf '"days_since_commit":%s,' "$DAYS_SINCE_COMMIT"
    printf '"agent_vision":%s,' "$AGENT_VISION"
    printf '"model_hint":"%s",' "$(jstr "$MODEL_HINT")"
    printf '"generated_at":"%s",' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
echo "Fix the ✗ item(s) above — missing runtimes/payloads are one command: bash scripts/bootstrap.sh — then re-run: bash scripts/doctor.sh"
exit 1
