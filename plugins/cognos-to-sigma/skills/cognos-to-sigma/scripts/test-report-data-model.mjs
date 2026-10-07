#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { buildReportDataModel } from './lib/report-data-model.mjs';
import { groundWarehouseRefs } from './lib/warehouse-column-refs.mjs';

const work = mkdtempSync(join(tmpdir(), 'cognos-report-model-'));
const report = join(work, 'report.xml'), inventoryPath = join(work, 'sources.json'), output = join(work, 'dm.json');
const runner = fileURLToPath(new URL('./build-dm-from-report.mjs', import.meta.url));
const xml = `<report><queries><query name="q"><selection>
  <dataItem name="Region"><expression>[Business].[Orders].[Region]</expression></dataItem>
  <dataItem name="Value"><expression>[C].[Business].[Orders].[Revenue]</expression></dataItem>
  <dataItem name="Literal"><expression>'[Ignore].[Fake].[Column]'</expression></dataItem>
  </selection><detailFilters><detailFilter use="prohibited"><filterExpression>[Ignore].[Disabled].[Secret] = 1</filterExpression></detailFilter></detailFilters>
  </query></queries></report>`;
try {
  writeFileSync(report, xml.replace('[C].[Business]', '[Business]'));
  const initial = spawnSync(process.execPath, [runner, '--report', report, '--out', inventoryPath], { encoding: 'utf8' });
  assert.equal(initial.status, 10, initial.stderr);
  const template = JSON.parse(readFileSync(inventoryPath));
  assert.equal(template.subjects.length, 1);
  assert.deepEqual(template.subjects[0].columns, { Region: null, Revenue: null });
  assert.equal(template.sourceModelReviewed, false);
  assert.match(initial.stdout, /No existing Sigma model is required/);
  writeFileSync(report, xml);
  const fourPart = spawnSync(process.execPath, [runner, '--report', report, '--out', join(work, 'four-part.json')], { encoding: 'utf8' });
  assert.equal(fourPart.status, 10, fourPart.stderr);
  assert.equal(JSON.parse(readFileSync(join(work, 'four-part.json'))).subjects.length, 2, 'different full subject paths remain distinct');
  writeFileSync(report, xml.replace('[Business].[Orders].[Region]', '[Unknown].[Region]'));
  const ambiguous = spawnSync(process.execPath, [runner, '--report', report, '--out', join(work, 'ambiguous.json')], { encoding: 'utf8' });
  assert.notEqual(ambiguous.status, 0);
  assert.match(ambiguous.stderr, /ambiguous two-part/);
  assert(!existsSync(join(work, 'ambiguous.json')));
  writeFileSync(report, xml.replace('[C].[Business]', '[Business]'));
  const inventory = { subjects: [{ ref: '[Business].[Orders]', name: 'Orders', columns: [
    { name: 'Region', sigmaName: 'Region' }, { name: 'Revenue', sigmaName: 'Revenue' },
  ] }] };
  const mapping = { sourceModelReviewed: true, modelName: 'Native source model', subjects: [
    { ref: '[Business].[Orders]', path: ['DB', 'S', 'FACT_ORDERS'], columns: { Region: 'REGION_NAME', Revenue: 'NET_AMOUNT' } },
  ] };
  const calls = [];
  const api = async (method, path, body) => {
    calls.push({ method, path, body });
    if (path === '/v2/connections/connection') return { ok: true, status: 200, json: { friendlyName: false } };
    if (method === 'POST') return { ok: true, status: 200, json: { kind: 'table', inodeId: 'table' } };
    return { ok: true, status: 200, json: { entries: [{ name: 'REGION_NAME' }, { name: 'NET_AMOUNT' }] } };
  };
  const model = await buildReportDataModel(inventory, mapping, 'connection', api);
  assert.equal(model.name, 'Native source model');
  assert.equal(model.pages[0].elements[0].name, 'Orders');
  assert.deepEqual(model.pages[0].elements[0].columns.map(c => c.formula), ['[FACT_ORDERS/REGION_NAME]', '[FACT_ORDERS/NET_AMOUNT]']);
  assert.equal(calls[1].path, '/v2/connection/connection/lookup');
  const preserved = structuredClone(model);
  await groundWarehouseRefs(preserved, api, { preserveElementNames: true });
  assert.equal(preserved.pages[0].elements[0].name, 'Orders', 'physical-name connection must preserve logical report subjects');
  await assert.rejects(buildReportDataModel(inventory, { ...mapping, sourceModelReviewed: false }, 'connection', api), /sourceModelReviewed/);
  await assert.rejects(buildReportDataModel(inventory, { ...mapping, subjects: [] }, 'connection', api), /exactly one/);
  await assert.rejects(buildReportDataModel(inventory, { ...mapping, subjects: [{ ...mapping.subjects[0], columns: { Region: 'Wrong' } }] }, 'connection', api), /not found/);
  const mappingPath = join(work, 'mapping.json'); writeFileSync(mappingPath, JSON.stringify(mapping));
  const stub = `globalThis.fetch = async (url, init) => {
    const path = new URL(url).pathname;
    if (path === '/v2/connections/connection') return new Response(JSON.stringify({friendlyName:false}));
    if (path.endsWith('/lookup')) return new Response(JSON.stringify({kind:'table',inodeId:'table'}));
    if (path.includes('/connections/tables/')) return new Response(JSON.stringify({entries:[{name:'REGION_NAME'},{name:'NET_AMOUNT'}]}));
    if (path === '/v2/dataModels/spec') {
      const body = JSON.parse(init.body);
      if (body.pages[0].elements[0].name !== 'Orders' || body.folderId !== 'folder') throw new Error('invalid create body');
      return new Response(JSON.stringify({dataModelId:'created-model'}));
    }
    if (path.endsWith('/columns')) return new Response(JSON.stringify({entries: process.env.TEST_INCOMPLETE ? [] : [{elementId:'real-element',name:'Region',type:{type:'text'}},{elementId:'real-element',name:'Revenue',type:{type:'number'}}]}));
    if (path.endsWith('/elements')) return new Response(JSON.stringify({entries:[{elementId:'real-element',name:'Orders'}]}));
    throw new Error('unexpected request');
  };`;
  const result = spawnSync(process.execPath, ['--import', `data:text/javascript,${encodeURIComponent(stub)}`, runner,
    '--report', report, '--mapping', mappingPath, '--connection', 'connection', '--create', '--folder', 'folder', '--out', output], {
    encoding: 'utf8', env: { ...process.env, SIGMA_BASE_URL: 'https://aws-api.sigmacomputing.com', SIGMA_API_TOKEN: 'test-token', SIGMA_WORKDIR: work },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).dataModelId, 'created-model');
  assert.equal(JSON.parse(readFileSync(output + '.state.json')).verified, true);
  assert(existsSync(output));
  const incompleteOut = join(work, 'incomplete.json');
  const incomplete = spawnSync(process.execPath, ['--import', `data:text/javascript,${encodeURIComponent(stub)}`, runner,
    '--report', report, '--mapping', mappingPath, '--connection', 'connection', '--create', '--folder', 'folder', '--out', incompleteOut], {
    encoding: 'utf8', env: { ...process.env, SIGMA_BASE_URL: 'https://aws-api.sigmacomputing.com', SIGMA_API_TOKEN: 'test-token', SIGMA_WORKDIR: work, TEST_INCOMPLETE: '1' },
  });
  assert.notEqual(incomplete.status, 0);
  assert.match(incomplete.stderr, /readback does not match/);
  assert.equal(JSON.parse(readFileSync(incompleteOut + '.state.json')).verified, false);
  const retry = spawnSync(process.execPath, [runner, '--report', report, '--mapping', mappingPath, '--connection', 'connection', '--create', '--folder', 'folder', '--out', output], { encoding: 'utf8' });
  assert.notEqual(retry.status, 0);
  assert.match(retry.stderr, /state already exists/);
  const orchestrator = spawnSync(process.execPath, [fileURLToPath(new URL('./migrate-cognos.mjs', import.meta.url)),
    '--dm-spec', output, '--report', report, '--connection', 'connection', '--out', join(work, 'run'), '--dry-run'], { encoding: 'utf8' });
  assert.equal(orchestrator.status, 0, orchestrator.stderr);
  assert.equal(JSON.parse(readFileSync(join(work, 'run', 'dm.json'))).pages[0].elements[0].name, 'Orders');
  assert(existsSync(join(work, 'run', 'wb.json')), 'report-only model must enter the normal report pipeline');
  for (const name of ['model-one', 'model-two']) {
    const modelFile = join(work, `${name}.json`);
    writeFileSync(modelFile, JSON.stringify(model));
    const isolated = spawnSync(process.execPath, [fileURLToPath(new URL('./migrate-cognos.mjs', import.meta.url)),
      '--dm-spec', modelFile, '--report', report, '--connection', 'connection', '--dry-run'], {
      encoding: 'utf8', env: { ...process.env, HOME: work, USERPROFILE: work },
    });
    assert.equal(isolated.status, 0, isolated.stderr);
    assert(existsSync(join(work, 'cognos-migration', name, 'dm.json')), 'default run directory must derive from the DM spec');
  }
  console.log('test-report-data-model: PASS (inventory, verified mapping, create and readback without an existing model)');
} finally { rmSync(work, { recursive: true, force: true }); }
