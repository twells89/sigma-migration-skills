# Print-critical Cognos reports → Sigma Reports

Sigma Reports use pixel-positioned pages, header/footer panels, vertically
paginated tables and PDF export. A workbook page-break or PNG is not print
parity. The print mode shares the workbook converter's data logic, but emits
Sigma Report `contents` instead of a workbook spec.

## Editable output contract

Recreate the report as native Sigma elements. Use the XML for text, expressions,
queries, controls and data bindings; use the rendered PDF to measure and verify
appearance. Do not embed a PDF page, screenshot, or SVG rendering of business
text/tables as the report output. Visual similarity alone cannot prove an
editable migration, even when the exported PDF looks identical.

Keep labels and prose in `kind: text`; data records/totals in native data elements
with verified sources/formulas. Images are for approved logos, illustrations,
watermarks or barcode artwork, not substitutes for business content. If a layout
cannot be recreated natively, report that limitation and stop rather than flatten
it. Do not add token text or a dummy table to make an image-based page pass a gate.

Before declaring completion, inventory each substantive source section against
its native element IDs/kinds on GET readback, edit representative text and data
formatting in the retained preview, and re-export to verify the edits and every
page. The preflight rejects image-only page bodies even when another page has a
table or a repeating footer contains text. Mixed screenshot/text pages still need
manual inventory review; that structural check cannot identify every screenshot.

## Inputs and fidelity gates

1. Export the Cognos report-spec XML and Data Module JSON or Framework Manager
   `model.xml` (`.cpf` is only a workspace pointer). Offline files work.
2. Obtain a **rendered Cognos PDF** using representative prompts and enough rows
   to exercise pagination. XML alone cannot reveal actual font, wrap and page
   positions. Use the PDF to determine pixel page size and margins.
3. Land required data in the warehouse and post/read back a Sigma data model.
    **Reuse or create:** a matching existing model is not a prerequisite. Follow
    `report-only-model.md` for report XML/PDF input without a semantic-model export.
    Complete model construction before invoking the print converter.
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

**Last live validation (2026-10-01):** Sigma Report code rejected `pivot-table`.
Current beta documentation lists broader support, including repeated containers;
do not generalize the converter's guards into permanent platform limitations.
This converter still refuses crosstabs and repeated/nested layouts until those
specific paths have a verified Report representation and PDF readback. The
workbook converter retains native pivots.

Nested data containers keep their fields and group keys in their own query
scope in the diagnostic workbook. That is not a nested-record implementation:
the print path refuses nested lists, master-detail links and compound list cells
until their complete content, row correlation and pagination are authored.
Used query sources with unsupported joins, set operations or unsafe query references are
flagged and left unbound; projecting a model column from a joined query does
not make that query equivalent to the column's base table. These dependencies
block print rather than silently losing upstream filters or changing row grain.
The workbook ID remapper requires an exact existing element ID or an unambiguous
subject-name match, even for a model with only one table. It leaves workbook-local
table dependencies unchanged and does not overwrite output on unresolved bindings.

Prompt pages are input UI, not output pages. Their tables, page breaks and
panels are excluded from the workbook and Report; their select-value and custom-
control metadata remains available to translate supported workbook controls.
A prompt-only report fails instead of inventing an output page. Print also
refuses runtime prompt widgets (including search/text prompts that did not
produce a workbook control), conditional rendering, untranslated layout report
expressions, page sets and active page-count/number resets. A default selection
is not evidence of the source run's parameters, and global page numbering is
not equivalent to per-document resets. Explicit false/zero resets do not block.

### Safe query projections

A direct `<source><queryRef refQuery="upstream"/></source>` can resolve through
one or more alias-only queries to a single detail-grain model subject. Each
projected item must be an exact `[upstream].[Item]` reference with explicit
`aggregate="none"` throughout the chain; the base items
must be three- or four-part model references to the same namespace/subject path.
Aliases and declared data types are retained. Required/default literal `=` and
`in (...)` filters from every stage are applied on hidden columns bound to their
original fields, even if those fields are omitted or their names are reused
for different output columns. Prohibited predicates stay disabled; quoted
numeric-looking strings, commas and escaped quotes remain literal values.

This is not arbitrary query execution. Computed expressions, aggregates
(including unselected upstream aggregates), distinct/auto-summary boundaries,
query-level sorts, optional or prompt filters, active summary/structured filters,
mixed model paths, ambiguous names, missing items and cycles remain unbound.
No intermediate helper table or SQL is invented to conceal an unsupported
boundary. General joined/set queries and nested-record pagination are still separate
implementation gaps, and even a safe offline projection needs posted-model
readback plus independent source-value/PDF parity before production use.

### Detail workbook joins

Two safe detail/projection operands can form an inner (default) or `leftOuter`
equijoin with composite `AND` keys. Operand predicates execute on dedicated
source tables on a hidden workbook page, before the join. The join uses ordinary
relational matching, not lookup/deduplication; declared Cognos cardinality is
not proof of key uniqueness. Output fields must be exact operand aliases with
`aggregate="none"`. Post-join filters, computed outputs, aggregation, nested
joins, optional/unknown operand cardinalities, unsupported join kinds and
non-equi/OR conditions remain blocked.

The emitted source follows the current compiled Sigma join schema and is tested
offline for duplicate-key fanout, null keys, composite keys and outer-join filter
placement. A synthetic sample-model join was also created/read back with clean
columns and exported in Sigma: input predicates remained inside each subquery,
and an unmatched left row retained a null right value. This validates that
restricted path, not arbitrary source joins or customer warehouse parity. The Report
path refuses these hidden source dependencies until non-printing placement is
verified, rather than printing extra source tables.

Ordinary literal filters use the same strict parser as projected predicates.
Optional filters and unresolved multi-select/cascading/search prompt comparisons
are flagged rather than applied unconditionally or as literal `?prompt?` text.

## Draft a Report (offline)

### Keep discovery bounded

Inventory large XML/PDF inputs locally rather than attaching the full documents
to model context. Start with `pdfinfo` and a namespace-aware XML parser; store
the query dependency graph, prompt definitions, filter usage, nested lists,
master-detail links, scoped totals, barcode requirements, and page-set/reset
semantics in a private work directory outside the repository. If strict XML
parsing fails, report the encoding/syntax error; do not silently repair the
source or treat replacement-decoded text as authoritative.
The CLI rejects invalid UTF-8 bytes and non-UTF-8 XML declarations, and the report
parser validates XML structure before conversion. Obtain a clean UTF-8 export
or explicitly transcode from a confirmed encoding; no automatic repair is made.

Extract PDF text to local files and inspect small, explicit page ranges. Count
all pages and document boundaries programmatically, then inspect representative
first, continuation, and final pages visually. Record which source layouts the
PDF actually covers and obtain missing layouts and runtime prompt selections.
Keep raw converter outputs and errors private; return concise findings, not
whole XML files, PDFs, or warning dumps. At final parity, compare **every** page
in bounded batches; sampling during discovery is not final parity.

`use="prohibited"` detail and summary filters are disabled in Cognos and are
excluded from conversion and print filter guards. Required/default and optional
filters are not disabled: resolve their runtime behavior and all unconverted
filter warnings before printing. Do not infer prompt selections from defaults
or apply disabled test predicates from the XML.

### Run the converter

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
`fontSize` styles an editable text block; `dense: true` splits supplied prose
into separately positioned native text paragraphs, preserving editability.
Its conservative line-count estimate can reject overflow; split/reflow the
approved text and inspect the actual export, never fall back to an image.
Live rendering uses a minimum line box even at small inline font sizes; the
composer budgets at least 24px per line and emits Markdown hard breaks for
explicit source newlines. Reducing the font alone does not safely reduce height.
The neutral fixture alone sets `sampleFill: true` to generate clearly labeled nonbinding filler;
ordinary blueprints never invent text, and an oversized supplied block fails
instead of silently truncating. `emblem` creates an
illustrative circular SVG mark from `label`, `subtitle` and a hex `accent`.
For a diagonal text watermark use `watermark`
with `text`, optional hex `color`, `opacity` in `[0,1]`, and `angle`. The
optional `imageBox` positions its image layer **inside the printable canvas**.
The default box is a centered, bounded rectangle for a letter-size page.
`backgroundImageUrl` supplies decorative HTTPS artwork instead of a generated
watermark SVG. Never use it to insert a rendered source report or data table.
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
example was subsequently updated in place with native dense text, read back,
and exported as nine nonblank letter pages. All supplied terms paragraphs were
extractable on the expected pages, the table binding survived, and a further
edit to an existing text element appeared in the next export. The initial native
text export clipped lines; the minimum line-box correction above fixed the
observed issue. This is sample render/editability evidence, not a claim of
pixel-identical customer reproduction. Re-export after any content or font change.

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
prove Cognos parity: identical file content explicitly fails the parity verdict.
Paper size is checked for every page, not just the first sheet. Where no source PDF exists, report only Sigma structural
validation and a rendered Sigma PDF, not pixel-perfect parity.

References: [Reports as code](https://help.sigmacomputing.com/docs/manage-reports-as-code),
[paginated table](https://help.sigmacomputing.com/docs/example-representation-report-with-a-paginated-table),
[PDF export API](https://help.sigmacomputing.com/reference/export-report).
