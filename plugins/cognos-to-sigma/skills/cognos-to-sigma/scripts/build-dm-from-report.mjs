#!/usr/bin/env node
import { closeSync, existsSync, openSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { api, parseArgs, elementsOf, extractId } from './lib/sigma-rest.mjs';
import { buildReportDataModel } from './lib/report-data-model.mjs';

const args = parseArgs(process.argv.slice(2));
if (!args.report || typeof args.out !== 'string') throw new Error('need --report <report.xml> --out <private-output.json> [--mapping sources.json --connection ID --create --folder ID]');
if (args.create && (typeof args.folder !== 'string' || !args.mapping)) throw new Error('--create requires --mapping and an approved --folder');
if (args.create && (existsSync(`${args.out}.state.json`) || existsSync(`${args.out}.create-lock`))) throw new Error(`a model creation state already exists for ${args.out}; inspect/reuse that model instead of creating a duplicate`);
const result = spawnSync(process.execPath, [fileURLToPath(new URL('../converter/cli.mjs', import.meta.url)), args.report, '--source-inventory'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
if (result.status !== 0) throw new Error(`source inventory failed: ${result.stderr}`);
const inventory = JSON.parse(result.stdout);
if (!args.mapping) {
  writeFileSync(args.out, JSON.stringify({ ...inventory, sourceModelReviewed: false,
    subjects: inventory.subjects.map((s) => ({ ...s, path: null, columns: Object.fromEntries(s.columns.map((c) => [c.name, null])) })) }, null, 2) + '\n', { mode: 0o600 });
  console.log(JSON.stringify({ status: 'warehouse_mapping_required', subjects: inventory.subjects.length, out: args.out,
    next: 'Discover physical warehouse tables/columns and review source-model semantics, fill the mapping, then rerun with --mapping --connection. No existing Sigma model is required.' }));
  process.exit(10);
}
const mapping = JSON.parse(readFileSync(args.mapping, 'utf8'));
const model = await buildReportDataModel(inventory, mapping, args.connection, api);
writeFileSync(args.out, JSON.stringify(model, null, 2) + '\n', { mode: 0o600 });
if (!args.create) {
  console.log(JSON.stringify({ status: 'warehouse_verified_model_ready', out: args.out, elements: model.pages[0].elements.length }));
  process.exit(0);
}
const lockPath = `${args.out}.create-lock`;
// Reserve the output before POST; a transport error has an indeterminate result,
// so leave the lock for inspection rather than risk a second create on retry.
closeSync(openSync(lockPath, 'wx', 0o600));
const post = await api('POST', '/v2/dataModels/spec', { ...model, folderId: args.folder });
const dataModelId = post.ok && extractId(post, 'dataModelId');
if (!dataModelId) throw new Error(`data model POST failed (HTTP ${post.status})`);
// Save the created identity before any gate can fail, so retries do not proliferate models.
const state = { dataModelId, spec: args.out, verified: false };
const statePath = `${args.out}.state.json`;
writeFileSync(statePath, JSON.stringify(state, null, 2) + '\n', { mode: 0o600 });
unlinkSync(lockPath);
const columns = await api('GET', `/v2/dataModels/${dataModelId}/columns`);
const elements = await api('GET', `/v2/dataModels/${dataModelId}/elements`);
if (!columns.ok || !elements.ok || !Array.isArray(columns.json?.entries) || !Array.isArray(elements.json?.entries) ||
    columns.json.nextPage || columns.json.nextPageToken || elements.json.nextPage || elements.json.nextPageToken) throw new Error(`model ${dataModelId} created; complete readback required before continuing (saved ${statePath})`);
if (columns.json.entries.some((c) => String(c.type?.type || c.type).toLowerCase() === 'error')) throw new Error(`model ${dataModelId} has error columns; repair before building report (saved ${statePath})`);
const observed = elementsOf(elements.json);
if (model.pages[0].elements.some((e) => {
  const matches = observed.filter((x) => x.name === e.name);
  return matches.length !== 1 || e.columns.some((column) => !columns.json.entries.some((actual) =>
    actual.elementId === matches[0].id && (actual.name || actual.label) === column.name));
})) throw new Error(`model ${dataModelId} subject/column readback does not match (saved ${statePath})`);
state.verified = true;
writeFileSync(statePath, JSON.stringify({ ...state, elements: observed }, null, 2) + '\n', { mode: 0o600 });
console.log(JSON.stringify({ ...state, statePath, next: 'Use this dataModelId with the report converter and remapper; print/layout/parity gates still apply.' }));
