#!/usr/bin/env python3
"""Enrich a derive_master master-map with caption-flexible lookup keys (n4pi.7).

build-charts resolves a Tableau chart header to a master column by regex-matching
the header against the master-map's keys. derive_master emits one key per master
column (its display name, plus a few agg/date-part prefixes). Two classes of
header still miss:

  (a) space / underscore / case variants — a warehouse column "WEEK_OF" won't
      match a chart header "Week Of" because the derive_master regex escapes the
      literal underscore.
  (b) friendly Tableau CAPTIONS — a chart plots "Weekly Goal" but the master
      column is the warehouse-named "WEEK_GOAL"; the caption→field mapping lives
      in the .twb (<column caption='..' name='[..]'>), not in the warehouse name.

This adds both so signal-built charts (no view CSV) resolve their measures/dims.
The selection VALUE never changes — only additional match keys are added; the
existing keys win first (insertion order is preserved on re-load).

Usage: enrich-master-map.py <run-dir> <twb-path>
  <run-dir>/master-map.json   (read + rewritten in place)
  <run-dir>/master-cols.yaml  (read-only; the authoritative column list)
"""
import json
import re
import sys

try:
    import yaml
except ImportError:
    sys.exit("enrich-master-map.py needs PyYAML (pip install pyyaml)")

run = sys.argv[1] if len(sys.argv) > 1 else "."
twb = sys.argv[2] if len(sys.argv) > 2 else None

# Optional Tableau CSV aggregation / date-part prefix the chart header may carry
# (mirrors mechanical-specs.header_regex so an enriched key tolerates the same).
AGG = (
    r"(?:(?:sum|avg|average|min|max|median|distinct count|count) of "
    r"|(?:avg|sum|min|max|med|cnt|ctd)\.\s*"
    r"|(?:second|minute|hour|day|week|month|quarter|year) of )?"
)

mmap = json.load(open(f"{run}/master-map.json"))
mcols = yaml.safe_load(open(f"{run}/master-cols.yaml"))["columns"]


def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def desuffix(name):
    return re.sub(r"_\d+$", "", name)  # WEEK_OF_2 -> WEEK_OF


# Index master cols by normalized de-suffixed warehouse base (first wins —
# the un-suffixed/earlier-ordered column is preferred).
by_base = {}
for c in mcols:
    by_base.setdefault(norm(desuffix(c["name"])), c)

added = 0
# (a) space/underscore/case-flexible entry for every master column name.
for c in mcols:
    pat = re.escape(c["name"]).replace("_", r"[\s_]*")
    key = f"(?i)^{AGG}{pat}$"
    if key not in mmap:
        mmap[key] = {"id": c["id"], "name": c["name"]}
        added += 1

# (b) caption -> column via the .twb <column caption=.. name=..> metadata.
capmap = 0
if twb:
    xml = open(twb, encoding="utf-8", errors="replace").read()
    caps = re.findall(
        r"<column\b[^>]*\bcaption='([^']+)'[^>]*\bname='\[([^']+)\]'", xml
    )
    for cap, field in caps:
        base = re.sub(r"\s*\([^)]*\)\s*", "", field)       # strip (Custom SQL QueryN)
        base = re.sub(r"\s*\(copy\)_\d+$", "", base)
        col = by_base.get(norm(base))
        if not col:
            continue
        key = f"(?i)^{AGG}{re.escape(cap)}$"
        if key not in mmap:
            mmap[key] = {"id": col["id"], "name": col["name"]}
            capmap += 1

json.dump(mmap, open(f"{run}/master-map.json", "w"), indent=2)
print(
    f"enriched mmap: +{added} normalized, +{capmap} caption entries "
    f"(total {len(mmap)})"
)
