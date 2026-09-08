#!/usr/bin/env node
/**
 * score-coverage.mjs — converter-coverage scorer for the metabase-assessment skill.
 *
 * For every Metabase card JSON (*.card.json) and dashboard JSON
 * (*.dashboard.json), classify features into auto / hint / manual / unhandled
 * by detecting the EXACT gap signals the metabase-to-sigma converter
 * (converter/metabase.ts, translateMbqlExpr) translates cleanly vs. flags.
 * This does NOT re-run the converter — it detects the same patterns so the
 * estate's auto-migration % matches what the tool will actually do.
 *
 * Zero external dependencies (Node built-ins only). MBQL arrives already
 * parsed (nested JSON arrays like ["sum", ["field", 72, null]]), so the
 * scorer simply recurses the dataset_query trees and matches op names against
 * the converter's translated-vs-flagged tables — no regex DSL parsing at all.
 *
 *   node score-coverage.mjs --in <dir-of-specs> --out <dir>
 *
 * Reads --in for *.card.json + *.dashboard.json (recurses one level into
 * specs/). If a sandboxes.json (EE GTAP export) sits next to the specs, its
 * policies are surfaced as needs-review items. Writes <out>/coverage.json.
 * Read-only.
 */
import { readFileSync, readdirSync, statSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { join, basename, dirname } from 'node:path';
// pMBQL ("lib/" MBQL) → legacy — modern instances (Cloud v1.61+) return
// dataset_query as {"lib/type":"mbql/query","stages":[…]} (100% of a 7k-card
// production estate). Normalized at intake; a list may mix both formats.
import { normalizeCard } from './pmbql-normalize.mjs';

// ---- args ----
const args = process.argv.slice(2);
let inDir = null, outDir = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--in') inDir = args[++i];
  else if (args[i] === '--out') outDir = args[++i];
}
if (!inDir || !outDir) {
  console.error('usage: score-coverage.mjs --in <specs-dir> --out <dir>');
  process.exit(2);
}
if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true });

// ---- collect spec files (the dir itself, and a specs/ subdir if present) ----
function collect(dir) {
  const out = [];
  const tryDir = (d) => {
    if (!existsSync(d)) return;
    for (const f of readdirSync(d)) {
      const p = join(d, f);
      let st;
      try { st = statSync(p); } catch { continue; }
      if (st.isFile() && (f.endsWith('.card.json') || f.endsWith('.dashboard.json'))) out.push(p);
    }
  };
  tryDir(dir);
  tryDir(join(dir, 'specs'));
  return [...new Set(out)];
}

// ============================================================================
// GAP SIGNAL DEFINITIONS — each maps to a converter behavior.
// See refs/scoring-rubric.md (this skill) + refs/expression-dsl.md (converter).
// ============================================================================

// Aggregations translateMbqlExpr maps cleanly (Sum/Avg/CountIf/SumIf/share…).
const AUTO_AGGS = new Set(['count', 'sum', 'avg', 'min', 'max', 'median', 'distinct',
  'stddev', 'var', 'percentile', 'count-where', 'sum-where', 'share']);

// Cumulative / window aggregations the converter flags loudly — the window
// scope lives on the consuming Sigma element, so they're never faked.
const UNHANDLED_AGGS = new Set(['cum-sum', 'cum-count', 'offset']);

// Expression / filter ops in expression-dsl.md's translated table.
const AUTO_OPS = new Set([
  '+', '-', '*', '/', 'case', 'coalesce', 'concat', 'substring',
  'trim', 'ltrim', 'rtrim', 'upper', 'lower', 'length', 'replace',
  'regex-match-first', 'split-part',
  'round', 'floor', 'ceil', 'abs', 'sqrt', 'exp', 'power', 'log',
  'datetime-add', 'datetime-subtract', 'datetime-diff',
  'get-year', 'get-quarter', 'get-month', 'get-week', 'get-day',
  'get-day-of-week', 'get-hour', 'get-minute', 'get-second',
  'now', 'relative-datetime',
  'text', 'integer', 'float', 'date',          // casts → Text/Int/Number/DateTrunc
  '=', '!=', 'in', 'not-in', '<', '<=', '>', '>=', 'between',
  'is-null', 'not-null', 'is-empty', 'not-empty',
  'starts-with', 'ends-with', 'contains', 'does-not-contain',
  'time-interval', 'inside',
]);

// Structural tokens — handled elsewhere or free; never counted as features.
const IGNORE_OPS = new Set(['field', 'expression', 'aggregation', 'value',
  'aggregation-options', 'and', 'or', 'not', 'asc', 'desc', 'datetime', 'interval']);

// Card displays the converter builds natively (chart/table/pivot/KPI/map).
// Production histogram (7k-card estate): table 2999 · bar 1604 · line 1176 ·
// combo 449 · scalar 259 · pie 135 · row 130 · area 67 · pivot 39 · scatter 3
// all convert natively — see refs/scoring-rubric.md.
const AUTO_DISPLAYS = new Set(['table', 'bar', 'row', 'line', 'area', 'combo',
  'scatter', 'pie', 'scalar', 'smartscalar', 'trend', 'pivot', 'map',
  'funnel', 'gauge', 'waterfall', 'sankey']);
// Progress has no faithful native mapping; the converter preserves its data in
// a flagged table. Funnel/gauge/waterfall/sankey are native Sigma kinds.
const UNHANDLED_DISPLAYS = new Set(['progress']);

function makeAdd(state) {
  return (signal, bucket, reason, remediation) => {
    let g = state.gaps.find((x) => x.signal === signal);
    if (!g) { g = { signal, bucket, count: 0, reason, remediation }; state.gaps.push(g); }
    g.count++;
    if (bucket === 'auto') state.nAuto++; else if (bucket === 'hint') state.nHint++;
    else if (bucket === 'manual') state.nManual++; else state.nUnhandled++;
  };
}

// ---- MBQL tree walker — classifies every op the way translateMbqlExpr would.
function walkExpr(node, where, add) {
  if (!Array.isArray(node)) return;
  const op = typeof node[0] === 'string' ? node[0].toLowerCase() : null;
  if (op === 'value') return; // literal wrapper — unwraps transparently
  if (op === 'field') {
    const opts = node[2];
    if (opts && typeof opts === 'object' && opts.binning) {
      add('binning breakout (numeric histogram)', 'manual', `"${where}" bins a numeric field (${JSON.stringify(opts.binning)})`,
        'The converter passes binning through with a warning. Recreate the buckets with BinFixed()/BinCount() in the consuming Sigma workbook element.');
    }
    return;
  }
  if (op === 'segment') {
    add('segment ref (["segment", id])', 'manual', `"${where}" references a saved segment — its definition lives in another object`,
      'Inline the segment\'s own MBQL filter (GET /api/segment/{id}) into the Sigma element filter; the converter flags the ref instead of guessing.');
    return;
  }
  if (op === 'metric') {
    add('legacy metric ref (["metric", id])', 'manual', `"${where}" references a saved legacy metric`,
      'Inline the metric\'s own MBQL aggregation (GET /api/legacy-metric/{id}) as a Sigma metric; the converter flags the ref instead of guessing.');
    return;
  }
  if (op) {
    if (UNHANDLED_AGGS.has(op)) {
      add(`${op} (cumulative/offset window calc)`, 'unhandled', `"${where}" uses MBQL ${op}`,
        'Running totals / lag need a window scope Sigma defines on the consuming element. Rebuild with CumulativeSum / Lag in the date-grouped workbook element (proven pattern); the converter emits a flagged placeholder.');
    } else if (AUTO_AGGS.has(op)) {
      add('translated aggregation', 'auto', `"${where}" uses ${op} — maps via translateMbqlExpr`, '—');
    } else if (AUTO_OPS.has(op)) {
      add('translated expression/filter op', 'auto', `"${where}" uses ${op} — maps via translateMbqlExpr`, '—');
    } else if (op === 'aggregation-options') {
      // wrapper supplies the metric's name — score the inner aggregation only
      walkExpr(node[1], where, add);
      return;
    } else if (!IGNORE_OPS.has(op)) {
      add(`unmapped MBQL op ${op}`, 'unhandled', `"${where}" uses ${op} — no confirmed Sigma mapping`,
        'Review and translate by hand; the converter emits a /* unmapped */ placeholder + a loud warning — never silent, never guessed.');
    }
  }
  for (const child of node.slice(op ? 1 : 0)) walkExpr(child, where, add);
}

// ---- MBQL query (structural pass + expression trees) ----
function scoreMbqlQuery(q, where, add, deps) {
  if (!q || typeof q !== 'object') return;
  if (q['source-query']) {
    // pMBQL stages>1 / legacy nested source-query — converter flags + skips
    // (rare but real: 14 of 7,023 on the reference production estate)
    add('multi-stage query (nested source-query)', 'manual', `"${where}" aggregates over an inner query stage`,
      'Rebuild as a chain of Sigma elements (inner stage → element, outer stage → child element) or a custom-SQL element; the converter flags it, never mistranslates.');
  }
  const st = q['source-table'];
  if (typeof st === 'string' && st.startsWith('card__')) {
    const dep = Number(st.slice(6));
    if (!Number.isNaN(dep)) deps.push(dep);
    add('nested-card source (card__N)', 'hint', `"${where}" is built on saved card ${st.slice(6)}`,
      'Converts to an element sourced from that card\'s element — sequence the source card (usually a model) first; the converter wires it when both are in the input set.');
  } else if (st != null) {
    add('table source', 'auto', 'maps to the model/DM element for the warehouse table', '—');
  }
  if (q['source-query']) scoreMbqlQuery(q['source-query'], `${where} (inner query)`, add, deps);

  for (const j of q.joins || []) {
    add('explicit MBQL join', 'hint', `"${where}" joins ${typeof j['source-table'] === 'string' ? j['source-table'] : 'table ' + j['source-table']} (${j.strategy || 'left-join'})`,
      'Converts to a Sigma DM join source — review for fan-out (row multiplication) before trusting aggregates, exactly as you would in Metabase.');
    if (typeof j['source-table'] === 'string' && j['source-table'].startsWith('card__')) {
      const dep = Number(j['source-table'].slice(6));
      if (!Number.isNaN(dep)) deps.push(dep);
    }
    walkExpr(j.condition, `${where} join condition`, add);
  }
  for (const [name, expr] of Object.entries(q.expressions || {})) {
    walkExpr(expr, `${where} expression "${name}"`, add);
  }
  for (const agg of q.aggregation || []) walkExpr(agg, `${where} aggregation`, add);
  for (const b of q.breakout || []) {
    const opts = Array.isArray(b) && b[0] === 'field' ? b[2] : null;
    if (opts && typeof opts === 'object' && opts.binning) {
      walkExpr(b, `${where} breakout`, add); // emits the binning manual signal
    } else {
      add('breakout (group-by)', 'auto', 'maps to a Sigma grouping / chart axis', '—');
    }
  }
  walkExpr(q.filter, `${where} filter`, add);
  // order-by / limit / fields are free — the converter carries them silently.
}

function classifyDisplay(display, where, add) {
  const d = String(display || 'table').toLowerCase();
  if (AUTO_DISPLAYS.has(d)) {
    add(`${d} display → Sigma element`, 'auto', `${d} maps to a native Sigma chart/table/pivot/KPI/map element`, '—');
  } else if (d === 'object') {
    add('object display (record detail view)', 'manual', `"${where}" is a single-record detail view`,
      'The converter emits the data as a flagged table; recreate the detail experience with element filters / drill in Sigma.');
  } else if (UNHANDLED_DISPLAYS.has(d)) {
    add(`${d} display (no faithful Sigma mapping)`, 'unhandled', `"${where}" renders as a ${d} — no faithful native Sigma mapping is verified`,
      'Data is preserved as a flagged table; choose an explicitly approved replacement in the workbook.');
  } else {
    add(`${d} display (no converter mapping)`, 'unhandled', `"${where}" uses display "${d}"`,
      'Review and pick the closest Sigma element by hand; the converter emits a flagged table.');
  }
}

function countClickBehaviors(vs) {
  // click_behavior can sit at the top level or under column_settings.* — count keys anywhere.
  let n = 0;
  const walk = (o) => {
    if (!o || typeof o !== 'object') return;
    if (Array.isArray(o)) { for (const c of o) walk(c); return; }
    for (const [k, v] of Object.entries(o)) {
      if (k === 'click_behavior' && v) n++;
      walk(v);
    }
  };
  walk(vs);
  return n;
}

// ---- card scorer (mirrors metabase.ts) ----
function scoreCard(text, name) {
  let card;
  try { card = JSON.parse(text); } catch { return null; }
  try { card = normalizeCard(card); } catch { /* score the raw card — never crash the walk */ }
  const type = (card.type === 'model' || card.dataset === true) ? 'model'
    : card.type === 'metric' ? 'metric' : 'card';
  const state = { gaps: [], nAuto: 0, nHint: 0, nManual: 0, nUnhandled: 0 };
  const add = makeAdd(state);
  const deps = [];
  const dispName = card.name || name;

  const dq = card.dataset_query || {};
  if (dq.type === 'native') {
    add('native SQL card → DM sql element', 'auto', 'the SQL text becomes a Sigma Custom SQL element verbatim', '—');
    const tags = (dq.native && dq.native['template-tags']) || {};
    for (const [tname, tag] of Object.entries(tags)) {
      const ttype = String(tag?.type || '').toLowerCase();
      if (ttype === 'dimension') {
        add('field-filter template tag (type: dimension)', 'hint', `tag {{${tname}}} expands to a whole WHERE clause at runtime`,
          'Converts to a Sigma control on the target column + an element filter (not a plain =-parameter) — verify the widget type and default after conversion.');
      } else if (ttype === 'card') {
        add('nested-card template tag ({{#N}})', 'hint', `tag {{${tname}}} inlines another saved question as a sub-query`,
          'Sequence the referenced card first; the converter wires it when both are in the input set.');
      } else if (ttype === 'snippet') {
        add('snippet template tag', 'manual', `tag {{${tname}}} splices a shared SQL snippet`,
          'Inline the snippet text (GET /api/native-query-snippet) into the Sigma Custom SQL by hand; Sigma has no snippet library.');
      } else {
        add('plain template tag → control (text/number/date/boolean)', 'auto', `tag {{${tname}}} (${ttype || 'text'}) maps to a Sigma control — Sigma custom SQL uses the SAME {{control-id}} parameter syntax, so the statement converts near-verbatim`, '—');
      }
    }
    if (/\[\[/.test(dq.native?.query || '')) {
      add('optional [[…]] SQL block', 'hint', `"${dispName}" uses Metabase optional-clause syntax`,
        'Sigma has no optional-clause syntax: blocks whose tags are field filters or have defaults stay active; others are dropped (matching Metabase\'s empty-value behavior) with a loud warning. Review each.');
    }
  } else {
    scoreMbqlQuery(dq.query, dispName, add, deps);
  }

  classifyDisplay(card.display, dispName, add);

  // table.column_formatting — single rules convert to Sigma conditionalFormats;
  // gradient/range scales are flagged (spec shape not yet live-verified).
  for (const r of card.visualization_settings?.['table.column_formatting'] || []) {
    if (r?.type === 'single') {
      add('conditional formatting (single rule) → conditionalFormats', 'auto',
        `"${dispName}" has a threshold formatting rule — converts to a Sigma conditionalFormats entry`, '—');
    } else {
      add('conditional formatting (gradient/range scale)', 'manual',
        `"${dispName}" has a "${r?.type}" formatting scale`,
        'Recreate as a Sigma backgroundScale conditional format in the UI; the converter flags it.');
    }
  }

  const clicks = countClickBehaviors(card.visualization_settings);
  for (let i = 0; i < clicks; i++) {
    add('click_behavior (cross-filter / link)', 'manual', `"${dispName}" defines a click behavior`,
      'Re-implement as a Sigma action (cross-element filter / open-link); the converter flags it, never fakes it.');
  }

  return finalize({
    type, name: dispName, gaps: state.gaps,
    nAuto: state.nAuto, nHint: state.nHint, nManual: state.nManual, nUnhandled: state.nUnhandled,
    viewCount: typeof card.view_count === 'number' ? card.view_count : null,
    usesCards: [...new Set(deps)],
  });
}

// ---- dashboard scorer ----
function scoreDashboard(text, name) {
  let d;
  try { d = JSON.parse(text); } catch { return null; }
  const state = { gaps: [], nAuto: 0, nHint: 0, nManual: 0, nUnhandled: 0 };
  const add = makeAdd(state);
  const deps = [];
  const dispName = d.name || name;

  // v48+ uses dashcards[].size_x; pre-v48 uses ordered_cards[].sizeX — accept both.
  const dashcards = d.dashcards || d.ordered_cards || [];

  for (const p of d.parameters || []) {
    add('dashboard parameter → control', 'auto', `parameter "${p.name || p.slug}" maps to a Sigma control (+ per-card targets from parameter_mappings)`, '—');
  }
  for (const t of d.tabs || []) {
    add('dashboard tab → workbook page', 'auto', `tab "${t.name}" maps to a Sigma workbook page`, '—');
  }

  for (const dc of dashcards) {
    const vs = dc.visualization_settings || {};
    if ((dc.card_id == null || dc.card_id === undefined) && vs.virtual_card) {
      add('text/heading card → text element', 'auto', 'markdown passes through to a Sigma text element', '—');
    } else {
      if (dc.card_id != null) deps.push(dc.card_id);
      const cardDisplay = dc.card?.display || vs?.virtual_card?.display;
      classifyDisplay(cardDisplay, `${dispName} / card ${dc.card_id ?? '?'}`, add);
    }
    const clicks = countClickBehaviors(vs);
    for (let i = 0; i < clicks; i++) {
      add('click_behavior (cross-filter / link)', 'manual', `a dashcard on "${dispName}" defines a click behavior`,
        'Re-implement as a Sigma action (cross-element filter / open-link); the converter flags it, never fakes it.');
    }
  }

  return finalize({
    type: 'dashboard', name: dispName, gaps: state.gaps,
    nAuto: state.nAuto, nHint: state.nHint, nManual: state.nManual, nUnhandled: state.nUnhandled,
    viewCount: typeof d.view_count === 'number' ? d.view_count : null,
    usesCards: [...new Set(deps)],
  });
}

function finalize(r) {
  const nFeatures = r.nAuto + r.nHint + r.nManual + r.nUnhandled;
  const cost = 10 * r.nUnhandled + 3 * r.nManual + 1 * r.nHint;
  // value = 10·view_count when the instance exposes it (v50+), else 10·n_features.
  const usageBased = r.viewCount != null;
  const value = usageBased ? 10 * r.viewCount : 10 * nFeatures;
  const score = Math.round((value / (1 + cost)) * 100) / 100;
  const complexity = r.nUnhandled > 0 ? 'high' : r.nManual > 0 ? 'medium' : 'low';
  let tag;
  if (r.nUnhandled >= 1) tag = 'needs-review';
  else if (r.nManual + r.nUnhandled === 0) tag = 'migrate-first';
  else if (score >= 10) tag = 'easy-win';
  else tag = 'moderate';
  return {
    id: r.name, type: r.type, name: r.name,
    n_features: nFeatures, n_auto: r.nAuto, n_hint: r.nHint, n_manual: r.nManual, n_unhandled: r.nUnhandled,
    complexity, gaps: r.gaps,
    view_count: r.viewCount, uses_cards: r.usesCards || [],
    value, cost, score, tag,
  };
}

// ============================================================================
// main
// ============================================================================
const files = collect(inDir);
if (!files.length) {
  console.error(`no *.card.json / *.dashboard.json found under ${inDir}`);
  process.exit(1);
}

const artifacts = [];
for (const f of files) {
  const text = readFileSync(f, 'utf8');
  const name = basename(f).replace(/\.(card\.json|dashboard\.json)$/, '');
  const res = f.endsWith('.card.json') ? scoreCard(text, name) : scoreDashboard(text, name);
  if (res) { res.specFile = f; artifacts.push(res); }
}
artifacts.sort((a, b) => b.score - a.score);

// estate roll-up
const totals = artifacts.reduce((t, a) => {
  t.n_auto += a.n_auto; t.n_hint += a.n_hint; t.n_manual += a.n_manual; t.n_unhandled += a.n_unhandled;
  t.n_features += a.n_features;
  return t;
}, { n_auto: 0, n_hint: 0, n_manual: 0, n_unhandled: 0, n_features: 0 });

// % auto-migratable = features that convert with no manual/unhandled work.
// (auto + hint count as auto-migratable; hint is a review, not rework.)
const autoMigratable = totals.n_auto + totals.n_hint;
const pctAuto = totals.n_features ? Math.round((autoMigratable / totals.n_features) * 100) : 0;

// gap histogram = manual + unhandled signals aggregated by signal name
const histo = {};
for (const a of artifacts) {
  for (const g of a.gaps) {
    if (g.bucket === 'manual' || g.bucket === 'unhandled') {
      const k = g.signal;
      histo[k] = histo[k] || { signal: g.signal, bucket: g.bucket, count: 0, artifacts: [], reason: g.reason, remediation: g.remediation };
      histo[k].count += g.count;
      histo[k].artifacts.push(a.name);
    }
  }
}

// EE sandboxing (GTAP export saved by discovery) — estate-level needs-review item.
let nSandboxes = 0;
for (const cand of [join(inDir, 'sandboxes.json'), join(dirname(inDir), 'sandboxes.json'), outDir ? join(outDir, 'sandboxes.json') : null]) {
  if (cand && existsSync(cand)) {
    try {
      const sb = JSON.parse(readFileSync(cand, 'utf8'));
      if (Array.isArray(sb)) { nSandboxes = sb.length; break; }
    } catch { /* ignore */ }
  }
}
if (nSandboxes > 0) {
  histo['sandboxing policy (EE row-level security)'] = {
    signal: 'sandboxing policy (EE row-level security)', bucket: 'unhandled', count: nSandboxes,
    artifacts: ['(instance-level — sandboxes.json)'],
    reason: `${nSandboxes} GTAP sandboxing polic${nSandboxes === 1 ? 'y' : 'ies'} restrict data per group`,
    remediation: 'Port to Sigma user attributes + data-model filters with the metabase-to-sigma RLS engine (apply_sigma_rls.py) after the DM is posted — opt-in, reviewed per policy, never silent.',
  };
}
const gapHistogram = Object.values(histo).sort((a, b) => (b.bucket === 'unhandled' ? 1 : 0) - (a.bucket === 'unhandled' ? 1 : 0) || b.count - a.count);

const byComplexity = { low: 0, medium: 0, high: 0 };
const byTag = {};
for (const a of artifacts) { byComplexity[a.complexity]++; byTag[a.tag] = (byTag[a.tag] || 0) + 1; }

const rollup = {
  generated_at: new Date().toISOString().slice(0, 10),
  n_artifacts: artifacts.length,
  n_models: artifacts.filter((a) => a.type === 'model').length,
  n_cards: artifacts.filter((a) => a.type === 'card' || a.type === 'metric').length,
  n_dashboards: artifacts.filter((a) => a.type === 'dashboard').length,
  totals,
  pct_auto_migratable: pctAuto,
  gap_histogram: gapHistogram,
  by_complexity: byComplexity,
  by_tag: byTag,
  usage_available: artifacts.some((a) => a.view_count != null),
  n_sandboxes: nSandboxes,
};

const out = { rollup, artifacts };
writeFileSync(join(outDir, 'coverage.json'), JSON.stringify(out, null, 2));
console.log(`scored ${artifacts.length} artifacts (${rollup.n_models} models, ${rollup.n_cards} questions, ${rollup.n_dashboards} dashboards) — ${pctAuto}% auto-migratable -> ${join(outDir, 'coverage.json')}`);
