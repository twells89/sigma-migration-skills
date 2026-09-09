#!/usr/bin/env node
// assert-parity.mjs — the verification GATE. Two modes.
//
// PLAN: given a posted workbook (or data model) id, emit one Sigma query per
// element so the agent can pull Sigma's actuals and compare to the Metabase source.
//   node scripts/assert-parity.mjs --plan --type workbook --id <workbookId>
//   node scripts/assert-parity.mjs --plan --type datamodel --id <dataModelId>
//
// CHECK: given the agent's saved query results + an expected baseline (the numbers
// from the Metabase report / source warehouse), confirm parity within tolerance.
//   node scripts/assert-parity.mjs --check --actual actual.json --expected expected.json [--tol 0.01]
//     [--workdir DIR]            # write the gate sentinels here (default: dirname of --actual):
//                                #   parity-final.json  (gate 1 of assert-phase6-ran.rb)
//   actual.json / expected.json: { "<label>": <number>, ... }  (per-dimension or totals)
//     [--census '<json>']        # optional tile census {zones_total, charts_built,
//                                #   zones_unmatched, unmatched_zone_names:[]} — gate 5;
//                                #   derive from the converter stats (dashcards vs built)
//
// A migration is GREEN only when --check passes AND `ruby scripts/assert-phase6-ran.rb
// --workdir <dir> --workbook-id <id>` exits 0 (all 7 gates). Do not declare success
// on a 200 POST alone.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { api, parseArgs, elementsOf } from './lib/sigma-rest.mjs';

const a = parseArgs(process.argv.slice(2));

if (a.plan) {
  if (!a.id || !a.type) { console.error('need --type workbook|datamodel --id <id>'); process.exit(2); }
  const scope = a.type === 'workbook' ? 'workbook' : 'datamodel';
  const els = elementsOf((await api('GET', a.type === 'workbook' ? `/v2/workbooks/${a.id}/elements` : `/v2/dataModels/${a.id}/elements`)).json);
  console.log(`# Parity plan for ${a.type} ${a.id} — run each SQL statement through Sigma MCP or the query API, then compare to the Metabase source.\n`);
  for (const e of els) {
    console.log(`## ${e.name} (${e.kind || 'element'})  elementId=${e.id}`);
    console.log(`scope=${scope}  ${a.type === 'workbook' ? 'workbookId' : 'dataModelId'}=${a.id}`);
    console.log(`  sql: SELECT * FROM "${scope}"."${e.id}" LIMIT 50\n`);
  }
  console.log('Then save the per-element totals/dimension values to actual.json and run --check against the Metabase numbers.');
  process.exit(0);
}

if (a.check) {
  if (!a.actual || !a.expected) { console.error('need --actual <json> --expected <json>'); process.exit(2); }
  const actual = JSON.parse(readFileSync(a.actual, 'utf8'));
  const expected = JSON.parse(readFileSync(a.expected, 'utf8'));
  const tol = Number(a.tol ?? 0.01);
  const rows = []; let fail = 0;
  for (const k of Object.keys(expected)) {
    const e = Number(expected[k]), av = Number(actual[k]);
    const ok = Number.isFinite(av) && (e === 0 ? av === 0 : Math.abs(av - e) / Math.abs(e) <= tol);
    if (!ok) fail++;
    rows.push(`${ok ? 'PASS' : 'FAIL'}  ${k}: expected ${e}, got ${Number.isFinite(av) ? av : '(missing)'}`);
  }
  console.log(rows.join('\n'));
  console.log(fail ? `\n${fail}/${rows.length} FAILED — not parity-clean.` : `\nPARITY GREEN: ${rows.length}/${rows.length} within ±${tol * 100}%.`);

  // Gate sentinel: parity-final.json (gate 1 of the shared assert-phase6-ran.rb;
  // same contract every sigma-migration-skills plugin emits). mode='live' because
  // SKILL.md Phase 4 REQUIRES live re-run Metabase expecteds, never a stale baseline.
  const workdir = a.workdir || dirname(a.actual);
  const failNames = rows.filter((r) => r.startsWith('FAIL')).map((r) => r.slice(6, r.indexOf(':')));
  const final = {
    status: fail ? 'FAIL' : 'PASS', mode: 'live',
    charts_total: rows.length, charts_pass: rows.length - fail,
    fail_names: failNames, tolerance: tol, at: new Date().toISOString(),
  };
  if (a.census) {
    try { final.tile_census = JSON.parse(a.census); }
    catch { console.error('WARN: --census is not valid JSON — tile_census omitted (gate 5 will SKIP).'); }
  }
  writeFileSync(join(workdir, 'parity-final.json'), JSON.stringify(final, null, 2));
  console.error(`sentinel → ${join(workdir, 'parity-final.json')} (gate 1; now run: ruby scripts/assert-phase6-ran.rb --workdir ${workdir} --workbook-id <id>)`);
  process.exit(fail ? 1 : 0);
}

console.error('specify --plan or --check (see header).');
process.exit(2);
