/**
 * Metabase → Sigma Data Model converter.   [LIVE-VALIDATED 2026-06-11 — exact parity; see refs/design-notes.md §10]
 *
 * Input = plain REST JSON (see refs/rest-api.md):
 *   { metadata?: <GET /api/database/{id}/metadata>, cards: [<GET /api/card/{id}>, …],
 *     sandboxes?: [<GET /api/mt/gtap> entries — EE row sandboxing, detect-only] }
 *
 * Mapping (refs/design-notes.md decisions 1–8):
 *   referenced warehouse table         → `warehouse-table` element (all metadata fields as raw columns)
 *   MBQL card with `joins`             → its own element with a `join` source (left/right/inner/full)
 *   nested question (source "card__N") → element sourced from card N's element (kind:'table')
 *   native SQL card                    → sql-source element (statement verbatim; NO element name;
 *                                        {{tags}} flagged with the control to create)
 *   `expressions`                      → calculated columns (translateMbqlExpr)
 *   `aggregation` (+ aggregation-options names) → element metrics
 *   breakout temporal-unit             → DateTrunc calc column
 *   fk_target_field_id (both tables present)    → DM relationship + derived join view
 *   sandboxes                          → `security` (DETECT-ONLY — never injected into the model)
 *
 * MBQL arrives already parsed (nested JSON arrays), so translateMbqlExpr walks a
 * tree — no regex DSL parsing. Every row of refs/expression-dsl.md is implemented;
 * flagged ops (cum-sum, offset, segment, metric, binning) emit a readable
 * "unmapped" comment placeholder + a loud warning — never silent, never faked.
 */

import {
  resetIds, sigmaShortId, sigmaInodeId, sigmaDisplayName, sigmaColFormula,
  inferSigmaFormat, buildDerivedElements,
  type SigmaElement, type SigmaColumn, type SigmaMetric, type ConversionResult,
} from './sigma-ids.js';
// pMBQL ("lib/" MBQL) → legacy MBQL — modern instances (Cloud v1.61+) return
// dataset_query as {"lib/type":"mbql/query","stages":[…]}; normalize at intake.
import { normalizeCard } from './pmbql-normalize.mjs';

// ── options / shared types ────────────────────────────────────────────────────

export interface LearnedRule { pattern: string; template: string; flags?: string }

export type WarehouseDialect = 'bigquery' | 'snowflake' | 'databricks' | 'redshift' | 'postgres' | 'mysql' | 'athena' | 'unknown';

export interface MetabaseConvertOptions {
  connectionId?: string;
  database?: string;       // warehouse database for source paths (e.g. DEMO_DB)
  schema?: string;         // overrides table.schema when set
  modelName?: string;
  warehouse?: WarehouseDialect;  // drives SQL dialect transforms (array agg, etc.)
  // Customer-discovered translation rules (gap-scout, ~/.metabase-to-sigma/learned-rules.json).
  // Applied BEFORE the built-in translator: a rule whose regex matches the FULL
  // JSON serialization of an MBQL node wins (template may use $1.. captures).
  learnedRules?: LearnedRule[];
}

/**
 * Apply warehouse-specific SQL transforms to a native SQL statement.
 * Called after tag rewriting, before the statement is written to the spec.
 *
 * Currently handles the single most common rendering failure:
 *   Array aggregations — Sigma cannot display array/nested types in table cells.
 *   Each warehouse has a different string-aggregation idiom.
 */
export function applyWarehouseTransforms(sql: string, warehouse: WarehouseDialect): string {
  switch (warehouse) {
    case 'bigquery':
      // ARRAY_AGG(x [IGNORE NULLS]) → array_to_string(ARRAY_AGG(x [IGNORE NULLS]), ', ')
      // Skip if already wrapped to avoid double-wrapping on re-runs.
      return sql.replace(
        /\bARRAY_AGG\s*(\([^)]+(?:\s+IGNORE\s+NULLS)?\)(?:\s+IGNORE\s+NULLS)?)/gi,
        (m) => m.toLowerCase().includes('array_to_string') ? m : `array_to_string(${m}, ', ')`,
      );
    case 'snowflake':
      // Snowflake ARRAY_AGG returns VARIANT — Sigma renders it as "[object]".
      // LISTAGG is simpler and returns a plain string.
      return sql.replace(
        /\bARRAY_AGG\s*\(([^)]+)\)/gi,
        (_m, arg) => `LISTAGG(${arg}, ', ')`,
      );
    case 'databricks':
      // collect_list(x) returns an array type — wrap in array_join.
      return sql.replace(
        /\bcollect_list\s*\(([^)]+)\)/gi,
        (_m, arg) => `array_join(collect_list(${arg}), ', ')`,
      );
    case 'redshift':
    case 'postgres':
      // STRING_AGG is ANSI and works on both.
      return sql.replace(
        /\bARRAY_AGG\s*\(([^)]+)\)/gi,
        (_m, arg) => `STRING_AGG(CAST(${arg} AS VARCHAR), ', ')`,
      );
    case 'athena':
      // Athena (Trino): array_join(array_agg(x), ', ')
      return sql.replace(
        /\bARRAY_AGG\s*\(([^)]+)\)/gi,
        (_m, arg) => `array_join(array_agg(${arg}), ', ')`,
      );
    default:
      return sql;
  }
}

export interface MetabaseFieldInfo {
  id: number; tableId: number; tableName: string; schema?: string;
  columnName: string; displayName: string; baseType?: string;
  fkTargetFieldId?: number | null;
}
export interface MetabaseTableInfo { id: number; name: string; schema?: string; fields: MetabaseFieldInfo[]; }
export interface FieldIndex { byId: Map<number, MetabaseFieldInfo>; tableById: Map<number, MetabaseTableInfo>; tableByLeaf: Map<string, number>; }

/** GET /api/database/{id}/metadata → field-id index (MBQL refs columns by integer id). */
export function buildFieldIndex(metadata: any): FieldIndex {
  const byId = new Map<number, MetabaseFieldInfo>();
  const tableById = new Map<number, MetabaseTableInfo>();
  const tableByLeaf = new Map<string, number>();
  for (const t of metadata?.tables || []) {
    const ti: MetabaseTableInfo = { id: t.id, name: t.name, schema: t.schema, fields: [] };
    for (const f of t.fields || []) {
      const fi: MetabaseFieldInfo = {
        id: f.id, tableId: t.id, tableName: t.name, schema: t.schema,
        columnName: f.name,
        // Sigma-derived display name (NOT Metabase's display_name) so sibling
        // bracket refs resolve against the raw-column auto-derived name.
        displayName: sigmaDisplayName(f.name),
        baseType: f.base_type, fkTargetFieldId: f.fk_target_field_id ?? null,
      };
      ti.fields.push(fi); byId.set(f.id, fi);
    }
    tableById.set(t.id, ti);
    if (t.name) tableByLeaf.set(String(t.name).toLowerCase(), t.id);
  }
  return { byId, tableById, tableByLeaf };
}

// ── simple native-SQL → native-model recognizer ─────────────────────────────
// A native-SQL card that is just a single SELECT over warehouse table(s) is
// re-expressed as a structured (MBQL) query so it converts to a NATIVE Sigma
// data model (table/join source, raw columns, aggregation metrics) instead of a
// custom-SQL element. That is what makes its dashboard filters reproducible: the
// underlying columns are exposed, so Sigma controls/element-filters work natively
// (custom-SQL {{param}} filtering is inert from the workbook — live-disproven).
// Returns a synthetic { 'source-table', joins?, aggregation?, breakout? } query,
// or null when the SQL is too complex (CTE / subquery / CASE / window / set-op /
// non-field-filter variable tag) — those fall back to a flagged custom-SQL element.
const LEAF = (path: string) => String(path).trim().replace(/[`"\];]/g, '').split('.').pop()!.toLowerCase();
const AGG_FN: Record<string, string> = { sum: 'sum', avg: 'avg', count: 'count', min: 'min', max: 'max', 'count_distinct': 'distinct', median: 'median', stddev: 'stddev' };

export function recognizeSimpleNativeSql(card: any, fidx?: FieldIndex): any | null {
  if (!fidx) return null;
  const dq = card?.dataset_query;
  if (!dq || dq.type !== 'native') return null;
  let sql = String(dq.native?.query || '');
  const tags: Record<string, any> = dq.native?.['template-tags'] || {};
  if (!sql.trim()) return null;
  sql = sql.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/--[^\n]*/g, ' ').replace(/\s+/g, ' ').trim();
  // bail on anything we will not model faithfully
  if (/^\s*with\b/i.test(sql)) return null;
  if (/\b(union|intersect|except|having)\b/i.test(sql)) return null;
  if (/\bover\s*\(/i.test(sql) || /\bcase\b/i.test(sql) || /\(\s*select\b/i.test(sql)) return null;
  // only field-filter (dimension) tags are reproducible without custom SQL;
  // a bare {{value}} variable tag needs SQL substitution → keep as custom SQL.
  for (const t of Object.values(tags)) if (String(t?.type).toLowerCase() !== 'dimension') return null;

  // split top-level clauses (safe: no subqueries past the guards above)
  const find = (kw: RegExp) => { const m = kw.exec(sql); return m ? m.index : -1; };
  if (!/^\s*select\b/i.test(sql)) return null;
  const iFrom = find(/\bfrom\b/i); if (iFrom < 0) return null;
  const iWhere = find(/\bwhere\b/i);
  const iGroup = find(/\bgroup\s+by\b/i);
  const iOrder = find(/\border\s+by\b/i);
  const bound = (start: number) => {
    const ends = [iWhere, iGroup, iOrder].filter((x) => x > start);
    return ends.length ? Math.min(...ends) : sql.length;
  };
  const selectList = sql.slice(sql.search(/select\b/i) + 6, iFrom).trim();
  const fromClause = sql.slice(iFrom + 4, bound(iFrom)).trim();
  const groupClause = iGroup >= 0 ? sql.slice(iGroup + sql.slice(iGroup).match(/^group\s+by/i)![0].length, bound(iGroup)).trim() : '';
  // WHERE must contain ONLY field-filter tags (which we surface as Sigma controls/
  // element-filters) and trivial 1=1 / [[optional]] markers — anything else is a
  // real predicate that the remodel would SILENTLY DROP (wrong numbers). Bail to
  // custom SQL in that case (never silently mistranslate). Also bail on LIMIT.
  const whereClause = iWhere >= 0 ? sql.slice(iWhere + 5, bound(iWhere)).trim() : '';
  if (whereClause) {
    const residual = whereClause
      .replace(/\{\{\s*[^}]+\s*\}\}/g, ' ').replace(/\[\[|\]\]/g, ' ')
      .replace(/\b1\s*=\s*1\b/g, ' ').replace(/\b(and|or)\b/gi, ' ')
      .replace(/[()\s]+/g, '');
    if (residual) return null;
  }
  if (/\blimit\b\s+\d/i.test(sql)) return null;

  // FROM + JOINs → alias→tableId map (first source = base)
  const aliasTable = new Map<string, number>();
  let baseTableId: number | null = null;
  const joins: any[] = [];
  // tokenize: base then repeated "[type] join <path> [as] <alias> on <cond>"
  const joinRe = /\b(?:(inner|left|right|full)\s+)?(?:outer\s+)?join\b/gi;
  const firstJoin = sql.slice(iFrom).search(joinRe);
  const baseSeg = (firstJoin < 0 ? fromClause : sql.slice(iFrom + 4, iFrom + firstJoin)).trim();
  const parseRef = (seg: string): { tid: number; alias?: string } | null => {
    const parts = seg.trim().split(/\s+/);
    const tid = fidx.tableByLeaf?.get(LEAF(parts[0]));
    if (tid == null) return null;
    let alias: string | undefined;
    if (parts.length >= 3 && /^as$/i.test(parts[1])) alias = parts[2];
    else if (parts.length === 2) alias = parts[1];
    return { tid, alias };
  };
  const baseRef = parseRef(baseSeg); if (!baseRef) return null;
  baseTableId = baseRef.tid; if (baseRef.alias) aliasTable.set(baseRef.alias.toLowerCase(), baseRef.tid);
  // walk joins
  const joinClause = firstJoin < 0 ? '' : sql.slice(iFrom + firstJoin, bound(iFrom));
  if (joinClause) {
    const segRe = /\b(?:(inner|left|right|full)\s+)?(?:outer\s+)?join\b\s+([\s\S]+?)\s+on\s+([\s\S]+?)(?=\b(?:inner\s+|left\s+|right\s+|full\s+)?(?:outer\s+)?join\b|$)/gi;
    let jm: RegExpExecArray | null;
    while ((jm = segRe.exec(joinClause))) {
      const [, jtype, jref, jcond] = jm;
      const r = parseRef(jref); if (!r) return null;
      if (r.alias) aliasTable.set(r.alias.toLowerCase(), r.tid);
      const cm = /([\w.]+)\s*=\s*([\w.]+)/.exec(jcond); if (!cm) return null;
      const resolveCol = (tok: string): any | null => {
        const [a, c] = tok.includes('.') ? tok.split('.') : [undefined, tok];
        const tid = a ? aliasTable.get(a.toLowerCase()) ?? baseTableId : baseTableId;
        const f = tid != null ? fidx.tableById.get(tid)?.fields.find((x) => x.columnName.toLowerCase() === c.toLowerCase()) : undefined;
        return f ? ['field', f.id, a && aliasTable.get(a.toLowerCase()) !== baseTableId ? { 'join-alias': a } : null] : null;
      };
      const L = resolveCol(cm[1]), R = resolveCol(cm[2]); if (!L || !R) return null;
      joins.push({ 'source-table': r.tid, strategy: `${(jtype || 'left').toLowerCase()}-join`, alias: r.alias,
        condition: ['=', L, R] });
    }
  }

  // resolve a "[alias.]col" token to a field ref
  const colRef = (tok: string): any | null => {
    const [a, c] = tok.includes('.') ? tok.split('.') : [undefined, tok];
    const tid = a ? aliasTable.get(a.toLowerCase()) : baseTableId;
    if (tid == null) return null;
    const f = fidx.tableById.get(tid)?.fields.find((x) => x.columnName.toLowerCase() === c.replace(/[`"]/g, '').toLowerCase());
    return f ? ['field', f.id, a && tid !== baseTableId ? { 'join-alias': a } : null] : null;
  };

  // SELECT list → aggregations + plain dimensions. Track each item's output ALIAS
  // (explicit `as X`, else the column/function name) so the dashboard can re-map
  // the card's viz settings (graph.dimensions/metrics reference these aliases).
  const items = selectList.split(/,(?![^(]*\))/).map((s) => s.trim());
  if (items.some((s) => !s)) return null;   // trailing/empty comma (e.g. BQ `…, from`) — don't trust the parse; keep verbatim SQL
  const aggregation: any[] = [];
  const breakout: any[] = [];
  const resultMetadata: any[] = [];
  const explicitAlias = (it: string): string | null => { const m = /\s+as\s+(["`\w]+)\s*$/i.exec(it); return m ? m[1].replace(/["`]/g, '') : null; };
  for (const it of items) {
    const expr = it.replace(/\s+as\s+["`\w]+\s*$/i, '').trim();
    const am = /^(\w+)\s*\(\s*(distinct\s+)?(.+?)\s*\)$/i.exec(expr);
    if (am && AGG_FN[am[1].toLowerCase()]) {
      const fn = AGG_FN[(am[2] ? 'count_distinct' : am[1]).toLowerCase()] || AGG_FN[am[1].toLowerCase()];
      const arg = am[3].trim();
      const aggIdx = aggregation.length;
      if (arg === '*' || /^\d+$/.test(arg)) aggregation.push(['count']);
      else { const ref = colRef(arg); if (!ref) return null; aggregation.push([fn, ref]); }
      const alias = explicitAlias(it) || am[1].toLowerCase();
      resultMetadata.push({ name: alias, display_name: alias, field_ref: ['aggregation', aggIdx] });
      continue;
    }
    if (!/^[\w.`"]+$/.test(expr)) return null;       // reject non-trivial expressions
    const ref = colRef(expr); if (!ref) return null;
    const alias = explicitAlias(it) || expr.split('.').pop()!.replace(/[`"]/g, '');
    breakout.push(ref);
    resultMetadata.push({ name: alias, display_name: alias, field_ref: ref });
  }
  // If a GROUP BY is present it defines the dimension grain; honor it (ordinals
  // map to the Nth select item). Otherwise the SELECT dims are the breakout.
  if (groupClause) {
    breakout.length = 0;
    for (const g of groupClause.split(/,(?![^(]*\))/).map((s) => s.trim()).filter(Boolean)) {
      if (/^\d+$/.test(g)) { const rm = resultMetadata[Number(g) - 1]; if (rm && Array.isArray(rm.field_ref) && rm.field_ref[0] === 'field') breakout.push(rm.field_ref); continue; }
      const ref = colRef(g); if (!ref) return null;
      breakout.push(ref);
    }
  }
  // Surface every field-filter tag's mapped column as an extra breakout dimension
  // (so it lands in the result set + the element exposes it) — that is what lets
  // the dashboard reproduce the filter as a native Sigma control/element-filter.
  // It is NOT added to the viz, so it never becomes an unwanted chart axis.
  for (const t of Object.values(tags)) {
    const dim = (t as any).dimension;
    const fid = Array.isArray(dim) && dim[0] === 'field' && typeof dim[1] === 'number' ? dim[1] : null;
    if (fid == null || resultMetadata.some((rm) => Array.isArray(rm.field_ref) && rm.field_ref[1] === fid)) continue;
    const f = fidx.byId.get(fid); if (!f) continue;
    breakout.push(dim);
    resultMetadata.push({ name: f.columnName, display_name: f.columnName, field_ref: dim });
  }

  const query = { database: dq.database, 'source-table': baseTableId, ...(joins.length ? { joins } : {}),
    ...(aggregation.length ? { aggregation } : {}), ...(breakout.length ? { breakout } : {}) };
  return { query, resultMetadata };
}

// ── MBQL expression tree → Sigma formula ─────────────────────────────────────

export interface MbqlCtx {
  /** ["field", id|name, opts] → bracketed Sigma ref (DateTrunc-wrapped if temporal-unit). */
  resolveField: (ref: any) => string;
  /** Same ref → bare display name (for naming metrics/columns). */
  fieldDisplay: (ref: any) => string;
  warn: (msg: string) => void;
  learnedRules?: LearnedRule[];
}

const DATEPART: Record<string, string> = {
  'get-year': 'year', 'get-quarter': 'quarter', 'get-month': 'month', 'get-week': 'week',
  'get-day': 'day', 'get-day-of-week': 'dayofweek', 'get-hour': 'hour',
  'get-minute': 'minute', 'get-second': 'second',
};

export function translateMbqlExpr(node: any, ctx: MbqlCtx): string {
  // Learned rules first — a validated customer rule beats the built-in translation.
  // Contract mirrors cognos applyLearnedRules: regex pattern → template, but matched
  // against the FULL JSON serialization of the node (MBQL is a tree, not a string).
  if (ctx.learnedRules?.length && typeof node === 'object' && node !== null) {
    const json = JSON.stringify(node);
    for (const r of ctx.learnedRules) {
      try {
        const re = new RegExp(r.pattern, r.flags || '');
        const m = json.match(re);
        if (m && m.index === 0 && m[0].length === json.length) return json.replace(re, r.template);
      } catch { /* bad rule — skip */ }
    }
  }
  if (node === null || node === undefined) return 'Null';
  if (typeof node === 'number') return String(node);
  if (typeof node === 'boolean') return node ? 'True' : 'False';
  if (typeof node === 'string') return `"${node.replace(/"/g, '\\"')}"`;
  if (!Array.isArray(node)) {
    ctx.warn(`unrecognized MBQL node ${JSON.stringify(node).slice(0, 60)} — emitted a placeholder.`);
    return `/* unmapped: ${JSON.stringify(node).slice(0, 40)} */`;
  }

  const op = String(node[0]).toLowerCase();
  const t = (x: any) => translateMbqlExpr(x, ctx);
  const args = () => node.slice(1).map(t);

  switch (op) {
    case 'field': return ctx.resolveField(node);
    case 'expression': return `[${node[1]}]`;                 // sibling custom-column ref
    case 'value': return t(node[1]);                          // literal wrapper unwraps transparently

    // n-ary arithmetic → left-fold binary
    case '+': case '-': case '*': case '/': {
      const a = args();
      return a.length === 1 ? a[0] : a.reduce((acc, x) => `(${acc} ${op} ${x})`);
    }

    case 'case': {
      const clauses: any[] = node[1] || [];
      const dflt = node[2] && typeof node[2] === 'object' && 'default' in node[2] ? t(node[2].default) : 'Null';
      let out = dflt;
      for (let i = clauses.length - 1; i >= 0; i--) out = `If(${t(clauses[i][0])}, ${t(clauses[i][1])}, ${out})`;
      return out;
    }

    case 'coalesce': return `Coalesce(${args().join(', ')})`;
    case 'concat': return `Concat(${args().join(', ')})`;
    case 'substring': return node[3] !== undefined
      ? `Mid(${t(node[1])}, ${t(node[2])}, ${t(node[3])})` : `Mid(${t(node[1])}, ${t(node[2])})`;
    case 'trim': return `Trim(${t(node[1])})`;
    case 'ltrim': return `LTrim(${t(node[1])})`;
    case 'rtrim': return `RTrim(${t(node[1])})`;
    case 'upper': return `Upper(${t(node[1])})`;
    case 'lower': return `Lower(${t(node[1])})`;
    case 'length': return `Len(${t(node[1])})`;
    case 'replace': return `Replace(${t(node[1])}, ${t(node[2])}, ${t(node[3])})`;
    case 'regex-match-first': return `RegexpExtract(${t(node[1])}, ${t(node[2])})`;
    case 'split-part': return `SplitPart(${t(node[1])}, ${t(node[2])}, ${t(node[3])})`;

    case 'round': return `Round(${args().join(', ')})`;
    case 'floor': return `Floor(${t(node[1])})`;
    case 'ceil': return `Ceiling(${t(node[1])})`;
    case 'abs': return `Abs(${t(node[1])})`;
    case 'sqrt': return `Sqrt(${t(node[1])})`;
    case 'exp': return `Exp(${t(node[1])})`;
    case 'power': return `Power(${t(node[1])}, ${t(node[2])})`;
    case 'log': return `Log(${t(node[1])}, 10)`;              // Metabase log is base-10

    case 'datetime-add': return `DateAdd("${node[3]}", ${t(node[2])}, ${t(node[1])})`;
    case 'datetime-subtract': {
      const n = node[2];
      const neg = typeof n === 'number' ? String(-n) : `-(${t(n)})`;
      return `DateAdd("${node[3]}", ${neg}, ${t(node[1])})`;
    }
    case 'datetime-diff': return `DateDiff("${node[3]}", ${t(node[1])}, ${t(node[2])})`;
    case 'get-year': case 'get-quarter': case 'get-month': case 'get-week':
    case 'get-day': case 'get-day-of-week': case 'get-hour': case 'get-minute': case 'get-second':
      return `DatePart("${DATEPART[op]}", ${t(node[1])})`;
    case 'now': return 'Now()';
    case 'relative-datetime':
      return node[1] === 'current' ? 'Today()' : `DateAdd("${node[2]}", ${t(node[1])}, Today())`;

    // type casts (Metabase 50+ expression functions)
    case 'text': return `Text(${t(node[1])})`;
    case 'integer': return `Int(${t(node[1])})`;
    case 'float': return `Number(${t(node[1])})`;
    case 'date': return `DateTrunc("day", ${t(node[1])})`;   // date(x) = day-truncated datetime

    // comparisons — multi-value `=` ⇒ infix `or` chain; multi `!=` ⇒ infix `and` chain.
    // Sigma has NO IsIn, and NO Or()/And() FUNCTIONS either — `Or(a, b)` returns
    // "Invalid formula" at POST (live-verified 2026-06-12); and/or are infix only.
    // (pMBQL `in`/`not-in` are normalized to multi-value =/!= upstream; aliased here too)
    case 'in': case 'not-in': case '=': case '!=': {
      const eq = op === '=' || op === 'in' ? '=' : '!=';
      const a = t(node[1]);
      const vals = node.slice(2).map(t);
      if (vals.length <= 1) return `${a} ${eq} ${vals[0] ?? 'Null'}`;
      const parts = vals.map((v: string) => `${a} ${eq} ${v}`);
      return eq === '=' ? `(${parts.join(' or ')})` : `(${parts.join(' and ')})`;
    }
    case '<': case '<=': case '>': case '>=':
      return `${t(node[1])} ${op} ${t(node[2])}`;
    case 'between': return `Between(${t(node[1])}, ${t(node[2])}, ${t(node[3])})`;
    case 'and': return `(${args().join(' and ')})`;
    case 'or': return `(${args().join(' or ')})`;
    case 'not': return `Not(${t(node[1])})`;
    case 'is-null': return `IsNull(${t(node[1])})`;
    case 'not-null': return `IsNotNull(${t(node[1])})`;
    case 'is-empty': return `(IsNull(${t(node[1])}) or ${t(node[1])} = "")`;
    case 'not-empty': return `(IsNotNull(${t(node[1])}) and ${t(node[1])} != "")`;

    case 'starts-with': case 'ends-with': case 'contains': case 'does-not-contain': {
      const fn = op === 'starts-with' ? 'StartsWith' : op === 'ends-with' ? 'EndsWith' : 'Contains';
      const opts = node[3] && typeof node[3] === 'object' ? node[3] : {};
      const caseSensitive = opts['case-sensitive'] === true;
      const s = t(node[1]), sub = t(node[2]);
      // Metabase string matching is case-INSENSITIVE by default — wrap in Lower()
      const body = caseSensitive ? `${fn}(${s}, ${sub})` : `${fn}(Lower(${s}), Lower(${sub}))`;
      return op === 'does-not-contain' ? `Not(${body})` : body;
    }

    case 'time-interval': {
      const f = t(node[1]); const n = node[2]; const unit = node[3];
      if (n === 'current') return `DateTrunc("${unit}", ${f}) = DateTrunc("${unit}", Today())`;
      return typeof n === 'number' && n > 0
        ? `${f} <= DateAdd("${unit}", ${n}, Today())`
        : `${f} >= DateAdd("${unit}", ${typeof n === 'number' ? n : t(n)}, Today())`;
    }
    case 'inside': {
      // ["inside", latField, lonField, latMax, lonMin, latMin, lonMax] → lat/lon Between pair
      const [lat, lon, latMax, lonMin, latMin, lonMax] = node.slice(1).map(t);
      return `(Between(${lat}, ${latMin}, ${latMax}) and Between(${lon}, ${lonMin}, ${lonMax}))`;
    }

    // ── aggregations (legal at the top of an aggregation clause) ──────────────
    case 'count': return 'Count()';
    case 'sum': return `Sum(${t(node[1])})`;
    case 'avg': return `Avg(${t(node[1])})`;
    case 'min': return `Min(${t(node[1])})`;
    case 'max': return `Max(${t(node[1])})`;
    case 'median': return `Median(${t(node[1])})`;
    case 'distinct': return `CountDistinct(${t(node[1])})`;
    case 'stddev': return `StdDev(${t(node[1])})`;
    case 'var': return `Variance(${t(node[1])})`;
    case 'percentile': return `Percentile(${t(node[1])}, ${t(node[2])})`;
    case 'count-where': return `CountIf(${t(node[1])})`;            // condition only — no field arg
    case 'sum-where': return `SumIf(${t(node[1])}, ${t(node[2])})`; // FIELD FIRST
    case 'share': return `CountIf(${t(node[1])}) / Count()`;
    case 'aggregation-options': return t(node[1]);                  // wrapper only supplies the name

    // ── flagged — never faked ──────────────────────────────────────────────────
    case 'cum-sum': case 'cum-count':
      ctx.warn(`"${op}" is a running total — rebuild with CumulativeSum in the date-grouped workbook element (window scope lives on the consuming element).`);
      return `/* unmapped: ${op} */`;
    case 'offset':
      ctx.warn('"offset" is a lag/lead window function — rebuild with Lag/window calc in the consuming element.');
      return '/* unmapped: offset */';
    case 'segment':
      ctx.warn(`["segment", ${node[1]}] references a saved segment — inline its MBQL from GET /api/segment/${node[1]} and re-run.`);
      return `/* unmapped: segment ${node[1]} */`;
    case 'metric':
      ctx.warn(`["metric", ${node[1]}] references a saved (legacy) metric — inline its MBQL from GET /api/legacy-metric/${node[1]} and re-run.`);
      return `/* unmapped: metric ${node[1]} */`;
    case 'aggregation':
      ctx.warn(`["aggregation", ${node[1]}] positional ref outside order-by — not resolvable here.`);
      return `/* unmapped: aggregation ${node[1]} */`;

    default:
      ctx.warn(`MBQL op "${op}" has no confirmed Sigma mapping — emitted a placeholder; review/translate manually.`);
      return `/* unmapped: ${op} */`;
  }
}

const AGG_LABEL: Record<string, (d: string) => string> = {
  count: () => 'Count',
  sum: (d) => `Sum of ${d}`, avg: (d) => `Average of ${d}`, min: (d) => `Min of ${d}`,
  max: (d) => `Max of ${d}`, median: (d) => `Median of ${d}`,
  distinct: (d) => `Distinct Count of ${d}`, stddev: (d) => `StdDev of ${d}`,
  var: (d) => `Variance of ${d}`, percentile: (d) => `Percentile of ${d}`,
  'count-where': () => 'Count of Matching Rows', 'sum-where': (d) => `Sum of ${d} (Filtered)`,
  share: () => 'Share of Matching Rows',
  'cum-sum': (d) => `Cumulative Sum of ${d}`, 'cum-count': () => 'Cumulative Count',
};

/** Aggregation clause → { formula, name } — named via aggregation-options, else derived ("Sum of Revenue"). */
export function translateAggregation(node: any, ctx: MbqlCtx): { formula: string; name: string } {
  let inner = node; let name: string | undefined;
  if (Array.isArray(node) && String(node[0]).toLowerCase() === 'aggregation-options') {
    inner = node[1];
    const o = node[2] || {};
    name = o['display-name'] || (o.name ? sigmaDisplayName(o.name) : undefined);
  }
  const formula = translateMbqlExpr(inner, ctx);
  if (!name) {
    const op = Array.isArray(inner) ? String(inner[0]).toLowerCase() : '';
    const fieldRef = Array.isArray(inner) ? inner.find((x: any) => Array.isArray(x) && x[0] === 'field') : undefined;
    const disp = fieldRef ? ctx.fieldDisplay(fieldRef) : '';
    name = AGG_LABEL[op] ? AGG_LABEL[op](disp) : sigmaDisplayName(op || 'Metric');
  }
  return { formula, name };
}

// ── convert ───────────────────────────────────────────────────────────────────

// Live-verified enum: inner | left-outer | right-outer | full-outer | lookup.
const JOIN_TYPE: Record<string, string> = {
  'left-join': 'left-outer', 'right-join': 'right-outer', 'inner-join': 'inner', 'full-join': 'full-outer',
};
const titleCase = (s: string) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : s);

function normalizeInput(input: any): { metadata?: any; cards: any[]; sandboxes?: any[] } {
  const root = typeof input === 'string' ? JSON.parse(input) : input;
  // pMBQL → legacy at extraction intake; per-card sniff (a list may mix formats).
  const norm = (cs: any[]) => (cs || []).map((c) => normalizeCard(c));
  if (Array.isArray(root)) return { cards: norm(root) };
  if (root?.cards) return { metadata: root.metadata, cards: norm(root.cards), sandboxes: root.sandboxes };
  if (root?.dataset_query) return { cards: norm([root]) };
  return { metadata: root?.metadata, cards: [], sandboxes: root?.sandboxes };
}

export function convertMetabaseToSigma(input: string | object, options: MetabaseConvertOptions = {}): ConversionResult {
  resetIds();
  const { connectionId = '<CONNECTION_ID>', database = '', schema = '' } = options;
  const warnings: string[] = [];
  const inp = normalizeInput(input);
  const fidx = inp.metadata ? buildFieldIndex(inp.metadata) : null;
  if (!fidx) warnings.push("no database metadata provided — falling back to each card's result_metadata names (table qualifiers are lost); pass GET /api/database/{id}/metadata as input.metadata.");

  // Engine-aware database default when --database is omitted: Metabase metadata
  // carries the warehouse identifier in engine-specific `details` keys
  // (Snowflake `db`; BigQuery `project-id` — Sigma BQ paths are [project, dataset, table]).
  const metaEngine: string = inp.metadata?.engine || '';
  const metaDb: string = (() => {
    const d = inp.metadata?.details || {};
    const keys = /bigquery/.test(metaEngine)
      ? ['project-id', 'project-id-from-credentials']
      : ['db', 'dbname', 'database'];
    for (const k of keys) if (typeof d[k] === 'string' && d[k]) return d[k];
    return '';
  })();

  interface ElemCtx {
    element: SigmaElement; columns: SigmaColumn[]; metrics: SigmaMetric[]; order: string[];
    colIdByName: Map<string, string>; colIdByFieldId: Map<number, string>;
    ownedByCard: boolean;   // card-specific element (join/nested/sql) — safe for element filters
  }
  const elemCtxs: ElemCtx[] = [];
  const tableCtxByTableId = new Map<number, ElemCtx>();
  const newCtx = (element: SigmaElement, ownedByCard: boolean): ElemCtx => {
    const c: ElemCtx = {
      element, columns: element.columns as SigmaColumn[], metrics: [], order: element.order as string[],
      colIdByName: new Map(), colIdByFieldId: new Map(), ownedByCard,
    };
    elemCtxs.push(c); return c;
  };

  const tablePath = (t: MetabaseTableInfo): string[] => {
    const path: string[] = [database || metaDb || '<DATABASE>'];
    // Per-table schema FIRST — estates span schemas/datasets; --schema is only a
    // fallback for metadata that omits it.
    const sch = t.schema || schema || '';
    if (sch) path.push(sch);
    // Preserve case: Snowflake metadata reports uppercase physical names already;
    // BigQuery (case-sensitive) reports lowercase — uppercasing breaks BQ paths
    // AND the formula prefixes that must match the path tail (live-verified:
    // [accounts/Account Id] on path […, 'accounts'] resolves; ACCOUNTS would not).
    path.push(t.name);
    return path;
  };

  // Referenced warehouse table → warehouse-table element (one per table, deduped).
  const ensureTableElement = (tableId: number): ElemCtx | null => {
    const existing = tableCtxByTableId.get(tableId);
    if (existing) return existing;
    const t = fidx?.tableById.get(tableId);
    if (!t) { warnings.push(`table ${tableId} is not in the database metadata — cannot emit a warehouse-table element for it.`); return null; }
    // Case-preserved: the warehouse-element column prefix must match the path tail
    // exactly (BQ is lowercase; Snowflake metadata is already uppercase).
    const tableTail = t.name;
    const element: SigmaElement = {
      id: sigmaShortId(), kind: 'table', name: sigmaDisplayName(t.name),
      source: { connectionId, kind: 'warehouse-table', path: tablePath(t) },
      columns: [], order: [],
    };
    const ctx = newCtx(element, false);
    tableCtxByTableId.set(tableId, ctx);
    for (const f of t.fields) {
      const id = sigmaInodeId(f.columnName);
      ctx.columns.push({ id, formula: sigmaColFormula(tableTail, f.columnName) });
      ctx.order.push(id);
      ctx.colIdByName.set(f.displayName.toLowerCase(), id);
      ctx.colIdByFieldId.set(f.id, id);
    }
    return ctx;
  };

  // Per-card MBQL translation context: field-id resolution via metadata, falling
  // back to the card's result_metadata names (with a warning — decision 1).
  const mkMbqlCtx = (card: any): MbqlCtx => {
    const rmById = new Map<number, any>();
    for (const rm of card.result_metadata || []) {
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
        warnings.push(`card "${card.name}": field ${idOrName} could not be resolved (no metadata match, no result_metadata match) — emitted [Field ${idOrName}]. Fallback chain: pass /api/database/{id}/metadata; if that 403s on a scoped key, GET /api/field/${idOrName} works even for restricted DBs.`);
        return `Field ${idOrName}`;
      }
      return sigmaDisplayName(String(idOrName ?? ''));
    };
    const ctx: MbqlCtx = {
      fieldDisplay: display,
      resolveField: (ref: any) => {
        const opts = (Array.isArray(ref) && ref[2]) || {};
        // Implicit FK join ([field, dimField, {source-field}]) — the dim table must
        // exist as an element or the FK relationship (and the derived view column
        // the consuming chart needs) is silently dropped (live-verified).
        if (opts['source-field'] && Array.isArray(ref) && typeof ref[1] === 'number') {
          const f = fidx?.byId.get(ref[1]);
          if (f) ensureTableElement(f.tableId);
        }
        let out = `[${display(ref)}]`;
        if (opts['temporal-unit']) out = `DateTrunc("${opts['temporal-unit']}", ${out})`;
        if (opts.binning) ctx.warn(`numeric binning on [${display(ref)}] is flagged — recreate with BinFixed/BinCount in the workbook element.`);
        return out;
      },
      warn: (m) => warnings.push(`card "${card.name}": ${m}`),
      learnedRules: options.learnedRules,
    };
    return ctx;
  };

  const parseJoinCondition = (cond: any, ctxM: MbqlCtx): Array<{ left: string; right: string }> => {
    // Join-condition refs are bare [Column] scoped to each side, using Sigma's
    // PRETTIFIED display name of the physical column ('[Product Key]'; the physical
    // '[PRODUCT_KEY]' 400s "Column reference not found" — live-verified).
    const rawCol = (ref: any): string => {
      if (Array.isArray(ref) && ref[0] === 'field' && typeof ref[1] === 'number') {
        const f = fidx?.byId.get(ref[1]);
        if (f) return `[${sigmaDisplayName(f.columnName)}]`;
      }
      return `[${ctxM.fieldDisplay(ref)}]`;
    };
    const out: Array<{ left: string; right: string }> = [];
    const walk = (c: any) => {
      if (!Array.isArray(c)) return;
      const op = String(c[0]).toLowerCase();
      if (op === 'and') { c.slice(1).forEach(walk); return; }
      if (op === '=' && c.length === 3) out.push({ left: rawCol(c[1]), right: rawCol(c[2]) });
    };
    walk(cond);
    return out;
  };

  // MBQL card with `joins` → its own element with a join source.
  const buildJoinElement = (card: any, q: any, ctxM: MbqlCtx): ElemCtx | null => {
    const baseId = q['source-table'];
    const baseT = typeof baseId === 'number' ? fidx?.tableById.get(baseId) : undefined;
    if (!baseT) { warnings.push(`card "${card.name}" joins from table ${JSON.stringify(baseId)}, which is not in the metadata — join element skipped.`); return null; }
    ensureTableElement(baseId);  // base + joined tables also get warehouse-table elements (FK relationships, reuse)
    const joins: any[] = [];
    const joinedTables: MetabaseTableInfo[] = [];
    for (const j of q.joins || []) {
      const jt = typeof j['source-table'] === 'number' ? fidx?.tableById.get(j['source-table']) : undefined;
      if (!jt) { warnings.push(`card "${card.name}": join to ${JSON.stringify(j['source-table'])} not resolvable (card-source join or missing metadata) — that join was skipped.`); continue; }
      ensureTableElement(j['source-table']);
      joinedTables.push(jt);
      const on = parseJoinCondition(j.condition, ctxM);
      if (!on.length) warnings.push(`card "${card.name}": join condition for ${jt.name} is not a simple equi-join — author the ON clause in Sigma.`);
      joins.push({
        // connectionId is REQUIRED on each join side (nested sources carry their own
        // connection — live-verified 400 "joins[0].left.connectionId: Invalid string").
        // Conditions live in `columns` (not `on`), and the relationship `name` is the
        // formula prefix for this right source's columns ([NAME/Col]).
        left: { kind: 'warehouse-table', connectionId, path: tablePath(baseT) },
        right: { kind: 'warehouse-table', connectionId, path: tablePath(jt) },
        joinType: JOIN_TYPE[j.strategy || 'left-join'] || 'left-outer',
        columns: on,
        name: jt.name,
      });
    }
    const element: SigmaElement = {
      id: sigmaShortId(), kind: 'table', name: card.name || `Card ${card.id}`,
      // source.name is the formula prefix for the head source's columns.
      source: { kind: 'join', name: baseT.name, connectionId, joins },
      columns: [], order: [],
    };
    const ctx = newCtx(element, true);
    const addRaw = (t: MetabaseTableInfo) => {
      for (const f of t.fields) {
        const key = f.displayName.toLowerCase();
        if (ctx.colIdByName.has(key)) continue; // duplicate display name (e.g. the join key on both sides) — first wins
        const id = sigmaInodeId(f.columnName);
        ctx.columns.push({ id, formula: sigmaColFormula(t.name, f.columnName) });
        ctx.order.push(id);
        ctx.colIdByName.set(key, id);
        ctx.colIdByFieldId.set(f.id, id);
      }
    };
    addRaw(baseT);
    for (const jt of joinedTables) addRaw(jt);
    return ctx;
  };

  const addCalc = (ctx: ElemCtx, name: string, formula: string): void => {
    if (ctx.colIdByName.has(name.toLowerCase())) return; // same-named calc already on this (shared) element
    const id = sigmaShortId();
    ctx.columns.push({ id, name, formula });
    ctx.order.push(id);
    ctx.colIdByName.set(name.toLowerCase(), id);
  };
  const addMetric = (ctx: ElemCtx, name: string, formula: string): void => {
    if (ctx.metrics.some((m) => m.name === name)) return;
    const m: SigmaMetric = { id: sigmaShortId(), name, formula };
    const fmt = inferSigmaFormat(formula, name);
    if (fmt) (m as any).format = fmt;
    ctx.metrics.push(m);
  };

  const cards: any[] = inp.cards || [];
  const cardById = new Map<number, any>(cards.filter((c) => c?.id != null).map((c) => [c.id, c]));
  const cardElemId = new Map<number, string>();
  const inFlight = new Set<number>();
  let sqlElements = 0;

  // ── template tags → Sigma controls (45% of cards on the reference estate) ────
  // Plain variable tags keep their {{tag}} verbatim — Sigma custom SQL uses the
  // SAME {{control-id}} parameter syntax — and get a matching control element.
  // Field-filter (dimension) tags expand to a whole SQL predicate at runtime, so
  // the {{tag}} is replaced with a documented `1=1 /* … */` and the filter is
  // recreated as a control + element filter on the consuming workbook element.
  // See refs/template-tags.md for the full mapping table.
  const TAG_CONTROL_TYPE: Record<string, string> = { text: 'text', number: 'number', date: 'date', boolean: 'switch' };
  const controlElements: SigmaElement[] = [];
  const controlByControlId = new Map<string, any>();
  const ensureControl = (controlId: string, name: string, controlType: string, value: any): void => {
    const existing = controlByControlId.get(controlId);
    if (existing) {
      if (existing.controlType !== controlType) {
        warnings.push(`template tag "${controlId}" appears with conflicting types (${existing.controlType} vs ${controlType}) across cards — one control was emitted with type ${existing.controlType}; review.`);
      }
      return;
    }
    // Each controlType variant has REQUIRED discriminant fields (live-verified: omitting
    // text's `mode` fails the union match and surfaces as `Invalid kind: "control"`).
    const ctrl: any = { id: sigmaShortId(), kind: 'control', controlId, name, controlType };
    if (controlType === 'text') ctrl.mode = 'equals';
    if (controlType === 'number') ctrl.mode = '=';
    if (controlType === 'date') ctrl.mode = '=';
    if (controlType === 'switch') ctrl.mode = 'True/All';
    if (value != null) ctrl.value = value;
    controlByControlId.set(controlId, ctrl);
    controlElements.push(ctrl);
  };
  const TAG_RE = (tag: string) => new RegExp(`\\{\\{\\s*${tag.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\}\\}`, 'g');

  /** Rewrite a native statement per its template tags; returns the SQL to emit. */
  const processNativeSql = (card: any, statement: string, tags: Record<string, any>): string => {
    let sql = statement;
    const tagType = (n: string) => String(tags[n]?.type || 'text').toLowerCase();
    // 1. Optional [[ … ]] blocks (Metabase: included only when the tag has a value).
    sql = sql.replace(/\[\[([\s\S]*?)\]\]/g, (_m, body: string) => {
      const inner = [...body.matchAll(/\{\{\s*([^{}\s]+)\s*\}\}/g)].map((m) => m[1]);
      const keep = inner.length > 0 && inner.every((n) =>
        tagType(n) === 'dimension' || tags[n]?.default != null);
      if (keep) {
        warnings.push(`card "${card.name}": optional [[…]] block kept ACTIVE (its tag${inner.length > 1 ? 's' : ''} {{${inner.join('}}, {{')}}} ${inner.every((n) => tagType(n) === 'dimension') ? 'are field filters that neutralize to 1=1' : 'have defaults'}) — verify the always-on semantics.`);
        return body;
      }
      warnings.push(`card "${card.name}": optional [[…]] block DROPPED (tag has no default — Metabase omits it when empty; Sigma has no optional-clause syntax). Re-add the clause around the control if the filter must be available: ${body.trim().slice(0, 80)}`);
      return '';
    });
    // 2. Per-tag handling.
    for (const [tagName, tagRaw] of Object.entries(tags)) {
      const tag: any = tagRaw;
      const ttype = String(tag?.type || 'text').toLowerCase();
      const display = tag?.['display-name'] || sigmaDisplayName(tagName);
      if (ttype === 'dimension') {
        // field filter — expands to a whole WHERE predicate at runtime
        const dim = tag.dimension;
        const fieldId = Array.isArray(dim) && dim[0] === 'field' && typeof dim[1] === 'number' ? dim[1] : null;
        const f = fieldId != null ? fidx?.byId.get(fieldId) : undefined;
        const colDesc = f ? `[${f.displayName}] (${f.tableName})` : `the tag's mapped column (field ${fieldId ?? '?'} — resolve via GET /api/field/{id})`;
        // NO {{braces}} in the comment — Sigma resolves {{…}} refs even inside SQL
        // comments and 400s on the missing control (live-verified).
        sql = sql.replace(TAG_RE(tagName), `1=1 /* Metabase field filter '${tagName}' → filter ${f ? `[${f.displayName}]` : 'the mapped column'} on the consuming Sigma element */`);
        warnings.push(`card "${card.name}": native {{${tagName}}} is a FIELD FILTER (widget ${tag['widget-type'] || '?'}) on ${colDesc} — the predicate was neutralized to 1=1 in the SQL; recreate it as a Sigma control + element filter on that column in the workbook (field filters expand to a whole WHERE clause, not a scalar).`);
      } else if (ttype === 'card') {
        // {{#N}} sub-question — inline its SQL when the referenced card is available
        const refId = tag['card-id'];
        const ref = refId != null ? cardById.get(refId) : undefined;
        const refDq = ref?.dataset_query;
        const refTags = refDq?.native?.['template-tags'] || {};
        if (refDq?.type === 'native' && Object.keys(refTags).length === 0) {
          sql = sql.replace(TAG_RE(tagName), `(\n${refDq.native?.query || ''}\n)`);
          warnings.push(`card "${card.name}": native {{${tagName}}} (sub-question card ${refId}) was INLINED as a sub-select from card ${refId}'s SQL — verify.`);
        } else {
          warnings.push(`card "${card.name}": native {{${tagName}}} references card ${refId ?? '?'} — ${ref ? 'it is not a tag-free native card, so it was NOT inlined automatically' : `fetch GET /api/card/${refId ?? '{id}'}, add it to the input set, and re-run to inline it`}; resolve manually before posting.`);
        }
      } else if (ttype === 'snippet') {
        warnings.push(`card "${card.name}": native {{${tagName}}} splices a SQL snippet — inline it (GET /api/native-query-snippet) into the statement before posting; Sigma has no snippet library.`);
      } else {
        // text / number / date / boolean variable — SAME {{name}} syntax in Sigma custom SQL
        const controlType = TAG_CONTROL_TYPE[ttype] || 'text';
        ensureControl(tagName, display, controlType, tag?.default);
        warnings.push(`card "${card.name}": native {{${tagName}}} (${ttype}) — a Sigma ${controlType} control "${display}" (controlId "${tagName}") was emitted; the {{${tagName}}} reference is kept verbatim (Sigma custom SQL uses the same {{control-id}} parameter syntax). Verify the control's default${tag?.required ? ' (tag is REQUIRED — set a default or the element errors until set)' : ''}.`);
      }
    }
    // 3. Warehouse-specific SQL transforms (array agg → string agg, etc.)
    if (options.warehouse && options.warehouse !== 'unknown') {
      sql = applyWarehouseTransforms(sql, options.warehouse);
    }
    // 4. Strip trailing semicolon(s): Sigma wraps a custom-SQL element's statement
    // as a subquery `( … )`, so a trailing `;` is a syntax error at POST
    // (live-verified on BigQuery: `Expected ")" but got ";"`). Metabase tolerates it.
    sql = sql.replace(/;\s*$/, '').trimEnd();
    return sql;
  };

  const processCard = (card: any): void => {
    if (!card) return;
    if (card.id != null && cardElemId.has(card.id)) return;
    if (card.id != null && inFlight.has(card.id)) { warnings.push(`card ${card.id} participates in a circular card__ reference chain — skipped.`); return; }
    if (card.id != null) inFlight.add(card.id);
    const done = () => { if (card.id != null) inFlight.delete(card.id); };
    let dq = card.dataset_query || {};
    // Simple native SQL → native Sigma data model (so filters are reproducible
    // natively — see recognizeSimpleNativeSql). Complex SQL stays custom SQL below.
    if (dq.type === 'native') {
      const remodeled = recognizeSimpleNativeSql(card, fidx || undefined);
      if (remodeled) {
        dq = { type: 'query', database: dq.database, query: remodeled.query };
        warnings.push(`card "${card.name}": simple native SQL auto-remodeled to a NATIVE Sigma data model (table/join source + aggregation) — its columns are exposed so dashboard filters reproduce as native Sigma controls/element-filters (no custom SQL).`);
      }
    }
    const ctxM = mkMbqlCtx(card);

    // ── native SQL card → sql-source element (statement near-verbatim, NO element name) ──
    // SQL dialect passes through to Sigma custom SQL untouched — same-warehouse
    // migrations (e.g. BigQuery→BigQuery) are near-verbatim.
    if (dq.type === 'native') {
      const statement = processNativeSql(card, dq.native?.query || '', dq.native?.['template-tags'] || {});
      const element: SigmaElement = {
        // No `name` field: Sigma derives the sql element's own identifier.
        id: sigmaShortId(), kind: 'table',
        source: { kind: 'sql', connectionId, statement },
        columns: [], order: [],
      };
      const ctx = newCtx(element, true);
      for (const rm of card.result_metadata || []) {
        // Prettify ALWAYS (sigmaDisplayName is idempotent): native-card display_name
        // is the raw alias (x_axis_type), which otherwise becomes the chart label.
        const disp = sigmaDisplayName(rm.display_name || rm.name);
        const id = sigmaShortId();
        // sql-element column refs MUST be [Custom SQL/ALIAS] (raw SQL output alias).
        // Bare [Display Name] refs POST 200 but resolve to type "error" at query
        // time (live-verified — the readback gate exists for exactly this).
        ctx.columns.push({ id, name: disp, formula: `[Custom SQL/${rm.name || disp}]` });
        ctx.order.push(id);
        ctx.colIdByName.set(disp.toLowerCase(), id);
      }
      if (card.id != null) cardElemId.set(card.id, element.id);
      sqlElements++;
      done();
      return;
    }

    // ── MBQL card ────────────────────────────────────────────────────────────────
    const q = dq.query || {};
    if (q['source-query']) {
      // multi-stage query (pMBQL stages>1 / legacy nested source-query) — rare
      // (14 of 7,023 on the reference estate) and structurally a sub-query;
      // flagged, never silently mistranslated.
      warnings.push(`card "${card.name}" is a MULTI-STAGE query (nested source-query) — not auto-converted; rebuild as a chain of Sigma elements (inner stage → element, outer stage → child element) or a custom-SQL element. Card skipped.`);
      done(); return;
    }
    const src = q['source-table'];
    let target: ElemCtx | null = null;

    if (typeof src === 'string' && src.startsWith('card__')) {
      // Nested question — sourced from card N's element when card N is in the input set.
      const n = Number(src.slice('card__'.length));
      const parent = cardById.get(n);
      if (!parent) { warnings.push(`card "${card.name}" is a nested question on card ${n}, which is NOT in the input set — fetch GET /api/card/${n}, add it, and re-run; card skipped.`); done(); return; }
      processCard(parent);
      const parentElemId = cardElemId.get(n);
      if (!parentElemId) { warnings.push(`card "${card.name}": its source card ${n} did not produce an element — skipped.`); done(); return; }
      const element: SigmaElement = {
        id: sigmaShortId(), kind: 'table', name: card.name || `Card ${card.id}`,
        source: { kind: 'table', elementId: parentElemId },
        columns: [], order: [],
      };
      target = newCtx(element, true);
      // Passthrough the parent's columns — a table-sourced element starts EMPTY
      // (zero queryable columns live-verified), so anything consuming this element
      // (the workbook chart for this very card) has nothing to reference without them.
      const parentCtx = elemCtxs.find((c) => c.element.id === parentElemId);
      const parentName = parentCtx?.element.name || 'Parent';
      for (const pc of parentCtx?.columns || []) {
        const tail = pc.name || /\/([^\]/]+)\]$/.exec(String(pc.formula || ''))?.[1];
        if (!tail || target.colIdByName.has(tail.toLowerCase())) continue;
        const id = sigmaShortId();
        target.columns.push({ id, name: tail, formula: `[${parentName}/${tail}]` });
        target.order.push(id);
        target.colIdByName.set(tail.toLowerCase(), id);
      }
    } else if (Array.isArray(q.joins) && q.joins.length) {
      target = buildJoinElement(card, q, ctxM);
    } else if (typeof src === 'number') {
      target = ensureTableElement(src);
      if (!target) warnings.push(`card "${card.name}" skipped — its source table ${src} is unknown.`);
    } else if (src !== undefined) {
      warnings.push(`card "${card.name}": unrecognized source-table ${JSON.stringify(src)} — skipped.`);
    }
    if (!target) { done(); return; }
    if (card.id != null) cardElemId.set(card.id, target.element.id);

    // expressions → calculated columns
    for (const [name, expr] of Object.entries(q.expressions || {})) {
      addCalc(target, String(name), translateMbqlExpr(expr, ctxM));
    }
    // breakout temporal-unit → DateTrunc calc column (plain breakouts are already raw columns)
    for (const b of q.breakout || []) {
      const unit = Array.isArray(b) && b[2]?.['temporal-unit'];
      if (unit) addCalc(target, `${ctxM.fieldDisplay(b)} (${titleCase(String(unit))})`, ctxM.resolveField(b));
      else if (Array.isArray(b) && b[2]?.binning) ctxM.resolveField(b); // emits the binning warning
      // implicit FK breakout ([field, dim, {source-field}]) — resolveField ensures the
      // dim TABLE element exists, so the FK relationship + derived-view column survive
      else if (Array.isArray(b) && b[2]?.['source-field']) ctxM.resolveField(b);
    }
    // aggregations → element metrics
    for (const a of q.aggregation || []) {
      const { formula, name } = translateAggregation(a, ctxM);
      addMetric(target, name, formula);
    }
    // card filter: safe on a card-owned element; NEVER on a shared table element
    // (an element filter on a shared-source element propagates into every consumer).
    if (q.filter) {
      const formula = translateMbqlExpr(q.filter, ctxM);
      if (target.ownedByCard) {
        const id = sigmaShortId();
        target.columns.push({ id, name: `Filter: ${card.name || card.id}`, formula, hidden: true });
        ((target.element as any).filters ||= []).push({ id: sigmaShortId(), columnId: id, kind: 'list', mode: 'include', values: [true] });
      } else {
        warnings.push(`card "${card.name}": its MBQL filter translates to ${formula} — NOT applied to the shared "${target.element.name}" element (a filter there would propagate to every consumer); apply it on the consuming workbook element.`);
      }
    }
    if (q.limit != null && !target.ownedByCard) {
      warnings.push(`card "${card.name}": row limit ${q.limit} not ported — never cap a shared DM element; apply a top-N on the consuming workbook element if needed.`);
    }
    done();
  };

  for (const card of cards) processCard(card);

  // ── FK metadata → relationships on the fact-side element (both tables present) ──
  let relationshipCount = 0;
  for (const [tableId, ctx] of tableCtxByTableId) {
    const t = fidx?.tableById.get(tableId);
    if (!t) continue;
    for (const f of t.fields) {
      if (!f.fkTargetFieldId) continue;
      const tgtField = fidx!.byId.get(f.fkTargetFieldId);
      if (!tgtField) continue;
      const tgtCtx = tableCtxByTableId.get(tgtField.tableId);
      if (!tgtCtx) continue;  // both tables must be present in the model
      const sourceColumnId = ctx.colIdByFieldId.get(f.id);
      const targetColumnId = tgtCtx.colIdByFieldId.get(tgtField.id);
      if (!sourceColumnId || !targetColumnId) continue;
      (ctx.element.relationships ||= []).push({
        id: sigmaShortId(),
        name: tgtField.tableName,   // relationship name = target table tail, case-preserved
        targetElementId: tgtCtx.element.id,
        keys: [{ sourceColumnId, targetColumnId }],
      });
      relationshipCount++;
    }
  }

  // ── finalize ──────────────────────────────────────────────────────────────────
  const elements: SigmaElement[] = [];
  for (const ctx of elemCtxs) {
    if (ctx.metrics.length) (ctx.element as any).metrics = ctx.metrics;
    elements.push(ctx.element);
  }
  for (const de of buildDerivedElements(elements)) elements.push(de);
  // template-tag controls last (so {{tag}} refs in sql elements have a target)
  for (const ctrl of controlElements) elements.push(ctrl);

  // ── Metabase sandboxing (EE row security) — DETECT-ONLY, never injected ───────
  const security = (inp.sandboxes || []).map((s: any) => {
    const tname = fidx?.tableById.get(s.table_id)?.name || `table ${s.table_id}`;
    const parts = Object.entries(s.attribute_remappings || {}).map(([attr, tgt]: [string, any]) => {
      const tgtRef = Array.isArray(tgt) && tgt[0] === 'dimension' ? tgt[1] : tgt;
      const col = Array.isArray(tgtRef) && tgtRef[0] === 'field'
        ? (fidx?.byId.get(tgtRef[1])?.displayName || `field ${tgtRef[1]}`)
        : JSON.stringify(tgt);
      return `[${col}] = user attribute "${attr}"`;
    });
    return {
      type: 'row-filter',
      name: s.name || `Sandbox: ${tname}`,
      expression: parts.length ? parts.join(' AND ') : (s.card_id != null ? `rows restricted to saved question ${s.card_id}` : '(no attribute remappings found)'),
      groups: [s.group_id].filter((g: any) => g != null),
    };
  });
  if (security.length) {
    warnings.push(`SECURITY: ${security.length} Metabase sandbox(es) detected — NOT ported into the model spec. ` +
      `Run the skill's RLS flow (scripts/apply_sigma_rls.py) after posting the model; skipping leaves ALL rows visible to everyone.`);
  }

  const stats = {
    cards: cards.length,
    elements: elements.length,
    sqlElements,
    controls: controlElements.length,
    columns: elements.reduce((n, e) => n + (e.columns?.length || 0), 0),
    metrics: elements.reduce((n, e) => n + ((e as any).metrics?.length || 0), 0),
    relationships: relationshipCount,
  };
  return {
    model: {
      name: options.modelName || inp.metadata?.name || 'Metabase Data Model',
      schemaVersion: 1,
      pages: [{ id: sigmaShortId(), name: 'Page 1', elements }],
    },
    warnings, stats,
    ...(security.length ? { security } : {}),
  };
}
