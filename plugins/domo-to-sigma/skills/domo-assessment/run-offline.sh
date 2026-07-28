#!/usr/bin/env bash
# run-offline.sh — offline green-bar driver for the domo-assessment skill.
#
# Runs the full pipeline (probe-governance -> discover-domo -> score-coverage
# -> render-readout) against the committed fixtures for both governance tiers
# (tier-b, tier-a), entirely offline (no Sigma/Domo creds, no network), and
# asserts on the emitted complexity.json. Prints `OFFLINE GREEN: <tier>` per
# tier on success; exits non-zero and fails loudly on any miss.
#
# Usage: bash run-offline.sh   (from any CWD; paths resolve relative to this
# script's own directory)

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SKILL_DIR"

for tier in tier-b tier-a; do
  case "$tier" in
    tier-b) expected_tier="B" ;;
    tier-a) expected_tier="A" ;;
  esac

  OUT="/tmp/domo-assessment-offline-$tier"
  rm -rf "$OUT"
  mkdir -p "$OUT"

  FIXTURES="fixtures/$tier"

  ruby scripts/probe-governance.rb --from-fixtures "$FIXTURES" --out "$OUT"
  ruby scripts/discover-domo.rb    --from-fixtures "$FIXTURES" --out "$OUT"
  ruby scripts/score-coverage.rb   --in "$OUT" --out "$OUT"
  ruby scripts/render-readout.rb   --in "$OUT" --out "$OUT"

  ruby -rjson -e '
    path, expected_tier = ARGV
    data = JSON.parse(File.read(path))
    tags = data.fetch("artifacts", []).map { |a| a["tag"] }

    failures = []
    failures << "missing tag: retire" unless tags.include?("retire")
    failures << "missing tag: needs-gap-scout" unless tags.include?("needs-gap-scout")
    failures << "wrong tier: expected #{expected_tier.inspect}, got #{data["tier"].inspect}" unless data["tier"] == expected_tier

    unless failures.empty?
      warn "ASSERTION FAILED (#{path}): #{failures.join("; ")}"
      exit 1
    end
  ' "$OUT/complexity.json" "$expected_tier"

  echo "OFFLINE GREEN: $tier"
done
