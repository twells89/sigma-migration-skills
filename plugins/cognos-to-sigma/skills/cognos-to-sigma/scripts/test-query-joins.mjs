#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const cli = fileURLToPath(new URL('../converter/cli.mjs', import.meta.url));
const work = mkdtempSync(join(tmpdir(), 'cognos-joins-'));
const input = join(work, 'report.xml');
const joinPath = (name) => join(work, name);
const item = (name, expr) => `<dataItem name="${name}" aggregate="none"><expression>${expr}</expression></dataItem>`;
const source = (name, subject, predicate) => `<query name="${name}"><source><model/></source><selection>
  ${['Key', 'Site', 'Value', 'Enabled'].map(col => item(col, `[C].[M].[${subject}].[${col}]`)).join('')}
  </selection><detailFilters><detailFilter><filterExpression>${predicate}</filterExpression></detailFilter></detailFilters></query>`;
const left = source('left', 'Orders', '[Enabled] = 1');
const right = source('right', 'Lines', '[Enabled] = 1');
const condition = '[left].[Key] = [right].[Key] and [right].[Site] = [left].[Site]';
const joined = (type) => `<query name="joined"><source><joinOperation ${type ? `joinType="${type}"` : ''}>
  <joinOperands><joinOperand cardinality="1:N"><queryRef refQuery="left"/></joinOperand><joinOperand cardinality="1:N"><queryRef refQuery="right"/></joinOperand></joinOperands>
  <joinFilter><filterExpression>${condition}</filterExpression></joinFilter></joinOperation></source><selection>
  ${item('Left Value', '[left].[Value]')}${item('Right Value', '[right].[Value]')}
  </selection></query>`;
const report = (type = '', queries) => `<report><queries>${queries || joined(type) + right + left}</queries><layouts><layout><reportPages><page name="Output"><pageBody><contents>
  <list refQuery="joined"><listColumns><listColumn><listColumnBody><dataItemValue refDataItem="Left Value"/></listColumnBody></listColumn><listColumn><listColumnBody><dataItemValue refDataItem="Right Value"/></listColumnBody></listColumn></listColumns></list>
  </contents></pageBody></page></reportPages></layout></layouts></report>`;
const run = (xml, print = false) => {
  writeFileSync(input, xml);
  return spawnSync(process.execPath, [cli, input, ...(print ? ['--print'] : [])], { encoding: 'utf8', timeout: 10000 });
};
const rows = {
  Orders: [
    { Key: 1, Site: 'A', Value: 10, Enabled: 1 }, { Key: 1, Site: 'A', Value: 11, Enabled: 1 },
    { Key: 2, Site: 'B', Value: 20, Enabled: 1 }, { Key: null, Site: 'A', Value: 30, Enabled: 1 },
    { Key: 3, Site: 'A', Value: 40, Enabled: 0 },
  ],
  Lines: [
    { Key: 1, Site: 'A', Value: 100, Enabled: 1 }, { Key: 1, Site: 'A', Value: 101, Enabled: 1 },
    { Key: 1, Site: 'B', Value: 102, Enabled: 1 }, { Key: 2, Site: 'B', Value: 200, Enabled: 0 },
    { Key: null, Site: 'A', Value: 300, Enabled: 1 },
  ],
};
const materialize = (element) => {
  const get = (row, formula) => row[Object.keys(row).find(k => k.toLowerCase() === formula.match(/\/([^/]+)\]$/)[1].toLowerCase())];
  return rows[element.source.elementId].filter(row => (element.filters || []).every(f => f.values.includes(get(row, element.columns.find(c => c.id === f.columnId).formula))))
    .map(row => Object.fromEntries(element.columns.map(c => [c.name, get(row, c.formula)])));
};
let failed = 0;
const check = (label, fn) => { try { fn(); console.log(`PASS ${label}`); } catch (e) { failed++; console.error(`FAIL ${label}: ${e.message}`); } };
try {
  for (const [type, sigmaType, expected] of [
    ['', 'inner', [[10, 100], [10, 101], [11, 100], [11, 101]]],
    ['leftOuter', 'left-outer', [[10, 100], [10, 101], [11, 100], [11, 101], [20, null], [30, null]]],
  ]) {
    check(`${sigmaType} join preserves composite keys, duplicates, nulls and input filters`, () => {
      const result = run(report(type));
      assert.equal(result.status, 0, result.stderr);
      const doc = JSON.parse(result.stdout).document;
      const table = doc.elements.find(e => e.source?.kind === 'join');
      assert.ok(table, 'join must be emitted, not a guessed model table');
      const join = table.source.joins[0];
      assert.equal(join.joinType, sigmaType);
      assert.deepEqual(join.columns, [{ left: '[Key]', right: '[Key]' }, { left: '[Site]', right: '[Site]' }]);
      const l = doc.elements.find(e => e.id === join.left.elementId), r = doc.elements.find(e => e.id === join.right.elementId);
      assert.equal(l.source.elementId, 'Orders'); assert.equal(r.source.elementId, 'Lines');
      assert.equal(l.filters.length, 1); assert.equal(r.filters.length, 1);
      const hidden = doc.pages.find(p => p.visibility === 'hidden');
      assert.ok(hidden);
      const hiddenLayout = doc.layout.match(new RegExp(`<Page[^>]+id="${hidden.id}"[^>]*>([\\s\\S]*?)</Page>`))[1];
      assert.ok(hiddenLayout.includes(`elementId="${l.id}"`) && hiddenLayout.includes(`elementId="${r.id}"`));
      const actual = materialize(l).flatMap(a => {
        const matches = materialize(r).filter(b => join.columns.every(k => {
          const x = a[k.left.slice(1, -1)], y = b[k.right.slice(1, -1)];
          return x != null && y != null && x === y;
        }));
        return matches.length ? matches.map(b => [a.Value, b.Value]) : sigmaType === 'left-outer' ? [[a.Value, null]] : [];
      });
      assert.deepEqual(actual, expected);
      assert.equal(table.columns[0].formula.toLowerCase(), `[${table.source.name}/value]`.toLowerCase());
      assert.equal(table.columns[1].formula.toLowerCase(), `[${join.name}/value]`.toLowerCase());
      const wb = joinPath('workbook.json'), remapped = joinPath('remapped.json');
      writeFileSync(wb, result.stdout);
      const stub = `globalThis.fetch = async () => new Response(JSON.stringify({entries:[{elementId:'orders-id',name:'Orders'},{elementId:'lines-id',name:'Lines'}]}));`;
      const mapped = spawnSync(process.execPath, ['--import', `data:text/javascript,${encodeURIComponent(stub)}`,
        fileURLToPath(new URL('./remap-wb-to-dm-ids.mjs', import.meta.url)), '--wb', wb, '--dm-id', 'model', '--out', remapped], {
        encoding: 'utf8', env: { ...process.env, SIGMA_BASE_URL: 'https://stub.invalid', SIGMA_API_TOKEN: 'test-token' },
      });
      assert.equal(mapped.status, 0, mapped.stderr);
      const remappedDoc = JSON.parse(readFileSync(remapped, 'utf8')).document;
      assert.deepEqual(remappedDoc.elements.find(e => e.id === table.id).source, table.source);
      assert.equal(remappedDoc.elements.find(e => e.id === l.id).source.elementId, 'orders-id');
      assert.equal(remappedDoc.elements.find(e => e.id === r.id).source.elementId, 'lines-id');
      const printed = run(report(type), true);
      assert.equal(printed.status, 1); assert.equal(printed.stdout, '');
      assert.match(printed.stderr, /hidden visual source table/);
    });
  }
  for (const [label, xml] of [
    ['non-equi', report().replace(condition, condition.replace(' = ', ' &gt; '))],
    ['OR join', report().replace(condition, condition.replace(' and ', ' or '))],
    ['missing key', report().replace(condition, condition.replace('[left].[Key]', '[left].[Absent]'))],
    ['unsupported join kind', report('lookup')],
    ['filtered joined result', report('', joined('').replace('</selection>', '</selection><detailFilters><detailFilter><filterExpression>[Left Value] = 10</filterExpression></detailFilter></detailFilters>') + left + right)],
    ['aggregate operand', report().replace('name="Value" aggregate="none"', 'name="Value" aggregate="total"')],
    ['optional operand filter', report().replace('<detailFilter>', '<detailFilter use="optional">')],
    ['optional cardinality', report().replace('cardinality="1:N"', 'cardinality="0:N"')],
    ['computed output', report().replace('[left].[Value]', '[left].[Value] + 1')],
  ]) {
    check(`unsafe join stays unbound: ${label}`, () => {
      const result = run(xml); assert.equal(result.status, 0, result.stderr);
      const doc = JSON.parse(result.stdout).document;
      assert.ok(!doc.elements.some(e => e.source?.kind === 'join'));
      assert.equal(doc.elements.find(e => e.kind === 'table').source.elementId, '<element>');
      assert.match(result.stderr, /query dependency/);
    });
  }
} finally { rmSync(work, { recursive: true, force: true }); }
assert.equal(failed, 0, `${failed} join regressions failed`);
