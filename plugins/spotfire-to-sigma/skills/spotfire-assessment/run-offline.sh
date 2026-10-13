#!/usr/bin/env bash
# Hermetic Spotfire assessment: both committed evidence tiers plus unit tests.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SKILL_DIR"

for fixture in full metadata-only; do
  out="/tmp/spotfire-assessment-offline-$fixture"
  rm -rf "$out"
  python3 scripts/assess.py --from-fixtures "fixtures/$fixture" --out "$out"

  for artifact in probe.json inventory.json complexity.json shortlist.json migration-plan.json readout.md; do
    test -s "$out/$artifact"
  done
  test -s "$out/usage.json"
  echo "OFFLINE GREEN: $fixture"
done

python3 -m unittest discover -s test -p 'test_*.py'
