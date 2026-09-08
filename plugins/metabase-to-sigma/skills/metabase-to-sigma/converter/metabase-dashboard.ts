/**
 * Metabase dashboard JSON → Sigma workbook code-representation payload.
 *
 * Input = GET /api/dashboard/{id}. Accepts BOTH the modern `dashcards` shape
 * (size_x/size_y) and the legacy `ordered_cards` shape (sizeX/sizeY).
 *
 *   dashboard tab            → workbook page (no tabs → single page)
 *   dashcard (by `display`)  → table / bar-chart (row = orientation:'horizontal' — the ONLY
 *                              valid orientation value; vertical OMITS the key) / line-chart /
 *                              area-chart / combo-chart / scatter-chart / pie-chart /
 *                              kpi-chart / pivot-table / region-map | point-map /
 *                              funnel-chart / gauge-chart / sankey-chart /
 *                              waterfall-chart. Progress stays a flagged table.
 *   text/heading dashcards   → text elements (markdown passes through)
 *   dashboard parameters     → workbook controls (controlId = parameter slug); each
 *                              parameter_mapping wires a REAL control `filters` target
 *                              on a TABLE element (the dashcard itself when it is a
 *                              table, else a hidden base table the chart re-roots
 *                              through — chart/KPI targets 400, and boolean-match
 *                              columns referencing list controls error live). The
 *                              control-scope.json sidecar carries declared scope.
 *
 * Element sources are PLACEHOLDERS: source { kind:'table', elementId: '<DM element NAME>' }.
 * The real Sigma element ids don't exist until the DM is POSTed —
 * scripts/remap-wb-to-dm-ids.mjs rewrites the placeholders afterwards (matched by name).
 *
 * Workbook output follows the released code representation: outer metadata plus
 * `document`, metadata-only pages, flat elements, and authoritative layout XML.
 * Metabase's 24-column grid maps 1:1 to Sigma and client ids survive CREATE.
 */

import { resetIds, sigmaShortId, sigmaDisplayName, formatFromMask } from './sigma-ids.js';
import { buildFieldIndex, recognizeSimpleNativeSql, translateMbqlExpr, translateAggregation, type FieldIndex, type MbqlCtx, type LearnedRule } from './metabase.js';
// pMBQL → legacy at intake: embedded dashcard cards AND parameter_mapping
// targets arrive in pMBQL form on modern instances (Cloud v1.61+).
import { normalizeCard, normalizeClause } from './pmbql-normalize.mjs';

// ── workbook spec types (minimal) ────────────────────────────────────────────
interface WbColumn { id: string; name: string; formula: string; format?: Record<string, any>; hidden?: boolean; }
interface WbControl {
  id: string; kind: 'control'; controlId: string; name: string; controlType: string;
  source?: Record<string, any>; value?: any; values?: any[]; mode?: string;
  filters?: Array<{ source: { kind: string; elementId: string }; columnId: string }>;
}
interface WbElement {
  id: string; kind: string; name?: string; source?: Record<string, any>;
  columns?: WbColumn[]; order?: string[]; filters?: any[]; conditionalFormats?: any[];
  rowsBy?: Array<{ columnId: string }>; columnsBy?: Array<{ columnId: string }>; values?: string[];
  xAxis?: { columnId: string };                                                          // cartesian charts
  yAxis?: { columnIds: Array<string | Record<string, any>> };
  value?: { columnId: string };
  color?: any; stacking?: string; orientation?: string;
  latitude?: { columnId: string }; longitude?: { columnId: string };
  region?: { columnId: string; regionType: string };
  stage?: { columnId: string }; series?: { columnId: string };
  stages?: Array<{ columnId: string }>;
  body?: string;
}
interface WbPage { id: string; name: string; elements: WbElement[]; }

export interface DashboardLayoutHint {
  grid: number;
  pages: Array<{ name: string; elements: Array<{ elementId: string; name: string; row: number; col: number; sizeX: number; sizeY: number }> }>;
}
/** control-scope.json sidecar (shared cross-plugin contract — see
 *  scripts/lib/control_lint.rb header CONTRACT + refs/control-parity.md).
 *  sourceFilterSignals = dashboard parameters with >=1 parameter_mapping
 *  (Metabase parameters declare their card targets EXPLICITLY — an unmapped
 *  parameter filters nothing in Metabase either, so it is not a signal).
 *  Per-control `scope` = the converted element names of its mapped cards
 *  (the declared-target allowlist); `mustReach` = the subset the converter
 *  actually wired (hard assertions for the lint's closure walk). */
export interface ControlScopeSidecar {
  version: 1; source: 'metabase'; sourceFilterSignals: number;
  controls: Array<{ controlId: string; sourceName?: string; scope: string[] | 'page'; mustReach: string[] }>;
}
export interface MetabaseDashboardResult {
  workbook: {
    name: string;
    document: {
      schemaVersion: number; kind: 'workbook';
      pages: Array<{ id: string; name: string; visibility?: string }>;
      elements: WbElement[]; layout: string;
    };
  };
  warnings: string[];
  stats: Record<string, number>;
  layout: DashboardLayoutHint;
  /** control-scope.json sidecar — write next to the workbook spec (cli --control-scope-out). */
  controlScope: ControlScopeSidecar;
  /** dashboard-parameter → native-template-tag wirings (the dominant pattern on
   *  production estates: the parameter drives a {{tag}} in a card's SQL). The
   *  DM converter emits the matching {{tag}} control; these record which
   *  dashboard parameter should drive it. */
  parameterWiring?: Array<{ parameter: string; slug: string; card: string; tag: string; kind: 'variable' | 'field-filter' }>;
  unreproducibleFilters?: Array<{ controlId: string; name: string; reason: string; hint: string }>;
}
export interface MetabaseDashboardOptions {
  workbookName?: string;
  dataModelId?: string;
  metadata?: any;                          // GET /api/database/{id}/metadata — field-id resolution
  cardNameById?: Record<number, string>;   // card id → DM element name (for "card__N" sources)
  learnedRules?: LearnedRule[];
}

// Metabase parameter type → Sigma control type. null type ⇒ flagged (warning, no control).
function controlTypeFor(t: string): { type?: string; warn?: string } {
  if (t === 'date/range') return { type: 'date-range' };
  if (t === 'date' || t?.startsWith('date/')) return { type: 'date' };
  if (t === 'temporal-unit') return { warn: 'temporal-unit ("time grouping") parameter has no Sigma control analog — flagged; pick a grouping in the chart instead.' };
  if (t === 'string/=' || t === 'category' || t === 'id') return { type: 'list' };
  if (t?.startsWith('string/')) return { type: 'list', warn: `parameter operator "${t}" approximated as a list (include) control — verify the filter semantics.` };
  if (t === 'number/=') return { type: 'number' };
  if (t === 'number/between') return { type: 'number-range' };
  if (t?.startsWith('number/')) return { type: 'number', warn: `parameter operator "${t}" approximated as a number control — verify the filter semantics.` };
  return { warn: `parameter type "${t}" not mapped — create the control manually.` };
}

const DISPLAY_KIND: Record<string, string> = {
  table: 'table', bar: 'bar-chart', row: 'bar-chart', line: 'line-chart', area: 'area-chart',
  combo: 'combo-chart', scatter: 'scatter-chart', pie: 'pie-chart',
  scalar: 'kpi-chart', smartscalar: 'kpi-chart', trend: 'kpi-chart',
  pivot: 'pivot-table', funnel: 'funnel-chart', gauge: 'gauge-chart',
  sankey: 'sankey-chart', waterfall: 'waterfall-chart',
};
// No faithful native Sigma analog → flagged table, never faked.
const NO_ANALOG = new Set(['progress']);
const titleCase = (s: string) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : s);

const xmlAttr = (value: unknown) => String(value ?? '')
  .replace(/&/g, '&amp;').replace(/"/g, '&quot;')
  .replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** Build the required, authoritative workbook layout from Metabase's exact
 *  24-column dashboard grid. Controls occupy a band above source tiles;
 *  utility/base elements are placed on the hidden Data page. */
function buildWorkbookLayout(pages: WbPage[], hints: DashboardLayoutHint): string {
  const hintByPage = new Map(hints.pages.map((p) => [p.name.toLowerCase(), p.elements]));
  const rowScale = 2;
  const kindHeight = (kind: string) => kind === 'control' ? 2
    : kind === 'kpi-chart' ? 6
    : kind.endsWith('-chart') ? 10
    : (kind.endsWith('-map') || kind === 'pivot-table' || kind === 'table') ? 12
    : kind === 'text' ? 3 : 10;

  return pages.map((page) => {
    const lines: string[] = [];
    const placed = new Set<string>();
    const controls = page.elements.filter((e) => e.kind === 'control');
    const perRow = Math.min(Math.max(controls.length, 1), 4);

    controls.forEach((control, i) => {
      const span = Math.floor(24 / perRow);
      const col0 = 1 + (i % perRow) * span;
      const col1 = (i % perRow === perRow - 1) ? 25 : col0 + span;
      const row0 = 1 + Math.floor(i / perRow) * kindHeight('control');
      lines.push(`  <Element elementId="${xmlAttr(control.id)}" gridColumn="${col0} / ${col1}" gridRow="${row0} / ${row0 + kindHeight('control')}"/>`);
      placed.add(control.id);
    });

    let contentStart = controls.length
      ? 1 + Math.ceil(controls.length / perRow) * kindHeight('control')
      : 1;
    let nextRow = contentStart;
    const byId = new Map(page.elements.map((e) => [e.id, e]));
    for (const hint of hintByPage.get(page.name.toLowerCase()) || []) {
      const element = byId.get(hint.elementId);
      if (!element || placed.has(element.id)) continue;
      const col0 = Math.max(1, hint.col + 1);
      const col1 = Math.min(25, col0 + Math.max(hint.sizeX, 1));
      const row0 = contentStart + Math.max(hint.row, 0) * rowScale;
      const row1 = row0 + Math.max(hint.sizeY * rowScale, kindHeight(element.kind));
      lines.push(`  <Element elementId="${xmlAttr(element.id)}" gridColumn="${col0} / ${col1}" gridRow="${row0} / ${row1}"/>`);
      placed.add(element.id);
      nextRow = Math.max(nextRow, row1);
    }

    for (const element of page.elements) {
      if (placed.has(element.id)) continue;
      const height = kindHeight(element.kind);
      lines.push(`  <Element elementId="${xmlAttr(element.id)}" gridColumn="1 / 25" gridRow="${nextRow} / ${nextRow + height}"/>`);
      placed.add(element.id);
      nextRow += height;
    }

    return `<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="${xmlAttr(page.id)}">\n${lines.join('\n')}\n</Page>`;
  }).join('\n');
}

export function convertMetabaseDashboardToSigma(dashboard: any, options: MetabaseDashboardOptions = {}): MetabaseDashboardResult {
  resetIds();
  const warnings: string[] = [];
  const dash = typeof dashboard === 'string' ? JSON.parse(dashboard) : dashboard;
  const fidx: FieldIndex | null = options.metadata ? buildFieldIndex(options.metadata) : null;
  const name = options.workbookName || dash.name || 'Metabase Dashboard';

  // ── dashcards: accept BOTH the modern and the legacy shape ───────────────────
  const rawDcs: any[] = dash.dashcards || dash.ordered_cards || [];
  const dcs = rawDcs.map((d: any) => ({
    raw: d,
    card: d.card ? normalizeCard(d.card) : d.card,
    cardId: d.card_id,
    vs: { ...(d.card?.visualization_settings || {}), ...(d.visualization_settings || {}) },
    tabId: d.dashboard_tab_id ?? null,
    row: d.row ?? 0, col: d.col ?? 0,
    sizeX: d.size_x ?? d.sizeX ?? 4, sizeY: d.size_y ?? d.sizeY ?? 4,
    parameterMappings: d.parameter_mappings || [],
  }));

  // Simple native-SQL cards are auto-remodeled to a NATIVE Sigma data model (see
  // recognizeSimpleNativeSql) so their columns are exposed and dashboard filters
  // reproduce natively. Mirror that here: swap the card to its structured form
  // (+ the alias-aligned result_metadata so the viz keeps its axes) and rewrite
  // each field-filter template-tag mapping to a raw dimension target — which the
  // proven MBQL dimension-wiring path below turns into a control + element filter.
  for (const dc of dcs) {
    if (!dc.card || dc.card.dataset_query?.type !== 'native') continue;
    const remodeled = recognizeSimpleNativeSql(dc.card, fidx || undefined);
    if (!remodeled) continue;
    const tags = dc.card.dataset_query?.native?.['template-tags'] || {};
    dc.card = { ...dc.card, dataset_query: { type: 'query', database: dc.card.dataset_query.database, query: remodeled.query }, result_metadata: remodeled.resultMetadata };
    dc.parameterMappings = dc.parameterMappings.map((pm: any) => {
      const tgt = pm.target;
      const tag = Array.isArray(tgt) && Array.isArray(tgt[1]) && tgt[1][0] === 'template-tag' ? String(tgt[1][1]) : null;
      const dim = tag && tags[tag]?.type === 'dimension' ? tags[tag].dimension : null;
      return dim ? { ...pm, target: ['dimension', dim] } : pm;
    });
  }

  // ── parameters → controls (controlId = slug; wiring below is per-mapping) ────
  // Metabase parameters declare their card targets EXPLICITLY (per-dashcard
  // parameter_mappings) — count mappings up front so (a) unmapped parameters
  // are skipped (they filter nothing in Metabase either; porting one would
  // ship furniture the control lint rightly rejects), and (b) range-typed
  // mapped parameters get REAL control filter targets (below) instead of the
  // boolean-equality formula, which is wrong for range semantics.
  const mappingCountByParam = new Map<string, number>();
  for (const dc of dcs) for (const pm of dc.parameterMappings) {
    mappingCountByParam.set(pm.parameter_id, (mappingCountByParam.get(pm.parameter_id) || 0) + 1);
  }
  const paramById = new Map<string, any>();
  const controls: WbControl[] = [];
  const controlBySlug = new Map<string, WbControl>();
  for (const p of dash.parameters || []) {
    paramById.set(p.id, p);
    let { type, warn } = controlTypeFor(p.type);
    if (warn) warnings.push(`parameter "${p.name}" (${p.type}): ${warn}`);
    if (!type) continue;
    if (!mappingCountByParam.get(p.id)) {
      warnings.push(`parameter "${p.name}" (${p.type}) has NO parameter_mappings — it filters nothing in Metabase; no control emitted (flag, never furniture). Map it to a card in Metabase first if it should do something.`);
      continue;
    }
    // Date parameters wired to dimension targets become date-RANGE controls:
    // a scalar date control can only express equality, and the only verified
    // Sigma wiring for a datetime target column is a date-range control with
    // flat mode "between" (list/scalar targets on datetime columns are
    // silently stripped at POST — see refs/control-parity.md).
    if (type === 'date') type = 'date-range';
    const ctrl: any = {
      id: sigmaShortId(), kind: 'control', controlId: p.slug || p.id, name: p.name || p.slug,
      controlType: type,
    };
    // Metabase static value list (e.g. day/week/month grain switchers) → Sigma's
    // segmented control (the native idiom for small fixed choices); larger lists
    // stay a list control with a manual source.
    const staticVals: any[] | null =
      p.values_source_type === 'static-list' ? (p.values_source_config?.values || null) : null;
    if (staticVals?.length && type === 'list') {
      ctrl.controlType = staticVals.length <= 6 ? 'segmented' : 'list';
      ctrl.source = {
        kind: 'manual',
        valueType: typeof staticVals[0] === 'number' ? 'number' : 'text',
        values: staticVals,
      };
    }
    // Union discriminants are REQUIRED per controlType (same live-verified contract
    // as DM controls — omitting them fails validation as `Invalid kind: "control"`).
    if (ctrl.controlType === 'text') ctrl.mode = 'equals';
    if (ctrl.controlType === 'number') ctrl.mode = '=';
    if (ctrl.controlType === 'date') ctrl.mode = '=';
    if (ctrl.controlType === 'date-range') ctrl.mode = 'between';
    // Defaults: list controls take `values` (array), everything else scalar `value`;
    // never emit an explicit null. Range controls: Metabase encodes defaults as
    // relative tokens ("past30days") / "A~B" strings with no verified Sigma spec
    // analog — dropped with a warning, set the default in the Sigma UI.
    if (p.default != null) {
      if (ctrl.controlType === 'date-range' || ctrl.controlType === 'number-range') {
        warnings.push(`parameter "${p.name}": range default ${JSON.stringify(p.default)} has no verified Sigma spec shape — control emitted WITHOUT a default; set it in the UI.`);
      } else if (ctrl.controlType === 'list') {
        ctrl.values = Array.isArray(p.default) ? p.default : [p.default];
      } else {
        let v = Array.isArray(p.default) ? p.default[0] : p.default;
        // Metabase stores number defaults as strings ("20") — Sigma number controls want numbers.
        if (ctrl.controlType === 'number' && typeof v === 'string' && v.trim() !== '' && !isNaN(Number(v))) v = Number(v);
        ctrl.value = v;
      }
    }
    controls.push(ctrl);
    controlBySlug.set(ctrl.controlId, ctrl);
  }

  // field-id → display name (metadata first; result_metadata fallback per card)
  const mkCtx = (card: any, prefix: string | null): MbqlCtx => {
    const rmById = new Map<number, any>();
    for (const rm of card?.result_metadata || []) {
      const fr = rm.field_ref;
      if (Array.isArray(fr) && fr[0] === 'field' && typeof fr[1] === 'number') rmById.set(fr[1], rm);
    }
    const display = (ref: any): string => {
      const idOrName = Array.isArray(ref) ? ref[1] : ref;
      if (typeof idOrName === 'number') {
        const f = fidx?.byId.get(idOrName);
        if (f) return f.displayName;
        const rm = rmById.get(idOrName);
        if (rm) return rm.display_name || sigmaDisplayName(rm.name);
        warnings.push(`card "${card?.name}": field ${idOrName} unresolved (pass --metadata) — emitted [Field ${idOrName}].`);
        return `Field ${idOrName}`;
      }
      return sigmaDisplayName(String(idOrName ?? ''));
    };
    const ctx: MbqlCtx = {
      fieldDisplay: display,
      resolveField: (ref: any) => {
        const opts = (Array.isArray(ref) && ref[2]) || {};
        const disp = display(ref);
        let out = prefix ? `[${prefix}/${disp}]` : `[${disp}]`;
        if (opts['temporal-unit']) out = `DateTrunc("${opts['temporal-unit']}", ${out})`;
        if (opts.binning) ctx.warn(`numeric binning on [${disp}] is flagged — recreate with BinFixed/BinCount on the element.`);
        return out;
      },
      warn: (m) => warnings.push(`card "${card?.name}": ${m}`),
      learnedRules: options.learnedRules,
    };
    return ctx;
  };

  // Resolve the DM-element-NAME placeholder this dashcard sources.
  // remap-wb-to-dm-ids.mjs rewrites it to the real posted element id (matched by name).
  const sourceNameFor = (card: any): string => {
    const dq = card.dataset_query || {};
    if (dq.type === 'native') {
      warnings.push(`card "${card.name}" is a native-SQL question — its DM sql element carries NO name (Sigma derives one); wire this element's source.elementId manually after posting the DM.`);
      return card.name || 'Custom SQL';
    }
    const q = dq.query || {};
    const src = q['source-table'];
    if (typeof src === 'string' && src.startsWith('card__')) {
      const n = Number(src.slice('card__'.length));
      const mapped = options.cardNameById?.[n];
      if (mapped) return mapped;
      // Parent card not on this dashboard and no mapping provided — the DM
      // converter gives the NESTED card its own element (sourced from the parent),
      // so this card's own name is the resolvable placeholder (live-verified;
      // a "card__N" placeholder 400s at POST).
      if (card.name) {
        warnings.push(`card "${card.name}" sources nested card ${n} — no card-name mapping; sourced its OWN DM element by card name (the DM converter creates one per nested card). Pass cardNameById to source the parent model instead.`);
        return card.name;
      }
      warnings.push(`card "${card.name}" sources nested card ${n} — no card-name mapping provided; emitted placeholder "card__${n}" (remap will report it unresolved; pass cardNameById or fix by hand).`);
      return `card__${n}`;
    }
    if (typeof src === 'number') {
      const t = fidx?.tableById.get(src);
      if (!t) { warnings.push(`card "${card.name}": source table ${src} not in metadata — emitted placeholder "table_${src}".`); return `table_${src}`; }
      if (Array.isArray(q.joins) && q.joins.length) {
        // The DM converter gives every MBQL-join card its OWN join element, named
        // after the card, with exactly the card's columns. Source that — the generic
        // FK-derived "<Table> View" suffixes duplicate columns ("Category (PRODUCT_DIM)")
        // so card-named refs 400 against it (live-verified "Dependency not found").
        return card.name || `${sigmaDisplayName(t.name)} View`;
      }
      // Implicit FK joins (source-field refs) need the dim columns the base table
      // doesn't have — read from the FK-derived "<Table> View" element instead.
      if (JSON.stringify(q).includes('"source-field"')) return `${sigmaDisplayName(t.name)} View`;
      return sigmaDisplayName(t.name);
    }
    warnings.push(`card "${card.name}": unrecognized source ${JSON.stringify(src)} — emitted placeholder "<element>".`);
    return '<element>';
  };

  // column_settings → Sigma format (number_style/decimals/currency/prefix/suffix)
  const CURRENCY_SYMBOL: Record<string, string> = { USD: '$', EUR: '€', GBP: '£', JPY: '¥', CAD: '$', AUD: '$' };
  const formatFromColumnSettings = (s: any): Record<string, any> | undefined => {
    if (!s) return undefined;
    const d = s.decimals ?? 2;
    let fmt: Record<string, any> | null = null;
    if (s.number_style === 'currency' || s.currency) {
      const sym = CURRENCY_SYMBOL[String(s.currency || 'USD').toUpperCase()] || '$';
      fmt = { kind: 'number', formatString: `${sym},.${s.decimals ?? 2}f`, currencySymbol: sym };
    } else if (s.number_style === 'percent') {
      fmt = formatFromMask(`0${d ? '.' + '0'.repeat(d) : ''}%`);
    } else if (s.number_style === 'decimal' || s.decimals != null) {
      fmt = formatFromMask(`#,##0${d ? '.' + '0'.repeat(d) : ''}`);
    }
    if (s.suffix) fmt = { ...(fmt || { kind: 'number', formatString: ',.2f' }), suffix: s.suffix };
    if (s.prefix) fmt = { ...(fmt || { kind: 'number', formatString: ',.2f' }), prefix: s.prefix };
    // date_style / time_style: Sigma date-format spec shape is not yet verified
    // against a live readback — ignored silently (display-only, data unaffected).
    return fmt || undefined;
  };

  // table.column_formatting → Sigma conditionalFormats (single rules convert;
  // range/gradient scales are flagged — backgroundScale spec shape unverified).
  const CF_OPERATOR: Record<string, string> = {
    '=': '=', '!=': '!=', '<': '<', '>': '>', '<=': '<=', '>=': '>=',
    'is-null': 'IsNull', 'not-null': 'IsNotNull', contains: 'Contains',
    'does-not-contain': 'NotContains', 'starts-with': 'StartsWith', 'ends-with': 'EndsWith',
  };
  const buildConditionalFormats = (card: any, rules: any[], byKey: Map<string, string>): any[] => {
    const out: any[] = [];
    for (const r of rules || []) {
      const columnIds = (r.columns || []).map((n: string) => byKey.get(String(n).toLowerCase())).filter(Boolean);
      if (!columnIds.length) { warnings.push(`card "${card.name}": a conditional-formatting rule targets unresolved column(s) ${JSON.stringify(r.columns)} — skipped.`); continue; }
      if (r.type === 'single') {
        const condition = CF_OPERATOR[String(r.operator)];
        if (!condition) { warnings.push(`card "${card.name}": conditional-formatting operator "${r.operator}" has no Sigma mapping — rule skipped.`); continue; }
        const cf: any = { type: 'single', columnIds, condition, style: { backgroundColor: r.color || '#509EE3' } };
        if (r.value !== undefined && condition !== 'IsNull' && condition !== 'IsNotNull') cf.value = r.value;
        out.push(cf);
        if (r.highlight_row) warnings.push(`card "${card.name}": a conditional-formatting rule highlights the WHOLE ROW — Sigma's converted rule colors the matched column(s) only; extend columnIds to all columns if row highlighting is required.`);
      } else {
        warnings.push(`card "${card.name}": a "${r.type}" (gradient/range) conditional-formatting rule is flagged — recreate as a Sigma backgroundScale conditional format in the UI (spec shape not yet live-verified).`);
      }
    }
    return out;
  };

  interface BuiltCols {
    cols: WbColumn[]; order: string[];
    byKey: Map<string, string>;            // result name / display name (lowercase) → col id
    byFieldId: Map<number, string>;        // MBQL field id → col id
    byAggIndex: Map<number, string>;       // ["aggregation", n] → col id
    dimIds: string[]; metricIds: string[];
    keyOfId: Map<string, string>;          // col id → result_metadata name (series_settings keys)
  }

  const buildCardColumns = (card: any, sourceName: string, ctx: MbqlCtx): BuiltCols => {
    const out: BuiltCols = { cols: [], order: [], byKey: new Map(), byFieldId: new Map(), byAggIndex: new Map(), dimIds: [], metricIds: [], keyOfId: new Map() };
    const dq = card.dataset_query || {};
    const q = dq.type === 'query' ? dq.query || {} : null;
    let rms: any[] = card.result_metadata || [];
    if (!rms.length && q) {
      // never-run cards may carry no result_metadata — synthesize from the MBQL itself
      warnings.push(`card "${card.name}" has no result_metadata — columns synthesized from its MBQL (run the question once to capture exact result names).`);
      rms = [
        ...(q.breakout || []).map((b: any) => ({ name: ctx.fieldDisplay(b), display_name: ctx.fieldDisplay(b), field_ref: b })),
        ...(q.aggregation || []).map((_: any, i: number) => ({ name: `agg${i}`, display_name: '', field_ref: ['aggregation', i] })),
      ];
    }
    let aggSeq = 0;
    for (const rm of rms) {
      if (rm.name === 'pivot-grouping') continue; // Metabase-internal pivot column
      let fr = rm.field_ref;
      // Pivot (and some cached) result_metadata carries field_ref: null — reconstruct
      // from the MBQL by name (agg result cols are named sum/count/avg/…; live-verified).
      if (!Array.isArray(fr) && q) {
        const nmLower = String(rm.name || '').toLowerCase();
        if (q.aggregation?.length && /^(sum|count|avg|min|max|stddev|distinct|share|cum_sum|cum_count)(_\d+)?$/.test(nmLower)) {
          fr = ['aggregation', Math.min(aggSeq++, q.aggregation.length - 1)];
        } else {
          const b = (q.breakout || []).find((br: any) => ctx.fieldDisplay(br).toLowerCase() === String(rm.display_name || rm.name || '').toLowerCase());
          if (b) fr = b;
        }
      }
      // Prettify ALWAYS (idempotent) — raw native aliases (x_axis_type, count(*))
      // otherwise become the visible axis/column labels.
      let formula = ''; let isMetric = false; let nm = sigmaDisplayName(rm.display_name || rm.name || 'Column');
      if (Array.isArray(fr) && fr[0] === 'aggregation') {
        const agg = q?.aggregation?.[fr[1]];
        if (agg) {
          const tr = translateAggregation(agg, ctx);
          formula = tr.formula;
          if (!nm) nm = tr.name;
        } else { formula = `[${nm}]`; }       // native/aggregated upstream — passthrough
        isMetric = true;
      } else if (Array.isArray(fr) && fr[0] === 'expression') {
        const ex = q?.expressions?.[fr[1]];
        formula = ex ? translateMbqlExpr(ex, ctx) : `[${fr[1]}]`;
      } else if (Array.isArray(fr) && fr[0] === 'field') {
        formula = ctx.resolveField(fr);
      } else {
        formula = `[${nm}]`;                  // native result column — bare display ref
      }
      const id = sigmaShortId();
      const col: WbColumn = { id, name: nm, formula };
      out.cols.push(col); out.order.push(id);
      if (rm.name) { out.byKey.set(String(rm.name).toLowerCase(), id); out.keyOfId.set(id, rm.name); }
      out.byKey.set(nm.toLowerCase(), id);
      if (Array.isArray(fr) && fr[0] === 'field' && typeof fr[1] === 'number') out.byFieldId.set(fr[1], id);
      if (Array.isArray(fr) && fr[0] === 'aggregation') out.byAggIndex.set(fr[1], id);
      (isMetric ? out.metricIds : out.dimIds).push(id);
    }
    return out;
  };

  // resolve a column_split / graph.* entry (field ref | agg ref | name string) → col id
  const resolveEntry = (entry: any, built: BuiltCols, ctx: MbqlCtx): string | undefined => {
    if (typeof entry === 'string') return built.byKey.get(entry.toLowerCase());
    if (Array.isArray(entry) && entry[0] === 'aggregation') return built.byAggIndex.get(entry[1]);
    if (Array.isArray(entry) && entry[0] === 'field') {
      if (typeof entry[1] === 'number' && built.byFieldId.has(entry[1])) return built.byFieldId.get(entry[1]);
      return built.byKey.get(ctx.fieldDisplay(entry).toLowerCase());
    }
    return undefined;
  };

  // dashboard-parameter → template-tag wirings (aggregated; see parameterWiring)
  const tagWirings: NonNullable<MetabaseDashboardResult['parameterWiring']> = [];

  // ── control-scope bookkeeping (the sidecar contract) ─────────────────────────
  // scope = converted element names of each control's MAPPED cards (declared
  // targets); reach = the subset the converter actually wired (bool formula,
  // range filter target, or field-filter recreation). dmBound = controls whose
  // only wiring is the control→DM-parameter binding (remap --dm-spec).
  const scopeBySlug = new Map<string, Set<string>>();
  const reachBySlug = new Map<string, Set<string>>();
  const dmBoundSlugs = new Set<string>();
  const record = (m: Map<string, Set<string>>, slug: string, name?: string) => {
    if (!name) return;
    if (!m.has(slug)) m.set(slug, new Set());
    m.get(slug)!.add(name);
  };

  // Hidden sourcing roots for range-control filter targets. A Sigma control's
  // `filters` target may only point at a TABLE element (chart/KPI targets 400
  // "Dependency not found") — so a range-mapped chart is re-rooted through a
  // base table that sources the same DM element and carries the columns the
  // chart (and the control target) needs. Base tables live on a final "Data"
  // page whose id starts with "data" (the cross-plugin convention the layout
  // gates use to exempt utility pages).
  const baseTables: WbElement[] = [];

  // ── per-dashcard element builder ───────────────────────────────────────────
  const buildElement = (dc: (typeof dcs)[number]): WbElement | null => {
    const vs = dc.vs;
    // text / heading dashcards (card_id null + virtual_card) → text elements
    if (dc.cardId == null && vs.virtual_card) {
      const display = vs.virtual_card.display;
      if (display === 'text' || display === 'heading') {
        // Live contract: text elements carry `body` (string), not `text` —
        // POST 400s "body: Invalid string: undefined".
        return { id: sigmaShortId(), kind: 'text', name: 'Text', body: vs.text || '' } as any;
      }
      warnings.push(`virtual card (display "${display}") is not a text/heading — skipped (link/action cards have no Sigma spec analog).`);
      return null;
    }
    const card = dc.card;
    if (!card) { warnings.push(`dashcard ${dc.raw.id}: card ${dc.cardId} not embedded in the dashboard JSON — skipped.`); return null; }
    if (vs.click_behavior || Object.values(vs.column_settings || {}).some((c: any) => c?.click_behavior)) {
      warnings.push(`card "${card.name}": click_behavior (cross-filter / link) is not converted — re-create as a Sigma action.`);
    }

    const display = String(card.display || 'table');
    const sourceName = sourceNameFor(card);
    const ctx = mkCtx(card, card.dataset_query?.type === 'native' ? null : sourceName);
    const built = buildCardColumns(card, sourceName, ctx);

    // column_settings → formats. Keys: '["name","COL"]' or '["ref",["field",72,null]]'.
    for (const [key, setting] of Object.entries(vs.column_settings || {})) {
      try {
        const k = JSON.parse(key);
        const colId = k[0] === 'name' ? built.byKey.get(String(k[1]).toLowerCase())
          : k[0] === 'ref' ? resolveEntry(k[1], built, ctx) : undefined;
        const fmt = formatFromColumnSettings(setting);
        if (colId && fmt) { const c = built.cols.find((c) => c.id === colId); if (c) c.format = fmt; }
      } catch { /* unparseable column_settings key — ignore */ }
    }

    // Cross-document DM references are kind 'data-model' (kind 'table' is for
    // same-workbook elements — live-verified 400 "Dependency not found").
    const source: Record<string, any> = { kind: 'data-model', elementId: sourceName };
    if (options.dataModelId) source.dataModelId = options.dataModelId;
    const el: WbElement = {
      id: sigmaShortId(), kind: DISPLAY_KIND[display] || 'table', name: card.name || `Card ${card.id}`,
      source, columns: built.cols, order: built.order,
    };

    // graph.dimensions / graph.metrics matched through result_metadata names
    const dimIds = ((vs['graph.dimensions'] || []).filter(Boolean)
      .map((n: string) => built.byKey.get(n.toLowerCase())).filter(Boolean) as string[]);
    const metIds = ((vs['graph.metrics'] || []).filter(Boolean)
      .map((n: string) => built.byKey.get(n.toLowerCase())).filter(Boolean) as string[]);
    const xIds = dimIds.length ? dimIds : built.dimIds;
    const yIds = metIds.length ? metIds : built.metricIds;

    if (NO_ANALOG.has(display)) {
      // never fake a viz — emit the data as a table + a LOUD warning
      el.kind = 'table';
      el.name = `${card.name} (was ${display})`;
      warnings.push(`card "${card.name}" is a Metabase ${display} — no faithful native Sigma mapping is verified; emitted its data as a TABLE. Re-pick a Sigma viz in the workbook.`);
    } else if (display === 'object') {
      // single-record detail view — flagged, emitted as a table (never faked)
      el.kind = 'table';
      el.name = `${card.name} (object detail)`;
      warnings.push(`card "${card.name}" is a Metabase object DETAIL view (single record) — emitted its data as a flagged TABLE; recreate the detail experience with element filters / drill in Sigma.`);
    } else if (el.kind === 'kpi-chart') {
      const scalarField = vs['scalar.field'] ? built.byKey.get(String(vs['scalar.field']).toLowerCase()) : undefined;
      const valId = scalarField || yIds[0] || built.metricIds[0] || built.order[0];
      if (!valId) { warnings.push(`card "${card.name}" (scalar) resolved no value column — skipped.`); return null; }
      el.value = { columnId: valId };   // kpi-chart wants {columnId}, NOT {id}
      if (display === 'smartscalar' || display === 'trend') {
        warnings.push(`card "${card.name}" is a ${display} — the VALUE converts; the auto "vs previous period" comparison does not. Add a Sigma KPI comparison manually.`);
      }
    } else if (el.kind === 'pie-chart') {
      const sliceId = (vs['pie.dimension'] && built.byKey.get(String(vs['pie.dimension']).toLowerCase())) || xIds[0];
      const valId = (vs['pie.metric'] && built.byKey.get(String(vs['pie.metric']).toLowerCase())) || yIds[0];
      if (sliceId) el.color = { columnId: sliceId };
      if (valId) el.value = { columnId: valId };
      if (!sliceId || !valId) warnings.push(`card "${card.name}" (pie): could not resolve ${!sliceId ? 'slice dimension' : 'value'} — fix in the workbook.`);
    } else if (el.kind === 'pivot-table') {
      const split = vs['pivot_table.column_split'] || {};
      const rowsBy = (split.rows || []).map((e: any) => resolveEntry(e, built, ctx)).filter(Boolean).map((columnId: string) => ({ columnId }));
      const columnsBy = (split.columns || []).map((e: any) => resolveEntry(e, built, ctx)).filter(Boolean).map((columnId: string) => ({ columnId }));
      let values = (split.values || []).map((e: any) => resolveEntry(e, built, ctx)).filter(Boolean) as string[];
      if (!values.length) values = built.metricIds;
      // rowsBy/columnsBy = arrays of {columnId}, values = bare column-id strings —
      // without rowsBy+columnsBy the pivot silently collapses to one grand-total cell.
      el.rowsBy = rowsBy; el.columnsBy = columnsBy; el.values = values;
      if (!rowsBy.length && !columnsBy.length) warnings.push(`card "${card.name}" (pivot): no row/column split resolved — the pivot will collapse to a single grand-total cell; set rowsBy/columnsBy.`);
    } else if (display === 'map') {
      const mapType = vs['map.type'] || 'region';
      if (mapType === 'pin') {
        const latId = built.cols.find((c) => /\blat/i.test(c.name))?.id;
        const lonId = built.cols.find((c) => /\b(lon|lng)/i.test(c.name))?.id;
        if (latId && lonId) {
          el.kind = 'point-map'; el.latitude = { columnId: latId }; el.longitude = { columnId: lonId };
        } else {
          el.kind = 'table'; el.name = `${card.name} (was pin map)`;
          warnings.push(`card "${card.name}" (pin map): no lat/long columns resolved — emitted its data as a table.`);
        }
      } else {
        const regId = xIds[0] || built.dimIds[0];
        if (regId) {
          el.kind = 'region-map'; el.region = { columnId: regId, regionType: vs['map.region'] === 'us_states' ? 'us-state' : 'country' };
          if (yIds[0]) el.color = { by: 'scale', column: yIds[0] };
          warnings.push(`card "${card.name}" → region-map: regionType guessed from map.region — verify (country / us-state / us-county / us-zipcode / ca-province).`);
        } else {
          el.kind = 'table'; el.name = `${card.name} (was region map)`;
          warnings.push(`card "${card.name}" (region map): no region column resolved — emitted its data as a table.`);
        }
      }
    } else if (el.kind === 'funnel-chart') {
      if (xIds[0] && yIds[0]) {
        el.stage = { columnId: xIds[0] };
        el.series = { columnId: yIds[0] };
      } else {
        el.kind = 'table'; el.name = `${card.name} (was funnel)`;
        warnings.push(`card "${card.name}" (funnel): a stage dimension and measure are required — emitted its data as a TABLE.`);
      }
    } else if (el.kind === 'gauge-chart') {
      const valId = yIds[0] || built.metricIds[0] || built.order[0];
      if (valId) el.value = { columnId: valId };
      else {
        el.kind = 'table'; el.name = `${card.name} (was gauge)`;
        warnings.push(`card "${card.name}" (gauge): no value column resolved — emitted its data as a TABLE.`);
      }
    } else if (el.kind === 'sankey-chart') {
      if (xIds.length >= 2 && yIds[0]) {
        el.stages = xIds.map((columnId) => ({ columnId }));
        el.value = { columnId: yIds[0] };
      } else {
        el.kind = 'table'; el.name = `${card.name} (was sankey)`;
        warnings.push(`card "${card.name}" (sankey): at least two stage dimensions and one measure are required — emitted its data as a TABLE.`);
      }
    } else if (el.kind.endsWith('-chart')) {
      // cartesian: bar / row / line / area / combo / scatter / waterfall
      if (xIds[0]) el.xAxis = { columnId: xIds[0] };
      else warnings.push(`card "${card.name}" (${display}): no x-axis dimension resolved — set it in the workbook.`);
      if (el.kind === 'combo-chart') {
        // series_settings per-series display → bare-string (default mark) vs object
        // (overridden mark / secondary axis) forms on yAxis.columnIds — the persisted
        // dual-axis shape (feedback_sigma_combo_dual_axis).
        const ss = vs.series_settings || {};
        el.yAxis = {
          columnIds: yIds.map((id) => {
            const key = built.keyOfId.get(id);
            const d = key ? ss[key]?.display : undefined;
            return d && d !== 'bar' ? { columnId: id } : id;
          }),
        };
        if (Object.keys(ss).length) warnings.push(`card "${card.name}" (combo): per-series marks emitted via the bare-string/object yAxis form — verify each series' mark + axis in Sigma.`);
      } else if (yIds.length) {
        el.yAxis = { columnIds: yIds };
      } else {
        warnings.push(`card "${card.name}" (${display}): no measure resolved for the value axis — add one in the workbook.`);
      }
      if (xIds.length > 1) el.color = { by: 'category', column: xIds[1] };  // 2nd dimension = series color
      if (display === 'row') el.orientation = 'horizontal';  // 'horizontal' is the ONLY valid value; vertical bar OMITS the key
      // Live-verified enum: none | stacked | normalized (Metabase's 'normalized'
      // passes through verbatim; 'percent' is rejected "Invalid value: string").
      const stack = vs['stackable.stack_type'];
      if (stack === 'stacked') el.stacking = 'stacked';
      else if (stack === 'normalized') el.stacking = 'normalized';
    }
    // display === 'table' → plain table element: columns + order already set.

    // series_settings → series display names (rename the y columns); colors are
    // positional-only in the Sigma spec (bar color.scheme) — flagged, not guessed.
    if (vs.series_settings && el.kind !== 'combo-chart') {
      let renamed = 0; let colored = 0;
      for (const [key, s] of Object.entries(vs.series_settings as Record<string, any>)) {
        const colId = built.byKey.get(String(key).toLowerCase());
        const c = colId && built.cols.find((c) => c.id === colId);
        if (c && s?.title && s.title !== c.name) { built.byKey.set(String(s.title).toLowerCase(), c.id); c.name = s.title; renamed++; }
        if (s?.color) colored++;
      }
      if (colored) warnings.push(`card "${card.name}": ${colored} per-series color(s) in series_settings — Sigma's spec colors bar categories positionally (color.scheme) and pie/line series via theme only; re-apply colors in the workbook.`);
      if (renamed) warnings.push(`card "${card.name}": ${renamed} series renamed from series_settings titles.`);
    }

    // table.column_formatting → Sigma conditionalFormats (single rules; ranges flagged)
    if (Array.isArray(vs['table.column_formatting']) && vs['table.column_formatting'].length) {
      const cfs = buildConditionalFormats(card, vs['table.column_formatting'], built.byKey);
      if (cfs.length) el.conditionalFormats = cfs;
    }

    // table.columns enabled:false → hide
    for (const tc of vs['table.columns'] || []) {
      if (tc?.enabled === false && tc.name) {
        const id = built.byKey.get(String(tc.name).toLowerCase());
        const c = id && built.cols.find((c) => c.id === id);
        if (c) c.hidden = true;
      }
    }

    // ── parameter_mappings → control `filters` targets ─────────────────────────
    // Every wirable mapping becomes a REAL control filter target — the verified
    // cross-plugin wiring (refs/control-parity.md). A control reference inside a
    // boolean match column (`[Col] = [slug]`) reads back as an error-typed
    // column for list controls (live-caught 2026-06-12), so targets are the
    // only honest form. Targets may only point at TABLE elements: a table
    // dashcard is targeted directly; charts/KPIs re-root through a hidden base
    // TABLE (collected in `pendingTargets`, materialized below). List/segmented
    // targets on numeric or datetime columns are silently stripped at POST —
    // those bind through a hidden Text() cast column (`cast`).
    const pendingTargets: Array<{ slug: string; disp: string; fieldRef?: any; cast: boolean }> = [];
    const NUMERIC_OR_DATETIME = /type\/(Integer|BigInteger|Float|Decimal|Number|DateTime|Date|Time)/;
    const needsCast = (slug: string, baseType?: string) => {
      const t = controlBySlug.get(slug)?.controlType;
      return (t === 'list' || t === 'segmented' || t === 'text')
        && !!baseType && NUMERIC_OR_DATETIME.test(baseType);
    };
    for (const pm of dc.parameterMappings) {
      const p = paramById.get(pm.parameter_id);
      if (!p) { warnings.push(`card "${card.name}": parameter_mapping references unknown parameter ${pm.parameter_id} — skipped.`); continue; }
      const slug = p.slug || p.id;
      record(scopeBySlug, slug, el.name);
      let tgt = pm.target;
      // pMBQL targets carry [op, {opts}, …] inner clauses — normalize them.
      if (Array.isArray(tgt) && tgt.length >= 2) tgt = [tgt[0], normalizeClause(tgt[1])];
      // native template-tag targets (the DOMINANT production pattern — 13.5k of
      // 14.6k mappings on the reference estate): the parameter drives a {{tag}}
      // in the card's SQL. The DM converter emits the {{tag}} control; record
      // the wiring (aggregated into one warning per parameter, not per mapping).
      const innerTag = Array.isArray(tgt) && Array.isArray(tgt[1]) && tgt[1][0] === 'template-tag' ? String(tgt[1][1]) : null;
      if (innerTag && (tgt[0] === 'variable' || tgt[0] === 'dimension')) {
        if (tgt[0] === 'variable') {
          tagWirings.push({ parameter: p.name || slug, slug, card: card.name || String(card.id), tag: innerTag, kind: 'variable' });
          dmBoundSlugs.add(slug);
          continue;
        }
        // dimension + template-tag = the parameter drives a FIELD FILTER tag.
        // The DM converter neutralized that tag to 1=1 — recreate the filter
        // here when the tag's mapped column is in the card's result set.
        tagWirings.push({ parameter: p.name || slug, slug, card: card.name || String(card.id), tag: innerTag, kind: 'field-filter' });
        const tag = card.dataset_query?.native?.['template-tags']?.[innerTag];
        const dimRef = tag?.dimension;
        const dimColId = Array.isArray(dimRef) ? resolveEntry(dimRef, built, ctx) : undefined;
        if (dimColId) {
          const targetCol = built.cols.find((c) => c.id === dimColId)!;
          const fieldId = Array.isArray(dimRef) && typeof dimRef[1] === 'number' ? dimRef[1] : undefined;
          const baseType = (fieldId != null && fidx?.byId.get(fieldId)?.baseType)
            || (card.result_metadata || []).find((rm: any) => rm.name && built.byKey.get(String(rm.name).toLowerCase()) === dimColId)?.base_type;
          pendingTargets.push({ slug, disp: targetCol.name, fieldRef: dimRef, cast: needsCast(slug, baseType) });
          record(reachBySlug, slug, el.name);
        } else {
          warnings.push(`card "${card.name}": parameter "${p.name}" drives field-filter tag {{${innerTag}}} but the tag's column is not in the card's result set — add the column to the SQL SELECT, then filter it via the "${slug}" control.`);
        }
        continue;
      }
      if (Array.isArray(tgt) && tgt[0] === 'text-tag') {
        warnings.push(`card "${card.name}": parameter "${p.name}" targets a TEXT TAG (markdown placeholder) — Sigma text elements cannot bind controls; re-author the text or drop the binding.`);
        continue;
      }
      if (!Array.isArray(tgt) || tgt[0] !== 'dimension') {
        warnings.push(`card "${card.name}": parameter "${p.name}" targets ${JSON.stringify(tgt)} — unmappable; wire it manually.`);
        continue;
      }
      const fieldRef = tgt[1];
      const disp = ctx.fieldDisplay(fieldRef);
      const baseType = (typeof fieldRef?.[1] === 'number' ? fidx?.byId.get(fieldRef[1])?.baseType : undefined)
        || (Array.isArray(fieldRef) && fieldRef[2]?.['base-type']) || undefined;
      pendingTargets.push({ slug, disp, fieldRef, cast: needsCast(slug, baseType) });
      record(reachBySlug, slug, el.name);
    }

    // card-level MBQL filter → hidden boolean column + element filter (element is card-specific here, so this is safe)
    const q = card.dataset_query?.type === 'query' ? card.dataset_query.query : null;
    if (q?.filter) {
      const formula = translateMbqlExpr(q.filter, ctx);
      const fid = sigmaShortId();
      built.cols.push({ id: fid, name: `Filter: ${card.name || card.id}`, formula, hidden: true });
      (el.filters ||= []).push({ id: sigmaShortId(), columnId: fid, kind: 'list', mode: 'include', values: [true] });
    }

    // ── mapped targets → table element + control filter targets ────────────────
    // A table dashcard is targeted DIRECTLY (it is already a table element); a
    // chart/KPI/pivot re-roots through a hidden base TABLE (same DM source,
    // passthrough columns) on the Data page — control targets may only point at
    // table elements, and the element inherits the filter through the source
    // closure. List/segmented targets on numeric/datetime columns bind through
    // a hidden Text() cast column (silently stripped otherwise — verified).
    if (pendingTargets.length) {
      const isNative = card.dataset_query?.type === 'native';
      let targetElId: string;
      let targetCols: WbColumn[];        // column set on the TARGET table
      let colByDisp: (disp: string) => WbColumn | undefined;

      if (el.kind === 'table') {
        // the dashcard is already a table — target it directly
        targetElId = el.id;
        targetCols = built.cols;
        colByDisp = (disp) => {
          let c = built.cols.find((cc) => cc.name === disp);
          if (!c) {
            const pt = pendingTargets.find((r) => r.disp === disp);
            c = { id: sigmaShortId(), name: disp, formula: pt?.fieldRef ? ctx.resolveField(pt.fieldRef) : `[${disp}]`, hidden: true };
            built.cols.push(c);
            built.byKey.set(disp.toLowerCase(), c.id);
          }
          return c;
        };
      } else {
        const baseName = `${card.name || `Card ${card.id}`} Base`;
        // passthrough set: every source ref in the element's formulas + the targets.
        // A "source ref" is a `[sourceName/X]`-prefixed token (MBQL cards) or, on
        // native cards, a bare `[X]` that is either a passthrough column reading
        // itself or a token that names no local column (a direct source read);
        // bare refs to OTHER local columns and `[slug]` control refs stay local.
        const needed = new Set<string>(pendingTargets.map((r) => r.disp));
        const localNames = new Set(built.cols.map((cc) => cc.name));
        const isPassthroughSelf = (c: WbColumn, tok: string) => c.name === tok && String(c.formula).trim() === `[${tok}]`;
        const prefixed = new RegExp(`\\[${sourceName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/([^\\]]+)\\]`, 'g');
        for (const c of built.cols) {
          const f = String(c.formula || '');
          if (isNative) {
            for (const m of f.matchAll(/\[([^\]/]+)\]/g)) {
              const tok = m[1];
              if (controlBySlug.has(tok)) continue;
              if (isPassthroughSelf(c, tok) || !localNames.has(tok)) needed.add(tok);
            }
          } else {
            for (const m of f.matchAll(prefixed)) needed.add(m[1]);
          }
        }
        const srcPrefix = isNative ? '' : `${sourceName}/`;
        const baseCols: WbColumn[] = [...needed].map((n) => ({ id: sigmaShortId(), name: n, formula: `[${srcPrefix}${n}]` }));
        const baseEl: WbElement = {
          id: sigmaShortId(), kind: 'table', name: baseName,
          source: { ...source }, columns: baseCols, order: baseCols.map((c) => c.id),
        };
        baseTables.push(baseEl);
        // re-root the chart: source the base table, rewrite source refs through it
        el.source = { kind: 'table', elementId: baseEl.id };
        for (const c of built.cols) {
          if (typeof c.formula !== 'string') continue;
          if (isNative) {
            const orig = c.formula;
            c.formula = orig.replace(/\[([^\]/]+)\]/g, (whole, tok) => {
              if (controlBySlug.has(tok)) return whole;
              if (isPassthroughSelf(c, tok) || !localNames.has(tok)) return `[${baseName}/${tok}]`;
              return whole;
            });
          } else {
            c.formula = c.formula.split(`[${sourceName}/`).join(`[${baseName}/`);
          }
        }
        targetElId = baseEl.id;
        targetCols = baseCols;
        colByDisp = (disp) => baseCols.find((c) => c.name === disp);
      }

      for (const pt of pendingTargets) {
        const ctrl = controlBySlug.get(pt.slug);
        const tc = colByDisp(pt.disp);
        if (!ctrl || !tc) continue;
        let columnId = tc.id;
        if (pt.cast) {
          // numeric/datetime list target — bind through a hidden Text() cast
          let cast = targetCols.find((c) => c.name === `${pt.disp} (Text)`);
          if (!cast) {
            cast = { id: sigmaShortId(), name: `${pt.disp} (Text)`, formula: `Text([${pt.disp}])`, hidden: true };
            targetCols.push(cast);
            const holder = targetElId === el.id ? el : baseTables[baseTables.length - 1];
            if (holder.order) holder.order.push(cast.id);
          }
          columnId = cast.id;
        }
        (ctrl.filters ||= []).push({ source: { kind: 'table', elementId: targetElId }, columnId });
      }
    }

    el.columns = built.cols;
    el.order = built.order;
    return el;
  };

  // ── pages: one per dashboard tab (no tabs → single page) ─────────────────────
  const tabs: any[] = dash.tabs?.length ? dash.tabs : [null];
  const pages: WbPage[] = [];
  const layout: DashboardLayoutHint = { grid: 24, pages: [] };
  const builtPages: Array<{ name: string; els: WbElement[] }> = [];

  for (const tab of tabs) {
    const pageName = tab ? (tab.name || `Tab ${tab.id}`) : 'Page 1';
    const pageDcs = dcs
      .filter((d) => tab === null || (d.tabId ?? tabs[0]?.id) === tab.id)
      .sort((a, b) => a.row - b.row || a.col - b.col);
    const els: WbElement[] = [];
    const hints: DashboardLayoutHint['pages'][number]['elements'] = [];
    for (const dc of pageDcs) {
      const el = buildElement(dc);
      if (!el) continue;
      els.push(el);
      hints.push({ elementId: el.id, name: el.name || el.kind, row: dc.row, col: dc.col, sizeX: dc.sizeX, sizeY: dc.sizeY });
    }
    builtPages.push({ name: pageName, els });
    layout.pages.push({ name: pageName, elements: hints });
  }

  // Prune controls the converter KNOWS are furniture. A control is only LIVE if
  // it has a real Sigma wiring path: a formula reference (reachBySlug) or an
  // element `filters` target. Two failure modes are flagged, never shipped:
  //   1. field-filter parameters whose column is missing from every mapped
  //      card's result set (no target to bind).
  //   2. variable-tag parameters that only drive a DM-SQL {{tag}} (dmBoundSlugs).
  //      LIVE-DISPROVEN 2026-06-15 on a validation org: a workbook control bound
  //      only to a DM custom-SQL {{param}} is INERT — the export API ignores a
  //      text grain control entirely and a numeric one mis-substitutes and
  //      breaks the query (0 rows). The control lint rightly flags these dead.
  //      So they are NOT emitted; they go into `unreproducibleFilters` with a
  //      manual-remodel hint instead of shipping furniture that lies.
  const unreproducibleFilters: Array<{ controlId: string; name: string; reason: string; hint: string }> = [];
  const liveControls = controls.filter((c) => {
    const wired = reachBySlug.has(c.controlId) || (c.filters || []).length > 0;
    if (wired) return true;
    if (dmBoundSlugs.has(c.controlId)) {
      unreproducibleFilters.push({
        controlId: c.controlId, name: c.name,
        reason: 'drives a native {{tag}} consumed pre-aggregation inside custom SQL — a workbook control bound to a DM-SQL parameter is inert (live-disproven)',
        hint: 'rebuild as a native Sigma control: surface the underlying column/date in the element and filter/group on it (date-trunc control for granularity, relative-date filter for a window, list control for a value), or sync this control to the DM parameter in the Sigma UI.',
      });
      warnings.push(`control "${c.name}" [${c.controlId}] only drives a DM custom-SQL {{tag}} — NOT emitted (a workbook control bound to a DM-SQL parameter is inert, live-disproven). Listed in unreproducibleFilters with a remodel hint.`);
    } else {
      unreproducibleFilters.push({
        controlId: c.controlId, name: c.name,
        reason: 'its mapped column is not in any consuming element\'s result set (consumed then aggregated away inside SQL)',
        hint: 'add the column to the card\'s SELECT (and GROUP BY) so it lands in the result set, then this control binds as an element filter automatically.',
      });
      warnings.push(`control "${c.name}" [${c.controlId}] has no wirable target in any mapped card — control NOT emitted (it would be dead furniture; see the per-card warnings for the fix).`);
    }
    return false;
  });

  // Assemble pages: controls live on the first page, AFTER the elements they
  // target (a control whose `filters` target appears later in the spec fails
  // at POST — verified cross-plugin gotcha, refs/control-parity.md).
  let placedControls = false;
  for (const bp of builtPages) {
    const pageEls: WbElement[] = !placedControls && liveControls.length ? [...bp.els, ...(liveControls as any)] : bp.els;
    if (!placedControls && liveControls.length) placedControls = true;
    pages.push({ id: sigmaShortId(), name: bp.name, elements: pageEls });
  }

  // Hidden base-table sourcing roots live on a trailing "Data" page; its id
  // starts with "data" — the cross-plugin convention layout gates use to
  // exempt utility pages from dashboard-layout checks.
  if (baseTables.length) {
    pages.push({ id: `data${sigmaShortId()}`, name: 'Data', elements: baseTables });
  }

  // one aggregated warning per parameter that drives native template tags
  // (per-mapping warnings would be thousands of lines on production estates)
  if (tagWirings.length) {
    const bySlug = new Map<string, typeof tagWirings>();
    for (const w of tagWirings) { (bySlug.get(w.slug) || bySlug.set(w.slug, []).get(w.slug)!).push(w); }
    for (const [slug, ws] of bySlug) {
      const tags = [...new Set(ws.map((w) => w.tag))];
      warnings.push(`parameter "${ws[0].parameter}" (control "${slug}") drives native template tag${tags.length > 1 ? 's' : ''} {{${tags.join('}}, {{')}}} across ${ws.length} card(s) — the DM converter emits the matching {{tag}} control(s); consolidate: either reference the DM control directly or sync this workbook control's value to it (see parameterWiring in the result + refs/template-tags.md).`);
    }
  }

  const allEls = pages.filter((p) => p.name !== 'Data').flatMap((p) => p.elements).filter((e) => e.kind !== 'control');
  const stats = {
    dashcards: dcs.length,
    pages: pages.length,
    tables: allEls.filter((e) => e.kind === 'table').length,
    pivots: allEls.filter((e) => e.kind === 'pivot-table').length,
    kpis: allEls.filter((e) => e.kind === 'kpi-chart').length,
    charts: allEls.filter((e) => e.kind.endsWith('-chart') && e.kind !== 'kpi-chart').length,
    maps: allEls.filter((e) => e.kind.endsWith('-map')).length,
    texts: allEls.filter((e) => e.kind === 'text').length,
    columns: allEls.reduce((n, e) => n + (e.columns?.length || 0), 0),
    filters: allEls.reduce((n, e) => n + (e.filters?.length || 0), 0),
    controls: liveControls.length,
    baseTables: baseTables.length,
  };

  // control-scope.json sidecar (shared cross-plugin contract — control_lint.rb
  // header CONTRACT + refs/control-parity.md). Signals = mapped parameters;
  // scope = each control's DECLARED card targets (converted element names);
  // mustReach = the subset the converter actually wired. dm-bound controls
  // (variable-tag → control.parameters via remap --dm-spec) carry their scope
  // as declared intent — if the org rejects the binding, post-and-readback
  // drops them and patches this sidecar (see scripts/post-and-readback.mjs).
  const controlScope: ControlScopeSidecar = {
    version: 1, source: 'metabase',
    sourceFilterSignals: [...mappingCountByParam.keys()].filter((id) => paramById.has(id)).length,
    controls: liveControls.map((c) => ({
      controlId: c.controlId,
      sourceName: `Metabase parameter "${c.name}"${dmBoundSlugs.has(c.controlId) ? ' (drives native {{tag}}s via DM-parameter binding)' : ''}`,
      scope: [...(scopeBySlug.get(c.controlId) || [])],
      mustReach: [...(reachBySlug.get(c.controlId) || [])],
    })),
  };

  const documentPages = pages.map((page) => ({
    id: page.id,
    name: page.name,
    ...(page.name === 'Data' ? { visibility: 'hidden' } : {}),
  }));
  // Controls come after every element they target, including hidden Data-page
  // base tables. Forward filter targets are rejected by workbook CREATE.
  const flatElements = [
    ...pages.flatMap((page) => page.elements).filter((element) => element.kind !== 'control'),
    ...(liveControls as WbElement[]),
  ];
  const workbook = {
    name,
    document: {
      schemaVersion: 1,
      kind: 'workbook' as const,
      pages: documentPages,
      elements: flatElements,
      layout: buildWorkbookLayout(pages, layout),
    },
  };

  return {
    workbook,
    warnings, stats, layout, controlScope,
    ...(tagWirings.length ? { parameterWiring: tagWirings } : {}),
    ...(unreproducibleFilters.length ? { unreproducibleFilters } : {}),
  };
}
