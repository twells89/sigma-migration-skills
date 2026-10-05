#!/usr/bin/env node
import { strict as assert } from 'node:assert';
import { reportSpecErrors } from './lib/report-spec.mjs';

const base = { schemaVersion: 1, kind: 'report', elements: [{ id: 'table', kind: 'table',
  source: { kind: 'data-model', dataModelId: 'dm', elementId: 'el' },
  columns: [{ id: 'col', name: 'Value', formula: '[Sales/Value]' }] }],
  pages: [{ id: 'page', name: 'Page' }],
  config: { margin: 48, pageWidth: 816, pageHeight: 1056 },
  layout: '<Page id="page"><Element elementId="table" x="48" y="48" width="720" height="200" flow="paginated"/></Page>' };
assert.deepEqual(reportSpecErrors(base), []);
assert.match(reportSpecErrors({ ...base, elements: [{ ...base.elements[0], kind: 'pivot-table' }] }).join(' '), /pivot-table/);
assert.match(reportSpecErrors({ ...base, layout: '<Page id="page"/>' }).join(' '), /unplaced/);
assert.match(reportSpecErrors({ ...base, elements: [] }).join(' '), /data-bearing/);
assert.match(reportSpecErrors({ ...base, elements: [{ id: 'table', kind: 'image', source: { kind: 'url', url: 'https://example.org/image.svg' } }] }).join(' '), /data-bearing/);
assert.match(reportSpecErrors({ ...base, elements: [{ ...base.elements[0], source: { kind: 'data-model', elementId: 'el' } }] }).join(' '), /unbound/);
assert.match(reportSpecErrors({ ...base, pages: [{ id: 'missing', name: 'Missing' }] }).join(' '), /page missing/);
const imagePage = { ...base,
  pages: [...base.pages, { id: 'scan', name: 'Scanned output' }],
  elements: [...base.elements, { id: 'scan-image', kind: 'image', source: { kind: 'url', url: 'https://example.org/page.png' } },
    { id: 'footer', kind: 'text', body: 'Page 2' }],
  panels: [{ id: 'foot', type: 'footer', pages: ['scan'] }],
  layout: `${base.layout}<Page id="scan"><Element elementId="scan-image"/></Page><Panel id="foot"><Element elementId="footer"/></Panel>`,
};
assert.match(reportSpecErrors(imagePage).join(' '), /image-only.*editable/i, 'a table elsewhere and a native footer must not disguise a screenshot page');
assert.deepEqual(reportSpecErrors({ ...base,
  elements: [...base.elements, { id: 'logo', kind: 'image', source: { kind: 'url', url: 'https://example.org/logo.svg' } }],
  layout: base.layout.replace('</Page>', '<Element elementId="logo"/></Page>'),
}), [], 'decorative artwork alongside native data is allowed');
console.log('test-report-spec: PASS');
