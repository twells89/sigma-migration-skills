#!/usr/bin/env node
// remap-wb-to-dm-ids.mjs — wire a Metabase-converted workbook spec to a freshly-posted DM.
//
// The report converter emits each element's `source.elementId` as the query's
// SUBJECT DISPLAY NAME (a placeholder), because the real Sigma element IDs don't
// exist until the DM is POSTed. After you POST the DM, run this to rewrite every
// element's `source.elementId` (and `dataModelId`) to the real IDs, matched by
// element NAME from the DM readback. (This was a manual step in every live test.)
//
// Usage:
//   eval "$(scripts/get-token.sh)"
//   node scripts/remap-wb-to-dm-ids.mjs --wb wb-spec.json --dm-id <dataModelId> [--out wb.remapped.json]
import { readFileSync, writeFileSync } from 'node:fs';
import { api, parseArgs, elementsOf } from './lib/sigma-rest.mjs';
import { document, metadata, workbookElements, wrap } from './lib/code_rep.mjs';

const a = parseArgs(process.argv.slice(2));
if (!a.wb || !a['dm-id']) { console.error('need --wb <spec.json> --dm-id <dataModelId>'); process.exit(2); }
const dmId = a['dm-id'];
const rawWb = JSON.parse(readFileSync(a.wb, 'utf8'));
const wbDoc = document(rawWb);
const wbEls = workbookElements(rawWb);

const els = elementsOf((await api('GET', `/v2/dataModels/${dmId}/elements`)).json);
if (!els.length) { console.error(`No elements found on data model ${dmId} (token? wrong id?)`); process.exit(1); }
const byName = new Map(els.map((e) => [e.name.toLowerCase(), e.id]));

let remapped = 0; const unresolved = [];
// Column-set fallback: Sigma does NOT honor sql-element names (all read back as
// "Custom SQL"), so native-card placeholders never match by name. Fingerprint each
// DM element by its column display names and match the workbook element's bare
// [Col] refs against them (best unique superset wins).
// Normalize: DM sql columns keep RAW aliases (NET_REVENUE), workbook refs are
// prettified (Net Revenue) — compare alphanumerics only.
const norm = (s) => String(s || '').toLowerCase().replace(/[^a-z0-9]/g, '');
const colEntries = (await api('GET', `/v2/dataModels/${dmId}/columns?limit=500`)).json?.entries || [];
const colsByElement = new Map();
for (const c of colEntries) {
  if (!colsByElement.has(c.elementId)) colsByElement.set(c.elementId, new Set());
  colsByElement.get(c.elementId).add(norm(c.name));
}
const wantedCols = (e) => {
  const names = new Set();
  for (const c of e.columns || []) {
    const m = /^\[([^\]/]+)\]$/.exec(String(c.formula || ''));
    if (m) names.add(norm(m[1]));
  }
  return names;
};
const byColumns = (e) => {
  const want = wantedCols(e);
  if (!want.size) return undefined;
  const hits = [];
  for (const [elId, have] of colsByElement) {
    if ([...want].every((n) => have.has(n))) hits.push({ elId, extra: have.size - want.size });
  }
  if (!hits.length) return undefined;
  // Smallest superset wins (a native card's sql element carries EXACTLY its result
  // columns; wide base tables also match but with many extras). Tie → ambiguous.
  hits.sort((x, y) => x.extra - y.extra);
  if (hits.length > 1 && hits[0].extra === hits[1].extra) return undefined;
  return hits[0].elId;
};

// Ref repair: workbook formulas must be [<DM element name>/<ACTUAL column name>]
// (DM sql elements keep RAW aliases like NET_REVENUE; derived views suffix duplicate
// names like "Category (PRODUCT_DIM)"). Bare or prettified refs POST 200 but resolve
// to type "error" — rewrite every bracket token against the live DM columns.
const nameByElement = new Map(els.map((e) => [e.id, e.name]));
const colNamesByElement = new Map(); // elId -> Map(norm -> [actual names])
for (const c of colEntries) {
  if (!colNamesByElement.has(c.elementId)) colNamesByElement.set(c.elementId, new Map());
  const m = colNamesByElement.get(c.elementId);
  const n = norm(c.name);
  if (!m.has(n)) m.set(n, []);
  if (!m.get(n).includes(c.name)) m.get(n).push(c.name);
}
let repaired = 0; const unrepairable = [];
// Control references ([<controlId>] in boolean match columns like
// `[Region] = [region]`) must survive repair UNTOUCHED — rewriting `[region]`
// to `[Customer Dim/Region]` turns the filter into always-true (live-caught by
// the control lint: the control reads back dead).
const controlIds = new Set();
for (const e of wbEls) {
  if (e.kind === 'control' && e.controlId) controlIds.add(e.controlId);
}
const repairRefs = (e, elId) => {
  const elName = nameByElement.get(elId);
  const colMap = colNamesByElement.get(elId);
  if (!elName || !colMap) return;
  const resolveCol = (token) => {
    const n = norm(token);
    const exact = colMap.get(n);
    if (exact?.length === 1) return exact[0];
    // tolerate the derived-view disambiguation suffix: Category -> "Category (PRODUCT_DIM)"
    const cands = [];
    for (const [k, names] of colMap) {
      if (k !== n && k.startsWith(n)) cands.push(...names.filter((nm) => /\(.+\)\s*$/.test(nm)));
    }
    return cands.length === 1 ? cands[0] : undefined;
  };
  for (const c of e.columns || []) {
    if (typeof c.formula !== 'string') continue;
    c.formula = c.formula.replace(/\[([^\]]+)\]/g, (whole, inner) => {
      if (controlIds.has(inner)) return whole;       // control ref — never a column
      const slash = inner.indexOf('/');
      const colTok = slash >= 0 ? inner.slice(slash + 1) : inner;
      const real = resolveCol(colTok);
      if (!real) { unrepairable.push(`${e.name || e.id}: ${whole}`); return whole; }
      repaired++;
      return `[${elName}/${real}]`;
    });
  }
};

// Intra-workbook sources (charts re-rooted through a hidden base TABLE so a
// range control's `filters` target has a table to point at — see the converter's
// pendingRanges) reference another element's id, not a DM placeholder: skip them.
const inWorkbookIds = new Set();
for (const e of wbEls) if (e.id) inWorkbookIds.add(e.id);

for (const e of wbEls) {
  const s = e.source; if (!s || !('elementId' in s)) continue;
  if (inWorkbookIds.has(s.elementId)) continue;          // base-table source — already real
  s.dataModelId = dmId;
  const want = String(s.elementId || '').toLowerCase();
  const real = byName.get(want) || byColumns(e) || (els.length === 1 ? els[0].id : undefined);
  if (real) { s.elementId = real; remapped++; repairRefs(e, real); } else unresolved.push(s.elementId);
}

// ── wire workbook controls to the DM controls they duplicate ─────────────────
// The DM converter emits a control per {{tag}} (the tag lives in DM SQL); the
// dashboard converter emits a control per dashboard parameter with the SAME
// controlId (slug). Without wiring, the workbook control is decorative — pass
// --dm-spec <the dm spec JSON you POSTed> to set control.parameters so the
// workbook control DRIVES the DM control.
let wired = 0;
if (a['dm-spec']) {
  const dmSpec = JSON.parse(readFileSync(a['dm-spec'], 'utf8'));
  const dmControlIds = new Set();
  for (const p of dmSpec.pages || []) for (const e of p.elements || []) {
    if (e.kind === 'control' && e.controlId) dmControlIds.add(e.controlId);
  }
  const wireControl = (c) => {
    if (c?.kind !== 'control' || !dmControlIds.has(c.controlId)) return;
    c.parameters = [{ kind: 'data-model', dataModelId: dmId, controlId: c.controlId }];
    wired++;
  };
  for (const e of wbEls) wireControl(e);
}

const out = a.out || a.wb.replace(/\.json$/, '.remapped.json');
const wb = rawWb.document ? rawWb : wrap(wbDoc, metadata(rawWb));
writeFileSync(out, JSON.stringify(wb, null, 2));
console.log(JSON.stringify({ dataModelId: dmId, dmElements: els.length, remapped, repaired, unrepairable, controlsWired: wired, unresolved, out }, null, 2));
if (unresolved.length) { console.error(`WARN: ${unresolved.length} elementId(s) unresolved — DM has no element named: ${unresolved.join(', ')}`); process.exit(1); }
