# Workbook Spec Validation

Validate before every POST/PUT, then read back and compile-check after the write.

## 1. Confirm the live shape

The workbook body is wrapped:

```yaml
name: Example
folderId: <folder-id>
document:
  schemaVersion: 1
  kind: workbook
  elements: [...]
  pages: [...]
  layout: |
    ...
```

The live OpenAPI requires flat `document.elements` and metadata-only pages.
PUT accepts only `{document: {...}}`. Data-model specs are a separate surface
and may retain nested `pages[].elements`.

## 2. Dry-run

```bash
./scripts/wb-rep.rb verify /tmp/workbook-spec.yaml
```

The verify endpoint catches representation and dependency errors without
persistence.

## 3. Offline validation

```bash
./scripts/validate-spec.sh /tmp/workbook-spec.yaml
```

This checks the wrapper, required arrays, forbidden nested elements, formula
qualification heuristics, bidirectional layout coverage, case-sensitive
`columnId` pointers, pointer targets, and common grouped-table mistakes.

## 4. Manual formula pass

For every formula:

1. A bare `[Column]` must resolve to a column declared on the same element.
2. A qualified reference uses the applicable prefix:
   - warehouse table: source table name;
   - workbook element: source element `name`;
   - join: join top-level/leg name;
   - Custom SQL: literal `Custom SQL` and the exact SQL alias;
   - data model: data-model element name.
3. Raw warehouse identifiers are accepted and Sigma may canonicalize them on
   POST. Do not guess a friendly conversion up front.
4. Custom SQL aliases and join keys are special: use their exact documented
   forms rather than applying general warehouse-name normalization.

## 5. Shape and layout pass

- `document` has `schemaVersion`, `kind: workbook`, `elements`, and `pages`.
- `pages`, `overlays`, and `panels` contain metadata only.
- Every literal element appears once in `document.elements`.
- Every element is placed in `document.layout`.
- Layout references only declared elements and known page/overlay/panel IDs.
- Container children use canonical `<Container>` / `<Element>` tags; tabbed
  containers use `<TabbedContainer>` / `<Tab>`.
- Never emit legacy `<GridContainer>` / `<LayoutElement>` aliases.
- A `page-break` spans exactly one layout row.
- Preserve `settings`, `agents`, `overlays`, and `panels on full-replacement PUT.
- Box charts remain unsupported/pending: no box-chart element kind exists in
  the live OpenAPI.

## 5b. Grouping pass

- A `table` with aggregate columns needs `groupings`; otherwise it renders
  detail rows even when its formulas look like a summary.
- Every `groupBy`, `calculations`, and grouping sort reference names a column
  declared on that table.
- Every `calculations` column contains an aggregate expression.
- Columns used only to support a grouped calculation should be hidden. A
  visible column outside `groupBy` / `calculations` exposes detail rows in the
  grouped table.
- Multiple grouping objects are nested levels, not independent summaries.

## 6. Readback and compile verification

POST success does not prove semantic or visual correctness. Immediately GET the
spec and compare it with the submitted document:

- use the warehouse formula form returned by readback for future edits (Sigma
  may canonicalize a raw name or preserve it);
- confirm optional fields survived instead of being silently stripped;
- confirm dynamic text and control references were normalized/resolved;
- confirm layout, theme, navigation, overlays, and panels survived.

Then run:

```bash
./scripts/verify-workbook.sh <workbook-id>
```

Finally render every affected page. Compile verification cannot prove that a
join groups as intended, a control has options, a progress ring uses the right
scale, or a layout is visually usable.

## Common errors

| Error | Meaning |
|---|---|
| `document.pages[].elements is no longer supported` | Move literal elements to `document.elements`; use layout for placement. |
| `element '<id>' is not placed in layout` | Add a layout placement for that flat element. |
| `Invalid kind: document.elements[N]` | The selected element/control subtype has the wrong inner shape. |
| `Dependency not found` | A source, column, control, or dynamic reference did not resolve. |
| `Column reference not found` on a join | The join key does not match the required exact source column form. |
| field disappears on GET | The server ignored/stripped it; use the canonical readback or inspect the live schema. |

## Retry budget

Do not use the write endpoint as a syntax search loop. For each failed
POST/PUT:

1. classify it as authentication, entitlement, shape/schema, dependency, or
   semantic/rendering;
2. make one local correction backed by validator/OpenAPI/readback evidence;
3. rerun offline validation and dry-run verification;
4. submit one corrected write.

If the same error class persists, stop and surface the unresolved contract or
entitlement. Do not rotate through guessed field names such as `columnID`,
`column`, `id`, and `columnId`.

Do not convert a successful POST into a claim of parity. The readback,
compiler query, and render are separate gates.
