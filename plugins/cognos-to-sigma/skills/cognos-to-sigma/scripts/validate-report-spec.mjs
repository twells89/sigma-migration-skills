#!/usr/bin/env node
// Validate Sigma Report code via POST /v2/reports with dryRun:true. --create
// persists the validated report and checks element + column readback.
import { readFileSync, writeFileSync } from 'node:fs';
import { api, parseArgs } from './lib/sigma-rest.mjs';
import { reportSpecErrors } from './lib/report-spec.mjs';

const args = parseArgs(process.argv.slice(2));
if (!args.spec || !args.folder || !args.name) {
  console.error('usage: node scripts/validate-report-spec.mjs --spec <report.json> --folder <id> --name "<name>" [--create --out <readback.json>]');
  process.exit(2);
}
const contents = JSON.parse(readFileSync(args.spec, 'utf8'));
if (args.create === true && args.out === true) throw new Error('--out requires a readback path');
const localErrors = reportSpecErrors(contents);
if (localErrors.length) throw new Error(`Report preflight failed: ${localErrors.join('; ')}`);
if (contents.elements.some((e) => e.source?.kind === 'data-model' && (!e.source.dataModelId || !e.source.elementId || /[<>]/.test(e.source.dataModelId)))) {
  throw new Error('report needs --dm remapping and a real dataModelId before Sigma validation');
}
const payload = { name: args.name, folderId: args.folder, contents, dryRun: !args.create };
// Always dry-run first. Creating without a preceding dry-run could persist a
// report with warnings (or unsupported elements silently dropped).
const dryRun = await api('POST', '/v2/reports', { ...payload, dryRun: true });
if (!dryRun.ok || dryRun.json?.dryRun !== true || dryRun.json?.warnings?.length) {
  throw new Error(`Sigma report dry-run failed or returned warnings (HTTP ${dryRun.status}): ${dryRun.text.slice(0, 500)}`);
}
const verified = args.create ? await api('POST', '/v2/reports', payload) : dryRun;
if (!verified.ok || verified.json?.valid === false) {
  throw new Error(`Sigma report ${args.create ? 'create' : 'dry-run'} failed (HTTP ${verified.status}): ${verified.text.slice(0, 500)}`);
}
if (!args.create) {
  console.log(JSON.stringify({ valid: true, warnings: dryRun.json.warnings }, null, 2));
  process.exit(0);
}
const id = verified.json?.reportId;
if (!id) throw new Error(`create succeeded but no reportId was returned: ${verified.text.slice(0, 300)}`);
const get = await api('GET', `/v2/reports/${id}?includeContents=true`);
if (!get.ok || !get.json?.contents) throw new Error(`report ${id} created, but readback failed: HTTP ${get.status}`);
const sourceKinds = contents.elements.filter((e) => e.source?.kind).map((e) => e.kind);
const observedKinds = get.json.contents.elements.filter((e) => e.source?.kind).map((e) => e.kind);
if (sourceKinds.length !== observedKinds.length || sourceKinds.some((kind, i) => kind !== observedKinds[i])) {
  throw new Error(`report ${id} created but lost/reordered data elements on readback`);
}
const cols = await api('GET', `/v2/reports/${id}/columns`);
if (!cols.ok) throw new Error(`report ${id} created but columns readback failed (HTTP ${cols.status})`);
const broken = (cols.json?.entries || []).filter((c) =>
  String(c.type?.type || c.type || '').toLowerCase() === 'error');
if (broken.length) throw new Error(`report ${id} created but has ${broken.length} error column(s): ${broken.map((c) => c.name).join(', ')}`);
if (args.out) writeFileSync(args.out, JSON.stringify(get.json, null, 2) + '\n');
console.log(JSON.stringify({ reportId: id, url: get.json.url, dataElements: sourceKinds.length,
  columns: cols.json?.entries?.length ?? null, warnings: verified.json?.warnings || [], out: args.out || null }, null, 2));
