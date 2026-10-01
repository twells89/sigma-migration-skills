#!/usr/bin/env node
// Same subject-name → posted-DM-id remap as remap-wb-to-dm-ids.mjs, for flat
// Sigma Report `contents.elements`. A missing subject is a hard error.
import { readFileSync, writeFileSync } from 'node:fs';
import { api, elementsOf, parseArgs } from './lib/sigma-rest.mjs';

const args = parseArgs(process.argv.slice(2));
if (!args.report || !args['dm-id']) {
  console.error('usage: node scripts/remap-report-to-dm-ids.mjs --report <spec.json> --dm-id <id> [--out <spec.json>]');
  process.exit(2);
}
const spec = JSON.parse(readFileSync(args.report, 'utf8'));
if (spec.kind !== 'report' || !Array.isArray(spec.elements)) throw new Error('expected Sigma Report contents (kind: report, elements: [])');
const dm = await api('GET', `/v2/dataModels/${args['dm-id']}/elements`);
if (!dm.ok) throw new Error(`could not list DM elements: HTTP ${dm.status}`);
const byName = new Map(elementsOf(dm.json).map((e) => [e.name.toLowerCase(), e.id]));
const unresolved = [];
for (const e of spec.elements) {
  if (e.source?.kind !== 'data-model') continue;
  const match = byName.get(String(e.source.elementId || '').toLowerCase());
  if (!match) unresolved.push(`${e.name || e.id} → ${e.source.elementId}`);
  else { e.source.dataModelId = args['dm-id']; e.source.elementId = match; }
}
if (unresolved.length) throw new Error(`source subjects missing in DM ${args['dm-id']}: ${unresolved.join(', ')}`);
const out = args.out || args.report.replace(/\.json$/, '.remapped.json');
writeFileSync(out, JSON.stringify(spec, null, 2) + '\n');
console.log(JSON.stringify({ out, dataModelId: args['dm-id'], mapped: spec.elements.filter((e) => e.source?.kind === 'data-model').length }));
