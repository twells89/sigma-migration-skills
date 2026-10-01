#!/usr/bin/env node
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { composePrintLayout } from './compose-print-layout.mjs';
import { reportSpecErrors } from './lib/report-spec.mjs';

const base = { schemaVersion: 1, kind: 'report', elements: [
  { id: 'table', kind: 'table', source: { kind: 'data-model', dataModelId: 'dm', elementId: 'el' },
    columns: [{ id: 'region', name: 'Region', formula: '[Orders/Region]' }] }],
  pages: [{ id: 'summary', name: 'Regional orders' }],
  config: { margin: 48, pageWidth: 816, pageHeight: 1056 },
  layout: '<Page id="summary"><Element elementId="table" x="48" y="48" width="720" height="350" flow="paginated"/></Page>' };
const bp = JSON.parse(readFileSync(new URL('../fixtures/print-layout-blueprint.json', import.meta.url), 'utf8'));
const { contents, summary } = composePrintLayout(base, bp);
assert.deepEqual(contents.pages.map((p) => p.name), ['Cover', 'Letter', 'Summary', ...Array.from({ length: 6 }, (_, i) => `Terms ${i + 1}`)]);
assert.deepEqual(summary.backgrounds, ['Cover', 'Letter', 'Summary']);
assert.equal(summary.textElements, 24);
assert.deepEqual(base.pages.map((p) => p.name), ['Regional orders']);
assert.equal(contents.elements.filter((e) => e.kind === 'table').length, 1);
assert.equal(contents.panels.filter((p) => p.type === 'footer').length, 1);
assert.deepEqual(contents.panels[0].pages, contents.pages.map((p) => p.id));
assert(contents.elements.some((e) => /CurrentPageNumber\(\)/.test(e.body)));
assert.equal(contents.elements.filter((e) => e.kind === 'image' && e.source.url.startsWith('data:image/svg+xml;base64,')).length, 11);
const dense = contents.elements.filter((e) => e.kind === 'image' && /Example note 1/.test(Buffer.from(e.source.url.split(',')[1], 'base64').toString('utf8')));
assert.equal(dense.length, 6);
assert(dense.every((e) => Buffer.from(e.source.url.split(',')[1], 'base64').toString('utf8').includes('font-size="9"')));
assert(contents.pages.every((p) => !p.backgroundImage));
for (const [index, page] of contents.pages.entries()) {
  const pageMatch = [...contents.layout.matchAll(/<Page\b[^>]*\bid="([^"]+)"[^>]*>([\s\S]*?)<\/Page>/g)][index];
  assert.equal(pageMatch[1], page.id);
  if (index >= 3) assert.match(pageMatch[2], /<Element[^>]+ x="48" y="(?:83|48)" width="670" height="(?:795|830)"\/>/);
  assert((pageMatch[2].match(/<Element\b/g) || []).length >= 1);
}
assert.deepEqual(reportSpecErrors(contents), []);
const withFooter = { ...base, elements: [...base.elements, { id: 'old-footer', kind: 'text', body: 'Old' }],
  panels: [{ id: 'old-panel', type: 'footer', pages: ['summary'], config: { height: 50 } }],
  layout: `${base.layout}<Panel id="old-panel" type="footer"><Element elementId="old-footer" x="0" y="0" width="200" height="30"/></Panel>` };
const replaced = composePrintLayout(withFooter, bp).contents;
assert.equal(replaced.panels.filter((panel) => panel.type === 'footer').length, 1);
assert(!replaced.layout.includes('old-panel') && !replaced.elements.some((element) => element.id === 'old-footer'));
const withHeader = { ...withFooter,
  elements: [...withFooter.elements, { id: 'old-header', kind: 'text', body: 'Old source header' }],
  panels: [...withFooter.panels, { id: 'header-panel', type: 'header', pages: ['summary'], config: { height: 50 } }],
  layout: `${withFooter.layout}<Panel id="header-panel" type="header"><Element elementId="old-header" x="0" y="0" width="200" height="30"/></Panel>` };
const withoutHeader = composePrintLayout(withHeader, bp).contents;
assert(!withoutHeader.panels.some((panel) => panel.type === 'header'));
assert(!withoutHeader.elements.some((element) => element.id === 'old-header'));
assert.throws(() => composePrintLayout(base, { pages: [{ name: 'Invalid', blocks: [{ x: 0, y: 0, width: 5000, height: 20, body: 'Bad' }] }] }), /exceeds/);
assert.throws(() => composePrintLayout(base, { pages: [{ name: 'Bad URL', backgroundImageUrl: 'file:///secret' }] }), /HTTPS or a base64 SVG data URI/);
assert.throws(() => composePrintLayout(base, { pages: [{ sourcePage: 'Regional orders', tableBox: { x: 0, y: 0, width: 900, height: 100 } }] }), /table exceeds/);
assert.doesNotThrow(() => composePrintLayout(base, { pages: [{ sourcePage: 'Regional orders', tableBox: { x: 48, y: 48, width: 720, height: 960 } }] }));
assert.throws(() => composePrintLayout(base, { pages: [{ sourcePage: 'Regional orders', tableBox: { x: 0, y: 0, width: 720, height: 960 } }] }), /table exceeds/);
assert.throws(() => composePrintLayout(base, { pages: [{ name: 'Overflow', watermark: { text: 'SAMPLE' }, imageBox: { x: 0, y: 0, width: 816, height: 1056 } }] }), /exceeds/);
assert.throws(() => composePrintLayout(base, { pages: [{ name: 'Bad dense', blocks: [{ x: 48, y: 48, width: 200, height: 100, body: 'test', fontSize: 13, dense: true }] }] }), /fixed 9px/);
const noFill = composePrintLayout(base, { pages: [{ name: 'Small print', blocks: [{ x: 48, y: 48, width: 500, height: 120, body: 'Supplied text only.', dense: true }] }] }).contents;
const noFillSvg = Buffer.from(noFill.elements.find((e) => e.kind === 'image').source.url.split(',')[1], 'base64').toString('utf8');
assert(!noFillSvg.includes('Example note') && noFillSvg.includes('Supplied text only.'));
assert.throws(() => composePrintLayout(base, { pages: [{ name: 'Too much', blocks: [{ x: 48, y: 48, width: 220, height: 60, body: 'A long paragraph that should not be silently truncated. '.repeat(30), dense: true }] }] }), /exceeds the allotted page/);
assert.throws(() => composePrintLayout(base, { pages: [{ name: 'After', position: 'after', afterPage: 'Missing' }] }), /afterPage/);
assert.throws(() => composePrintLayout(base, { pages: [{ sourcePage: 'Regional orders' }, { sourcePage: 'Regional orders' }] }), /more than once/);
assert.throws(() => composePrintLayout(base, { pages: [{ sourcePage: 'Regional orders' }], footer: { body: 'x', pages: ['Regional orders', 'Regional orders'] } }), /more than once/);
const shared = { ...withFooter, pages: [...withFooter.pages, { id: 'second', name: 'Second' }],
  panels: [{ ...withFooter.panels[0], pages: ['summary', 'second'] }],
  layout: `${withFooter.layout}<Page id="second"></Page>` };
assert.throws(() => composePrintLayout(shared, { pages: [{ sourcePage: 'Regional orders' }], footer: { body: 'Replacement', pages: ['Regional orders'] } }), /shared with unselected/);
console.log('test-compose-print-layout: PASS');
