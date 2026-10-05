#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const work = mkdtempSync(join(tmpdir(), 'cognos-remap-'));
const script = fileURLToPath(new URL('./remap-wb-to-dm-ids.mjs', import.meta.url));
const stub = `globalThis.fetch = async (url, init) => {
  if (init.method !== 'GET' || !String(url).endsWith('/v2/dataModels/model/elements')) throw new Error('unexpected request');
  return new Response(JSON.stringify({entries:JSON.parse(process.env.TEST_ELEMENTS)}));
};`;
const input = join(work, 'input.json'), output = join(work, 'output.json');
try {
  // Exercise the shipped converter through the remap gate, not just a hand-built spec.
  const report = join(work, 'report.xml');
  writeFileSync(report, `<report><queries><query name="q"><source><queryRef refQuery="upstream"/></source><selection>
    <dataItem name="Region"><expression>[C].[M].[Sales].[Region]</expression></dataItem>
    </selection></query></queries><layouts><layout><reportPages><page name="Records"><pageBody><contents>
    <list refQuery="q"><listColumns><listColumn><listColumnBody><dataItemValue refDataItem="Region"/></listColumnBody></listColumn></listColumns></list>
    </contents></pageBody></page></reportPages></layout></layouts></report>`);
  const cli = fileURLToPath(new URL('../converter/cli.mjs', import.meta.url));
  const converted = spawnSync(process.execPath, [cli, report], { encoding: 'utf8' });
  assert.equal(converted.status, 0, converted.stderr);
  assert.match(converted.stderr, /query dependency/);
  const generated = JSON.parse(converted.stdout);
  assert.equal(generated.document.elements[0].source.elementId, '<element>');
  const printed = spawnSync(process.execPath, [cli, report, '--print'], { encoding: 'utf8' });
  assert.equal(printed.status, 1);
  assert.equal(printed.stdout, '');
  assert.match(printed.stderr, /unresolved query dependency/);
  for (const [binding, duplicate, valid] of [
    ['Sales', false, true], ['sales', false, true], ['real-sales', false, true],
    ['<element>', false, false], ['Missing', false, false], ['Sales', true, false],
  ]) {
    const spec = binding === '<element>' ? generated : { name: 'Synthetic report', document: { schemaVersion: 1, kind: 'workbook',
      pages: [{ id: 'page', name: 'Records' }],
      elements: [
        { id: 'base', kind: 'table', source: { kind: 'data-model', dataModelId: '<DM_ID>', elementId: binding } },
        { id: 'child', kind: 'table', source: { kind: 'table', elementId: 'base' } },
      ],
      layout: '<Page id="page"><Element elementId="base"/><Element elementId="child"/></Page>',
    } };
    writeFileSync(input, JSON.stringify(spec));
    writeFileSync(output, 'prior output');
    const result = spawnSync(process.execPath, ['--import', `data:text/javascript,${encodeURIComponent(stub)}`,
      script, '--wb', input, '--dm-id', 'model', '--out', output], {
      encoding: 'utf8', env: { ...process.env, SIGMA_BASE_URL: 'https://stub.invalid', SIGMA_API_TOKEN: 'test-token',
        TEST_ELEMENTS: JSON.stringify([{ elementId: 'real-sales', name: 'Sales' },
          ...(duplicate ? [{ elementId: 'other-sales', name: 'Sales' }] : [])]),
      },
    });
    if (valid) {
      assert.equal(result.status, 0, result.stderr);
      const [base, child] = JSON.parse(readFileSync(output, 'utf8')).document.elements;
      assert.deepEqual(base.source, { kind: 'data-model', dataModelId: 'model', elementId: 'real-sales' });
      assert.deepEqual(child.source, { kind: 'table', elementId: 'base' }, 'internal dependency must not become a data-model source');
    } else {
      assert.equal(result.status, 1, 'unresolved or ambiguous model bindings must fail');
      assert.match(result.stderr, /unresolved/);
      assert.equal(readFileSync(output, 'utf8'), 'prior output', 'failed remap must not overwrite prior output');
    }
  }
  console.log('test-remap-wb-to-dm-ids: PASS');
} finally {
  rmSync(work, { recursive: true, force: true });
}
