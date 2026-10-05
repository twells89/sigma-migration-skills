#!/usr/bin/env node
// remap-wb-to-dm-ids.mjs — wire a Cognos-converted workbook spec to a freshly-posted DM.
//
// The report converter emits each element's `source.elementId` as the query's
// SUBJECT DISPLAY NAME (a placeholder), because the real Sigma element IDs don't
// exist until the DM is POSTed. After you POST the DM, run this to rewrite every
// element's `source.elementId` (and `dataModelId`) to the real IDs, matched by
// element NAME from the DM readback. (This was a manual step in every live test.)
//
// Usage:
//   eval "$(scripts/get-token.sh)"
//   node scripts/remap-wb-to-dm-ids.mjs --wb wb-spec.json --dm-id <dataModelId> [--out wb.remapped.json]
import { readFileSync, writeFileSync } from 'node:fs';
import { api, parseArgs, elementsOf } from './lib/sigma-rest.mjs';
import * as CodeRep from './lib/code_rep.mjs';
import { assertWorkbookContract } from './lib/workbook_contract.mjs';

const a = parseArgs(process.argv.slice(2));
if (!a.wb || !a['dm-id']) { console.error('need --wb <spec.json> --dm-id <dataModelId>'); process.exit(2); }
const dmId = a['dm-id'];
const wb = JSON.parse(readFileSync(a.wb, 'utf8'));
const doc = assertWorkbookContract(wb);

const els = elementsOf((await api('GET', `/v2/dataModels/${dmId}/elements`)).json);
if (!els.length) { console.error(`No elements found on data model ${dmId} (token? wrong id?)`); process.exit(1); }

let remapped = 0; const unresolved = [];
for (const e of CodeRep.workbookElements(doc)) {
  const s = e.source; if (!s || s.kind !== 'data-model') continue;
  s.dataModelId = dmId;
  const want = String(s.elementId || '').toLowerCase();
  const matches = els.filter((element) => element.name.toLowerCase() === want);
  const real = els.find((element) => element.id === s.elementId)?.id || (matches.length === 1 ? matches[0].id : undefined);
  if (real) { s.elementId = real; remapped++; } else unresolved.push(s.elementId);
}

if (unresolved.length) {
  console.error(`ERROR: ${unresolved.length} elementId(s) unresolved - no verified DM subject binding for: ${unresolved.join(', ')}`);
  process.exit(1);
}
const out = a.out || a.wb.replace(/\.json$/, '.remapped.json');
writeFileSync(out, JSON.stringify(CodeRep.wrap(doc, CodeRep.metadata(wb)), null, 2));
console.log(JSON.stringify({ dataModelId: dmId, dmElements: els.length, remapped, unresolved, out }, null, 2));
