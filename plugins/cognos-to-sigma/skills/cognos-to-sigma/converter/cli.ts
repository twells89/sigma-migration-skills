#!/usr/bin/env node
/**
 * Cognos → Sigma converter CLI.
 *   node --import tsx/esm cli.ts <data-module.json | report.xml> [opts]
 *
 * Auto-detects input:  *.json → Data Module → Sigma data model
 *                      *.xml  → report spec  → Sigma workbook
 *
 * Options: --connection <id> --database <DB> --schema <S> --dm <dataModelId> --pretty
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { convertCognosToSigma } from './cognos.js';
import { convertCognosReportToSigma } from './cognos-report.js';

// Gap-scout learned rules (validated, customer-discovered translations) live in the
// customer's home dir so a skill `git pull` never clobbers them. Applied before the
// built-in translator (see scripts/gap-scout.md).
function loadLearnedRules() {
  try {
    const p = join(homedir(), '.cognos-to-sigma', 'learned-rules.json');
    const rules = JSON.parse(readFileSync(p, 'utf8'));
    const arr = Array.isArray(rules) ? rules : (rules.rules || []);
    if (arr.length) console.error(`[learned-rules] applying ${arr.length} customer rule(s) from ${p}`);
    return arr;
  } catch { return []; }
}

const args = process.argv.slice(2);
const file = args.find((a) => !a.startsWith('--'));
const opt = (k: string, d = '') => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
if (!file) { console.error('usage: cli.ts <module.json|report.xml> [--connection X --database DB --schema S --dm ID]'); process.exit(1); }

// --metrics <file>: JSON map { "<Subject display name>": [{name, formula}, …] } of
// the posted DM's referenceable metrics, so a report measure binds to a governed
// [Metrics/<name>] ref instead of re-deriving the aggregate inline. Absent → inline.
function loadMetrics() {
  const p = opt('metrics');
  if (!p) return undefined;
  try { return JSON.parse(readFileSync(p, 'utf8')); }
  catch (e) { console.error(`[metrics] could not read ${p} (${(e as Error).message}); measures stay inline`); return undefined; }
}

const xml = readFileSync(file, 'utf8');
const isReport = file.endsWith('.xml') || xml.trimStart().startsWith('<');
const res = isReport
  ? convertCognosReportToSigma(xml, { dataModelId: opt('dm', '<DM_ID>'), metrics: loadMetrics() })
  : convertCognosToSigma(xml, { connectionId: opt('connection', '<CONNECTION_ID>'), database: opt('database'), schema: opt('schema'), learnedRules: loadLearnedRules() });

const payload = isReport ? (res as any).workbook : (res as any).model;
process.stdout.write(JSON.stringify(payload, null, 2) + '\n');
console.error(`\n[${isReport ? 'report→workbook' : 'module→data-model'}] stats: ${JSON.stringify(res.stats)}`);
// Detected security (RLS) — detect-only; the skill's apply_sigma_rls.py ports it.
const security = (res as any).security;
if (security?.length) {
  const out = opt('security-out', 'security.json');
  writeFileSync(out, JSON.stringify(security, null, 2));
  console.error(`SECURITY: ${security.length} rule(s) detected → ${out} — run scripts/apply_sigma_rls.py after posting the model (see SKILL.md "Security").`);
}
if (res.warnings.length) {
  console.error(`warnings (${res.warnings.length}) — translated where possible, flagged where not:`);
  res.warnings.forEach((w) => console.error('  ! ' + w));
}
