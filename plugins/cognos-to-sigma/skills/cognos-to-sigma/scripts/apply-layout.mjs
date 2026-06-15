#!/usr/bin/env node
// apply-layout.mjs — give a migrated Cognos workbook a CLEAN container-banded
// dashboard grid (layout-playbook.md, verified 2026-06-10).
//
// Sigma auto-arrange stacks every element at the SAME height (KPIs as tall as
// tables, charts squished). Flat LayoutElement lists also produce dead zones /
// detached controls — so every multi-element page is grouped into full-width
// BAND CONTAINERS:
//   1. header band — dark, full-width, page/workbook title text
//   2. control band — controls side-by-side (global filters)
//   3. KPI band(s) — runs of kpi-charts as rows of up to 3 TALL tiles (Sigma
//      hides the KPI title below ~5 grid rows)
//   4. chart rows — consecutive charts paired 2-across, even heights
//   5. tables / maps / pivots — full-width band each
// Spec side each band needs a `kind: container` placeholder element; layout
// side a <GridContainer> (NOT <LayoutElement type="grid">, which silently
// drops children) whose child <LayoutElement>s use CONTAINER-RELATIVE
// coordinates (rows restart at 1). Layout elementIds must match the POSTED
// (reassigned) ids, so this GETs the readback spec first.
//
// Usage:
//   eval "$(scripts/get-token.sh)"
//   node scripts/apply-layout.mjs --workbook <workbookId>
//
// Idempotent (band elements are re-derived each run). Run it as the last step
// of the build/verify phase.
import { api, parseArgs } from './lib/sigma-rest.mjs';
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const a = parseArgs(process.argv.slice(2));
if (!a.workbook) { console.error('need --workbook <workbookId>'); process.exit(2); }

const HEADER_STYLE = { backgroundColor: '#0F172A', borderRadius: 'round' };
const HDR_H = 3;   // header band height (grid rows)
const CTRL_H = 3;  // control band height
const KPI_H = 6;   // KPI tile height — >= 5 so the title renders
const CHART_H = 11; // paired chart row height
// full-width per-kind heights for non-chart content
const H = (k) => (k.endsWith('-map') || k === 'pivot-table' || k === 'table') ? 12
  : k === 'text' ? 3 : 11;

const le = (id, c0, c1, r0, r1) =>
  `  <LayoutElement elementId="${id}" gridColumn="${c0} / ${c1}" gridRow="${r0} / ${r1}"/>`;
const gcXml = (id, r0, r1, inner) =>
  `<GridContainer elementId="${id}" type="grid" gridColumn="1 / 25" gridRow="${r0} / ${r1}" ` +
  `gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">\n${inner}\n</GridContainer>`;

const isChart = (k) => k.endsWith('-chart') && k !== 'kpi-chart';

function pageLayout(page, fallbackTitle) {
  // strip band elements injected by a previous run (idempotency)
  page.elements = (page.elements || []).filter((e) =>
    !(String(e.id || '').startsWith('band-') && (e.kind === 'container' || e.kind === 'text')));
  const els = page.elements.filter((e) => e.id);
  if (!els.length) return null;
  const pfx = `band-${page.id}`;
  const bandEls = [];   // container/header spec elements to inject
  const bands = [];     // page-level GridContainer XML blocks
  let row = 1;

  // (1) header band
  const title = page.name || fallbackTitle || 'Dashboard';
  bandEls.push({ id: `${pfx}-hdr`, kind: 'container', style: { ...HEADER_STYLE } });
  bandEls.push({ id: `${pfx}-hdrtext`, kind: 'text',
                 body: `# <span style="color: #FFFFFF">${title}</span>` });
  bands.push(gcXml(`${pfx}-hdr`, row, row + HDR_H, le(`${pfx}-hdrtext`, 1, 25, 1, 1 + HDR_H)));
  row += HDR_H;

  // (2) control band: up to 4 across per row, one container for all of them
  const controls = els.filter((e) => e.kind === 'control');
  const content = els.filter((e) => e.kind !== 'control');
  if (controls.length) {
    const lines = [];
    const perRow = Math.min(controls.length, 4);
    const span = Math.floor(24 / perRow);
    controls.forEach((c, i) => {
      const col0 = 1 + (i % perRow) * span;
      const col1 = (i % perRow === perRow - 1) ? 25 : col0 + span;
      const r = 1 + Math.floor(i / perRow) * CTRL_H;
      lines.push(le(c.id, col0, col1, r, r + CTRL_H));
    });
    const h = Math.ceil(controls.length / perRow) * CTRL_H;
    bandEls.push({ id: `${pfx}-ctl`, kind: 'container' });
    bands.push(gcXml(`${pfx}-ctl`, row, row + h, lines.join('\n')));
    row += h;
  }

  // (3..5) content bands
  let bandN = 0;
  const pushBand = (h, lines) => {
    bandN += 1;
    const cid = `${pfx}-${bandN}`;
    bandEls.push({ id: cid, kind: 'container' });
    bands.push(gcXml(cid, row, row + h, lines.join('\n')));
    row += h;
  };
  for (let i = 0; i < content.length; i++) {
    const e = content[i];
    if (e.kind === 'kpi-chart') {
      // KPI panel: the whole run in ONE band container, rows of up to 3 TALL tiles
      let j = i; while (j < content.length && content[j].kind === 'kpi-chart') j++;
      const run = content.slice(i, j);
      const perRow = Math.min(run.length, 3);
      const span = Math.floor(24 / perRow);
      const lines = run.map((k, n) => {
        const col0 = 1 + (n % perRow) * span;
        const col1 = (n % perRow === perRow - 1) ? 25 : col0 + span;
        const r = 1 + Math.floor(n / perRow) * KPI_H;
        return le(k.id, col0, col1, r, r + KPI_H);
      });
      pushBand(Math.ceil(run.length / perRow) * KPI_H, lines);
      i = j - 1;
      continue;
    }
    if (isChart(e.kind) && i + 1 < content.length && isChart(content[i + 1].kind)) {
      // chart row: two charts side-by-side, even heights (the 2x2 grid pattern)
      pushBand(CHART_H, [le(e.id, 1, 13, 1, 1 + CHART_H),
                         le(content[i + 1].id, 13, 25, 1, 1 + CHART_H)]);
      i += 1;
      continue;
    }
    // lone chart / table / map / pivot / text: full-width band
    const h = isChart(e.kind) ? CHART_H : H(e.kind);
    pushBand(h, [le(e.id, 1, 25, 1, 1 + h)]);
  }

  page.elements = page.elements.concat(bandEls);
  return `<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="${page.id}">\n${bands.join('\n')}\n</Page>`;
}

const got = await api('GET', `/v2/workbooks/${a.workbook}/spec`);
if (!got.json) { console.error(`GET spec failed (HTTP ${got.status}): ${got.text.slice(0, 300)}`); process.exit(1); }
const spec = got.json;
// The layout is a SINGLE top-level `spec.layout` XML holding one <Page> block per page
// (NOT pages[].layout — that's silently dropped). Strip read-only fields before the PUT.
const pageBlocks = [];
for (const p of spec.pages || []) {
  delete p.layout;
  if ((p.name || '') === 'Data') continue; // hidden master page — auto-arrange is fine
  const xml = pageLayout(p, spec.name);
  if (xml) pageBlocks.push(xml);
}
if (!pageBlocks.length) { console.log('no layoutable pages — nothing to lay out'); process.exit(0); }
spec.layout = `<?xml version="1.0" encoding="utf-8"?>\n${pageBlocks.join('\n')}`;
for (const k of ['workbookId', 'url', 'ownerId', 'createdBy', 'updatedBy', 'createdAt', 'updatedAt', 'latestDocumentVersion', 'documentVersion']) delete spec[k];
if (a.folder && !spec.folderId) spec.folderId = a.folder;

const put = await api('PUT', `/v2/workbooks/${a.workbook}/spec`, spec);
if (!put.ok) { console.error(`PUT failed (HTTP ${put.status}): ${put.text.slice(0, 400)}`); process.exit(1); }

// verify the layout (containers included) survived readback
const rb = await api('GET', `/v2/workbooks/${a.workbook}/spec`);
const rbLayout = rb.json?.layout || '';
const ok = /<LayoutElement/.test(rbLayout) && /<GridContainer/.test(rbLayout);
console.log(JSON.stringify({ workbookId: a.workbook, pagesLaidOut: pageBlocks.length, layoutOnReadback: ok }, null, 2));
if (!ok) { console.error('FAIL: container layout did not survive readback (check elementId matches — a GridContainer with an unknown elementId is silently dropped)'); process.exit(1); }

// Layout-quality lint (gate) — shared scripts/lib/layout_lint.rb, vendored
// byte-identical across the migration plugins. Runs on the final readback spec:
// raw-id element display names, controls orphaned outside containers on a banded
// page, and generic Sigma auto-page titles in the header band. The Ruby lint is
// reused as-is (cognos already shells out to ruby for find-or-pick-dm.rb).
// --skip-layout-lint bypasses.
if (!a['skip-layout-lint'] && rb.json) {
  const tmp = join(tmpdir(), `cognos-layout-lint-${a.workbook}.json`);
  writeFileSync(tmp, JSON.stringify(rb.json));
  const lint = spawnSync('ruby', [join(HERE, 'lib', 'layout_lint.rb'), tmp], { encoding: 'utf8' });
  if (lint.stdout) process.stderr.write(lint.stdout);
  if (lint.stderr) process.stderr.write(lint.stderr);
  if (lint.status !== 0) {
    console.error('FAIL: layout-lint violations (gate) — fix the layout or re-run with --skip-layout-lint');
    process.exit(4);
  }
  console.error('layout lint: clean');
}
console.error(`container-banded layout applied (${pageBlocks.length} page block(s))`);

// Visual-QA gate — render each CONTENT page to a FULL-PAGE PNG so the layout can
// be reviewed against refs/layout-visual-qa.md (matching qlik/tableau Phase 5b).
// NON-FATAL: a transient export failure must not sink a green migration — the
// REVIEW is the gate. Page ids come from the post-PUT readback spec (rb.json) we
// already hold: those are the AUTHORITATIVE posted ids (the Cognos POST reassigns
// page/element ids, so the local pre-POST spec would carry stale ids — and this
// readback is the same JSON the layout gate above already depends on, not the
// flaky-YAML /spec case). The Sigma token is passed explicitly to the python
// child via env (inherited SIGMA_API_TOKEN; same one the api() helper uses).
// --skip-visual-qa bypasses.
if (!a['skip-visual-qa'] && rb.json) {
  const contentPages = (rb.json.pages || []).filter((p) => {
    const tag = `${p.id || ''} ${p.name || ''}`.toLowerCase();
    return p.id && !tag.includes('data');
  });
  const vqaDir = join(tmpdir(), `cognos-visual-qa-${a.workbook}`);
  mkdirSync(vqaDir, { recursive: true });
  const tok = process.env.SIGMA_API_TOKEN || '';
  let rendered = 0;
  for (const p of contentPages) {
    const out = join(vqaDir, `${p.id}.png`);
    const png = spawnSync('python3',
      [join(HERE, 'sigma-export-png.py'), '--workbook', a.workbook, '--page', p.id,
        '--out', out, '--w', '1800', '--h', '1000'],
      { encoding: 'utf8', env: { ...process.env, SIGMA_API_TOKEN: tok } });
    if (png.status === 0) { rendered++; }
    else { console.error(`   [warn] visual-QA render failed for page ${p.id} (exit ${png.status})${png.stderr ? `: ${png.stderr.trim().slice(0, 200)}` : ''}`); }
  }
  console.error(`visual QA: rendered ${rendered}/${contentPages.length} full-page PNG(s) → ${vqaDir}`);
  if (rendered > 0) {
    console.error('VISUAL QA (mandatory review — do not skip): open each PNG and check vs');
    console.error('refs/layout-visual-qa.md — populated controls, titles present, right chart');
    console.error('kinds, sensible colors/heights, no overlaps/dead zones.');
  }
}
