/**
 * pMBQL ("lib/" MBQL, Metabase Lib) → legacy MBQL normalizer.
 *
 * Modern Metabase instances (observed: Metabase Cloud v1.61.x; 100% of a
 * 7k-card production estate) return `dataset_query` in pMBQL form:
 *
 *   { "lib/type": "mbql/query", "database": N, "stages": [ ... ] }
 *
 * instead of the legacy `{ "type": "native"|"query", ... }` the converter and
 * scorer were built against. A single card-list response may contain EITHER
 * format depending on instance version — sniff the `lib/type` key, never the
 * version string.
 *
 * Shape differences handled here (all verified against production payloads):
 *   query    {lib/type:"mbql/query", stages:[…]}     → {type, database, native|query}
 *   stage    mbql.stage/native {native:"sql", template-tags} → {native:{query, template-tags}}
 *   stage    mbql.stage/mbql   {aggregation, breakout, filters, joins, …}
 *   clause   [op, {opts}, …args]                     → [op, …args] (opts map is ALWAYS
 *            the 2nd element in pMBQL; legacy puts it last, or 3rd for "field")
 *   field    ["field", {opts}, idOrName]             → ["field", idOrName, opts|null]
 *   filters  array (implicit AND)                    → single `filter` (["and", …])
 *   in/not-in                                        → multi-value "="/"!=" (the
 *            converter renders those as Or/And chains — Sigma has no IsIn)
 *   named aggregation (name/display-name in opts)    → ["aggregation-options", inner, {…}]
 *   expressions list (lib/expression-name in opts)   → {name: clause} map
 *   source-card N                                    → source-table "card__N"
 *   joins {stages:[{source-table}], conditions:[…]}  → {source-table, condition, …}
 *   multi-stage (rare but real: 14 of 7,023 cards)   → legacy source-query nesting
 *   template-tags dimension clauses                  → legacy field refs
 *
 * `normalizeCard` prefers the server-provided `legacy_query` JSON string when
 * present and parseable (the instance's own down-conversion — authoritative),
 * falling back to this normalizer. Zero dependencies; usable from Node ≥18.
 *
 * NOTE: this file exists in two locations (converter + assessment scripts) so
 * each skill stays self-contained. The converter test suite asserts the two
 * copies are byte-identical — edit one, copy to the other.
 */

const isOptsMap = (x) => x !== null && typeof x === 'object' && !Array.isArray(x);

/** A pMBQL clause is [op:string, optsMap, ...args] — opts ALWAYS second. */
const isPmbqlClause = (n) => Array.isArray(n) && typeof n[0] === 'string' && isOptsMap(n[1]);

function cleanOpts(opts) {
  const out = {};
  for (const [k, v] of Object.entries(opts || {})) {
    if (k.startsWith('lib/') || k === 'effective-type' || k === 'ident') continue;
    out[k] = v;
  }
  return out;
}

const STRING_MATCH_OPS = new Set(['starts-with', 'ends-with', 'contains', 'does-not-contain']);

/** Recursively normalize a pMBQL clause tree into legacy MBQL. */
export function normalizeClause(node) {
  if (!Array.isArray(node)) return node;
  if (!isPmbqlClause(node)) return node.map(normalizeClause); // e.g. case clause-pair lists
  const op = node[0];
  const opts = cleanOpts(node[1]);
  const args = node.slice(2);
  const hasOpts = Object.keys(opts).length > 0;

  switch (op) {
    case 'field':
      // ["field", {opts}, idOrName] → ["field", idOrName, opts|null]
      return ['field', args[0], hasOpts ? opts : null];
    case 'expression':
      return hasOpts ? ['expression', args[0], opts] : ['expression', args[0]];
    case 'aggregation':
      return ['aggregation', args[0]];
    case 'template-tag':
      return ['template-tag', args[0]];
    case 'value':
      return normalizeClause(args[0]); // literal wrapper — unwrap
    case 'absolute-datetime':
      return normalizeClause(args[0]); // legacy filters carry the bare ISO string
    case 'case':
    case 'if': {
      // ["case", {opts}, [[pred, expr], …], default?] → ["case", [[…]], {default}?]
      const pairs = (args[0] || []).map((p) =>
        Array.isArray(p) ? [normalizeClause(p[0]), normalizeClause(p[1])] : p);
      const out = ['case', pairs];
      if (args.length > 1 && args[1] !== undefined) out.push({ default: normalizeClause(args[1]) });
      return out;
    }
    case 'in':
      return ['=', ...args.map(normalizeClause)];
    case 'not-in':
      return ['!=', ...args.map(normalizeClause)];
    case 'time-interval':
    case 'relative-time-interval': {
      // ["time-interval", {opts}, field, n, unit] → ["time-interval", field, n, unit, opts?]
      const rest = args.map(normalizeClause);
      return hasOpts ? ['time-interval', ...rest, opts] : ['time-interval', ...rest];
    }
    case 'segment':
    case 'metric':
      return [op, args[0]];
    default: {
      const rest = args.map(normalizeClause);
      // string-match ops carry case-sensitive in opts — legacy puts it last
      if (STRING_MATCH_OPS.has(op) && hasOpts) return [op, ...rest, opts];
      return [op, ...rest];
    }
  }
}

/** Aggregation clause — pMBQL names live in opts → legacy aggregation-options wrapper. */
function normalizeAggregation(a) {
  if (!isPmbqlClause(a)) return normalizeClause(a);
  const o = a[1];
  const norm = normalizeClause(a);
  const nm = o['display-name'] || o.name;
  if (!nm) return norm;
  const wrap = {};
  if (o.name) wrap.name = o.name;
  if (o['display-name']) wrap['display-name'] = o['display-name'];
  return ['aggregation-options', norm, wrap];
}

function normalizeJoin(j) {
  const out = {};
  const st0 = (j.stages && j.stages[0]) || {};
  if (st0['source-card'] != null) out['source-table'] = `card__${st0['source-card']}`;
  else if (st0['source-table'] != null) out['source-table'] = st0['source-table'];
  else if (j['source-table'] != null) out['source-table'] = j['source-table'];
  if (j.alias != null) out.alias = j.alias;
  if (j.strategy != null) out.strategy = j.strategy;
  if (Array.isArray(j.conditions)) {
    const cs = j.conditions.map(normalizeClause);
    out.condition = cs.length === 1 ? cs[0] : ['and', ...cs];
  } else if (j.condition) {
    out.condition = normalizeClause(j.condition);
  }
  if (j.fields != null) out.fields = Array.isArray(j.fields) ? j.fields.map(normalizeClause) : j.fields;
  return out;
}

function normalizeTemplateTags(tags) {
  if (!tags) return tags;
  const out = {};
  for (const [k, t] of Object.entries(tags)) {
    out[k] = t && t.dimension ? { ...t, dimension: normalizeClause(t.dimension) } : t;
  }
  return out;
}

/** One pMBQL stage → legacy query object (native stages return {__native}). */
function normalizeStage(stage, prev) {
  if (stage['lib/type'] === 'mbql.stage/native') {
    const native = { query: stage.native ?? stage.query ?? '' };
    if (stage['template-tags']) native['template-tags'] = normalizeTemplateTags(stage['template-tags']);
    if (stage.collection) native.collection = stage.collection; // MongoDB
    return { __native: native };
  }
  const q = {};
  if (prev) {
    q['source-query'] = prev.__native
      ? { native: prev.__native.query, 'template-tags': prev.__native['template-tags'] || {} }
      : prev;
  } else if (stage['source-card'] != null) {
    q['source-table'] = `card__${stage['source-card']}`;
  } else if (stage['source-table'] != null) {
    q['source-table'] = stage['source-table'];
  }
  if (Array.isArray(stage.joins)) q.joins = stage.joins.map(normalizeJoin);
  if (Array.isArray(stage.expressions)) {
    q.expressions = {};
    for (const e of stage.expressions) {
      const nm = (isPmbqlClause(e) && e[1]['lib/expression-name']) || `expr_${Object.keys(q.expressions).length}`;
      q.expressions[nm] = normalizeClause(e);
    }
  }
  if (Array.isArray(stage.aggregation)) q.aggregation = stage.aggregation.map(normalizeAggregation);
  if (Array.isArray(stage.breakout)) q.breakout = stage.breakout.map(normalizeClause);
  if (Array.isArray(stage.filters) && stage.filters.length) {
    const fs = stage.filters.map(normalizeClause);
    q.filter = fs.length === 1 ? fs[0] : ['and', ...fs];
  } else if (stage.filter) {
    q.filter = normalizeClause(stage.filter);
  }
  if (Array.isArray(stage['order-by'])) {
    q['order-by'] = stage['order-by'].map((o) =>
      Array.isArray(o) && isOptsMap(o[1]) ? [o[0], normalizeClause(o[2])] : normalizeClause(o));
  }
  if (stage.limit != null) q.limit = stage.limit;
  if (Array.isArray(stage.fields)) q.fields = stage.fields.map(normalizeClause);
  return q;
}

export function isPmbqlQuery(dq) {
  return !!dq && typeof dq === 'object' && dq['lib/type'] === 'mbql/query';
}

/**
 * pMBQL dataset_query → legacy dataset_query. Legacy input passes through
 * untouched (format-sniffing: a list endpoint may return either).
 */
export function normalizeDatasetQuery(dq) {
  if (!isPmbqlQuery(dq)) return dq;
  const stages = Array.isArray(dq.stages) ? dq.stages : [];
  let acc = null;
  for (const s of stages) acc = normalizeStage(s, acc);
  if (acc && acc.__native) return { type: 'native', database: dq.database, native: acc.__native };
  return { type: 'query', database: dq.database, query: acc || {} };
}

/**
 * Normalize a full card object (non-mutating). Prefers the server-provided
 * `legacy_query` (a JSON string — the instance's own down-conversion, present
 * on ~70% of cards observed) and falls back to normalizeDatasetQuery.
 */
export function normalizeCard(card) {
  if (!card || typeof card !== 'object') return card;
  if (!isPmbqlQuery(card.dataset_query)) return card;
  if (typeof card.legacy_query === 'string' && card.legacy_query.trim().startsWith('{')) {
    try {
      const lq = JSON.parse(card.legacy_query);
      if (lq && (lq.type === 'native' || lq.type === 'query')) return { ...card, dataset_query: lq };
    } catch { /* fall through to the normalizer */ }
  }
  if (isOptsMap(card.legacy_query) && (card.legacy_query.type === 'native' || card.legacy_query.type === 'query')) {
    return { ...card, dataset_query: card.legacy_query };
  }
  return { ...card, dataset_query: normalizeDatasetQuery(card.dataset_query) };
}
