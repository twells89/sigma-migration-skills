#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

python3 - <<'PY'
import json
from pathlib import Path

result = json.loads(Path("golden/workbook.json").read_text())
workbook = result["workbook"]
assert set(workbook) == {"name", "document"}, "workbook must use outer metadata + document wrapper"
doc = workbook["document"]
pages = doc["pages"]
elements = doc["elements"]
layout = doc["layout"]

assert len(pages) == 2, f"expected 2 metadata pages, got {len(pages)}"
assert all("elements" not in page for page in pages), "pages must be metadata-only"
assert len(elements) == 19, f"expected 19 flat elements, got {len(elements)}"
assert sum(len(element.get("columns", [])) for element in elements) == 28, "expected 28 columns"
assert all(f'<Page' in layout and f'id="{page["id"]}"' in layout for page in pages), "layout must contain every page"
assert "<LayoutElement" not in layout and "<GridContainer" not in layout, "layout must not emit compatibility aliases"
assert "<Element " in layout, "layout must use the live Element tag"
for element in elements:
    needle = f'elementId="{element["id"]}"'
    assert layout.count(needle) == 1, f'{element["id"]} must appear exactly once in layout'
assert any(element.get("kind") == "navigation" for element in elements), "multi-page report needs navigation"
assert result["stats"]["pages"] == 2
print("  ok   current workbook wrapper/flat-elements/layout contract")
PY

# Exercise the bundled production CLI, not just the TypeScript test harness.
skill="../../../plugins/cognos-to-sigma/skills/cognos-to-sigma"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
node "$skill/converter/cli.mjs" "$skill/fixtures/print-list.report.xml" \
  --print --dm example-model --out "$tmp/report.json" --warnings-out "$tmp/warnings.json"
python3 - "$tmp/report.json" "$tmp/warnings.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1]))
warnings = json.load(open(sys.argv[2]))
assert report['kind'] == 'report' and report['schemaVersion'] == 1
assert len(report['pages']) == 1
assert [e['kind'] for e in report['elements']] == ['table', 'text', 'text']
assert {p['type'] for p in report['panels']} == {'header', 'footer'}
assert report['layout'].count('flow="paginated"') == 1
assert 'gridRow=' not in report['layout']
assert not warnings, warnings
print('  ok   print CLI emits a paginated Sigma Report with header and footer')
PY

node "$skill/scripts/compose-print-layout.mjs" --spec "$tmp/report.json" \
  --blueprint "$skill/fixtures/print-layout-blueprint.json" --out "$tmp/composed.json"
test -s "$tmp/composed.json" || { echo '  FAIL print layout composer did not write its output'; exit 1; }
python3 - "$tmp/composed.json" <<'PY'
import json
import re
import sys

report = json.load(open(sys.argv[1]))
assert [p['name'] for p in report['pages']] == ['Cover', 'Letter', 'Summary'] + [f'Terms {i}' for i in range(1, 7)]
assert sum(e['kind'] == 'table' for e in report['elements']) == 1
assert sum(e['kind'] == 'image' for e in report['elements']) == 11
assert next(e for e in report['elements'] if e['kind'] == 'table')['name'] == 'Product revenue by line'
assert sum(p['type'] == 'footer' for p in report['panels']) == 1
assert not any(p['type'] == 'header' for p in report['panels'])
footer = next(p for p in report['panels'] if p['type'] == 'footer')
assert footer['pages'] == [p['id'] for p in report['pages']]
assert any('{{CurrentPageNumber()}} of {{TotalPageCount()}}' in e.get('body', '') for e in report['elements'])
layout = report['layout']
assert re.findall(r'<Page id="([^"]+)"', layout) == [p['id'] for p in report['pages']]
assert layout.count('flow="paginated"') == 1
assert 'x="48" y="265" width="670" height="455" flow="paginated"' in layout
assert layout.count('x="48" y="48" width="670" height="830"') == 5
assert all(layout.count(f'elementId="{e["id"]}"') == 1 for e in report['elements'])
print('  ok   bundled print report composes neutral nine-page cover, letter, summary, terms, watermark and numbered footer')
PY

if node "$skill/converter/cli.mjs" "$skill/fixtures/banking-risk-crosstab.report.xml" \
  --print --dm example-model > "$tmp/pivot.json" 2> "$tmp/pivot-error.log"; then
  echo '  FAIL print CLI silently converted an unsupported Report pivot'
  exit 1
fi
python3 - "$tmp/pivot-error.log" <<'PY'
import sys
message = open(sys.argv[1]).read()
assert 'crosstab' in message and 'pivot-table' in message, message
print('  ok   print CLI refuses unsupported Report pivots')
PY

node "$skill/converter/cli.mjs" "$skill/fixtures/banking-risk-crosstab.report.xml" \
  --dm example-model > "$tmp/workbook.json"
python3 - "$tmp/workbook.json" <<'PY'
import json
import sys
workbook = json.load(open(sys.argv[1]))['document']
pivots = [e for e in workbook['elements'] if e['kind'] == 'pivot-table']
assert len(pivots) == 2
for pivot in pivots:
    measure = next(c for c in pivot['columns'] if c['name'] == 'Net Loss')
    assert measure['formula'].startswith('Avg('), measure
    assert pivot['totals']['showGrandTotals'] == 'shown'
    assert pivot['rowsBy'][0]['sort']['direction'] == 'ascending'
    assert pivot['columnsBy'][0]['sort']['direction'] == 'ascending'
print('  ok   production workbook pivots retain Avg, grand totals and edge sorts')
PY

# Print must not silently ignore a structured detail filter that has no
# filterExpression. Exercise the shipped bundle as well as the TS unit tests.
python3 - "$skill/fixtures/print-list.report.xml" "$tmp/structured-filter.xml" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
assert source.count('</selection></query>') == 1
source = source.replace('</selection></query>',
    '</selection><detailFilters><detailFilter><filterDefinition><filterInValues refDataItem="Region">'
    '<filterValues><filterValue>West</filterValue></filterValues></filterInValues>'
    '</filterDefinition></detailFilter></detailFilters></selection></query>')
Path(sys.argv[2]).write_text(source)
PY
if node "$skill/converter/cli.mjs" "$tmp/structured-filter.xml" --print --dm example-model \
    --out "$tmp/filtered.json" 2> "$tmp/filtered-error.log"; then
  echo '  FAIL print CLI silently dropped a structured filter'
  exit 1
fi
python3 - "$tmp/filtered-error.log" <<'PY'
import sys
message = open(sys.argv[1]).read()
assert 'filter was not converted' in message or 'structured or empty filter' in message, message
print('  ok   production print CLI refuses an unconverted structured detail filter')
PY
