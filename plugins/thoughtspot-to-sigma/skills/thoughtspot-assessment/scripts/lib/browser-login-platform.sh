#!/usr/bin/env bash
# Cross-platform helpers for browser-login.sh. Safe to source in tests.

sigma_base64url() {
  tr '+/' '-_' | tr -d '=\r\n'
}

sigma_pkce_verifier() {
  tr -d '\r\n=+/' | cut -c1-64
}

sigma_require_component() {
  local label="$1" value="$2" pattern="$3"
  if [[ ! "$value" =~ $pattern ]]; then
    printf 'Error: generated %s contains invalid characters; aborting before authorization.\n' "$label" >&2
    return 1
  fi
}

sigma_uname() {
  if [[ -n "${SIGMA_UNAME_OVERRIDE:-}" ]]; then
    printf '%s\n' "$SIGMA_UNAME_OVERRIDE"
  else
    uname -s 2>/dev/null || printf 'unknown\n'
  fi
}

sigma_open_windows_browser() {
  local url="$1"
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -NonInteractive \
      -Command 'Start-Process -FilePath $args[0]' "$url" >/dev/null 2>&1 &&
      return 0
  fi
  if command -v cmd.exe >/dev/null 2>&1; then
    # Git Bash rewrites /c as a POSIX path; //c passes the switch verbatim.
    cmd.exe //c start "" "$url" >/dev/null 2>&1 && return 0
  fi
  if command -v explorer.exe >/dev/null 2>&1; then
    explorer.exe "$url" >/dev/null 2>&1 && return 0
  fi
  return 1
}

sigma_open_system_browser() {
  local url="$1" platform
  platform=$(sigma_uname)
  case "$platform" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      sigma_open_windows_browser "$url"
      return
      ;;
  esac

  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 && return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 && return 0
  fi

  # Some Windows shells report an unexpected uname. Keep native launchers as
  # a final fallback without affecting macOS/Linux command preference.
  sigma_open_windows_browser "$url"
}

sigma_prepare_callback_file() {
  local path="$1" old_umask
  [[ -n "$path" ]] || return 1
  case "$path" in
    /*) ;;
    *)
      printf 'Error: SIGMA_OAUTH_CALLBACK_FILE must be an absolute POSIX path.\n' >&2
      return 1
      ;;
  esac
  [[ -d "$(dirname "$path")" ]] || {
    printf 'Error: callback-file directory does not exist: %s\n' "$(dirname "$path")" >&2
    return 1
  }
  old_umask=$(umask)
  umask 077
  : > "$path"
  umask "$old_umask"
  # Best effort on POSIX filesystems. Git Bash on NTFS can report inherited
  # ACLs as 0644 even after chmod; the file must never be group/world writable.
  chmod 600 "$path" 2>/dev/null || true
}

sigma_wait_for_callback_file() {
  local path="$1" timeout="$2" elapsed=0 callback=""
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Error: callback-file timeout must be a positive integer.\n' >&2
    return 1
  }
  while (( elapsed < timeout )); do
    if [[ -s "$path" ]]; then
      IFS= read -r callback < "$path" || true
      rm -f "$path"
      [[ -n "$callback" ]] || return 1
      printf '%s\n' "$callback"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  rm -f "$path"
  return 1
}
