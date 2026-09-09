#!/usr/bin/env node
// apply-layout.mjs — give a migrated Metabase workbook a CLEAN dashboard grid.
//
// Sigma auto-arrange stacks every element at the SAME height (KPIs as tall as tables,
// charts squished) — so for any multi-element page we write an explicit 24-col layout:
// controls in a top row, then content stacked full-width with per-kind heights. Layout
// CREATE preserves element ids and the converter already emits this layout.
// This script GETs the current document and reapplies it as the final,
// layout-safe full-document write after any post-create repair.
//
// Usage:
//   eval "$(scripts/get-token.sh)"
//   node scripts/apply-layout.mjs --workbook <workbookId> [--hints layout-hints.json]
//
// --hints (from `cli.ts … --layout-out hints.json`) reproduces the ORIGINAL
// Metabase dashboard geometry 1:1 (24-col grid, row/col/sizeX/sizeY per element;
// element ids are preserved on workbook CREATE so hints match the live spec).
// Controls aren't Metabase dashcards, so they get a top band; hinted content is
// placed below at exact coordinates; unhinted leftovers stack at the bottom.
// Without --hints, falls back to the generic per-kind stacked layout.
//
// Idempotent. Run it as the last step of the build/verify phase.
import { readFileSync } from 'node:fs';
import { api, parseArgs } from './lib/sigma-rest.mjs';
import { document, workbookElements, workbookElementsWithPages, wrap } from './lib/code_rep.mjs';

const a = parseArgs(process.argv.slice(2));
if (!a.workbook) { console.error('need --workbook <workbookId> [--hints hints.json]'); process.exit(2); }
const hints = a.hints ? JSON.parse(readFileSync(a.hints, 'utf8')) : null;
const ROWSCALE = 2; // Metabase row unit → Sigma grid rows (proportions, rows are "auto")

// per-kind row-unit heights (24-col grid; rows are "auto" so spans set relative size)
const H = (k) => k === 'control' ? 2
  : k === 'kpi-chart' ? 6
  : k.endsWith('-chart') ? 10
  : (k.endsWith('-map') || k === 'pivot-table' || k === 'table') ? 12
  : k === 'text' ? 3 : 10;

// Exact mode: place each hinted element at its Metabase grid coordinates.
function pageLayoutExact(page, els, hintEls) {
  els = (els || []).filter((e) => e.id);
  const byId = new Map(els.map((e) => [e.id, e]));
  // name fallback queues (texts share names — consume in order)
  const byName = new Map();
  for (const e of els) {
    const k = String(e.name || e.kind || '').toLowerCase();
    if (!byName.has(k)) byName.set(k, []);
    byName.get(k).push(e);
  }
  const controls = els.filter((e) => e.kind === 'control');
  const lines = [];
  let row = 1;
  controls.forEach((c, i) => {
    const perRow = Math.min(controls.length, 4);
    const span = Math.floor(24 / perRow);
    const col0 = 1 + (i % perRow) * span;
    const r = row + Math.floor(i / perRow) * H('control');
    const col1 = (i % perRow === perRow - 1) ? 25 : col0 + span;
    lines.push(`  <Element elementId="${c.id}" gridColumn="${col0} / ${col1}" gridRow="${r} / ${r + H('control')}"/>`);
  });
  if (controls.length) row += Math.ceil(controls.length / 4) * H('control');

  const placed = new Set(controls.map((c) => c.id));
  let maxRow = row;
  for (const h of hintEls || []) {
    let el = byId.get(h.elementId);
    if (!el || placed.has(el.id)) {
      const q = byName.get(String(h.name || '').toLowerCase()) || [];
      el = q.find((e) => !placed.has(e.id));
    }
    if (!el || placed.has(el.id) || el.kind === 'control') continue;
    placed.add(el.id);
    const c0 = Math.max(1, (h.col ?? 0) + 1);
    const c1 = Math.min(25, c0 + Math.max(h.sizeX ?? 4, 1));
    const r0 = row + (h.row ?? 0) * ROWSCALE;
    const r1 = r0 + Math.max((h.sizeY ?? 4) * ROWSCALE, 2);
    lines.push(`  <Element elementId="${el.id}" gridColumn="${c0} / ${c1}" gridRow="${r0} / ${r1}"/>`);
    if (r1 > maxRow) maxRow = r1;
  }
  // anything unhinted stacks full-width below the hinted grid
  for (const e of els) {
    if (placed.has(e.id)) continue;
    const h = H(e.kind);
    lines.push(`  <Element elementId="${e.id}" gridColumn="1 / 25" gridRow="${maxRow} / ${maxRow + h}"/>`);
    maxRow += h;
  }
  return `<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="${page.id}">\n${lines.join('\n')}\n</Page>`;
}

function pageLayout(page, els) {
  els = (els || []).filter((e) => e.id);
  const controls = els.filter((e) => e.kind === 'control');
  const content = els.filter((e) => e.kind !== 'control');
  const lines = [];
  let row = 1;
  // controls: up to 4 across the top
  controls.forEach((c, i) => {
    const perRow = Math.min(controls.length, 4);
    const span = Math.floor(24 / perRow);
    const col0 = 1 + (i % perRow) * span;
    const r = row + Math.floor(i / perRow) * H('control');
    const col1 = (i % perRow === perRow - 1) ? 25 : col0 + span;
    lines.push(`  <Element elementId="${c.id}" gridColumn="${col0} / ${col1}" gridRow="${r} / ${r + H('control')}"/>`);
  });
  if (controls.length) row += Math.ceil(controls.length / 4) * H('control');
  // content: stacked full-width, per-kind heights (clean, no overlap, right proportions).
  // Exception: RUNS of consecutive kpi-charts lay out as rows of up to 3 TALL tiles
  // (a KPI panel) — full-width singles waste a page and Sigma hides the KPI title
  // below ~5 grid rows, so never shrink them either.
  for (let i = 0; i < content.length; i++) {
    const e = content[i];
    if (e.kind === 'kpi-chart') {
      let j = i; while (j < content.length && content[j].kind === 'kpi-chart') j++;
      const run = content.slice(i, j);
      const perRow = Math.min(run.length, 3);
      const span = Math.floor(24 / perRow);
      run.forEach((k, n) => {
        const col0 = 1 + (n % perRow) * span;
        const col1 = (n % perRow === perRow - 1) ? 25 : col0 + span;
        const r = row + Math.floor(n / perRow) * H('kpi-chart');
        lines.push(`  <Element elementId="${k.id}" gridColumn="${col0} / ${col1}" gridRow="${r} / ${r + H('kpi-chart')}"/>`);
      });
      row += Math.ceil(run.length / perRow) * H('kpi-chart');
      i = j - 1;
      continue;
    }
    const h = H(e.kind);
    lines.push(`  <Element elementId="${e.id}" gridColumn="1 / 25" gridRow="${row} / ${row + h}"/>`);
    row += h;
  }
  return `<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="${page.id}">\n${lines.join('\n')}\n</Page>`;
}

const got = await api('GET', `/v2/workbooks/${a.workbook}/spec`);
if (!got.json) { console.error(`GET spec failed (HTTP ${got.status}): ${got.text.slice(0, 300)}`); process.exit(1); }
const spec = document(got.json);
const elements = workbookElements(got.json);
const elementsByPage = new Map((spec.pages || []).map((page) => [page.id, []]));
const unplaced = [];
for (const [element, page] of workbookElementsWithPages(got.json)) {
  if (page?.id && elementsByPage.has(page.id)) elementsByPage.get(page.id).push(element);
  else unplaced.push(element);
}
// A legacy no-layout artifact has no page ownership. Keep it recoverable by
// assigning its elements to the first metadata page before generating layout.
if (unplaced.length && spec.pages?.[0]) elementsByPage.get(spec.pages[0].id).push(...unplaced);

// Layout is one `document.layout` XML string. Pages contain metadata only;
// element ownership comes from each <Page> block.
const hintPageByName = new Map((hints?.pages || []).map((p) => [String(p.name || '').toLowerCase(), p.elements || []]));
const pageBlocks = [];
let exactPages = 0;
for (const p of spec.pages || []) {
  const pageElements = elementsByPage.get(p.id) || [];
  const hintEls = hintPageByName.get(String(p.name || '').toLowerCase());
  const xml = hintEls?.length
    ? (exactPages++, pageLayoutExact(p, pageElements, hintEls))
    : pageLayout(p, pageElements);
  if (xml) pageBlocks.push(xml);
}
if (hints) console.error(`exact-grid pages: ${exactPages}/${(spec.pages || []).length}`);
if (!pageBlocks.length || !elements.length) { console.log('no workbook elements — nothing to lay out'); process.exit(0); }
spec.layout = `<?xml version="1.0" encoding="utf-8"?>\n${pageBlocks.join('\n')}`;

// PUT replaces the entire workbook document and accepts only {document:{...}}.
const put = await api('PUT', `/v2/workbooks/${a.workbook}/spec`, wrap(spec));
if (!put.ok) { console.error(`PUT failed (HTTP ${put.status}): ${put.text.slice(0, 400)}`); process.exit(1); }

// verify the layout survived readback
const rb = await api('GET', `/v2/workbooks/${a.workbook}/spec`);
const ok = /<Element\b/.test(document(rb.json).layout || '');
console.log(JSON.stringify({ workbookId: a.workbook, pagesLaidOut: pageBlocks.length, layoutOnReadback: ok }, null, 2));
if (!ok) { console.error('FAIL: layout did not survive readback (check elementId matches)'); process.exit(1); }
console.error(`clean layout applied (${pageBlocks.length} page block(s))`);

// shared layout lint on the laid-out readback spec (same lib gate 6 runs —
// scripts/lib/layout_lint.rb, vendored byte-identical across plugins)
{
  const { writeFileSync } = await import('node:fs');
  const { dirname, join } = await import('node:path');
  const { fileURLToPath } = await import('node:url');
  const { spawnSync } = await import('node:child_process');
  const tmp = `/tmp/layout-lint-${a.workbook}.spec.json`;
  writeFileSync(tmp, JSON.stringify(rb.json, null, 2));
  const lint = spawnSync('ruby', [join(dirname(fileURLToPath(import.meta.url)), 'lib', 'layout_lint.rb'), tmp], { stdio: 'inherit' });
  if (lint.status !== 0) { console.error('FAIL: layout lint violations on the applied layout (see above) — fix and re-run.'); process.exit(1); }
}
