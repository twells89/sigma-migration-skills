#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const cli = fileURLToPath(new URL('../converter/cli.mjs', import.meta.url));
const work = mkdtempSync(join(tmpdir(), 'cognos-projections-'));
const file = join(work, 'report.xml');
const item = (name, expr) => `<dataItem name="${name}" aggregate="none"><expression>${expr}</expression></dataItem>`;
const filter = (expr, use = '') => `<detailFilter ${use ? `use="${use}"` : ''}><filterExpression>${expr}</filterExpression></detailFilter>`;
const base = `<query name="base"><source><model/></source><selection>
  ${item('Row ID', '[C].[M].[Sales].[Row ID]')}${item('Region', '[C].[M].[Sales].[Region]')}
  ${item('Status', '[C].[M].[Sales].[Status]')}${item('Code', '[C].[M].[Sales].[Code]')}
  </selection><detailFilters>${filter("[Region] = 'East'")}${filter("[Status] = 'Closed'", 'prohibited')}</detailFilters></query>`;
const middle = `<query name="middle"><source><queryRef refQuery="base"/></source><selection>
  ${item('Row ID', '[base].[Row ID]')}${item('Area', '[base].[Region]')}${item('State', '[base].[Status]')}${item('Code', '[base].[Code]')}
  </selection><detailFilters>${filter("[State] in ('Open', 'Queued')")}</detailFilters></query>`;
const leaf = `<query name="leaf"><source><queryRef refQuery="middle"/></source><selection>
  ${item('Row ID', '[middle].[Row ID]')}${item('Region', '[middle].[State]')}
  </selection><detailFilters>${filter("[Region] = 'Open'")}</detailFilters></query>`;
const list = '<list refQuery="leaf"><listColumns><listColumn><listColumnBody><dataItemValue refDataItem="Row ID"/></listColumnBody></listColumn><listColumn><listColumnBody><dataItemValue refDataItem="Region"/></listColumnBody></listColumn></listColumns></list>';
const report = (queries = leaf + middle + base, contents = list) => `<report><queries>${queries}</queries><layouts><layout><reportPages><page name="Output"><pageBody><contents>${contents}</contents></pageBody></page></reportPages></layout></layouts></report>`;
const run = (xml, print = false) => {
  writeFileSync(file, xml);
  return spawnSync(process.execPath, [cli, file, ...(print ? ['--print'] : [])], { encoding: 'utf8', timeout: 10000 });
};
let failed = 0;
const check = (label, fn) => {
  try { fn(); console.log(`PASS ${label}`); }
  catch (err) { failed++; console.error(`FAIL ${label}: ${err.message}`); }
};
const data = (result) => {
  assert.equal(result.status, 0, result.stderr);
  const payload = JSON.parse(result.stdout);
  return payload.document || payload;
};
const predicates = (table) => table.filters.map(f => ({
  formula: table.columns.find(c => c.id === f.columnId).formula.toLowerCase(),
  values: f.values,
}));
try {
  for (const queries of [leaf + middle + base, base + middle + leaf]) {
    check('chained aliases retain source, visible fields, hidden upstream filters and row population', () => {
      const result = run(report(queries));
      const doc = data(result);
      assert.doesNotMatch(result.stderr, /query dependency/);
      const tables = doc.elements.filter(e => e.kind === 'table');
      assert.equal(tables.length, 1, 'no helper tables or intermediate-query leakage');
      const t = tables[0];
      assert.equal(t.source.elementId, 'Sales');
      assert.deepEqual(t.order.map(id => t.columns.find(c => c.id === id).name), ['Row Id', 'Region']);
      assert.equal(t.columns.find(c => c.name === 'Region').formula.toLowerCase(), '[sales/status]');
      assert.deepEqual(predicates(t), [
        { formula: '[sales/region]', values: ['East'] },
        { formula: '[sales/status]', values: ['Open', 'Queued'] },
        { formula: '[sales/status]', values: ['Open'] },
      ]);
      assert.ok(t.columns.find(c => c.formula.toLowerCase() === '[sales/region]').hidden);
      const rows = [
        { id: 1, region: 'East', status: 'Open' }, { id: 2, region: 'West', status: 'Open' },
        { id: 3, region: 'East', status: 'Closed' }, { id: 4, region: 'East', status: 'Queued' },
      ];
      const actual = rows.filter(row => predicates(t).every(p => p.values.includes(row[p.formula.match(/^\[sales\/(.*)\]$/)[1]])));
      assert.deepEqual(actual.map(r => r.id), [1]);
      const printed = data(run(report(queries), true));
      assert.deepEqual(predicates(printed.elements.find(e => e.kind === 'table')), predicates(t));
    });
  }
  check('literal filter strings retain commas, escaped quotes and numeric-looking text', () => {
    const q = base.replace("[Region] = 'East'", "[Code] in ('001', 'A,B', 'O''Brien')");
    const t = data(run(report(leaf + middle + q))).elements.find(e => e.kind === 'table');
    assert.deepEqual(predicates(t)[0].values, ['001', 'A,B', "O'Brien"]);
  });
  check('numeric and empty-string literals retain their types', () => {
    const q = base.replace("[Region] = 'East'", "[Code] in (-2, 1.5, 1e2, '')");
    const t = data(run(report(leaf + middle + q))).elements.find(e => e.kind === 'table');
    assert.deepEqual(predicates(t)[0].values, [-2, 1.5, 100, '']);
  });
  check('explicit detail flags and prohibited summary filters remain safe', () => {
    const q = base.replace('<query name="base">', '<query name="base" autoGroupAndSummarize="false" distinct="false">')
      .replace('</query>', '<summaryFilters><summaryFilter use="prohibited"/></summaryFilters></query>');
    const result = run(report(leaf + middle + q), true);
    assert.equal(result.status, 0, result.stderr);
  });
  check('KPI source receives all inherited predicates', () => {
    const doc = data(run(report(undefined, '<singleton refQuery="leaf"><dataItemValue refDataItem="Row ID"/></singleton>')));
    assert.equal(doc.elements.find(e => e.kind === 'kpi-chart').filters.length, 3);
  });
  check('sibling query source is not mutated by another projection', () => {
    const xml = report(leaf + middle + base, list + list.replace('refQuery="leaf"', 'refQuery="base"'));
    const tables = data(run(xml)).elements.filter(e => e.kind === 'table');
    assert.equal(tables.length, 2);
    assert.equal(tables[1].source.elementId, 'Sales');
    assert.equal(tables[1].filters.length, 1);
    assert.deepEqual(tables[1].filters[0].values, ['East']);
  });
  check('repeater source retains inherited filters', () => {
    const xml = report(undefined, '<repeater name="Cards" refQuery="leaf"><contents><dataItemValue refDataItem="Row ID"/></contents></repeater>');
    const t = data(run(xml)).elements.find(e => e.kind === 'table');
    assert.equal(t.source.elementId, 'Sales');
    assert.equal(t.filters.length, 3);
  });
  check('omitted upstream fields do not leak into implicit output columns', () => {
    const t = data(run(report(undefined, '<list refQuery="leaf"/>'))).elements.find(e => e.kind === 'table');
    assert.deepEqual(t.order.map(id => t.columns.find(c => c.id === id).name), ['Row Id', 'Region']);
    assert.equal(t.filters.length, 3);
  });
  check('generated hidden filter names cannot collide with projected aliases', () => {
    const xml = report((leaf + middle + base).replace('name="Region" aggregate="none"><expression>[middle].[State]', 'name="Query Filter 1" aggregate="none"><expression>[middle].[State]')
      .replace("[Region] = 'Open'", "[Query Filter 1] = 'Open'"), list.replace('refDataItem="Region"', 'refDataItem="Query Filter 1"'));
    const t = data(run(xml)).elements.find(e => e.kind === 'table');
    assert.equal(new Set(t.columns.map(c => c.name.toLowerCase())).size, t.columns.length);
    assert.equal(t.filters.length, 3);
  });
  const hazards = [
    ['missing upstream', report(leaf + middle)],
    ['query cycle', report(leaf + middle.replace('refQuery="base"', 'refQuery="leaf"') + base)],
    ['computed projection', report(leaf.replace('[middle].[State]', "[middle].[State] || 'x'") + middle + base)],
    ['computed upstream', report(leaf + middle + base.replace('[C].[M].[Sales].[Status]', "upper([C].[M].[Sales].[Status])"))],
    ['upstream aggregate', report(leaf + middle + base.replace('name="Status" aggregate="none"', 'name="Status" aggregate="total"'))],
    ['unspecified model aggregate', report(leaf + middle + base.replace('name="Status" aggregate="none"', 'name="Status"'))],
    ['projection aggregate', report(leaf.replace('name="Region" aggregate="none"', 'name="Region" aggregate="total"') + middle + base)],
    ['distinct upstream', report(leaf + middle + base.replace('<query name="base">', '<query name="base" distinct="true">'))],
    ['multiple subjects', report(leaf + middle + base.replace('[Sales].[Code]', '[Other].[Code]'))],
    ['same subject in different modules', report(leaf + middle + base.replace('[M].[Sales].[Code]', '[OtherModule].[Sales].[Code]'))],
    ['optional filter', report(leaf + middle + base.replace('<detailFilter >', '<detailFilter use="optional">'))],
    ['prompt filter', report(leaf + middle + base.replace("[Region] = 'East'", '[Region] in (?region?)'))],
    ['summary filter', report(leaf + middle + base.replace('</query>', '<summaryFilters><summaryFilter><filterExpression>[Code] = 1</filterExpression></summaryFilter></summaryFilters></query>'))],
    ['structured filter', report(leaf + middle + base.replace('<detailFilters>', '<detailFilters><detailFilter><filterDefinition/></detailFilter>'))],
    ['unsupported literal expression', report(leaf + middle + base.replace("[Region] = 'East'", "[Region] = upper('East')"))],
    ['missing field', report(leaf.replace('[middle].[State]', '[middle].[Absent]') + middle + base)],
    ['join source', report(leaf + middle.replace('<queryRef refQuery="base"/>', '<joinOperation><queryRef refQuery="base"/></joinOperation>') + base)],
    ['set source', report(leaf + middle.replace('<queryRef refQuery="base"/>', '<queryOperation name="union"><queryRef refQuery="base"/></queryOperation>') + base)],
    ['unselected upstream aggregate', report(leaf + middle + base.replace('</selection>', '<dataItem name="Total" aggregate="total"><expression>[C].[M].[Sales].[Amount]</expression></dataItem></selection>'))],
    ['unsafe integer literal', report(leaf + middle + base.replace("[Region] = 'East'", '[Code] = 9007199254740993'))],
    ['upstream sort boundary', report(leaf + middle + base.replace('</selection>', '</selection><sortList><sortItem refDataItem="Region"/></sortList>'))],
    ['duplicate query name', report(leaf + middle + base + base)],
    ['display name collision', report(leaf.replace('</selection>', `${item('ROW_ID', '[middle].[Row ID]')}</selection>`) + middle + base)],
  ];
  for (const [label, xml] of hazards) {
    check(`unsafe projection remains unbound: ${label}`, () => {
      const result = run(xml);
      const t = data(result).elements.find(e => e.kind === 'table');
      assert.equal(t.source.elementId, '<element>');
      assert.match(result.stderr, /query dependency/);
      const printed = run(xml, true);
      assert.equal(printed.status, 1);
      assert.equal(printed.stdout, '');
      assert.match(printed.stderr, /query dependency/);
    });
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}
assert.equal(failed, 0, `${failed} query projection regressions failed`);
