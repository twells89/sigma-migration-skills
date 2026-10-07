// Smoke test on the bundled fixtures: node --import tsx/esm test.ts
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { convertCognosToSigma, convertCognosIR } from './cognos.js';
import { convertCognosReportToSigma } from './cognos-report.js';
import { convertCognosPrintToSigma } from './cognos-print.js';
import {
  isFrameworkManagerXml, listFrameworkManagerSubjectAreas, normalizeCognosFrameworkManager,
} from './cognos-fm.js';
import { sigmaDisplayName } from './sigma-ids.js';
// @ts-expect-error Vendored runtime adapter is plain ESM.
import * as CodeRep from '../scripts/lib/code_rep.mjs';

const FIX = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures');
let fail = 0;

// ── sigmaDisplayName must match Sigma's OWN derivation (incl. letter↔digit splits;
// verified against live DM readbacks 2026-06-10 — beads-sigma-c31q) ──────────────
const NAME_CASES: Array<[string, string]> = [
  ['CY_Q1_REVENUE', 'Cy Q 1 Revenue'],   // the 16-dep-not-found case: Q1 splits to "Q 1"
  ['PY_Q4', 'Py Q 4'],
  ['FY2024', 'Fy 2024'],                  // letters→digits boundary, multi-digit group
  ['REVENUE_FY2024', 'Revenue Fy 2024'],
  ['X2024FY', 'X 2024 Fy'],               // digits→letters boundary
  ['Sheet1_1', 'Sheet 1 1'],
  ['GROSS_PROFIT', 'Gross Profit'],
  ['Province_or_State', 'Province or State'],  // small words stay lowercase (not first)
  ['Month_number', 'Month Number'],
  ['_row_id', 'Row Id'],
];
for (const [input, expected] of NAME_CASES) {
  const got = sigmaDisplayName(input);
  if (got === expected) console.log(`✓ sigmaDisplayName(${JSON.stringify(input).padEnd(20)}) → ${JSON.stringify(got)}`);
  else { fail++; console.log(`✗ sigmaDisplayName(${JSON.stringify(input)}) → ${JSON.stringify(got)} (expected ${JSON.stringify(expected)})`); }
}

// ── go-sales-performance regression: macro→Switch wired by controlId, segmented
// control with values+default, KPI singletons, element filters ───────────────────
{
  const r = convertCognosReportToSigma(readFileSync(join(FIX, 'go-sales-performance.report.xml'), 'utf8'), { dataModelId: 'dm' });
  const doc = CodeRep.document(r.workbook);
  const els = CodeRep.workbookElements(r.workbook) as any[];
  const controls = els.filter((e: any) => e.kind === 'control');
  const ctl = controls.find((c: any) => c.controlId === 'pColumn') as any;
  const checks: Array<[string, boolean]> = [
    ['workbook uses document wrapper', !!r.workbook.document && !('pages' in (r.workbook as any))],
    ['pages are metadata-only', doc.pages.every((p: any) => !('elements' in p))],
    ['elements are flat', Array.isArray(doc.elements) && doc.elements.length === els.length],
    ['authoritative layout places every element',
      els.every((e: any) => (doc.layout.match(new RegExp(`elementId="${e.id}"`, 'g')) || []).length === 1)],
    ['layout uses live Element tags',
      /<Element\b/.test(doc.layout) && !/<(?:LayoutElement|GridContainer)\b/.test(doc.layout)],
    ['pColumn control is segmented', ctl?.controlType === 'segmented'],
    ['pColumn has explicit values', JSON.stringify(ctl?.source?.values) === JSON.stringify(['Revenue', 'Gross Profit'])],
    ['pColumn defaults to Revenue', ctl?.value === 'Revenue'],
    ['pQuarter control registered with Q1-Q4 + default Q4',
      controls.some((c: any) => c.controlId === 'pQuarter' && c.value === 'Q4' && c.source?.values?.length === 4)],
    ['Switch wired by controlId [pColumn]',
      els.some((e) => e.columns?.some((c: any) => /Switch\(\[pColumn\], "Gross Profit", \[Sheet 1\/Gross Profit\], \[Sheet 1\/Revenue\]\)/.test(c.formula)))],
    ['6 KPI singletons converted', els.filter((e) => e.kind === 'kpi-chart').length === 6],
    ['KPI value uses columnId', els.filter((e) => e.kind === 'kpi-chart').every((e) => e.value?.columnId)],
    ['KPI macro → Switch over digit-split refs',
      els.some((e) => e.kind === 'kpi-chart' && e.columns?.some((c: any) => c.formula.includes('[Sheet 1 1/Cy Q 1 Revenue]')))],
    ['detail filters became element filters', r.stats.filters >= 4],
    ['?pQuarter? filter is a boolean match column',
      els.some((e) => e.columns?.some((c: any) => c.formula === '[Quarter Label] = [pQuarter]'))],
    ['lists grouped', els.some((e) => e.kind === 'table' && e.groupings?.length)],
    ['year bound categorically on the line chart',
      els.some((e) => e.kind === 'line-chart' && e.columns?.some((c: any) => /^Text\(/.test(c.formula) && c.name === 'Year'))],
    ['no unresolved Switch placeholders', !els.some((e) => e.columns?.some((c: any) => /map prompt tokens/.test(c.formula)))],
  ];
  for (const [label, ok] of checks) {
    if (ok) console.log(`✓ go-sales: ${label}`);
    else { fail++; console.log(`✗ go-sales: ${label}`); }
  }
}

// ── workbook-code release surface: flat elements + required layout and the
// newly released grounded mappings (waterfall/legend/drill/navigation/
// page-break/progress/panels/styles/repeaters); gated box stays loud. ──────────
{
  const xml = `<report viewPagesAsTabs="topLeft">
    <reportName>Release features</reportName>
    <layouts><layout><reportPages>
      <page name="Overview"><pageHeader><style><CSS value="background-color:#445566"/></style></pageHeader><pageBody><contents>
        <block name="Revenue panel"><style><CSS value="background-color:#112233;border-radius:8px"/></style>
          <vizControl name="Revenue bridge" type="com.ibm.vis.waterfall">
            <vcDataSet refDataStore="ds"/>
            <vcSlotData idSlot="categories"><vcSlotDsColumn refDsColumn="Category"/></vcSlotData>
            <vcSlotData idSlot="values"><vcSlotDsColumn refDsColumn="Revenue" rollupMethod="total"/></vcSlotData>
            <vizPropertyValues><vizPropertyBooleanValue name="legendVisible">true</vizPropertyBooleanValue>
              <vizPropertyEnumValue name="legendPosition">right</vizPropertyEnumValue></vizPropertyValues>
          </vizControl>
        </block>
        <pageBreak/>
        <repeater name="Category cards" refQuery="q"><dataItemValue refDataItem="Category"/></repeater>
        <drillBehavior enabled="true"/>
      </contents></pageBody></page>
      <page name="Detail"><pageBody><contents>
        <vizControl name="Target progress" type="com.ibm.vis.progressbar">
          <vcDataSet refDataStore="ds"/>
          <vcSlotData idSlot="values"><vcSlotDsColumn refDsColumn="Revenue" rollupMethod="total"/></vcSlotData>
        </vizControl>
        <vizControl name="Distribution" type="com.ibm.vis.boxplot">
          <vcDataSet refDataStore="ds"/>
          <vcSlotData idSlot="categories"><vcSlotDsColumn refDsColumn="Category"/></vcSlotData>
          <vcSlotData idSlot="values"><vcSlotDsColumn refDsColumn="Revenue" rollupMethod="total"/></vcSlotData>
        </vizControl>
      </contents></pageBody></page>
    </reportPages></layout></layouts>
    <queries><query name="q"><selection>
      <dataItem name="Category" aggregate="none"><expression>[C].[M].[Sales].[Category]</expression></dataItem>
      <dataItem name="Revenue" aggregate="total"><expression>[C].[M].[Sales].[Revenue]</expression></dataItem>
    </selection></query></queries>
    <reportDataStores><reportDataStore name="ds"><dsV5ListQuery refQuery="q"/></reportDataStore></reportDataStores>
  </report>`;
  const r = convertCognosReportToSigma(xml, { dataModelId: 'dm' });
  const doc = CodeRep.document(r.workbook);
  const els = CodeRep.workbookElements(r.workbook) as any[];
  const checks: Array<[string, boolean]> = [
    ['two Cognos pages stay two metadata-only pages', doc.pages.length === 2 && doc.pages.every((p: any) => !p.elements)],
    ['auto navigation emitted per tabbed report page', els.filter((e: any) => e.kind === 'navigation' && e.mode === 'auto').length === 2],
    ['waterfall uses released kind + yAxis', els.some((e: any) => e.kind === 'waterfall-chart' && e.yAxis?.columnIds?.length === 1)],
    ['legend settings grounded from viz properties', els.some((e: any) => e.kind === 'waterfall-chart' && e.legend?.visibility === 'shown' && e.legend?.position === 'right')],
    ['drillBehavior uses released drill control', els.some((e: any) => e.kind === 'control' && e.controlType === 'drill')],
    ['page break emitted', els.some((e: any) => e.kind === 'page-break')],
    ['progress emitted with aggregate source', els.some((e: any) => e.kind === 'progress' && typeof e.value === 'string')
      && els.some((e: any) => e.kind === 'table' && e.name === 'Target progress (progress source)' && e.columns?.some((c: any) => /^Sum\(/.test(c.formula)))],
    ['named block becomes styled panel', els.some((e: any) => e.kind === 'container' && e.name === 'Revenue Panel' && e.style?.backgroundColor === '#112233')],
    ['page header becomes document panel', doc.panels?.some((p: any) => p.type === 'header'
      && p.pages?.[0] === doc.pages[0].id && p.config?.backgroundColor === '#445566')],
    ['repeater becomes repeated-container with child binding', els.some((e: any) => e.kind === 'repeated-container')
      && els.some((e: any) => e.kind === 'table' && e.name === 'Category cards source')
      && els.some((e: any) => e.kind === 'text' && /Category cards source repeated container/.test(e.body || ''))],
    ['box chart remains loud and data-preserving', els.some((e: any) => e.kind === 'table' && /was box plot/.test(e.name || '') && e.groupings?.length)
      && r.warnings.some((w) => w.includes('⛔ WORKBOOK FEATURE GAP [box-chart (workspace gated)]'))],
    ['layout is authoritative for every flat element',
      els.every((e: any) => (doc.layout.match(new RegExp(`elementId="${e.id}"`, 'g')) || []).length === 1)],
    ['panel layout uses live Element/Container tags',
      /<Element\b/.test(doc.layout) && /<Container\b/.test(doc.layout)
        && !/<(?:LayoutElement|GridContainer)\b/.test(doc.layout)],
  ];
  for (const [label, ok] of checks) {
    if (ok) console.log(`✓ release: ${label}`);
    else { fail++; console.log(`✗ release: ${label}`); }
  }
}

// ── Framework Manager ingest ─────────────────────────────────────────────────
// ── Cognos list and crosstab fidelity ────────────────────────────────────────
{
  const xml = `<report><reportName>Agent activity</reportName><layouts><layout><reportPages>
    <page name="Summary"><pageBody><contents><list name="Agents" refQuery="agents">
      <listGroups><listGroup refDataItem="Site"/></listGroups>
      <listColumns>
        <listColumn><listColumnTitle><textItem><dataSource><staticValue>Agent</staticValue></dataSource></textItem></listColumnTitle><listColumnBody><textItem><dataSource><dataItemValue refDataItem="Agent"/></dataSource></textItem></listColumnBody></listColumn>
        <listColumn><listColumnBody><textItem><dataSource><dataItemValue refDataItem="Calls"/></dataSource></textItem><textItem><dataSource><dataItemValue refDataItem="Target"/></dataSource></textItem></listColumnBody></listColumn>
      </listColumns><sortList><sortItem refDataItem="Calls" sortOrder="descending"/></sortList>
    </list></contents></pageBody></page>
    <page name="Details"><pageBody><contents><list name="Call log" refQuery="log"><listColumns>
      <listColumn><listColumnBody><textItem><dataSource><dataItemValue refDataItem="Call ID"/></dataSource></textItem></listColumnBody></listColumn>
      <listColumn><listColumnBody><textItem><dataSource><dataItemValue refDataItem="Started"/></dataSource></textItem></listColumnBody></listColumn>
    </listColumns><sortList><sortItem refDataItem="Started" sortOrder="descending"/></sortList></list>
    </contents></pageBody></page></reportPages></layout></layouts><queries>
    <query name="agents"><selection><dataItem name="Site" aggregate="none"><expression>[C].[M].[Agents].[Site]</expression></dataItem>
      <dataItem name="Agent" aggregate="none"><expression>[C].[M].[Agents].[Agent]</expression></dataItem>
      <dataItem name="Calls" aggregate="total"><expression>[C].[M].[Agents].[Calls]</expression></dataItem>
      <dataItem name="Target" aggregate="none"><expression>[C].[M].[Agents].[Target]</expression></dataItem>
    </selection></query>
    <query name="log"><selection><dataItem name="Call ID" aggregate="none"><expression>[C].[M].[Calls].[Call_ID]</expression></dataItem>
      <dataItem name="Started" aggregate="none"><expression>[C].[M].[Calls].[Started]</expression></dataItem>
    </selection></query></queries></report>`;
  const r = convertCognosReportToSigma(xml, { dataModelId: 'dm' });
  const els = CodeRep.workbookElements(r.workbook) as any[];
  const summary = els.find((e: any) => e.kind === 'table' && e.name.includes('agents'));
  const log = els.find((e: any) => e.kind === 'table' && e.name.includes('log'));
  const checks: Array<[string, boolean]> = [
    ['only visible listColumnBody values become displayed columns', summary?.order?.length === 2],
    ['non-visible group key is retained but hidden', summary?.columns?.some((c: any) => c.name === 'Site' && c.hidden && !summary.order.includes(c.id))],
    ['grouping contains both visible and hidden dimensions', summary?.groupings?.[0]?.groupBy?.length === 2],
    ['grouped list sorts by the source measure descending', summary?.groupings?.[0]?.sort?.[0]?.columnId === summary.columns.find((c: any) => c.name === 'Calls')?.id && summary.groupings[0].sort[0].direction === 'descending'],
    ['detail list sorts without inventing an aggregate grouping', !log?.groupings && log?.sort?.[0]?.direction === 'descending'],
    ['compound Cognos cell gets a named fidelity warning', r.warnings.some((w) => w.includes('visible column combines Calls, Target'))],
  ];
  for (const [label, ok] of checks) {
    if (ok) console.log(`✓ lists: ${label}`);
    else { fail++; console.log(`✗ lists: ${label}`); }
  }
}

{
  const xml = `<report><queries><query name="detail"><selection>
    <dataItem name="Region" aggregate="none"><expression>[C].[M].[Calls].[Region]</expression></dataItem>
    <dataItem name="Call ID" aggregate="none"><expression>[C].[M].[Calls].[Call_ID]</expression></dataItem>
    <dataItem name="Talk Time" aggregate="total"><expression>[C].[M].[Calls].[Talk_Time]</expression></dataItem>
  </selection></query></queries><layouts><layout><reportPages><page name="Log"><pageBody><contents>
    <list name="Call log" refQuery="detail"><listGroups><listGroup refDataItem="Region"/></listGroups><listColumns>
      <listColumn><listColumnBody><dataItemValue refDataItem="Call ID"/></listColumnBody></listColumn>
      <listColumn><listColumnBody><dataItemValue refDataItem="Talk Time"/></listColumnBody></listColumn>
    </listColumns></list>
  </contents></pageBody></page></reportPages></layout></layouts></report>`;
  const r = convertCognosReportToSigma(xml);
  const table = (CodeRep.workbookElements(r.workbook) as any[]).find((e) => e.kind === 'table');
  if (!table?.groupings && r.warnings.some((w) => /row-level identifier/.test(w))) console.log('✓ lists: detail-row call ID prevents accidental roll-up');
  else { fail++; console.log('✗ lists: call log was wrongly rolled up despite its row identifier'); }
}

{
  const r = convertCognosReportToSigma(readFileSync(join(FIX, 'banking-risk-crosstab.report.xml'), 'utf8'), { dataModelId: 'dm' });
  const pivots = (CodeRep.workbookElements(r.workbook) as any[]).filter((e: any) => e.kind === 'pivot-table');
  const checks: Array<[string, boolean]> = [
    ['banking crosstabs remain two pivots', pivots.length === 2],
    ['each Net Loss is averaged, never silently summed', pivots.every((p: any) => p.columns.some((c: any) => c.name === 'Net Loss' && /^Avg\(/.test(c.formula)))],
    ['explicit row and column grand totals are retained', pivots.every((p: any) => p.totals?.showGrandTotals === 'shown')],
    ['row and column source sort lists become pivot shelf sorts', pivots.every((p: any) => p.rowsBy?.[0]?.sort?.direction === 'ascending' && p.columnsBy?.[0]?.sort?.direction === 'ascending')],
  ];
  for (const [label, ok] of checks) {
    if (ok) console.log(`✓ pivots: ${label}`);
    else { fail++; console.log(`✗ pivots: ${label}`); }
  }
}

{
  // A missing first edge must not shift the surviving member's sort to the
  // wrong source node. Workbook stays data-preserving and warns about the gap.
  const xml = `<report><queries><query name="q"><selection>
    <dataItem name="Region"><expression>[C].[M].[Sales].[Region]</expression></dataItem>
    <dataItem name="Year"><expression>[C].[M].[Sales].[Year]</expression></dataItem>
    <dataItem name="Amount" aggregate="total"><expression>[C].[M].[Sales].[Amount]</expression></dataItem>
  </selection></query></queries><layouts><layout><reportPages><page name="Pivot"><pageBody><contents>
    <crosstab refQuery="q"><crosstabRows><crosstabNodeMember refDataItem="Absent"><sortList><sortItem refDataItem="Amount" sortOrder="ascending"/></sortList></crosstabNodeMember>
    <crosstabNodeMember refDataItem="Region"><sortList><sortItem refDataItem="Amount" sortOrder="descending"/></sortList></crosstabNodeMember></crosstabRows>
    <crosstabColumns><crosstabNodeMember refDataItem="Year"><sortList><sortItem refDataItem="Year" sortOrder="ascending"/></sortList></crosstabNodeMember></crosstabColumns>
    <crosstabCorner><dataItemLabel refDataItem="Amount"/></crosstabCorner></crosstab>
  </contents></pageBody></page></reportPages></layout></layouts></report>`;
  const result = convertCognosReportToSigma(xml);
  const pivot = (CodeRep.workbookElements(result.workbook) as any[]).find((e) => e.kind === 'pivot-table');
  const amount = pivot?.columns?.find((c: any) => c.name === 'Amount');
  const checks: Array<[string, boolean]> = [
    ['missing crosstab edge is flagged', result.warnings.some((w) => /member "Absent" not in query/.test(w))],
    ['remaining row sort stays on its source edge', pivot?.rowsBy?.length === 1 && pivot.rowsBy[0].sort?.direction === 'descending' && pivot.rowsBy[0].sort?.by === amount?.id],
    ['unaffected column sort is preserved', pivot?.columnsBy?.[0]?.sort?.direction === 'ascending'],
  ];
  for (const [label, ok] of checks) {
    if (ok) console.log(`✓ pivots: ${label}`);
    else { fail++; console.log(`✗ pivots: ${label}`); }
  }
}

{
  const xml = `<report><queries><query name="q"><selection>
    <dataItem name="Region" aggregate="none"><expression>[C].[M].[Sales].[Region]</expression></dataItem>
    <dataItem name="Target" aggregate="none"><expression>[C].[M].[Sales].[Target]</expression></dataItem>
    <dataItem name="Total" aggregate="total"><expression>[C].[M].[Sales].[Total]</expression></dataItem>
  </selection></query></queries><layouts><layout><reportPages><page name="A"><pageBody><contents>
    <list refQuery="q"><listGroups><listGroup refDataItem="Region"/></listGroups><listColumns>
      <listColumn><listColumnBody><dataItemValue refDataItem="Total"/><dataItemValue refDataItem="Target"/></listColumnBody></listColumn>
    </listColumns></list>
  </contents></pageBody></page></reportPages></layout></layouts></report>`;
  const result = convertCognosReportToSigma(xml);
  const table = (CodeRep.workbookElements(result.workbook) as any[]).find((e) => e.kind === 'table');
  if (table?.order.length === 1 && table?.groupings?.[0]?.groupBy.length === 1 && table.groupings[0].calculations.length === 1) console.log('✓ lists: measure-only visible table groups by the hidden source key');
  else { fail++; console.log('✗ lists: measure-only visible table lost grouping'); }
}

// Nested records keep their own query scope, even with same-named fields.
{
  const child = `<list name="Details" refQuery="detail"><listGroups><listGroup refDataItem="Category"/></listGroups>
    <listColumns><listColumn><listColumnBody><dataItemValue refDataItem="Label"/>
      <conditionalStyleRef refConditionalStyle="Detail style"/>
    </listColumnBody></listColumn></listColumns></list>`;
  const xml = `<report><queries>
    <query name="header"><source><model/></source><selection>
      <dataItem name="Label"><expression>[C].[M].[Headers].[Label]</expression></dataItem>
      <dataItem name="Amount" aggregate="total"><expression>[C].[M].[Headers].[Amount]</expression></dataItem>
      <dataItem name="Internal"><expression>[C].[M].[Headers].[Internal]</expression></dataItem>
    </selection></query>
    <query name="detail"><source><model/></source><selection>
      <dataItem name="Label"><expression>[C].[M].[Details].[Label]</expression></dataItem>
      <dataItem name="Category"><expression>[C].[M].[Details].[Category]</expression></dataItem>
    </selection></query>
  </queries><layouts><layout><reportPages><page name="Records"><pageBody><contents>
    <list name="Headers" refQuery="header"><listColumns>
      <listColumn><listColumnBody><block><contents>${child}<textItem><dataSource><dataItemValue refDataItem="Amount"/></dataSource></textItem></contents></block></listColumnBody></listColumn>
    </listColumns></list>
  </contents></pageBody></page></reportPages></layout></layouts></report>`;
  const r = convertCognosReportToSigma(xml, { captureLineage: true });
  const header = r.lineage?.find((s) => s.source['@_name'] === 'Headers');
  const detail = r.lineage?.find((s) => s.source['@_name'] === 'Details');
  const elements = CodeRep.workbookElements(r.workbook) as any[];
  const parentTable = elements.find((e) => e.id === header?.elementId);
  const childTable = elements.find((e) => e.id === detail?.elementId);
  const checks: Array<[string, boolean]> = [
    ['parent cell excludes child fields even when the names exist in both queries',
      parentTable?.columns?.length === 1 && parentTable.columns[0].name === 'Amount'],
    ['child list binds its own query and preserves its hidden grouping key',
      childTable?.source?.elementId === 'Details' && childTable.columns?.some((c: any) => c.name === 'Label' && /Details\//.test(c.formula)) &&
      childTable.columns?.some((c: any) => c.name === 'Category' && c.hidden)],
    ['child grouping and conditional styles are not attributed to parent',
      !parentTable?.groupings && !r.warnings.some((w) => /list "header" uses conditional|list "Headers": group key/.test(w))],
    ['nested record layout is explicitly flagged, not represented as faithful flat tables',
      r.warnings.some((w) => /nested data container/.test(w))],
  ];
  for (const [label, ok] of checks) {
    if (ok) console.log(`✓ nested lists: ${label}`);
    else { fail++; console.log(`✗ nested lists: ${label}`); }
  }
  const onlyChild = xml.replace('<textItem><dataSource><dataItemValue refDataItem="Amount"/></dataSource></textItem>', '');
  const onlyChildResult = convertCognosReportToSigma(onlyChild);
  const onlyChildTables = (CodeRep.workbookElements(onlyChildResult.workbook) as any[]).filter((e) => e.kind === 'table');
  if (onlyChildTables.length === 1 && onlyChildTables[0].source.elementId === 'Details' &&
      onlyChildResult.warnings.some((w) => /no visible dataItemValue/.test(w))) {
    console.log('✓ nested lists: a container-only parent does not invent columns or duplicate the child');
  } else { fail++; console.log('✗ nested lists: container-only parent was mistaken for a data table'); }
  const sameQuery = convertCognosReportToSigma(xml.replace('refQuery="detail"', 'refQuery="header"'), { captureLineage: true });
  const sameParentId = sameQuery.lineage?.find((s) => s.source['@_name'] === 'Headers')?.elementId;
  const sameParent = (CodeRep.workbookElements(sameQuery.workbook) as any[]).find((e) => e.id === sameParentId);
  if (sameParent?.columns?.length === 1 && sameParent.columns[0].name === 'Amount') {
    console.log('✓ nested lists: same-query child still owns its fields');
  } else { fail++; console.log('✗ nested lists: same-query child fields leaked into parent'); }
  try { convertCognosPrintToSigma(xml); fail++; console.log('✗ print: nested record was flattened'); }
  catch (err: any) {
    if (/nested data container|master-detail/.test(err.message)) console.log('✓ print: nested record cannot pass as unrelated flat tables');
    else { fail++; console.log('✗ print: unexpected nested-record error: ' + err.message); }
  }
}

// ── Sigma Report/PDF path — same query translations, pixel layout ───────────
{
  const xml = `<report><queries><query name="q"><selection>
    <dataItem name="Region" aggregate="none"><expression>[Business].[Orders].[Region]</expression></dataItem>
  </selection></query></queries><layouts><layout><reportPages><page name="Output"><pageBody><contents>
    <list refQuery="q"><listColumns><listColumn><listColumnBody><dataItemValue refDataItem="Region"/></listColumnBody></listColumn></listColumns></list>
  </contents></pageBody></page></reportPages></layout></layouts></report>`;
  const result = convertCognosReportToSigma(xml);
  const table = (CodeRep.workbookElements(result.workbook) as any[]).find((e) => e.kind === 'table');
  if (table.source.elementId === 'Orders' && table.columns[0].formula.toLowerCase() === '[orders/region]') {
    console.log('✓ model refs: three-part namespace/subject/column binds without residual dot refs');
  } else { fail++; console.log('✗ model refs: three-part reference was misbound'); }
}

{
  const xml = `<report><reportName>Quarterly statement</reportName><layouts><layout><reportPages>
    <page name="Summary"><pageHeader><style><CSS value="background-color:#112233"/></style><contents><textItem><dataSource><staticValue>Quarterly statement</staticValue></dataSource></textItem></contents></pageHeader>
      <pageBody><contents><list name="Revenue" refQuery="q"><listColumns>
        <listColumn><listColumnBody><dataItemValue refDataItem="Region"/></listColumnBody></listColumn>
        <listColumn><listColumnBody><dataItemValue refDataItem="Revenue"/></listColumnBody></listColumn>
      </listColumns></list></contents></pageBody>
      <pageFooter><contents><textItem><dataSource><staticValue>Confidential</staticValue></dataSource></textItem></contents></pageFooter>
    </page><page name="By segment"><pageBody><contents><list refQuery="q"><listColumns>
      <listColumn><listColumnBody><dataItemValue refDataItem="Segment"/></listColumnBody></listColumn>
      <listColumn><listColumnBody><dataItemValue refDataItem="Revenue"/></listColumnBody></listColumn>
    </listColumns></list></contents></pageBody></page></reportPages></layout></layouts><queries><query name="q"><selection>
      <dataItem name="Region" aggregate="none"><expression>[C].[M].[Orders].[Region]</expression></dataItem>
      <dataItem name="Segment" aggregate="none"><expression>[C].[M].[Orders].[Segment]</expression></dataItem>
      <dataItem name="Revenue" aggregate="total"><expression>[C].[M].[Orders].[Revenue]</expression></dataItem>
    </selection></query></queries></report>`;
  const r = convertCognosPrintToSigma(xml, { dataModelId: 'dm', pageWidth: 816, pageHeight: 1056, margin: 48 });
  const c = r.contents;
  const checks: Array<[string, boolean]> = [
    ['Sigma Report contents uses kind report, not workbook', c.kind === 'report' && c.schemaVersion === 1],
    ['two report pages retain their Cognos names', c.pages.map((p) => p.name).join(' / ') === 'Summary / By segment'],
    ['both report lists share the workbook query translation', c.elements.filter((e: any) => e.kind === 'table' && e.columns?.length === 2).length === 2],
    ['page data tables flow into paginated PDF', (c.layout.match(/flow="paginated"/g) || []).length === 2],
    ['print layout uses pixel coordinates, no grid rows', /x="48" y="/.test(c.layout) && !/gridRow=/.test(c.layout)],
    ['Cognos header AND footer survive as report panels', !!c.panels?.some((p: any) => p.type === 'header') && !!c.panels?.some((p: any) => p.type === 'footer')],
    ['every report element has exactly one placement', c.elements.every((e: any) => c.layout.split(`elementId="${e.id}"`).length === 2)],
    ['print config reflects requested page dimensions', c.config.pageWidth === 816 && c.config.margin === 48],
  ];
  for (const [label, ok] of checks) {
    if (ok) console.log(`✓ print: ${label}`);
    else { fail++; console.log(`✗ print: ${label}`); }
  }
  const compound = xml.replace('<dataItemValue refDataItem="Region"/>', '<dataItemValue refDataItem="Region"/><dataItemValue refDataItem="Segment"/>');
  const masterDetail = xml.replace('<list name="Revenue" refQuery="q">', `<list name="Revenue" refQuery="q"><masterDetailLinks><masterDetailLink>
    <masterContext><dataItemContext refDataItem="Region"/></masterContext><detailContext><dataItemContext refDataItem="Region"/></detailContext>
  </masterDetailLink></masterDetailLinks>`);
  for (const [label, input, expected] of [
    ['compound cell', compound, /compound|visible column combines/],
    ['master-detail correlation', masterDetail, /master-detail/],
  ] as const) {
    try { convertCognosPrintToSigma(input); fail++; console.log(`✗ print: accepted unconverted ${label}`); }
    catch (err: any) {
      if (expected.test(err.message)) console.log(`✓ print: refuses unconverted ${label}`);
      else { fail++; console.log(`✗ print: unexpected ${label} error: ${err.message}`); }
    }
  }
  for (const source of [
    '<joinOperation><joinOperands><joinOperand><queryRef refQuery="left"/></joinOperand><joinOperand><queryRef refQuery="missing"/></joinOperand></joinOperands></joinOperation>',
    '<queryOperation name="union"><queryRefs><queryRef refQuery="left"/><queryRef refQuery="right"/></queryRefs></queryOperation>',
    '<queryRef refQuery="left"/>',
  ]) {
    const dependent = xml.replace('<queries>', `<queries>
      <query name="left"><source><model/></source><selection><dataItem name="Region"><expression>[C].[M].[Orders].[Region]</expression></dataItem></selection>
        <detailFilters><detailFilter><filterExpression>[Region] = 'East'</filterExpression></detailFilter></detailFilters></query>
      <query name="right"><source><model/></source><selection><dataItem name="Region"><expression>[C].[M].[Other].[Region]</expression></dataItem></selection></query>`)
      .replace('<query name="q">', `<query name="q"><source>${source}</source>`);
    const result = convertCognosReportToSigma(dependent);
    const tables = (CodeRep.workbookElements(result.workbook) as any[]).filter((e) => e.kind === 'table');
    if (result.warnings.some((w) => /query dependency.*left/.test(w)) && tables.every((e) => e.source.elementId === '<element>')) {
      console.log('✓ queries: dependent source is flagged instead of guessed from a projected model column');
    } else { fail++; console.log('✗ queries: query dependency silently mapped to a model subject'); }
    try { convertCognosPrintToSigma(dependent); fail++; console.log('✗ print: accepted unresolved query source'); }
    catch (err: any) {
      if (/query dependency/.test(err.message)) console.log('✓ print: refuses unresolved query dependency');
      else { fail++; console.log('✗ print: unexpected query dependency error: ' + err.message); }
    }
  }
  const unused = xml.replace('<queries>', '<queries><query name="unused"><source><queryRef refQuery="absent"/></source></query>');
  try { convertCognosPrintToSigma(unused); console.log('✓ print: unused query operation does not block unrelated printable data'); }
  catch (err: any) { fail++; console.log('✗ print: unused query operation blocked print: ' + err.message); }
  try { convertCognosPrintToSigma('<report><reportName>Empty</reportName></report>'); fail++; console.log('✗ print: refuses an empty report'); }
  catch { console.log('✓ print: refuses an empty report'); }
  try { convertCognosPrintToSigma(readFileSync(join(FIX, 'banking-risk-crosstab.report.xml'), 'utf8')); fail++; console.log('✗ print: rejects unsupported pivot Report code'); }
  catch (err: any) {
    if (/crosstab\(s\).*pivot-table/.test(err.message)) console.log('✓ print: rejects unsupported pivot Report code');
    else { fail++; console.log('✗ print: unexpected error for crosstab: ' + err.message); }
  }
  const missingQuery = `<report><layouts><layout><reportPages><page name="Missing"><pageBody><contents><list refQuery="unknown"/></contents></pageBody></page></reportPages></layout></layouts></report>`;
  try { convertCognosPrintToSigma(missingQuery); fail++; console.log('✗ print: refuses an unresolved Cognos list'); }
  catch (err: any) {
    if (/could not be emitted|no printable data/.test(err.message)) console.log('✓ print: refuses an unresolved Cognos list');
    else { fail++; console.log('✗ print: unexpected unresolved-list error: ' + err.message); }
  }
  const unresolvedBody = xml.replace('<dataItemValue refDataItem="Region"/>', '<staticValue>No query field</staticValue>')
    .replace('<dataItemValue refDataItem="Revenue"/>', '<staticValue>No query field</staticValue>');
  try { convertCognosPrintToSigma(unresolvedBody); fail++; console.log('✗ print: refuses a list with no resolvable visible columns'); }
  catch (err: any) {
    if (/data visual could not be emitted|no printable data/.test(err.message)) console.log('✓ print: refuses a list with no resolvable visible columns');
    else { fail++; console.log('✗ print: unexpected unresolved-column error: ' + err.message); }
  }
  const prompted = xml.replace('<expression>[C].[M].[Orders].[Region]</expression>',
    '<expression>prompt(\'period\')</expression>');
  try { convertCognosPrintToSigma(prompted); fail++; console.log('✗ print: refuses prompt controls that change values'); }
  catch (err: any) {
    if (/prompt|parameter|control/.test(err.message)) console.log('✓ print: refuses prompt controls that change values');
    else { fail++; console.log('✗ print: unexpected prompted-report error: ' + err.message); }
  }
  const structured = xml.replace('</selection></query>', '</selection><detailFilters><detailFilter><filterDefinition><filterInValues refDataItem="Region"><filterValues><filterValue>West</filterValue></filterValues></filterInValues></filterDefinition></detailFilter></detailFilters></query>');
  const workbook = convertCognosReportToSigma(structured);
  const workbookTable = (CodeRep.workbookElements(workbook.workbook) as any[]).find((e) => e.kind === 'table');
  if (!workbookTable?.filters?.length && workbook.warnings.some((w) => /structured or empty detail filter/.test(w))) console.log('✓ print: structured Cognos filter is warned, not mistaken for a converted workbook filter');
  else { fail++; console.log('✗ print: structured Cognos filter was falsely converted or not warned'); }
  try { convertCognosPrintToSigma(structured); fail++; console.log('✗ print: refuses structured detail filters'); }
  catch (err: any) {
    if (/filter was not converted|structured or empty filter/.test(err.message)) console.log('✓ print: refuses structured detail filters before publishing extra rows');
    else { fail++; console.log('✗ print: unexpected structured-filter error: ' + err.message); }
  }
  const structuredSummary = xml.replace('</selection></query>', '</selection><summaryFilters><summaryFilter><filterDefinition><filterInValues refDataItem="Region"><filterValues><filterValue>West</filterValue></filterValues></filterInValues></filterDefinition></summaryFilter></summaryFilters></query>');
  try { convertCognosPrintToSigma(structuredSummary); fail++; console.log('✗ print: refuses structured summary filters'); }
  catch (err: any) {
    if (/filter was not converted|structured or empty filter/.test(err.message)) console.log('✓ print: refuses structured summary filters');
    else { fail++; console.log('✗ print: unexpected structured-summary-filter error: ' + err.message); }
  }
  // Disabled predicates must not restrict rows, register controls, or block print.
  const prohibited = xml.replace('</selection></query>', `</selection>
    <detailFilters>
      <detailFilter><filterExpression>[Region] = 'East'</filterExpression></detailFilter>
      <detailFilter use="prohibited"><filterExpression>[Region] = 'West'</filterExpression></detailFilter>
      <detailFilter use="prohibited"><filterExpression>[Region] = ?disabledRegion?</filterExpression></detailFilter>
      <detailFilter use="prohibited"><filterDefinition><filterInValues refDataItem="Region"/></filterDefinition></detailFilter>
      <detailFilter use="prohibited"/>
    </detailFilters>
    <summaryFilters>
      <summaryFilter use="prohibited"><filterExpression>[Revenue] &gt; 100</filterExpression></summaryFilter>
      <summaryFilter use="prohibited"><filterDefinition><filterInValues refDataItem="Region"/></filterDefinition></summaryFilter>
      <summaryFilter use="prohibited"/>
    </summaryFilters></query>`);
  const disabledResult = convertCognosReportToSigma(prohibited);
  const disabledElements = CodeRep.workbookElements(disabledResult.workbook) as any[];
  const disabledTables = disabledElements.filter((e) => e.kind === 'table');
  const disabledChecks: Array<[string, boolean]> = [
    ['prohibited detail filters leave only the active predicate on every table',
      disabledTables.length === 2 && disabledTables.every((e) => e.filters?.length === 1 &&
        JSON.stringify(e.filters[0].values) === '["East"]')],
    ['prohibited prompt filters do not create controls', !disabledElements.some((e) => e.kind === 'control')],
    ['prohibited structured and summary filters produce no repair warning',
      !disabledResult.warnings.some((w) => /filter/i.test(w))],
  ];
  for (const [label, ok] of disabledChecks) {
    if (ok) console.log(`✓ filters: ${label}`);
    else { fail++; console.log(`✗ filters: ${label}`); }
  }
  try {
    const printed = convertCognosPrintToSigma(prohibited);
    if (printed.contents.elements.filter((e: any) => e.kind === 'table').every((e: any) =>
      e.filters?.length === 1 && JSON.stringify(e.filters[0].values) === '["East"]')) {
      console.log('✓ print: prohibited filters neither block print nor become predicates');
    } else { fail++; console.log('✗ print: prohibited filter changed printed predicates'); }
  } catch (err: any) { fail++; console.log('✗ print: prohibited filter incorrectly blocks print: ' + err.message); }
  for (const use of ['', ' use="required"', ' use="optional"']) {
    const active = structured.replace('<detailFilter>', `<detailFilter${use}>`);
    try { convertCognosPrintToSigma(active); fail++; console.log(`✗ print: active structured filter was allowed (${use})`); }
    catch (err: any) {
      if (/filter was not converted|structured or empty filter/.test(err.message)) console.log(`✓ print: active structured filter still blocks (${use || 'default'})`);
      else { fail++; console.log('✗ print: unexpected active-filter error: ' + err.message); }
    }
  }
  const scatter = `<report><queries><query name="scatter"><selection>
      <dataItem name="Group"><expression>[C].[M].[Sales].[Group]</expression></dataItem>
      <dataItem name="X"><expression>[C].[M].[Sales].[X]</expression></dataItem>
      <dataItem name="Y"><expression>[C].[M].[Sales].[Y]</expression></dataItem>
    </selection></query></queries><reportDataStores><reportDataStore name="ds"><dsV5ListQuery refQuery="scatter"/></reportDataStore></reportDataStores>
    <layouts><layout><reportPages><page name="Plot"><pageBody><contents><vizControl name="Sample scatter" type="com.ibm.vis.scatter">
      <vcDataSet refDataStore="ds"/><vcSlotData idSlot="series"><vcSlotDsColumn refDsColumn="Group"/></vcSlotData>
      <vcSlotData idSlot="x"><vcSlotDsColumn refDsColumn="X"/></vcSlotData>
      <vcSlotData idSlot="y"><vcSlotDsColumn refDsColumn="Y"/></vcSlotData>
    </vizControl></contents></pageBody></page></reportPages></layout></layouts></report>`;
  const scatterWorkbook = convertCognosReportToSigma(scatter, { captureLineage: true });
  if (scatterWorkbook.lineage?.some((entry) => entry.hiddenSource && entry.kind === 'table') &&
      (CodeRep.workbookElements(scatterWorkbook.workbook) as any[]).some((e) => e.kind === 'scatter-chart')) {
    console.log('✓ print: hidden scatter source is identifiable before workbook wrapping');
  } else { fail++; console.log('✗ print: scatter fixture did not create the hidden source'); }
  try { convertCognosPrintToSigma(scatter); fail++; console.log('✗ print: refuses hidden scatter source'); }
  catch (err: any) {
    if (/hidden visual source table/.test(err.message)) console.log('✓ print: refuses hidden scatter helper instead of printing it as a table');
    else { fail++; console.log('✗ print: unexpected scatter-source error: ' + err.message); }
  }
}

// ── Framework Manager ingest ─────────────────────────────────────────────────
{
  const fmXml = readFileSync(join(FIX, 'acme-warehouse.fm.xml'), 'utf8');
  const areas = listFrameworkManagerSubjectAreas(fmXml);
  const sales = convertCognosIR(
    normalizeCognosFrameworkManager(fmXml, { subjectArea: 'Sales Analysis' }), { connectionId: 'c' });
  const ent = convertCognosIR(
    normalizeCognosFrameworkManager(fmXml, { subjectArea: 'Customer Entitlement' }), { connectionId: 'c' });
  const el = (r: any, n: string) => r.model.pages[0].elements.find((e: any) => e.name === n);
  const col = (e: any, n: string) => (e?.columns || []).find((c: any) => c.name === n);

  const fact = el(sales, 'Sales Fact');
  const orderDate = el(sales, 'Order Date');
  const shipDate = el(sales, 'Ship Date');
  const entEl = el(ent, 'Entitlement');

  const checks: Array<[string, boolean]> = [
    ['root-element sniff accepts an FM model', isFrameworkManagerXml(fmXml)],
    ['root-element sniff rejects a report spec',
      !isFrameworkManagerXml(readFileSync(join(FIX, 'go-sales-performance.report.xml'), 'utf8'))],
    ['subject areas enumerated largest-first',
      areas.length === 2 && areas[0].name === 'Sales Analysis' && areas[0].objects === 5],
    ['an unknown subject area is a hard error', (() => {
      try { normalizeCognosFrameworkManager(fmXml, { subjectArea: 'Nope' }); return false; } catch { return true; }
    })()],
    // Rule 2: one physical DATE_DIM exposed twice must stay TWO elements, or the two
    // date roles collapse into one and the fact joins to the wrong grain.
    ['role-playing aliases stay separate elements',
      !!orderDate && !!shipDate && orderDate.id !== shipDate.id],
    ['both date roles point at the same physical table',
      orderDate?.source.path.join('.') === 'ACME_ANALYTICS.DW.DATE_DIM'
      && shipDate?.source.path.join('.') === 'ACME_ANALYTICS.DW.DATE_DIM'],
    ['business labels survive the resolve', !!col(orderDate, 'Order Year') && !!col(shipDate, 'Ship Year')],
    ['warehouse path is catalog.schema.table from the data source',
      fact?.source.path.join('.') === 'ACME_ANALYTICS.DW.SALES_FACT' && fact?.source.kind === 'warehouse-table'],
    ['facts with an aggregate become metrics',
      (fact?.metrics || []).some((m: any) => m.name === 'Net Amount' && m.formula === 'Sum([Net Amount])')],
    ['relationships land on the many side with the fact as source',
      (fact?.relationships || []).length === 4],
    // stopNodes hands back raw XML — an undecoded `&lt;` compiles to type "error".
    ['XML entities are decoded in expressions',
      col(fact, 'Order Size Band')?.formula.includes('<') === true
      && !col(fact, 'Order Size Band')?.formula.includes('&lt;')],
    ['searched CASE becomes nested If',
      /^If\(.*,\s*If\(/.test(col(fact, 'Order Size Band')?.formula || '')],
    ['running-total maps to the native CumulativeSum',
      col(fact, 'Running Net Amount')?.formula === 'CumulativeSum([Net Amount])'],
    // The whole point of the *Over fix: a scoped aggregate must still be postable.
    ['scoped total() degrades to a plain aggregate, not *Over',
      (fact?.metrics || []).some((m: any) => m.name === 'Region Net Amount' && m.formula === 'Sum([Net Amount])')],
    ['dropped partition is flagged, not silent',
      sales.warnings.some((w: string) => /partition is DROPPED/.test(w))],
    ['custom SQL becomes a sql source', entEl?.source.kind === 'sql'],
    ['sql source columns use the Custom SQL prefix',
      (entEl?.columns || []).every((c: any) => c.formula.startsWith('[Custom SQL/'))],
    ['Cognos [datasource].TABLE is fully qualified in the statement',
      entEl?.source.statement.includes('ACME_ANALYTICS.DW.V_CUSTOMER_ENTITLEMENT')],
    ['composite join emits both key pairs',
      (entEl?.relationships || [])[0]?.keys.length === 2],
    ['runtime macro is detected as security, never injected',
      (ent.security || []).some((s: any) => s.type === 'framework-manager-macro')
      && ent.warnings.some((w: string) => /runtime macro/.test(w))],
    ['DMR dimensions are flagged, not converted',
      sales.warnings.some((w: string) => /DMR dimension/.test(w))],
    ['embedded FM filters are flagged, not applied',
      sales.warnings.some((w: string) => /embedded Framework Manager filter/.test(w))],
  ];
  for (const [label, ok] of checks) {
    if (ok) console.log(`✓ framework-manager: ${label}`);
    else { fail++; console.log(`✗ framework-manager: ${label}`); }
  }
}

// ── Regression: the *Over window family must NEVER reach a spec ──────────────
// `SumOver` / `CountOver` / `RankOver` / … hard-reject a DM-spec POST with 400 and
// resolve to `Unknown function` in a workbook calc column. Any converter path that
// emits one ships a model the customer cannot post.
{
  const RE_OVER = /\b(?:Sum|Avg|Count|Min|Max|RowNumber|Rank)Over\s*\(/;
  const offenders: string[] = [];
  const scan = (where: string, model: any) => {
    for (const e of model.pages[0].elements) {
      for (const c of e.columns || []) if (RE_OVER.test(c.formula || '')) offenders.push(`${where} · ${e.name} · column ${c.name || c.id}: ${c.formula}`);
      for (const m of e.metrics || []) if (RE_OVER.test(m.formula || '')) offenders.push(`${where} · ${e.name} · metric ${m.name}: ${m.formula}`);
    }
  };
  for (const f of readdirSync(FIX).filter((x) => x.endsWith('.module.json'))) {
    scan(f, convertCognosToSigma(readFileSync(join(FIX, f), 'utf8'), { connectionId: 'c' }).model);
  }
  const fmXml = readFileSync(join(FIX, 'acme-warehouse.fm.xml'), 'utf8');
  for (const a of listFrameworkManagerSubjectAreas(fmXml)) {
    scan(a.name, convertCognosIR(normalizeCognosFrameworkManager(fmXml, { subjectArea: a.path }), { connectionId: 'c' }).model);
  }
  if (!offenders.length) console.log('✓ no *Over window function reaches any emitted spec');
  else { fail++; offenders.forEach((o) => console.log(`✗ *Over in emitted spec — ${o}`)); }
}

for (const f of readdirSync(FIX)) {
  try {
    if (f.endsWith('.fm.xml')) {
      const xml = readFileSync(join(FIX, f), 'utf8');
      const areas = listFrameworkManagerSubjectAreas(xml);
      if (!areas.length) throw new Error('no subject areas');
      const r = convertCognosIR(normalizeCognosFrameworkManager(xml, { subjectArea: areas[0].path }), { connectionId: 'c' });
      if (!r.model.pages[0].elements.length) throw new Error('no elements');
      console.log(`✓ ${f.padEnd(34)} framework-manager → ${areas.length} subject areas · "${areas[0].name}" → ${r.stats.elements} elems · ${r.stats.columns} cols · ${r.stats.metrics} metrics · ${r.stats.relationships} rels`);
    } else if (f.endsWith('.module.json')) {
      const r = convertCognosToSigma(readFileSync(join(FIX, f), 'utf8'), { connectionId: 'c', database: 'DB', schema: 'S' });
      if (!r.model.pages[0].elements.length) throw new Error('no elements');
      console.log(`✓ ${f.padEnd(34)} module → ${r.stats.elements} elems · ${r.stats.columns} cols · ${r.stats.metrics} metrics · ${r.stats.relationships} rels`);
    } else if (f.endsWith('.report.xml')) {
      const r = convertCognosReportToSigma(readFileSync(join(FIX, f), 'utf8'), { dataModelId: 'dm' });
      const doc = CodeRep.document(r.workbook);
      if (!Array.isArray(doc.elements) || doc.pages.some((p: any) => 'elements' in p) || !doc.layout) {
        throw new Error('legacy workbook representation');
      }
      if (/<(?:LayoutElement|GridContainer)\b/.test(doc.layout)) {
        throw new Error('legacy workbook layout tags');
      }
      console.log(`✓ ${f.padEnd(34)} report → ${r.stats.tables} tables · ${r.stats.pivots} pivots · ${r.stats.kpis} kpis · ${r.stats.charts} charts · ${r.stats.maps} maps · ${r.stats.columns} cols · ${r.stats.filters} filters · ${r.stats.controls} controls`);
    }
  } catch (e: any) { fail++; console.log(`✗ ${f} — ${e.message}`); }
}
console.log(fail ? `\n${fail} FAILED` : '\nall fixtures converted ✓');
process.exit(fail ? 1 : 0);
