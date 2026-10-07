#!/usr/bin/env node
// post-and-readback.mjs — POST a Cognos-converted DM or workbook spec, then read it
// back and FAIL LOUDLY on any error-typed column (a spec can POST 200 yet have
// formulas that don't resolve at query time — those surface as type "error").
//
// Usage:
//   eval "$(scripts/get-token.sh)"
//   node scripts/post-and-readback.mjs --type datamodel|workbook --spec spec.json --folder <folderId> [--name N] [--out map.json]
//
// Prints { dataModelId|workbookId, errors:[...] } and exits non-zero if any error columns.
import { readFileSync, writeFileSync } from 'node:fs';
import { api, extractId, parseArgs, elementsOf } from './lib/sigma-rest.mjs';
import * as CodeRep from './lib/code_rep.mjs';
import { assertWorkbookContract } from './lib/workbook_contract.mjs';
import { groundWarehouseRefs } from './lib/warehouse-column-refs.mjs';

const a = parseArgs(process.argv.slice(2));
if (!a.type || !a.spec || !a.folder) { console.error('need --type datamodel|workbook --spec <spec.json> --folder <folderId>'); process.exit(2); }
const idField = a.type === 'datamodel' ? 'dataModelId' : 'workbookId';
const postPath = a.type === 'datamodel' ? '/v2/dataModels/spec' : '/v2/workbooks/spec';
const colsPath = (id) => a.type === 'datamodel' ? `/v2/dataModels/${id}/columns` : `/v2/workbooks/${id}/columns`;

const spec = JSON.parse(readFileSync(a.spec, 'utf8'));
if (a.type === 'datamodel') {
  const grounding = await groundWarehouseRefs(spec, api, { preserveElementNames: a['preserve-subject-names'] === true });
  const modes = Object.entries(grounding.connectionModes)
    .map(([id, friendly]) => `${id}=${friendly ? 'friendly' : 'physical'}`).join(', ');
  console.error(`connection naming: ${modes}; grounded ${grounding.rewritten} formula(s), ` +
    `re-keyed ${grounding.rekeyed} id(s), re-prefixed ${grounding.reprefixed} ref(s)`);
}
// name AFTER the spread — `{name, ...spec}` let spec.name silently override --name (beads-sigma-unff).
const name = a.name || spec.name || `cognos ${a.type} ${Date.now()}`;
// Workbook code-rep nests non-metadata fields under `document` (verified live
// 2026-08-03/04) and REJECTS the old flat body with HTTP 400. The datamodel
// surface is confirmed NOT changing — it ignores `document` — so only the
// workbook branch wraps; the datamodel body construction below is untouched
// (still `{folderId, ...spec, name}`, name last so it can't be silently
// overridden by a spec.name).
let workbookDoc;
if (a.type === 'workbook') {
  try { workbookDoc = assertWorkbookContract(spec, { requireWrapper: true }); }
  catch (error) { console.error(`REFUSE POST: ${error.message}`); process.exit(1); }
}
const body = a.type === 'workbook'
  ? CodeRep.wrap(workbookDoc, { folderId: a.folder, ...CodeRep.metadata(spec), name })
  : { folderId: a.folder, ...spec, name };
const post = await api('POST', postPath, body);
const id = extractId(post, idField);
if (!id) { console.error(`POST failed (HTTP ${post.status}): ${post.text.slice(0, 500)}`); process.exit(1); }
console.error(`POST ok → ${idField}=${id}`);

// Silent-error guard: scan resolved column types; type "error" = formula didn't resolve.
const cols = await api('GET', colsPath(id));
const errors = [];
const list = cols.json?.entries || cols.json?.columns || (Array.isArray(cols.json) ? cols.json : []);
for (const c of (Array.isArray(list) ? list : [])) {
  const t = c.type?.type || c.columnType || c.type;
  if (String(t).toLowerCase() === 'error') errors.push(c.name || c.columnName || c.columnId);
}
const elements = elementsOf((await api('GET', a.type === 'datamodel' ? `/v2/dataModels/${id}/elements` : `/v2/workbooks/${id}/elements`)).json);
let layoutOnReadback;
if (a.type === 'workbook') {
  const readback = await api('GET', `/v2/workbooks/${id}/spec`);
  if (!readback.ok || !readback.json) {
    console.error(`FAIL: workbook spec readback failed (HTTP ${readback.status}): ${readback.text.slice(0, 500)}`);
    process.exit(1);
  }
  try {
    assertWorkbookContract(readback.json, { requireWrapper: true });
    layoutOnReadback = true;
  } catch (error) {
    console.error(`FAIL: posted workbook did not survive the code/layout readback gate: ${error.message}`);
    process.exit(1);
  }
}
const result = { [idField]: id, elements, errors, ...(a.type === 'workbook' ? { layoutOnReadback } : {}) };
if (a.out) writeFileSync(a.out, JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 2));
if (errors.length) { console.error(`FAIL: ${errors.length} error-typed column(s): ${errors.join(', ')}`); process.exit(1); }
console.error(`readback clean: ${elements.length} element(s), 0 error columns`);
