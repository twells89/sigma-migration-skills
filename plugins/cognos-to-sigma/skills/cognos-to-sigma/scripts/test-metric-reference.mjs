#!/usr/bin/env node
// test-metric-reference.mjs — DM-metric references in the report→workbook converter
// (bead 7bun.7). A measure prefers a governed [Metrics/<name>] reference over
// re-deriving the aggregation inline, when its inline aggregate matches a metric on
// the referenced subject element (formula-equivalence match via the cognos-local
// binder converter/metric-binding.ts; strip the [Subject/…] prefix). migrate-cognos
// passes the posted DM's metrics (keyed by element display name) via --metrics.
//
// Runs the ACTUAL vendored bundle (converter/cli.mjs) via plain node — no tsx, no
// network, no creds — so it exercises exactly what production runs.
//
// Run: node scripts/test-metric-reference.mjs   (exit 0 = pass)
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SKILL = dirname(__dirname);
const CLI = join(SKILL, 'converter', 'cli.mjs');
const REPORT = join(SKILL, 'fixtures', 'sales-overview-charts.report.xml');

let fail = 0;
const check = (cond, msg) => { if (!cond) fail++; console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${msg}`); };

function build(metricsMap) {
  const args = [CLI, REPORT, '--dm', 'dm-x'];
  if (metricsMap) {
    const d = mkdtempSync(join(tmpdir(), 'cog-mb-'));
    const mp = join(d, 'metrics.json');
    writeFileSync(mp, JSON.stringify(metricsMap));
    args.push('--metrics', mp);
  }
  // stdout = the workbook JSON; the converter's translation warnings go to stderr
  // (ignored here to keep the test output clean).
  const out = execFileSync('node', args,
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] });
  return JSON.parse(out);
}

const formulasOf = (wb) => (wb.pages || [])
  .flatMap((p) => p.elements || [])
  .flatMap((e) => (e.columns || []).map((c) => String(c.formula)));

// 1) no --metrics → inline aggregates, no metric refs (byte-identical fallback)
{
  const f = formulasOf(build(null));
  check(f.some((x) => x === 'Sum([Sales/revenue])'), 'no --metrics: Sum([Sales/revenue]) stays inline');
  check(!f.some((x) => x.startsWith('[Metrics/')), 'no --metrics: no [Metrics/<name>] refs emitted');
}

// 2) with matching DM metrics (bare formulas) → governed [Metrics/<name>] references,
//    even for measures on a query whose subject differs from the column's subject.
{
  const METRICS = {
    Sales: [
      { name: 'Total Revenue', formula: 'Sum([revenue])' },
      { name: 'Total Gross Profit', formula: 'Sum([gross Profit])' },
    ],
  };
  const f = formulasOf(build(METRICS));
  check(f.some((x) => x === '[Metrics/Total Revenue]'), 'match: Sum([Sales/revenue]) → [Metrics/Total Revenue]');
  check(f.some((x) => x === '[Metrics/Total Gross Profit]'), 'match: Sum([Sales/gross Profit]) → [Metrics/Total Gross Profit]');
  check(!f.some((x) => x === 'Sum([Sales/revenue])'), 'match: no un-bound Sum([Sales/revenue]) remains');
  // a measure with no matching metric (quantity) stays inline — no false positive
  check(f.some((x) => x === 'Sum([Sales/quantity])'), 'non-match: Sum([Sales/quantity]) stays inline');
}

console.log(fail === 0
  ? 'ALL PASS — cognos report measures bind to [Metrics/<name>] (byte-identical fallback)'
  : `${fail} FAILURE(S)`);
process.exit(fail === 0 ? 0 : 1);
