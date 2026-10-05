#!/usr/bin/env bash
# validate-spec.sh — scan a workbook spec for likely formula-qualification errors.
#
# Catches the #1 Sigma spec mistake: a bare bracketed reference (e.g. [Question ID])
# inside a formula when the referenced column actually lives on the source element,
# not the current one, and therefore needs a prefix (e.g. [AI Usage Data/Question ID]).
#
# Accepts YAML (recommended) or JSON input. YAML is detected by the
# .yaml/.yml extension and converted to JSON internally before the jq pass.
#
# Usage: ./validate-spec.sh <path-to-spec.yaml|.json>
# Exit codes:
#   0  — no obvious issues
#   1  — issues found
#   2  — setup / input error
#
# Limitations: regex-based, so it does not parse formulas semantically. It can
# produce false positives on bracketed text inside string literals (e.g.
# DateFormat(..., "[MM] %Y") ) — inspect flagged cases before blindly fixing.
# It does NOT verify that qualified refs ([Source/col]) point to real sources;
# the server reports those.

set -euo pipefail

FILE="${1:-}"
if [ -z "$FILE" ]; then
  echo "Usage: $0 <path-to-spec.yaml|.json>" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required. Install with: brew install jq (macOS) or apt install jq (Debian/Ubuntu)." >&2
  exit 2
fi

if [ ! -f "$FILE" ]; then
  echo "Error: file not found: $FILE" >&2
  exit 2
fi

# Convert YAML → JSON in memory if the file looks like YAML.
#
# Earlier versions trusted yq's exit code as proof of JSON output, which broke
# against Go yq (mikefarah, Homebrew default on macOS): `yq . file.yaml` exits 0
# but emits YAML, not JSON, so the downstream jq call failed with
# "Invalid literal at line 1, column 5". Fix: try Go yq's explicit -o=json first,
# fall back to Python yq's bare `.`, and validate each candidate with `jq empty`
# before accepting it — the success criterion is now "output parses as JSON",
# not "yq exited 0".
to_json() {
  case "$FILE" in
    *.yaml|*.yml)
      if command -v yq >/dev/null 2>&1; then
        # Go yq (mikefarah) — explicit JSON output flag, unambiguous.
        out=$(yq -o=json . "$FILE" 2>/dev/null) \
          && printf '%s' "$out" | jq empty >/dev/null 2>&1 \
          && { printf '%s' "$out"; return 0; }
        # Python yq (kislyuk) — bare `.` already emits JSON.
        out=$(yq . "$FILE" 2>/dev/null) \
          && printf '%s' "$out" | jq empty >/dev/null 2>&1 \
          && { printf '%s' "$out"; return 0; }
      fi
      if command -v python3 >/dev/null 2>&1; then
        python3 - "$FILE" <<'PY' 2>/dev/null && return 0
import sys, json
try:
    import yaml
except ImportError:
    sys.exit(2)
with open(sys.argv[1]) as f:
    print(json.dumps(yaml.safe_load(f)))
PY
      fi
      echo "Error: cannot convert YAML to JSON. Install one of:" >&2
      echo "  - Go yq:        brew install yq                (recommended on macOS)" >&2
      echo "  - Python yq:    pip install yq" >&2
      echo "  - PyYAML:       pip install PyYAML            (python3 + import yaml)" >&2
      exit 2
      ;;
    *)
      cat "$FILE"
      ;;
  esac
}

SPEC_JSON="$(to_json)"

# The live workbook OpenAPI requires a wrapped document with one flat
# document.elements array. Pages, overlays, and panels are metadata only;
# document.layout is the source of truth for placement and containment.
SHAPE_ISSUES=$(printf '%s' "$SPEC_JSON" | jq -r '
  if (.document | type) != "object" then
    "Missing required object: document"
  else
    .document as $d |
    (["schemaVersion", "kind", "elements", "pages"][] |
      select($d[.] == null) | "Missing required document field: \(.)"),
    (select(($d.elements | type) != "array") | "document.elements must be an array"),
    (select(($d.pages | type) != "array") | "document.pages must be an array"),
    (select($d.kind != null and $d.kind != "workbook") | "document.kind must be workbook"),
    ($d.pages[]? | select(has("elements")) |
      "Page \(.id // "(unnamed)") contains forbidden nested elements; move them to document.elements"),
    ($d.overlays[]? | select(has("elements")) |
      "Overlay \(.id // "(unnamed)") contains forbidden nested elements; move them to document.elements"),
    ($d.panels[]? | select(has("elements")) |
      "Panel \(.id // "(unnamed)") contains forbidden nested elements; move them to document.elements"),
    ($d.elements[]? |
      select(.kind == "container" and .style.padding? != null and .style.padding != "none") |
      "Container \(.id // "(unnamed)") style.padding must be none or omitted"),
    (select(($d.elements | type) == "array" and ($d.elements | length) > 0 and
      (($d.layout // "") | length) == 0) |
      "document.layout is required by skill policy when document.elements is non-empty")
  end
')

FORMULA_ISSUES=$(printf '%s' "$SPEC_JSON" | jq -r '
  .document.elements[]? |
    . as $element |
    select($element.source.kind != "warehouse-table") |
    (.columns // []) as $cols |
    ($cols | map(.name // "")) as $named |
    ($cols | map(
      (.formula // "") |
      (try capture("^\\[[^/]+/(?<name>[^\\]]+)\\]$").name catch "")
    )) as $derived |
    (($named + $derived) | map(select(. != ""))) as $siblings |
    $cols[]? |
    . as $col |
    ($col.formula // "") as $formula |
    ( [ $formula | scan("\\[[^/\\]]+\\]") | .[1:-1] ] ) as $bare_refs |
    ( $bare_refs | map(select(. as $ref | $siblings | index($ref) | not)) ) as $unresolved |
    select($unresolved | length > 0) |
    "Element: \($element.name // $element.id // "(unnamed)")\n  Column: \($col.name // $col.id // "(unnamed)")\n  Formula: \($formula)\n  Unresolved bare refs: \($unresolved | join(", "))\n"
')

LAYOUT_ISSUES=$(printf '%s' "$SPEC_JSON" | jq -r '
  .document as $d |
  (($d.elements // []) | map(.id) | map(select(. != null))) as $declared_all |
  ($declared_all | unique) as $declared |
  ([($d.layout // "") | scan("elementId=\"([^\"]+)\"") | .[0]]) as $placed_all |
  ($placed_all | unique) as $placed |
  ([($d.pages // [])[], ($d.overlays // [])[], ($d.panels // [])[]] |
    map(.id) | map(select(. != null)) | unique) as $declared_regions |
  ([($d.layout // "") | scan("<(?:Page|Overlay|Panel)[^>]*\\bid=\"([^\"]+)\"") | .[0]] | unique) as $placed_regions |
  (($d.elements // []) | map(select(.kind == "page-break") | .id)) as $page_break_ids |
  ([($d.layout // "") |
    scan("<(?:Element|LayoutElement)\\b[^>]*\\belementId=\"([^\"]+)\"[^>]*\\bgridRow=\"\\s*([0-9]+)\\s*/\\s*([0-9]+)\"")]) as $leaf_rows |
  (($d.layout // "") |
    select(test("<LayoutElement\\b")) |
    "Legacy layout tag <LayoutElement> is forbidden for authoring; emit <Element>"),
  (($d.layout // "") |
    select(test("<GridContainer\\b")) |
    "Legacy layout tag <GridContainer> is forbidden for authoring; emit <Container>"),
  ($leaf_rows[]? as $row |
    select(($page_break_ids | index($row[0])) != null and
      (($row[2] | tonumber) - ($row[1] | tonumber) != 1)) |
    "Page break \($row[0]) must span exactly one grid row (got \($row[1]) / \($row[2]))"),
  ($declared_all | group_by(.)[] | select(length > 1) | .[0] |
    "Duplicate document.elements id: \(.)"),
  ($placed_all | group_by(.)[] | select(length > 1) | .[0] |
    "Element is placed more than once in document.layout: \(.)"),
  ($placed - $declared)[]? | "Layout references undeclared elementId: \(.)",
  ($declared - $placed)[]? | "Element is not placed in document.layout: \(.)",
  ($placed_regions - $declared_regions)[]? | "Layout references undeclared page/overlay/panel id: \(.)",
  ($declared_regions - $placed_regions)[]? | "Page/overlay/panel is missing from document.layout: \(.)"
')

POINTER_ISSUES=$(printf '%s' "$SPEC_JSON" | jq -r '
  def element_label($e): ($e.name // $e.controlId // $e.id // "(unnamed)");
  def pointer_issue($label; $path; $pointer; $ids):
    if ($pointer | type) == "object" then
      if ($pointer | has("id")) and (($pointer | has("columnId")) | not) then
        "\($label) \($path) uses id; use columnId"
      elif $pointer.columnId != null and (($ids | index($pointer.columnId)) == null) then
        "\($label) \($path) references undeclared column \($pointer.columnId)"
      else empty end
    elif ($pointer | type) == "string" and (($ids | index($pointer)) == null) then
      "\($label) \($path) references undeclared column \($pointer)"
    else empty end;

  .document.elements[]? as $e |
  (element_label($e)) as $label |
  (($e.columns // []) | map(.id) | map(select(. != null))) as $ids |
  ($e | .. | objects | to_entries[] |
    select((.key | ascii_downcase) == "columnid" and .key != "columnId") |
    "\($label) uses incorrectly-cased field \(.key); use columnId"),
  (["xAxis", "value", "comparisonColumn", "holeValue", "geography",
    "latitude", "longitude", "region", "size", "category", "stage", "series"][] as $field |
    pointer_issue($label; $field; $e[$field]; $ids)),
  (["yAxis", "yAxis2"][] as $axis |
    ($e[$axis].columnIds // []) | to_entries[]? |
    pointer_issue($label; "\($axis).columnIds[\(.key)]"; .value; $ids)),
  (["rowsBy", "columnsBy"][] as $shelf |
    ($e[$shelf] // []) | to_entries[]? |
    pointer_issue($label; "\($shelf)[\(.key)]"; .value; $ids)),
  (["rowsBy", "columnsBy"][] as $shelf |
    ($e.trellis[$shelf] // []) | to_entries[]? |
    pointer_issue($label; "trellis.\($shelf)[\(.key)]"; .value; $ids)),
  (($e.seriesLineAreaStyle // []) | to_entries[]? |
    pointer_issue($label; "seriesLineAreaStyle[\(.key)]"; .value; $ids)),
  (select($e.kind == "pivot-table") |
    ($e.values // []) | to_entries[]? |
    pointer_issue($label; "values[\(.key)]"; .value; $ids)),
  (($e.order // []) | to_entries[]? |
    pointer_issue($label; "order[\(.key)]"; .value; $ids)),
  (select(($e.color | type) == "object" and ($e.color.columnId != null or $e.color.id != null)) |
    pointer_issue($label; "color"; $e.color; $ids)),
  (select(($e.color | type) == "object" and $e.color.column != null) |
    pointer_issue($label; "color.column"; $e.color.column; $ids))
')

GROUPING_ISSUES=$(printf '%s' "$SPEC_JSON" | jq -r '
  def aggregate_formula: test("(?i)\\b(sum|count|countdistinct|avg|average|min|max|median|percentile|stddev|variance)\\s*\\(");
  .document.elements[]? |
  select(.kind == "table") as $e |
  ($e.name // $e.id // "(unnamed)") as $label |
  ($e.columns // []) as $columns |
  ($columns | map(.id) | map(select(. != null))) as $ids |
  ($columns | map(select(.id != null) | {key: .id, value: .}) | from_entries) as $by_id |
  ($columns | map(select((.formula // "") | aggregate_formula))) as $aggregates |
  ($e.groupings // []) as $groupings |
  (if ($groupings | length) == 0 and ($aggregates | length) > 0 then
    "\($label) has aggregate columns but no groupings: \($aggregates | map(.id // .name) | join(", "))"
  else empty end),
  ($groupings | to_entries[]? | .key as $index | .value as $grouping |
    ((($grouping.groupBy // []) + ($grouping.calculations // []))[]? as $column_id |
      select(($ids | index($column_id)) == null) |
      "\($label) groupings[\($index)] references undeclared column \($column_id)"),
    (($grouping.calculations // [])[]? as $column_id |
      select($by_id[$column_id] != null and (($by_id[$column_id].formula // "") | aggregate_formula | not)) |
      "\($label) groupings[\($index)].calculations references non-aggregate column \($column_id)"),
    (($grouping.sort // []) | to_entries[]? as $sort |
      select($sort.value.columnId != null and (($ids | index($sort.value.columnId)) == null)) |
      "\($label) groupings[\($index)].sort[\($sort.key)] references undeclared column \($sort.value.columnId)")
  )
')

GROUPING_WARNINGS=$(printf '%s' "$SPEC_JSON" | jq -r '
  .document.elements[]? |
  select(.kind == "table" and ((.groupings // []) | length) > 0) as $e |
  ($e.name // $e.id // "(unnamed)") as $label |
  ([($e.groupings // [])[] | (.groupBy // [])[], (.calculations // [])[]] | unique) as $used |
  [($e.columns // [])[] as $column |
    select(($column.hidden // false) != true and (($used | index($column.id)) == null)) |
    ($column.id // $column.name)] as $visible_extras |
  select(($visible_extras | length) > 0) |
  "\($label) leaves visible detail columns outside groupBy/calculations: \($visible_extras | join(", "))"
')

if [ -z "$SHAPE_ISSUES" ] && [ -z "$FORMULA_ISSUES" ] && [ -z "$LAYOUT_ISSUES" ] && [ -z "$POINTER_ISSUES" ] && [ -z "$GROUPING_ISSUES" ]; then
  echo "OK: no obvious workbook spec errors."
  echo ""
  echo "Note: bare refs on warehouse-table sources are accepted as raw warehouse columns."
  echo "For other sources, this validator flags bare refs ([col] without a '/') that don't"
  echo "match a declared sibling column. It also checks the wrapped flat-document shape and"
  echo "layout coverage, column pointers, and grouped-table semantics. Qualified refs still"
  echo "require server readback and compile verification because Sigma may canonicalize names."
  if [ -n "$GROUPING_WARNINGS" ]; then
    echo ""
    echo "Workbook grouping warnings:"
    echo "$GROUPING_WARNINGS"
  fi
  exit 0
fi

if [ -n "$SHAPE_ISSUES" ]; then
  echo "Workbook shape errors:"
  echo ""
  echo "$SHAPE_ISSUES"
  echo ""
fi

if [ -n "$LAYOUT_ISSUES" ]; then
  echo "Workbook layout errors:"
  echo ""
  echo "$LAYOUT_ISSUES"
  echo ""
fi

if [ -n "$FORMULA_ISSUES" ]; then
  echo "Likely formula qualification errors:"
  echo ""
  echo "$FORMULA_ISSUES"
  echo "Fix: outside a warehouse-table source, a bare bracketed ref ([col] with no '/')"
  echo "must match a declared column in the SAME element. Otherwise add the source prefix."
  echo ""
  echo "  Wrong:  Count([Question ID])"
  echo "  Right:  Count([AI Usage Data/Question ID])"
fi
if [ -n "$POINTER_ISSUES" ]; then
  echo "Workbook column pointer errors:"
  echo ""
  echo "$POINTER_ISSUES"
  echo ""
fi

if [ -n "$GROUPING_ISSUES" ]; then
  echo "Workbook grouping errors:"
  echo ""
  echo "$GROUPING_ISSUES"
  echo ""
fi

if [ -n "$GROUPING_WARNINGS" ]; then
  echo "Workbook grouping warnings:"
  echo ""
  echo "$GROUPING_WARNINGS"
  echo ""
fi
exit 1
