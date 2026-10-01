#!/usr/bin/env node
// Validate Sigma Report code via POST /v2/reports with dryRun:true. --create
// persists the validated report and checks element + column readback.
import { readFileSync, writeFileSync } from 'node:fs';
import { api, parseArgs } from './lib/sigma-rest.mjs';
import { reportSpecErrors } from './lib/report-spec.mjs';

const args = parseArgs(process.argv.slice(2));
if (!args.spec || !args.folder || !args.name) {
  console.error('usage: node scripts/validate-report-spec.mjs --spec <report.json> --folder <id> --name "<name>" [--create | --update <reportId> --backup <before.json>] [--out <readback.json>]');
  process.exit(2);
}
const contents = JSON.parse(readFileSync(args.spec, 'utf8'));
if (args.create && args.update) throw new Error('choose either --create or --update');
if (args.update && (args.update === true || !args.backup || args.backup === true)) throw new Error('--update requires report ID and --backup <before.json>');
if ((args.create || args.update) && args.out === true) throw new Error('--out requires a readback path');
const localErrors = reportSpecErrors(contents);
if (localErrors.length) throw new Error(`Report preflight failed: ${localErrors.join('; ')}`);
if (contents.elements.some((e) => e.source?.kind === 'data-model' && (!e.source.dataModelId || !e.source.elementId || /[<>]/.test(e.source.dataModelId)))) {
  throw new Error('report needs --dm remapping and a real dataModelId before Sigma validation');
}
let before;
if (args.update) {
  const get = await api('GET', `/v2/reports/${args.update}?includeContents=true`);
  if (!get.ok || !get.json?.contents || !Number.isFinite(get.json.documentVersion)) throw new Error('update needs a complete GET with documentVersion');
  before = get.json;
  if (args.name !== before.name) throw new Error('update name differs from existing report');
  const oldSources = before.contents.elements.filter((e) => e.source?.kind === 'data-model');
  const newSources = contents.elements.filter((e) => e.source?.kind === 'data-model');
  if (oldSources.length !== newSources.length || oldSources.some((e) => !newSources.some((next) => next.id === e.id && next.source.dataModelId === e.source.dataModelId && next.source.elementId === e.source.elementId))) {
    throw new Error('update changes or removes data model bindings');
  }
  const newPageNames = new Set(contents.pages.map((page) => page.name));
  if (before.contents.pages.some((page) => !newPageNames.has(page.name))) throw new Error('update removes an existing report page');
  if (new Set(before.contents.pages.map((page) => page.name)).size !== before.contents.pages.length) throw new Error('update cannot identify duplicate page names safely');
  const oldKinds = new Map(before.contents.elements.map((e) => [e.id, e.kind]));
  if ([...oldKinds].some(([elementId, kind]) => !['text', 'image'].includes(kind) && !contents.elements.some((e) => e.id === elementId && e.kind === kind))) {
    throw new Error('update removes or changes an existing non-decorative element');
  }
  const panelRefs = new Map(before.contents.panels?.map((panel) => [panel.id, panel]) || []);
  if ([...panelRefs.values()].some((panel) => panel.type !== 'header' && panel.type !== 'footer' && !contents.panels?.some((next) => next.id === panel.id))) {
    throw new Error('update removes an unrecognized panel');
  }
  const inventory = await api('GET', `/v2/reports/${args.update}/elements?pageSize=1000`);
  if (!inventory.ok || !Array.isArray(inventory.json?.entries) || inventory.json?.nextPageToken) throw new Error('update needs a complete element inventory');
  const visible = new Set(before.contents.elements.map((e) => e.id));
  if ((inventory.json?.entries || []).some((e) => !visible.has(e.elementId))) throw new Error('GET omits an inventoried report element; refusing full replacement');
  const files = await api('GET', `/v2/files?typeFilters=report&name=${encodeURIComponent(before.name)}&limit=1000`);
  if (!files.ok || !Array.isArray(files.json?.entries) || files.json?.nextPage) throw new Error('update needs a complete report file listing');
  const file = files.json?.entries?.find((entry) => entry.id === args.update);
  if (!file || file.type !== 'report' || file.parentId !== args.folder) throw new Error('update folder does not match existing report');
}
const payload = { name: args.name, folderId: args.folder, contents, dryRun: !args.create && !args.update };
// Always dry-run first. Creating without a preceding dry-run could persist a
// report with warnings (or unsupported elements silently dropped).
const dryRun = await api('POST', '/v2/reports', { ...payload, dryRun: true });
if (!dryRun.ok || dryRun.json?.dryRun !== true || dryRun.json?.warnings?.length) {
  throw new Error(`Sigma report dry-run failed or returned warnings (HTTP ${dryRun.status}): ${dryRun.text.slice(0, 500)}`);
}
if (before) writeFileSync(args.backup, JSON.stringify(before, null, 2) + '\n', { flag: 'wx' });
const verified = args.update
  ? await api('PUT', `/v2/reports/${args.update}/contents`, { contents, documentVersion: before.documentVersion })
  : args.create ? await api('POST', '/v2/reports', payload) : dryRun;
if (!verified.ok || verified.json?.valid === false) {
  throw new Error(`Sigma report ${args.update ? 'update' : args.create ? 'create' : 'dry-run'} failed (HTTP ${verified.status}): ${verified.text.slice(0, 500)}`);
}
if (!args.create && !args.update) {
  console.log(JSON.stringify({ valid: true, warnings: dryRun.json.warnings }, null, 2));
  process.exit(0);
}
const id = args.update || verified.json?.reportId;
if (!id) throw new Error(`create succeeded but no reportId was returned: ${verified.text.slice(0, 300)}`);
const get = await api('GET', `/v2/reports/${id}?includeContents=true`);
if (!get.ok || !get.json?.contents) throw new Error(`report ${id} written, but readback failed: HTTP ${get.status}`);
const sourceElements = new Map(contents.elements.map((e) => [e.id, e.kind]));
const observedElements = new Map(get.json.contents.elements.map((e) => [e.id, e.kind]));
if (sourceElements.size !== observedElements.size || [...sourceElements].some(([key, kind]) => observedElements.get(key) !== kind)) {
  throw new Error(`report ${id} written but lost or changed elements on readback`);
}
if (before && (id !== args.update || get.json.documentVersion <= before.documentVersion)) throw new Error('report update did not advance the existing document version');
const sourceKinds = contents.elements.filter((e) => e.source?.kind && e.kind !== 'image').map((e) => e.kind);
const cols = await api('GET', `/v2/reports/${id}/columns`);
if (!cols.ok) throw new Error(`report ${id} created but columns readback failed (HTTP ${cols.status})`);
const broken = (cols.json?.entries || []).filter((c) =>
  String(c.type?.type || c.type || '').toLowerCase() === 'error');
if (broken.length) throw new Error(`report ${id} created but has ${broken.length} error column(s): ${broken.map((c) => c.name).join(', ')}`);
if (args.out) writeFileSync(args.out, JSON.stringify(get.json, null, 2) + '\n');
console.log(JSON.stringify({ reportId: id, url: get.json.url, dataElements: sourceKinds.length,
  columns: cols.json?.entries?.length ?? null, warnings: verified.json?.warnings || [], out: args.out || null }, null, 2));
