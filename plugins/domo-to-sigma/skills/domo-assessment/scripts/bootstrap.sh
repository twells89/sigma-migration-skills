#!/usr/bin/env bash
# bootstrap.sh — ONE command that takes a fresh machine to doctor-green
# (macOS / Linux / Windows Git-Bash). PLAN-v3 PR-15: environment bootstrap
# burned ~25–30% of field tokens (hand-driven runtime installs, TTY/creds
# failures) — this script replaces every "install X by hand" instruction.
#
#   bash scripts/bootstrap.sh [--workdir DIR]     # verify + install + creds + doctor
#   bash scripts/bootstrap.sh --check             # DRY RUN: report what WOULD change,
#                                                 # install nothing, touch nothing.
#   Creds chaining (optional; passed through to setup.rb — the single
#   credential writer; values are never echoed):
#     --client-id ID --client-secret SECRET [--base-url URL] [--connection-id ID]
#     --from-env                                  # persist from exported env vars
#
# Contract:
#   * IDEMPOTENT — a complete environment no-ops straight into a doctor run.
#   * NON-INTERACTIVE / no-TTY-safe — never prompts; the creds flow runs only
#     when SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET (and Tableau PAT vars, where the
#     tableau scripts ship) are already exported (setup.rb --from-env).
#   * NEVER requires admin — activates runtimes already installed via version
#     managers (rbenv/nvm/fnm/asdf/pyenv, Homebrew keg-only) by prepending
#     their bin dirs, installs via user-scoped Homebrew where present (apt-get
#     only when ALREADY root, e.g. a bare CI container — there is no sudo path
#     in this script), and pip-installs with --user. It never edits system dirs.
#   * PINNED — new Node installs are pinned to the 22 LTS line (maintenance
#     until 2027-04-30; the 20 line reached end-of-life 2026-04-30, so a fresh
#     20.x install would land an unsupported runtime. SIGMA_BOOTSTRAP_NODE_PIN
#     overrides). The Python render payload pins numpy>=2.3 and installs with
#     a TLS-proxy-safe pip chain (never verification off).
#   * Finishes by running scripts/doctor.sh (which writes doctor.json — the
#     report the orchestrator gates on) and writing the bootstrap SENTINEL
#     (~/.sigma-migration/bootstrap.json, + <WORKDIR>/bootstrap.json when
#     --workdir is given). intake.rb / migrate-*.rb refuse to start without it.
#   * --check makes NO network calls and NO writes (doctor is skipped too), so
#     it is testable offline; exit 0 = environment complete, 1 = pieces missing.
#
# Exit codes: 0 complete (env green; full mode: doctor passed + sentinel
# written) · 1 incomplete (check: pieces missing; full: an install failed or
# doctor still red) · 2 usage.
#
# Windows PowerShell users: run scripts\bootstrap.ps1 instead.
set -u

MODE=full
WORKDIR="${BOOTSTRAP_WORKDIR:-}"
CRED_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    # Value-taking flags MUST verify $2 exists: with $#=1, `shift 2` shifts
    # nothing in bash and the loop would reprocess the same flag forever — a
    # silent zero-output hang.
    --workdir)
      [ $# -ge 2 ] || { echo "bootstrap.sh: missing value for $1 (see --help)" >&2; exit 2; }
      WORKDIR="$2"; shift 2 ;;
    --workdir=*) WORKDIR="${1#*=}"; shift ;;
    # Creds chaining: pass-through to setup.rb (same flag names). setup.rb
    # stays the SINGLE credential writer; values are never echoed by this
    # script (the check-mode plan line prints a redacted count only).
    --client-id|--client-secret|--base-url|--connection-id)
      [ $# -ge 2 ] || { echo "bootstrap.sh: missing value for $1 (see --help)" >&2; exit 2; }
      CRED_ARGS+=("$1" "$2"); shift 2 ;;
    --from-env) CRED_ARGS+=(--from-env); shift ;;
    -h|--help)
      # Structural range (2 .. the line before `set -u`), so header edits
      # can't silently truncate the printed help.
      sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "bootstrap.sh: unknown arg '$1' (supported: --check, --workdir DIR, --from-env, --client-id/--client-secret/--base-url/--connection-id VALUE)" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HOME/.sigma-migration"
PATH_SNIPPET="$STATE_DIR/path.sh"
# 22 = the newest LTS line already in MAINTENANCE (until 2027-04-30). Node 20
# reached EOL 2026-04-30 — never pin a default to an end-of-lifed line.
# Exact patch = a known-published 22.x release (tarballs exist for
# darwin/linux x64+arm64). Bump deliberately — never float, never guess.
NODE_PIN="${SIGMA_BOOTSTRAP_NODE_PIN:-22.14.0}"
NODE_PIN_MAJOR="${NODE_PIN%%.*}"

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows-bash ;;
  Darwin) OS=macos ;; Linux) OS=linux ;; *) OS=unknown ;;
esac

NEEDED=0            # pieces the env is missing (check mode: WOULD-do count)
INSTALL_FAILED=0
ACTIONS=""          # newline-joined action log for the sentinel
PATH_ADDED=""       # newline-joined PATH prepends persisted this run

say()  { printf '%s\n' "$*"; }
okay() { printf '  \xe2\x9c\x93 %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
act()  { ACTIONS="${ACTIONS}${ACTIONS:+
}$1"; }
# missing piece: in --check report WOULD + count; in full mode the caller does
# the install right after (and reports its own outcome).
plan() { # $1 = piece, $2 = what bootstrap does about it
  NEEDED=$((NEEDED+1))
  if [ "$MODE" = check ]; then
    printf '  \xe2\x9c\x97 %s\n     WOULD: %s\n' "$1" "$2"
  else
    printf '  \xe2\x9c\x97 %s\n     \xe2\x86\x92 %s\n' "$1" "$2"
  fi
}

# Prepend a dir to PATH for this run and persist it to ~/.sigma-migration/path.sh
# so later sessions can `source` one file instead of re-diagnosing (doctor's
# node-installed-but-not-on-PATH class). Never touches shell profiles.
activate_path() { # $1 = bin dir
  case ":$PATH:" in *":$1:"*) return 0 ;; esac
  PATH="$1:$PATH"; export PATH
  [ "$MODE" = check ] && return 0
  mkdir -p "$STATE_DIR" 2>/dev/null
  chmod 700 "$STATE_DIR" 2>/dev/null
  if [ ! -f "$PATH_SNIPPET" ] || ! grep -F "\"$1:\$PATH\"" "$PATH_SNIPPET" >/dev/null 2>&1; then
    printf 'export PATH="%s:$PATH"\n' "$1" >> "$PATH_SNIPPET"
    chmod 600 "$PATH_SNIPPET" 2>/dev/null
  fi
  PATH_ADDED="${PATH_ADDED}${PATH_ADDED:+
}$1"
  act "path-activate: $1"
}

# Newest matching bin dir from version-manager install layouts (globs sorted, last wins).
latest_bindir() { # $@ = glob patterns of runtime BINARIES; prints the binary's dir
  _lb_out=""
  for _lb_cand in "$@"; do [ -x "$_lb_cand" ] && _lb_out="$_lb_cand"; done
  [ -n "$_lb_out" ] && dirname "$_lb_out"
}

# purge_env_kv_line KEY — self-heal: drop a stale `export KEY=…` line an OLDER
# bootstrap generation persisted into ~/.sigma-migration/env (pip wiring is
# session-only now; a stale PIP_USE_FEATURE line under pip < 22.2 is rejected
# at parse time, killing EVERY pip call in every shell that sources the file).
# Rewrites in place via cat-> so the creds file keeps its inode and 600 mode.
# Full mode only — callers gate on MODE (--check makes no writes).
purge_env_kv_line() {
  _pe_file="$STATE_DIR/env"
  { [ -f "$_pe_file" ] && grep -q "^export $1=" "$_pe_file" 2>/dev/null; } || return 0
  _pe_tmp="$(mktemp)" || return 0
  grep -v "^export $1=" "$_pe_file" > "$_pe_tmp" 2>/dev/null
  cat "$_pe_tmp" > "$_pe_file" 2>/dev/null && rm -f "$_pe_tmp"
  chmod 600 "$_pe_file" 2>/dev/null
  act "self-heal: removed stale $1 wiring from $_pe_file"
}

brew_ok() { command -v brew >/dev/null 2>&1; }

# apt-get is used ONLY when this process is already root (bare CI containers)
# — there is no sudo path in this script, by contract.
APT_UPDATED=false
apt_root_ok() { [ "$(id -u 2>/dev/null)" = "0" ] && command -v apt-get >/dev/null 2>&1; }
apt_root_install() { # pkgs... (full mode only — callers gate on MODE)
  apt_root_ok || return 1
  if [ "$APT_UPDATED" = false ]; then
    apt-get update -qq >/dev/null 2>&1 || return 1
    APT_UPDATED=true
  fi
  apt-get install -y -qq --no-install-recommends "$@" >/dev/null 2>&1
}

# ── Windows (Git-Bash) package-manager helpers ───────────────────────────────
# winget first — user scope requested, interactivity disabled. EXE-based
# installers do not all honor scope deterministically (some still demand UAC
# even user-scoped), so an elevation-needing install fails cleanly here and
# falls through to scoop, which is user-dir by design — the no-admin contract
# holds either way. scoop commands run through powershell.exe because scoop's
# own entrypoint is a .ps1. Full mode only — callers gate on MODE.
winget_install() { # <package-id>
  command -v winget >/dev/null 2>&1 || command -v winget.exe >/dev/null 2>&1 || return 1
  winget.exe install --id "$1" --exact --source winget --scope user \
    --accept-package-agreements --accept-source-agreements \
    --disable-interactivity >/dev/null 2>&1
}
scoop_ps() { # scoop subcommand string, e.g. "install ruby"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "scoop $1" >/dev/null 2>&1
}
ensure_scoop() {
  if powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
       "if (Get-Command scoop -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" >/dev/null 2>&1; then
    return 0
  fi
  # Official user-dir installer (https://scoop.sh) — no admin, no machine writes.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
    "irm get.scoop.sh | iex" >/dev/null 2>&1
}
win_install() { # <winget-id> <scoop-pkg> <label>
  if winget_install "$1"; then
    act "install: $3 (winget $1, user scope)"
    return 0
  fi
  if ensure_scoop && scoop_ps "install $2"; then
    act "install: $3 (scoop $2, portable user dir)"
    activate_path "$HOME/scoop/shims"
    return 0
  fi
  return 1
}

# node_portable_install — pinned official tarball into ~/.local/node, the exact
# path the doctor's version-manager probe list already recognizes. User-dir,
# no elevation. Full mode only — callers gate on MODE.
node_portable_install() {
  local plat arch url tmp rc
  case "$OS" in macos) plat=darwin ;; *) plat=linux ;; esac
  case "$(uname -m 2>/dev/null)" in arm64|aarch64) arch=arm64 ;; *) arch=x64 ;; esac
  url="https://nodejs.org/dist/v${NODE_PIN}/node-v${NODE_PIN}-${plat}-${arch}.tar.gz"
  # Bare containers can lack curl itself — fetch it the no-sudo way first.
  if ! command -v curl >/dev/null 2>&1; then
    apt_root_install curl ca-certificates || return 1
  fi
  tmp="$(mktemp -d)" || return 1
  ( cd "$tmp" \
      && curl -fsSL --proto '=https' -o node.tar.gz "$url" \
      && tar -xzf node.tar.gz \
      && mkdir -p "$HOME/.local" \
      && rm -rf "$HOME/.local/node" \
      && mv "node-v${NODE_PIN}-${plat}-${arch}" "$HOME/.local/node" ) >/dev/null 2>&1
  rc=$?
  rm -rf "$tmp"
  return $rc
}

# Real-Python probe (rejects the Windows Store alias stub) — doctor.sh
# duplicates this body: KEEP IN LOCKSTEP (the tableau skill's
# test-bootstrap-lockstep.sh diffs the two bodies, ignoring only the PY_*
# success line, and fails on drift).
py_real() {
  local exe="$1"; shift
  command -v "$exe" >/dev/null 2>&1 || return 1
  local ver; ver="$("$exe" "$@" --version 2>&1)" || return 1
  case "$ver" in Python\ [0-9]*) : ;; *) return 1 ;; esac
  local where; where="$("$exe" "$@" -c 'import sys;print(sys.executable)' 2>/dev/null)" || return 1
  case "$(printf '%s' "$where" | tr 'A-Z' 'a-z')" in *windowsapps*) return 1 ;; esac
  PY_RUN="$exe${*:+ $*}"; return 0
}

say "Environment bootstrap — host: $OS  mode: $MODE"
# Up-front write disclosure (both modes — in --check it is the complete list
# of what a full run WOULD touch outside the workdir; nothing else, ever):
say "Writes outside the workdir: user-dir runtime installs, PATH lines in $PATH_SNIPPET, creds via setup.rb in $STATE_DIR/env, and the $STATE_DIR/{bootstrap,doctor}.json reports (disclosed; nothing else)."
say ""

# Source a previously persisted PATH snippet first: a re-run should see what the
# last bootstrap activated (idempotency).
[ -f "$PATH_SNIPPET" ] && . "$PATH_SNIPPET" 2>/dev/null

# ── ruby ─────────────────────────────────────────────────────────────────────
if command -v ruby >/dev/null 2>&1; then
  okay "ruby $(ruby -e 'print RUBY_VERSION' 2>/dev/null)"
else
  RUBY_DIR="$(latest_bindir \
    "$HOME"/.rbenv/versions/*/bin/ruby \
    "$HOME"/.rubies/*/bin/ruby \
    "$HOME"/.asdf/installs/ruby/*/bin/ruby \
    /opt/homebrew/opt/ruby/bin/ruby \
    /usr/local/opt/ruby/bin/ruby)"
  if [ -n "$RUBY_DIR" ]; then
    plan "ruby installed but not on PATH ($RUBY_DIR)" "activate it (prepend to PATH; persisted in $PATH_SNIPPET)"
    [ "$MODE" = full ] && { activate_path "$RUBY_DIR"; okay "ruby $(ruby -e 'print RUBY_VERSION' 2>/dev/null) (activated from $RUBY_DIR)"; }
  elif brew_ok; then
    plan "ruby not found" "brew install ruby (user-scoped Homebrew; no admin)"
    if [ "$MODE" = full ]; then
      if brew install ruby >/dev/null 2>&1; then
        BREW_RUBY="$(brew --prefix ruby 2>/dev/null)/bin"
        [ -d "$BREW_RUBY" ] && activate_path "$BREW_RUBY"
        act "install: ruby (brew)"
        command -v ruby >/dev/null 2>&1 && okay "ruby $(ruby -e 'print RUBY_VERSION' 2>/dev/null) (brew)" || { INSTALL_FAILED=1; note "brew install ruby finished but ruby still not resolvable"; }
      else
        INSTALL_FAILED=1; note "brew install ruby FAILED — see brew output; re-run bootstrap after fixing"
      fi
    fi
  elif apt_root_ok; then
    plan "ruby not found" "apt-get install ruby (this process is already root — no sudo involved)"
    if [ "$MODE" = full ]; then
      if apt_root_install ruby && command -v ruby >/dev/null 2>&1; then
        act "install: ruby (apt-get, root)"
        okay "ruby $(ruby -e 'print RUBY_VERSION' 2>/dev/null) (apt-get)"
      else
        INSTALL_FAILED=1; note "apt-get install ruby FAILED — re-run bootstrap after fixing"
      fi
    fi
  elif [ "$OS" = windows-bash ]; then
    # 3.4 = the newest 3.x in NORMAL maintenance (3.3 is security-only until
    # ~2027-03; 4.0 is current stable but a major-line jump the orchestrators
    # haven't been gem-vetted for). Known skew: the scoop fallback's
    # main-bucket 'ruby' floats at current stable (4.x) — winget is the
    # pinned route; scoop is best-effort.
    plan "ruby not found" "winget install RubyInstallerTeam.Ruby.3.4 (user scope; scoop 'ruby' as portable fallback — no admin)"
    if [ "$MODE" = full ]; then
      if win_install RubyInstallerTeam.Ruby.3.4 ruby ruby; then
        if command -v ruby >/dev/null 2>&1; then
          okay "ruby $(ruby -e 'print RUBY_VERSION' 2>/dev/null) (windows package manager)"
        else
          note "ruby installed but not resolvable in THIS shell (winget PATH edits land in new shells) — reopen Git Bash and re-run bootstrap"
        fi
      else
        INSTALL_FAILED=1; note "ruby install FAILED (winget and scoop both unavailable/failed) — from PowerShell run: powershell -ExecutionPolicy Bypass -File scripts\\bootstrap.ps1"
      fi
    fi
  else
    plan "ruby not found (no version-manager install, no Homebrew, not root-with-apt)" \
         "no admin-free install route on this host — tell the USER to provide ruby (e.g. install Homebrew or rbenv), then re-run bootstrap"
    [ "$MODE" = full ] && INSTALL_FAILED=1
  fi
fi

# ── python3 ──────────────────────────────────────────────────────────────────
PY_RUN=""
if py_real py -3 || py_real python3 || py_real python; then
  okay "python ($PY_RUN) $($PY_RUN --version 2>&1 | sed 's/^Python //')"
else
  PY_DIR="$(latest_bindir \
    "$HOME"/.pyenv/versions/*/bin/python3 \
    "$HOME"/.asdf/installs/python/*/bin/python3 \
    /opt/homebrew/opt/python@*/bin/python3 \
    /usr/local/opt/python@*/bin/python3)"
  if [ -n "$PY_DIR" ]; then
    plan "python3 installed but not on PATH ($PY_DIR)" "activate it (prepend to PATH; persisted in $PATH_SNIPPET)"
    [ "$MODE" = full ] && { activate_path "$PY_DIR"; py_real python3 && okay "python ($PY_RUN) activated from $PY_DIR"; }
  elif brew_ok; then
    plan "python3 not found" "brew install python (user-scoped Homebrew; no admin)"
    if [ "$MODE" = full ]; then
      if brew install python >/dev/null 2>&1; then
        act "install: python (brew)"
        py_real python3 && okay "python ($PY_RUN) (brew)" || { INSTALL_FAILED=1; note "brew install python finished but python3 still not resolvable"; }
      else
        INSTALL_FAILED=1; note "brew install python FAILED — see brew output; re-run bootstrap after fixing"
      fi
    fi
  elif apt_root_ok; then
    plan "python3 not found" "apt-get install python3 python3-pip (this process is already root — no sudo involved)"
    if [ "$MODE" = full ]; then
      if apt_root_install python3 python3-pip && py_real python3; then
        act "install: python3 (+pip) (apt-get, root)"
        okay "python ($PY_RUN) (apt-get)"
      else
        INSTALL_FAILED=1; note "apt-get install python3 FAILED — re-run bootstrap after fixing"
      fi
    fi
  elif [ "$OS" = windows-bash ]; then
    # 3.13: still in bugfix until 2026-10 (3.14 is the newest line; numpy
    # 2.3.2+ supports 3.11–3.14, so either works — 3.13 is kept as the
    # longer-field-proven installer while it remains in bugfix).
    plan "python3 not found" "winget install Python.Python.3.13 (user scope; scoop 'python' as portable fallback — no admin)"
    if [ "$MODE" = full ]; then
      if win_install Python.Python.3.13 python python; then
        if py_real py -3 || py_real python3 || py_real python; then
          okay "python ($PY_RUN) (windows package manager; the Store alias stub is rejected by the probe)"
        else
          note "python installed but not resolvable in THIS shell (winget PATH edits land in new shells) — reopen Git Bash and re-run bootstrap"
        fi
      else
        INSTALL_FAILED=1; note "python install FAILED (winget and scoop both unavailable/failed) — from PowerShell run: powershell -ExecutionPolicy Bypass -File scripts\\bootstrap.ps1"
      fi
    fi
  else
    plan "python3 not found (no version-manager install, no Homebrew, not root-with-apt)" \
         "no admin-free install route on this host — tell the USER to provide python3, then re-run bootstrap"
    [ "$MODE" = full ] && INSTALL_FAILED=1
  fi
fi

# pip --user install with escalating, NAMED fallbacks — never verification off:
#   1) plain --user
#   2) PEP 668 "externally-managed-environment" (Homebrew/Debian Python):
#      retry --user --break-system-packages (says why first)
#   3) TLS-intercepting corporate proxy (the S2 field-failure class): retry
#      verifying against the OS trust store — which carries the corporate CA —
#      via pip's truststore feature, ACCUMULATING rung 2's flags (an enterprise
#      apt/Homebrew host behind a TLS proxy needs the union, not either alone).
#      Honest scope: the flag helps only pip 22.2–24.1 with truststore
#      importable — pip >= 24.2 uses the OS store by default, and a corporate
#      CA absent from the OS store needs PIP_CERT. NEVER --trusted-host.
#      The rung is GATED on exactly that scope (pip_truststore_window +
#      truststore importable — never while installing truststore itself);
#      outside it the helper prints the PIP_CERT remediation instead of a
#      retry that cannot work, and the retry logs to a SEPARATE file so the
#      original TLS error is never overwritten.
# On final failure the last 4 pip log lines are shown (the old helper
# swallowed all output, leaving TLS/proxy failures opaque).
pip_user_install() {
  _pi_log="$(mktemp)" || return 1
  _pi_tls="$(mktemp)" || { rm -f "$_pi_log"; return 1; }
  _pi_extra=""
  $PY_RUN -m pip install --user --quiet "$@" >/dev/null 2>"$_pi_log"; _pi_rc=$?
  if [ $_pi_rc -ne 0 ] && grep -qi 'externally.managed' "$_pi_log"; then
    note "pip: externally-managed interpreter (PEP 668) — retrying with --user --break-system-packages"
    _pi_extra="--break-system-packages"
    $PY_RUN -m pip install --user "$_pi_extra" --quiet "$@" >/dev/null 2>"$_pi_log"; _pi_rc=$?
  fi
  if [ $_pi_rc -ne 0 ] && grep -qiE 'ssl|certificate' "$_pi_log"; then
    # Rung 3 is gated TWICE. (a) pip_truststore_window: below 22.2 pip rejects
    # --use-feature=truststore AT PARSE TIME, and because the retry wrote to
    # the same log it ERASED the real TLS error this helper exists to surface
    # (macOS Command Line Tools python ships pip 21.2.4 — common, not exotic).
    # (b) TRUSTSTORE_OK: rung 3 asks pip to use a feature provided by the
    # truststore package, so it is chicken-and-egg on the very call that
    # installs truststore. When either gate says no, print the ACTIONABLE
    # remediation instead of a retry that cannot work.
    if ! pip_truststore_window; then
      note "pip: TLS failure — NOT retrying with --use-feature=truststore: this pip is outside the [22.2, 24.2) window where that opt-in exists and is not already the default. Point pip at the corporate CA once instead: export PIP_CERT=/path/to/corp-ca.pem (never --trusted-host)."
    elif [ "${TRUSTSTORE_OK:-false}" != true ]; then
      note "pip: TLS failure — NOT retrying with --use-feature=truststore: the truststore package is not importable yet (this install may BE truststore). Set PIP_CERT=/path/to/corp-ca.pem and re-run."
    else
      note "pip: TLS failure — retrying with --use-feature=truststore (OS trust store)"
      cp "$_pi_log" "$_pi_tls"          # NEVER clobber the rung-1/2 diagnostic
      $PY_RUN -m pip install --user ${_pi_extra:+"$_pi_extra"} --quiet --use-feature=truststore "$@" >/dev/null 2>"$_pi_log"; _pi_rc=$?
      if [ $_pi_rc -ne 0 ]; then
        note "pip: the truststore retry also failed; the ORIGINAL TLS error was:"
        sed 's/^/    pip: /' "$_pi_tls" | tail -n 4
      fi
    fi
  fi
  [ $_pi_rc -ne 0 ] && sed 's/^/    pip: /' "$_pi_log" | tail -n 4
  rm -f "$_pi_log" "$_pi_tls"
  return $_pi_rc
}

# pip_truststore_window — true when the resolved pip is in [22.2, 24.2): the
# only versions where the explicit truststore opt-in both EXISTS (added 22.2 —
# older pips reject the option name at parse time, killing every pip call)
# and is not yet the DEFAULT (24.2 vendors truststore and uses the OS store
# out of the box). Wiring outside this window is broken or redundant.
pip_truststore_window() {
  _tw_v="$($PY_RUN -m pip --version 2>/dev/null | awk '{print $2}')"
  _tw_major="${_tw_v%%.*}"; _tw_minor="${_tw_v#*.}"; _tw_minor="${_tw_minor%%.*}"
  case "$_tw_major" in ''|*[!0-9]*) return 1 ;; esac
  case "$_tw_minor" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$_tw_major" -lt 22 ] || { [ "$_tw_major" -eq 22 ] && [ "$_tw_minor" -lt 2 ]; }; then
    return 1
  fi
  if [ "$_tw_major" -gt 24 ] || { [ "$_tw_major" -eq 24 ] && [ "$_tw_minor" -ge 2 ]; }; then
    return 1
  fi
  return 0
}

# ── python payload (pinned render deps + truststore; TLS-proxy-safe pip) ─────
if [ -n "$PY_RUN" ] || py_real py -3 || py_real python3 || py_real python; then
  # Stale-wiring self-heal FIRST: an older bootstrap generation persisted
  # PIP_USE_FEATURE=truststore into ~/.sigma-migration/env, and this shell may
  # have sourced it — under pip < 22.2 the option name is rejected at parse
  # time, so EVERY pip call dies. Clear the session value; wiring is
  # session-only now (set below only on proven success, inside the version
  # window) and the persisted leftover is purged.
  unset PIP_USE_FEATURE
  [ "$MODE" = full ] && purge_env_kv_line PIP_USE_FEATURE
  # Presence probes BEFORE the version floor (the IDEMPOTENT contract: probe
  # first, install only what is missing). The 3.11+ floor below is an INSTALL
  # prerequisite — numpy>=2.3 has no wheels for older interpreters — not a
  # runtime one: a host whose payload already imports on, say, CLT python 3.9
  # is doctor-green and must SKIP here, not fail on interpreter age.
  TRUSTSTORE_OK=false
  $PY_RUN -c "import truststore" >/dev/null 2>&1 && TRUSTSTORE_OK=true
  # Render payload SELF-GATES the way doctor's render check does: only where
  # the render scripts exist next to this bootstrap (pillow/numpy feed
  # visual-similarity.py, requests feeds sigma-export-png.py) — assessment
  # twins that ship neither script must not install a payload nothing uses.
  NEED_RENDER=true
  if [ ! -f "$HERE/visual-similarity.py" ] && [ ! -f "$HERE/sigma-export-png.py" ]; then
    NEED_RENDER=false
  fi
  RENDER_OK=true
  if [ "$NEED_RENDER" = true ] && ! $PY_RUN -c "import PIL, numpy, requests" >/dev/null 2>&1; then
    RENDER_OK=false
  fi
  PYVER="$($PY_RUN -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
  # Payload floor — enforced ONLY when the render payload actually needs a pip
  # install. On an older interpreter the pip step would die with a misleading
  # "No matching distribution found" that the TLS remediation misdirects to
  # proxy advice — name the real cause instead.
  if [ "$RENDER_OK" != true ] \
     && ! $PY_RUN -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
    plan "python ${PYVER:-?.?} is too old for the pinned payload (numpy>=2.3 needs Python 3.11+; truststore needs 3.10+)" \
         "no pip route on this interpreter — tell the USER to provide Python 3.11+ (macOS: brew install python; Windows: winget install --id Python.Python.3.13 --scope user), then re-run bootstrap"
    [ "$MODE" = full ] && INSTALL_FAILED=1
  else
    # truststore wherever a real python exists: it is how the python HTTPS
    # path (pip included) trusts TLS-intercepting corporate proxies via the
    # OS store (pip >= 24.2 does this by default). Not required — the doctor
    # warns, never gates, on it.
    if [ "$TRUSTSTORE_OK" = true ]; then
      okay "python truststore (OS trust store for TLS)"
    elif ! $PY_RUN -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
      # 3.10 floor — honest skip, not a red ✗: the doctor does not gate on
      # truststore, so failing here would contradict a green doctor on a host
      # whose render payload already imports.
      note "truststore skipped: python ${PYVER:-?.?} is below its 3.10 floor (TLS-proxy hosts: set PIP_CERT once, or install Python 3.11+ and re-run)"
    else
      plan "python truststore missing (OpenSSL 3.x TLS vs Looker/Tableau Cloud)" \
           "$PY_RUN -m pip install --user truststore (TLS-proxy-safe chain; no admin)"
      if [ "$MODE" = full ]; then
        # Success keys off PROVEN importability (the re-probe), not pip's rc.
        if pip_user_install truststore && $PY_RUN -c "import truststore" >/dev/null 2>&1; then
          act "install: pip --user truststore"
          okay "python truststore installed"
          TRUSTSTORE_OK=true
        else
          note "pip --user install of truststore FAILED — if a corporate proxy intercepts TLS, point pip at its CA once: export PIP_CERT=/path/to/corp-ca.pem — do NOT disable TLS verification. (pip >= 24.2 verifies against the OS trust store by default; on older pips even this truststore install needs PIP_CERT when the corporate CA is missing from the OS store.)"
        fi
      fi
    fi
    # Wire pip to truststore for the REST OF THIS RUN only where the explicit
    # opt-in can work: truststore importable AND pip in [22.2, 24.2). Outside
    # the window the flag is broken (< 22.2: invalid option) or redundant
    # (>= 24.2: default). Session-only by design — nothing is persisted, so a
    # later pip upgrade can never be mis-wired by a stale line.
    if [ "$MODE" = full ] && [ "$TRUSTSTORE_OK" = true ] && pip_truststore_window; then
      export PIP_USE_FEATURE=truststore
    fi
    if [ "$NEED_RENDER" != true ]; then
      okay "render payload not needed here (no render scripts adjacent) — skipped"
    elif [ "$RENDER_OK" = true ]; then
      okay "python deps (Pillow + numpy + requests)"
    else
      plan "python deps missing (Pillow/numpy>=2.3/requests — renders + the gate-14 visual floor)" \
           "$PY_RUN -m pip install --user pillow 'numpy>=2.3' requests (pinned; user site-packages; no admin)"
      if [ "$MODE" = full ]; then
        if pip_user_install pillow 'numpy>=2.3' requests \
           && $PY_RUN -c "import PIL, numpy, requests" >/dev/null 2>&1; then
          act "install: pip --user pillow numpy>=2.3 requests"
          okay "python deps installed (pip --user; numpy pinned >=2.3)"
        else
          INSTALL_FAILED=1
          note "pip --user install of pillow/numpy>=2.3/requests FAILED — if the error was 'externally-managed-environment' (PEP 668) the retry with --break-system-packages also failed; otherwise check network/proxy. Re-run bootstrap when resolved"
        fi
      fi
    fi
  fi
fi

# ── node (vendored converters run via node; new installs PINNED to 22 LTS) ──
# fnm_pinned_install — shared by the fnm-present and windows-bash routes:
# pinned install + default (BOTH verified — a default that fails leaves later
# shells on the wrong line), real bin dir via `fnm exec … process.execPath`
# (fnm's layout is versioned; guessing globs races the install), cygpath -u
# normalization on Git-Bash (fnm prints a Windows-style dir there — bash
# splits PATH at the drive colon, so persisting it raw wires a PATH line that
# never resolves), then VERIFIED resolution: `node` must actually resolve
# after the prepend, or we fail with the fnm-env remediation instead of
# repeating the same broken write on every re-run. Full mode only.
fnm_pinned_install() {
  if fnm install "$NODE_PIN_MAJOR" >/dev/null 2>&1 && fnm default "$NODE_PIN_MAJOR" >/dev/null 2>&1; then
    NODE_DIR="$(fnm exec --using "$NODE_PIN_MAJOR" node -e 'console.log(require("path").dirname(process.execPath))' 2>/dev/null)"
    if [ "$OS" = windows-bash ] && [ -n "$NODE_DIR" ]; then
      NODE_DIR="$(cygpath -u "$NODE_DIR" 2>/dev/null || printf '%s' "$NODE_DIR")"
    fi
    [ -n "$NODE_DIR" ] && activate_path "$NODE_DIR"
    act "install: node $NODE_PIN_MAJOR LTS (fnm, pinned)"
    if command -v node >/dev/null 2>&1; then
      okay "node $(node --version 2>/dev/null) (fnm, pinned to the $NODE_PIN_MAJOR line)"
    else
      INSTALL_FAILED=1
      note "fnm installed node $NODE_PIN_MAJOR but 'node' still does not resolve — run 'fnm env' and add its PATH line (Unix-style via cygpath -u on Git-Bash) to $PATH_SNIPPET, then re-run bootstrap"
    fi
  else
    INSTALL_FAILED=1; note "fnm install $NODE_PIN_MAJOR FAILED — re-run bootstrap when the network allows"
  fi
}
if command -v node >/dev/null 2>&1; then
  okay "node $(node --version 2>/dev/null)"
else
  # KEEP IN LOCKSTEP with doctor.sh's node candidate list (its "G1" check):
  # same version-manager dirs, so anything the doctor calls "INSTALLED but not
  # on PATH" is ACTIVATED here, never re-installed. Bootstrap may activate
  # ADDITIONAL brew opt dirs (the two /opt entries below) — never fewer dirs.
  # test-bootstrap-lockstep.sh Part A diffs the two lists.
  NODE_DIR="$(latest_bindir \
    "$HOME"/.fnm/node-versions/*/installation/bin/node \
    "$HOME"/.local/share/fnm/node-versions/*/installation/bin/node \
    "$HOME/Library/Application Support/fnm/node-versions"/*/installation/bin/node \
    "$HOME"/.nvm/versions/node/*/bin/node \
    "$HOME"/.asdf/installs/nodejs/*/bin/node \
    "$HOME"/.local/node/bin/node \
    /opt/homebrew/opt/node/bin/node \
    /usr/local/opt/node/bin/node)"
  if [ -n "$NODE_DIR" ]; then
    plan "node installed but not on PATH ($NODE_DIR)" "activate it (prepend to PATH; persisted in $PATH_SNIPPET)"
    [ "$MODE" = full ] && { activate_path "$NODE_DIR"; okay "node $(node --version 2>/dev/null) (activated from $NODE_DIR)"; }
  elif command -v fnm >/dev/null 2>&1; then
    plan "node not found (fnm present)" "fnm install $NODE_PIN_MAJOR && fnm default $NODE_PIN_MAJOR (pinned 22 LTS; user-scoped; no admin)"
    [ "$MODE" = full ] && fnm_pinned_install
  elif [ "$OS" = macos ]; then
    # brew first when present. node@22 is keg-only (versioned formulae always
    # are) and upstream-scheduled for Homebrew deprecation well before the
    # line's real 2027-04 EOL — so a brew failure CHAINS to the pinned
    # portable tarball instead of dead-ending every macOS+Homebrew host.
    plan "node not found" "brew install node@22 (keg-only; PATH persisted) — pinned portable tarball to ~/.local/node if brew is absent or fails"
    if [ "$MODE" = full ]; then
      if brew_ok && brew install node@22 >/dev/null 2>&1; then
        BREW_NODE="$(brew --prefix 2>/dev/null)/opt/node@22/bin"
        [ -d "$BREW_NODE" ] && activate_path "$BREW_NODE"
        act "install: node@22 (brew, keg-only)"
        command -v node >/dev/null 2>&1 && okay "node $(node --version 2>/dev/null) (brew node@22)" || { INSTALL_FAILED=1; note "brew install node@22 finished but node still not resolvable"; }
      elif node_portable_install; then
        activate_path "$HOME/.local/node/bin"
        act "install: node v$NODE_PIN (portable ~/.local/node, pinned)"
        command -v node >/dev/null 2>&1 && okay "node $(node --version 2>/dev/null) (portable, pinned)" || { INSTALL_FAILED=1; note "portable node landed but node still not resolvable"; }
      else
        INSTALL_FAILED=1; note "node install FAILED (brew node@22 unavailable/failed; portable download failed) — check network/proxy, or install Node 22 yourself, then re-run bootstrap"
      fi
    fi
  elif [ "$OS" = linux ]; then
    # Deliberately NOT distro apt here: distro nodejs floats (e.g. 18 on
    # ubuntu 24.04), which breaks the 22-line pin. The pinned portable tarball
    # is deterministic and needs no elevation.
    plan "node not found" "pinned portable tarball v$NODE_PIN to ~/.local/node (no admin, nothing unpinned)"
    if [ "$MODE" = full ]; then
      if node_portable_install; then
        activate_path "$HOME/.local/node/bin"
        act "install: node v$NODE_PIN (portable ~/.local/node, pinned)"
        command -v node >/dev/null 2>&1 && okay "node $(node --version 2>/dev/null) (portable, pinned)" || { INSTALL_FAILED=1; note "portable node landed but node still not resolvable"; }
      else
        INSTALL_FAILED=1; note "node install FAILED (portable download) — check network/proxy, or install Node 22 yourself, then re-run bootstrap"
      fi
    fi
  elif [ "$OS" = windows-bash ]; then
    # The fnm route the doctor already hints at: user-scoped, no admin, pinned.
    plan "node not found" "install fnm (winget user scope / scoop portable), then fnm install $NODE_PIN_MAJOR (pinned 22 LTS; no admin)"
    if [ "$MODE" = full ]; then
      command -v fnm >/dev/null 2>&1 || win_install Schniz.fnm fnm fnm || true
      if command -v fnm >/dev/null 2>&1; then
        fnm_pinned_install
      else
        # Either winget/scoop failed outright, or winget succeeded but its
        # PATH edit only lands in NEW shells — never half-install.
        INSTALL_FAILED=1
        note "fnm not resolvable in this shell (install failed, or winget PATH lands in new shells only) — reopen the shell and re-run: bash scripts/bootstrap.sh (PowerShell twin: powershell -ExecutionPolicy Bypass -File scripts\\bootstrap.ps1)"
      fi
    fi
  else
    plan "node not found (no version-manager install; unrecognized OS)" \
         "no admin-free install route on this host — tell the USER to provide node 22 LTS (e.g. install fnm), then re-run bootstrap"
    [ "$MODE" = full ] && INSTALL_FAILED=1
  fi
fi

# ── credentials (non-interactive only — setup.rb is the single writer) ──────
NEUTRAL_ENV="$STATE_DIR/env"
if [ "${#CRED_ARGS[@]}" -gt 0 ]; then
  # Flag form first: explicit flags beat auto-detection (they can rotate
  # already-persisted creds). Values are redacted everywhere.
  plan "Sigma credentials provided via flags" \
       "ruby scripts/setup.rb <cred flags redacted: ${#CRED_ARGS[@]} token(s)> (single credential writer; values never echoed)"
  if [ "$MODE" = full ]; then
    if [ -f "$HERE/setup.rb" ] && command -v ruby >/dev/null 2>&1 \
       && ruby "$HERE/setup.rb" ${CRED_ARGS[@]+"${CRED_ARGS[@]}"} >/dev/null 2>&1; then
      act "creds: setup.rb (flag form)"
      okay "Sigma credentials persisted via setup.rb (flag form)"
    else
      INSTALL_FAILED=1; note "setup.rb (flag form) FAILED — check the flag values (needs ruby + setup.rb next to this script); or run 'ruby scripts/setup.rb' once in a real terminal"
    fi
  fi
elif [ -f "$NEUTRAL_ENV" ] && grep -q 'SIGMA_CLIENT_ID' "$NEUTRAL_ENV" 2>/dev/null; then
  okay "Sigma credentials present ($NEUTRAL_ENV)"
elif [ -n "${SIGMA_CLIENT_ID:-}" ] && [ -n "${SIGMA_CLIENT_SECRET:-}" ]; then
  plan "Sigma credentials not yet persisted (env vars ARE exported)" \
       "ruby scripts/setup.rb --from-env (persists them; values never echoed)"
  if [ "$MODE" = full ]; then
    if [ -f "$HERE/setup.rb" ] && command -v ruby >/dev/null 2>&1 && ruby "$HERE/setup.rb" --from-env >/dev/null 2>&1; then
      act "creds: setup.rb --from-env"
      okay "Sigma credentials persisted from the environment (setup.rb --from-env)"
    else
      INSTALL_FAILED=1; note "setup.rb --from-env FAILED — check SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET exports"
    fi
  fi
else
  plan "Sigma credentials MISSING (no $NEUTRAL_ENV, no SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET in the env)" \
       "export SIGMA_CLIENT_ID + SIGMA_CLIENT_SECRET (+ SIGMA_BASE_URL) and re-run bootstrap — or the USER runs 'ruby scripts/setup.rb' once in a real terminal"
  # Not an install failure: bootstrap cannot invent credentials. Doctor will
  # fail-close on them below, keeping the run honestly red until they exist.
fi

# Tableau PAT (only where the tableau scripts ship next to this bootstrap).
if [ -f "$HERE/setup-tableau.rb" ]; then
  if [ -f "$NEUTRAL_ENV" ] && grep -q 'TABLEAU_PAT_SECRET' "$NEUTRAL_ENV" 2>/dev/null; then
    okay "Tableau credentials present ($NEUTRAL_ENV)"
  elif [ -n "${TABLEAU_PAT_NAME:-}" ] && [ -n "${TABLEAU_PAT_SECRET:-}" ]; then
    plan "Tableau PAT not yet persisted (env vars ARE exported)" "ruby scripts/setup-tableau.rb --from-env"
    if [ "$MODE" = full ]; then
      if command -v ruby >/dev/null 2>&1 && ruby "$HERE/setup-tableau.rb" --from-env >/dev/null 2>&1; then
        act "creds: setup-tableau.rb --from-env"
        okay "Tableau credentials persisted from the environment"
      else
        INSTALL_FAILED=1; note "setup-tableau.rb --from-env FAILED — check TABLEAU_PAT_NAME/TABLEAU_PAT_SECRET/TABLEAU_SITE_CONTENT_URL/TABLEAU_SERVER_URL exports"
      fi
    fi
  else
    note "(Tableau PAT not configured — WARN-level; needed only for Tableau discovery. Export TABLEAU_PAT_NAME/TABLEAU_PAT_SECRET and re-run bootstrap to persist.)"
  fi
fi

# ── check mode stops here (no doctor, no writes — offline-safe) ──────────────
if [ "$MODE" = check ]; then
  say ""
  if [ "$NEEDED" -eq 0 ]; then
    say "bootstrap --check: environment COMPLETE — nothing to install. Run 'bash scripts/bootstrap.sh' to (re)confirm doctor-green + write the sentinel."
    exit 0
  fi
  say "bootstrap --check: $NEEDED piece(s) missing (listed above). Run 'bash scripts/bootstrap.sh' to fix them non-interactively."
  exit 1
fi

# ── doctor (writes doctor.json — the report the orchestrator gates on) ───────
say ""
say "Running the environment doctor…"
if [ -n "$WORKDIR" ]; then
  bash "$HERE/doctor.sh" --workdir "$WORKDIR"
else
  bash "$HERE/doctor.sh"
fi
DOCTOR_EXIT=$?
DOCTOR_PASS=false
[ "$DOCTOR_EXIT" -eq 0 ] && DOCTOR_PASS=true

# ── sentinel ─────────────────────────────────────────────────────────────────
jstr() { _js="${1:-}"; _js="$(printf '%s' "$_js" | sed 's/\\/\\\\/g; s/"/\\"/g')"; printf '%s' "$_js"; }
json_lines() { # newline-joined $1 -> JSON string array items
  _jl_out=""
  while IFS= read -r _jl_line; do
    [ -z "$_jl_line" ] && continue
    _jl_out="${_jl_out}${_jl_out:+,}\"$(jstr "$_jl_line")\""
  done <<EOF
$1
EOF
  printf '%s' "$_jl_out"
}
write_sentinel() {
  _ws_dest="$1"
  mkdir -p "$(dirname "$_ws_dest")" 2>/dev/null || return 0
  {
    printf '{'
    printf '"bootstrap_version":1,'
    printf '"mode":"full",'
    printf '"os":"%s",' "$(jstr "$OS")"
    printf '"actions":[%s],' "$(json_lines "$ACTIONS")"
    printf '"path_additions":[%s],' "$(json_lines "$PATH_ADDED")"
    printf '"install_failed":%s,' "$([ "$INSTALL_FAILED" -eq 0 ] && echo false || echo true)"
    printf '"doctor_pass":%s,' "$DOCTOR_PASS"
    printf '"completed_at":"%s"' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '}\n'
  } > "$_ws_dest" 2>/dev/null || true
}
write_sentinel "$STATE_DIR/bootstrap.json"
[ -n "$WORKDIR" ] && write_sentinel "$WORKDIR/bootstrap.json"

say ""
if [ -n "$PATH_ADDED" ]; then
  say "PATH additions persisted to $PATH_SNIPPET — new shells outside bootstrap: 'source $PATH_SNIPPET'."
fi
if [ "$DOCTOR_PASS" = true ] && [ "$INSTALL_FAILED" -eq 0 ]; then
  say "bootstrap: COMPLETE — doctor green; sentinel written to $STATE_DIR/bootstrap.json${WORKDIR:+ and $WORKDIR/bootstrap.json}."
  exit 0
fi
say "bootstrap: INCOMPLETE — $( [ "$INSTALL_FAILED" -ne 0 ] && printf 'an install step failed; ' )doctor exit $DOCTOR_EXIT. Fix the ✗ items above (doctor names each) and re-run: bash scripts/bootstrap.sh"
exit 1
