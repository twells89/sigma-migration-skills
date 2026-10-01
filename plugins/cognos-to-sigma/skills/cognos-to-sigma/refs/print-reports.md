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
   horizontal pagination, static HTML and missing data. Reports containing
   Cognos prompt/drill controls are refused until the controls can be carried
   into the PDF without changing data. Unconverted detail or summary filters
   also stop the print path. A
   created Report with unsupported visual content is not a completed conversion.

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

## Bind and validate (Sigma REST)

Remap placeholder query-subject names to posted model element IDs, then run
the Report API's **dry run** before creating it:

```bash
node scripts/remap-report-to-dm-ids.mjs --report /tmp/cognos-report.json \
  --dm-id <data-model-id> --out /tmp/cognos-report.remapped.json
node scripts/validate-report-spec.mjs --spec /tmp/cognos-report.remapped.json \
  --folder <selected-folder-id> --name "Quarterly Statement"
```

The validator uses current `POST /v2/reports` with `contents` and `dryRun:true`
(the old `/v2/reports/spec` endpoint is deprecated). Once dry-run passes and
the user chose a destination, rerun with `--create --out
/tmp/cognos-report.readback.json`. Creation reads back the data elements and
fails on `type:error` columns. `POST /v2/reports` publishes version 1 on
create; later edits must be published before exporting. Then:

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
