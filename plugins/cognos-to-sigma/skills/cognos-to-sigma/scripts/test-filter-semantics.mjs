#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const work = mkdtempSync(join(tmpdir(), 'cognos-filters-')), file = join(work, 'report.xml');
const cli = fileURLToPath(new URL('../converter/cli.mjs', import.meta.url));
const report = (predicate, use = '', widget = '') => `<report><queries><query name="q"><selection>
  <dataItem name="Code"><expression>[C].[M].[Sales].[Code]</expression></dataItem></selection>
  <detailFilters><detailFilter ${use ? `use="${use}"` : ''}><filterExpression>${predicate}</filterExpression></detailFilter></detailFilters></query></queries>
  <layouts><layout><reportPages><page name="Output"><pageBody><contents>${widget}<list refQuery="q"><listColumns>
  <listColumn><listColumnBody><dataItemValue refDataItem="Code"/></listColumnBody></listColumn></listColumns></list>
  </contents></pageBody></page></reportPages></layout></layouts></report>`;
const run = (xml, print = false) => { writeFileSync(file, xml); return spawnSync(process.execPath, [cli, file, ...(print ? ['--print'] : [])], { encoding: 'utf8' }); };
try {
  for (const [predicate, values] of [
    ["[Code] in ('001', 'A,B', 'O''Brien', 'x)y', '')", ['001', 'A,B', "O'Brien", 'x)y', '']],
    ['[Code] in (1, -2, 1.5)', [1, -2, 1.5]],
  ]) {
    const result = run(report(predicate)); assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout).document.elements[0].filters[0].values, values);
  }
  for (const [predicate, use, widget] of [
    ['[Code] in (?codes?)', '', ''],
    ["[Code] = upper('x')", '', ''],
    ["[Code] = '001'", 'optional', ''],
    ['[Code] = ?codes?', '', '<selectValue parameter="codes" multiSelect="true"><selectOptions><selectOption useValue="x"/></selectOptions></selectValue>'],
    ['[Code] = ?codes?', '', '<selectWithSearch parameter="codes"/>'],
  ]) {
    const xml = report(predicate, use, widget), result = run(xml);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(!JSON.parse(result.stdout).document.elements.find(e => e.kind === 'table').filters?.length);
    assert.match(result.stderr, /re-create/);
    assert.equal(run(xml, true).status, 1);
  }
  console.log('test-filter-semantics: PASS');
} finally { rmSync(work, { recursive: true, force: true }); }
