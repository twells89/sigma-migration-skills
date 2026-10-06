#!/usr/bin/env node
// apply-layout.mjs — authoritative-layout readback gate for Cognos workbooks.
//
// The converter now authors document.layout together with metadata-only pages
// and flat document.elements. Page membership exists only in that layout, so
// synthesizing a replacement after POST would destroy source page/panel/tab/
// repeater intent. This command GETs the posted spec and fails unless the
// authored layout survived exactly as a complete, authoritative membership map.
//
// Usage:
//   eval "$(scripts/get-token.sh)"
//   node scripts/apply-layout.mjs --workbook <workbookId>
//
// Run it as the last step of the build/verify phase.
import { api, parseArgs } from './lib/sigma-rest.mjs';
import { assertWorkbookContract } from './lib/workbook_contract.mjs';
import { pythonArgv } from './lib/py_resolve.mjs';
import { spawnSync } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const a = parseArgs(process.argv.slice(2));
if (!a.workbook) { console.error('need --workbook <workbookId>'); process.exit(2); }

const got = await api('GET', `/v2/workbooks/${a.workbook}/spec`);
if (!got.json) { console.error(`GET spec failed (HTTP ${got.status}): ${got.text.slice(0, 300)}`); process.exit(1); }
let rbSpec;
try { rbSpec = assertWorkbookContract(got.json, { requireWrapper: true }); }
catch (error) { console.error(`FAIL: authoritative layout readback gate: ${error.message}`); process.exit(1); }
const rb = got;
const pageBlocks = rbSpec.pages || [];
console.log(JSON.stringify({
  workbookId: a.workbook,
  pagesLaidOut: pageBlocks.length,
  elementsLaidOut: (rbSpec.elements || []).length,
  layoutOnReadback: true,
}, null, 2));

// Layout-quality lint (gate) — shared scripts/lib/layout_lint.rb, vendored
// byte-identical across the migration plugins. Runs on the final readback spec:
// raw-id element display names, controls orphaned outside containers on a banded
// page, and generic Sigma auto-page titles in the header band. The Ruby lint is
// reused as-is (cognos already shells out to ruby for find-or-pick-dm.rb).
// --skip-layout-lint bypasses.
if (!a['skip-layout-lint'] && rb.json) {
  const tmp = join(tmpdir(), `cognos-layout-lint-${a.workbook}.json`);
  writeFileSync(tmp, JSON.stringify(rbSpec));
  const lint = spawnSync('ruby', [join(HERE, 'lib', 'layout_lint.rb'), tmp], { encoding: 'utf8' });
  if (lint.stdout) process.stderr.write(lint.stdout);
  if (lint.stderr) process.stderr.write(lint.stderr);
  if (lint.status !== 0) {
    console.error('FAIL: layout-lint violations (gate) — fix the layout or re-run with --skip-layout-lint');
    process.exit(4);
  }
  console.error('layout lint: clean');
}
console.error(`authoritative layout verified (${pageBlocks.length} page block(s))`);

// Visual-QA gate — render each CONTENT page to a FULL-PAGE PNG so the layout can
// be reviewed against refs/layout-visual-qa.md (matching qlik/tableau Phase 5b).
// NON-FATAL: a transient export failure must not sink a green migration — the
// REVIEW is the gate. Page ids come from the authoritative GET readback we
// already hold. The Python exporter inherits the browser-first provider state
// and independently handles token age plus one 401 refresh/retry.
// --skip-visual-qa bypasses.
if (!a['skip-visual-qa'] && rb.json) {
  const contentPages = (rbSpec.pages || []).filter((p) => {
    const tag = `${p.id || ''} ${p.name || ''}`.toLowerCase();
    return p.id && !tag.includes('data');
  });
  const vqaDir = join(tmpdir(), `cognos-visual-qa-${a.workbook}`);
  mkdirSync(vqaDir, { recursive: true });
  const PY = pythonArgv();
  let rendered = 0;
  for (const p of contentPages) {
    const out = join(vqaDir, `${p.id}.png`);
    const png = spawnSync(PY[0],
      [...PY.slice(1), join(HERE, 'sigma-export-png.py'), '--workbook', a.workbook, '--page', p.id,
        '--out', out, '--w', '1800', '--h', '1000'],
      { encoding: 'utf8' });
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
