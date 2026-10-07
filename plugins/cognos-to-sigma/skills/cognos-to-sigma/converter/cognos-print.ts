/** Cognos report XML → Sigma Report code representation (pixel layout).
 * Reuses the workbook converter's translated queries and visual elements;
 * only presentation is different. A rendered Cognos PDF is still required to
 * certify pixel fidelity (fonts, page geometry and row pagination can vary).
 */
import { XMLParser } from 'fast-xml-parser';
import { convertCognosReportToSigma, type CognosReportOptions } from './cognos-report.js';
import { sigmaShortId } from './sigma-ids.js';

export interface CognosPrintOptions extends CognosReportOptions {
  pageWidth?: number; pageHeight?: number; margin?: number;
}

const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '@_', trimValues: true });
const arr = (value: any): any[] => Array.isArray(value) ? value : value == null ? [] : [value];
const findAll = (node: any, tag: string, out: any[] = []): any[] => {
  if (!node || typeof node !== 'object') return out;
  for (const [key, value] of Object.entries(node)) {
    if (key === tag) out.push(...arr(value));
    if (key === 'promptPages') continue;
    for (const item of arr(value)) findAll(item, tag, out);
  }
  return out;
};
const text = (v: any) => String(typeof v === 'object' ? v?.['#text'] || '' : v || '').trim();
const esc = (value: string) => String(value).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const style = (node: any) => findAll(node?.style || {}, 'CSS')
  .map((s: any) => String(s['@_value'] || '')).join(';');
const cssSize = (node: any, prop: 'width' | 'height', base: number): number | null => {
  const match = style(node).match(new RegExp(`(?:^|;)\\s*${prop}\\s*:\\s*([0-9.]+)\\s*(px|pt|%)`, 'i'));
  if (!match) return null;
  const n = Number(match[1]);
  return match[2] === '%' ? base * n / 100 : match[2].toLowerCase() === 'pt' ? n * 4 / 3 : n;
};
const pageNodes = (report: any): any[] => {
  const pages = findAll(report.layouts || {}, 'reportPage').concat(findAll(report.layouts || {}, 'page'));
  return pages.length ? pages : [report];
};

interface Placement { elementId: string; pageId: string; source: any; kind: string; order: number }

export function convertCognosPrintToSigma(xml: string, options: CognosPrintOptions = {}) {
  const { workbook, warnings: original, lineage = [] } = convertCognosReportToSigma(xml,
    { ...options, captureLineage: true });
  const doc = workbook.document;
  const report = parser.parse(xml).report;
  if (!report) throw new Error('input is not a Cognos report specification');
  const sources = pageNodes(report);
  // The workbook cannot model page footers; Sigma Reports can. Replace that
  // workbook-only warning with a report-specific finding below as needed.
  const warnings = original.filter((warning) => !warning.includes('WORKBOOK FEATURE GAP [page footer panel]'));
  const pageWidth = options.pageWidth ?? 816, pageHeight = options.pageHeight ?? 1056;
  const margin = options.margin ?? 48;
  if (![pageWidth, pageHeight, margin].every(Number.isFinite) || pageWidth < 200 || pageHeight < 200 || margin < 0 || margin * 2 >= Math.min(pageWidth, pageHeight)) {
    throw new Error('invalid page geometry: provide positive pageWidth/pageHeight and a smaller margin');
  }
  const width = pageWidth - 2 * margin;
  const elements = new Map(doc.elements.map((element: any) => [element.id, element]));
  const placed = new Set<string>();
  const content: any[] = [];
  const panels: Array<Record<string, any>> = [];
  const pageLines: string[] = [], panelLines: string[] = [];
  const notPrintable = new Set(['navigation', 'page-break', 'drill', 'progress', 'repeated-container', 'container', 'tabbed-container', 'divider']);
  const queryGaps = original.filter((warning) => /query dependency/.test(warning));
  if (queryGaps.length) {
    throw new Error(`Cognos report has an unresolved query dependency; build or repair the data model and preserve query joins, filters and grain before printing.\n${queryGaps.slice(0, 5).join('\n')}${queryGaps.length > 5 ? `\n${queryGaps.length - 5} further query gaps are listed by the workbook converter.` : ''}`);
  }
  if (original.some((warning) => /nested data container|master-detail links/.test(warning))) {
    throw new Error('Cognos report uses a nested data container or master-detail layout; unrelated flat tables cannot preserve its record correlation and pagination.');
  }
  if (original.some((warning) => /visible column combines/.test(warning))) {
    throw new Error('Cognos report has a compound list cell; retaining only its first value would omit printable content. Re-author the complete cell before printing.');
  }
  // CodeRep.wrap strips visibleAsSource from workbook code, so use the
  // pre-wrap lineage marker. Printing a hidden scatter/progress helper as a
  // table changes the PDF; removing it also breaks its dependent visual.
  if (lineage.some((slot) => slot.hiddenSource)) {
    throw new Error('Cognos report uses a hidden visual source table; author its dependency on a non-printing Report page and verify the visual before printing.');
  }
  const slots: Placement[] = lineage.filter((slot) => !notPrintable.has(slot.kind) && slot.kind !== 'control')
    .sort((a, b) => a.pageId === b.pageId ? a.order - b.order : doc.pages.findIndex((p: any) => p.id === a.pageId) - doc.pages.findIndex((p: any) => p.id === b.pageId));
  const used = new Set<string>();
  const unsupported = slots.filter((slot) => slot.kind === 'pivot-table');
  if (unsupported.length) {
    const names = unsupported.map((slot) => (elements.get(slot.elementId) as any)?.name || slot.elementId);
    throw new Error(`${unsupported.length} Cognos crosstab(s) require Sigma Report pivot-table code support; the live Reports dry-run rejects pivot-table. ${names.join(', ')}. Use the workbook pivot until Report code supports it.`);
  }
  const unsupportedCharts = slots.filter((slot) => !['table', 'kpi-chart', 'bar-chart', 'line-chart', 'area-chart', 'pie-chart', 'scatter-chart', 'donut-chart', 'combo-chart', 'point-map', 'region-map'].includes(slot.kind));
  if (unsupportedCharts.length) {
    throw new Error(`Sigma Report code has no verified mapping for: ${unsupportedCharts.map((slot) => slot.kind).join(', ')}. Keep the workbook or re-author and validate those visuals explicitly.`);
  }
  // The workbook converter carries some source features only as a flagged
  // fallback table; that table is not an acceptable PDF replacement for a
  // Cognos chart. Catch those even when the fallback has kind `table`.
  const unsupportedSourceKinds = new Set(['waterfall-chart', 'progress', 'repeated-container']);
  if (doc.elements.some((element: any) => unsupportedSourceKinds.has(element.kind))) {
    throw new Error('Cognos report contains a workbook-only visual/layout element (waterfall, progress or repeated container) that has no direct Sigma Report mapping. Re-author explicitly before print migration.');
  }
  if (doc.elements.some((element: any) => element.kind === 'control')) {
    throw new Error('Cognos report uses parameter or drill controls; render and author a control-specific Sigma Report before printing. Omitting controls could change the reported values.');
  }
  if (findAll(report.layouts || report, 'pageSet').length ||
      ['@_resetPageNumber', '@_resetPageCount'].some((tag) => findAll(report.layouts || report, tag)
        .some((value) => !['false', '0', ''].includes(String(value).toLowerCase())))) {
    throw new Error('Cognos page-set or page-reset pagination is not converted; verify document boundaries and per-document numbering before printing.');
  }
  if (findAll(report.layouts || report, 'conditionalRender').length) {
    throw new Error('Cognos conditional rendering is not converted; resolve which pages and records should render before printing.');
  }
  // Prompt metadata may not have produced a workbook control (search/text/multi-
  // select widgets and render-only parameters). Absence of a control is no proof.
  const promptRoots = [report, ...findAll(report, 'promptPages')];
  if (promptRoots.some((root) => ['selectValue', 'selectWithSearch', 'textBox', 'selectDate', 'selectTime', 'selectDateTime', 'selectInterval', 'selectTree']
    .some((tag) => findAll(root, tag).some((widget) => widget?.['@_parameter'])))) {
    throw new Error('Cognos runtime prompt widgets require verified parameter selections and behavior before printing; defaults are not a source snapshot.');
  }
  if (findAll(report.layouts || report, 'reportExpression').length) {
    throw new Error('Cognos runtime report expression is not converted; preserve parameter display text and page-number expressions before printing.');
  }
  if (original.some((warning) => /no grounded Sigma mapping|preserved its data as a table|emitted its data as a table/i.test(warning))) {
    throw new Error('Cognos visual was degraded to a table by the workbook converter; cannot claim print fidelity until it is explicitly re-authored.');
  }
  if (original.some((warning) => /<list>|<crosstab>|<vizControl>|<singleton>|no visible dataItemValue/.test(warning) && /skipped|was not emitted|cannot emit/i.test(warning))) {
    throw new Error('a Cognos report data visual could not be emitted by the workbook converter; refusing to create an incomplete Sigma Report');
  }
  if (original.some((warning) => /list column .*not found in query|crosstab .* member .*not in query|chart .* column .*not in query/i.test(warning))) {
    throw new Error('a Cognos report data column was dropped because it was absent from the backing query; refusing an incomplete Sigma Report');
  }
  if (original.some((warning) => /unmapped Cognos aggregate|aggregate .* is not mapped|unmapped Cognos rollup/i.test(warning))) {
    throw new Error('a Cognos measure has no grounded Sigma aggregate; refusing to publish a print report with potentially wrong values');
  }
  if (original.some((warning) => /filter.*re-create|summary filter:/.test(warning))) {
    throw new Error('a Cognos report filter was not converted; a print report could display different values until its filter is authored');
  }
  // Filter XML can be structured (e.g. filterDefinition/filterInValues) and
  // have no filterExpression. The workbook translator cannot see these in
  // q.filters, so warn/refuse rather than exporting unfiltered extra rows.
  if (['detailFilter', 'summaryFilter'].some((tag) => findAll(report, tag).some((filter) =>
    filter?.['@_use'] !== 'prohibited' && !text(filter?.filterExpression || filter?.expression)))) {
    throw new Error('a Cognos report uses a structured or empty filter without a translated expression; refusing an unfiltered print report');
  }
  const add = (element: any, x: number, y: number, w: number, h: number, flow = false) => {
    if (!element || placed.has(element.id)) return '';
    content.push(element); placed.add(element.id);
    return `  <Element elementId="${esc(element.id)}" x="${Math.round(x)}" y="${Math.round(y)}" width="${Math.round(w)}" height="${Math.round(h)}"${flow ? ' flow="paginated"' : ''}/>`;
  };
  const staticText = (node: any) => findAll(node, 'staticValue')
    .map(text).filter(Boolean).find((s) => !/^<[^>]+>/.test(s) && !/^[A-Za-z ]{1,8}$/.test(s));
  const headings = (node: any): string[] => {
    const out: string[] = [];
    const visit = (part: any) => {
      if (!part || typeof part !== 'object') return;
      for (const [key, value] of Object.entries(part)) {
        // A list's no-data fallback is not a page heading, and visual/data
        // labels belong to the visual that renders them.
        if (['list', 'crosstab', 'vizControl', 'singleton', 'noDataHandler', 'HTMLItem'].includes(key)) continue;
        if (key === 'staticValue') out.push(...arr(value).map(text));
        else arr(value).forEach(visit);
      }
    };
    visit(node);
    return out.filter((s) => s && s.length < 100 && !s.startsWith('<'));
  };
  for (let i = 0; i < doc.pages.length; i++) {
    const page = doc.pages[i];
    const source = sources[i] || {};
    const body = source.pageBody?.contents || source.contents || source;
    const lines: string[] = [];
    let y = margin;
    // Preserve explicit Cognos page/header text. Other freeform HTML and nested
    // table layouts are listed as review items rather than flattened blindly.
    const title = headings(body)[0];
    if (title && !slots.some((s) => s.pageId === page.id && s.kind === 'text')) {
      const heading = { id: sigmaShortId(), kind: 'text', body: title };
      lines.push(add(heading, margin, y, width, 36)); y += 44;
    }
    const pageSlots = slots.filter((slot) => slot.pageId === page.id);
    const staticValues = headings(body);
    if (staticValues.length > 1) {
      warnings.push(`page "${page.name}": ${staticValues.length} static text/layout cells need the Cognos PDF to position; only the first heading was retained.`);
    }
    if (!pageSlots.length && staticValues.length) {
      warnings.push(`page "${page.name}": no data visuals resolved; review its static text/layout against the Cognos PDF.`);
    }
    const visualCount = pageSlots.length;
    const heightPer = Math.min(390, Math.floor((pageHeight - margin - y - Math.max(0, visualCount - 1) * 16) / Math.max(1, visualCount)));
    if (visualCount && heightPer < 120) {
      warnings.push(`page "${page.name}": ${visualCount} elements cannot fit legibly in ${pageHeight}px; split or resize against the Cognos PDF.`);
    }
    for (const slot of pageSlots) {
      if (used.has(slot.elementId)) continue;
      used.add(slot.elementId);
      const element = elements.get(slot.elementId) as any;
      if (!element) throw new Error(`source element ${slot.elementId} is missing from the converted workbook`);
      const w = Math.min(width, cssSize(slot.source, 'width', width) || width);
      const isTable = ['table', 'pivot-table'].includes(slot.kind);
      const sourceHeight = cssSize(slot.source, 'height', pageHeight - 2 * margin);
      const remaining = pageHeight - margin - y;
      const h = Math.max(1, Math.min(heightPer, sourceHeight || heightPer, remaining));
      if (isTable && remaining < 160) {
        warnings.push(`page "${page.name}": the ${slot.kind} at y=${Math.round(y)} may overflow the page; provide a Cognos PDF to calibrate pagination.`);
      }
      lines.push(add(element, margin, y, w, h, isTable));
      if (isTable && slot.kind === 'table' && slot.source?.['@_horizontalPagination'] === 'true') {
        warnings.push(`page "${page.name}": Cognos list "${slot.source?.['@_name'] || element?.name}" requests horizontal pagination; Sigma Reports paginate vertically only. Check wide columns against the source PDF.`);
      }
      if (isTable && Number(slot.source?.['@_rowsPerPage']) > 10000) {
        warnings.push(`page "${page.name}": Cognos list "${slot.source?.['@_name'] || element?.name}" requests ${slot.source['@_rowsPerPage']} rows/page; Sigma Report exports cap each table at 10,000 rendered rows.`);
      }
      y += h + 16;
    }
    pageLines.push(`  <Page id="${esc(page.id)}">${lines.length ? '\n' + lines.join('\n') + '\n  ' : ''}</Page>`);

    for (const [tag, type] of [['pageHeader', 'header'], ['pageFooter', 'footer']] as const) {
      const original = findAll(source, tag)[0];
      if (!original) continue;
      const textValue = staticText(original);
      const panelHeight = Math.min(130, cssSize(original, 'height', pageHeight) || 64);
      const panelId = sigmaShortId();
      const background = style(original).match(/background(?:-color)?\s*:\s*(#[0-9a-f]{3,8})/i)?.[1];
      panels.push({ id: panelId, type, title: `${page.name} ${type}`, pages: [page.id], config: {
        height: panelHeight, ...(background ? { backgroundColor: background } : {}),
      } });
      if (textValue) {
        const part = { id: sigmaShortId(), kind: 'text', body: textValue };
        panelLines.push(`  <Panel id="${esc(panelId)}" type="${type}">\n${add(part, 12, 12, Math.max(40, width - 24), Math.max(20, panelHeight - 18))}\n  </Panel>`);
      } else {
        warnings.push(`page "${page.name}": ${type} panel contains layout or HTML that needs reference-PDF review.`);
        panelLines.push(`  <Panel id="${esc(panelId)}" type="${type}"/>`);
      }
    }
    if (findAll(body, 'HTMLItem').length) warnings.push(`page "${page.name}": embedded Cognos HTML requires manual Sigma Report re-authoring.`);
  }
  for (const element of doc.elements as any[]) {
    if (placed.has(element.id)) continue;
    if (['navigation', 'page-break'].includes(element.kind)) continue;
    if (!['container', 'repeated-container', 'text'].includes(element.kind)) {
      warnings.push(`element "${element.name || element.id}" (${element.kind}) was not placed in the Sigma Report — inspect source XML.`);
    }
  }
  if (!content.some((el: any) => ['table', 'kpi-chart'].includes(el.kind) || /-(chart|map)$/.test(el.kind))) {
    throw new Error('Cognos report contains no printable data elements; refusing an empty Sigma Report');
  }
  const layout = `<?xml version="1.0" encoding="utf-8"?>\n${[...pageLines, ...panelLines].join('\n')}`;
  return {
    contents: { schemaVersion: 1, kind: 'report' as const, elements: content,
      pages: doc.pages.map(({ id, name }: any) => ({ id, name })),
      ...(panels.length ? { panels } : {}), config: { pageWidth, pageHeight, margin }, layout },
    warnings,
    stats: { pages: doc.pages.length, elements: content.length, panels: panels.length },
  };
}
