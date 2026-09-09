// Smoke + contract tests on the bundled fixtures: node --import tsx/esm test.ts
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { applyWarehouseTransforms, convertMetabaseToSigma, recognizeSimpleNativeSql, buildFieldIndex } from './metabase.js';
import { convertMetabaseDashboardToSigma } from './metabase-dashboard.js';

const FIX = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures');
const read = (f: string) => JSON.parse(readFileSync(join(FIX, f), 'utf8'));
const wbDoc = (wb: any) => wb.document || wb;
const wbElements = (wb: any) => wbDoc(wb).elements
  || (wbDoc(wb).pages || []).flatMap((p: any) => p.elements || []);
const wbControls = (wb: any) => wbElements(wb).filter((e: any) => e.kind === 'control');
const pageHasElement = (wb: any, pageId: string, elementId: string) => {
  const layout = String(wbDoc(wb).layout || '');
  const page = layout.match(new RegExp(`<Page\\b[^>]*id="${pageId}"[^>]*>([\\s\\S]*?)<\\/Page>`));
  return !!page && new RegExp(`<Element\\b[^>]*elementId="${elementId}"`).test(page[1]);
};
let fail = 0;
const check = (group: string, label: string, ok: boolean) => {
  if (ok) console.log(`✓ ${group}: ${label}`);
  else { fail++; console.log(`✗ ${group}: ${label}`); }
};

const metadata = read('metadata.json');
const ordersModel = read('orders-model.card.json');
const revenueTrend = read('revenue-trend.card.json');
const nativeCard = read('top-customers-native.card.json');

// ── warehouse dialect transforms ─────────────────────────────────────────────
{
  const sql = 'SELECT ARRAY_AGG(REGION) AS REGIONS FROM DEMO_DB.DEMO.CUSTOMER_DIM';
  check('warehouse', 'BigQuery array aggregation becomes a renderable string',
    /array_to_string\(ARRAY_AGG\(REGION\), ', '\)/i.test(applyWarehouseTransforms(sql, 'bigquery')));
  const transformed = convertMetabaseToSigma(
    { metadata, cards: [{ ...nativeCard, dataset_query: {
      ...nativeCard.dataset_query,
      native: { ...nativeCard.dataset_query.native, query: sql, 'template-tags': {} },
    }}] },
    { connectionId: 'c', database: 'DEMO_DB', schema: 'DEMO', warehouse: 'bigquery' },
  );
  const statement = (transformed.model.pages[0].elements as any[])
    .find((e: any) => e.source?.kind === 'sql')?.source?.statement;
  check('warehouse', 'converter applies the selected warehouse transform without crashing',
    /array_to_string/i.test(statement || ''));
}

// ── cards → data model ────────────────────────────────────────────────────────
{
  const r = convertMetabaseToSigma(
    { metadata, cards: [ordersModel, revenueTrend, nativeCard] },
    { connectionId: 'conn1', database: 'DEMO_DB', schema: 'DEMO' },
  );
  const els = r.model.pages[0].elements as any[];
  const byName = (n: string) => els.find((e) => e.name === n);
  const orderFact = byName('Order Fact');
  const customerDim = byName('Customer Dim');
  const joinEl = byName('Orders Model');
  const sqlEl = els.find((e) => e.source?.kind === 'sql');
  const derived = byName('Order Fact View');
  const col = (el: any, n: string) => el?.columns?.find((c: any) => c.name === n);

  check('dm', 'schemaVersion is 1', (r.model as any).schemaVersion === 1);
  check('dm', 'warehouse-table elements for both referenced tables (path DEMO_DB/DEMO/TABLE)',
    JSON.stringify(orderFact?.source?.path) === JSON.stringify(['DEMO_DB', 'DEMO', 'ORDER_FACT'])
    && JSON.stringify(customerDim?.source?.path) === JSON.stringify(['DEMO_DB', 'DEMO', 'CUSTOMER_DIM']));
  check('dm', 'field-id resolution: plain column = inode id + [TABLE/Display] formula',
    orderFact?.columns?.some((c: any) => /^inode-.{22}\/SALES_AMOUNT$/.test(c.id) && c.formula === '[ORDER_FACT/Sales Amount]'));
  check('dm', 'join element: live contract — columns key, left-outer, named sides, [Display] refs',
    joinEl?.source?.kind === 'join'
    && typeof joinEl?.source?.name === 'string'
    && joinEl?.source?.joins?.[0]?.joinType === 'left-outer'
    && typeof joinEl?.source?.joins?.[0]?.name === 'string'
    && joinEl?.source?.joins?.[0]?.left?.connectionId !== undefined
    && joinEl?.source?.joins?.[0]?.columns?.[0]?.left === '[Customer Key]'
    && joinEl?.source?.joins?.[0]?.columns?.[0]?.right === '[Customer Key]');
  check('dm', 'arithmetic expression: Net Amount = ([Sales Amount] - [Discount Amount])',
    col(joinEl, 'Net Amount')?.formula === '([Sales Amount] - [Discount Amount])');
  check('dm', 'case → If, multi-value = → infix or chain (no IsIn, no Or() function — live-verified)',
    col(joinEl, 'Tier Bucket')?.formula === 'If(([Loyalty Tier] = "GOLD" or [Loyalty Tier] = "PLATINUM"), "Premium", "Standard")');
  check('dm', 'datetime-diff → DateDiff',
    col(orderFact, 'Days Since Order')?.formula === 'DateDiff("day", [Order Date], Now())');
  check('dm', 'breakout temporal-unit → DateTrunc calc column',
    col(orderFact, 'Order Date (Month)')?.formula === 'DateTrunc("month", [Order Date])');
  check('dm', 'named aggregation keeps its display-name (Total Revenue)',
    joinEl?.metrics?.some((m: any) => m.name === 'Total Revenue' && m.formula === 'Sum([Sales Amount])'));
  check('dm', 'unnamed aggregation derives a name (Sum of Sales Amount)',
    orderFact?.metrics?.some((m: any) => m.name === 'Sum of Sales Amount' && m.formula === 'Sum([Sales Amount])'));
  check('dm', 'card filter NOT applied to the shared element (warned instead)',
    !orderFact?.filters && r.warnings.some((w) => /NOT applied to the shared/.test(w) && /DateAdd\("day", -365, Today\(\)\)/.test(w)));
  check('dm', 'native SQL card → sql-source element with NO element-level name',
    !!sqlEl && sqlEl.name === undefined && /SELECT/.test(sqlEl.source.statement));
  check('dm', 'native sql columns are [Custom SQL/RAW_ALIAS] refs with names (bare refs error live)',
    sqlEl?.columns?.some((c: any) => /^\[Custom SQL\//.test(c.formula) && typeof c.name === 'string'));
  check('dm', 'plain text {{tag}} warns with the control to create',
    r.warnings.some((w) => /\{\{region\}\}/.test(w) && /control/.test(w) && /"region"/.test(w)));
  check('dm', 'dimension {{tag}} (field filter) is flagged',
    r.warnings.some((w) => /\{\{order_date\}\}/.test(w) && /FIELD FILTER/.test(w)));
  check('dm', 'FK metadata → relationship CUSTOMER_DIM on the fact element',
    orderFact?.relationships?.length === 1
    && orderFact.relationships[0].name === 'CUSTOMER_DIM'
    && orderFact.relationships[0].targetElementId === customerDim?.id
    && orderFact.relationships[0].keys?.[0]?.sourceColumnId && orderFact.relationships[0].keys?.[0]?.targetColumnId);
  check('dm', 'STORE_DIM FK skipped (table not referenced — both tables must be present)',
    !els.some((e) => e.name === 'Store Dim') && orderFact?.relationships?.length === 1);
  check('dm', 'derived join view exists and exposes dim columns',
    !!derived && derived.columns.some((c: any) => c.formula === '[Order Fact/CUSTOMER_DIM/Region]'));
  check('dm', 'derived view SKIPS the relationship key column (no Customer Key passthrough)',
    !!derived && !derived.columns.some((c: any) => c.formula === '[Order Fact/CUSTOMER_DIM/Customer Key]'));
}

// ── nested questions (source-table "card__N") ────────────────────────────────
{
  const nested = {
    id: 300, name: 'Premium Orders', type: 'question', display: 'table', database_id: 2,
    dataset_query: { type: 'query', database: 2, query: { 'source-table': 'card__100' } },
    result_metadata: [],
  };
  const r = convertMetabaseToSigma({ metadata, cards: [ordersModel, nested] }, { connectionId: 'c', database: 'DEMO_DB', schema: 'DEMO' });
  const els = r.model.pages[0].elements as any[];
  const parent = els.find((e) => e.name === 'Orders Model');
  const child = els.find((e) => e.name === 'Premium Orders');
  check('nested', 'in-input nested card → element sourced from card 100\'s element',
    !!child && child.source?.kind === 'table' && child.source?.elementId === parent?.id);

  const r2 = convertMetabaseToSigma({ metadata, cards: [nested] }, { connectionId: 'c', database: 'DEMO_DB' });
  check('nested', 'missing source card → warning + skip',
    !(r2.model.pages[0].elements as any[]).some((e: any) => e.name === 'Premium Orders')
    && r2.warnings.some((w) => /card 100/.test(w) && /NOT in the input set/.test(w)));
}

// ── learned rules hook (applied before built-in translation) ─────────────────
{
  const r = convertMetabaseToSigma(
    { metadata, cards: [revenueTrend] },
    { connectionId: 'c', database: 'DEMO_DB', learnedRules: [{ pattern: '\\["datetime-diff",.*"day"\\]', template: 'DaysBetween()' }] },
  );
  const of = (r.model.pages[0].elements as any[]).find((e) => e.name === 'Order Fact');
  check('rules', 'learned rule overrides the built-in translation',
    of?.columns?.some((c: any) => c.name === 'Days Since Order' && c.formula === 'DaysBetween()'));
}

// ── sandboxing detection (detect-only) ───────────────────────────────────────
{
  const r = convertMetabaseToSigma({
    metadata, cards: [revenueTrend],
    sandboxes: [{ table_id: 45, group_id: 7, attribute_remappings: { region: ['dimension', ['field', 85, null]] } }],
  }, { connectionId: 'c', database: 'DEMO_DB' });
  check('security', 'sandbox → security entry (row-filter, group, readable expression)',
    (r as any).security?.length === 1
    && (r as any).security[0].type === 'row-filter'
    && (r as any).security[0].groups?.[0] === 7
    && /\[Region\] = user attribute "region"/.test((r as any).security[0].expression));
  check('security', 'security is detect-only — no filters injected into the model',
    !(r.model.pages[0].elements as any[]).some((e: any) => e.filters?.length)
    && r.warnings.some((w) => /SECURITY/.test(w) && /NOT ported/.test(w)));
}

// ── dashboard → workbook ─────────────────────────────────────────────────────
{
  const r = convertMetabaseDashboardToSigma(read('exec-overview.dashboard.json'),
    { metadata, cardNameById: { 100: 'Orders Model' } });
  const wb = r.workbook;
  const doc = wbDoc(wb);
  const els = wbElements(wb) as any[];
  const controls = wbControls(wb);
  const byName = (n: string) => els.find((e) => e.name === n);

  check('wb', 'released code rep: document wrapper, flat elements, metadata-only pages, canonical layout',
    doc.schemaVersion === 1 && doc.kind === 'workbook' && Array.isArray(doc.elements)
    && doc.pages.every((p: any) => !('elements' in p))
    && /<Page\b/.test(doc.layout) && /<Element\b/.test(doc.layout)
    && !/<LayoutElement\b/.test(doc.layout));
  check('wb', 'one page per dashboard tab (Overview, Detail) + hidden trailing Data page',
    doc.pages.length === 3 && doc.pages[0].name === 'Overview' && doc.pages[1].name === 'Detail'
    && doc.pages[2].name === 'Data' && doc.pages[2].id.startsWith('data')
    && doc.pages[2].visibility === 'hidden');
  check('wb', 'text dashcard → text element with the markdown in body (live contract)',
    els.some((e) => e.kind === 'text' && /## Executive Overview/.test((e as any).body)));
  const kpi = byName('Total Revenue');
  check('wb', 'scalar → kpi-chart with value {columnId} (NOT {id})',
    kpi?.kind === 'kpi-chart' && !!kpi.value?.columnId && kpi.value?.id === undefined);
  check('wb', 'column_settings currency/decimals → Sigma format on the KPI column',
    kpi?.columns?.some((c: any) => c.format?.formatString === '$,.0f'));
  const line = byName('Revenue Trend');
  check('wb', 'line → line-chart with x dim + y metric matched through result_metadata',
    line?.kind === 'line-chart' && !!line.xAxis?.columnId && line.yAxis?.columnIds?.length === 1);
  const lineBase = byName('Revenue Trend Base');
  check('wb', 'range-mapped chart re-rooted through a base TABLE on the Data page (control targets need a table)',
    lineBase?.kind === 'table' && lineBase?.source?.kind === 'data-model' && lineBase?.source?.elementId === 'Order Fact'
    && pageHasElement(wb, doc.pages[2].id, lineBase.id)
    && line?.source?.kind === 'table' && line?.source?.elementId === lineBase.id);
  check('wb', 'line x column is the DateTrunc breakout rewritten through the base table',
    line?.columns?.some((c: any) => c.formula === 'DateTrunc("month", [Revenue Trend Base/Order Date])')
    && lineBase?.columns?.some((c: any) => c.name === 'Order Date' && c.formula === '[Order Fact/Order Date]'));
  const bar = byName('Customers by Region');
  check('wb', 'bar → bar-chart with orientation key OMITTED (vertical)',
    bar?.kind === 'bar-chart' && !('orientation' in bar));
  const row = byName('Customers by Loyalty Tier');
  check('wb', 'row → bar-chart with orientation "horizontal" (the only valid value)',
    row?.kind === 'bar-chart' && row.orientation === 'horizontal');
  const pie = byName('Stores by State');
  check('wb', 'pie → pie-chart with columnId slice + value',
    pie?.kind === 'pie-chart' && !!pie.color?.columnId && !!pie.value?.columnId
    && pie.color?.id === undefined && pie.value?.id === undefined);
  const pivot = byName('Revenue by Region and Tier');
  check('wb', 'pivot → rowsBy/columnsBy as [{columnId}] objects + values as bare id strings',
    pivot?.kind === 'pivot-table'
    && pivot.rowsBy?.length === 1 && typeof pivot.rowsBy[0] === 'object' && !!pivot.rowsBy[0].columnId
    && pivot.columnsBy?.length === 1 && !!pivot.columnsBy[0].columnId
    && pivot.values?.length === 1 && typeof pivot.values[0] === 'string');
  check('wb', 'explicit-join card sources its own card-named join element (exact columns, no dedup suffixes)',
    pivot?.source?.elementId === 'Revenue by Region and Tier');
  const funnel = byName('Tier Funnel');
  check('wb', 'funnel → native funnel-chart with columnId channels',
    funnel?.kind === 'funnel-chart' && !!funnel.stage?.columnId && !!funnel.series?.columnId);
  check('wb', 'nested-question dashcard → source placeholder is the model name',
    byName('Premium Orders')?.source?.elementId === 'Orders Model');
  check('wb', 'nested card MBQL filter → hidden bool column + element filter [true]',
    byName('Premium Orders')?.columns?.some((c: any) => c.hidden && c.formula === '[Orders Model/Tier Bucket] = "Premium"')
    && byName('Premium Orders')?.filters?.some((f: any) => f.kind === 'list' && f.mode === 'include' && f.values[0] === true));
  const dateCtl = controls.find((c: any) => c.controlId === 'date_range');
  check('wb', 'parameters → controls wired by slug (date/range → date-range mode "between", string/= → list)',
    dateCtl?.controlType === 'date-range' && (dateCtl as any)?.mode === 'between'
    && controls.some((c: any) => c.controlId === 'region' && c.controlType === 'list'));
  check('wb', 'relative range default dropped with a warning (no verified Sigma spec shape)',
    dateCtl?.value === undefined && r.warnings.some((w) => /range default "past30days"/.test(w)));
  const barBase = byName('Customers by Region Base');
  const regionCtl = controls.find((c: any) => c.controlId === 'region') as any;
  check('wb', 'list parameter_mapping → control `filters` target on the chart\'s base table (NO boolean match column — list-control formula refs error live)',
    regionCtl?.filters?.length === 1
    && regionCtl.filters[0].source?.kind === 'table'
    && regionCtl.filters[0].source?.elementId === barBase?.id
    && regionCtl.filters[0].columnId === barBase?.columns?.find((c: any) => c.name === 'Region')?.id
    && !bar?.columns?.some((c: any) => /= \[region\]/.test(String(c.formula))));
  check('wb', 'range parameter_mapping → control `filters` target on the base table column (not boolean equality)',
    (dateCtl as any)?.filters?.length === 1
    && (dateCtl as any).filters[0].source?.kind === 'table'
    && (dateCtl as any).filters[0].source?.elementId === lineBase?.id
    && (dateCtl as any).filters[0].columnId === lineBase?.columns?.find((c: any) => c.name === 'Order Date')?.id
    && !line?.columns?.some((c: any) => /= \[date_range\]/.test(String(c.formula))));
  check('wb', 'element source placeholders are DM element NAMES on data-model sources (remap rewrites); mapped charts re-root through their base',
    row?.source?.kind === 'data-model' && row?.source?.elementId === 'Customer Dim'
    && bar?.source?.kind === 'table' && bar?.source?.elementId === barBase?.id);
  check('wb', 'controls placed AFTER the elements they target in spec order (POST rejects forward targets)',
    controls.every((control: any) => (control.filters || []).every((filter: any) => {
      const targetIndex = els.findIndex((e: any) => e.id === filter.source?.elementId);
      return targetIndex >= 0 && els.indexOf(control) > targetIndex;
    })));
  check('wb', 'control-scope sidecar: signals = mapped params; scope/mustReach = declared targets',
    r.controlScope.sourceFilterSignals === 2
    && r.controlScope.controls.length === 2
    && JSON.stringify(r.controlScope.controls.find((c) => c.controlId === 'date_range')?.scope) === '["Revenue Trend"]'
    && JSON.stringify(r.controlScope.controls.find((c) => c.controlId === 'region')?.mustReach) === '["Customers by Region"]');
  check('wb', 'layout hints preserve the 1:1 24-col grid',
    r.layout.grid === 24
    && r.layout.pages[0].elements.some((h) => h.name === 'Revenue Trend' && h.col === 5 && h.sizeX === 10 && h.sizeY === 6));
  check('wb', 'click_behavior flagged', r.warnings.some((w) => /click_behavior/.test(w)));
}

// ── current native visualization/channel contract ───────────────────────────
{
  const source = read('exec-overview.dashboard.json');
  const clone = (dc: any, id: number, display: string, name: string, vs: any = {}) => {
    const next = JSON.parse(JSON.stringify(dc));
    next.id = id; next.card_id = id; next.dashboard_tab_id = null;
    next.row = (id - 300) * 6; next.col = 0;
    next.parameter_mappings = [];
    next.card.id = id; next.card.display = display; next.card.name = name;
    next.card.visualization_settings = vs;
    return next;
  };
  const scalar = source.dashcards.find((d: any) => d.card?.display === 'scalar');
  const bar = source.dashcards.find((d: any) => d.card?.display === 'bar');
  const pivot = source.dashcards.find((d: any) => d.card?.display === 'pivot');
  const dash = {
    name: 'Native Viz Contract',
    parameters: [],
    dashcards: [
      clone(scalar, 300, 'gauge', 'Gauge Native'),
      clone(bar, 301, 'waterfall', 'Waterfall Native',
        { 'graph.dimensions': ['REGION'], 'graph.metrics': ['count'] }),
      clone(pivot, 302, 'sankey', 'Sankey Native',
        { 'graph.dimensions': ['REGION', 'LOYALTY_TIER'], 'graph.metrics': ['sum'] }),
      clone(bar, 303, 'map', 'Region Map Native',
        { 'graph.dimensions': ['REGION'], 'graph.metrics': ['count'], 'map.type': 'region', 'map.region': 'us_states' }),
      clone(scalar, 304, 'progress', 'Progress Fallback'),
    ],
  };
  const r = convertMetabaseDashboardToSigma(dash, { metadata });
  const els = wbElements(r.workbook);
  const named = (name: string) => els.find((e: any) => e.name === name) as any;
  check('native-viz', 'gauge emits native value.columnId',
    named('Gauge Native')?.kind === 'gauge-chart' && !!named('Gauge Native')?.value?.columnId);
  check('native-viz', 'waterfall emits current cartesian channels',
    named('Waterfall Native')?.kind === 'waterfall-chart'
    && !!named('Waterfall Native')?.xAxis?.columnId
    && named('Waterfall Native')?.yAxis?.columnIds?.length === 1);
  check('native-viz', 'sankey emits stages/value columnId pointers',
    named('Sankey Native')?.kind === 'sankey-chart'
    && named('Sankey Native')?.stages?.length === 2
    && named('Sankey Native')?.stages.every((s: any) => !!s.columnId)
    && !!named('Sankey Native')?.value?.columnId);
  check('native-viz', 'region map emits region.columnId',
    named('Region Map Native')?.kind === 'region-map'
    && !!named('Region Map Native')?.region?.columnId
    && named('Region Map Native')?.region?.id === undefined);
  check('native-viz', 'progress remains a loud data-preserving table fallback',
    named('Progress Fallback (was progress)')?.kind === 'table'
    && r.warnings.some((w) => /Progress Fallback.*no faithful native Sigma mapping/.test(w)));
}

// ── legacy ordered_cards (sizeX/sizeY) ───────────────────────────────────────
{
  const r = convertMetabaseDashboardToSigma(read('legacy-grid.dashboard.json'), { metadata });
  const els = wbElements(r.workbook) as any[];
  check('legacy', 'ordered_cards accepted — both dashcards converted on one page',
    wbDoc(r.workbook).pages.length === 1 && els.filter((e) => e.kind !== 'control').length === 2);
  check('legacy', 'sizeX/sizeY geometry flows into the layout hints',
    r.layout.pages[0].elements.some((h) => h.sizeX === 12 && h.sizeY === 6));
  check('legacy', 'kpi value {columnId} on the legacy scalar too',
    els.some((e) => e.kind === 'kpi-chart' && !!e.value?.columnId));
}

// ── pMBQL (modern "lib/" MBQL — 100% of a 7k-card production estate) ─────────
{
  const cards = ['pmbql-native', 'pmbql-native-tags', 'pmbql-structured', 'pmbql-joins', 'pmbql-expressions', 'pmbql-multistage']
    .map((f) => read(`${f}.card.json`));
  const r = convertMetabaseToSigma({ metadata, cards }, { connectionId: 'c', database: 'DEMO_DB', schema: 'DEMO' });
  const els = r.model.pages[0].elements as any[];
  const sqlEls = els.filter((e) => e.source?.kind === 'sql');
  const ctrl = (id: string) => els.find((e) => e.kind === 'control' && e.controlId === id);
  // pmbql-native is a SIMPLE single-SELECT → auto-remodeled to a native model (no
  // sql element); pmbql-native-tags has variable tags → stays a custom-SQL element.
  check('pmbql', 'simple native stage → native model; tagged native stage stays sql (1 sql element)',
    sqlEls.length === 1
    && r.warnings.some((w) => /Daily Revenue \(pMBQL Native\).*auto-remodeled to a NATIVE Sigma data model/.test(w)));
  const tagged = sqlEls.find((e) => /JOIN DEMO_DB.DEMO.CUSTOMER_DIM/.test(e.source.statement));
  check('pmbql', 'plain {{region}} kept verbatim (Sigma uses the same syntax) + text control emitted',
    /\{\{region\}\}/.test(tagged?.source.statement || '')
    && ctrl('region')?.controlType === 'text' && ctrl('region')?.value === 'West');
  check('pmbql', 'number tag → number control with default',
    ctrl('min_qty')?.controlType === 'number' && ctrl('min_qty')?.value === 1);
  check('pmbql', 'field-filter tag neutralized to 1=1 + brace-free comment (Sigma parses {{}} in comments)',
    /1=1 \/\* Metabase field filter 'order_date' → filter \[Order Date\]/.test(tagged?.source.statement || '')
    && !/\{\{order_date\}\}/.test(tagged?.source.statement || ''));
  check('pmbql', 'optional [[…]] block without a default DROPPED + warned',
    !/\{\{tier\}\}/.test(tagged?.source.statement || '') && r.warnings.some((w) => /\[\[…\]\] block DROPPED/.test(w) && /tier/.test(w)));
  check('pmbql', 'card tag {{#400…}} inlined as a sub-select from the referenced native card',
    /\(\nSELECT ORDER_DATE, SUM\(SALES_AMOUNT\)/.test(tagged?.source.statement || ''));
  const of = els.find((e) => e.name === 'Order Fact');
  check('pmbql', 'named pMBQL aggregation (display-name in opts) → Total Revenue metric',
    of?.metrics?.some((m: any) => m.name === 'Total Revenue' && m.formula === 'Sum([Sales Amount])')
    && of?.metrics?.some((m: any) => m.name === 'Count' && m.formula === 'Count()'));
  check('pmbql', 'opts-second temporal-unit breakout → DateTrunc week calc',
    of?.columns?.some((c: any) => c.name === 'Order Date (Week)' && c.formula === 'DateTrunc("week", [Order Date])'));
  check('pmbql', 'filters array AND-merged; pMBQL "in" → Or chain (warned on the shared element)',
    r.warnings.some((w) => /\(\[Order Number\] = 100 or \[Order Number\] = 200\)/.test(w))
    && r.warnings.some((w) => /\[Order Date\] >= DateAdd\("month", -6, Today\(\)\)/.test(w)));
  const joinEl = els.find((e) => e.name === 'Orders with Customers (pMBQL Join)');
  check('pmbql', 'pMBQL join {stages, conditions} → join source on Customer Key (live shape)',
    joinEl?.source?.kind === 'join' && joinEl?.source?.joins?.[0]?.joinType === 'left-outer'
    && joinEl?.source?.joins?.[0]?.columns?.[0]?.left === '[Customer Key]');
  check('pmbql', 'expression list (lib/expression-name) → calc columns: case→If, date()→DateTrunc day',
    of?.columns?.some((c: any) => c.name === 'Size Bucket' && c.formula === 'If([Sales Amount] > 1000, "Large", "Small")')
    && of?.columns?.some((c: any) => c.name === 'Days to Now' && c.formula === 'DateDiff("day", [Order Date], Now())')
    && of?.columns?.some((c: any) => c.name === 'Order Day' && c.formula === 'DateTrunc("day", [Order Date])'));
  check('pmbql', 'multi-stage card flagged + skipped (never silently mistranslated)',
    r.warnings.some((w) => /MULTI-STAGE/.test(w) && /Average Weekly Revenue/.test(w))
    && !els.some((e) => e.name === 'Average Weekly Revenue (pMBQL Multi-Stage)'));
}

// ── legacy_query preference (server's own down-conversion wins when present) ──
{
  const { normalizeCard } = await import('./pmbql-normalize.mjs');
  const card = {
    id: 1, name: 'lq', dataset_query: { 'lib/type': 'mbql/query', database: 2, stages: [{ 'lib/type': 'mbql.stage/native', native: 'SELECT 2' }] },
    legacy_query: JSON.stringify({ type: 'native', database: 2, native: { query: 'SELECT 1', 'template-tags': {} } }),
  };
  const n = normalizeCard(card);
  check('pmbql', 'legacy_query JSON string preferred over re-normalizing',
    n.dataset_query.type === 'native' && n.dataset_query.native.query === 'SELECT 1');
  const n2 = normalizeCard({ ...card, legacy_query: 'not json {' });
  check('pmbql', 'unparseable legacy_query falls back to the normalizer',
    n2.dataset_query.type === 'native' && n2.dataset_query.native.query === 'SELECT 2');
}

// ── pMBQL dashboard: tag wiring, conditional formats, series settings, object ─
{
  const r = convertMetabaseDashboardToSigma(read('pmbql-params.dashboard.json'), { metadata });
  const els = wbElements(r.workbook) as any[];
  const controls = wbControls(r.workbook);
  const table = els.find((e) => e.name === 'Filtered Revenue (pMBQL Native + Tags)');
  const bar = els.find((e) => e.name === 'Weekly Orders by Region (pMBQL)');
  check('pmbql-wb', 'date/range dimension parameter → live date-range control (real filter target)',
    controls.some((c: any) => c.controlId === 'order_window' && c.controlType === 'date-range'));
  check('pmbql-wb', 'variable + field-filter template-tag targets recorded in parameterWiring',
    (r.parameterWiring || []).some((w) => w.slug === 'region_param' && w.tag === 'region' && w.kind === 'variable')
    && (r.parameterWiring || []).some((w) => w.slug === 'order_date_param' && w.tag === 'order_date' && w.kind === 'field-filter'));
  check('pmbql-wb', 'tag wiring warnings AGGREGATED (one per parameter, not per mapping)',
    r.warnings.filter((w) => /drives native template tag/.test(w)).length === 2);
  const barBase = els.find((e) => e.name === 'Weekly Orders by Region (pMBQL) Base');
  const owCtl = controls.find((c: any) => c.controlId === 'order_window') as any;
  check('pmbql-wb', 'pMBQL dimension target (opts-second field) on a date/range param → base-table control filter target',
    barBase?.kind === 'table'
    && bar?.source?.elementId === barBase?.id
    && owCtl?.filters?.[0]?.source?.elementId === barBase?.id
    && !bar?.columns?.some((c: any) => /= \[order_window\]$/.test(String(c.formula))));
  check('pmbql-wb', 'unwirable field-filter control NOT emitted (column missing from every mapped result set)',
    !controls.some((c: any) => c.controlId === 'order_date_param')
    && r.warnings.some((w) => /order_date_param.*NOT emitted|control "Order Date".*NOT emitted/i.test(w)));
  check('pmbql-wb', 'variable-tag-only control NOT emitted (DM-SQL {{tag}} binding is inert, live-disproven) and listed in unreproducibleFilters',
    !controls.some((c: any) => c.controlId === 'region_param')
    && (r.unreproducibleFilters || []).some((u) => u.controlId === 'region_param' && /inert|pre-aggregation/.test(u.reason)));
  check('pmbql-wb', 'table.column_formatting single rule → conditionalFormats; range rule flagged',
    table?.conditionalFormats?.length === 1
    && table.conditionalFormats[0].condition === '>'
    && table.conditionalFormats[0].style?.backgroundColor === '#22c55e'
    && r.warnings.some((w) => /gradient\/range/.test(w)));
  check('pmbql-wb', 'series_settings title renames the series column',
    bar?.columns?.some((c: any) => c.name === 'Revenue ($)')
    && r.warnings.some((w) => /per-series color/.test(w)));
  check('pmbql-wb', 'object display → flagged detail-view table',
    els.some((e) => e.kind === 'table' && e.name === 'Order Record (object detail)')
    && r.warnings.some((w) => /object DETAIL view/.test(w)));
  check('pmbql-wb', 'virtual text card still passes markdown through (body field)',
    els.some((e) => e.kind === 'text' && /## Ops Notes/.test((e as any).body)));
}

// ── control-targeting: unmapped parameters are furniture in Metabase too ─────
{
  const d = read('exec-overview.dashboard.json');
  d.parameters = [...(d.parameters || []), { id: 'pX', name: 'Orphan Filter', slug: 'orphan', type: 'string/=' }];
  const r = convertMetabaseDashboardToSigma(d, { metadata, cardNameById: { 100: 'Orders Model' } });
  check('scope', 'parameter with zero parameter_mappings → NO control + loud warning',
    !wbControls(r.workbook).some((c: any) => c.controlId === 'orphan')
    && r.warnings.some((w) => /"Orphan Filter".*NO parameter_mappings/.test(w)));
  check('scope', 'unmapped parameter not counted in sourceFilterSignals',
    r.controlScope.sourceFilterSignals === 2);
}

// ── BigQuery estate: paths/casing/dialect (Sigma side LIVE-verified 2026-06-11
// against conn bc534032 "BigQuery- Wells"; Metabase side fixture-shaped) ────────
{
  const bq = read('bq-estate.card.json');
  // NO --database flag: project must come from metadata.details['project-id'].
  const r = convertMetabaseToSigma(bq, { connectionId: 'connBQ' });
  const els = r.model.pages[0].elements as any[];
  const orders = els.find((e) => e.name === 'Data Order');
  const customers = els.find((e) => e.name === 'Dim Customer');
  const joinEl = els.find((e) => e.name === 'Revenue by Region (BQ join)');
  const sqlEl = els.find((e) => e.source?.kind === 'sql');

  check('bq', 'project auto-derived from details.project-id, case-preserved lowercase table tail',
    JSON.stringify(orders?.source?.path) === JSON.stringify(['acme-data-lake', 'dbt_prod', 'data_order']));
  check('bq', 'per-table dataset wins (estate spans datasets — no global --schema)',
    JSON.stringify(customers?.source?.path) === JSON.stringify(['acme-data-lake', 'dbt_core', 'dim_customer']));
  check('bq', 'warehouse column prefix matches the lowercase path tail',
    orders?.columns?.some((c: any) => c.formula === '[data_order/Order Id]'));
  check('bq', 'BQ-dialect native SQL verbatim (backticks + trailing comma preserved)',
    /`acme-data-lake\.dbt_prod\.data_order`/.test(sqlEl?.source?.statement || '')
    && /as n_orders,\s*from/.test(sqlEl?.source?.statement || ''));
  check('bq', 'join source/relationship names case-preserved + prettified condition refs',
    joinEl?.source?.name === 'data_order'
    && joinEl?.source?.joins?.[0]?.name === 'dim_customer'
    && joinEl?.source?.joins?.[0]?.columns?.[0]?.left === '[Customer Id]'
    && orders?.relationships?.some((x: any) => x.name === 'dim_customer'));
}

// ── the two pmbql-normalize.mjs copies must stay byte-identical ──────────────
{
  const here = dirname(fileURLToPath(import.meta.url));
  const a = readFileSync(join(here, 'pmbql-normalize.mjs'), 'utf8');
  const b = readFileSync(join(here, '..', '..', 'metabase-assessment', 'scripts', 'pmbql-normalize.mjs'), 'utf8');
  check('sync', 'converter + assessment pmbql-normalize.mjs copies are byte-identical', a === b);
}

// ── native-SQL → NATIVE-MODEL recognizer (auto-remodel + safety bails) ───────
{
  const meta = { tables: [
    { id: 1, name: 'ORDER_FACT', schema: 'DEMO', fields: [
      { id: 101, name: 'CUSTOMER_KEY', base_type: 'type/Integer' },
      { id: 102, name: 'NET_REVENUE', base_type: 'type/Float' }] },
    { id: 2, name: 'CUSTOMER_DIM', schema: 'DEMO', fields: [
      { id: 201, name: 'CUSTOMER_KEY', base_type: 'type/Integer' },
      { id: 202, name: 'REGION', base_type: 'type/Text' },
      { id: 203, name: 'LAST_NAME', base_type: 'type/Text' }] }] };
  const fidx = buildFieldIndex(meta);
  const ff = (name: string, fid: number) => ({ [name]: { id: 't', name, 'display-name': name, type: 'dimension', dimension: ['field', fid, null], 'widget-type': 'string/=' } });
  const card = (q: string, tags?: any) => ({ id: 9, name: 'Native', display: 'bar',
    dataset_query: { type: 'native', database: 2, native: { query: q, 'template-tags': tags || {} } },
    result_metadata: [{ name: 'REGION', display_name: 'Region' }, { name: 'NET_REVENUE', display_name: 'Net Revenue' }],
    visualization_settings: { 'graph.dimensions': ['REGION'], 'graph.metrics': ['NET_REVENUE'] } });
  const JOIN = 'from DEMO_DB.DEMO.ORDER_FACT f join DEMO_DB.DEMO.CUSTOMER_DIM c on f.CUSTOMER_KEY = c.CUSTOMER_KEY';

  const simple = card(`select c.REGION as REGION, sum(f.NET_REVENUE) as NET_REVENUE ${JOIN} where {{last_name}} group by c.REGION`, ff('last_name', 203));
  const rm = recognizeSimpleNativeSql(simple, fidx);
  check('remodel', 'simple SELECT+JOIN+GROUP BY → structured native model + surfaces field-filter dim',
    !!rm && rm.query['source-table'] === 1 && rm.query.joins?.length === 1 && rm.query.aggregation?.length === 1
    && rm.resultMetadata.some((r: any) => r.name === 'LAST_NAME' && r.field_ref[1] === 203));
  const dmR = convertMetabaseToSigma({ metadata: meta, cards: [simple] }, { connectionId: 'c', database: 'DEMO_DB' });
  check('remodel', 'remodeled card emits a NATIVE element (join source), NO sql element',
    !dmR.model.pages[0].elements.some((e: any) => e.source?.kind === 'sql')
    && dmR.model.pages[0].elements.some((e: any) => e.source?.kind === 'join'));
  // the field filter wires to a LIVE control with a real element-filter target
  const dash = { name: 'D', parameters: [{ id: 'p', name: 'Last Name', slug: 'last_name', type: 'string/=', sectionId: 'string' }],
    dashcards: [{ id: 1, card_id: 9, row: 0, col: 0, size_x: 12, size_y: 8, card: simple,
      parameter_mappings: [{ parameter_id: 'p', card_id: 9, target: ['dimension', ['template-tag', 'last_name']] }] }] };
  const wbR = convertMetabaseDashboardToSigma(dash, { metadata: meta });
  const lnCtrl = wbControls(wbR.workbook).find((c: any) => c.controlId === 'last_name') as any;
  check('remodel', 'field-filter param → LIVE control with a real element-filter target (not dead furniture)',
    !!lnCtrl && (lnCtrl.filters || []).length > 0 && !(wbR.unreproducibleFilters || []).some((u) => u.controlId === 'last_name'));

  // SAFETY BAILS — never silently mistranslate
  check('remodel', 'real WHERE predicate → bail to custom SQL (no silent filter drop)',
    recognizeSimpleNativeSql(card(`select c.REGION as REGION, sum(f.NET_REVENUE) as NET_REVENUE ${JOIN} where f.NET_REVENUE > 100 and {{last_name}} group by c.REGION`, ff('last_name', 203)), fidx) === null);
  check('remodel', 'LIMIT → bail', recognizeSimpleNativeSql(card('select c.REGION as REGION from DEMO_DB.DEMO.CUSTOMER_DIM c group by c.REGION limit 10'), fidx) === null);
  check('remodel', 'CASE / CTE / subquery / window → bail',
    recognizeSimpleNativeSql(card('select case when 1=1 then 2 end as x from DEMO_DB.DEMO.ORDER_FACT f'), fidx) === null
    && recognizeSimpleNativeSql(card('with t as (select 1) select * from t'), fidx) === null
    && recognizeSimpleNativeSql(card('select count(*) n from DEMO_DB.DEMO.ORDER_FACT f where id in (select id from DEMO_DB.DEMO.CUSTOMER_DIM c)'), fidx) === null);
  check('remodel', 'variable (non-field-filter) tag → bail (needs custom-SQL substitution)',
    recognizeSimpleNativeSql(card(`select c.REGION as REGION ${JOIN} where c.REGION = {{region}} group by c.REGION`, { region: { id: 't', name: 'region', type: 'text' } }), fidx) === null);
  check('remodel', 'unknown table/column → bail', recognizeSimpleNativeSql(card('select x from NOPE.NOPE.NOPE n'), fidx) === null);
  check('remodel', 'no metadata → bail (safe)', recognizeSimpleNativeSql(simple, undefined) === null);

  // trailing semicolon must be stripped from custom-SQL fallback (Sigma wraps the
  // statement as a subquery → trailing `;` is a POST syntax error). CTE → not remodeled.
  const semi = { id: 7, name: 'Semi', display: 'table',
    dataset_query: { type: 'native', database: 2, native: {
      query: 'with t as (select region from DEMO_DB.DEMO.CUSTOMER_DIM) select * from t order by region;', 'template-tags': {} } },
    result_metadata: [{ name: 'region', display_name: 'Region' }] };
  const semiR = convertMetabaseToSigma({ metadata: meta, cards: [semi] }, { connectionId: 'c', database: 'DEMO_DB' });
  const semiEl = semiR.model.pages[0].elements.find((e: any) => e.source?.kind === 'sql');
  check('remodel', 'custom-SQL fallback strips trailing semicolon (no subquery-wrap break)',
    !!semiEl && !/;\s*$/.test(semiEl.source.statement) && /order by region$/i.test(semiEl.source.statement.trim()));
}

// ── every fixture converts without throwing ──────────────────────────────────
for (const f of readdirSync(FIX).sort()) {
  try {
    if (f.endsWith('.card.json')) {
      const j = read(f);
      // self-contained bundles ({metadata, cards}) carry their own engine metadata
      const r = j.cards
        ? convertMetabaseToSigma(j, { connectionId: 'c' })
        : convertMetabaseToSigma({ metadata, cards: [j] }, { connectionId: 'c', database: 'DEMO_DB', schema: 'DEMO' });
      // a lone flagged card (e.g. multi-stage) may legitimately produce 0 elements — but never silently
      if (!r.model.pages[0].elements.length && !r.warnings.length) throw new Error('no elements and no warnings');
      console.log(`✓ ${f.padEnd(36)} cards → ${r.stats.elements} elems · ${r.stats.columns} cols · ${r.stats.metrics} metrics · ${r.stats.relationships} rels (${r.warnings.length} warnings)`);
    } else if (f.endsWith('.dashboard.json')) {
      const r = convertMetabaseDashboardToSigma(read(f), { metadata });
      if (!wbDoc(r.workbook).pages.length) throw new Error('no pages');
      console.log(`✓ ${f.padEnd(36)} dashboard → ${r.stats.pages} pages · ${r.stats.kpis} kpis · ${r.stats.charts} charts · ${r.stats.pivots} pivots · ${r.stats.tables} tables · ${r.stats.texts} texts · ${r.stats.controls} controls · ${r.stats.filters} filters (${r.warnings.length} warnings)`);
    }
  } catch (e: any) { fail++; console.log(`✗ ${f} — ${e.message}`); }
}

console.log(fail ? `\n${fail} FAILED` : '\nall checks green ✓');
process.exit(fail ? 1 : 0);
