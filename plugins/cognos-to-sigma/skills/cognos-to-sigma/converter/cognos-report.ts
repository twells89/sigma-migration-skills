/**
 * IBM Cognos report-spec XML → Sigma workbook spec.   [LOCAL / WIP — not registered]
 *
 * Phase 2 of the Cognos converter (Phase 1 = Data Module JSON → DM, in cognos.ts).
 * MVP scope = **list reports** (the most common Cognos report kind):
 *   <query> + <dataItem><expression>  → the dataset (maps to the migrated DM element)
 *   <list refQuery=…> + its columns    → a Sigma `table` element with those columns
 *   model ref [C].[Module].[Subject].[Col] → [Subject/Col] (resolves against the DM)
 *   dataItem cross-ref [Other Item]        → [Other Item] (sibling column)
 *   prompt('p', …)                         → a Sigma control [+ control registered]
 *   detail/summary filter                  → element filter (expression translated)
 *   aggregate / if / date DSL              → reuses translateCognosExpr (cognos.ts)
 *
 * Cognos report MACROS (`# … prompt('x','token',…) … #` that build SQL/column refs
 * at runtime — e.g. a "swap measure" picker) ARE translated when the prompt's value
 * set is recoverable from the report (a `<selectValue parameter=…>` and/or
 * `customControl` button configs): they become a Sigma `segmented` control + a
 * `Switch([promptId], value, [col], …, defaultCol)` wired by controlId. Macros whose
 * value set can't be recovered still degrade to a flagged placeholder (never faked).
 *
 * Also converted: singletons → kpi-charts, detail filters → element filters
 * (`?prompt?` filters → control + boolean match column), auto-aggregated lists →
 * grouped tables (`groupings`), crosstabs → pivot-tables, charts (RAVE2
 * `<vizControl>`) → Sigma chart elements. NOT yet: drill-through→actions,
 * conditional render blocks, master-detail. Those are the research long-tail.
 */

import { XMLParser, XMLValidator } from 'fast-xml-parser';
import { resetIds, sigmaShortId, sigmaDisplayName } from './sigma-ids.js';
import { translateCognosExpr, type CognosQuerySubject } from './cognos.js';
import { metricRefOrInline, type BindMetric } from './metric-binding.js';
import { VIZ_GATED, VIZ_KIND, VIZ_NO_ANALOG, workbookGap } from './workbook-features.js';
// @ts-expect-error The vendored runtime adapter is plain ESM; esbuild bundles it.
import * as CodeRep from '../scripts/lib/code_rep.mjs';

const xmlParser = new XMLParser({
  ignoreAttributes: false, attributeNamePrefix: '@_', trimValues: true,
  isArray: (n) => ['query', 'dataItem', 'list', 'page', 'detailFilter', 'summaryFilter',
    'dataItemValue', 'dataItemLabel', 'listColumn', 'reportPage',
    'crosstab', 'crosstabNode', 'crosstabNodeMember',
    'vizControl', 'vcDataSet', 'vcSlotData', 'vcSlotDsColumn', 'reportDataStore'].includes(n),
});
const arr = (v: any): any[] => (Array.isArray(v) ? v : v == null ? [] : [v]);
const txt = (v: any): string => (v == null ? '' : typeof v === 'object' ? (v['#text'] ?? '') : String(v));

function filterLiterals(rhs: string, list: boolean): Array<string | number> | null {
  const literal = "(?:'(?:[^']|'')*'|[-+]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][-+]?\\d+)?)";
  if (!new RegExp(`^\\s*${literal}${list ? `(?:\\s*,\\s*${literal})*` : ''}\\s*$`).test(rhs)) return null;
  const values = [...rhs.matchAll(new RegExp(literal, 'g'))].map(([value]) =>
    value.startsWith("'") ? value.slice(1, -1).replace(/''/g, "'") : Number(value));
  return values.some((value) => typeof value === 'number' &&
    (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value)))) ? null : values;
}

// ── workbook spec types (minimal) ────────────────────────────────────────────
interface WbColumn { id: string; name: string; formula: string; format?: Record<string, any>; hidden?: boolean; }
interface WbControl {
  id: string; kind: 'control'; controlId: string; name: string; controlType: string;
  source?: Record<string, any>; value?: string | null;                                     // segmented (parameter)
}
interface WbElement {
  id: string; kind: string; name?: string; source?: Record<string, any>;
  columns?: WbColumn[]; order?: string[]; filters?: any[];
  sort?: Array<{ columnId: string; direction: 'ascending' | 'descending' }>;
  groupings?: Array<{ id: string; groupBy: string[]; calculations: string[];
    sort?: Array<{ columnId: string; direction: 'ascending' | 'descending' }> }>;
  rowsBy?: Array<{ id: string; sort?: { by: string; direction: 'ascending' | 'descending' } }>;
  columnsBy?: Array<{ id: string; sort?: { by: string; direction: 'ascending' | 'descending' } }>;
  values?: string[]; totals?: { showGrandTotals: 'shown' };
  xAxis?: { columnId: string; sort?: { by: string; direction: string } };                  // cartesian charts
  yAxis?: { columnIds: string[] };
  value?: { id?: string; columnId?: string };                                              // pie/donut {id} · kpi {columnId}
  color?: any; stacking?: string; orientation?: string;                                    // bar styling
  latitude?: { id: string }; longitude?: { id: string }; size?: { id: string };            // point-map / scatter
  region?: { id: string; regionType: string }; geography?: { id: string };                 // region-map / geography-map
  visibleAsSource?: boolean;                                                                // hidden grouped source (scatter)
  refMarks?: WbRefMark[];                                                                    // reference / baseline lines
  dataLabel?: { labels: string };                                                            // value labels (bar)
  legend?: { visibility?: 'shown' | 'hidden'; position?: 'top' | 'bottom' | 'left' | 'right' };
  style?: Record<string, any>;
  body?: string;
  mode?: string; options?: any[]; pageLabels?: Array<{ pageId: string; label: string }>;
  tabs?: Array<{ name: string }>;
  min?: string; max?: string; shape?: string;
  arrangement?: string; cardSize?: string; cardStyle?: Record<string, any>; noDataText?: string;
}
// A Sigma reference line. `value` MUST be the wrapped {type:formula,formula:"…"}
// form — a bare number 400s at POST. label.visibility must be 'shown' (not
// 'hidden') or it strips the label (matches qlik_refmarks, build-sigma-workbook.py).
interface WbRefMark {
  type: 'line';
  axis: 'axis' | 'series';
  value: { type: 'formula'; formula: string };
  line?: { color?: string; width?: number };
  label?: { visibility: 'shown'; text: string };
}
interface WbPage { id: string; name: string; visibility?: 'shown' | 'hidden'; }
export interface CognosReportResult {
  workbook: {
    name: string;
    document: {
      schemaVersion: number; kind: 'workbook'; pages: WbPage[];
      elements: Array<WbElement | WbControl>; layout: string;
      panels?: Array<Record<string, any>>;
      settings?: Record<string, any>;
    };
  };
  warnings: string[];
  stats: Record<string, number>;
  // Used only by the print converter to preserve Cognos page and element order;
  // never serialized into a posted workbook spec.
  lineage?: Array<{ elementId: string; pageId: string; source: any; kind: string; order: number; hiddenSource?: boolean }>;
}
export interface CognosReportOptions {
  dataModelId?: string;
  workbookName?: string;
  // DM metrics referenceable per query-subject element, keyed by the element's
  // Sigma display name (= sigmaDisplayName(subject), the `[Subject/…]` prefix). A
  // measure whose inline aggregate matches one binds to a governed [Metrics/<name>]
  // reference instead of re-deriving it inline. Absent → inline, byte-identical.
  metrics?: Record<string, BindMetric[]>;
  captureLineage?: boolean;
}

// ── ingest ────────────────────────────────────────────────────────────────────
interface DataItem { name: string; expression: string; aggregate?: string; dataType?: string; sort?: string; }
interface ProjectionFilter { item: DataItem; values: Array<string | number>; }
interface Query { name: string; subject: string; items: Map<string, DataItem>; filters: string[]; sourceGap?: string; projectionFilters?: ProjectionFilter[]; }
interface PromptMeta { options: string[]; def?: string; valueRefs: Record<string, string>; unsupported?: boolean; }

const outputOnly = new Set(['promptPages']);
function findAll(node: any, tag: string, out: any[] = [], stopAt: ReadonlySet<string> = outputOnly): any[] {
  if (node && typeof node === 'object') {
    for (const [k, v] of Object.entries(node)) {
      if (k === tag) arr(v).forEach((x) => out.push(x));
      if (stopAt.has(k)) continue;
      arr(v).forEach((x) => (x && typeof x === 'object') && findAll(x, tag, out, stopAt));
    }
  }
  return out;
}

// Nested data containers own their fields even when they reuse the same query.
const dataContainers = new Set(['list', 'singleton', 'crosstab', 'vizControl', 'repeater', 'repeaterTable']);
const findInDataScope = (node: any, tag: string): any[] => findAll(node, tag, [], dataContainers);

const xmlEsc = (s: string): string => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;')
  .replace(/</g, '&lt;').replace(/>/g, '&gt;');

/**
 * The current workbook representation has a flat document.elements collection.
 * Page ownership exists only in the authoritative document.layout XML, so every
 * emitted element (including hidden source tables and containers) is placed
 * exactly once. Pages themselves remain metadata-only.
 */
function buildAuthoritativeLayout(
  pages: WbPage[],
  byPage: Map<string, Array<WbElement | WbControl>>,
  containerChildren: Map<string, string[]>,
): string {
  const blocks = pages.map((page) => {
    const elements = byPage.get(page.id) || [];
    const nested = new Set([...containerChildren.values()].flat());
    const lines: string[] = [];
    let row = 1;
    for (let i = 0; i < elements.length; i++) {
      const element = elements[i] as WbElement;
      if (nested.has(element.id)) continue;
      const children = containerChildren.get(element.id);
      if (children?.length) {
        const height = Math.max(6, children.length * 11);
        const inner = children.map((id, n) =>
          `    <Element elementId="${xmlEsc(id)}" gridColumn="1 / 25" gridRow="${1 + n * 11} / ${1 + (n + 1) * 11}"/>`,
        ).join('\n');
        lines.push(`  <Container elementId="${xmlEsc(element.id)}" type="grid" gridColumn="1 / 25" gridRow="${row} / ${row + height}" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">\n${inner}\n  </Container>`);
        row += height;
        continue;
      }
      if (element.kind === 'page-break') {
        lines.push(`  <Element elementId="${xmlEsc(element.id)}" gridColumn="1 / 25" gridRow="${row} / ${row + 1}"/>`);
        row += 1;
        continue;
      }
      if (element.kind === 'kpi-chart') {
        const run: WbElement[] = [];
        let j = i;
        while (j < elements.length && !nested.has((elements[j] as WbElement).id)
          && (elements[j] as WbElement).kind === 'kpi-chart' && run.length < 4) {
          run.push(elements[j] as WbElement); j++;
        }
        const span = Math.floor(24 / run.length);
        run.forEach((kpi, n) => {
          const c0 = 1 + n * span;
          const c1 = n === run.length - 1 ? 25 : c0 + span;
          lines.push(`  <Element elementId="${xmlEsc(kpi.id)}" gridColumn="${c0} / ${c1}" gridRow="${row} / ${row + 6}"/>`);
        });
        row += 6; i = j - 1;
        continue;
      }
      const next = elements[i + 1] as WbElement | undefined;
      const isChart = element.kind.endsWith('-chart') && element.kind !== 'kpi-chart';
      const nextIsChart = !!next && !nested.has(next.id) && next.kind.endsWith('-chart') && next.kind !== 'kpi-chart';
      if (isChart && nextIsChart) {
        lines.push(`  <Element elementId="${xmlEsc(element.id)}" gridColumn="1 / 13" gridRow="${row} / ${row + 11}"/>`);
        lines.push(`  <Element elementId="${xmlEsc(next.id)}" gridColumn="13 / 25" gridRow="${row} / ${row + 11}"/>`);
        row += 11; i += 1;
        continue;
      }
      const height = element.kind === 'control' || element.kind === 'navigation' || element.kind === 'text'
        ? 3 : element.visibleAsSource === false ? 1 : 12;
      lines.push(`  <Element elementId="${xmlEsc(element.id)}" gridColumn="1 / 25" gridRow="${row} / ${row + height}"/>`);
      row += height;
    }
    return `<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="${xmlEsc(page.id)}">\n${lines.join('\n')}\n</Page>`;
  });
  return `<?xml version="1.0" encoding="utf-8"?>\n${blocks.join('\n')}`;
}

// ── convert ─────────────────────────────────────────────────────────────────
export function convertCognosReportToSigma(xml: string, options: CognosReportOptions = {}): CognosReportResult {
  resetIds();
  const warnings: string[] = [];
  const validity = XMLValidator.validate(xml);
  if (validity !== true) throw new Error(`invalid Cognos report XML at line ${validity.err.line}, column ${validity.err.col}: ${validity.err.code}`);
  const parsed = xmlParser.parse(xml);
  const report = parsed.report || parsed;
  const reportName = txt(report.reportName) || options.workbookName || 'Cognos Report';

  // 1) queries → dataItem maps. Track the dominant model subject per query.
  const queries = new Map<string, Query>();
  const queryNodes = new Map<string, any>();
  const duplicateQueries = new Set<string>();
  for (const q of findAll(report.queries || report, 'query')) {
    const name = q['@_name'] || 'query';
    if (queryNodes.has(name)) duplicateQueries.add(name);
    queryNodes.set(name, q);
    const items = new Map<string, DataItem>();
    let subject = '';
    for (const di of findAll(q, 'dataItem')) {
      const dn = di['@_name']; if (!dn) continue;
      const expr = txt(di.expression);
      // RS_dataType XMLAttribute (1=int, 2=decimal, 3=string …) — used to detect
      // numeric dimensions that need a categorical (Text) axis binding.
      const dataType = findAll(di, 'XMLAttribute').find((x: any) => x['@_name'] === 'RS_dataType')?.['@_value'];
      items.set(dn, { name: dn, expression: expr, aggregate: di['@_aggregate'], dataType, sort: di['@_sort'] });
      const m = expr.match(/\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]\.\[[^\]]+\]/); // [C].[Module].[Subject].[Col]
      if (m && !subject) subject = m[1];
    }
    // Cognos keeps disabled predicates in the XML with use="prohibited".
    const activeFilters = findAll(q, 'detailFilter').filter((f) => f['@_use'] !== 'prohibited');
    const filterNodes = activeFilters.filter((f) => f['@_use'] == null || f['@_use'] === 'required');
    if (activeFilters.length !== filterNodes.length) {
      warnings.push(`query "${name}": optional or unknown detail filter usage needs runtime selection/omission semantics - re-create as a Sigma filter before claiming parity.`);
    }
    const filters = filterNodes.map((f: any) => txt(f.filterExpression || f.expression)).filter(Boolean);
    if (filterNodes.length !== filters.length) {
      warnings.push(`query "${name}": ${filterNodes.length - filters.length} structured or empty detail filter(s) have no expression — re-create as Sigma filters; no unfiltered output is parity-verified.`);
    }
    const dependencies = [...new Set(findAll(q.source, 'queryRef').map((ref) => ref['@_refQuery']).filter(Boolean))];
    const operations = ['joinOperation', 'queryOperation'].filter((tag) => findAll(q.source, tag).length);
    const sourceGap = dependencies.length || operations.length
      ? `query dependency on ${dependencies.map((ref) => `"${ref}"`).join(', ') || '(unspecified queries)'}${operations.length ? ` via ${operations.join(', ')}` : ''} is not converted; preserve its joins, filters and grain before binding a Sigma source.`
      : undefined;
    queries.set(name, { name, subject: sourceGap ? '' : subject, items, filters, sourceGap });
  }

  // Inline only detail-grain aliases. An aggregate/distinct/optional predicate at
  // any upstream stage needs an actual query boundary, not a flattened source.
  type Projection = { subject: string; items: Map<string, DataItem>; filters: ProjectionFilter[] };
  const projections = new Map<string, Projection | null>();
  const resolving = new Set<string>();
  const resolveProjection = (name: string): Projection | null => {
    if (projections.has(name)) return projections.get(name)!;
    if (resolving.has(name) || duplicateQueries.has(name)) return null;
    const q = queries.get(name), node = queryNodes.get(name);
    if (!q || !node) return null;
    resolving.add(name);
    // Cache a refusal until the entire projection and every predicate prove safe.
    projections.set(name, null);
    try {
      const allowed = new Set(['@_name', '@_autoGroupAndSummarize', '@_distinct', 'source', 'selection', 'detailFilters', 'summaryFilters']);
      if (Object.keys(node).some((key) => !allowed.has(key)) ||
          ['@_distinct', '@_autoGroupAndSummarize'].some((key) => node[key] != null && !['false', '0'].includes(String(node[key])))) return null;
      const sourceKeys = Object.keys(node.source || {});
      const base = sourceKeys.length === 1 && sourceKeys[0] === 'model';
      const ref = node.source?.queryRef;
      if (!base && !(sourceKeys.length === 1 && sourceKeys[0] === 'queryRef' && typeof ref?.['@_refQuery'] === 'string')) return null;
      if (base ? Object.keys(node.source.model || {}).length > 0 : Object.keys(ref).some((key) => key !== '@_refQuery')) return null;
      const upstream = base ? null : resolveProjection(ref['@_refQuery']);
      if (!base && !upstream) return null;
      if (Object.keys(node.selection || {}).some((key) => key !== 'dataItem')) return null;
      if (arr(node.selection?.dataItem).length !== q.items.size || !q.items.size) return null;
      if (findAll(node, 'summaryFilter').some((f) => f['@_use'] !== 'prohibited')) return null;
      const items = new Map<string, DataItem>();
      const names = new Set<string>();
      let subject = upstream?.subject || '';
      let modelPath = '';
      for (const di of arr(node.selection?.dataItem)) {
        const item = q.items.get(di['@_name'])!;
        if (Object.keys(di).some((key) => !['@_name', '@_aggregate', '@_rollupAggregate', 'expression', 'XMLAttributes'].includes(key)) ||
            di['@_aggregate'] !== 'none' ||
            [di['@_aggregate'], di['@_rollupAggregate']].some((value) => value != null && value !== 'none')) return null;
        const display = sigmaDisplayName(item.name).toLowerCase();
        if (names.has(display)) return null;
        names.add(display);
        if (base) {
          const modelRef = item.expression.match(/^\s*\[([^\]]+)\]\.\[([^\]]+)\]\.\[([^\]]+)\]\.\[([^\]]+)\]\s*$/);
          if (!modelRef) return null;
          const path = JSON.stringify(modelRef.slice(1, 4));
          if (modelPath && modelPath !== path) return null;
          modelPath = path;
          subject = modelRef[3];
          items.set(item.name, { ...item });
        } else {
          const alias = item.expression.match(/^\s*\[([^\]]+)\]\.\[([^\]]+)\]\s*$/);
          const original = alias && alias[1] === ref['@_refQuery'] ? upstream!.items.get(alias[2]) : undefined;
          if (!original) return null;
          items.set(item.name, { ...item, expression: original.expression, dataType: item.dataType ?? original.dataType });
        }
      }
      const filters = [...(upstream?.filters || [])];
      for (const f of findAll(node, 'detailFilter')) {
        if (f['@_use'] === 'prohibited') continue;
        if (f['@_use'] != null && f['@_use'] !== 'required') return null;
        if (Object.keys(f).some((key) => !['@_use', 'filterExpression', 'expression'].includes(key))) return null;
        const expression = txt(f.filterExpression || f.expression);
        const match = expression.match(/^\s*\[([^\]]+)\]\s*=\s*([\s\S]+?)\s*$/) ||
          expression.match(/^\s*\[([^\]]+)\]\s+in\s*\(([\s\S]*?)\)\s*$/i);
        const item = match && items.get(match[1]);
        if (!match || !item) return null;
        const isList = /^\s*\[[^\]]+\]\s+in\b/i.test(expression);
        const values = filterLiterals(match[2], isList);
        if (!values) return null;
        filters.push({ item, values });
      }
      const result = { subject, items, filters };
      projections.set(name, result);
      return result;
    } finally {
      resolving.delete(name);
    }
  };
  for (const q of queries.values()) {
    if (!q.sourceGap) continue;
    const projection = resolveProjection(q.name);
    if (!projection) continue;
    q.subject = projection.subject;
    q.items = projection.items;
    q.projectionFilters = projection.filters;
    q.filters = [];
    q.sourceGap = undefined;
  }

  // A filtered join leg must remain a query boundary. Never turn a many-match
  // equijoin into a lookup or push right-side filters after an outer join.
  const joinPlans = new Map<string, { left: Projection; right: Projection; leftName: string; rightName: string;
    columns: Array<{ left: string; right: string }>; joinType: string; source?: Record<string, any> }>();
  for (const q of queries.values()) {
    if (!q.sourceGap || duplicateQueries.has(q.name)) continue;
    const node = queryNodes.get(q.name), op = node.source?.joinOperation;
    if (!op || Object.keys(node.source).length !== 1 ||
        Object.keys(node).some((key) => !['@_name', 'source', 'selection', 'detailFilters', 'summaryFilters'].includes(key)) ||
        Object.keys(op).some((key) => !['@_joinType', 'joinOperands', 'joinFilter'].includes(key))) continue;
    const joinType = ({ inner: 'inner', leftOuter: 'left-outer' } as Record<string, string>)[op['@_joinType'] || 'inner'];
    const operands = arr(op.joinOperands?.joinOperand);
    if (!joinType || operands.length !== 2 || Object.keys(op.joinOperands).some((key) => key !== 'joinOperand') ||
        operands.some((o) => Object.keys(o).some((key) => !['@_cardinality', 'queryRef'].includes(key)) ||
          (o['@_cardinality'] != null && !['1:1', '1:N', '1:n'].includes(o['@_cardinality'])) ||
          Object.keys(o.queryRef || {}).length !== 1 || !o.queryRef?.['@_refQuery'])) continue;
    const [leftRef, rightRef] = operands.map((o) => o.queryRef['@_refQuery']);
    if (leftRef === rightRef) continue;
    const left = resolveProjection(leftRef), right = resolveProjection(rightRef);
    if (!left || !right || ['detailFilter', 'summaryFilter'].some((tag) => findAll(node, tag).some((f) => f['@_use'] !== 'prohibited'))) continue;
    if (Object.keys(op.joinFilter || {}).length !== 1 || typeof op.joinFilter?.filterExpression !== 'string') continue;
    const columns: Array<{ left: string; right: string }> = [];
    for (const term of op.joinFilter.filterExpression.split(/\s+and\s+/i)) {
      const pair = term.match(/^\s*\[([^\]]+)\]\.\[([^\]]+)\]\s*=\s*\[([^\]]+)\]\.\[([^\]]+)\]\s*$/);
      if (!pair) { columns.length = 0; break; }
      const [, a, x, b, y] = pair;
      const keys = a === leftRef && b === rightRef ? [x, y] : a === rightRef && b === leftRef ? [y, x] : [];
      if (!left.items.has(keys[0]) || !right.items.has(keys[1])) { columns.length = 0; break; }
      columns.push({ left: `[${sigmaDisplayName(keys[0])}]`, right: `[${sigmaDisplayName(keys[1])}]` });
    }
    if (!columns.length || Object.keys(node.selection || {}).some((key) => key !== 'dataItem') ||
        arr(node.selection?.dataItem).length !== q.items.size || !q.items.size) continue;
    const leftName = `Query ${joinPlans.size + 1} Left`, rightName = `Query ${joinPlans.size + 1} Right`;
    const items = new Map<string, DataItem>(), names = new Set<string>();
    for (const di of arr(node.selection.dataItem)) {
      const item = q.items.get(di['@_name'])!, alias = item.expression.match(/^\s*\[([^\]]+)\]\.\[([^\]]+)\]\s*$/);
      if (!alias) break;
      const original = alias[1] === leftRef ? left.items.get(alias[2]) : alias[1] === rightRef ? right.items.get(alias[2]) : undefined;
      const display = sigmaDisplayName(item.name).toLowerCase();
      if (!original || names.has(display) || di['@_aggregate'] !== 'none' ||
          (di['@_rollupAggregate'] != null && di['@_rollupAggregate'] !== 'none') ||
          Object.keys(di).some((key) => !['@_name', '@_aggregate', '@_rollupAggregate', 'expression', 'XMLAttributes'].includes(key))) break;
      names.add(display);
      items.set(item.name, { ...item, expression: `[${alias[1] === leftRef ? leftName : rightName}].[${sigmaDisplayName(original.name)}]`,
        dataType: item.dataType ?? original.dataType });
    }
    if (items.size !== q.items.size) continue;
    joinPlans.set(q.name, { left, right, leftName, rightName, columns, joinType });
    q.items = items;
    q.filters = [];
    q.sourceGap = undefined;
  }

  // 1b) prompt metadata — value set + default from the report's own widgets:
  // <selectValue parameter="pX"> gives the option list + default selection;
  // customControl button configs ("Parameter"/"Button label"/"Button value") give
  // an explicit option→model-column mapping for swap-measure macros.
  const prompts = new Map<string, PromptMeta>();
  // Prompt pages supply control metadata, never printable visuals or pages.
  for (const sv of findAll(report, 'selectValue', [], new Set())) {
    const p = sv['@_parameter']; if (!p) continue;
    const meta = prompts.get(p) || { options: [], valueRefs: {} };
    if (sv['@_multiSelect'] === 'true' || sv['@_cascadeOn'] || sv['@_refQuery']) meta.unsupported = true;
    for (const o of findAll(sv, 'selectOption')) {
      const v = o['@_useValue'];
      if (v && !meta.options.includes(v)) meta.options.push(v);
    }
    const d = txt(findAll(sv, 'defaultSimpleSelection')[0]);
    if (d && meta.def == null) meta.def = d;
    prompts.set(p, meta);
  }
  for (const tag of ['selectWithSearch', 'textBox']) {
    for (const widget of findAll(report, tag, [], new Set())) {
      const p = widget['@_parameter']; if (!p) continue;
      const meta = prompts.get(p) || { options: [], valueRefs: {} };
      meta.unsupported = true;
      prompts.set(p, meta);
    }
  }
  for (const cc of findAll(report, 'customControl', [], new Set())) {
    try {
      const cfg = JSON.parse(txt(cc.configuration));
      const p = cfg?.['Parameter'];
      if (p && cfg['Button label'] && cfg['Button value']) {
        const meta = prompts.get(p) || { options: [], valueRefs: {} };
        meta.valueRefs[cfg['Button label']] = String(cfg['Button value']);
        if (!meta.options.includes(cfg['Button label'])) meta.options.push(cfg['Button label']);
        prompts.set(p, meta);
      }
    } catch { /* non-JSON customControl config — ignore */ }
  }

  // Prompts → Sigma SEGMENTED controls (parameters). Wired by controlId — element
  // formulas reference `[<promptName>]`, which Sigma resolves against `controlId`
  // (NOT the display name). A bare `list` control with no value source is unusable
  // as a scalar (beads-sigma-fh4u) — segmented + explicit manual values is the
  // verified working shape.
  const controls = new Map<string, WbControl>();
  const registerPrompt = (p: string) => {
    if (controls.has(p)) return;
    const meta = prompts.get(p);
    const ctrl: WbControl = {
      id: sigmaShortId(), kind: 'control', controlId: p, name: sigmaDisplayName(p),
      controlType: 'segmented',
      source: { kind: 'manual', valueType: 'text', values: [...(meta?.options || [])], labels: (meta?.options || []).map(() => null) },
      value: meta?.def ?? meta?.options?.[0] ?? null,
    };
    if (!meta?.options?.length) {
      warnings.push(`prompt '${p}': no <selectValue> options found in the report — emitted an empty segmented control; add its values in Sigma.`);
    }
    controls.set(p, ctrl);
  };

  // Translate a bare Cognos model ref string ([C].[Module].[Subject].[Col] or
  // [Subject].[Col]) to a Sigma [Subject/Col] ref — used by the macro expansion.
  const translateModelRef = (ref: string): string => ref
    .replace(/\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]\.\[([^\]]+)\]/g, (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`)
    .replace(/\[([^\]/]+)\]\.\[([^\]]+)\]/g, (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`);

  // expression translation: model refs + dataItem cross-refs + prompts + macros, then the DSL.
  const translate = (expr: string, q: Query): { formula: string; warns: string[] } => {
    const warns: string[] = [];
    let f = (expr || '').trim();

    // Cognos report MACRO ( # … # ) — dynamic SQL/column building (e.g. prompt-driven
    // measure swap). Translated to control + Switch when the prompt's value set is
    // recoverable from the report; otherwise flagged (never faked).
    if (f.startsWith('#') || /#\s*sql\s*\(|'token'/.test(f)) {
      const norm = (s: string) => s.replace(/[\s'"]+/g, '');
      // Pattern A — token swap with a default column:  # prompt('p','token','<colRef>') #
      const mA = f.match(/^#\s*prompt\(\s*'([^']+)'\s*,\s*'token'\s*(?:,\s*'([^']*)')?\s*\)\s*#$/s);
      if (mA) {
        const [, p, defRef] = mA;
        registerPrompt(p);
        const meta = prompts.get(p);
        const defaultFormula = defRef ? translateModelRef(defRef) : undefined;
        // Which option IS the macro default? (its branch becomes the Switch fallback)
        const defaultOption = defRef && meta
          ? Object.keys(meta.valueRefs).find((k) => norm(meta.valueRefs[k]) === norm(defRef))
          : undefined;
        const branches: string[] = [];
        for (const opt of meta?.options || []) {
          if (opt === defaultOption) continue;
          // option → column ref: explicit customControl mapping first, then a
          // same-named dataItem in this query (its expression is the model ref).
          let refFormula = meta!.valueRefs[opt] ? translateModelRef(meta!.valueRefs[opt]) : undefined;
          if (!refFormula) {
            const di = q.items.get(opt) || [...q.items.values()].find((d) => d.name.toLowerCase() === opt.toLowerCase());
            if (di && !di.expression.trim().startsWith('#')) refFormula = translateModelRef(di.expression.trim());
          }
          if (refFormula) branches.push(`"${opt}", ${refFormula}`);
          else warns.push(`prompt '${p}' option "${opt}" could not be mapped to a model column — left out of the Switch; add the branch manually.`);
        }
        if (defaultFormula && branches.length) {
          return { formula: `Switch([${p}], ${branches.join(', ')}, ${defaultFormula})`, warns };
        }
        if (defaultFormula) {
          warns.push(`prompt '${p}': no swap options resolved — emitted only the macro's default column.`);
          return { formula: defaultFormula, warns };
        }
      }
      // Pattern B — column ref built by string concat:  # '<prefix' + prompt('p','token') + 'suffix]' #
      const mB = f.match(/^#\s*'([^']*)'\s*\+\s*prompt\(\s*'([^']+)'\s*,\s*'token'\s*\)\s*\+\s*'([^']*)'\s*#$/s);
      if (mB) {
        const [, pre, p, suf] = mB;
        registerPrompt(p);
        const meta = prompts.get(p);
        if (meta?.options?.length) {
          const def = meta.def && meta.options.includes(meta.def) ? meta.def : meta.options[meta.options.length - 1];
          const branches = meta.options.filter((o) => o !== def).map((o) => `"${o}", ${translateModelRef(pre + o + suf)}`);
          const defaultFormula = translateModelRef(pre + def + suf);
          return { formula: branches.length ? `Switch([${p}], ${branches.join(', ')}, ${defaultFormula})` : defaultFormula, warns };
        }
        warns.push(`dataItem builds a column ref from prompt '${p}' but the report carries no option list for it — emitted a placeholder.`);
        return { formula: `/* MACRO — manual: ${f.slice(0, 60)} */`, warns };
      }
      // Anything else (#sql(), multi-prompt concat, …) — flag, never fake.
      const promptName = (f.match(/prompt\(\s*'([^']+)'/) || [])[1];
      if (promptName) registerPrompt(promptName);
      warns.push(`dataItem uses a Cognos macro (#…#${promptName ? `, prompt '${promptName}'` : ''}) that builds the column/SQL at runtime — model it in Sigma as a control + Switch([Control], …). Emitted a placeholder.`);
      return { formula: promptName ? `Switch([${promptName}] /* map prompt tokens to columns */)` : `/* MACRO — manual: ${f.slice(0, 60)} */`, warns };
    }

    // model column ref → [Subject/Col]   (resolves against the migrated DM element)
    f = f.replace(/\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]\.\[([^\]]+)\]/g,
      (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`);
    // shorter model ref [Subject].[Col]
    f = f.replace(/\[([^\]]+)\]\.\[([^\]]+)\]/g, (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`);
    // dataItem cross-refs [Other Item] → [Other Item] (sibling column; keep display name)
    f = f.replace(/\[([^\]\/]+)\]/g, (whole, nm) => (q.items.has(nm) ? `[${sigmaDisplayName(nm)}]` : whole));
    // prompt('p') standalone → control ref. Sigma resolves control refs by
    // controlId, so emit the raw prompt name (the controlId), NOT the display name.
    f = f.replace(/prompt\(\s*'([^']+)'[^)]*\)/g, (_m, p) => { registerPrompt(p); return `[${p}]`; });

    // hand off arithmetic / aggregate / if / date DSL to the shared translator
    const dsl = translateCognosExpr(f, { identifier: q.subject || 'Q', items: [] } as unknown as CognosQuerySubject,
      () => '', {} as any);
    dsl.warnings.forEach((w) => warns.push(w));
    return { formula: dsl.formula, warns };
  };

  // Cognos dataFormat → nearest Sigma column format. Scaled currency patterns
  // ($###.#M, scale -6 etc.) map to d3 SI-prefix ('s') strings — the value renders
  // with the magnitude suffix Sigma picks (k/M/B), the closest native analog.
  const formatFromNode = (node: any): Record<string, any> | undefined => {
    const cf = findAll(node, 'currencyFormat')[0];
    const pf = findAll(node, 'percentFormat')[0];
    const nf = findAll(node, 'numberFormat')[0];
    const dec = (x: any, d: number) => (x?.['@_decimalSize'] != null ? Number(x['@_decimalSize']) : d);
    const scaled = (x: any) => x?.['@_scale'] != null || /[KMB]/.test(String(x?.['@_pattern'] || ''));
    if (cf) return { kind: 'number', formatString: scaled(cf) ? `$,.${dec(cf, 1) + 2}s` : `$,.${dec(cf, 2)}f` };
    if (pf) return { kind: 'number', formatString: `,.${dec(pf, 0)}%` };
    if (nf) return { kind: 'number', formatString: scaled(nf) ? `$,.${dec(nf, 1) + 2}s` : `,.${dec(nf, 2)}f` };
    return undefined;
  };

  const reportPages = findAll(report.layouts || report, 'reportPage').concat(findAll(report.layouts || report, 'page'));
  if (!reportPages.length && findAll(report.layouts || report, 'promptPages').length) {
    throw new Error('Cognos report has no output pages; prompt pages cannot become a workbook or printable fallback.');
  }
  const pageNodes = reportPages.length ? reportPages : [{ '@_name': 'Report' }];
  const pages: WbPage[] = pageNodes.map((p) => ({
    id: sigmaShortId(),
    name: p['@_name'] || 'Report',
  }));
  const pageIdBySourceNode = new WeakMap<object, string>();
  const sourceOrder = new WeakMap<object, number>();
  let sourceOrdinal = 0;
  const indexLayout = (node: any) => {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) { node.forEach(indexLayout); return; }
    if (!sourceOrder.has(node)) sourceOrder.set(node, sourceOrdinal++);
    Object.values(node).forEach(indexLayout);
  };
  if (options.captureLineage) pageNodes.forEach(indexLayout);
  pageNodes.forEach((pageNode, i) => {
    if (!pageNode || typeof pageNode !== 'object') return;
    for (const tag of ['singleton', 'list', 'crosstab', 'vizControl', 'pageBreak', 'repeater', 'repeaterTable', 'block']) {
      for (const node of findAll(pageNode, tag)) {
        if (node && typeof node === 'object') pageIdBySourceNode.set(node, pages[i].id);
      }
    }
  });
  const elementsByPage = new Map<string, Array<WbElement | WbControl>>(pages.map((p) => [p.id, []]));
  const elementsBySourceNode = new WeakMap<object, WbElement[]>();
  const lineage: NonNullable<CognosReportResult['lineage']> = [];
  const containerChildren = new Map<string, string[]>();
  const lists = findAll(report, 'list');
  const pageEls: WbElement[] = [];
  const addToPage = (pageId: string, element: WbElement | WbControl) => {
    elementsByPage.get(pageId)!.push(element);
    if ((element as WbElement).kind !== 'control') pageEls.push(element as WbElement);
  };
  const addElement = (sourceNode: any, element: WbElement) => {
    const pageId = sourceNode && typeof sourceNode === 'object'
      ? pageIdBySourceNode.get(sourceNode) || pages[0].id : pages[0].id;
    addToPage(pageId, element);
    if (options.captureLineage && sourceNode && typeof sourceNode === 'object') {
      lineage.push({ elementId: element.id, pageId, source: sourceNode, kind: element.kind,
        order: sourceOrder.get(sourceNode) ?? 0, ...(element.visibleAsSource === false ? { hiddenSource: true } : {}) });
    }
    if (sourceNode && typeof sourceNode === 'object') {
      const current = elementsBySourceNode.get(sourceNode) || [];
      current.push(element);
      elementsBySourceNode.set(sourceNode, current);
    }
  };

  // Every element sources the migrated DM element. The converter emits the query
  // SUBJECT display name as the elementId placeholder — remap-wb-to-dm-ids.mjs
  // rewrites it to the real posted element id.
  const warnedSources = new Set<string>();
  let queryPage: WbPage | undefined;
  const dmSource = (q: Query) => {
    const join = joinPlans.get(q.name);
    if (join) {
      if (!join.source) {
        if (!queryPage) {
          queryPage = { id: sigmaShortId(), name: 'Query Sources', visibility: 'hidden' };
          pages.push(queryPage);
          elementsByPage.set(queryPage.id, []);
        }
        const legs = [join.left, join.right].map((projection, index) => {
          const legQuery: Query = { name: q.name, subject: projection.subject, items: projection.items, filters: [], projectionFilters: projection.filters };
          const columns = [...projection.items.values()].map((item) => ({ id: sigmaShortId(), name: sigmaDisplayName(item.name), formula: translate(item.expression, legQuery).formula }));
          const table: WbElement = { id: sigmaShortId(), kind: 'table', name: index ? join.rightName : join.leftName,
            source: { kind: 'data-model', dataModelId: options.dataModelId || '<DM_ID>', elementId: sigmaDisplayName(projection.subject) },
            columns, order: columns.map((c) => c.id) };
          applyQueryFilters(table, legQuery);
          addToPage(queryPage!.id, table);
          if (options.captureLineage) lineage.push({ elementId: table.id, pageId: queryPage!.id, source: {}, kind: 'table', order: 0, hiddenSource: true });
          return { kind: 'table', elementId: table.id };
        });
        join.source = { kind: 'join', name: join.leftName, primarySource: legs[0],
          joins: [{ left: legs[0], right: legs[1], name: join.rightName, joinType: join.joinType, columns: join.columns }] };
      }
      return join.source;
    }
    if (q.sourceGap && !warnedSources.has(q.name)) {
      warnings.push(`query "${q.name}": ${q.sourceGap}`);
      warnedSources.add(q.name);
    }
    return { kind: 'data-model', dataModelId: options.dataModelId || '<DM_ID — wire after posting the data model>', elementId: q.subject ? sigmaDisplayName(q.subject) : '<element>' };
  };
  if (findAll(report.layouts || report, 'masterDetailLink').length) {
    warnings.push('Cognos master-detail links are not converted; separate Sigma elements do not preserve parent/child row correlation. Re-author the keyed record layout before claiming parity.');
  }

  // Prefer a governed [Metrics/<name>] ref over an inline aggregate when it matches
  // a DM metric by formula equivalence. A list/crosstab/chart measure can reference
  // a column from a DIFFERENT subject than the query's own (e.g. Sum([Sales/rev]) on
  // a "Products Sales" query), so try the query subject first, then every subject in
  // the map — each attempt strips only its own [Subject/…] prefix, so only the one
  // matching the formula's actual prefix can bind (no cross-subject false positive).
  const bindMeasure = (formula: string, q: Query): string => {
    const map = options.metrics || {};
    const subjects = q.subject ? [sigmaDisplayName(q.subject), ...Object.keys(map)] : Object.keys(map);
    for (const s of subjects) {
      const out = metricRefOrInline(formula, s, map[s]);
      if (out !== formula) return out;
    }
    return formula;
  };

  // Per-query detail filters → Sigma element filters, applied to every element built
  // on that query (never silently dropped). Handles:
  //   [Col] = <literal>      → list filter, values:[literal]
  //   [Col] in (a, b, …)     → list filter, values:[a, b, …]
  //   [Col] = ?prompt?       → segmented control + boolean match column + list filter on [true]
  // Anything else stays a loud warning to re-create manually.
  const ensureFilterCol = (el: WbElement, q: Query, itemName: string): string | undefined => {
    const di = q.items.get(itemName);
    if (!di) return undefined;
    const want = sigmaDisplayName(di.name);
    const existing = (el.columns || []).find((c) => c.name === want);
    if (existing) return existing.id;
    const { formula, warns } = translate(di.expression, q);
    warns.forEach((w) => warnings.push(`"${q.name}.${itemName}": ${w}`));
    const id = sigmaShortId();
    // hidden + not in `order` — filter plumbing, not a display column
    (el.columns ||= []).push({ id, name: want, formula, hidden: true });
    return id;
  };
  const applyQueryFilters = (el: WbElement, q: Query) => {
    // Keep predicates bound to their original fields, not a downstream alias
    // that may reuse the same name for a different column.
    for (const [index, filter] of (q.projectionFilters || []).entries()) {
      const { formula } = translate(filter.item.expression, q);
      let name = `Query Filter ${index + 1}`;
      while ((el.columns || []).some((c) => c.name.toLowerCase() === name.toLowerCase()) ||
             [...q.items.keys()].some((key) => sigmaDisplayName(key).toLowerCase() === name.toLowerCase())) name += ' Filter';
      const id = sigmaShortId();
      (el.columns ||= []).push({ id, name, formula, hidden: true });
      (el.filters ||= []).push({ id: sigmaShortId(), columnId: id, kind: 'list', mode: 'include', values: [...filter.values] });
    }
    for (const fx of q.filters) {
      const m = fx.match(/^\s*\[([^\]]+)\]\s+(in)\s*\(([\s\S]*)\)\s*$/i) || fx.match(/^\s*\[([^\]]+)\]\s*(=)\s*([\s\S]+?)\s*$/);
      const fail = (why: string) => warnings.push(`filter "${fx.slice(0, 80)}" on query "${q.name}": ${why} — re-create as a Sigma element/page filter.`);
      if (!m) { fail('not a simple =/in filter'); continue; }
      const [, nm, op, rhs] = m;
      if (!q.items.has(nm)) { fail(`[${nm}] is not a dataItem in the query`); continue; }
      const colId = ensureFilterCol(el, q, nm);
      if (!colId) { fail('filter column could not be added'); continue; }
      const col = el.columns!.find((c) => c.id === colId)!;
      const textCol = /^Text\(/.test(col.formula);
      const prompt = rhs.trim().match(/^\?(\w+)\?$/);
      if (prompt && op === '=') {
        const p = prompt[1];
        if (prompts.get(p)?.unsupported || !prompts.get(p)?.options.length) {
          fail('prompt requires unresolved multi-value, cascading or dynamic choices');
          continue;
        }
        registerPrompt(p);
        const boolId = sigmaShortId();
        el.columns!.push({ id: boolId, name: `${col.name} = ${p}`, formula: `[${col.name}] = [${p}]`, hidden: true });
        (el.filters ||= []).push({ id: sigmaShortId(), columnId: boolId, kind: 'list', mode: 'include', values: [true] });
      } else {
        const values = filterLiterals(rhs, op.toLowerCase() === 'in');
        if (!values) { fail('unsupported prompt or non-literal comparison'); continue; }
        (el.filters ||= []).push({ id: sigmaShortId(), columnId: colId, kind: 'list', mode: 'include', values: textCol ? values.map(String) : values });
      }
    }
  };

  // 2a) singletons → kpi-chart elements (beads-sigma-ir3z: these are the KPI panel —
  // never drop them). Each <singleton refQuery><dataItemValue refDataItem> becomes a
  // Sigma kpi-chart whose value column is the dataItem's translated formula
  // (Sum-wrapped when row-level); sibling dataItems it references ([CYQRev]-[PYQRev])
  // are materialized as supporting columns on the same element.
  for (const sg of findAll(report, 'singleton')) {
    const qName = sg['@_refQuery'];
    const q = queries.get(qName);
    if (!q) { warnings.push(`<singleton> "${sg['@_name']}" refQuery="${qName}" has no matching query — skipped.`); continue; }
    const ref = findInDataScope(sg, 'dataItemValue').map((d: any) => d['@_refDataItem']).find(Boolean);
    const di = ref ? q.items.get(ref) : undefined;
    if (!di) { warnings.push(`<singleton> "${sg['@_name']}" has no resolvable dataItem ("${ref}") — skipped.`); continue; }

    const cols: WbColumn[] = [];
    const idByName = new Map<string, string>();
    const addKpiCol = (nm: string): string | undefined => {
      if (idByName.has(nm)) return idByName.get(nm);
      const d = q.items.get(nm);
      if (!d) return undefined;
      // sibling dataItems referenced by this expression first (so [X] refs resolve)
      for (const sm of d.expression.matchAll(/\[([^\]/.]+)\]/g)) {
        if (sm[1] !== nm && q.items.has(sm[1])) addKpiCol(sm[1]);
      }
      const { formula, warns } = translate(d.expression, q);
      warns.forEach((w) => warnings.push(`"${qName}.${nm}": ${w}`));
      // case-INSENSITIVE: translateCognosExpr re-derives bracket refs, which can
      // lowercase non-first words ([Cyq Rev] → [Cyq rev]); Sigma resolves refs
      // case-insensitively, but a case-sensitive check here would miss the sibling
      // and double-aggregate (Sum over a Sum column → error column).
      const referencesSibling = [...q.items.keys()].some((k) => k !== nm && formula.toLowerCase().includes(`[${sigmaDisplayName(k).toLowerCase()}]`));
      const hasAgg = /\b(Sum|Avg|Min|Max|Count|CountDistinct|Median)\s*\(/.test(formula);
      const id = sigmaShortId();
      // a row-level formula must aggregate to render as a single KPI value;
      // formulas over already-aggregated sibling columns stay as-is.
      cols.push({ id, name: sigmaDisplayName(nm), formula: bindMeasure(referencesSibling || hasAgg ? formula : `Sum(${formula})`, q) });
      idByName.set(nm, id);
      return id;
    };
    const valId = addKpiCol(ref)!;
    const fmt = formatFromNode(sg);
    if (fmt) cols.find((c) => c.id === valId)!.format = fmt;
    if (findAll(sg, 'conditionalStyleRef').length) {
      warnings.push(`singleton "${sg['@_name']}" (${ref}) uses conditional styling (e.g. up/down KPI icons) — not portable to a Sigma kpi-chart spec; the VALUE is preserved, re-create the icon rule manually.`);
    }
    const el: WbElement = {
      id: sigmaShortId(), kind: 'kpi-chart', name: di.name, source: dmSource(q),
      columns: cols, order: cols.map((c) => c.id), value: { columnId: valId },
    };
    applyQueryFilters(el, q);
    addElement(sg, el);
  }

  for (const L of lists) {
    const qName = L['@_refQuery'];
    if ([...dataContainers].some((tag) => findAll(L, tag).length)) {
      warnings.push(`list "${L['@_name'] || qName}": nested data container layout is not converted; child fields retain their own query scope, but separate Sigma elements do not reproduce the nested record.`);
    }
    const q = queries.get(qName);
    if (!q) { warnings.push(`<list> refQuery="${qName}" has no matching query — skipped.`); continue; }
    // Only listColumnBody defines displayed columns. Group headers and compound
    // cells can have additional dataItemValues that aren't separate columns.
    const colRefs: string[] = [];
    const layoutColumns = arr(L.listColumns?.listColumn);
    for (const lc of layoutColumns) {
      const body = findInDataScope(lc.listColumnBody || {}, 'dataItemValue')
        .map((d) => d['@_refDataItem']).filter(Boolean) as string[];
      if (!body.length) continue;
      colRefs.push(body[0]);
      if (new Set(body).size > 1) warnings.push(`list "${L['@_name'] || qName}": a visible column combines ${[...new Set(body)].join(', ')} — used ${body[0]} as the data column; reproduce the compound cell in Sigma.`);
    }
    // A list with explicit columns but no resolvable bodies must not silently
    // expand to every query item (often hidden/report-plumbing columns).
    if (layoutColumns.length && !colRefs.length) {
      warnings.push(`list "${L['@_name'] || qName}": no visible dataItemValue resolved from its listColumnBody — cannot emit a faithful table.`);
      continue;
    }
    const refs = colRefs.length ? colRefs : [...q.items.keys()];
    const columns: WbColumn[] = [];
    const AGG: Record<string, string> = { total: 'Sum', summary: 'Sum', aggregate: 'Sum', calculated: 'Sum', average: 'Avg', count: 'Count', maximum: 'Max', minimum: 'Min' };
    const sourceGroups = [...new Set(findInDataScope(L, 'listGroup')
      .map((g: any) => g['@_refDataItem']).filter(Boolean))] as string[];
    const visibleDims = refs.filter((ref) => {
      const item = q.items.get(ref);
      return item && (!item.aggregate || item.aggregate === 'none');
    });
    const detailGrain = visibleDims.some((ref) => /\b(?:call\s*id|transaction\s*id|row\s*id)\b/i.test(ref));
    if (detailGrain && sourceGroups.length) {
      warnings.push(`list "${L['@_name'] || qName}": row-level identifier (${visibleDims.filter((ref) => /\b(?:call\s*id|transaction\s*id|row\s*id)\b/i.test(ref)).join(', ')}) appears with Cognos group headers — keep row-grain measures rather than rolling them up again; verify the source PDF.`);
    }
    // Cognos lists auto-group: non-aggregate dataItems are the grain, aggregate
    // ('total'/'calculated'/…) dataItems are rolled up per group. Mirror that with a
    // Sigma grouped table (beads-sigma-0xlz): dims → groupBy, measures (Agg-wrapped)
    // → grouping calculations.
    const isMeasureItem = (d: DataItem) => !!d.aggregate && d.aggregate !== 'none';
    const grouped = !detailGrain && refs.some((r) => { const d = q.items.get(r); return d && isMeasureItem(d); })
      && (sourceGroups.length > 0 || refs.some((r) => { const d = q.items.get(r); return d && !isMeasureItem(d); }));
    const dimIds: string[] = [];
    const measureIds: string[] = [];
    const footerRefs: string[] = [];
    for (const r of refs) {
      const di = q.items.get(r);
      if (!di) {
        // layout aggregate/footer column, e.g. "Total(Revenue)" / "Summary(Revenue)" / "Average(Revenue)1"
        const m = r.match(/^(Total|Summary|Aggregate|Average|Count|Maximum|Minimum)\((.+?)\)\d*$/i);
        if (m && q.items.get(m[2])) {
          if (grouped) { footerRefs.push(r); continue; } // grand-total footer — see warning below
          columns.push({ id: sigmaShortId(), name: sigmaDisplayName(r), formula: `${AGG[m[1].toLowerCase()]}([${sigmaDisplayName(m[2])}])` });
          continue;
        }
        warnings.push(`list column "${r}" not found in query "${qName}" — skipped.`); continue;
      }
      const { formula, warns } = translate(di.expression, q);
      warns.forEach((w) => warnings.push(`"${qName}.${r}": ${w}`));
      const id = sigmaShortId();
      if (grouped && isMeasureItem(di)) {
        // beads-sigma-kvza: an unmapped Cognos aggregate must be LOUD, not a silent Sum.
        const _aggk = di.aggregate!.toLowerCase();
        if (!AGG[_aggk]) warnings.push(`list measure "${di.name}" (query "${qName}"): unmapped Cognos aggregate '${di.aggregate}' — defaulted to Sum (degraded); verify parity or add the mapping (refs/cognos-coverage.md).`);
        const fn = AGG[_aggk] || 'Sum';
        columns.push({ id, name: sigmaDisplayName(di.name), formula: bindMeasure(/^\s*(Sum|Avg|Min|Max|Count|CountDistinct)\s*\(/.test(formula) ? formula : `${fn}(${formula})`, q) });
        measureIds.push(id);
      } else {
        columns.push({ id, name: sigmaDisplayName(di.name), formula });
        if (grouped) dimIds.push(id);
      }
    }
    if (footerRefs.length) {
      warnings.push(`list "${qName}": footer total(s) ${footerRefs.join(', ')} — the grouped Sigma table already aggregates per group; add a grand-total via the table's totals UI (a duplicate Sum column would double-aggregate).`);
    }
    // conditional styles on list columns (e.g. threshold-driven $K/$M/$B data formats)
    // have no spec analog — never drop them silently.
    const condRefs = [...new Set(findInDataScope(L, 'conditionalStyleRef').map((c: any) => c['@_refConditionalStyle']).filter(Boolean))];
    if (condRefs.length) warnings.push(`list "${qName}" uses conditional style(s) ${condRefs.map((r) => `"${r}"`).join(', ')} — threshold-driven formats/styles aren't portable to the Sigma spec; set a column format (e.g. $,.3s) or conditional formatting in the UI.`);
    const el: WbElement = {
      id: sigmaShortId(), kind: 'table', name: `${q.subject ? sigmaDisplayName(q.subject) + ' — ' : ''}${qName}`,
      source: dmSource(q),
      columns, order: columns.map((c) => c.id),
    };
    const groupCols: string[] = [];
    for (const ref of sourceGroups) {
      const id = columns.find((c) => c.name === sigmaDisplayName(ref))?.id || ensureFilterCol(el, q, ref);
      if (id && !groupCols.includes(id)) groupCols.push(id);
      else if (!id) warnings.push(`list "${L['@_name'] || qName}": group key "${ref}" is not a query dataItem — grouping needs manual repair.`);
    }
    if (grouped && (groupCols.length || dimIds.length) && measureIds.length) {
      el.groupings = [{ id: sigmaShortId(), groupBy: [...new Set([...groupCols, ...dimIds])], calculations: measureIds }];
    } else if (sourceGroups.length && !detailGrain) {
      warnings.push(`list "${L['@_name'] || qName}": source group headers cannot be reproduced without an aggregate grouping — group keys were retained but review the presentation.`);
    }
    const sortItems = findAll(L.sortList || L.listSorts || {}, 'sortItem').filter((si: any) => si['@_refDataItem']);
    if (!sortItems.length) {
      for (const ref of refs) {
        const dir = q.items.get(ref)?.sort;
        if (dir) sortItems.push({ '@_refDataItem': ref, '@_sortOrder': dir });
      }
    }
    const sorts: NonNullable<WbElement['sort']> = [];
    for (const si of sortItems) {
      const ref = si['@_refDataItem'];
      const id = columns.find((c) => c.name === sigmaDisplayName(ref))?.id || ensureFilterCol(el, q, ref);
      if (!id) { warnings.push(`list "${L['@_name'] || qName}": sort key "${ref}" not in query — apply manually.`); continue; }
      const raw = String(si['@_sortOrder'] || si['@_direction'] || 'ascending').toLowerCase();
      sorts.push({ columnId: id, direction: raw.startsWith('desc') ? 'descending' : 'ascending' });
    }
    if (sorts.length && el.groupings) el.groupings[0].sort = sorts;
    else if (sorts.length) el.sort = sorts;
    applyQueryFilters(el, q);
    addElement(L, el);
  }

  // 2b) crosstabs → pivot-table elements (rows edge → rowsBy, columns edge → columnsBy, measure → values)
  const isTotal = (r: string) => /^(Total|Summary|Aggregate|Average|Count|Maximum|Minimum)\(/i.test(r || '');
  for (const X of findAll(report, 'crosstab')) {
    const qName = X['@_refQuery'];
    const q = queries.get(qName);
    if (!q) { warnings.push(`<crosstab> refQuery="${qName}" has no matching query — skipped.`); continue; }
    const edge = (subtree: any) => [...new Set(findAll(subtree || {}, 'crosstabNodeMember').map((m) => m['@_refDataItem']).filter((r) => r && !isTotal(r)))];
    const rowRefs = edge(X.crosstabRows);
    const colRefs = edge(X.crosstabColumns);
    let measRefs = [...new Set(findAll(X.crosstabCorner || {}, 'dataItemLabel').map((d) => d['@_refDataItem']).filter((r) => r && !isTotal(r)))];
    if (!measRefs.length) measRefs = [...q.items.keys()].filter((k) => !rowRefs.includes(k) && !colRefs.includes(k) && !isTotal(k));
    const cols: WbColumn[] = [];
    const AGG: Record<string, string> = { total: 'Sum', sum: 'Sum', summary: 'Sum', aggregate: 'Sum', average: 'Avg', avg: 'Avg', count: 'Count', countdistinct: 'CountDistinct', maximum: 'Max', minimum: 'Min' };
    const mk = (ref: string, agg: boolean): { id: string } | null => {
      const di = q.items.get(ref); if (!di) { warnings.push(`crosstab "${qName}" member "${ref}" not in query — skipped.`); return null; }
      const { formula, warns } = translate(di.expression, q); warns.forEach((w) => warnings.push(`"${qName}.${ref}": ${w}`));
      const id = sigmaShortId();
      let result = formula;
      if (agg) {
        const kind = String(di.aggregate || 'total').toLowerCase();
        const fn = AGG[kind];
        if (!fn) warnings.push(`crosstab "${qName}" measure "${ref}": aggregate '${di.aggregate}' is not mapped — left its formula for manual review (never silently Sum).`);
        else result = bindMeasure(/^\s*(Sum|Avg|Min|Max|Count|CountDistinct)\s*\(/.test(formula) ? formula : `${fn}(${formula})`, q);
      }
      cols.push({ id, name: sigmaDisplayName(di.name), formula: result });
      return { id };
    };
    // Keep each emitted edge paired with its source ref. A missing query item
    // must not shift subsequent members' sorts onto an earlier surviving edge.
    const makeEdges = (refs: string[]) => refs.flatMap((ref) => {
      const item = mk(ref, false);
      return item ? [{ ref, item }] : [];
    });
    const rowEdges = makeEdges(rowRefs), columnEdges = makeEdges(colRefs);
    const rowsBy = rowEdges.map(({ item }) => item);
    const columnsBy = columnEdges.map(({ item }) => item);
    // Finish values before resolving sort.by: Cognos can order an edge by a
    // measure, in which case it must target the AGGREGATED value column.
    const values = (measRefs.map((m) => mk(m, true)).filter(Boolean) as Array<{ id: string }>).map((o) => o.id);
    const addEdgeSorts = (subtree: any, edges: Array<{ ref: string; item: { id: string; sort?: { by: string; direction: 'ascending' | 'descending' } } }>) => {
      for (const { ref, item } of edges) {
        const member = findAll(subtree, 'crosstabNodeMember').find((m: any) => m['@_refDataItem'] === ref);
        const si = findAll(member?.sortList || {}, 'sortItem')[0];
        if (!si) continue;
        const byRef = si['@_refDataItem'] || ref;
        const by = cols.find((c) => c.name === sigmaDisplayName(byRef))?.id;
        if (!by) { warnings.push(`crosstab "${qName}" sort key "${byRef}" is not on an edge or a value — apply manually.`); continue; }
        const raw = String(si['@_sortOrder'] || si['@_direction'] || 'ascending').toLowerCase();
        item.sort = { by, direction: raw.startsWith('desc') ? 'descending' : 'ascending' };
      }
    };
    addEdgeSorts(X.crosstabRows, rowEdges);
    addEdgeSorts(X.crosstabColumns, columnEdges);
    // Sigma pivot: rowsBy/columnsBy are {id} objects, values are bare column-id strings.
    if (!values.length || (!rowsBy.length && !columnsBy.length)) warnings.push(`crosstab "${qName}" missing a measure or both edges — review the pivot.`);
    const el: WbElement = {
      id: sigmaShortId(), kind: 'pivot-table', name: `${q.subject ? sigmaDisplayName(q.subject) + ' — ' : ''}${qName} (crosstab)`,
      source: dmSource(q),
      columns: cols, order: cols.map((c) => c.id), rowsBy, columnsBy, values,
    };
    if (findAll(X.crosstabRows, 'crosstabNodeMember').some((m: any) => isTotal(m['@_refDataItem'])) ||
        findAll(X.crosstabColumns, 'crosstabNodeMember').some((m: any) => isTotal(m['@_refDataItem']))) {
      el.totals = { showGrandTotals: 'shown' };
    }
    applyQueryFilters(el, q);
    addElement(X, el);
  }

  // 2c) charts (RAVE2 <vizControl>) → Sigma chart elements
  // dataStore name → refQuery: vcDataSet.refDataStore → <reportDataStore name><dsV5ListQuery refQuery>
  const dsToQuery = new Map<string, string>();
  for (const ds of findAll(report, 'reportDataStore')) {
    const nm = ds['@_name'];
    const rq = findAll(ds, 'dsV5ListQuery').map((x: any) => x['@_refQuery']).find(Boolean);
    if (nm && rq) dsToQuery.set(nm, rq);
  }
  const ROLLUP_AGG: Record<string, string> = { total: 'Sum', sum: 'Sum', average: 'Avg', avg: 'Avg', count: 'Count', countdistinct: 'CountDistinct', maximum: 'Max', minimum: 'Min' };
  // Enumerated chart mappings and gated/no-analog fallbacks live in the
  // grounded workbook feature catalog (`workbook-features.ts`).
  const isMapViz = (t: string) => /tiledmap|choropleth|\bmap\b/.test(t);
  const chartSource = dmSource;

  // Cognos/RAVE2 sequential & diverging palette names → Sigma `scheme` arrays
  // (low→high). Mirrors qlik_color()'s scheme handling (build-sigma-workbook.py):
  // a by-MEASURE color needs an explicit low→high array, not a palette id.
  const COGNOS_SCHEME: Record<string, string[]> = {
    // sequential (single-hue ramps)
    blue: ['#deebf7', '#9ecae1', '#3182bd'], blues: ['#deebf7', '#9ecae1', '#3182bd'],
    green: ['#e5f5e0', '#a1d99b', '#31a354'], greens: ['#e5f5e0', '#a1d99b', '#31a354'],
    orange: ['#fee6ce', '#fdae6b', '#e6550d'], oranges: ['#fee6ce', '#fdae6b', '#e6550d'],
    red: ['#fee0d2', '#fc9272', '#de2d26'], reds: ['#fee0d2', '#fc9272', '#de2d26'],
    purple: ['#efedf5', '#bcbddc', '#756bb1'], heat: ['#ffffcc', '#fd8d3c', '#bd0026'],
    sequential: ['#ffffcc', '#fd8d3c', '#bd0026'],
    // diverging
    diverging: ['#a50026', '#f46d43', '#fee090', '#74add1', '#313695'],
    redblue: ['#a50026', '#f46d43', '#fee090', '#74add1', '#313695'],
    redgreen: ['#d73027', '#fee08b', '#1a9850'],
  };
  const SEQ_DEFAULT = COGNOS_SCHEME.sequential;
  // Resolve a Cognos color/palette signal to a Sigma scheme. Reads any palette
  // name the viz exposes (vizPropertyValues `*palette*`/`*scheme*` props, or a
  // refPaletteDefinition) → scheme array; falls back to the sequential default.
  const schemeFromSignal = (sig?: string): string[] => {
    const key = String(sig || '').toLowerCase().replace(/[^a-z]/g, '');
    for (const k of Object.keys(COGNOS_SCHEME)) if (key.includes(k)) return [...COGNOS_SCHEME[k]];
    return [...SEQ_DEFAULT];
  };
  // Pull a viz-level palette/scheme name out of a <vizControl>'s property values
  // (vizPropertyValues > vizProperty*Value name="…palette…"/"…scheme…") so a
  // by-measure color reproduces the source palette when the viz exposes one.
  const vizColorSignal = (V: any): string | undefined => {
    for (const pv of findAll(V, 'vizPropertyValues')) {
      for (const [, v] of Object.entries(pv)) {
        for (const p of arr(v)) {
          const nm = String(p?.['@_name'] || '');
          if (/palette|colou?r.?scheme|colou?rmodel/i.test(nm)) {
            const val = txt(p);
            if (val) return val;
          }
        }
      }
    }
    // refPaletteDefinition / refPalette attribute on a color slot or the viz
    const pal = (findAll(V, 'vcSlotData').map((s: any) => s['@_refPaletteDefinition'] || s['@_refPalette']).find(Boolean))
      || V['@_refPaletteDefinition'] || V['@_refPalette'];
    return pal ? String(pal) : undefined;
  };

  const legendFromViz = (V: any): WbElement['legend'] | undefined => {
    let seen = false;
    let visibility: 'shown' | 'hidden' | undefined;
    let position: 'top' | 'bottom' | 'left' | 'right' | undefined;
    for (const tag of ['vizPropertyBooleanValue', 'vizPropertyEnumValue', 'vizPropertyStringValue']) {
      for (const prop of findAll(V, tag)) {
        const name = String(prop['@_name'] || '');
        if (!/legend/i.test(name)) continue;
        seen = true;
        const value = String(prop['@_value'] ?? txt(prop)).toLowerCase();
        if (/visible|show|display/i.test(name)) visibility = /^(false|hidden|none|off|0)$/.test(value) ? 'hidden' : 'shown';
        if (/position|placement|location/i.test(name)) {
          const side = (['top', 'bottom', 'left', 'right'] as const).find((x) => value.includes(x));
          if (side) position = side;
        }
      }
    }
    return seen ? { ...(visibility ? { visibility } : {}), ...(position ? { position } : {}) } : undefined;
  };

  const styleFromNode = (node: any): Record<string, any> | undefined => {
    const css = findAll(node, 'CSS').map((x: any) => String(x['@_value'] || txt(x))).join(';');
    const style: Record<string, any> = {};
    const background = css.match(/background(?:-color)?\s*:\s*(#[0-9a-f]{3,8})/i)?.[1];
    if (background) style.backgroundColor = background;
    const radius = css.match(/border-radius\s*:\s*([^;]+)/i)?.[1]?.trim();
    if (radius && radius !== '0' && radius !== '0px') style.borderRadius = 'round';
    return Object.keys(style).length ? style : undefined;
  };

  // RAVE2 reference lines / baselines → Sigma refMarks. Cognos expresses these as
  // <baseline> (a.k.a. <vizBaseline>) nodes carrying either a static @_value (or
  // numeric text) or a @_refDataItem (a data-driven baseline = a measure ref), plus
  // optional @_label and @_color. X-axis baselines (refAxis="category"/"x") → Sigma
  // axis 'axis'; value/Y baselines → 'series'. value is wrapped {type:formula,…}
  // (a bare number 400s) and label.visibility is 'shown' — matches qlik_refmarks().
  const buildRefMarks = (V: any, q: Query, vizName: string): WbRefMark[] => {
    const nodes = [...findAll(V, 'baseline'), ...findAll(V, 'vizBaseline')];
    const out: WbRefMark[] = [];
    for (const b of nodes) {
      if (String(b['@_visible'] ?? b['@_show'] ?? 'true').toLowerCase() === 'false') continue;
      const onX = /^(category|categories|x|item|itemaxis)$/i.test(String(b['@_refAxis'] || b['@_axis'] || ''));
      const axis: WbRefMark['axis'] = onX ? 'axis' : 'series';
      let formula = '';
      const di = b['@_refDataItem'] ? q.items.get(b['@_refDataItem']) : undefined;
      if (di) {
        // data-driven baseline (e.g. "average of Revenue") → aggregated measure ref
        const { formula: f, warns } = translate(di.expression, q);
        warns.forEach((w) => warnings.push(`"${vizName}.baseline ${b['@_refDataItem']}": ${w}`));
        formula = /^\s*(Sum|Avg|Min|Max|Count|CountDistinct|Median)\s*\(/.test(f) ? f : `Avg(${f})`;
      } else {
        const v = b['@_value'] ?? b['@_position'] ?? txt(b.value) ?? txt(b);
        if (v != null && String(v).trim() !== '' && /^-?[\d.]+$/.test(String(v).trim())) formula = String(v).trim();
      }
      if (!formula) {
        warnings.push(`chart "${vizName}": a reference line / baseline had no static value or data-item measure — skipped (re-add it in the workbook).`);
        continue;
      }
      const rm: WbRefMark = {
        type: 'line', axis, value: { type: 'formula', formula },
        line: { color: String(b['@_color'] || b['@_lineColor'] || '#ef4444'), width: 2 },
      };
      const label = b['@_label'] || b['@_text'] || (di ? sigmaDisplayName(di.name) : undefined);
      if (label) rm.label = { visibility: 'shown', text: String(label) };
      out.push(rm);
    }
    return out;
  };

  for (const V of findAll(report, 'vizControl')) {
    const vizType = String(V['@_type'] || '').toLowerCase();
    const vizName = V['@_name'] || 'Chart';
    const dsName = findAll(V, 'vcDataSet').map((d: any) => d['@_refDataStore']).find(Boolean);
    const qName = dsName ? dsToQuery.get(dsName) : undefined;
    const q = qName ? queries.get(qName) : undefined;
    if (!q) { warnings.push(`<vizControl> "${vizName}" (${vizType}): no resolvable query (dataStore "${dsName}") — chart skipped.`); continue; }

    // slot entries by id (categories / series / values / size / x / y / color)
    const slot = (id: string): Array<{ ref: string; rollup?: string; sort?: string; format?: Record<string, any> }> => {
      const out: Array<{ ref: string; rollup?: string; sort?: string; format?: Record<string, any> }> = [];
      for (const sd of findAll(V, 'vcSlotData')) {
        if (String(sd['@_idSlot'] || '').toLowerCase() !== id) continue;
        for (const c of findAll(sd, 'vcSlotDsColumn')) if (c['@_refDsColumn']) {
          out.push({ ref: c['@_refDsColumn'], rollup: c['@_rollupMethod'], sort: c['@_dsSort'], format: formatFromNode(c) });
        }
      }
      return out;
    };
    const cols: WbColumn[] = [];
    const seen = new Map<string, string>();
    const addCol = (e: { ref: string; rollup?: string; format?: Record<string, any> } | undefined, measure: boolean, categorical = false): string | undefined => {
      if (!e) return undefined;
      const di = q.items.get(e.ref);
      if (!di) { warnings.push(`chart "${vizName}" column "${e.ref}" not in query "${qName}" — skipped.`); return undefined; }
      const nm = sigmaDisplayName(di.name);
      if (seen.has(nm)) return seen.get(nm);
      let { formula, warns } = translate(di.expression, q); warns.forEach((w) => warnings.push(`"${vizName}.${e.ref}": ${w}`));
      // A numeric dimension (e.g. Year, RS_dataType 1/2) bound to a category axis
      // renders as a continuous axis in Sigma — cast to Text so it binds categorically.
      if (categorical && !measure && (di.dataType === '1' || di.dataType === '2')) formula = `Text(${formula})`;
      const id = sigmaShortId();
      // beads-sigma-kvza: warn on an unmapped Cognos rollup (empty rollup -> Sum is the
      // documented default and is NOT a miss). Degraded Sum stays but is now loud.
      let fn = '';
      if (measure) {
        const _rk = String(e.rollup || '').toLowerCase();
        if (_rk && !ROLLUP_AGG[_rk]) warnings.push(`chart "${vizName}" measure "${nm}": unmapped Cognos rollup '${e.rollup}' — defaulted to Sum (degraded); verify parity (refs/cognos-coverage.md).`);
        fn = ROLLUP_AGG[_rk] || 'Sum';
      }
      const col: WbColumn = { id, name: nm, formula: measure ? bindMeasure(`${fn}(${formula})`, q) : formula };
      if (e.format) col.format = e.format;
      cols.push(col);
      seen.set(nm, id); return id;
    };

    const cats = slot('categories'), series = slot('series'), vals = slot('values');
    const sizes = slot('size'), xs = slot('x'), ys = slot('y'), colorSlot = slot('color');
    const kind = VIZ_KIND[vizType];

    // Progress/bullet/gauge visuals now have a native workbook-code element.
    // It has no source/columns of its own, so retain a hidden aggregate source
    // table and bind the progress formula to that table's display name.
    if (/progress|bullet|gauge/.test(vizType)) {
      const valueEntry = vals[0] || sizes[0] || ys[0];
      const valueId = addCol(valueEntry, true);
      const valueCol = cols.find((c) => c.id === valueId);
      if (!valueCol) {
        warnings.push(workbookGap('progress', `chart "${vizName}" had no resolvable value measure; no progress element was emitted.`));
        continue;
      }
      const sourceName = `${vizName} (progress source)`;
      const source: WbElement = {
        id: sigmaShortId(), kind: 'table', name: sourceName, source: chartSource(q),
        columns: cols, order: cols.map((c) => c.id), visibleAsSource: false,
      };
      const percent = valueEntry?.format?.formatString?.includes('%');
      const progress: WbElement = {
        id: sigmaShortId(), kind: 'progress', name: vizName,
        min: '0', max: percent ? '1' : '100',
        value: { columnId: valueId },
        mode: percent ? 'percent' : 'value', shape: /ring|radial|gauge/.test(vizType) ? 'ring' : 'bar',
      };
      // The progress schema's value is a formula string, not a column pointer.
      (progress as any).value = `[${sourceName}/${valueCol.name}]`;
      addElement(V, source);
      addElement(V, progress);
      continue;
    }

    // maps: Cognos tiledmap → Sigma point-map (lat/long slots) or region-map (named-location slots)
    if (isMapViz(vizType)) {
      const lat = slot('latlonglocations.latitude')[0] || slot('latitude')[0];
      const lon = slot('latlonglocations.longitude')[0] || slot('longitude')[0];
      const region = slot('locations')[0] || slot('location')[0];
      if (lat && lon) {
        const latId = addCol(lat, false), lonId = addCol(lon, false);
        const sizeId = addCol(slot('latlongsize')[0] || sizes[0], true);
        const colorId = addCol(slot('latlongcolor')[0] || colorSlot[0], true);
        const el: WbElement = { id: sigmaShortId(), kind: 'point-map', name: vizName, source: chartSource(q), columns: cols, order: [] };
        const legend = legendFromViz(V); if (legend) el.legend = legend;
        if (latId) el.latitude = { id: latId };
        if (lonId) el.longitude = { id: lonId };
        if (sizeId) el.size = { id: sizeId };
        if (colorId) el.color = { by: 'scale', column: colorId };
        el.order = cols.map((c) => c.id);
        if (!cols.length) { warnings.push(`<vizControl> map "${vizName}" had no resolvable lat/long columns — skipped.`); continue; }
        applyQueryFilters(el, q);
        addElement(V, el);
      } else if (region) {
        const regId = addCol(region, false);
        const colorId = addCol(slot('locationcolor')[0] || colorSlot[0] || slot('locationheight')[0], true);
        if (!regId) { warnings.push(`<vizControl> map "${vizName}" had no resolvable location column — skipped.`); continue; }
        const el: WbElement = { id: sigmaShortId(), kind: 'region-map', name: vizName, source: chartSource(q), columns: cols, order: cols.map((c) => c.id), region: { id: regId, regionType: 'country' } };
        const legend = legendFromViz(V); if (legend) el.legend = legend;
        if (colorId) el.color = { by: 'scale', column: colorId };
        warnings.push(`chart "${vizName}" → region-map: defaulted regionType to "country" — set it to match your data (country / us-state / us-county / us-zipcode / us-cbsa / us-postal-place / ca-province).`);
        applyQueryFilters(el, q);
        addElement(V, el);
      } else {
        // a map with neither coordinate nor named-location slots → table fallback
        for (const c of findAll(V, 'vcSlotDsColumn')) if (c['@_refDsColumn']) addCol({ ref: c['@_refDsColumn'], rollup: c['@_rollupMethod'] }, !!c['@_rollupMethod']);
        if (!cols.length) { warnings.push(`<vizControl> map "${vizName}" (${vizType}) had no resolvable columns — skipped.`); continue; }
        warnings.push(`chart "${vizName}" is a Cognos map (${vizType}) with no lat/long or named-location slot — emitted its data as a table; add geographic columns + a map in the workbook.`);
        const fb: WbElement = { id: sigmaShortId(), kind: 'table', name: `${vizName} (was map)`, source: chartSource(q), columns: cols, order: cols.map((c) => c.id) };
        const measures = cols.filter((c) => /^\s*(Sum|Avg|Min|Max|Count|CountDistinct)\s*\(/.test(c.formula)).map((c) => c.id);
        const dimensions = cols.filter((c) => !measures.includes(c.id)).map((c) => c.id);
        if (measures.length && dimensions.length) fb.groupings = [{ id: sigmaShortId(), groupBy: dimensions, calculations: measures }];
        applyQueryFilters(fb, q);
        addElement(V, fb);
      }
      continue;
    }

    if (!kind) {
      // no native Sigma chart → table fallback + flag (collect every slot column, incl. map latlong/etc.)
      const gated = VIZ_GATED[vizType];
      const label = gated || VIZ_NO_ANALOG[vizType] || vizType.replace('com.ibm.vis.', '');
      for (const c of findAll(V, 'vcSlotDsColumn')) if (c['@_refDsColumn']) addCol({ ref: c['@_refDsColumn'], rollup: c['@_rollupMethod'] }, !!c['@_rollupMethod']);
      if (!cols.length) { warnings.push(`<vizControl> "${vizName}" (${vizType}) had no resolvable columns — skipped.`); continue; }
      warnings.push(workbookGap(gated ? 'box-chart (workspace gated)' : `visual ${vizType}`,
        gated
          ? `chart "${vizName}" is a Cognos ${label}; Sigma box-chart is workspace-gated, so the converter preserved its data as a table instead of risking a masked entitlement failure. Enable and verify box-chart before replacing it.`
          : `chart "${vizName}" is a Cognos ${label}; no grounded Sigma mapping is cataloged. Its data was preserved as a table.`));
      const fb: WbElement = { id: sigmaShortId(), kind: 'table', name: `${vizName} (was ${label})`, source: chartSource(q), columns: cols, order: cols.map((c) => c.id) };
      const measures = cols.filter((c) => /^\s*(Sum|Avg|Min|Max|Count|CountDistinct)\s*\(/.test(c.formula)).map((c) => c.id);
      const dimensions = cols.filter((c) => !measures.includes(c.id)).map((c) => c.id);
      if (measures.length && dimensions.length) fb.groupings = [{ id: sigmaShortId(), groupBy: dimensions, calculations: measures }];
      applyQueryFilters(fb, q);
      addElement(V, fb);
      continue;
    }

    const el: WbElement = { id: sigmaShortId(), kind, name: vizName, source: chartSource(q), columns: [], order: [] };
    const legend = legendFromViz(V); if (legend) el.legend = legend;

    if (kind === 'pie-chart' || kind === 'donut-chart') {
      const colorId = addCol(cats[0] || colorSlot[0], false);
      const valId = addCol(vals[0] || sizes[0], true);
      if (colorId) el.color = { id: colorId };
      if (valId) el.value = { id: valId };
    } else if (kind === 'scatter-chart') {
      // A Cognos bubble/scatter is measure-vs-measure with the series/color slot as
      // the POINT identity. Sigma's scatter axes are a GROUPING axis: putting an
      // aggregate directly on xAxis evaluates it per source row and every point
      // collapses to the DM grain (verified Qlik-side, bead ry0n). Correct,
      // UI-verified shape: bind the scatter to a hidden grouped SOURCE table (one
      // row per point dim) and reference the grouped columns with RAW refs; the dim
      // stays on color:{by:category} so points don't merge.
      const dimSlot = series[0] || colorSlot[0];
      const xId = addCol(xs[0] || cats[0], true);                  // x measure (Sum-wrapped per point)
      const yId = addCol(ys[0] || vals[0] || sizes[0], true);      // y measure
      const dId = dimSlot ? addCol(dimSlot, false) : undefined;    // point identity (category)
      const szId = sizes[0] && sizes[0] !== (ys[0] || vals[0]) ? addCol(sizes[0], true) : undefined;
      if (xId && yId && dId) {
        // hidden grouped source: one row per dim, x/y(/size) aggregated.
        const grpId = sigmaShortId();
        const srcName = `${vizName} (scatter source)`;
        const src: WbElement = {
          id: sigmaShortId(), kind: 'table', name: srcName, source: chartSource(q),
          columns: cols, order: cols.map((c) => c.id),
          groupings: [{ id: grpId, groupBy: [dId], calculations: szId ? [xId, yId, szId] : [xId, yId] }],
          visibleAsSource: false,
        };
        applyQueryFilters(src, q);   // carry detail filters onto the source grain
        // scatter element: raw refs back to the grouped source columns by display name.
        const byId = new Map(cols.map((c) => [c.id, c]));
        const raw = (srcColId: string) => {
          const sc = byId.get(srcColId)!;
          return { id: sigmaShortId(), name: sc.name, formula: `[${srcName}/${sc.name}]` };
        };
        const sDim = raw(dId), sX = raw(xId), sY = raw(yId);
        const scols: WbColumn[] = [sDim, sX, sY];
        el.source = { kind: 'table', elementId: src.id, groupingId: grpId };
        el.xAxis = { columnId: sX.id };
        el.yAxis = { columnIds: [sY.id] };
        el.color = { by: 'category', column: sDim.id };
        if (szId) { const sSz = raw(szId); scols.push(sSz); el.size = { id: sSz.id }; }
        el.columns = scols; el.order = scols.map((c) => c.id);
        const sRefMarks = buildRefMarks(V, q, vizName);   // e.g. a target line at y=<value>
        if (sRefMarks.length) el.refMarks = sRefMarks;
        addElement(V, src);
        addElement(V, el);
        continue;   // self-contained: skip the shared el.columns=cols assignment below
      }
      // <2 measures or no category dim: fall back to a plain ungrouped scatter.
      if (xId) el.xAxis = { columnId: xId };
      if (yId) el.yAxis = { columnIds: [yId] };
      if (dId) el.color = { by: 'category', column: dId };
      const sRefMarks = buildRefMarks(V, q, vizName);
      if (sRefMarks.length) el.refMarks = sRefMarks;
    } else {
      // cartesian: bar / line / area / combo. The released waterfall schema
      // deliberately has no xAxis property; retain its category columns while
      // binding only the required yAxis.
      const xId = addCol(cats[0], false, true);
      if (xId && kind !== 'waterfall-chart') {
        el.xAxis = { columnId: xId };
        if (cats[0]?.sort) el.xAxis.sort = { by: xId, direction: /desc/i.test(cats[0].sort) ? 'descending' : 'ascending' };
      }
      if (cats.length > 1) { warnings.push(`chart "${vizName}": Cognos used ${cats.length} category levels; Sigma x-axis takes one — bound the first, kept the rest as columns.`); cats.slice(1).forEach((c) => addCol(c, false, true)); }
      const yIds = [...vals, ...sizes].map((v) => addCol(v, true)).filter(Boolean) as string[];
      if (yIds.length) el.yAxis = { columnIds: yIds };
      else warnings.push(`chart "${vizName}" (${kind}) resolved no measure for the value axis — add a measure in the workbook.`);
      // COLOR encoding. A `series` slot is always categorical (split-by). A `color`
      // slot can be EITHER: a dimension (by:category) OR a measure (rollupMethod set
      // ⇒ by:scale, a continuous color ramp). Cognos drives the cartesian color by
      // measure far more than the old by:'category'-always path admitted. A measure
      // can't sit on both yAxis and color, so — like qlik_color() — duplicate it into
      // a dedicated color column and read the source palette into a low→high scheme.
      const colorE = colorSlot[0];
      const colorIsMeasure = !series[0] && !!colorE && !!colorE.rollup && !!q.items.get(colorE.ref);
      if (colorIsMeasure) {
        const baseId = addCol(colorE, true);                 // the measure (may already be a yAxis col)
        const base = cols.find((c) => c.id === baseId);
        if (base) {
          const dupId = sigmaShortId();
          const dup: WbColumn = { id: dupId, name: `${base.name} (color)`, formula: base.formula };
          if (base.format) dup.format = base.format;
          cols.push(dup);
          el.color = { by: 'scale', column: dupId, scheme: schemeFromSignal(vizColorSignal(V)) };
        }
      } else {
        const cId = addCol(series[0] || colorE, false);
        if (cId) el.color = { by: 'category', column: cId };
      }
      const refMarks = buildRefMarks(V, q, vizName);
      if (refMarks.length) el.refMarks = refMarks;
      if (kind === 'bar-chart') {
        el.stacking = /stacked/.test(vizType) ? 'stacked' : 'none';
        if (/\bbar\b/.test(vizType) && !/column/.test(vizType)) el.orientation = 'horizontal'; // Cognos "bar" = horizontal
      }
      if (kind === 'combo-chart' && yIds.length > 1) warnings.push(`chart "${vizName}" → combo-chart: all measures placed on the primary axis as the same mark — set per-series shape / secondary axis in the workbook.`);
      if (kind === 'waterfall-chart' && cats.length > 1) {
        warnings.push(workbookGap('waterfall category hierarchy',
          `chart "${vizName}" has ${cats.length} Cognos category levels, but released waterfall-chart code exposes no xAxis hierarchy. All category columns were retained; verify the rendered step labels.`));
      }
    }

    el.columns = cols; el.order = cols.map((c) => c.id);
    if (!cols.length) { warnings.push(`<vizControl> "${vizName}" (${vizType}) had no resolvable slot columns — skipped.`); continue; }
    applyQueryFilters(el, q);
    addElement(V, el);
  }

  // Released non-chart workbook features.
  for (const pageBreak of findAll(report, 'pageBreak')) {
    addElement(pageBreak, { id: sigmaShortId(), kind: 'page-break' });
  }

  for (const drill of findAll(report, 'drillBehavior')) {
    if (!drill || typeof drill !== 'object' || Object.keys(drill).length === 0) continue;
    const id = sigmaShortId();
    addToPage(pages[0].id, {
      id, kind: 'control', controlId: `drill-${id}`, name: 'Drill',
      controlType: 'drill',
    } as WbControl);
  }
  for (const reportDrill of findAll(report, 'reportDrill')) {
    const name = reportDrill['@_name'] || 'unnamed report drill';
    const path = findAll(reportDrill, 'reportPath')[0]?.['@_path'];
    warnings.push(workbookGap('cross-report drill-through',
      `"${name}" targets ${path || 'another Cognos report'}. The released Sigma drill control is hierarchy drill, not cross-document navigation; wire a converted target page/document explicitly.`));
  }

  // Cognos repeaters become first-class repeated containers. The binding name
  // uses the data-model source element's display name, matching Sigma's derived
  // "<source name> repeated container" namespace.
  for (const repeater of [...findAll(report, 'repeater'), ...findAll(report, 'repeaterTable')]) {
    const qName = repeater['@_refQuery'];
    const q = queries.get(qName);
    if (!q) {
      warnings.push(workbookGap('repeater', `refQuery="${qName || '(missing)'}" has no matching query; repeater was not emitted.`));
      continue;
    }
    const refs = [...new Set(findInDataScope(repeater, 'dataItemValue').map((x: any) => x['@_refDataItem']).filter(Boolean))] as string[];
    const sourceName = `${repeater['@_name'] || qName} source`;
    const sourceColumns: WbColumn[] = refs.flatMap((ref) => {
      const di = q.items.get(ref);
      if (!di) return [];
      const translated = translate(di.expression, q);
      translated.warns.forEach((w) => warnings.push(`"${qName}.${ref}": ${w}`));
      return [{ id: sigmaShortId(), name: sigmaDisplayName(di.name), formula: translated.formula }];
    });
    const source: WbElement = {
      id: sigmaShortId(), kind: 'table', name: sourceName, source: dmSource(q),
      columns: sourceColumns, order: sourceColumns.map((c) => c.id), visibleAsSource: false,
    };
    applyQueryFilters(source, q);
    addElement(repeater, source);
    const rc: WbElement = {
      id: sigmaShortId(), kind: 'repeated-container', name: repeater['@_name'] || `${qName} repeater`,
      source: { kind: 'table', elementId: source.id }, arrangement: 'list', cardSize: 'small',
      noDataText: 'No rows', cardStyle: styleFromNode(repeater),
    };
    addElement(repeater, rc);
    const children: string[] = [];
    for (const ref of refs) {
      const di = q.items.get(ref);
      if (!di) continue;
      const child: WbElement = {
        id: sigmaShortId(), kind: 'text',
        body: `{{[${sourceName} repeated container/${sigmaDisplayName(di.name)}]}}`,
      };
      addElement(repeater, child);
      children.push(child.id);
    }
    if (children.length) containerChildren.set(rc.id, children);
    else warnings.push(workbookGap('repeater content',
      `"${rc.name}" had no resolvable dataItemValue children. The repeated-container shell was preserved, but its card content must be authored.`));
  }

  // Named Cognos blocks are semantic panels. Preserve panels that actually own
  // converted visual children; unnamed layout-only blocks remain structural
  // noise and are not emitted.
  const claimedPanelChildren = new Set<string>();
  for (const block of findAll(report, 'block')) {
    if (!block['@_name']) continue;
    const children: string[] = [];
    for (const tag of ['singleton', 'list', 'crosstab', 'vizControl', 'repeater', 'repeaterTable']) {
      for (const node of findAll(block, tag)) {
        for (const element of elementsBySourceNode.get(node) || []) {
          if (!claimedPanelChildren.has(element.id)) {
            children.push(element.id);
            claimedPanelChildren.add(element.id);
          }
        }
      }
    }
    if (!children.length) continue;
    const panel: WbElement = {
      id: sigmaShortId(), kind: 'container', name: sigmaDisplayName(block['@_name']),
      ...(styleFromNode(block) ? { style: styleFromNode(block) } : {}),
    };
    addElement(block, panel);
    containerChildren.set(panel.id, children);
  }

  // attach parameter controls to the first page. Controls remain ordinary flat
  // document elements; the layout is their sole page-membership authority.
  const controlEls = [...controls.values()];
  controlEls.forEach((control) => addToPage(pages[0].id, control));

  // Cognos' report-page tab mode maps directly to Sigma's released auto
  // navigation element. Place one at the start of every page.
  const visiblePages = pages.filter((page) => page.visibility !== 'hidden');
  if (visiblePages.length > 1 && report['@_viewPagesAsTabs']) {
    const pageLabels = visiblePages.map((p) => ({ pageId: p.id, label: p.name }));
    for (const page of visiblePages) {
      const nav: WbElement = {
        id: sigmaShortId(), kind: 'navigation', mode: 'auto', pageLabels,
      };
      elementsByPage.get(page.id)!.unshift(nav);
    }
  }

  // detail filters are converted per element (applyQueryFilters); summary filters
  // (post-aggregation HAVING-style) still surface as warnings to re-create.
  for (const fnode of findAll(report, 'summaryFilter')) {
    if (fnode['@_use'] === 'prohibited') continue;
    const fexpr = txt(fnode.filterExpression || fnode.expression);
    if (fexpr) warnings.push(`summary filter: "${fexpr.slice(0, 80)}" — post-aggregation filter; re-create as a Sigma filter on the aggregated column.`);
    else warnings.push('summary filter: structured or empty filter has no expression — re-create as a Sigma post-aggregation filter.');
  }

  // Page headers are now first-class document.panels definitions. Cognos page
  // footers do not map to the workbook panel union (header/sidebar only), so
  // they stay loud rather than being mislabeled as a sidebar.
  const panels: Array<Record<string, any>> = [];
  pageNodes.forEach((pageNode, i) => {
    const header = findAll(pageNode, 'pageHeader')[0];
    if (header) {
      const style = styleFromNode(header);
      panels.push({
        id: sigmaShortId(), type: 'header', title: `${pages[i].name} header`,
        pages: [pages[i].id],
        config: {
          scroll: 'none', borderStyle: 'none',
          ...(style?.backgroundColor ? { backgroundColor: style.backgroundColor } : {}),
        },
      });
    }
    if (findAll(pageNode, 'pageFooter').length) {
      warnings.push(workbookGap('page footer panel',
        `page "${pages[i].name}" has a Cognos pageFooter, but released workbook panels support header/sidebar only. Preserve footer content as ordinary page elements or a page-break print section.`));
    }
  });

  const stats = {
    queries: queries.size,
    tables: pageEls.filter((e) => e.kind === 'table').length,
    pivots: pageEls.filter((e) => e.kind === 'pivot-table').length,
    kpis: pageEls.filter((e) => e.kind === 'kpi-chart').length,
    charts: pageEls.filter((e) => e.kind.endsWith('-chart') && e.kind !== 'kpi-chart').length,
    maps: pageEls.filter((e) => e.kind.endsWith('-map')).length,
    columns: pageEls.reduce((n, e) => n + (e.columns?.length || 0), 0),
    filters: pageEls.reduce((n, e) => n + (e.filters?.length || 0), 0),
    controls: controls.size,
    refMarks: pageEls.reduce((n, e) => n + (e.refMarks?.length || 0), 0),
    scaleColors: pageEls.filter((e) => e.color?.by === 'scale').length,
    pages: pages.length,
    progress: pageEls.filter((e) => e.kind === 'progress').length,
    repeaters: pageEls.filter((e) => e.kind === 'repeated-container').length,
    panels: pageEls.filter((e) => e.kind === 'container').length,
    pagePanels: panels.length,
    pageBreaks: pageEls.filter((e) => e.kind === 'page-break').length,
  };
  const elements = pages.flatMap((page) => elementsByPage.get(page.id) || []);
  const document = {
    schemaVersion: 1,
    kind: 'workbook' as const,
    pages,
    elements,
    layout: buildAuthoritativeLayout(pages, elementsByPage, containerChildren),
    ...(panels.length ? { panels } : {}),
  };
  return {
    workbook: CodeRep.wrap(document, { name: reportName }) as CognosReportResult['workbook'],
    warnings, stats,
    ...(options.captureLineage ? { lineage } : {}),
  };
}
