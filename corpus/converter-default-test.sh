#!/usr/bin/env bash
# Converter-default regression test (GitHub issue #227). CREDS-FREE, network-free.
#
# Guards the invariant that made customers see different behavior than demos: the
# orchestrators must default to the PINNED VENDORED converter bundle and must NOT
# silently auto-discover a developer's ~/sigma-data-model-mcp checkout. A local
# build is used ONLY when EXPLICITLY opted in via an env var / flag.
#
# Two layers:
#   1. STATIC (all 5 orchestrators): no implicit `~/…sigma-data-model-mcp…` probe
#      and no hardcoded `/Users/<name>/…` developer path may reappear.
#   2. DYNAMIC (the 4 with a --print-converter mode): with a planted fake ~ checkout
#      + clean env → resolves to the vendored bundle; with the explicit env var →
#      resolves to the dev build.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
note() { printf '  %s\n' "$*"; }

# ── Layer 1: static — no implicit home-dir / hardcoded dev-path probing ──────────
echo "== static: no silent dev-checkout auto-discovery in any orchestrator"
STATIC_HITS=$(grep -rnE "expand_path\(['\"]~/[^'\"]*sigma-data-model-mcp|expanduser\(['\"]~/[^'\"]*sigma-data-model-mcp|/Users/[a-z]+/[^ ]*sigma-data-model-mcp" \
  plugins/*/skills/*/scripts/migrate-*.rb plugins/*/skills/*/scripts/migrate-*.py 2>/dev/null || true)
if [ -n "$STATIC_HITS" ]; then
  echo "FAIL: implicit dev-checkout probing reintroduced:"; echo "$STATIC_HITS"; fail=1
else
  note "OK — no implicit ~/ or /Users/<name>/ sigma-data-model-mcp probes"
fi

# ── Layer 2: dynamic — vendored default vs explicit override ─────────────────────
# fields: label | orchestrator | runner | env_var | build_basename | vendored_basename
CASES=(
  "powerbi|plugins/powerbi-to-sigma/skills/powerbi-to-sigma/scripts/migrate-powerbi.rb|ruby|PBI_MCP_DIR|powerbi.js|powerbi.mjs"
  "quicksight|plugins/quicksight-to-sigma/skills/quicksight-to-sigma/scripts/migrate-quicksight.rb|ruby|QS_MCP_DIR|quicksight.js|quicksight.mjs"
  "qlik|plugins/qlik-to-sigma/skills/qlik-to-sigma/scripts/migrate-qlik.rb|ruby|QLIK_MCP_DIR|qlik.js|qlik.mjs"
  "looker|plugins/looker-to-sigma/skills/looker-to-sigma/scripts/migrate-looker.py|python3|CONVERTER_PATH|lookml.js|lookml.mjs"
)

for spec in "${CASES[@]}"; do
  IFS='|' read -r label orch runner envvar build vendored <<<"$spec"
  echo "== dynamic: $label"
  if [ ! -f "$orch" ]; then echo "FAIL: orchestrator missing: $orch"; fail=1; continue; fi

  fh=$(mktemp -d)
  # Plant a fake dev checkout in BOTH well-known home locations — must be ignored.
  mkdir -p "$fh/sigma-data-model-mcp/build" "$fh/Desktop/sigma-data-model-mcp/build"
  echo "x" > "$fh/sigma-data-model-mcp/build/$build"
  echo "x" > "$fh/Desktop/sigma-data-model-mcp/build/$build"

  # (a) clean env + planted checkout → MUST resolve to the vendored bundle
  out_default=$(HOME="$fh" env -u "$envvar" "$runner" "$orch" --print-converter 2>/dev/null | head -1)
  if [[ "$out_default" == *"/converter/$vendored" ]]; then
    note "OK default → vendored ($vendored), planted ~ checkout ignored"
  else
    echo "FAIL default: expected vendored .../converter/$vendored, got: $out_default"; fail=1
  fi

  # (b) explicit override env var → MUST resolve to that dev build
  dd=$(mktemp -d); mkdir -p "$dd/build"; echo "x" > "$dd/build/$build"
  if [ "$envvar" = "CONVERTER_PATH" ]; then ovval="$dd/build/$build"; else ovval="$dd"; fi
  out_dev=$(HOME="$fh" env "$envvar=$ovval" "$runner" "$orch" --print-converter 2>/dev/null | head -1)
  if [[ "$out_dev" == "$dd/build/$build" ]]; then
    note "OK override ($envvar) → dev build honored"
  else
    echo "FAIL override: expected $dd/build/$build, got: $out_dev"; fail=1
  fi
  rm -rf "$fh" "$dd"
done

echo
if [ "$fail" -eq 0 ]; then echo "converter-default: ALL PASS"; else echo "converter-default: FAILURES above"; fi
exit $fail
