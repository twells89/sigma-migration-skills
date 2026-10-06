#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const cli = fileURLToPath(new URL('../converter/cli.mjs', import.meta.url));
const work = mkdtempSync(join(tmpdir(), 'cognos-pages-'));
const file = join(work, 'report.xml');
const list = '<list refQuery="q"><listColumns><listColumn><listColumnBody><dataItemValue refDataItem="Region"/></listColumnBody></listColumn></listColumns></list>';
const page = (name, body = list, attrs = '') => `<page name="${name}" ${attrs}><pageHeader><contents><textItem><dataSource><staticValue>${name} header</staticValue></dataSource></textItem></contents></pageHeader><pageBody><contents>${body}</contents></pageBody></page>`;
const query = '<queries><query name="q"><source><model/></source><selection><dataItem name="Region"><expression>[C].[M].[Sales].[Region]</expression></dataItem></selection></query></queries>';
const report = (layout, queries = query) => `<report viewPagesAsTabs="topLeft">${queries}<layouts><layout>${layout}</layout></layouts></report>`;
const run = (xml, print = false) => {
  writeFileSync(file, xml);
  return spawnSync(process.execPath, [cli, file, ...(print ? ['--print'] : [])], { encoding: 'utf8' });
};
let failed = 0;
const check = (label, fn) => {
  try { fn(); console.log(`PASS ${label}`); }
  catch (error) { failed++; console.error(`FAIL ${label}: ${error.message}`); }
};
try {
  for (const promptFirst of [true, false]) {
    const prompts = `<promptPages>${page('Choose', `${list}<pageBreak/>`)}</promptPages>`;
    const output = `<reportPages>${page('First')}${page('Second')}</reportPages>`;
    const xml = report(promptFirst ? prompts + output : output + prompts);
    check(`prompt pages/visuals excluded; source panels stay aligned (${promptFirst})`, () => {
      const wb = run(xml);
      assert.equal(wb.status, 0, wb.stderr);
      const doc = JSON.parse(wb.stdout).document;
      assert.deepEqual(doc.pages.map(p => p.name), ['First', 'Second']);
      assert.equal(doc.elements.filter(e => e.kind === 'table').length, 2);
      assert.ok(!doc.elements.some(e => e.kind === 'page-break'));
      assert.ok(doc.elements.filter(e => e.kind === 'navigation').every(e => e.pageLabels.length === 2));
      const printed = run(xml, true);
      assert.equal(printed.status, 0, printed.stderr);
      const contents = JSON.parse(printed.stdout);
      assert.deepEqual(contents.pages.map(p => p.name), ['First', 'Second']);
      assert.equal(contents.elements.filter(e => e.kind === 'table').length, 2);
      for (const name of ['First', 'Second']) {
        const p = contents.pages.find(p => p.name === name);
        assert.ok(contents.panels.some(panel => panel.title === `${name} header` && panel.pages.includes(p.id)));
        assert.ok(contents.elements.some(e => e.body === `${name} header`));
      }
      assert.ok(!contents.elements.some(e => String(e.body).includes('Choose')));
    });
  }
  check('prompt metadata survives output-page exclusion', () => {
    const widget = '<selectValue parameter="region"><selectOptions><selectOption useValue="East"/><selectOption useValue="West"/></selectOptions><defaultSelections><defaultSimpleSelection>West</defaultSimpleSelection></defaultSelections></selectValue>';
    const filtered = query.replace('</selection>', '</selection><detailFilters><detailFilter><filterExpression>[Region] = ?region?</filterExpression></detailFilter></detailFilters>');
    const result = run(report(`<promptPages>${page('Choose', widget)}</promptPages><reportPages>${page('Output')}</reportPages>`, filtered));
    assert.equal(result.status, 0, result.stderr);
    const doc = JSON.parse(result.stdout).document;
    assert.deepEqual(doc.pages.map(p => p.name), ['Output']);
    const control = doc.elements.find(e => e.controlId === 'region');
    assert.deepEqual(control.source.values, ['East', 'West']);
    assert.equal(control.value, 'West');
    assert.ok(doc.layout.includes(`elementId="${control.id}"`));
  });
  check('prompt-only report cannot create an output fallback', () => {
    for (const print of [false, true]) {
      const result = run(report(`<promptPages>${page('Choose')}</promptPages>`), print);
      assert.equal(result.status, 1);
      assert.equal(result.stdout, '');
      assert.match(result.stderr, /no output pages/i);
    }
  });
  check('custom-control metadata on a prompt page still drives a macro', () => {
    const widget = `<customControl><configuration>{"Parameter":"metric","Button label":"Revenue","Button value":"[C].[M].[Sales].[Revenue]"}</configuration></customControl>`;
    const macro = query.replace('[C].[M].[Sales].[Region]', "# prompt('metric','token','[C].[M].[Sales].[Region]') #");
    const result = run(report(`<promptPages>${page('Choose', widget)}</promptPages><reportPages>${page('Output')}</reportPages>`, macro));
    assert.equal(result.status, 0, result.stderr);
    const doc = JSON.parse(result.stdout).document;
    assert.deepEqual(doc.pages.map(p => p.name), ['Output']);
    assert.deepEqual(doc.elements.find(e => e.controlId === 'metric').source.values, ['Revenue']);
    assert.ok(doc.elements.some(e => e.columns?.some(c => c.formula.startsWith('Switch([metric]'))));
  });
  check('reportPage alias excludes prompt-only data and runtime layout', () => {
    const prompts = `<promptPages>${page('Choose', `${list}<textItem><dataSource><reportExpression>PageNumber()</reportExpression></dataSource></textItem>`, 'resetPageCount="true"')}</promptPages>`;
    const output = page('Output').replace('<page ', '<reportPage ').replace('</page>', '</reportPage>');
    const result = run(report(`${prompts}<reportPages>${output}</reportPages>`), true);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout).pages.map(p => p.name), ['Output']);
  });
  const simple = `<reportPages>${page('Output')}</reportPages>`;
  const blockers = [
    ['page set', `<reportPages><pageSet refQuery="q"><detailPages>${page('Output')}</detailPages></pageSet></reportPages>`, /page.set|pagination/i],
    ['reset number', `<reportPages>${page('Output', list, 'resetPageNumber="1"')}</reportPages>`, /reset|pagination/i],
    ['reset count', `<reportPages>${page('Output', list, 'resetPageCount="true"')}</reportPages>`, /reset|pagination/i],
    ['conditional render', simple.replace('<pageBody>', '<conditionalRender refVariable="visible"><renderFor value="yes"/></conditionalRender><pageBody>'), /conditional.*render/i],
    ['parameter display text', simple.replace('</contents></pageBody>', '<textItem><dataSource><reportExpression>ParamDisplayValue(\'region\')</reportExpression></dataSource></textItem></contents></pageBody>'), /runtime|parameter|prompt/i],
    ['page-number expression', simple.replace('</contents></pageBody>', '<textItem><dataSource><reportExpression>PageNumber()</reportExpression></dataSource></textItem></contents></pageBody>'), /report expression/i],
  ];
  for (const widget of ['<selectValue parameter="region"/>', '<selectWithSearch parameter="region"/>', '<textBox parameter="region"/>']) {
    blockers.push(['prompt widget', `<promptPages>${page('Choose', widget)}</promptPages>${simple}`, /runtime|parameter|prompt/i]);
    blockers.push(['inline prompt widget', `<reportPages>${page('Output', widget + list)}</reportPages>`, /runtime|parameter|prompt/i]);
  }
  for (const [label, layout, expected] of blockers) {
    check(`print refuses unsupported ${label}`, () => {
      const result = run(report(layout), true);
      assert.equal(result.status, 1);
      assert.equal(result.stdout, '');
      assert.match(result.stderr, expected);
    });
  }
  check('explicit false resets and ordinary pages remain printable', () => {
    const result = run(report(`<reportPages>${page('Output', list, 'resetPageCount="false" resetPageNumber="0"')}</reportPages>`), true);
    assert.equal(result.status, 0, result.stderr);
  });
} finally {
  rmSync(work, { recursive: true, force: true });
}
assert.equal(failed, 0, `${failed} report page regressions failed`);
