# Print-critical Cognos reports → Sigma Reports

Sigma Reports use pixel-positioned pages, header/footer panels, vertically
paginated tables and PDF export. A workbook page-break or PNG is not print
parity. The print mode shares the workbook converter's data logic, but emits
Sigma Report `contents` instead of a workbook spec.

## Inputs and fidelity gates

1. Export the Cognos report-spec XML and Data Module JSON or Framework Manager
   `model.xml` (`.cpf` is only a workspace pointer). Offline files work.
2. Obtain a **rendered Cognos PDF** using representative prompts and enough rows
   to exercise pagination. XML alone cannot reveal actual font, wrap and page
   positions. Use the PDF to determine pixel page size and margins.
3. Land required data in the warehouse and post/read back a Sigma data model.
   No placeholder `--dm` can be used for Sigma validation.
4. Resolve conversion warnings, including compound cells, unsupported formulas,
    horizontal pagination, static HTML and missing data. Structured filters
    without expressions are warned in the workbook path and refused in print
    mode rather than exporting rows Cognos excluded. Reports containing
    Cognos prompt/drill controls are refused until the controls can be carried
    into the PDF without changing data. Unconverted detail or summary filters
    also stop the print path. Hidden workbook chart-source tables (such as a
    scatter's grouping dependency) cannot be printed as extra tables; print
    mode refuses them until the dependency has a verified non-printing Report
    placement. A created Report with unsupported visual content is not a
    completed conversion.

**Live API limit:** Sigma Report *code* currently rejects `pivot-table` even
though the UI supports pivots. The print converter rejects a Cognos crosstab
rather than silently replacing it with a list. The workbook converter still
builds native pivots. Do not claim pixel-perfect support for crosstabs here.

## Draft a Report (offline)

Run from the `cognos-to-sigma` skill directory:

```bash
node converter/cli.mjs /path/to/report.xml --print --dm <data-model-id> \
  --page-width 816 --page-height 1056 --margin 48 \
  --out /tmp/cognos-report.json --warnings-out /tmp/cognos-print-warnings.json
```

The defaults are US letter at 96 dpi. Read the *source* PDF for page geometry
and adjust `--page-width`, `--page-height`, and `--margin`. Tables use
`flow="paginated"`; headers and footers get Sigma `<Panel>` layout roots.
Static text and relative source CSS are starting hints, not an exact copy.
Sigma Reports only paginate data tables vertically and export up to 10,000
rendered rows per table; the converter flags incompatible Cognos settings.

### Author additional print pages and repeated furniture

When the converted list page needs a designed cover, explanatory/terms pages,
or a repeated footer, author those from approved text in a JSON blueprint.
The neutral `fixtures/print-layout-blueprint.json` exercises nine letter-size
pages: graphic cover, letter, data-backed summary, six dense placeholder-text
pages, diagonal draft marks on the introductory pages, and a repeating footer.
All content is fictional; this is a layout smoke test, not a parity oracle.

```bash
node scripts/compose-print-layout.mjs --spec /tmp/cognos-report.json \
  --blueprint fixtures/print-layout-blueprint.json --out /tmp/cognos-report.composed.json
```

`pages[]` entries take `name` (new page, optionally `position: "first"` or
`position: "after"` with `afterPage`) or `sourcePage` (the converted page name).
`blocks[]` contain `x`, `y`, `width`, `height`, and a `body` string. Optional
`fontSize` styles an editable text block; `dense: true` renders supplied
prose as one **SVG image** with compact leading, not editable Sigma text.
Its text remains in the blueprint but is rasterized on export; replace it
with approved searchable copy before production use. The neutral fixture
alone sets `sampleFill: true` to generate clearly labeled nonbinding filler;
ordinary blueprints never invent text, and an oversized supplied block fails
instead of silently truncating. `emblem` creates an
illustrative circular SVG mark from `label`, `subtitle` and a hex `accent`.
For a diagonal text watermark use `watermark`
with `text`, optional hex `color`, `opacity` in `[0,1]`, and `angle`. The
optional `imageBox` positions its image layer **inside the printable canvas**.
The default box is a centered, bounded rectangle for a letter-size page.
`backgroundImageUrl` supplies an HTTPS image instead of a generated SVG.
`footer` takes `body`, optional `pages` (names; all pages by default),
`height`, text geometry and optional `brand` (a neutral SVG mark). It replaces an overlapping
converter footer; review the source footer before doing so. Use
`{{CurrentPageNumber()}} of {{TotalPageCount()}}` in the body for Sigma's
dynamic page numbers. Inspect any overflow sheets when tables paginate.
On a `sourcePage`, `tableTitle` and `tableBox` retitle/reposition a single
paginated table. `removeSourceHeader: true` removes a redundant converter
header only when it belongs exclusively to that page; the composer fails
closed for a header shared across multiple pages.

Sigma Report code does not accept `pages[].backgroundImage`; use the bounded
image layer generated by the composer instead. An image sized to the full
page can cause unexpected extra PDF pages even if Sigma's dry run passes.
Review every exported sheet for layering, text wrapping, and repeated panels.
With a posted data model, remap IDs and validate the **composed** spec through
the REST dry run, create/readback, and PDF export steps below. The neutral
example was read back with valid columns and exported as **nine** nonblank
letter-size PDF pages, with `1 of 9` through `9 of 9` page numbers. This
establishes render behavior and page sequence only, not data or pixel parity.

## Bind and validate (Sigma REST)

Remap placeholder query-subject names to posted model element IDs, then run
the Report API's **dry run** before creating it:

```bash
node scripts/remap-report-to-dm-ids.mjs --report /tmp/cognos-report.json \
  --dm-id <data-model-id> --out /tmp/cognos-report.remapped.json
node scripts/validate-report-spec.mjs --spec /tmp/cognos-report.remapped.json \
  --folder <selected-folder-id> --name "Quarterly Statement"
```

When using a blueprint, pass `/tmp/cognos-report.composed.json` as `--report`
instead. The validator uses current `POST /v2/reports` with `contents` and
`dryRun:true`
(the old `/v2/reports/spec` endpoint is deprecated). Once dry-run passes and
the user chose a destination, rerun with `--create --out
/tmp/cognos-report.readback.json`. Creation reads back the data elements and
fails on `type:error` columns. `POST /v2/reports` publishes version 1 on
create. For subsequent layout edits, **update the same Report** instead of
creating a new one:

```bash
node scripts/validate-report-spec.mjs --spec /tmp/cognos-report.remapped.json \
  --folder <selected-folder-id> --name "Quarterly Statement" \
  --update <existing-report-id> --backup /tmp/report-before.json \
  --out /tmp/report-after.json
```

The update verifies the dry run, matches the existing destination and data
sources, checks the element inventory, saves the full GET as a rollback
record, sends the current `documentVersion` with a full replacement PUT,
then reads back the result and checks for broken columns. It does not create
a new Report. Publish later UI edits before exporting. Then:

```bash
node scripts/export-report-pdf.mjs --report <report-id> \
  --out /tmp/sigma-report.pdf --layout portrait
```

The download endpoint can return HTTP 204 until rendering finishes; the
exporter polls for a non-empty `%PDF-` file. Inspect every page and table's
last page, including the printed totals, page numbers and panel repetition.

## Compare to the independent source PDF

```bash
python3 scripts/compare-report-pdfs.py \
  --cognos /path/to/rendered-cognos.pdf --sigma /tmp/sigma-report.pdf \
  --out /tmp/print-parity.json
```

Requires Poppler (`pdfinfo`, `pdftotext`, `pdftoppm`) and Pillow. Checks page
count, paper size, blank pages, printed values and text, and per-page raster
differences. Comparing an output to *itself* tests the comparator but cannot
prove Cognos parity. Where no source PDF exists, report only Sigma structural
validation and a rendered Sigma PDF, not pixel-perfect parity.

References: [Reports as code](https://help.sigmacomputing.com/docs/manage-reports-as-code),
[paginated table](https://help.sigmacomputing.com/docs/example-representation-report-with-a-paginated-table),
[PDF export API](https://help.sigmacomputing.com/reference/export-report).
