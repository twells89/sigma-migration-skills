import assert from 'node:assert/strict';
import {
  document,
  metadata,
  workbookElements,
  workbookElementsWithPages,
  workbookPageElementIds,
  wrap,
} from '../code_rep.mjs';

const live = {
  workbookId: 'w1',
  name: 'N',
  document: {
    schemaVersion: 1,
    pages: [{ id: 'p' }],
    elements: [{ id: 'e1', kind: 'table' }],
    overlays: [{ id: 'o1' }],
    panels: [{ id: 'panel1' }],
    layout: '<Page id="p"><Element elementId="e1"/></Page>',
  },
};

assert.equal(document(live).elements[0].id, 'e1');
assert.deepEqual(Object.keys(metadata(live)).sort(), ['name', 'workbookId']);
assert.deepEqual(workbookPageElementIds(live), { p: ['e1'] });
assert.equal(workbookElementsWithPages(live)[0][1].id, 'p');

const nested = {
  schemaVersion: 1,
  pages: [{ id: 'p', elements: [{ id: 'old', kind: 'text' }] }],
};
assert.deepEqual(workbookElements(nested).map((element) => element.id), ['old']);
const wrapped = wrap(nested).document;
assert.deepEqual(wrapped.elements.map((element) => element.id), ['old']);
assert.equal('elements' in wrapped.pages[0], false);

const legacyLayout = '<Page id="p"><GridContainer elementId="c"><LayoutElement elementId="e1"/>'
  + '<Noise elementId="not-layout"/></GridContainer></Page>';
assert.deepEqual(
  workbookPageElementIds({ ...live.document, layout: legacyLayout }),
  { p: ['c', 'e1'] },
);
const canonicalLayout = wrap({ ...live.document, layout: legacyLayout }).document.layout;
assert.equal(
  canonicalLayout,
  '<Page id="p"><Container elementId="c"><Element elementId="e1"/>'
    + '<Noise elementId="not-layout"/></Container></Page>',
);
assert.doesNotMatch(canonicalLayout, /LayoutElement|GridContainer/);

const legacyFields = {
  pages: [],
  elements: [
    { id: 'text', kind: 'text', verticalAlign: 'middle' },
    {
      id: 'kpi',
      kind: 'kpi-chart',
      layout: { anchor: 'start', verticalAnchor: 'end', titleOrient: 'bottom' },
    },
    { id: 'tabs', kind: 'tabbed-container', tabBar: { alignment: 'end' } },
    { id: 'h-rule', kind: 'divider', align: 'start' },
    { id: 'v-rule', kind: 'divider', direction: 'vertical', align: 'end' },
  ],
  overlays: [
    {
      id: 'filters',
      type: 'drawer',
      drawer: { width: 'medium', position: 'end', showShadow: 'shown' },
    },
  ],
};
const canonicalFields = wrap(legacyFields).document;
const fieldsById = Object.fromEntries(canonicalFields.elements.map((element) => [element.id, element]));
assert.equal(fieldsById.text.verticalAlign, 'center');
assert.deepEqual(
  fieldsById.kpi.layout,
  { anchor: 'left', verticalAnchor: 'bottom', titleOrient: 'bottom' },
);
assert.equal(fieldsById.tabs.tabBar.alignment, 'right');
assert.equal(fieldsById['h-rule'].align, 'top');
assert.equal(fieldsById['v-rule'].align, 'right');
assert.deepEqual(
  canonicalFields.overlays[0].drawer,
  { width: 'medium', showShadow: 'shown' },
);
assert.equal(legacyFields.elements[0].verticalAlign, 'middle');
assert.equal(legacyFields.overlays[0].drawer.position, 'end');

console.log('PASS — JavaScript workbook code representation');
