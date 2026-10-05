# Element-Level Workbook Rep (`scripts/wb-rep.rb`)

The spec API replaces a whole workbook document. The rep makes one flat
`document.elements[]` entry the editing unit while preserving metadata and
layout separately.

## File representation

```text
<rep>/
  workbook.yaml                 outer metadata + remaining document fields
  elements/
    010-revenue-kpi.yaml        one flat document.elements entry per file
    020-sales-by-region.yaml
  pages/
    010-overview/
      _page.yaml                page metadata only
      _layout.xml               matching <Page id="overview"> layout block
  overlays/
    010-detail/
      _overlay.yaml             modal/drawer metadata
      _layout.xml
  panels/
    010-sidebar/
      _panel.yaml               panel metadata
      _layout.xml
  renders/
  .sigma/
    manifest.yaml
    snapshot.yaml               canonical wrapped GET shape
    layout-preamble.xml
```

`workbook.yaml` mirrors the API wrapper:

```yaml
name: Sales
folderId: <folder-id>
document:
  schemaVersion: 1
  kind: workbook
  settings: { ... }
  agents: [...]
```

The split collections and layout are inserted beneath that `document` during
assembly. Elements never live beneath a page directory. Layout is the source of
truth for page/container/tab membership, so moving an element means editing
`_layout.xml`, not moving its YAML file.

## Commands

```bash
scripts/wb-rep.rb summarize <id|dir>
scripts/wb-rep.rb pull <workbook-id> <dir>
scripts/wb-rep.rb status <dir>
scripts/wb-rep.rb push <dir>
scripts/wb-rep.rb render <dir>
scripts/wb-rep.rb render <dir> --page Overview
scripts/wb-rep.rb import <spec.yaml> <dir>
scripts/wb-rep.rb assemble <dir> -o out.yaml
scripts/wb-rep.rb verify <spec.yaml>
scripts/wb-rep.rb lint <dir|spec.yaml>
scripts/wb-rep.rb capabilities --kind bar-chart
```

`pull` and `import` accept the wrapped API shape. A legacy flat artifact can be
read and is normalized immediately to the wrapped representation.

`push`:

1. reassembles the wrapped spec;
2. checks remote drift;
3. previews metadata, layout, and element changes;
4. validates flat-element formulas, layout coverage, and filter reference integrity;
5. POSTs the full create body or PUTs exactly `{document: {...}}`;
6. saves the canonical readback, including server normalization.

### `lint` — offline reference integrity

`lint` runs the two offline structural checks that `push` also runs, without any
network call: layout coverage, and **filter reference integrity**.

Every `filters[].columnId` must name a column declared on the element that owns
it. There are two shapes (see `../specification/controls.md`):

| Shape | Where the column lives |
|---|---|
| control wiring — `{ source: { kind: table, elementId }, columnId }` | the **target** element |
| element predicate — `{ id, columnId, kind: list \| top-n \| ... }` | the **owning** element |

Run it after editing any element file by hand, and always before `push` on a rep
you edited fragment-by-fragment:

```bash
scripts/wb-rep.rb lint <dir>
```

> **Why this is not redundant with `verify`.** Sigma's
> `POST /v2/workbooks/spec/verify` validates the element-predicate shape but
> **not** control wiring. Measured 2026-08-20: a control whose filter names a
> nonexistent column returns `valid: true` with zero errors, saves with the bogus
> id intact, and compiles with zero errors from
> `GET /v2/workbooks/{id}/queries` — the control just silently stops filtering.
> Nothing server-side catches it, so `lint` does.
>
> Related: `verify` also rejects some workbooks that are live and working (e.g.
> unresolvable data-model dependencies, overlay actions referencing a removed
> page). Treat a `verify` failure on a pre-existing workbook as "compare against
> a pre-edit baseline", not "this edit is broken".

## Editing rules

- Add/delete an element in `elements/` and add/delete every corresponding
  `elementId` placement in layout.
- Reorder pages/overlays/panels by filename prefix. Element filename order is
  useful for review but does not establish page ownership.
- `_page.yaml`, `_overlay.yaml`, and `_panel.yaml` are metadata only.
- Every non-empty workbook must have explicit layout under this skill policy.
- Keep IDs stable. Cross-element formulas use element names, so update dependent
  formulas when renaming.
- PUT is full document replacement. Never remove `settings`, `agents`,
  `overlays`, or `panels` merely because the current edit does not touch them.

After a push, run compile verification and inspect rendered pages. A successful
write proves shape validity, not formula parity or visual correctness.
