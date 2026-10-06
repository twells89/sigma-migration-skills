#!/usr/bin/env bash
# Offline regressions for validate-spec.sh formula and control contracts.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$HERE/validate-spec.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

write_spec() {
  local path="$1" formula="$2" control_source="$3"
  jq -n \
    --arg formula "$formula" \
    --argjson control_source "$control_source" \
    '{
      name: "Validator contract",
      folderId: "folder-test",
      document: {
        schemaVersion: 1,
        kind: "workbook",
        pages: [{id: "page-1", name: "Page"}],
        elements: [
          {
            id: "table-1",
            kind: "table",
            name: "Orders summary",
            source: {kind: "data-model", dataModelId: "dm-test", elementId: "orders"},
            columns: [
              {id: "region", name: "Region", formula: $formula},
              {id: "amount", name: "Amount", formula: "[Orders/Amount]"}
            ]
          },
          ({
            id: "control-1",
            kind: "control",
            controlId: "RegionFilter",
            controlType: "list",
            name: "Region",
            mode: "include",
            selectionMode: "multiple",
            values: [],
            filters: [{source: {kind: "table", elementId: "table-1"}, columnId: "region"}]
          } + (if $control_source then {
            source: {
              kind: "source",
              source: {kind: "table", elementId: "table-1"},
              columnId: "region"
            }
          } else {} end))
        ],
        layout: "<Workbook><Page id=\"page-1\"><Element elementId=\"table-1\"/><Element elementId=\"control-1\"/></Page></Workbook>"
      }
    }' > "$path"
}

expect_pass() {
  local path="$1" label="$2"
  "$VALIDATE" "$path" > "$TMP/out" ||
    { printf 'FAIL: expected pass: %s\n' "$label" >&2; return 1; }
  printf 'PASS: %s\n' "$label"
}

expect_fail() {
  local path="$1" needle="$2" label="$3"
  if "$VALIDATE" "$path" > "$TMP/out" 2>&1; then
    printf 'FAIL: expected failure: %s\n' "$label" >&2
    return 1
  fi
  case "$(< "$TMP/out")" in
    *"$needle"*) ;;
    *)
      printf 'FAIL: wrong diagnostic for %s\n' "$label" >&2
      printf '%s\n' '--- output ---' >&2
      printf '%s\n' "$( < "$TMP/out" )" >&2
      return 1
      ;;
  esac
  printf 'PASS: %s\n' "$label"
}

write_spec "$TMP/valid.json" "[Orders/Region]" true
expect_pass "$TMP/valid.json" "qualified source reference + populated list control"

write_spec "$TMP/self-ref.json" "[Region]" true
expect_fail "$TMP/self-ref.json" "Unresolved bare refs: Region" \
  "a column cannot treat itself as a valid sibling"

write_spec "$TMP/filters-only.json" "[Orders/Region]" false
expect_fail "$TMP/filters-only.json" "Missing value-list source" \
  "filters-only list control cannot ship with an empty picker"

printf '%s\n' "ALL PASS"
