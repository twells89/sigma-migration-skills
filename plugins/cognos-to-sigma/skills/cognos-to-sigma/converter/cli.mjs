#!/usr/bin/env node

// cli.ts
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// sigma-ids.ts
var SIGMA_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
var _usedIds = /* @__PURE__ */ new Set();
var SIGMA_LOWERCASE_WORDS = /* @__PURE__ */ new Set([
  "a",
  "an",
  "the",
  "and",
  "but",
  "or",
  "for",
  "nor",
  "so",
  "yet",
  "at",
  "by",
  "in",
  "of",
  "on",
  "to",
  "up",
  "as",
  "into",
  "via",
  "per"
]);
function resetIds() {
  _usedIds.clear();
}
function sigmaShortId(len = 10) {
  let id;
  do {
    id = Array.from(
      { length: len },
      () => SIGMA_CHARS[Math.floor(Math.random() * SIGMA_CHARS.length)]
    ).join("");
  } while (_usedIds.has(id));
  _usedIds.add(id);
  return id;
}
function sigmaDisplayName(s) {
  const normalized = (s || "").replace(/([a-z])([A-Z])/g, "$1_$2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2").replace(/([A-Za-z])([0-9])/g, "$1_$2").replace(/([0-9])([A-Za-z])/g, "$1_$2");
  const words = normalized.toLowerCase().split(/[_\s]+/).filter(Boolean);
  return words.map(
    (w, i) => i === 0 || !SIGMA_LOWERCASE_WORDS.has(w) ? w.charAt(0).toUpperCase() + w.slice(1) : w
  ).join(" ");
}
function formatFromMask(mask) {
  if (!mask || typeof mask !== "string") return null;
  const s = mask.trim();
  if (!s || /general|date|time|@|yy|dd/i.test(s)) return null;
  const decM = s.match(/\.([0#]+)/);
  const decimals = decM ? decM[1].length : 0;
  const isPercent = /%/.test(s);
  const isCurrency = /[$£€¥]/.test(s);
  if (isPercent) return { kind: "number", formatString: `,.${decimals}%` };
  if (isCurrency) return { kind: "number", formatString: `$,.${decimals}f`, currencySymbol: "$" };
  if (/[0#]/.test(s)) return { kind: "number", formatString: `,.${decimals}f` };
  return null;
}
function inferSigmaFormat(formula, displayName, sourceMask) {
  const fromMask = formatFromMask(sourceMask);
  if (fromMask) return fromMask;
  if (!formula) return null;
  const f = formula.trim();
  const n = (displayName || "").toLowerCase();
  const alreadyPctScale = /\*\s*100\b/.test(f);
  if (alreadyPctScale && /\b(rate|margin|pct|percent|ratio|share|mix)\b|%/.test(n)) {
    return { kind: "number", formatString: ",.2f", suffix: "%" };
  }
  const currencyWord = /\b(revenue|sales|profit|cost|spend|amount|discounts?|price|value|aov|arpu)\b/;
  const ratio = f.match(/^([A-Za-z]+)\s*\(([^)]*)\)\s*\/\s*([A-Za-z]+)\s*\(([^)]*)\)$/);
  if (ratio) {
    const [, numFn, numArg, denFn, denArg] = ratio;
    const isCount = (fn) => /^Count/i.test(fn);
    const numIsCurrency = currencyWord.test(numArg.toLowerCase());
    const nameSaysPct = /\b(rate|margin|pct|percent|ratio|share|mix)\b|%/.test(n);
    if (nameSaysPct || isCount(numFn) && isCount(denFn)) {
      return { kind: "number", formatString: ",.2%" };
    }
    if (numIsCurrency) {
      return { kind: "number", formatString: "$,.2f", currencySymbol: "$" };
    }
    return { kind: "number", formatString: ",.2f" };
  }
  if (/\b(rate|margin|pct|percent|ratio|share|mix)\b|%/.test(n)) {
    return { kind: "number", formatString: ",.2%" };
  }
  if (currencyWord.test(n)) {
    return { kind: "number", formatString: "$,.2f", currencySymbol: "$" };
  }
  if (/^Count(?:Distinct|If|DistinctIf)?\s*\(/.test(f)) {
    return { kind: "number", formatString: ",.0f" };
  }
  return null;
}
var DATA_MODEL_SCHEMA_SUMMARY = `
Sigma Data Model JSON top-level structure:
{
  "name": "Model Name",
  "pages": [{ "id": "pageId", "name": "Page 1", "elements": [...] }]
}

Element types: warehouse-table, custom-sql (kind:"sql"), join, union, control.
Columns: { "id": "inode-xxx/COL", "formula": "[TABLE/Display Name]" }
Calculated columns: { "id": "shortId", "formula": "[Price] - [Cost]", "name": "Profit" }
Metrics: { "id": "shortId", "formula": "Sum([Revenue])", "name": "Total Revenue" }
Relationships: { "id": "shortId", "targetElementId": "...", "keys": [{ "sourceColumnId": "...", "targetColumnId": "..." }] }

Cross-element Reference (accessing related dimension columns via relationships):
  [SOURCE_TABLE/REL_NAME/Column Display Name]
  REL_NAME is the relationship's "name" field (= target table name uppercase by convention).
  Example: DateDiff("day", [ORDER_FACT/PROMO_DIM/Start Date], [ORDER_FACT/PROMO_DIM/End Date])
  \u26A0 The dash-link form [SRC/FK_COL - link/Field] does NOT work via the API \u2014 use REL_NAME.

Conditional Aggregate Syntax:
  CountIf(condition) \u2014 condition only, NO field argument
  SumIf(field, condition) \u2014 FIELD FIRST, condition second
  AvgIf/MaxIf/MinIf/CountDistinctIf \u2014 all FIELD FIRST
  For booleans: always use [Column] = True, never bare [Column]

Groupings (for LOD / different aggregation levels):
  "groupings": [{ "id": "gId", "groupBy": ["colId1"], "calculations": ["calcId1"] }]
  Array order = nesting hierarchy. Use child elements for LOD patterns.
`.trim();
function buildDerivedElements(elements) {
  const derived = [];
  for (const srcEl of elements) {
    if (!srcEl.relationships?.length) continue;
    if (srcEl.source?.kind !== "warehouse-table") continue;
    const srcPath = srcEl.source.path || [];
    const srcTableName = srcPath[srcPath.length - 1] || "";
    const baseName = srcEl.name || srcTableName;
    const derivedName = `${srcEl.name || sigmaDisplayName(srcTableName)} View`;
    const viewCols = [];
    const viewOrder = [];
    for (const col of srcEl.columns || []) {
      if (!col.formula || col.formula.startsWith("/*")) continue;
      const fm = col.formula.match(/^\[([^\/\]]+)\/([^\]]+)\]$/);
      if (!fm) continue;
      const dispName = fm[2];
      if (dispName.includes("/")) continue;
      const cId = sigmaShortId();
      viewCols.push({ id: cId, formula: `[${baseName}/${dispName}]` });
      viewOrder.push(cId);
    }
    for (const rel of srcEl.relationships) {
      if (!rel.name) continue;
      const tgtEl = elements.find((e) => e.id === rel.targetElementId);
      if (!tgtEl || tgtEl.source?.kind !== "warehouse-table") continue;
      for (const col of tgtEl.columns || []) {
        if (!col.formula || col.formula.startsWith("/*")) continue;
        const fm = col.formula.match(/^\[([^\]]+)\]$/);
        if (!fm) continue;
        const inner = fm[1];
        const s = inner.indexOf("/");
        const dispName = s >= 0 ? inner.slice(s + 1) : inner;
        if (dispName.includes("/")) continue;
        const cId = sigmaShortId();
        viewCols.push({ id: cId, formula: `[${baseName}/${rel.name}/${dispName}]` });
        viewOrder.push(cId);
      }
    }
    if (viewCols.length > 0) {
      derived.push({
        id: sigmaShortId(),
        kind: "table",
        name: derivedName,
        source: { kind: "table", elementId: srcEl.id },
        columns: viewCols,
        order: viewOrder
      });
    }
  }
  return derived;
}

// cognos.ts
function applyLearnedRules(expr, rules) {
  let s = expr || "";
  for (const r of rules || []) {
    try {
      s = s.replace(new RegExp(r.pattern, r.flags || "gi"), r.template);
    } catch {
    }
  }
  return s;
}
var arr = (x) => Array.isArray(x) ? x : x == null ? [] : [x];
var lc = (s) => String(s ?? "").toLowerCase();
function normalizeCognosDataModule(input) {
  const root = typeof input === "string" ? JSON.parse(input) : input;
  const name = root.label || root.identifier || root.name || "Cognos Data Module";
  const querySubjects = [];
  const qsList = arr(root.querySubject || root.querySubjects || root.module?.querySubject);
  for (const qs of qsList) {
    const identifier = qs.identifier || qs.idForExpression || qs.label || "QUERY_SUBJECT";
    let table = identifier, database, schema;
    const ref0 = arr(qs.ref)[0];
    if (typeof ref0 === "string" && ref0.includes(".")) {
      table = ref0.split(".").slice(1).join(".");
    } else {
      const tableRef = arr(qs.definition?.dbQuery?.tableRef)[0] || qs.sourceTable || qs.table;
      const src = tableRef?.sourceTable || tableRef || {};
      table = src.name || (typeof tableRef === "string" ? tableRef : identifier);
      database = src.catalog || src.database || qs.catalog;
      schema = src.schema || qs.schema;
    }
    const items = [];
    for (const raw of arr(qs.item || qs.items)) {
      const qi = raw.queryItem || raw.calculation || raw.measure;
      if (!qi || !(qi.identifier || qi.label)) continue;
      const ident = qi.identifier || qi.label;
      const expr = qi.expression;
      const isCalc = !!raw.calculation || expr != null && !isPlainColumn(expr, identifier);
      items.push({
        identifier: ident,
        label: qi.label,
        expression: expr,
        datatype: qi.datatype || qi.highlevelDatatype,
        usage: lc(qi.usage),
        aggregate: lc(qi.regularAggregate || qi.aggregate || qi.aggregateFunction),
        isCalculation: isCalc
      });
    }
    querySubjects.push({ identifier, label: qs.label, database, schema, table, items });
  }
  const relationships = [];
  for (const rel of arr(root.relationship || root.relationships)) {
    const links = arr(rel.link);
    const left = qsKey(rel.left?.ref || links[0]?.ref || rel.left);
    const right = qsKey(rel.right?.ref || links[1]?.ref || rel.right);
    if (!left || !right) continue;
    const colLink = links.find((l) => l && (l.leftRef || l.rightRef));
    relationships.push({
      left,
      right,
      leftKey: colLink?.leftRef,
      rightKey: colLink?.rightRef,
      leftCard: lc(rel.left?.maxcard),
      rightCard: lc(rel.right?.maxcard),
      expression: rel.expression || rel.linkExpression,
      cardinality: rel.cardinality
    });
  }
  const securityFilters = [];
  const pushSec = (sf, subject) => {
    if (!sf || typeof sf !== "object") return;
    const groups = arr(sf.securityObject || sf.member || sf.members || sf.appliesTo).map((g) => typeof g === "string" ? g : g?.searchPath || g?.ref || g?.identifier).filter(Boolean);
    securityFilters.push({
      type: "data-module-security-filter",
      subject,
      name: sf.label || sf.identifier,
      expression: sf.expression || sf.filterDefinition || sf.embeddedFilter?.expression,
      ...groups.length ? { groups } : {}
    });
  };
  for (const sf of arr(root.securityFilter || root.securityFilters)) pushSec(sf);
  for (const qs of qsList) {
    for (const sf of arr(qs.securityFilter || qs.securityFilters)) pushSec(sf, qs.identifier || qs.label);
  }
  for (const fl of arr(root.filter || root.filters)) {
    if (fl && (lc(fl.classifier).includes("security") || arr(fl.propertyOverride).some((p) => lc(p).includes("security")))) pushSec(fl);
  }
  return { name, querySubjects, relationships, securityFilters };
}
function qsKey(ref) {
  const parts = String(ref).replace(/[[\]]/g, "").split(".");
  return parts[parts.length - 1].trim();
}
function isPlainColumn(expr, subjectId) {
  const e = (expr || "").trim();
  if (/^[A-Za-z_][\w ]*$/.test(e)) return true;
  const m = e.replace(/[[\]\s]/g, "").match(/^([\w]+)\.([\w]+)$/);
  return !!m && m[1].toUpperCase() === subjectId.toUpperCase();
}
function convertCognosIR(model, options = {}) {
  resetIds();
  const { connectionId = "<CONNECTION_ID>", database: dbOverride = "", schema: schOverride = "", modelName } = options;
  const warnings = [];
  const ctxByKey = /* @__PURE__ */ new Map();
  for (const qs of model.querySubjects) {
    const key = qs.identifier.toUpperCase();
    const path = [];
    const db = dbOverride || qs.database || "";
    const sch = schOverride || qs.schema || "";
    if (db) path.push(db);
    if (sch) path.push(sch);
    const tableTail = (qs.table || qs.identifier).toUpperCase();
    path.push(tableTail);
    const element = {
      id: sigmaShortId(),
      kind: "table",
      name: sigmaDisplayName(qs.identifier),
      source: { connectionId, kind: "warehouse-table", path },
      columns: [],
      order: []
    };
    ctxByKey.set(key, { element, columns: [], metrics: [], order: [], colIdByName: /* @__PURE__ */ new Map(), tableTail });
  }
  const ensureRawCol = (ctx, _tableKey, ident, hidden = false) => {
    const disp = sigmaDisplayName(ident);
    const existing = ctx.colIdByName.get(disp);
    if (existing) return existing;
    const id = sigmaShortId();
    const col = { id, formula: `[${ctx.tableTail}/${disp}]` };
    if (hidden) col.hidden = true;
    ctx.columns.push(col);
    ctx.order.push(id);
    ctx.colIdByName.set(disp, id);
    return id;
  };
  for (const qs of model.querySubjects) {
    const key = qs.identifier.toUpperCase();
    const ctx = ctxByKey.get(key);
    for (const item of qs.items) {
      const dispName = sigmaDisplayName(item.label || item.identifier);
      const isMeasure = !item.isCalculation && (item.usage === "fact" || item.usage === "measure") && item.aggregate && item.aggregate !== "none";
      if (item.isCalculation && item.expression) {
        const { formula, warnings: w } = translateCognosExpr(applyLearnedRules(item.expression, options.learnedRules), qs, ensureRawCol, ctx);
        w.forEach((x) => warnings.push(`"${qs.identifier}.${item.identifier}": ${x}`));
        if (/\b(Sum|Avg|Count|Min|Max|.*Over)\(/.test(formula)) {
          const m = { id: sigmaShortId(), name: dispName, formula };
          const fmt = inferSigmaFormat(formula, dispName);
          if (fmt) m.format = fmt;
          ctx.metrics.push(m);
        } else {
          const id = sigmaShortId();
          ctx.columns.push({ id, name: dispName, formula });
          ctx.order.push(id);
        }
      } else if (isMeasure) {
        ensureRawCol(ctx, key, item.identifier);
        const agg = aggFn(item.aggregate, `[${sigmaDisplayName(item.identifier)}]`);
        const m = { id: sigmaShortId(), name: dispName, formula: agg };
        const fmt = inferSigmaFormat(agg, dispName);
        if (fmt) m.format = fmt;
        ctx.metrics.push(m);
      } else {
        const physDisp = sigmaDisplayName(item.identifier);
        const existing = ctx.colIdByName.get(physDisp);
        if (existing) {
          if (dispName !== physDisp) {
          }
          continue;
        }
        const id = sigmaShortId();
        const col = { id, formula: `[${ctx.tableTail}/${physDisp}]` };
        if (dispName !== physDisp) col.name = dispName;
        ctx.columns.push(col);
        ctx.order.push(id);
        ctx.colIdByName.set(physDisp, id);
      }
    }
  }
  for (const rel of model.relationships) {
    let leftTable = rel.left, rightTable = rel.right, leftCol = rel.leftKey, rightCol = rel.rightKey;
    if (!leftCol || !rightCol) {
      const parsed = parseJoinExpr(rel.expression);
      if (!parsed) {
        warnings.push(`Relationship ${rel.left}\u2192${rel.right}: no join columns and expression "${trunc(rel.expression)}" not a simple equi-join \u2014 add manually in Sigma.`);
        continue;
      }
      ({ leftTable, leftCol, rightTable, rightCol } = parsed);
    }
    const rightIsMany = /many|\bn\b|\*/.test(rel.rightCard || "");
    const leftIsMany = /many|\bn\b|\*/.test(rel.leftCard || "");
    if (rightIsMany && !leftIsMany) {
      [leftTable, leftCol, rightTable, rightCol] = [rightTable, rightCol, leftTable, leftCol];
    }
    const srcKey = leftTable.toUpperCase(), tgtKey = rightTable.toUpperCase();
    const srcCtx = ctxByKey.get(srcKey), tgtCtx = ctxByKey.get(tgtKey);
    if (!srcCtx || !tgtCtx) {
      warnings.push(`Relationship ${srcKey}\u2192${tgtKey}: a query subject is missing \u2014 relationship skipped.`);
      continue;
    }
    const srcColId = ensureRawCol(srcCtx, srcKey, leftCol, true);
    const tgtColId = ensureRawCol(tgtCtx, tgtKey, rightCol, true);
    (srcCtx.element.relationships ||= []).push({
      id: sigmaShortId(),
      targetElementId: tgtCtx.element.id,
      keys: [{ sourceColumnId: srcColId, targetColumnId: tgtColId }],
      name: tgtKey
    });
  }
  const elements = [];
  for (const ctx of ctxByKey.values()) {
    ctx.element.columns = ctx.columns;
    ctx.element.order = ctx.order;
    if (ctx.metrics.length) ctx.element.metrics = ctx.metrics;
    elements.push(ctx.element);
  }
  for (const de of buildDerivedElements(elements)) elements.push(de);
  const stats = {
    querySubjects: model.querySubjects.length,
    elements: elements.length,
    columns: elements.reduce((n, e) => n + (e.columns?.length || 0), 0),
    metrics: elements.reduce((n, e) => n + (e.metrics?.length || 0), 0),
    relationships: elements.reduce((n, e) => n + (e.relationships?.length || 0), 0)
  };
  const security2 = (model.securityFilters || []).map((sf) => ({ ...sf }));
  if (security2.length) {
    warnings.push(`SECURITY: ${security2.length} data-module security filter(s) detected \u2014 NOT ported into the model spec. Run the skill's RLS flow (scripts/apply_sigma_rls.py) after posting the model; skipping leaves ALL rows visible to everyone.`);
  }
  return {
    model: { name: modelName || model.name, schemaVersion: 1, pages: [{ id: sigmaShortId(), name: "Page 1", elements }] },
    warnings,
    stats,
    ...security2.length ? { security: security2 } : {}
  };
}
function convertCognosToSigma(input, options = {}) {
  return convertCognosIR(normalizeCognosDataModule(input), options);
}
var AGG_MAP = {
  total: "Sum",
  sum: "Sum",
  average: "Avg",
  avg: "Avg",
  count: "Count",
  "count distinct": "CountDistinct",
  maximum: "Max",
  max: "Max",
  minimum: "Min",
  min: "Min"
};
var OVER_MAP = { total: "SumOver", sum: "SumOver", average: "AvgOver", count: "CountOver", maximum: "MaxOver", minimum: "MinOver" };
function aggFn(agg, inner) {
  const fn = AGG_MAP[agg] || "Sum";
  return `${fn}(${inner})`;
}
function translateCognosExpr(expr, qs, ensureRawCol, ctx) {
  const warnings = [];
  let f = (expr || "").trim();
  for (const bad of ["running-total", "running-count", "running-average", "running-difference", "moving-total", "moving-average", "rank", "percentile", "quantile", "tertile"]) {
    if (new RegExp(`\\b${bad}\\b`, "i").test(f)) warnings.push(`uses Cognos "${bad}" (window/running calc) \u2014 no clean single-column Sigma analog; needs manual authoring (window function).`);
  }
  f = f.replace(/\[[^\]]+\](?:\.\[[^\]]+\])*/g, (ref) => {
    const segs = ref.split(".").map((s) => s.replace(/[[\]]/g, "").trim());
    const item = segs[segs.length - 1];
    return `[${sigmaDisplayName(item)}]`;
  });
  f = translateCaseExpr(f);
  const identMap = /* @__PURE__ */ new Map();
  for (const it of qs.items || []) identMap.set(it.identifier.toLowerCase(), sigmaDisplayName(it.label || it.identifier));
  if (identMap.size) {
    const pfx = ctx && ctx.tableTail ? `${ctx.tableTail}/` : "";
    f = f.replace(/\[[^\]]*\]|[^[\]]+/g, (seg) => seg.startsWith("[") ? seg : seg.replace(/\b([A-Za-z_][A-Za-z0-9_]*)\b(?!\s*\()/g, (w) => {
      const d = identMap.get(w.toLowerCase());
      return d ? `[${pfx}${d}]` : w;
    }));
  }
  if (/\bcase\b[\s\S]*\bwhen\b/i.test(f)) warnings.push("a CASE expression could not be fully translated (nested or non-standard) \u2014 review/author manually.");
  f = f.replace(
    /\b(total|sum|average|count|maximum|minimum)\s*\(\s*([^()]*?)\s+for\s+([^()]*)\)/gi,
    (_m, fn, inner, scope) => {
      const over = OVER_MAP[lc(fn)] || "SumOver";
      const dims = scope.split(",").map((s) => s.trim()).join(", ");
      return `${over}(${inner.trim()}, ${dims})`;
    }
  );
  f = f.replace(/\b(total|sum|average|count|maximum|minimum)\s*\(/gi, (_m, fn) => `${AGG_MAP[lc(fn)] || "Sum"}(`);
  let guard = 0;
  while (/\bif\s*\(/i.test(f) && guard++ < 25) {
    f = f.replace(
      /\bif\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)\s*then\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)\s*else\s*/i,
      (_m, cond, thenv) => `If(${cond.trim()}, ${thenv.trim()}, `
    );
    if (!/\bif\s*\(/i.test(f)) break;
  }
  const opens = (f.match(/If\(/g) || []).length;
  const closes = (f.match(/\)/g) || []).length - (f.match(/\(/g) || []).length + opens;
  if (opens > 0 && closes < opens) f = f + ")".repeat(opens - Math.max(0, closes));
  f = f.replace(/_add_days\s*\(([^,]+),\s*([^)]+)\)/gi, (_m, d, n) => `DateAdd("day", ${n.trim()}, ${d.trim()})`);
  f = f.replace(/_add_months\s*\(([^,]+),\s*([^)]+)\)/gi, (_m, d, n) => `DateAdd("month", ${n.trim()}, ${d.trim()})`);
  f = f.replace(/_add_years\s*\(([^,]+),\s*([^)]+)\)/gi, (_m, d, n) => `DateAdd("year", ${n.trim()}, ${d.trim()})`);
  f = f.replace(/_days_between\s*\(([^,]+),\s*([^)]+)\)/gi, (_m, a, b) => `DateDiff("day", ${b.trim()}, ${a.trim()})`);
  f = f.replace(/\bextract\s*\(\s*(year|month|day)\s*,\s*([^)]+)\)/gi, (_m, part, d) => `DatePart("${lc(part)}", ${d.trim()})`);
  f = f.replace(/\bsubstring\s*\(/gi, "Mid(").replace(/\bsubstr\s*\(/gi, "Mid(").replace(/\bupper\s*\(/gi, "Upper(").replace(/\blower\s*\(/gi, "Lower(").replace(/\btrim\s*\(/gi, "Trim(");
  f = f.replace(
    /\bsubstitute\s*\(\s*([^,]+?)\s*,\s*([^,]+?)\s*,\s*([^)]+?)\s*\)/gi,
    (_m, p, r, s) => `RegexpReplace(${s.trim()}, ${p.trim()}, ${r.trim()})`
  );
  const castRepl = (_m, x, ty) => /char|text|string|varchar/i.test(ty) ? `Text(${x.trim()})` : x.trim();
  f = f.replace(/\bcast\s*\(\s*([^,()]+?)\s+as\s+(\w+)[^)]*\)/gi, castRepl);
  f = f.replace(/\bcast\s*\(\s*([^,()]+?)\s*,\s*(\w+)[^)]*\)/gi, castRepl);
  f = f.replace(/\b(?:n?varchar|char)\s*\(\s*([^,)]+?)(?:\s*,\s*\d+)?\s*\)/gi, (_m, x) => `Text(${x.trim()})`);
  f = f.replace(/\b(?:decimal|double|float|number)\s*\(\s*([^,)]+?)(?:\s*,[^)]*)?\)/gi, (_m, x) => x.trim());
  f = f.replace(/\|\|/g, "&");
  f = f.replace(/\bcoalesce\s*\(/gi, "Coalesce(");
  f = f.replace(/\babs\s*\(/gi, "Abs(").replace(/\bround\s*\(/gi, "Round(").replace(/\bfloor\s*\(/gi, "Floor(").replace(/\bceiling\s*\(/gi, "Ceiling(").replace(/\bsqrt\s*\(/gi, "Sqrt(").replace(/\bln\s*\(/gi, "Ln(").replace(/\bmod\s*\(/gi, "Mod(").replace(/\bpower\s*\(/gi, "Power(");
  f = f.replace(/'([^']*)'/g, '"$1"');
  const known = /\b(If|Switch|Sum|Avg|Count|CountDistinct|Min|Max|SumOver|AvgOver|CountOver|MinOver|MaxOver|DateAdd|DateDiff|DatePart|Mid|Upper|Lower|Trim|Coalesce|Text|RegexpReplace|Replace|Abs|Round|Floor|Ceiling|Sqrt|Ln|Mod|Power)\b/;
  for (const m of f.matchAll(/\b([a-z][a-z0-9_-]*)\s*\(/gi)) {
    if (!known.test(m[1]) && !/^(and|or|not|in|like|between|then|else|end|case|when)$/i.test(m[1])) {
      warnings.push(`function "${m[1]}()" has no confirmed Sigma mapping \u2014 review/translate manually.`);
    }
  }
  return { formula: f, warnings };
}
function translateCaseExpr(s) {
  let guard = 0;
  while (/\bcase\b/i.test(s) && guard++ < 25) {
    const m = s.match(/\bcase\b([\s\S]*?)\bend\b/i);
    if (!m || m.index == null) break;
    const repl = convertCaseBody(m[1]);
    if (repl == null) break;
    s = s.slice(0, m.index) + repl + s.slice(m.index + m[0].length);
  }
  return s;
}
function convertCaseBody(body) {
  const em = body.match(/\belse\b([\s\S]*)$/i);
  const elseVal = em ? em[1].trim() : "Null";
  const head = em ? body.slice(0, em.index) : body;
  const fw = head.search(/\bwhen\b/i);
  if (fw < 0) return null;
  const selector = head.slice(0, fw).trim();
  const clauses = head.slice(fw).split(/\bwhen\b/i).map((c) => c.trim()).filter(Boolean);
  const pairs = [];
  for (const cl of clauses) {
    const tm = cl.match(/^([\s\S]*?)\bthen\b([\s\S]*)$/i);
    if (!tm) return null;
    pairs.push([tm[1].trim(), tm[2].trim()]);
  }
  if (!pairs.length) return null;
  if (selector) return `Switch(${[selector, ...pairs.flatMap((p) => [p[0], p[1]]), elseVal].join(", ")})`;
  let out = elseVal;
  for (let i = pairs.length - 1; i >= 0; i--) out = `If(${pairs[i][0]}, ${pairs[i][1]}, ${out})`;
  return out;
}
function parseJoinExpr(expr) {
  if (!expr) return null;
  const e = expr.replace(/[[\]]/g, "");
  const m = e.match(/([\w]+)\.([\w]+)\s*=\s*([\w]+)\.([\w]+)/);
  if (!m) return null;
  if (/\band\b|\bor\b/i.test(e)) return null;
  return { leftTable: m[1].trim(), leftCol: m[2].trim(), rightTable: m[3].trim(), rightCol: m[4].trim() };
}
var trunc = (s, n = 80) => s && s.length > n ? s.slice(0, n) + "\u2026" : s || "";

// node_modules/fast-xml-parser/src/util.js
var nameStartChar = ":A-Za-z_\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD";
var nameChar = nameStartChar + "\\-.\\d\\u00B7\\u0300-\\u036F\\u203F-\\u2040";
var nameRegexp = "[" + nameStartChar + "][" + nameChar + "]*";
var regexName = new RegExp("^" + nameRegexp + "$");
function getAllMatches(string, regex) {
  const matches = [];
  let match = regex.exec(string);
  while (match) {
    const allmatches = [];
    allmatches.startIndex = regex.lastIndex - match[0].length;
    const len = match.length;
    for (let index = 0; index < len; index++) {
      allmatches.push(match[index]);
    }
    matches.push(allmatches);
    match = regex.exec(string);
  }
  return matches;
}
var isName = function(string) {
  const match = regexName.exec(string);
  return !(match === null || typeof match === "undefined");
};
function isExist(v) {
  return typeof v !== "undefined";
}
var DANGEROUS_PROPERTY_NAMES = [
  // '__proto__',
  // 'constructor',
  // 'prototype',
  "hasOwnProperty",
  "toString",
  "valueOf",
  "__defineGetter__",
  "__defineSetter__",
  "__lookupGetter__",
  "__lookupSetter__"
];
var criticalProperties = ["__proto__", "constructor", "prototype"];

// node_modules/fast-xml-parser/src/validator.js
var defaultOptions = {
  allowBooleanAttributes: false,
  //A tag can have attributes without any value
  unpairedTags: []
};
function validate(xmlData, options) {
  options = Object.assign({}, defaultOptions, options);
  const tags = [];
  let tagFound = false;
  let reachedRoot = false;
  if (xmlData[0] === "\uFEFF") {
    xmlData = xmlData.substr(1);
  }
  for (let i = 0; i < xmlData.length; i++) {
    if (xmlData[i] === "<" && xmlData[i + 1] === "?") {
      i += 2;
      i = readPI(xmlData, i);
      if (i.err) return i;
    } else if (xmlData[i] === "<") {
      let tagStartPos = i;
      i++;
      if (xmlData[i] === "!") {
        i = readCommentAndCDATA(xmlData, i);
        continue;
      } else {
        let closingTag = false;
        if (xmlData[i] === "/") {
          closingTag = true;
          i++;
        }
        let tagName = "";
        for (; i < xmlData.length && xmlData[i] !== ">" && xmlData[i] !== " " && xmlData[i] !== "	" && xmlData[i] !== "\n" && xmlData[i] !== "\r"; i++) {
          tagName += xmlData[i];
        }
        tagName = tagName.trim();
        if (tagName[tagName.length - 1] === "/") {
          tagName = tagName.substring(0, tagName.length - 1);
          i--;
        }
        if (!validateTagName(tagName)) {
          let msg;
          if (tagName.trim().length === 0) {
            msg = "Invalid space after '<'.";
          } else {
            msg = "Tag '" + tagName + "' is an invalid name.";
          }
          return getErrorObject("InvalidTag", msg, getLineNumberForPosition(xmlData, i));
        }
        const result = readAttributeStr(xmlData, i);
        if (result === false) {
          return getErrorObject("InvalidAttr", "Attributes for '" + tagName + "' have open quote.", getLineNumberForPosition(xmlData, i));
        }
        let attrStr = result.value;
        i = result.index;
        if (attrStr[attrStr.length - 1] === "/") {
          const attrStrStart = i - attrStr.length;
          attrStr = attrStr.substring(0, attrStr.length - 1);
          const isValid = validateAttributeString(attrStr, options);
          if (isValid === true) {
            tagFound = true;
          } else {
            return getErrorObject(isValid.err.code, isValid.err.msg, getLineNumberForPosition(xmlData, attrStrStart + isValid.err.line));
          }
        } else if (closingTag) {
          if (!result.tagClosed) {
            return getErrorObject("InvalidTag", "Closing tag '" + tagName + "' doesn't have proper closing.", getLineNumberForPosition(xmlData, i));
          } else if (attrStr.trim().length > 0) {
            return getErrorObject("InvalidTag", "Closing tag '" + tagName + "' can't have attributes or invalid starting.", getLineNumberForPosition(xmlData, tagStartPos));
          } else if (tags.length === 0) {
            return getErrorObject("InvalidTag", "Closing tag '" + tagName + "' has not been opened.", getLineNumberForPosition(xmlData, tagStartPos));
          } else {
            const otg = tags.pop();
            if (tagName !== otg.tagName) {
              let openPos = getLineNumberForPosition(xmlData, otg.tagStartPos);
              return getErrorObject(
                "InvalidTag",
                "Expected closing tag '" + otg.tagName + "' (opened in line " + openPos.line + ", col " + openPos.col + ") instead of closing tag '" + tagName + "'.",
                getLineNumberForPosition(xmlData, tagStartPos)
              );
            }
            if (tags.length == 0) {
              reachedRoot = true;
            }
          }
        } else {
          const isValid = validateAttributeString(attrStr, options);
          if (isValid !== true) {
            return getErrorObject(isValid.err.code, isValid.err.msg, getLineNumberForPosition(xmlData, i - attrStr.length + isValid.err.line));
          }
          if (reachedRoot === true) {
            return getErrorObject("InvalidXml", "Multiple possible root nodes found.", getLineNumberForPosition(xmlData, i));
          } else if (options.unpairedTags.indexOf(tagName) !== -1) {
          } else {
            tags.push({ tagName, tagStartPos });
          }
          tagFound = true;
        }
        for (i++; i < xmlData.length; i++) {
          if (xmlData[i] === "<") {
            if (xmlData[i + 1] === "!") {
              i++;
              i = readCommentAndCDATA(xmlData, i);
              continue;
            } else if (xmlData[i + 1] === "?") {
              i = readPI(xmlData, ++i);
              if (i.err) return i;
            } else {
              break;
            }
          } else if (xmlData[i] === "&") {
            const afterAmp = validateAmpersand(xmlData, i);
            if (afterAmp == -1)
              return getErrorObject("InvalidChar", "char '&' is not expected.", getLineNumberForPosition(xmlData, i));
            i = afterAmp;
          } else {
            if (reachedRoot === true && !isWhiteSpace(xmlData[i])) {
              return getErrorObject("InvalidXml", "Extra text at the end", getLineNumberForPosition(xmlData, i));
            }
          }
        }
        if (xmlData[i] === "<") {
          i--;
        }
      }
    } else {
      if (isWhiteSpace(xmlData[i])) {
        continue;
      }
      return getErrorObject("InvalidChar", "char '" + xmlData[i] + "' is not expected.", getLineNumberForPosition(xmlData, i));
    }
  }
  if (!tagFound) {
    return getErrorObject("InvalidXml", "Start tag expected.", 1);
  } else if (tags.length == 1) {
    return getErrorObject("InvalidTag", "Unclosed tag '" + tags[0].tagName + "'.", getLineNumberForPosition(xmlData, tags[0].tagStartPos));
  } else if (tags.length > 0) {
    return getErrorObject("InvalidXml", "Invalid '" + JSON.stringify(tags.map((t) => t.tagName), null, 4).replace(/\r?\n/g, "") + "' found.", { line: 1, col: 1 });
  }
  return true;
}
function isWhiteSpace(char) {
  return char === " " || char === "	" || char === "\n" || char === "\r";
}
function readPI(xmlData, i) {
  const start = i;
  for (; i < xmlData.length; i++) {
    if (xmlData[i] == "?" || xmlData[i] == " ") {
      const tagname = xmlData.substr(start, i - start);
      if (i > 5 && tagname === "xml") {
        return getErrorObject("InvalidXml", "XML declaration allowed only at the start of the document.", getLineNumberForPosition(xmlData, i));
      } else if (xmlData[i] == "?" && xmlData[i + 1] == ">") {
        i++;
        break;
      } else {
        continue;
      }
    }
  }
  return i;
}
function readCommentAndCDATA(xmlData, i) {
  if (xmlData.length > i + 5 && xmlData[i + 1] === "-" && xmlData[i + 2] === "-") {
    for (i += 3; i < xmlData.length; i++) {
      if (xmlData[i] === "-" && xmlData[i + 1] === "-" && xmlData[i + 2] === ">") {
        i += 2;
        break;
      }
    }
  } else if (xmlData.length > i + 8 && xmlData[i + 1] === "D" && xmlData[i + 2] === "O" && xmlData[i + 3] === "C" && xmlData[i + 4] === "T" && xmlData[i + 5] === "Y" && xmlData[i + 6] === "P" && xmlData[i + 7] === "E") {
    let angleBracketsCount = 1;
    for (i += 8; i < xmlData.length; i++) {
      if (xmlData[i] === "<") {
        angleBracketsCount++;
      } else if (xmlData[i] === ">") {
        angleBracketsCount--;
        if (angleBracketsCount === 0) {
          break;
        }
      }
    }
  } else if (xmlData.length > i + 9 && xmlData[i + 1] === "[" && xmlData[i + 2] === "C" && xmlData[i + 3] === "D" && xmlData[i + 4] === "A" && xmlData[i + 5] === "T" && xmlData[i + 6] === "A" && xmlData[i + 7] === "[") {
    for (i += 8; i < xmlData.length; i++) {
      if (xmlData[i] === "]" && xmlData[i + 1] === "]" && xmlData[i + 2] === ">") {
        i += 2;
        break;
      }
    }
  }
  return i;
}
var doubleQuote = '"';
var singleQuote = "'";
function readAttributeStr(xmlData, i) {
  let attrStr = "";
  let startChar = "";
  let tagClosed = false;
  for (; i < xmlData.length; i++) {
    if (xmlData[i] === doubleQuote || xmlData[i] === singleQuote) {
      if (startChar === "") {
        startChar = xmlData[i];
      } else if (startChar !== xmlData[i]) {
      } else {
        startChar = "";
      }
    } else if (xmlData[i] === ">") {
      if (startChar === "") {
        tagClosed = true;
        break;
      }
    }
    attrStr += xmlData[i];
  }
  if (startChar !== "") {
    return false;
  }
  return {
    value: attrStr,
    index: i,
    tagClosed
  };
}
var validAttrStrRegxp = new RegExp(`(\\s*)([^\\s=]+)(\\s*=)?(\\s*(['"])(([\\s\\S])*?)\\5)?`, "g");
function validateAttributeString(attrStr, options) {
  const matches = getAllMatches(attrStr, validAttrStrRegxp);
  const attrNames = {};
  for (let i = 0; i < matches.length; i++) {
    if (matches[i][1].length === 0) {
      return getErrorObject("InvalidAttr", "Attribute '" + matches[i][2] + "' has no space in starting.", getPositionFromMatch(matches[i]));
    } else if (matches[i][3] !== void 0 && matches[i][4] === void 0) {
      return getErrorObject("InvalidAttr", "Attribute '" + matches[i][2] + "' is without value.", getPositionFromMatch(matches[i]));
    } else if (matches[i][3] === void 0 && !options.allowBooleanAttributes) {
      return getErrorObject("InvalidAttr", "boolean attribute '" + matches[i][2] + "' is not allowed.", getPositionFromMatch(matches[i]));
    }
    const attrName = matches[i][2];
    if (!validateAttrName(attrName)) {
      return getErrorObject("InvalidAttr", "Attribute '" + attrName + "' is an invalid name.", getPositionFromMatch(matches[i]));
    }
    if (!Object.prototype.hasOwnProperty.call(attrNames, attrName)) {
      attrNames[attrName] = 1;
    } else {
      return getErrorObject("InvalidAttr", "Attribute '" + attrName + "' is repeated.", getPositionFromMatch(matches[i]));
    }
  }
  return true;
}
function validateNumberAmpersand(xmlData, i) {
  let re = /\d/;
  if (xmlData[i] === "x") {
    i++;
    re = /[\da-fA-F]/;
  }
  for (; i < xmlData.length; i++) {
    if (xmlData[i] === ";")
      return i;
    if (!xmlData[i].match(re))
      break;
  }
  return -1;
}
function validateAmpersand(xmlData, i) {
  i++;
  if (xmlData[i] === ";")
    return -1;
  if (xmlData[i] === "#") {
    i++;
    return validateNumberAmpersand(xmlData, i);
  }
  let count = 0;
  for (; i < xmlData.length; i++, count++) {
    if (xmlData[i].match(/\w/) && count < 20)
      continue;
    if (xmlData[i] === ";")
      break;
    return -1;
  }
  return i;
}
function getErrorObject(code, message, lineNumber) {
  return {
    err: {
      code,
      msg: message,
      line: lineNumber.line || lineNumber,
      col: lineNumber.col
    }
  };
}
function validateAttrName(attrName) {
  return isName(attrName);
}
function validateTagName(tagname) {
  return isName(tagname);
}
function getLineNumberForPosition(xmlData, index) {
  const lines = xmlData.substring(0, index).split(/\r?\n/);
  return {
    line: lines.length,
    // column number is last line's length + 1, because column numbering starts at 1:
    col: lines[lines.length - 1].length + 1
  };
}
function getPositionFromMatch(match) {
  return match.startIndex + match[1].length;
}

// node_modules/@nodable/entities/src/entities.js
var CURRENCY = {
  cent: "\xA2",
  pound: "\xA3",
  curren: "\xA4",
  yen: "\xA5",
  euro: "\u20AC",
  dollar: "$",
  fnof: "\u0192",
  inr: "\u20B9",
  af: "\u060B",
  birr: "\u1265\u122D",
  peso: "\u20B1",
  rub: "\u20BD",
  won: "\u20A9",
  yuan: "\xA5",
  cedil: "\xB8"
};
var XML = {
  amp: "&",
  apos: "'",
  gt: ">",
  lt: "<",
  quot: '"'
};
var COMMON_HTML = {
  nbsp: "\xA0",
  copy: "\xA9",
  reg: "\xAE",
  trade: "\u2122",
  mdash: "\u2014",
  ndash: "\u2013",
  hellip: "\u2026",
  laquo: "\xAB",
  raquo: "\xBB",
  lsquo: "\u2018",
  rsquo: "\u2019",
  ldquo: "\u201C",
  rdquo: "\u201D",
  bull: "\u2022",
  para: "\xB6",
  sect: "\xA7",
  deg: "\xB0",
  frac12: "\xBD",
  frac14: "\xBC",
  frac34: "\xBE"
};

// node_modules/@nodable/entities/src/EntityDecoder.js
var ENTITY_ACTION = Object.freeze({
  /** Resolve and expand the entity normally. */
  ALLOW: "allow",
  /** Silently skip this entity — it will not be registered. */
  BLOCK: "block",
  /** Throw an error, aborting entity registration entirely. */
  THROW: "throw"
});
var SPECIAL_CHARS = new Set("!?\\\\/[]$%{}^&*()<>|+");
function validateEntityName(name) {
  if (name[0] === "#") {
    throw new Error(`[EntityReplacer] Invalid character '#' in entity name: "${name}"`);
  }
  for (const ch of name) {
    if (SPECIAL_CHARS.has(ch)) {
      throw new Error(`[EntityReplacer] Invalid character '${ch}' in entity name: "${name}"`);
    }
  }
  return name;
}
function mergeEntityMaps(...maps) {
  const out = /* @__PURE__ */ Object.create(null);
  for (const map of maps) {
    if (!map) continue;
    for (const key of Object.keys(map)) {
      const raw = map[key];
      if (typeof raw === "string") {
        out[key] = raw;
      } else if (raw && typeof raw === "object" && raw.val !== void 0) {
        const val = raw.val;
        if (typeof val === "string") {
          out[key] = val;
        }
      }
    }
  }
  return out;
}
var LIMIT_TIER_EXTERNAL = "external";
var LIMIT_TIER_BASE = "base";
var LIMIT_TIER_ALL = "all";
function parseLimitTiers(raw) {
  if (!raw || raw === LIMIT_TIER_EXTERNAL) return /* @__PURE__ */ new Set([LIMIT_TIER_EXTERNAL]);
  if (raw === LIMIT_TIER_ALL) return /* @__PURE__ */ new Set([LIMIT_TIER_ALL]);
  if (raw === LIMIT_TIER_BASE) return /* @__PURE__ */ new Set([LIMIT_TIER_BASE]);
  if (Array.isArray(raw)) return new Set(raw);
  return /* @__PURE__ */ new Set([LIMIT_TIER_EXTERNAL]);
}
var NCR_LEVEL = Object.freeze({ allow: 0, leave: 1, remove: 2, throw: 3 });
var XML10_ALLOWED_C0 = /* @__PURE__ */ new Set([9, 10, 13]);
function parseNCRConfig(ncr) {
  if (!ncr) {
    return { xmlVersion: 1, onLevel: NCR_LEVEL.allow, nullLevel: NCR_LEVEL.remove };
  }
  const xmlVersion = ncr.xmlVersion === 1.1 ? 1.1 : 1;
  const onLevel = NCR_LEVEL[ncr.onNCR] ?? NCR_LEVEL.allow;
  const nullLevel = NCR_LEVEL[ncr.nullNCR] ?? NCR_LEVEL.remove;
  const clampedNull = Math.max(nullLevel, NCR_LEVEL.remove);
  return { xmlVersion, onLevel, nullLevel: clampedNull };
}
var EntityDecoder = class {
  /**
   * @param {object} [options]
   * @param {object|null}  [options.namedEntities]        — extra named entities merged into base map
   * @param {object}  [options.limit]                 — security limits
   * @param {number}       [options.limit.maxTotalExpansions=0]  — 0 = unlimited
   * @param {number}       [options.limit.maxExpandedLength=0]   — 0 = unlimited
   * @param {'external'|'base'|'all'|string[]} [options.limit.applyLimitsTo='external']
   *   Which entity tiers count against the security limits:
   *   - 'external' (default) — only input/runtime + persistent external entities
   *   - 'base'               — only DEFAULT_XML_ENTITIES + namedEntities
   *   - 'all'                — every entity regardless of tier
   *   - string[]             — explicit combination, e.g. ['external', 'base']
   * @param {((resolved: string, original: string) => string)|null} [options.postCheck=null]
   * @param {string[]} [options.remove=[]] — entity names (e.g. ['nbsp', '#13']) to delete (replace with empty string)
   * @param {string[]} [options.leave=[]]  — entity names to keep as literal (unchanged in output)
   * @param {object}   [options.ncr]       — Numeric Character Reference controls
   * @param {1.0|1.1}  [options.ncr.xmlVersion=1.0]
   *   XML version governing which codepoint ranges are restricted:
   *   - 1.0 — C0 controls U+0001–U+001F (except U+0009/000A/000D) are prohibited
   *   - 1.1 — C0 controls are allowed when written as NCRs; C1 (U+007F–U+009F) decoded as-is
   * @param {'allow'|'leave'|'remove'|'throw'} [options.ncr.onNCR='allow']
   *   Base action for numeric references. Severity order: allow < leave < remove < throw.
   *   For codepoint ranges that carry a minimum level (surrogates → remove, XML 1.0 C0 → remove),
   *   the effective action is max(onNCR, rangeMinimum).
   * @param {'remove'|'throw'} [options.ncr.nullNCR='remove']
   *   Action for U+0000 (null). 'allow' and 'leave' are clamped to 'remove' since null is never safe.
   * @param {((name: string, value: string) => 'allow'|'block'|'throw')|null} [options.onExternalEntity=null]
   *   Hook called when an external entity is registered via `setExternalEntities()` or
   *   `addExternalEntity()`. Return `ENTITY_ACTION.ALLOW` to accept the entity,
   *   `ENTITY_ACTION.BLOCK` to silently skip it, or `ENTITY_ACTION.THROW` to abort with an error.
   * @param {((name: string, value: string) => 'allow'|'block'|'throw')|null} [options.onInputEntity=null]
   *   Hook called when an input entity is registered via `addInputEntities()`. Return
   *   `ENTITY_ACTION.ALLOW` to accept, `ENTITY_ACTION.BLOCK` to silently skip, or
   *   `ENTITY_ACTION.THROW` to abort with an error.
   */
  constructor(options = {}) {
    this._limit = options.limit || {};
    this._maxTotalExpansions = this._limit.maxTotalExpansions || 0;
    this._maxExpandedLength = this._limit.maxExpandedLength || 0;
    this._postCheck = typeof options.postCheck === "function" ? options.postCheck : (r) => r;
    this._limitTiers = parseLimitTiers(this._limit.applyLimitsTo ?? LIMIT_TIER_EXTERNAL);
    this._numericAllowed = options.numericAllowed ?? true;
    this._baseMap = mergeEntityMaps(XML, options.namedEntities || null);
    this._externalMap = /* @__PURE__ */ Object.create(null);
    this._inputMap = /* @__PURE__ */ Object.create(null);
    this._totalExpansions = 0;
    this._expandedLength = 0;
    this._removeSet = new Set(options.remove && Array.isArray(options.remove) ? options.remove : []);
    this._leaveSet = new Set(options.leave && Array.isArray(options.leave) ? options.leave : []);
    const ncrCfg = parseNCRConfig(options.ncr);
    this._ncrXmlVersion = ncrCfg.xmlVersion;
    this._ncrOnLevel = ncrCfg.onLevel;
    this._ncrNullLevel = ncrCfg.nullLevel;
    this._onExternalEntity = typeof options.onExternalEntity === "function" ? options.onExternalEntity : null;
    this._onInputEntity = typeof options.onInputEntity === "function" ? options.onInputEntity : null;
  }
  // -------------------------------------------------------------------------
  // Private: registration hook dispatch
  // -------------------------------------------------------------------------
  /**
   * Invoke a registration hook for a single entity name/value pair.
   * Returns true when the entity should be accepted, false when it should be
   * silently skipped (BLOCK), and throws when the hook returns THROW.
   *
   * @param {((name: string, value: string) => 'allow'|'block'|'throw')|null} hook
   * @param {string} name
   * @param {string} value
   * @param {string} context  — used in error messages ('external' | 'input')
   * @returns {boolean}  true = accept, false = skip
   */
  _applyRegistrationHook(hook, name, value, context) {
    if (!hook) return true;
    const action = hook(name, value);
    if (action === ENTITY_ACTION.BLOCK) return false;
    if (action === ENTITY_ACTION.THROW) {
      throw new Error(
        `[EntityDecoder] Registration of ${context} entity "&${name};" was rejected by hook`
      );
    }
    return true;
  }
  // -------------------------------------------------------------------------
  // Persistent external entity registration
  // -------------------------------------------------------------------------
  /**
   * Replace the full set of persistent external entities.
   * All keys are validated — throws on invalid characters.
   * If `onExternalEntity` is set, it is called once per entry; entries that
   * return `ENTITY_ACTION.BLOCK` are silently omitted, `ENTITY_ACTION.THROW`
   * aborts the whole call.
   * @param {Record<string, string | { regex?: RegExp, val: string }>} map
   */
  setExternalEntities(map) {
    if (map) {
      for (const key of Object.keys(map)) {
        validateEntityName(key);
      }
    }
    if (!this._onExternalEntity) {
      this._externalMap = mergeEntityMaps(map);
      return;
    }
    const flat = mergeEntityMaps(map);
    const filtered = /* @__PURE__ */ Object.create(null);
    for (const [name, value] of Object.entries(flat)) {
      if (this._applyRegistrationHook(this._onExternalEntity, name, value, "external")) {
        filtered[name] = value;
      }
    }
    this._externalMap = filtered;
  }
  /**
   * Add a single persistent external entity.
   * If `onExternalEntity` is set it is called before the entity is stored;
   * `ENTITY_ACTION.BLOCK` silently skips storage, `ENTITY_ACTION.THROW` raises.
   * @param {string} key
   * @param {string} value
   */
  addExternalEntity(key, value) {
    validateEntityName(key);
    if (typeof value === "string" && value.indexOf("&") === -1) {
      if (this._applyRegistrationHook(this._onExternalEntity, key, value, "external")) {
        this._externalMap[key] = value;
      }
    }
  }
  // -------------------------------------------------------------------------
  // Input / runtime entity registration (per document)
  // -------------------------------------------------------------------------
  /**
   * Inject DOCTYPE entities for the current document.
   * Also resets per-document expansion counters.
   * If `onInputEntity` is set it is called once per entry; entries returning
   * `ENTITY_ACTION.BLOCK` are silently omitted, `ENTITY_ACTION.THROW` aborts.
   * @param {Record<string, string | { regx?: RegExp, regex?: RegExp, val: string }>} map
   */
  addInputEntities(map) {
    this._totalExpansions = 0;
    this._expandedLength = 0;
    if (!this._onInputEntity) {
      this._inputMap = mergeEntityMaps(map);
      return;
    }
    const flat = mergeEntityMaps(map);
    const filtered = /* @__PURE__ */ Object.create(null);
    for (const [name, value] of Object.entries(flat)) {
      if (this._applyRegistrationHook(this._onInputEntity, name, value, "input")) {
        filtered[name] = value;
      }
    }
    this._inputMap = filtered;
  }
  // -------------------------------------------------------------------------
  // Per-document reset
  // -------------------------------------------------------------------------
  /**
   * Wipe input/runtime entities and reset counters.
   * Call this before processing each new document.
   * @returns {this}
   */
  reset() {
    this._inputMap = /* @__PURE__ */ Object.create(null);
    this._totalExpansions = 0;
    this._expandedLength = 0;
    return this;
  }
  // -------------------------------------------------------------------------
  // XML version (can be set after construction, e.g. once parser reads <?xml?>)
  // -------------------------------------------------------------------------
  /**
   * Update the XML version used for NCR classification.
   * Call this as soon as the document's `<?xml version="...">` declaration is parsed.
   * @param {1.0|1.1|number} version
   */
  setXmlVersion(version) {
    this._ncrXmlVersion = version === 1.1 ? 1.1 : 1;
  }
  // -------------------------------------------------------------------------
  // Primary API
  // -------------------------------------------------------------------------
  /**
   * Replace all entity references in `str` in a single pass.
   *
   * @param {string} str
   * @returns {string}
   */
  decode(str) {
    if (typeof str !== "string" || str.length === 0) return str;
    if (str.indexOf("&") === -1) return str;
    const original = str;
    const chunks = [];
    const len = str.length;
    let last = 0;
    let i = 0;
    const limitExpansions = this._maxTotalExpansions > 0;
    const limitLength = this._maxExpandedLength > 0;
    const checkLimits = limitExpansions || limitLength;
    while (i < len) {
      if (str.charCodeAt(i) !== 38) {
        i++;
        continue;
      }
      let j = i + 1;
      while (j < len && str.charCodeAt(j) !== 59 && j - i <= 32) j++;
      if (j >= len || str.charCodeAt(j) !== 59) {
        i++;
        continue;
      }
      const token = str.slice(i + 1, j);
      if (token.length === 0) {
        i++;
        continue;
      }
      let replacement;
      let tier;
      if (this._removeSet.has(token)) {
        replacement = "";
        if (tier === void 0) {
          tier = LIMIT_TIER_EXTERNAL;
        }
      } else if (this._leaveSet.has(token)) {
        i++;
        continue;
      } else if (token.charCodeAt(0) === 35) {
        const ncrResult = this._resolveNCR(token);
        if (ncrResult === void 0) {
          i++;
          continue;
        }
        replacement = ncrResult;
        tier = LIMIT_TIER_BASE;
      } else {
        const resolved = this._resolveName(token);
        replacement = resolved?.value;
        tier = resolved?.tier;
      }
      if (replacement === void 0) {
        i++;
        continue;
      }
      if (i > last) chunks.push(str.slice(last, i));
      chunks.push(replacement);
      last = j + 1;
      i = last;
      if (checkLimits && this._tierCounts(tier)) {
        if (limitExpansions) {
          this._totalExpansions++;
          if (this._totalExpansions > this._maxTotalExpansions) {
            throw new Error(
              `[EntityReplacer] Entity expansion count limit exceeded: ${this._totalExpansions} > ${this._maxTotalExpansions}`
            );
          }
        }
        if (limitLength) {
          const delta = replacement.length - (token.length + 2);
          if (delta > 0) {
            this._expandedLength += delta;
            if (this._expandedLength > this._maxExpandedLength) {
              throw new Error(
                `[EntityReplacer] Expanded content length limit exceeded: ${this._expandedLength} > ${this._maxExpandedLength}`
              );
            }
          }
        }
      }
    }
    if (last < len) chunks.push(str.slice(last));
    const result = chunks.length === 0 ? str : chunks.join("");
    return this._postCheck(result, original);
  }
  // -------------------------------------------------------------------------
  // Private: limit tier check
  // -------------------------------------------------------------------------
  /**
   * Returns true if a resolved entity of the given tier should count
   * against the expansion/length limits.
   * @param {string} tier  — LIMIT_TIER_EXTERNAL | LIMIT_TIER_BASE
   * @returns {boolean}
   */
  _tierCounts(tier) {
    if (this._limitTiers.has(LIMIT_TIER_ALL)) return true;
    return this._limitTiers.has(tier);
  }
  // -------------------------------------------------------------------------
  // Private: entity resolution
  // -------------------------------------------------------------------------
  /**
   * Resolve a named entity token (without & and ;).
   * Priority: inputMap > externalMap > baseMap
   * Returns the resolved value tagged with its limit tier.
   *
   * @param {string} name
   * @returns {{ value: string, tier: string }|undefined}
   */
  _resolveName(name) {
    if (name in this._inputMap) return { value: this._inputMap[name], tier: LIMIT_TIER_EXTERNAL };
    if (name in this._externalMap) return { value: this._externalMap[name], tier: LIMIT_TIER_EXTERNAL };
    if (name in this._baseMap) return { value: this._baseMap[name], tier: LIMIT_TIER_BASE };
    return void 0;
  }
  /**
   * Classify a codepoint and return the minimum action level that must be applied.
   * Returns -1 when no minimum is imposed (normal allow path).
   *
   * Ranges checked (in priority order):
   *   1. U+0000            — null, governed by nullNCR (always ≥ remove)
   *   2. U+D800–U+DFFF     — surrogates, always prohibited (min: remove)
   *   3. U+0001–U+001F \ {0x09,0x0A,0x0D}  — XML 1.0 restricted C0 (min: remove)
   *      (skipped in XML 1.1 — C0 controls are allowed when written as NCRs)
   *
   * @param {number} cp  — codepoint
   * @returns {number}   — minimum NCR_LEVEL value, or -1 for no restriction
   */
  _classifyNCR(cp) {
    if (cp === 0) return this._ncrNullLevel;
    if (cp >= 55296 && cp <= 57343) return NCR_LEVEL.remove;
    if (this._ncrXmlVersion === 1) {
      if (cp >= 1 && cp <= 31 && !XML10_ALLOWED_C0.has(cp)) return NCR_LEVEL.remove;
    }
    return -1;
  }
  /**
   * Execute a resolved NCR action.
   *
   * @param {number} action   — NCR_LEVEL value
   * @param {string} token    — raw token (e.g. '#38') for error messages
   * @param {number} cp       — codepoint, used only for error messages
   * @returns {string|undefined}
   *   - decoded character string  → 'allow'
   *   - ''                        → 'remove'
   *   - undefined                 → 'leave' (caller must skip past '&' only)
   *   - throws Error              → 'throw'
   */
  _applyNCRAction(action, token, cp) {
    switch (action) {
      case NCR_LEVEL.allow:
        return String.fromCodePoint(cp);
      case NCR_LEVEL.remove:
        return "";
      case NCR_LEVEL.leave:
        return void 0;
      // signal: keep literal
      case NCR_LEVEL.throw:
        throw new Error(
          `[EntityDecoder] Prohibited numeric character reference &${token}; (U+${cp.toString(16).toUpperCase().padStart(4, "0")})`
        );
      default:
        return String.fromCodePoint(cp);
    }
  }
  /**
   * Full NCR resolution pipeline for a numeric token.
   *
   * Steps:
   *   1. Parse the codepoint (decimal or hex).
   *   2. Validate the raw codepoint range (NaN, <0, >0x10FFFF).
   *   3. If numericAllowed is false and no minimum restriction applies → leave as-is.
   *   4. Classify the codepoint to find the minimum required action level.
   *   5. Resolve effective action = max(onNCR, minimum).
   *   6. Apply and return.
   *
   * @param {string} token  — e.g. '#38', '#x26', '#X26'
   * @returns {string|undefined}
   *   - string (incl. '')  — replacement ('' = remove)
   *   - undefined          — leave original &token; as-is
   */
  _resolveNCR(token) {
    const second = token.charCodeAt(1);
    let cp;
    if (second === 120 || second === 88) {
      cp = parseInt(token.slice(2), 16);
    } else {
      cp = parseInt(token.slice(1), 10);
    }
    if (Number.isNaN(cp) || cp < 0 || cp > 1114111) return void 0;
    const minimum = this._classifyNCR(cp);
    if (!this._numericAllowed && minimum < NCR_LEVEL.remove) return void 0;
    const effective = minimum === -1 ? this._ncrOnLevel : Math.max(this._ncrOnLevel, minimum);
    return this._applyNCRAction(effective, token, cp);
  }
};

// node_modules/fast-xml-parser/src/xmlparser/OptionsBuilder.js
var defaultOnDangerousProperty = (name) => {
  if (DANGEROUS_PROPERTY_NAMES.includes(name)) {
    return "__" + name;
  }
  return name;
};
var defaultOptions2 = {
  preserveOrder: false,
  attributeNamePrefix: "@_",
  attributesGroupName: false,
  textNodeName: "#text",
  ignoreAttributes: true,
  removeNSPrefix: false,
  // remove NS from tag name or attribute name if true
  allowBooleanAttributes: false,
  //a tag can have attributes without any value
  //ignoreRootElement : false,
  parseTagValue: true,
  parseAttributeValue: false,
  trimValues: true,
  //Trim string values of tag and attributes
  cdataPropName: false,
  numberParseOptions: {
    hex: true,
    leadingZeros: true,
    eNotation: true,
    unicode: false
  },
  tagValueProcessor: function(tagName, val) {
    return val;
  },
  attributeValueProcessor: function(attrName, val) {
    return val;
  },
  stopNodes: [],
  //nested tags will not be parsed even for errors
  alwaysCreateTextNode: false,
  isArray: () => false,
  commentPropName: false,
  unpairedTags: [],
  processEntities: true,
  htmlEntities: false,
  entityDecoder: null,
  ignoreDeclaration: false,
  ignorePiTags: false,
  transformTagName: false,
  transformAttributeName: false,
  updateTag: function(tagName, jPath, attrs) {
    return tagName;
  },
  // skipEmptyListItem: false
  captureMetaData: false,
  maxNestedTags: 100,
  strictReservedNames: true,
  jPath: true,
  // if true, pass jPath string to callbacks; if false, pass matcher instance
  onDangerousProperty: defaultOnDangerousProperty
};
function validatePropertyName(propertyName, optionName) {
  if (typeof propertyName !== "string") {
    return;
  }
  const normalized = propertyName.toLowerCase();
  if (DANGEROUS_PROPERTY_NAMES.some((dangerous) => normalized === dangerous.toLowerCase())) {
    throw new Error(
      `[SECURITY] Invalid ${optionName}: "${propertyName}" is a reserved JavaScript keyword that could cause prototype pollution`
    );
  }
  if (criticalProperties.some((dangerous) => normalized === dangerous.toLowerCase())) {
    throw new Error(
      `[SECURITY] Invalid ${optionName}: "${propertyName}" is a reserved JavaScript keyword that could cause prototype pollution`
    );
  }
}
function normalizeProcessEntities(value, htmlEntities) {
  if (typeof value === "boolean") {
    return {
      enabled: value,
      // true or false
      maxEntitySize: 1e4,
      maxExpansionDepth: 1e4,
      maxTotalExpansions: Infinity,
      maxExpandedLength: 1e5,
      maxEntityCount: 1e3,
      allowedTags: null,
      tagFilter: null,
      appliesTo: "all"
    };
  }
  if (typeof value === "object" && value !== null) {
    return {
      enabled: value.enabled !== false,
      maxEntitySize: Math.max(1, value.maxEntitySize ?? 1e4),
      maxExpansionDepth: Math.max(1, value.maxExpansionDepth ?? 1e4),
      maxTotalExpansions: Math.max(1, value.maxTotalExpansions ?? Infinity),
      maxExpandedLength: Math.max(1, value.maxExpandedLength ?? 1e5),
      maxEntityCount: Math.max(1, value.maxEntityCount ?? 1e3),
      allowedTags: value.allowedTags ?? null,
      tagFilter: value.tagFilter ?? null,
      appliesTo: value.appliesTo ?? "all"
    };
  }
  return normalizeProcessEntities(true);
}
var buildOptions = function(options) {
  const built = Object.assign({}, defaultOptions2, options);
  const propertyNameOptions = [
    { value: built.attributeNamePrefix, name: "attributeNamePrefix" },
    { value: built.attributesGroupName, name: "attributesGroupName" },
    { value: built.textNodeName, name: "textNodeName" },
    { value: built.cdataPropName, name: "cdataPropName" },
    { value: built.commentPropName, name: "commentPropName" }
  ];
  for (const { value, name } of propertyNameOptions) {
    if (value) {
      validatePropertyName(value, name);
    }
  }
  if (built.onDangerousProperty === null) {
    built.onDangerousProperty = defaultOnDangerousProperty;
  }
  built.processEntities = normalizeProcessEntities(built.processEntities, built.htmlEntities);
  built.unpairedTagsSet = new Set(built.unpairedTags);
  if (built.stopNodes && Array.isArray(built.stopNodes)) {
    built.stopNodes = built.stopNodes.map((node) => {
      if (typeof node === "string" && node.startsWith("*.")) {
        return ".." + node.substring(2);
      }
      return node;
    });
  }
  return built;
};

// node_modules/fast-xml-parser/src/xmlparser/xmlNode.js
var METADATA_SYMBOL;
if (typeof Symbol !== "function") {
  METADATA_SYMBOL = "@@xmlMetadata";
} else {
  METADATA_SYMBOL = /* @__PURE__ */ Symbol("XML Node Metadata");
}
var XmlNode = class {
  constructor(tagname) {
    this.tagname = tagname;
    this.child = [];
    this[":@"] = /* @__PURE__ */ Object.create(null);
  }
  add(key, val) {
    if (key === "__proto__") key = "#__proto__";
    this.child.push({ [key]: val });
  }
  addChild(node, startIndex) {
    if (node.tagname === "__proto__") node.tagname = "#__proto__";
    if (node[":@"] && Object.keys(node[":@"]).length > 0) {
      this.child.push({ [node.tagname]: node.child, [":@"]: node[":@"] });
    } else {
      this.child.push({ [node.tagname]: node.child });
    }
    if (startIndex !== void 0) {
      this.child[this.child.length - 1][METADATA_SYMBOL] = { startIndex };
    }
  }
  /** symbol used for metadata */
  static getMetaDataSymbol() {
    return METADATA_SYMBOL;
  }
};

// node_modules/xml-naming/src/index.js
var nameStartChar10 = ":A-Za-z_\xC0-\xD6\xD8-\xF6\xF8-\u02FF\u0370-\u037D\u037F-\u0486\u0488-\u1FFF\u200C-\u200D\u2070-\u218F\u2C00-\u2FEF\u3001-\uD7FF\uF900-\uFDCF\uFDF0-\uFFFD";
var nameChar10 = nameStartChar10 + "\\-\\.\\d\xB7\u0300-\u036F\u203F-\u2040";
var nameStartChar11 = ":A-Za-z_\xC0-\u02FF\u0370-\u037D\u037F-\u0486\u0488-\u1FFF\u200C-\u200D\u2070-\u218F\u2C00-\u2FEF\u3001-\uD7FF\uF900-\uFDCF\uFDF0-\uFFFD\u{10000}-\u{EFFFF}";
var nameChar11 = nameStartChar11 + "\\-\\.\\d\xB7\u0300-\u036F\u0487\u203F-\u2040";
var buildRegexes = (startChar, char, flags = "") => {
  const ncStart = startChar.replace(":", "");
  const ncChar = char.replace(":", "");
  const ncNamePat = `[${ncStart}][${ncChar}]*`;
  return {
    name: new RegExp(`^[${startChar}][${char}]*$`, flags),
    ncName: new RegExp(`^${ncNamePat}$`, flags),
    qName: new RegExp(`^${ncNamePat}(?::${ncNamePat})?$`, flags),
    nmToken: new RegExp(`^[${char}]+$`, flags),
    nmTokens: new RegExp(`^[${char}]+(?:\\s+[${char}]+)*$`, flags)
  };
};
var regexes10 = buildRegexes(nameStartChar10, nameChar10);
var regexes11 = buildRegexes(nameStartChar11, nameChar11, "u");
var nameStartCharAscii = ":A-Za-z_";
var nameCharAscii = nameStartCharAscii + "\\-\\.\\d";
var regexesAscii = buildRegexes(nameStartCharAscii, nameCharAscii);
var getRegexes = (xmlVersion = "1.0", asciiOnly = false) => {
  if (asciiOnly) return regexesAscii;
  return xmlVersion === "1.1" ? regexes11 : regexes10;
};
var qName = (str, { xmlVersion = "1.0", asciiOnly = false } = {}) => getRegexes(xmlVersion, asciiOnly).qName.test(str);

// node_modules/fast-xml-parser/src/xmlparser/DocTypeReader.js
var DocTypeReader = class {
  constructor(options, xmlVersion) {
    this.suppressValidationErr = !options;
    this.options = options;
    this.xmlVersion = xmlVersion || 1;
  }
  setXmlVersion(xmlVersion = 1) {
    this.xmlVersion = xmlVersion;
  }
  readDocType(xmlData, i) {
    const entities = /* @__PURE__ */ Object.create(null);
    let entityCount = 0;
    if (xmlData[i + 3] === "O" && xmlData[i + 4] === "C" && xmlData[i + 5] === "T" && xmlData[i + 6] === "Y" && xmlData[i + 7] === "P" && xmlData[i + 8] === "E") {
      i = i + 9;
      let angleBracketsCount = 1;
      let hasBody = false, comment = false;
      let exp = "";
      for (; i < xmlData.length; i++) {
        if (xmlData[i] === "<" && !comment) {
          if (hasBody && hasSeq(xmlData, "!ENTITY", i)) {
            i += 7;
            let entityName, val;
            [entityName, val, i] = this.readEntityExp(xmlData, i + 1, this.suppressValidationErr);
            if (val.indexOf("&") === -1) {
              if (this.options.enabled !== false && this.options.maxEntityCount != null && entityCount >= this.options.maxEntityCount) {
                throw new Error(
                  `Entity count (${entityCount + 1}) exceeds maximum allowed (${this.options.maxEntityCount})`
                );
              }
              entities[entityName] = val;
              entityCount++;
            }
          } else if (hasBody && hasSeq(xmlData, "!ELEMENT", i)) {
            i += 8;
            const { index } = this.readElementExp(xmlData, i + 1);
            i = index;
          } else if (hasBody && hasSeq(xmlData, "!ATTLIST", i)) {
            i += 8;
          } else if (hasBody && hasSeq(xmlData, "!NOTATION", i)) {
            i += 9;
            const { index } = this.readNotationExp(xmlData, i + 1, this.suppressValidationErr);
            i = index;
          } else if (hasSeq(xmlData, "!--", i)) comment = true;
          else throw new Error(`Invalid DOCTYPE`);
          angleBracketsCount++;
          exp = "";
        } else if (xmlData[i] === ">") {
          if (comment) {
            if (xmlData[i - 1] === "-" && xmlData[i - 2] === "-") {
              comment = false;
              angleBracketsCount--;
            }
          } else {
            angleBracketsCount--;
          }
          if (angleBracketsCount === 0) {
            break;
          }
        } else if (xmlData[i] === "[") {
          hasBody = true;
        } else {
          exp += xmlData[i];
        }
      }
      if (angleBracketsCount !== 0) {
        throw new Error(`Unclosed DOCTYPE`);
      }
    } else {
      throw new Error(`Invalid Tag instead of DOCTYPE`);
    }
    return { entities, i };
  }
  readEntityExp(xmlData, i) {
    i = skipWhitespace(xmlData, i);
    const startIndex = i;
    while (i < xmlData.length && !/\s/.test(xmlData[i]) && xmlData[i] !== '"' && xmlData[i] !== "'") {
      i++;
    }
    let entityName = xmlData.substring(startIndex, i);
    validateEntityName2(entityName, { xmlVersion: this.xmlVersion });
    i = skipWhitespace(xmlData, i);
    if (!this.suppressValidationErr) {
      if (xmlData.substring(i, i + 6).toUpperCase() === "SYSTEM") {
        throw new Error("External entities are not supported");
      } else if (xmlData[i] === "%") {
        throw new Error("Parameter entities are not supported");
      }
    }
    let entityValue = "";
    [i, entityValue] = this.readIdentifierVal(xmlData, i, "entity");
    if (this.options.enabled !== false && this.options.maxEntitySize != null && entityValue.length > this.options.maxEntitySize) {
      throw new Error(
        `Entity "${entityName}" size (${entityValue.length}) exceeds maximum allowed size (${this.options.maxEntitySize})`
      );
    }
    i--;
    return [entityName, entityValue, i];
  }
  readNotationExp(xmlData, i) {
    i = skipWhitespace(xmlData, i);
    const startIndex = i;
    while (i < xmlData.length && !/\s/.test(xmlData[i])) {
      i++;
    }
    let notationName = xmlData.substring(startIndex, i);
    !this.suppressValidationErr && validateEntityName2(notationName, { xmlVersion: this.xmlVersion });
    i = skipWhitespace(xmlData, i);
    const identifierType = xmlData.substring(i, i + 6).toUpperCase();
    if (!this.suppressValidationErr && identifierType !== "SYSTEM" && identifierType !== "PUBLIC") {
      throw new Error(`Expected SYSTEM or PUBLIC, found "${identifierType}"`);
    }
    i += identifierType.length;
    i = skipWhitespace(xmlData, i);
    let publicIdentifier = null;
    let systemIdentifier = null;
    if (identifierType === "PUBLIC") {
      [i, publicIdentifier] = this.readIdentifierVal(xmlData, i, "publicIdentifier");
      i = skipWhitespace(xmlData, i);
      if (xmlData[i] === '"' || xmlData[i] === "'") {
        [i, systemIdentifier] = this.readIdentifierVal(xmlData, i, "systemIdentifier");
      }
    } else if (identifierType === "SYSTEM") {
      [i, systemIdentifier] = this.readIdentifierVal(xmlData, i, "systemIdentifier");
      if (!this.suppressValidationErr && !systemIdentifier) {
        throw new Error("Missing mandatory system identifier for SYSTEM notation");
      }
    }
    return { notationName, publicIdentifier, systemIdentifier, index: --i };
  }
  readIdentifierVal(xmlData, i, type) {
    let identifierVal = "";
    const startChar = xmlData[i];
    if (startChar !== '"' && startChar !== "'") {
      throw new Error(`Expected quoted string, found "${startChar}"`);
    }
    i++;
    const startIndex = i;
    while (i < xmlData.length && xmlData[i] !== startChar) {
      i++;
    }
    identifierVal = xmlData.substring(startIndex, i);
    if (xmlData[i] !== startChar) {
      throw new Error(`Unterminated ${type} value`);
    }
    i++;
    return [i, identifierVal];
  }
  readElementExp(xmlData, i) {
    i = skipWhitespace(xmlData, i);
    const startIndex = i;
    while (i < xmlData.length && !/\s/.test(xmlData[i])) {
      i++;
    }
    let elementName = xmlData.substring(startIndex, i);
    if (!this.suppressValidationErr && !qName(elementName, { xmlVersion: this.xmlVersion })) {
      throw new Error(`Invalid element name: "${elementName}"`);
    }
    i = skipWhitespace(xmlData, i);
    let contentModel = "";
    if (xmlData[i] === "E" && hasSeq(xmlData, "MPTY", i)) i += 4;
    else if (xmlData[i] === "A" && hasSeq(xmlData, "NY", i)) i += 2;
    else if (xmlData[i] === "(") {
      i++;
      const startIndex2 = i;
      while (i < xmlData.length && xmlData[i] !== ")") {
        i++;
      }
      contentModel = xmlData.substring(startIndex2, i);
      if (xmlData[i] !== ")") {
        throw new Error("Unterminated content model");
      }
    } else if (!this.suppressValidationErr) {
      throw new Error(`Invalid Element Expression, found "${xmlData[i]}"`);
    }
    return {
      elementName,
      contentModel: contentModel.trim(),
      index: i
    };
  }
  readAttlistExp(xmlData, i) {
    i = skipWhitespace(xmlData, i);
    let startIndex = i;
    while (i < xmlData.length && !/\s/.test(xmlData[i])) {
      i++;
    }
    let elementName = xmlData.substring(startIndex, i);
    validateEntityName2(elementName, { xmlVersion: this.xmlVersion });
    i = skipWhitespace(xmlData, i);
    startIndex = i;
    while (i < xmlData.length && !/\s/.test(xmlData[i])) {
      i++;
    }
    let attributeName = xmlData.substring(startIndex, i);
    if (!validateEntityName2(attributeName, { xmlVersion: this.xmlVersion })) {
      throw new Error(`Invalid attribute name: "${attributeName}"`);
    }
    i = skipWhitespace(xmlData, i);
    let attributeType = "";
    if (xmlData.substring(i, i + 8).toUpperCase() === "NOTATION") {
      attributeType = "NOTATION";
      i += 8;
      i = skipWhitespace(xmlData, i);
      if (xmlData[i] !== "(") {
        throw new Error(`Expected '(', found "${xmlData[i]}"`);
      }
      i++;
      let allowedNotations = [];
      while (i < xmlData.length && xmlData[i] !== ")") {
        const startIndex2 = i;
        while (i < xmlData.length && xmlData[i] !== "|" && xmlData[i] !== ")") {
          i++;
        }
        let notation = xmlData.substring(startIndex2, i);
        notation = notation.trim();
        if (!validateEntityName2(notation, { xmlVersion: this.xmlVersion })) {
          throw new Error(`Invalid notation name: "${notation}"`);
        }
        allowedNotations.push(notation);
        if (xmlData[i] === "|") {
          i++;
          i = skipWhitespace(xmlData, i);
        }
      }
      if (xmlData[i] !== ")") {
        throw new Error("Unterminated list of notations");
      }
      i++;
      attributeType += " (" + allowedNotations.join("|") + ")";
    } else {
      const startIndex2 = i;
      while (i < xmlData.length && !/\s/.test(xmlData[i])) {
        i++;
      }
      attributeType += xmlData.substring(startIndex2, i);
      const validTypes = ["CDATA", "ID", "IDREF", "IDREFS", "ENTITY", "ENTITIES", "NMTOKEN", "NMTOKENS"];
      if (!this.suppressValidationErr && !validTypes.includes(attributeType.toUpperCase())) {
        throw new Error(`Invalid attribute type: "${attributeType}"`);
      }
    }
    i = skipWhitespace(xmlData, i);
    let defaultValue = "";
    if (xmlData.substring(i, i + 8).toUpperCase() === "#REQUIRED") {
      defaultValue = "#REQUIRED";
      i += 8;
    } else if (xmlData.substring(i, i + 7).toUpperCase() === "#IMPLIED") {
      defaultValue = "#IMPLIED";
      i += 7;
    } else {
      [i, defaultValue] = this.readIdentifierVal(xmlData, i, "ATTLIST");
    }
    return {
      elementName,
      attributeName,
      attributeType,
      defaultValue,
      index: i
    };
  }
};
var skipWhitespace = (data, index) => {
  while (index < data.length && /\s/.test(data[index])) {
    index++;
  }
  return index;
};
function hasSeq(data, seq, i) {
  for (let j = 0; j < seq.length; j++) {
    if (seq[j] !== data[i + j + 1]) return false;
  }
  return true;
}
function validateEntityName2(name, xmlVersion) {
  if (qName(name, { xmlVersion }))
    return name;
  else
    throw new Error(`Invalid entity name ${name}`);
}

// node_modules/anynum/digitTable.js
var SCRIPT_ZEROS = [
  // Basic Latin (ASCII) — included for completeness / pass-through
  48,
  // 0-9
  // Arabic scripts
  1632,
  // Arabic-Indic ٠١٢٣٤٥٦٧٨٩
  1776,
  // Extended Arabic-Indic (Urdu/Persian/Sindhi) ۰۱۲۳
  // Indic scripts
  2406,
  // Devanagari ०१२३४५६७८९
  2534,
  // Bengali ০১২৩৪৫৬৭৮৯
  2662,
  // Gurmukhi ੦੧੨੩੪੫੬੭੮੯
  2790,
  // Gujarati ૦૧૨૩૪૫૬૭૮૯
  2918,
  // Odia ୦୧୨୩୪୫୬୭୮୯
  3046,
  // Tamil ௦௧௨௩௪௫௬௭௮௯
  3174,
  // Telugu ౦౧౨౩౪౫౬౭౮౯
  3302,
  // Kannada ೦೧೨೩೪೫೬೭೮೯
  3430,
  // Malayalam ൦൧൨൩൪൫൬൭൮൯
  3558,
  // Sinhala Archaic ෦෧෨෩෪෫෬෭෮෯
  // Southeast Asian scripts
  3664,
  // Thai ๐๑๒๓๔๕๖๗๘๙
  3792,
  // Lao ໐໑໒໓໔໕໖໗໘໙
  3872,
  // Tibetan ༠༡༢༣༤༥༦༧༨༩
  4160,
  // Myanmar ၀၁၂၃၄၅၆၇၈၉
  4240,
  // Myanmar Shan ႐႑႒႓႔႕႖႗႘႙
  6112,
  // Khmer ០១២៣៤៥៦៧៨៩
  6160,
  // Mongolian ᠐᠑᠒᠓᠔᠕᠖᠗᠘᠙
  6470,
  // Limbu ᥆᥇᥈᥉᥊᥋᥌᥍᥎᥏
  6608,
  // New Tai Lue ᧐᧑᧒᧓᧔᧕᧖᧗᧘᧙
  6784,
  // Tai Tham Hora ᪀᪁᪂᪃᪄᪅᪆᪇᪈᪉
  6800,
  // Tai Tham Tham ᪐᪑᪒᪓᪔᪕᪖᪗᪘᪙
  6992,
  // Balinese ᭐᭑᭒᭓᭔᭕᭖᭗᭘᭙
  7088,
  // Sundanese ᮰᮱᮲᮳᮴᮵᮶᮷᮸᮹
  7232,
  // Lepcha ᱀᱁᱂᱃᱄᱅᱆᱇᱈᱉
  7248,
  // Ol Chiki ᱐᱑᱒᱓᱔᱕᱖᱗᱘᱙
  // Fullwidth (CJK context)
  65296,
  // Fullwidth ０１２３４５６７８９
  // Mathematical digit variants (Unicode math block)
  120782,
  // Mathematical Bold
  120792,
  // Mathematical Double-Struck
  120802,
  // Mathematical Sans-Serif
  120812,
  // Mathematical Sans-Serif Bold
  120822,
  // Mathematical Monospace
  // Other scripts
  66720,
  // Osmanya 𐒠𐒡𐒢𐒣𐒤𐒥𐒦𐒧𐒨𐒩
  68912,
  // Hanifi Rohingya 𐴰𐴱𐴲𐴳𐴴𐴵𐴶𐴷𐴸𐴹
  69734,
  // Brahmi 𑁦𑁧𑁨𑁩𑁪𑁫𑁬𑁭𑁮𑁯
  69872,
  // Sora Sompeng 𑃰𑃱𑃲𑃳𑃴𑃵𑃶𑃷𑃸𑃹
  69942,
  // Chakma 𑄶𑄷𑄸𑄹𑄺𑄻𑄼𑄽𑄾𑄿
  70096,
  // Sharada 𑇐𑇑𑇒𑇓𑇔𑇕𑇖𑇗𑇘𑇙
  70384,
  // Khudawadi 𑋰𑋱𑋲𑋳𑋴𑋵𑋶𑋷𑋸𑋹
  70736,
  // Newa 𑑐𑑑𑑒𑑓𑑔𑑕𑑖𑑗𑑘𑑙
  70864,
  // Tirhuta 𑓐𑓑𑓒𑓓𑓔𑓕𑓖𑓗𑓘𑓙
  71248,
  // Modi 𑙐𑙑𑙒𑙓𑙔𑙕𑙖𑙗𑙘𑙙
  71360,
  // Takri 𑛀𑛁𑛂𑛃𑛄𑛅𑛆𑛇𑛈𑛉
  71472,
  // Ahom 𑜰𑜱𑜲𑜳𑜴𑜵𑜶𑜷𑜸𑜹
  71904,
  // Warang Citi 𑣠𑣡𑣢𑣣𑣤𑣥𑣦𑣧𑣨𑣩
  72016,
  // Dives Akuru 𑥐𑥑𑥒𑥓𑥔𑥕𑥖𑥗𑥘𑥙
  72688,
  // Khitan Small Script 𑯰𑯱𑯲𑯳𑯴𑯵𑯶𑯷𑯸𑯹
  72784,
  // Bhaiksuki 𑱐𑱑𑱒𑱓𑱔𑱕𑱖𑱗𑱘𑱙
  73040,
  // Masaram Gondi 𑵐𑵑𑵒𑵓𑵔𑵕𑵖𑵗𑵘𑵙
  73120,
  // Gunjala Gondi 𑶠𑶡𑶢𑶣𑶤𑶥𑶦𑶧𑶨𑶩
  73552,
  // Kawi 𑽐𑽑𑽒𑽓𑽔𑽕𑽖𑽗𑽘𑽙
  92768,
  // Mro 𖩠𖩡𖩢𖩣𖩤𖩥𖩦𖩧𖩨𖩩
  92864,
  // Tangsa 𖫀𖫁𖫂𖫃𖫄𖫅𖫆𖫇𖫈𖫉
  93008,
  // Pahawh Hmong 𖭐𖭑𖭒𖭓𖭔𖭕𖭖𖭗𖭘𖭙
  123200,
  // Nyiakeng Puachue Hmong 𞅀𞅁𞅂𞅃𞅄𞅅𞅆𞅇𞅈𞅉
  123632,
  // Wancho 𞋰𞋱𞋲𞋳𞋴𞋵𞋶𞋷𞋸𞋹
  124144,
  // Nag Mundari 𞓰𞓱𞓲𞓳𞓴𞓵𞓶𞓷𞓸𞓹
  125264,
  // Adlam 𞥐𞥑𞥒𞥓𞥔𞥕𞥖𞥗𞥘𞥙
  130032
  // Segmented digit symbols 🯰🯱🯲🯳🯴🯵🯶🯷🯸🯹
];
var NOT_DIGIT = 255;
var HIGH_MAP = /* @__PURE__ */ new Map();
var LOW_MAX = 65535;
var LOW_MIN = 1632;
var TABLE_OFFSET = LOW_MIN;
var TABLE_SIZE = LOW_MAX - LOW_MIN + 1;
var TABLE = new Uint8Array(TABLE_SIZE).fill(NOT_DIGIT);
for (const zero of SCRIPT_ZEROS) {
  for (let d = 0; d < 10; d++) {
    const cp = zero + d;
    if (cp <= LOW_MAX) {
      TABLE[cp - TABLE_OFFSET] = d;
    } else {
      HIGH_MAP.set(cp, d);
    }
  }
}

// node_modules/anynum/anynum.js
var CHAR_0 = 48;
var CHAR_9 = 57;
var CHAR_MINUS = 45;
var MINUS_SET = /* @__PURE__ */ new Set([8722, 65293, 65123]);
function anynum(str) {
  if (typeof str !== "string") return str;
  const len = str.length;
  if (len === 0) return str;
  let firstHit = -1;
  for (let i = 0; i < len; i++) {
    const cc = str.charCodeAt(i);
    if (cc >= CHAR_0 && cc <= CHAR_9 || cc === CHAR_MINUS) continue;
    if (cc < TABLE_OFFSET) {
      if (MINUS_SET.has(cc)) {
        firstHit = i;
        break;
      }
      continue;
    }
    if (cc >= 55296 && cc <= 56319) {
      if (i + 1 < len) {
        const low = str.charCodeAt(i + 1);
        if (low >= 56320 && low <= 57343) {
          const cp = 65536 + (cc - 55296 << 10) + (low - 56320);
          if (HIGH_MAP.has(cp)) {
            firstHit = i;
            break;
          }
        }
      }
      continue;
    }
    if (TABLE[cc - TABLE_OFFSET] !== NOT_DIGIT || MINUS_SET.has(cc)) {
      firstHit = i;
      break;
    }
  }
  if (firstHit === -1) return str;
  const chars = [];
  if (firstHit > 0) chars.push(str.slice(0, firstHit));
  for (let i = firstHit; i < len; i++) {
    const cc = str.charCodeAt(i);
    if (cc >= CHAR_0 && cc <= CHAR_9 || cc === CHAR_MINUS) {
      chars.push(str[i]);
      continue;
    }
    if (cc < TABLE_OFFSET) {
      chars.push(MINUS_SET.has(cc) ? "-" : str[i]);
      continue;
    }
    if (cc >= 55296 && cc <= 56319) {
      if (i + 1 < len) {
        const low = str.charCodeAt(i + 1);
        if (low >= 56320 && low <= 57343) {
          const cp = 65536 + (cc - 55296 << 10) + (low - 56320);
          const d2 = HIGH_MAP.get(cp);
          if (d2 !== void 0) {
            chars.push(String.fromCharCode(d2 + 48));
            i++;
            continue;
          }
        }
      }
      chars.push(str[i]);
      continue;
    }
    if (MINUS_SET.has(cc)) {
      chars.push("-");
      continue;
    }
    const d = TABLE[cc - TABLE_OFFSET];
    chars.push(d !== NOT_DIGIT ? String.fromCharCode(d + 48) : str[i]);
  }
  return chars.join("");
}
var anynum_default = anynum;

// node_modules/strnum/strnum.js
var hexRegex = /^[-+]?0x[a-fA-F0-9]+$/;
var binRegex = /^0b[01]+$/;
var octRegex = /^0o[0-7]+$/;
var numRegex = /^([\-\+])?(0*)([0-9]*(\.[0-9]*)?)$/;
var consider = {
  hex: true,
  binary: false,
  octal: false,
  leadingZeros: true,
  decimalPoint: ".",
  eNotation: true,
  //skipLike: /regex/,
  infinity: "original",
  // "null", "infinity" (Infinity type), "string" ("Infinity" (the string literal))
  unicode: false
};
function toNumber(str, options = {}) {
  options = Object.assign({}, consider, options);
  if (!str || typeof str !== "string") return str;
  let trimmedStr = str.trim();
  if (trimmedStr.length === 0) return str;
  else if (options.skipLike !== void 0 && options.skipLike.test(trimmedStr)) return str;
  else if (trimmedStr === "0") return 0;
  if (options.unicode) {
    trimmedStr = anynum_default(trimmedStr);
    if (trimmedStr === "0") return 0;
  }
  if (options.hex && hexRegex.test(trimmedStr)) {
    return parse_int(trimmedStr, 16);
  } else if (options.binary && binRegex.test(trimmedStr)) {
    return parse_int(trimmedStr, 2);
  } else if (options.octal && octRegex.test(trimmedStr)) {
    return parse_int(trimmedStr, 8);
  } else if (!isFinite(trimmedStr)) {
    return handleInfinity(str, Number(trimmedStr), options);
  } else if (trimmedStr.includes("e") || trimmedStr.includes("E")) {
    return resolveEnotation(str, trimmedStr, options);
  } else {
    const match = numRegex.exec(trimmedStr);
    if (match) {
      const sign = match[1] || "";
      const leadingZeros = match[2];
      let numTrimmedByZeros = trimZeros(match[3]);
      const decimalAdjacentToLeadingZeros = sign ? (
        // 0., -00., 000.
        str[leadingZeros.length + 1] === "."
      ) : str[leadingZeros.length] === ".";
      if (!options.leadingZeros && (leadingZeros.length > 1 || leadingZeros.length === 1 && !decimalAdjacentToLeadingZeros)) {
        return str;
      } else {
        const num = Number(trimmedStr);
        const parsedStr = String(num);
        if (num === 0) return num;
        if (parsedStr.search(/[eE]/) !== -1) {
          if (options.eNotation) return num;
          else return str;
        } else if (trimmedStr.indexOf(".") !== -1) {
          if (parsedStr === "0") return num;
          else if (parsedStr === numTrimmedByZeros) return num;
          else if (parsedStr === `${sign}${numTrimmedByZeros}`) return num;
          else return str;
        }
        let n = leadingZeros ? numTrimmedByZeros : trimmedStr;
        if (leadingZeros) {
          return n === parsedStr || sign + n === parsedStr ? num : str;
        } else {
          return n === parsedStr || n === sign + parsedStr ? num : str;
        }
      }
    } else {
      return str;
    }
  }
}
var eNotationRegx = /^([-+])?(0*)(\d*(\.\d*)?[eE][-\+]?\d+)$/;
function resolveEnotation(str, trimmedStr, options) {
  if (!options.eNotation) return str;
  const notation = trimmedStr.match(eNotationRegx);
  if (notation) {
    let sign = notation[1] || "";
    const eChar = notation[3].indexOf("e") === -1 ? "E" : "e";
    const leadingZeros = notation[2];
    const eAdjacentToLeadingZeros = sign ? (
      // 0E.
      str[leadingZeros.length + 1] === eChar
    ) : str[leadingZeros.length] === eChar;
    if (leadingZeros.length > 1 && eAdjacentToLeadingZeros) return str;
    else if (leadingZeros.length === 1 && (notation[3].startsWith(`.${eChar}`) || notation[3][0] === eChar)) {
      return Number(trimmedStr);
    } else if (leadingZeros.length > 0) {
      if (options.leadingZeros && !eAdjacentToLeadingZeros) {
        trimmedStr = (notation[1] || "") + notation[3];
        return Number(trimmedStr);
      } else return str;
    } else {
      return Number(trimmedStr);
    }
  } else {
    return str;
  }
}
function trimZeros(numStr) {
  if (numStr && numStr.indexOf(".") !== -1) {
    let end = numStr.length;
    while (end > 0 && numStr.charCodeAt(end - 1) === 48) end--;
    numStr = numStr.slice(0, end);
    if (numStr === ".") numStr = "0";
    else if (numStr[0] === ".") numStr = "0" + numStr;
    else if (numStr[numStr.length - 1] === ".") numStr = numStr.substring(0, numStr.length - 1);
    return numStr;
  }
  return numStr;
}
function parse_int(numStr, base) {
  const str = numStr.trim();
  if (base === 2 || base === 8) numStr = str.substring(2);
  if (parseInt) return parseInt(numStr, base);
  else if (Number.parseInt) return Number.parseInt(numStr, base);
  else if (window && window.parseInt) return window.parseInt(numStr, base);
  else throw new Error("parseInt, Number.parseInt, window.parseInt are not supported");
}
function handleInfinity(str, num, options) {
  const isPositive = num === Infinity;
  switch (options.infinity.toLowerCase()) {
    case "null":
      return null;
    case "infinity":
      return num;
    // Return Infinity or -Infinity
    case "string":
      return isPositive ? "Infinity" : "-Infinity";
    case "original":
    default:
      return str;
  }
}

// node_modules/fast-xml-parser/src/ignoreAttributes.js
function getIgnoreAttributesFn(ignoreAttributes) {
  if (typeof ignoreAttributes === "function") {
    return ignoreAttributes;
  }
  if (Array.isArray(ignoreAttributes)) {
    return (attrName) => {
      for (const pattern of ignoreAttributes) {
        if (typeof pattern === "string" && attrName === pattern) {
          return true;
        }
        if (pattern instanceof RegExp && pattern.test(attrName)) {
          return true;
        }
      }
    };
  }
  return () => false;
}

// node_modules/path-expression-matcher/src/Expression.js
var Expression = class {
  /**
   * Create a new Expression
   * @param {string} pattern - Pattern string (e.g., "root.users.user", "..user[id]")
   * @param {Object} options - Configuration options
   * @param {string} options.separator - Path separator (default: '.')
   */
  constructor(pattern, options = {}, data) {
    this.pattern = pattern;
    this.separator = options.separator || ".";
    this.segments = this._parse(pattern);
    this.data = data;
    this._hasDeepWildcard = this.segments.some((seg) => seg.type === "deep-wildcard");
    this._hasAttributeCondition = this.segments.some((seg) => seg.attrName !== void 0);
    this._hasPositionSelector = this.segments.some((seg) => seg.position !== void 0);
  }
  /**
   * Parse pattern string into segments
   * @private
   * @param {string} pattern - Pattern to parse
   * @returns {Array} Array of segment objects
   */
  _parse(pattern) {
    const segments = [];
    let i = 0;
    let currentPart = "";
    while (i < pattern.length) {
      if (pattern[i] === this.separator) {
        if (i + 1 < pattern.length && pattern[i + 1] === this.separator) {
          if (currentPart.trim()) {
            segments.push(this._parseSegment(currentPart.trim()));
            currentPart = "";
          }
          segments.push({ type: "deep-wildcard" });
          i += 2;
        } else {
          if (currentPart.trim()) {
            segments.push(this._parseSegment(currentPart.trim()));
          }
          currentPart = "";
          i++;
        }
      } else {
        currentPart += pattern[i];
        i++;
      }
    }
    if (currentPart.trim()) {
      segments.push(this._parseSegment(currentPart.trim()));
    }
    return segments;
  }
  /**
   * Parse a single segment
   * @private
   * @param {string} part - Segment string (e.g., "user", "ns::user", "user[id]", "ns::user:first")
   * @returns {Object} Segment object
   */
  _parseSegment(part) {
    const segment = { type: "tag" };
    let bracketContent = null;
    let withoutBrackets = part;
    const bracketMatch = part.match(/^([^\[]+)(\[[^\]]*\])(.*)$/);
    if (bracketMatch) {
      withoutBrackets = bracketMatch[1] + bracketMatch[3];
      if (bracketMatch[2]) {
        const content = bracketMatch[2].slice(1, -1);
        if (content) {
          bracketContent = content;
        }
      }
    }
    let namespace = void 0;
    let tagAndPosition = withoutBrackets;
    if (withoutBrackets.includes("::")) {
      const nsIndex = withoutBrackets.indexOf("::");
      namespace = withoutBrackets.substring(0, nsIndex).trim();
      tagAndPosition = withoutBrackets.substring(nsIndex + 2).trim();
      if (!namespace) {
        throw new Error(`Invalid namespace in pattern: ${part}`);
      }
    }
    let tag = void 0;
    let positionMatch = null;
    if (tagAndPosition.includes(":")) {
      const colonIndex = tagAndPosition.lastIndexOf(":");
      const tagPart = tagAndPosition.substring(0, colonIndex).trim();
      const posPart = tagAndPosition.substring(colonIndex + 1).trim();
      const isPositionKeyword = ["first", "last", "odd", "even"].includes(posPart) || /^nth\(\d+\)$/.test(posPart);
      if (isPositionKeyword) {
        tag = tagPart;
        positionMatch = posPart;
      } else {
        tag = tagAndPosition;
      }
    } else {
      tag = tagAndPosition;
    }
    if (!tag) {
      throw new Error(`Invalid segment pattern: ${part}`);
    }
    segment.tag = tag;
    if (namespace) {
      segment.namespace = namespace;
    }
    if (bracketContent) {
      if (bracketContent.includes("=")) {
        const eqIndex = bracketContent.indexOf("=");
        segment.attrName = bracketContent.substring(0, eqIndex).trim();
        segment.attrValue = bracketContent.substring(eqIndex + 1).trim();
      } else {
        segment.attrName = bracketContent.trim();
      }
    }
    if (positionMatch) {
      const nthMatch = positionMatch.match(/^nth\((\d+)\)$/);
      if (nthMatch) {
        segment.position = "nth";
        segment.positionValue = parseInt(nthMatch[1], 10);
      } else {
        segment.position = positionMatch;
      }
    }
    return segment;
  }
  /**
   * Get the number of segments
   * @returns {number}
   */
  get length() {
    return this.segments.length;
  }
  /**
   * Check if expression contains deep wildcard
   * @returns {boolean}
   */
  hasDeepWildcard() {
    return this._hasDeepWildcard;
  }
  /**
   * Check if expression has attribute conditions
   * @returns {boolean}
   */
  hasAttributeCondition() {
    return this._hasAttributeCondition;
  }
  /**
   * Check if expression has position selectors
   * @returns {boolean}
   */
  hasPositionSelector() {
    return this._hasPositionSelector;
  }
  /**
   * Get string representation
   * @returns {string}
   */
  toString() {
    return this.pattern;
  }
};

// node_modules/path-expression-matcher/src/ExpressionSet.js
var ExpressionSet = class {
  constructor() {
    this._byDepthAndTag = /* @__PURE__ */ new Map();
    this._wildcardByDepth = /* @__PURE__ */ new Map();
    this._deepWildcards = [];
    this._deepByTerminalTag = /* @__PURE__ */ new Map();
    this._patterns = /* @__PURE__ */ new Set();
    this._sealed = false;
  }
  /**
   * Add an Expression to the set.
   * Duplicate patterns (same pattern string) are silently ignored.
   *
   * @param {import('./Expression.js').default} expression - A pre-constructed Expression instance
   * @returns {this} for chaining
   * @throws {TypeError} if called after seal()
   *
   * @example
   * set.add(new Expression('root.users.user'));
   * set.add(new Expression('..script'));
   */
  add(expression) {
    if (this._sealed) {
      throw new TypeError(
        "ExpressionSet is sealed. Create a new ExpressionSet to add more expressions."
      );
    }
    if (this._patterns.has(expression.pattern)) return this;
    this._patterns.add(expression.pattern);
    if (expression.hasDeepWildcard()) {
      const lastSeg2 = expression.segments[expression.segments.length - 1];
      if (lastSeg2 && lastSeg2.type !== "deep-wildcard" && lastSeg2.tag !== "*") {
        const tag2 = lastSeg2.tag;
        if (!this._deepByTerminalTag.has(tag2)) this._deepByTerminalTag.set(tag2, []);
        this._deepByTerminalTag.get(tag2).push(expression);
      } else {
        this._deepWildcards.push(expression);
      }
      return this;
    }
    const depth = expression.length;
    const lastSeg = expression.segments[expression.segments.length - 1];
    const tag = lastSeg?.tag;
    if (!tag || tag === "*") {
      if (!this._wildcardByDepth.has(depth)) this._wildcardByDepth.set(depth, []);
      this._wildcardByDepth.get(depth).push(expression);
    } else {
      const key = `${depth}:${tag}`;
      if (!this._byDepthAndTag.has(key)) this._byDepthAndTag.set(key, []);
      this._byDepthAndTag.get(key).push(expression);
    }
    return this;
  }
  /**
   * Add multiple expressions at once.
   *
   * @param {import('./Expression.js').default[]} expressions - Array of Expression instances
   * @returns {this} for chaining
   *
   * @example
   * set.addAll([
   *   new Expression('root.users.user'),
   *   new Expression('root.config.setting'),
   * ]);
   */
  addAll(expressions) {
    for (const expr of expressions) this.add(expr);
    return this;
  }
  /**
   * Check whether a pattern string is already present in the set.
   *
   * @param {import('./Expression.js').default} expression
   * @returns {boolean}
   */
  has(expression) {
    return this._patterns.has(expression.pattern);
  }
  /**
   * Number of expressions in the set.
   * @type {number}
   */
  get size() {
    return this._patterns.size;
  }
  /**
   * Seal the set against further modifications.
   * Useful to prevent accidental mutations after config is built.
   * Calling add() or addAll() on a sealed set throws a TypeError.
   *
   * @returns {this}
   */
  seal() {
    this._sealed = true;
    return this;
  }
  /**
   * Whether the set has been sealed.
   * @type {boolean}
   */
  get isSealed() {
    return this._sealed;
  }
  /**
   * Test whether the matcher's current path matches any expression in the set.
   *
   * Evaluation order (cheapest → most expensive):
   *  1. Exact depth + tag bucket  — O(1) lookup, typically 0–2 expressions
   *  2. Depth-only wildcard bucket — O(1) lookup, rare
   *  3. Deep-wildcard list         — always checked, but usually small
   *
   * @param {import('./Matcher.js').default} matcher - Matcher instance (or readOnly view)
   * @returns {boolean} true if any expression matches the current path
   *
   * @example
   * if (stopNodes.matchesAny(matcher)) {
   *   // handle stop node
   * }
   */
  matchesAny(matcher) {
    return this.findMatch(matcher) !== null;
  }
  /**
  * Find and return the first Expression that matches the matcher's current path.
  *
  * Uses the same evaluation order as matchesAny (cheapest → most expensive):
  *  1. Exact depth + tag bucket
  *  2. Depth-only wildcard bucket
  *  3. Deep-wildcard list
  *
  * @param {import('./Matcher.js').default} matcher - Matcher instance (or readOnly view)
  * @returns {import('./Expression.js').default | null} the first matching Expression, or null
  *
  * @example
  * const expr = stopNodes.findMatch(matcher);
  * if (expr) {
  *   // access expr.config, expr.pattern, etc.
  * }
  */
  findMatch(matcher) {
    const depth = matcher.getDepth();
    const tag = matcher.getCurrentTag();
    const exactKey = `${depth}:${tag}`;
    const exactBucket = this._byDepthAndTag.get(exactKey);
    if (exactBucket) {
      for (let i = 0; i < exactBucket.length; i++) {
        if (matcher.matches(exactBucket[i])) return exactBucket[i];
      }
    }
    const wildcardBucket = this._wildcardByDepth.get(depth);
    if (wildcardBucket) {
      for (let i = 0; i < wildcardBucket.length; i++) {
        if (matcher.matches(wildcardBucket[i])) return wildcardBucket[i];
      }
    }
    const deepBucket = this._deepByTerminalTag.get(tag);
    if (deepBucket) {
      for (let i = 0; i < deepBucket.length; i++) {
        if (matcher.matches(deepBucket[i])) return deepBucket[i];
      }
    }
    for (let i = 0; i < this._deepWildcards.length; i++) {
      if (matcher.matches(this._deepWildcards[i])) return this._deepWildcards[i];
    }
    return null;
  }
};

// node_modules/path-expression-matcher/src/Matcher.js
var MatcherView = class {
  /**
   * @param {Matcher} matcher - The parent Matcher instance to read from.
   */
  constructor(matcher) {
    this._matcher = matcher;
  }
  /**
   * Get the path separator used by the parent matcher.
   * @returns {string}
   */
  get separator() {
    return this._matcher.separator;
  }
  /**
   * Get current tag name.
   * @returns {string|undefined}
   */
  getCurrentTag() {
    const path = this._matcher.path;
    return path.length > 0 ? path[path.length - 1].tag : void 0;
  }
  /**
   * Get current namespace.
   * @returns {string|undefined}
   */
  getCurrentNamespace() {
    const path = this._matcher.path;
    return path.length > 0 ? path[path.length - 1].namespace : void 0;
  }
  /**
   * Get current node's attribute value.
   * @param {string} attrName
   * @returns {*}
   */
  getAttrValue(attrName) {
    const path = this._matcher.path;
    if (path.length === 0) return void 0;
    return path[path.length - 1].values?.[attrName];
  }
  /**
   * Check if current node has an attribute.
   * @param {string} attrName
   * @returns {boolean}
   */
  hasAttr(attrName) {
    const path = this._matcher.path;
    if (path.length === 0) return false;
    const current = path[path.length - 1];
    return current.values !== void 0 && attrName in current.values;
  }
  /**
   * Get the value of a "kept" attribute from the nearest ancestor (or
   * current node) that declared it via `push(tag, attrs, ns, { keep: [...] })`.
   * @param {string} attrName
   * @returns {*}
   */
  getAnyParentAttr(attrName) {
    return this._matcher.getAnyParentAttr(attrName);
  }
  /**
   * Check whether any ancestor (or the current node) kept the given
   * attribute via `push(tag, attrs, ns, { keep: [...] })`.
   * @param {string} attrName
   * @returns {boolean}
   */
  hasAnyParentAttr(attrName) {
    return this._matcher.hasAnyParentAttr(attrName);
  }
  /**
   * Get current node's sibling position (child index in parent).
   * @returns {number}
   */
  getPosition() {
    const path = this._matcher.path;
    if (path.length === 0) return -1;
    return path[path.length - 1].position ?? 0;
  }
  /**
   * Get current node's repeat counter (occurrence count of this tag name).
   * @returns {number}
   */
  getCounter() {
    const path = this._matcher.path;
    if (path.length === 0) return -1;
    return path[path.length - 1].counter ?? 0;
  }
  /**
   * Get current node's sibling index (alias for getPosition).
   * @returns {number}
   * @deprecated Use getPosition() or getCounter() instead
   */
  getIndex() {
    return this.getPosition();
  }
  /**
   * Get current path depth.
   * @returns {number}
   */
  getDepth() {
    return this._matcher.path.length;
  }
  /**
   * Get path as string.
   * @param {string} [separator] - Optional separator (uses default if not provided)
   * @param {boolean} [includeNamespace=true]
   * @returns {string}
   */
  toString(separator, includeNamespace = true) {
    return this._matcher.toString(separator, includeNamespace);
  }
  /**
   * Get path as array of tag names.
   * @returns {string[]}
   */
  toArray() {
    return this._matcher.path.map((n) => n.tag);
  }
  /**
   * Match current path against an Expression.
   * @param {Expression} expression
   * @returns {boolean}
   */
  matches(expression) {
    return this._matcher.matches(expression);
  }
  /**
   * Match any expression in the given set against the current path.
   * @param {ExpressionSet} exprSet
   * @returns {boolean}
   */
  matchesAny(exprSet) {
    return exprSet.matchesAny(this._matcher);
  }
};
var Matcher = class {
  /**
   * Create a new Matcher.
   * @param {Object} [options={}]
   * @param {string} [options.separator='.'] - Default path separator
   */
  constructor(options = {}) {
    this.separator = options.separator || ".";
    this.path = [];
    this.siblingStacks = [];
    this._pathStringCache = null;
    this._view = new MatcherView(this);
    this._keptAttrs = [];
  }
  /**
   * Push a new tag onto the path.
   * @param {string} tagName
   * @param {Object|null} [attrValues=null]
   * @param {string|null} [namespace=null]
   * @param {Object|null} [options=null]
   * @param {string[]} [options.keep] - Names of attributes (from attrValues)
   */
  push(tagName, attrValues = null, namespace = null, options = null) {
    this._pathStringCache = null;
    if (this.path.length > 0) {
      this.path[this.path.length - 1].values = void 0;
    }
    const currentLevel = this.path.length;
    let level = this.siblingStacks[currentLevel];
    if (!level) {
      level = { counts: /* @__PURE__ */ new Map(), total: 0 };
      this.siblingStacks[currentLevel] = level;
    }
    const siblingKey = namespace ? `${namespace}:${tagName}` : tagName;
    const counter = level.counts.get(siblingKey) || 0;
    const position = level.total;
    level.counts.set(siblingKey, counter + 1);
    level.total++;
    const node = {
      tag: tagName,
      position,
      counter
    };
    if (namespace !== null && namespace !== void 0) {
      node.namespace = namespace;
    }
    if (attrValues !== null && attrValues !== void 0) {
      node.values = attrValues;
    }
    this.path.push(node);
    const depth = this.path.length;
    const keep = options !== null ? options.keep : null;
    if (keep !== null && keep !== void 0 && keep.length > 0 && attrValues) {
      for (let i = 0; i < keep.length; i++) {
        const name = keep[i];
        if (attrValues[name] !== void 0) {
          this._keptAttrs.push({ depth, name, value: attrValues[name] });
        }
      }
    }
  }
  /**
   * Pop the last tag from the path.
   * @returns {Object|undefined} The popped node
   */
  pop() {
    if (this.path.length === 0) return void 0;
    this._pathStringCache = null;
    const node = this.path.pop();
    if (this.siblingStacks.length > this.path.length + 1) {
      this.siblingStacks.length = this.path.length + 1;
    }
    const poppedDepth = this.path.length + 1;
    while (this._keptAttrs.length > 0 && this._keptAttrs[this._keptAttrs.length - 1].depth >= poppedDepth) {
      this._keptAttrs.pop();
    }
    return node;
  }
  /**
   * Update current node's attribute values.
   * Useful when attributes are parsed after push.
   * @param {Object} attrValues
   */
  updateCurrent(attrValues) {
    if (this.path.length > 0) {
      const current = this.path[this.path.length - 1];
      if (attrValues !== null && attrValues !== void 0) {
        current.values = attrValues;
      }
    }
  }
  /**
   * Get current tag name.
   * @returns {string|undefined}
   */
  getCurrentTag() {
    return this.path.length > 0 ? this.path[this.path.length - 1].tag : void 0;
  }
  /**
   * Get current namespace.
   * @returns {string|undefined}
   */
  getCurrentNamespace() {
    return this.path.length > 0 ? this.path[this.path.length - 1].namespace : void 0;
  }
  /**
   * Get current node's attribute value.
   * @param {string} attrName
   * @returns {*}
   */
  getAttrValue(attrName) {
    if (this.path.length === 0) return void 0;
    return this.path[this.path.length - 1].values?.[attrName];
  }
  /**
   * Check if current node has an attribute.
   * @param {string} attrName
   * @returns {boolean}
   */
  hasAttr(attrName) {
    if (this.path.length === 0) return false;
    const current = this.path[this.path.length - 1];
    return current.values !== void 0 && attrName in current.values;
  }
  /**
   * Get the value of a "kept" attribute from the nearest ancestor (or
   * current node) that declared it via `push(tag, attrs, ns, { keep: [...] })`.
   * Unlike getAttrValue(), this works regardless of how deep the path has
   * gone since the attribute was pushed — but only for attribute names that
   * were explicitly marked with `keep` at push time. Cost is proportional to
   * the number of currently-kept attributes (typically 0-3), not path depth.
   * @param {string} attrName
   * @returns {*} the value, or undefined if no ancestor kept this attribute
   */
  getAnyParentAttr(attrName) {
    const kept = this._keptAttrs;
    for (let i = kept.length - 1; i >= 0; i--) {
      if (kept[i].name === attrName) return kept[i].value;
    }
    return void 0;
  }
  /**
   * Check whether any ancestor (or the current node) kept the given
   * attribute via `push(tag, attrs, ns, { keep: [...] })`.
   * @param {string} attrName
   * @returns {boolean}
   */
  hasAnyParentAttr(attrName) {
    const kept = this._keptAttrs;
    for (let i = kept.length - 1; i >= 0; i--) {
      if (kept[i].name === attrName) return true;
    }
    return false;
  }
  /**
   * Get current node's sibling position (child index in parent).
   * @returns {number}
   */
  getPosition() {
    if (this.path.length === 0) return -1;
    return this.path[this.path.length - 1].position ?? 0;
  }
  /**
   * Get current node's repeat counter (occurrence count of this tag name).
   * @returns {number}
   */
  getCounter() {
    if (this.path.length === 0) return -1;
    return this.path[this.path.length - 1].counter ?? 0;
  }
  /**
   * Get current node's sibling index (alias for getPosition).
   * @returns {number}
   * @deprecated Use getPosition() or getCounter() instead
   */
  getIndex() {
    return this.getPosition();
  }
  /**
   * Get current path depth.
   * @returns {number}
   */
  getDepth() {
    return this.path.length;
  }
  /**
   * Get path as string.
   * @param {string} [separator] - Optional separator (uses default if not provided)
   * @param {boolean} [includeNamespace=true]
   * @returns {string}
   */
  toString(separator, includeNamespace = true) {
    const sep2 = separator || this.separator;
    const isDefault = sep2 === this.separator && includeNamespace === true;
    if (isDefault) {
      if (this._pathStringCache !== null) {
        return this._pathStringCache;
      }
      const result = this.path.map(
        (n) => n.namespace ? `${n.namespace}:${n.tag}` : n.tag
      ).join(sep2);
      this._pathStringCache = result;
      return result;
    }
    return this.path.map(
      (n) => includeNamespace && n.namespace ? `${n.namespace}:${n.tag}` : n.tag
    ).join(sep2);
  }
  /**
   * Get path as array of tag names.
   * @returns {string[]}
   */
  toArray() {
    return this.path.map((n) => n.tag);
  }
  /**
   * Reset the path to empty.
   */
  reset() {
    this._pathStringCache = null;
    this.path = [];
    this.siblingStacks = [];
    this._keptAttrs = [];
  }
  /**
   * Match current path against an Expression.
   * @param {Expression} expression
   * @returns {boolean}
   */
  matches(expression) {
    const segments = expression.segments;
    if (segments.length === 0) {
      return false;
    }
    if (expression.hasDeepWildcard()) {
      return this._matchWithDeepWildcard(segments);
    }
    return this._matchSimple(segments);
  }
  /**
   * @private
   */
  _matchSimple(segments) {
    if (this.path.length !== segments.length) {
      return false;
    }
    for (let i = 0; i < segments.length; i++) {
      if (!this._matchSegment(segments[i], this.path[i], i === this.path.length - 1)) {
        return false;
      }
    }
    return true;
  }
  /**
   * @private
   */
  _matchWithDeepWildcard(segments) {
    let pathIdx = this.path.length - 1;
    let segIdx = segments.length - 1;
    while (segIdx >= 0 && pathIdx >= 0) {
      const segment = segments[segIdx];
      if (segment.type === "deep-wildcard") {
        segIdx--;
        if (segIdx < 0) {
          return true;
        }
        const nextSeg = segments[segIdx];
        let found = false;
        for (let i = pathIdx; i >= 0; i--) {
          if (this._matchSegment(nextSeg, this.path[i], i === this.path.length - 1)) {
            pathIdx = i - 1;
            segIdx--;
            found = true;
            break;
          }
        }
        if (!found) {
          return false;
        }
      } else {
        if (!this._matchSegment(segment, this.path[pathIdx], pathIdx === this.path.length - 1)) {
          return false;
        }
        pathIdx--;
        segIdx--;
      }
    }
    return segIdx < 0;
  }
  /**
   * @private
   */
  _matchSegment(segment, node, isCurrentNode) {
    if (segment.tag !== "*" && segment.tag !== node.tag) {
      return false;
    }
    if (segment.namespace !== void 0) {
      if (segment.namespace !== "*" && segment.namespace !== node.namespace) {
        return false;
      }
    }
    if (segment.attrName !== void 0) {
      if (!isCurrentNode) {
        return false;
      }
      if (!node.values || !(segment.attrName in node.values)) {
        return false;
      }
      if (segment.attrValue !== void 0) {
        if (String(node.values[segment.attrName]) !== String(segment.attrValue)) {
          return false;
        }
      }
    }
    if (segment.position !== void 0) {
      if (!isCurrentNode) {
        return false;
      }
      const counter = node.counter ?? 0;
      if (segment.position === "first" && counter !== 0) {
        return false;
      } else if (segment.position === "odd" && counter % 2 !== 1) {
        return false;
      } else if (segment.position === "even" && counter % 2 !== 0) {
        return false;
      } else if (segment.position === "nth" && counter !== segment.positionValue) {
        return false;
      }
    }
    return true;
  }
  /**
   * Match any expression in the given set against the current path.
   * @param {ExpressionSet} exprSet
   * @returns {boolean}
   */
  matchesAny(exprSet) {
    return exprSet.matchesAny(this);
  }
  /**
   * Create a snapshot of current state.
   * @returns {Object}
   */
  snapshot() {
    return {
      path: this.path.map((node) => ({ ...node })),
      siblingStacks: this.siblingStacks.map((level) => level ? { counts: new Map(level.counts), total: level.total } : level),
      keptAttrs: this._keptAttrs.map((entry) => ({ ...entry }))
    };
  }
  /**
   * Restore state from snapshot.
   * @param {Object} snapshot
   */
  restore(snapshot) {
    this._pathStringCache = null;
    this.path = snapshot.path.map((node) => ({ ...node }));
    this.siblingStacks = snapshot.siblingStacks.map((level) => level ? { counts: new Map(level.counts), total: level.total } : level);
    this._keptAttrs = (snapshot.keptAttrs || []).map((entry) => ({ ...entry }));
  }
  /**
   * Return the read-only {@link MatcherView} for this matcher.
   *
   * The same instance is returned on every call — no allocation occurs.
   * It always reflects the current parser state and is safe to pass to
   * user callbacks without risk of accidental mutation.
   *
   * @returns {MatcherView}
   *
   * @example
   * const view = matcher.readOnly();
   * // pass view to callbacks — it stays in sync automatically
   * view.matches(expr);       // ✓
   * view.getCurrentTag();     // ✓
   * // view.push(...)         // ✗ method does not exist — caught by TypeScript
   */
  readOnly() {
    return this._view;
  }
};

// node_modules/is-unsafe/src/contexts/html.js
var HTML_PATTERNS = [
  {
    id: "html-script-open",
    description: "<script opening tag",
    pattern: /<script[\s>/]/i
  },
  {
    id: "html-script-close",
    description: "</script closing tag",
    pattern: /<\/script[\s>]/i
  },
  {
    id: "html-javascript-protocol",
    description: "javascript: URI scheme (with optional whitespace/encoding)",
    // Handles j&#x61;vascript:, j\u0061vascript:, and whitespace variants
    pattern: /j[\t\n\r ]*a[\t\n\r ]*v[\t\n\r ]*a[\t\n\r ]*s[\t\n\r ]*c[\t\n\r ]*r[\t\n\r ]*i[\t\n\r ]*p[\t\n\r ]*t[\t\n\r ]*:/i
  },
  {
    id: "html-vbscript-protocol",
    description: "vbscript: URI scheme",
    pattern: /vbscript[\t\n\r ]*:/i
  },
  {
    id: "html-data-html",
    description: "data:text/html URI \u2014 can execute scripts in browsers",
    pattern: /data[\t\n\r ]*:[\t\n\r ]*text\/html/i
  },
  {
    id: "html-data-xhtml",
    description: "data:application/xhtml+xml URI",
    pattern: /data[\t\n\r ]*:[\t\n\r ]*application\/xhtml/i
  },
  {
    id: "html-data-svg",
    description: "data:image/svg+xml URI \u2014 can execute scripts",
    pattern: /data[\t\n\r ]*:[\t\n\r ]*image\/svg\+xml/i
  },
  {
    id: "html-inline-event-handler",
    description: "Inline event handler attributes: onclick=, onerror=, onload=, etc.",
    // \bon ensures we match a word boundary so "phonetic=" is not caught
    pattern: /\bon\w{1,30}\s*=/i
  },
  {
    id: "html-entity-obfuscated-script",
    description: "HTML-entity-encoded <script (e.g. &#x3C;script or &lt;script)",
    // Entities include optional trailing semicolon: &#x3C; or &#x3C (both valid in HTML5)
    pattern: /(?:&#x0*3[Cc];?|&#0*60;?|&lt;)\s*script/i
  },
  {
    id: "html-entity-obfuscated-javascript",
    description: 'HTML-entity-encoded javascript: (partial \u2014 catches common &#106; or &#x6a; for "j")',
    pattern: /(?:&#x0*6[Aa];?|&#0*106;?)\s*(?:&#x0*61;?|a)[\s\S]{0,80}script\s*:/i
  },
  {
    id: "html-style-expression",
    description: "CSS expression() \u2014 IE-era code execution in style attributes",
    pattern: /style[\s\S]{0,20}expression\s*\(/i
  },
  {
    id: "html-object-embed",
    description: "<object or <embed tags that can load active content",
    pattern: /<(?:object|embed)[\s>/]/i
  },
  {
    id: "html-base-tag",
    description: "<base href= \u2014 can hijack all relative URLs on a page",
    pattern: /<base[\s>]/i
  },
  {
    id: "html-meta-refresh",
    description: '<meta http-equiv="refresh" \u2014 can redirect users',
    pattern: /<meta[\s\S]{0,40}http-equiv[\s\S]{0,20}refresh/i
  },
  {
    id: "html-srcdoc",
    description: "srcdoc= attribute on iframes \u2014 embeds HTML that can run scripts",
    pattern: /srcdoc\s*=/i
  },
  {
    id: "html-iframe",
    description: "<iframe tag",
    pattern: /<iframe[\s>/]/i
  },
  {
    id: "html-form",
    description: "<form tag \u2014 can be used for phishing / credential harvesting injection",
    pattern: /<form[\s>/]/i
  }
];
var html_default = HTML_PATTERNS;

// node_modules/is-unsafe/src/contexts/xml.js
var XML_PATTERNS = [
  {
    id: "xml-cdata-injection",
    description: "CDATA section injection: <![CDATA[ breaks out of text node context",
    pattern: /<!\[CDATA\[/i
  },
  {
    id: "xml-cdata-close",
    description: "CDATA close sequence: ]]> can terminate an enclosing CDATA section",
    pattern: /\]\]>/
  },
  {
    id: "xml-processing-instruction",
    description: "XML processing instruction: <?xml-stylesheet or <?php etc.",
    pattern: /<\?(?:xml[\- ]|php|asp)/i
  },
  {
    id: "xml-doctype-injection",
    description: "DOCTYPE declaration embedded in content \u2014 can define entities",
    // Match <!DOCTYPE followed by end-of-string, whitespace, or [ (internal subset)
    pattern: /<!DOCTYPE(?:[\s[]|$)/i
  },
  {
    id: "xml-entity-system",
    description: "SYSTEM keyword \u2014 used in external entity declarations (XXE)",
    pattern: /\bSYSTEM\s+["']/i
  },
  {
    id: "xml-entity-public",
    description: "PUBLIC keyword \u2014 used in external entity declarations (XXE)",
    pattern: /\bPUBLIC\s+["']/i
  },
  {
    id: "xml-entity-declaration",
    description: "<!ENTITY declaration \u2014 defines entities, potential XXE or entity expansion",
    pattern: /<!ENTITY[\s%]/i
  },
  {
    id: "xml-billion-laughs",
    description: "Entity reference chaining / billion laughs: repeated &eX; style references",
    // Heuristic: 3+ consecutive entity refs suggests expansion attack
    pattern: /(?:&\w{1,20};){3,}/
  },
  {
    id: "xml-namespace-confusion",
    description: "xmlns: attribute injection \u2014 can redefine namespaces to confuse parsers",
    pattern: /\bxmlns\s*(?::\w{1,40})?\s*=/i
  },
  {
    id: "xml-comment-injection",
    description: "<!-- comment injection \u2014 can hide content from some parsers",
    pattern: /<!--/
  },
  {
    id: "xml-comment-close",
    description: "--> closes an enclosing XML comment",
    pattern: /-->/
  },
  {
    id: "xml-pi-close",
    description: "?> closes an enclosing processing instruction",
    pattern: /\?>/
  }
];
var xml_default = XML_PATTERNS;

// node_modules/is-unsafe/src/contexts/svg.js
var SVG_PATTERNS = [
  {
    id: "svg-script-element",
    description: "<script element inside SVG executes JavaScript",
    pattern: /<script[\s>/]/i
  },
  {
    id: "svg-xlink-href-javascript",
    description: "xlink:href with javascript: \u2014 classic SVG XSS via <a> or <use>",
    pattern: /xlink\s*:\s*href\s*=\s*["']?\s*javascript\s*:/i
  },
  {
    id: "svg-href-javascript",
    description: "href= with javascript: in SVG context (<a>, <animate>, etc.)",
    pattern: /href\s*=\s*["']?\s*javascript\s*:/i
  },
  {
    id: "svg-foreignobject",
    description: "<foreignObject embeds HTML inside SVG \u2014 can execute scripts",
    pattern: /<foreignObject[\s>/]/i
  },
  {
    id: "svg-use-external",
    description: "<use xlink:href or href pointing to external resource (non-fragment URL)",
    // Match <use with href= where the value starts with a non-# character (external URL)
    // [\"'][^#] catches quoted values not starting with #; [^\"'#\s>] catches unquoted
    pattern: /<use[\s\S]{0,60}(?:xlink\s*:\s*)?href\s*=\s*(?:["'][^#]|[^"'#\s>])/i
  },
  {
    id: "svg-animate-href",
    description: '<animate attributeName="href" \u2014 can dynamically change href to javascript:',
    pattern: /<animate[\s\S]{0,80}attributeName\s*=\s*["'][\s]*href["']/i
  },
  {
    id: "svg-animate-xlinkhref",
    description: '<animate attributeName="xlink:href"',
    pattern: /<animate[\s\S]{0,80}attributeName\s*=\s*["'][\s]*xlink\s*:\s*href["']/i
  },
  {
    id: "svg-set-javascript",
    description: '<set to="javascript:..." \u2014 sets an attribute to a javascript: URI',
    pattern: /<set[\s\S]{0,80}to\s*=\s*["']?\s*javascript\s*:/i
  },
  {
    id: "svg-event-handler",
    description: "SVG-specific event handler attributes: onload=, onerror=, onactivate=, etc.",
    pattern: /\bon(?:load|error|activate|begin|end|repeat|focus|blur|click|mouse\w{1,20}|key\w{1,20})\s*=/i
  },
  {
    id: "svg-handler-generic",
    description: "Generic on* handler catch-all for SVG attributes",
    pattern: /\bon\w{1,30}\s*=/i
  },
  {
    id: "svg-filter-feimage",
    description: "<feImage href= \u2014 filter primitive that can load external resources",
    pattern: /<feImage[\s\S]{0,80}(?:xlink\s*:\s*)?href\s*=/i
  },
  {
    id: "svg-image-external",
    description: "<image xlink:href with http/https or javascript protocol",
    pattern: /<image[\s\S]{0,80}(?:xlink\s*:\s*)?href\s*=\s*["']?\s*(?:https?|javascript)\s*:/i
  },
  {
    id: "svg-style-javascript",
    description: "style= attribute containing javascript: (e.g. background:url(javascript:...))",
    pattern: /style\s*=[\s\S]{0,60}javascript\s*:/i
  }
];
var svg_default = SVG_PATTERNS;

// node_modules/is-unsafe/src/contexts/sql.js
var SQL_PATTERNS = [
  {
    id: "sql-block-comment-open",
    description: "SQL block comment open: /* ... */ \u2014 unusual in legitimate user text",
    pattern: /\/\*/
  },
  {
    id: "sql-union-select",
    description: "UNION SELECT \u2014 most common SQL injection aggregation attack",
    pattern: /\bUNION\s{1,20}(?:ALL\s{1,20})?SELECT\b/i
  },
  {
    id: "sql-drop-table",
    description: "DROP TABLE \u2014 destructive DDL injection",
    pattern: /\bDROP\s{1,20}TABLE\b/i
  },
  {
    id: "sql-drop-database",
    description: "DROP DATABASE \u2014 destructive DDL injection",
    pattern: /\bDROP\s{1,20}DATABASE\b/i
  },
  {
    id: "sql-insert-into",
    description: "INSERT INTO \u2014 data injection",
    pattern: /\bINSERT\s{1,20}INTO\b/i
  },
  {
    id: "sql-delete-from",
    description: "DELETE FROM \u2014 data deletion injection",
    pattern: /\bDELETE\s{1,20}FROM\b/i
  },
  {
    id: "sql-update-set",
    description: "UPDATE ... SET \u2014 data modification injection",
    // Allows arbitrary content between UPDATE and SET (table name, alias, etc.)
    pattern: /\bUPDATE\b[\s\S]{1,60}\bSET\b/i
  },
  {
    id: "sql-exec-xp",
    description: "EXEC xp_ \u2014 MSSQL extended stored procedure execution",
    pattern: /\bEXEC(?:UTE)?\s{1,20}xp_/i
  },
  {
    id: "sql-tautology-string",
    description: `Classic string tautology: ' OR '1'='1 or " OR "1"="1"`,
    // Last quote is optional — injection may truncate it: ' OR '1'='1--
    pattern: /'\s{0,10}OR\s{0,10}'[^']{0,20}'\s*=\s*'[^']{0,20}/i
  },
  {
    id: "sql-tautology-numeric",
    description: "Numeric tautology: OR 1=1",
    pattern: /\bOR\s{1,10}1\s*=\s*1\b/i
  },
  {
    id: "sql-always-true-zero",
    description: "Numeric tautology: OR 0=0",
    pattern: /\bOR\s{1,10}0\s*=\s*0\b/i
  },
  {
    id: "sql-sleep-benchmark",
    description: "Time-based blind injection: SLEEP() or BENCHMARK()",
    pattern: /\b(?:SLEEP|BENCHMARK)\s*\(/i
  },
  {
    id: "sql-waitfor-delay",
    description: "MSSQL time-based blind injection: WAITFOR DELAY",
    pattern: /\bWAITFOR\s{1,20}DELAY\b/i
  },
  {
    id: "sql-char-function",
    description: "CHAR() function \u2014 used to obfuscate injected strings",
    pattern: /\bCHAR\s*\(\s*\d{1,3}/i
  },
  {
    id: "sql-information-schema",
    description: "INFORMATION_SCHEMA \u2014 reconnaissance query for table/column enumeration",
    pattern: /\bINFORMATION_SCHEMA\b/i
  }
];
var sql_default = SQL_PATTERNS;

// node_modules/is-unsafe/src/contexts/shell.js
var SHELL_PATTERNS = [
  {
    id: "shell-path-traversal-unix",
    description: "Unix path traversal: ../  \u2014 climbing the directory tree",
    pattern: /\.\.\//
  },
  {
    id: "shell-path-traversal-windows",
    description: "Windows path traversal: ..\\ \u2014 climbing the directory tree",
    pattern: /\.\.\\/
  },
  {
    id: "shell-path-traversal-encoded",
    description: "URL-encoded path traversal: %2e%2e or %2f variants",
    pattern: /%2e%2e|%2f\.\.|\.\.%2f/i
  },
  {
    id: "shell-null-byte",
    description: "Null byte injection: \\x00 or %00 \u2014 truncates strings in C-backed functions",
    pattern: /\x00|%00/
  },
  {
    id: "shell-semicolon",
    description: "Semicolon command separator: cmd1; cmd2",
    pattern: /;/
  },
  {
    id: "shell-pipe",
    description: "Pipe operator: cmd1 | cmd2",
    pattern: /\|/
  },
  {
    id: "shell-and-operator",
    description: "AND operator: cmd1 && cmd2",
    pattern: /&&/
  },
  {
    id: "shell-or-operator",
    description: "OR operator: cmd1 || cmd2",
    pattern: /\|\|/
  },
  {
    id: "shell-backtick",
    description: "Backtick command substitution: `cmd`",
    pattern: /`/
  },
  {
    id: "shell-dollar-paren",
    description: "Dollar-paren command substitution: $(cmd)",
    pattern: /\$\(/
  },
  {
    id: "shell-dollar-brace",
    description: "Dollar-brace variable expansion: ${var} \u2014 can be abused for injection",
    pattern: /\$\{/
  },
  {
    id: "shell-redirect-out",
    description: "Output redirection: cmd > file or cmd >> file",
    pattern: />{1,2}/
  },
  {
    id: "shell-redirect-in",
    description: "Input redirection: cmd < file",
    pattern: /</
  },
  {
    id: "shell-newline-injection",
    description: "Newline injection: \\n or \\r \u2014 can inject new shell commands",
    pattern: /[\n\r]/
  },
  {
    id: "shell-glob-star",
    description: "Glob expansion: * or ? \u2014 can expand to unintended files",
    // Only flag when combined with path separators to reduce false positives
    pattern: /[/\\][*?]/
  },
  {
    id: "shell-absolute-root",
    description: "Absolute root path injection: string starting with / or \\ (Windows UNC)",
    pattern: /^(?:\/|\\\\)/
  },
  {
    id: "shell-windows-drive",
    description: "Windows drive letter path injection: C:\\ or D:/",
    pattern: /^[a-zA-Z]:[/\\]/
  },
  {
    id: "shell-curl-wget",
    description: "curl/wget with URL or flags \u2014 can exfiltrate data or download payloads",
    // Require a URL scheme (http/https/ftp) or a flag (-) to reduce false positives
    // "curl is a tool" won't match; "curl http://..." or "curl -s ..." will
    pattern: /\b(?:curl|wget)\s+(?:https?:\/\/|ftp:\/\/|-)/i
  }
];
var shell_default = SHELL_PATTERNS;

// node_modules/is-unsafe/src/contexts/redos.js
var REDOS_PATTERNS = [
  {
    id: "redos-nested-quantifier-plus",
    description: "Nested + quantifier inside a group with outer quantifier: (a+)+, (.+b)*, etc.",
    // Matches any group containing a + quantifier, with an outer * or + — catches (a+)+, (.+b)*, etc.
    pattern: /\([^)]*\+[^)]*\)[+*]/
  },
  {
    id: "redos-nested-quantifier-star",
    description: "Nested * quantifier: (a*)* or (a*)+ \u2014 catastrophic backtracking",
    pattern: /\([^)]*\*[^)]*\)[*+]/
  },
  {
    id: "redos-nested-groups",
    description: "Doubly nested quantified groups: ((a+)+) \u2014 guaranteed catastrophic",
    pattern: /\(\([^)]{0,40}\)[+*]\)[+*]/
  },
  {
    id: "redos-alternation-overlap",
    description: "Overlapping alternation under quantifier: (a|a)+ \u2014 ambiguous NFA paths",
    // Detect repeated identical alternatives under a quantifier
    pattern: /\(([^|()]{1,20})\|(?:\1)(?:\|[^|()]{1,20}){0,5}\)[+*?]{1,2}/
  },
  {
    id: "redos-star-plus-concat",
    description: "(x*x)+ pattern \u2014 triggers super-linear backtracking",
    pattern: /\([^)]{0,10}\*[^)]{0,10}\)[+*]/
  },
  {
    id: "redos-dot-star-greedy",
    description: "(.*){n,} or (.+){n,} \u2014 repeated greedy dot quantifiers",
    pattern: /\(\.[*+]\)\{?\d/
  },
  {
    id: "redos-large-repetition",
    description: "Very large fixed or range repetition count {1000,} or {1000,n} \u2014 denial of service via backtracking",
    // Matches { followed by 4+ digits (≥1000), then optional ,digits }
    pattern: /\{\d{4,}(?:,\d*)?\}/
  },
  {
    id: "redos-catastrophic-alternation",
    description: "Long alternation with many similar branches \u2014 polynomial backtracking risk",
    // Heuristic: 10+ pipe-separated alternatives in a single group
    pattern: /\([^)]{0,200}(?:\|[^|)]{0,50}){9,}\)/
  }
];
var redos_default = REDOS_PATTERNS;

// node_modules/is-unsafe/src/contexts/nosql.js
var sep = `["'\\s]*:`;
var NOSQL_PATTERNS = [
  // ─── MongoDB $ operator injection ────────────────────────────────────────
  {
    id: "nosql-where-operator",
    description: "$where \u2014 executes arbitrary JavaScript server-side in MongoDB",
    pattern: new RegExp(`\\$where${sep}`, "i")
  },
  {
    id: "nosql-ne-operator",
    description: '$ne \u2014 "not equal" operator used to bypass equality checks',
    pattern: new RegExp(`\\$ne${sep}`, "i")
  },
  {
    id: "nosql-gt-operator",
    description: '$gt \u2014 "greater than" used to bypass password/value checks',
    pattern: new RegExp(`\\$gte?${sep}`, "i")
  },
  {
    id: "nosql-lt-operator",
    description: '$lt / $lte \u2014 "less than" bypass variants',
    pattern: new RegExp(`\\$lte?${sep}`, "i")
  },
  {
    id: "nosql-regex-operator",
    description: "$regex \u2014 can be used to extract data character by character (blind injection)",
    pattern: new RegExp(`\\$regex${sep}`, "i")
  },
  {
    id: "nosql-or-operator",
    description: "$or \u2014 logical OR; used to create always-true conditions",
    pattern: new RegExp(`\\$or${sep}\\s*\\[`, "i")
  },
  {
    id: "nosql-and-operator",
    description: "$and \u2014 logical AND operator injection",
    pattern: new RegExp(`\\$and${sep}\\s*\\[`, "i")
  },
  {
    id: "nosql-nor-operator",
    description: "$nor \u2014 logical NOR operator injection",
    pattern: new RegExp(`\\$nor${sep}\\s*\\[`, "i")
  },
  {
    id: "nosql-exists-operator",
    description: "$exists \u2014 can enumerate fields to determine schema",
    pattern: new RegExp(`\\$exists${sep}`, "i")
  },
  {
    id: "nosql-in-operator",
    description: "$in \u2014 matches any value in a list; can enumerate values",
    pattern: new RegExp(`\\$in${sep}\\s*\\[`, "i")
  },
  {
    id: "nosql-expr-operator",
    description: "$expr \u2014 allows aggregation expressions in queries (MongoDB 3.6+)",
    pattern: new RegExp(`\\$expr${sep}`, "i")
  },
  {
    id: "nosql-function-operator",
    description: "$function \u2014 executes arbitrary JavaScript in MongoDB 4.4+",
    pattern: new RegExp(`\\$function${sep}`, "i")
  },
  {
    id: "nosql-accumulator-operator",
    description: "$accumulator \u2014 custom aggregation with arbitrary JS execution",
    pattern: new RegExp(`\\$accumulator${sep}`, "i")
  },
  // ─── Prototype pollution ─────────────────────────────────────────────────
  {
    id: "nosql-proto-pollution",
    description: "__proto__ \u2014 prototype pollution via object key injection",
    pattern: /__proto__/
  },
  {
    id: "nosql-constructor-prototype",
    description: "constructor.prototype \u2014 alternative prototype pollution vector (dot notation or JSON key)",
    // Matches dot-notation (obj.constructor.prototype) and JSON key adjacency
    // ("constructor": {"prototype": ...})
    pattern: /constructor[\s"':.,{\[]*prototype/i
  },
  {
    id: "nosql-proto-bracket",
    description: '["__proto__"] \u2014 bracket-notation prototype pollution',
    pattern: /\[["']__proto__["']\]/
  }
];
var nosql_default = NOSQL_PATTERNS;

// node_modules/is-unsafe/src/contexts/log.js
var LOG_PATTERNS = [
  // ─── CRLF / newline injection ─────────────────────────────────────────────
  {
    id: "log-crlf-injection",
    description: "CRLF injection: literal \\r or \\n embeds fake log lines",
    pattern: /[\r\n]/
  },
  {
    id: "log-url-encoded-crlf",
    description: "URL-encoded CRLF: %0d, %0a, %0D, %0A \u2014 decoded by some log parsers",
    pattern: /%0[dDaA]/
  },
  {
    id: "log-unicode-newline",
    description: "Unicode newline variants: U+2028 (line separator), U+2029 (paragraph separator)",
    pattern: /[\u2028\u2029]/
  },
  // ─── Log4Shell / JNDI injection (CVE-2021-44228) ─────────────────────────
  {
    id: "log-log4shell-jndi",
    description: "Log4Shell: ${jndi:...} triggers remote code execution in Apache Log4j",
    pattern: /\$\{jndi\s*:/i
  },
  {
    id: "log-log4shell-obfuscated",
    description: "Obfuscated Log4Shell: ${::-j}... lookup-bypass prefix used to evade WAF detection",
    // ${::- is the Log4j lookup-bypass escape sequence; presence alone is suspicious
    pattern: /\$\{::-/
  },
  {
    id: "log-log4j-lookup",
    description: "Log4j lookup syntax: ${env:...}, ${sys:...}, ${ctx:...} \u2014 data exfiltration",
    pattern: /\$\{(?:env|sys|ctx|main|map|sd|web|docker|k8s|spring)\s*:/i
  },
  // ─── Server-Side Template Injection (SSTI) in log messages ───────────────
  {
    id: "log-ssti-double-brace",
    description: "SSTI double-brace: {{expression}} \u2014 Jinja2, Twig, Handlebars, etc.",
    pattern: /\{\{[\s\S]{0,80}\}\}/
  },
  {
    id: "log-ssti-hash-brace",
    description: "SSTI hash-brace: #{expression} \u2014 Thymeleaf, Velocity, Ruby ERB",
    pattern: /#\{[\s\S]{0,80}\}/
  },
  {
    id: "log-ssti-dollar-brace",
    description: "SSTI/EL injection: ${expression with operators or method calls} \u2014 JSP EL, Freemarker, SpEL",
    // Require that the ${...} content looks like an expression, not a plain variable name.
    // Flags if the content contains: . ( * + operators, or known SSTI keywords.
    // This avoids flagging ${PATH}, ${HOME} etc. (plain shell variables).
    pattern: /\$\{[^}]*(?:\.|\(|\*|\+|\bclass\b|\bruntime\b|\bprocess\b|\bexec\b)[^}]{0,80}\}/i
  },
  {
    id: "log-ssti-percent-tag",
    description: "SSTI ERB/ASP tag: <%= expression %> \u2014 Ruby ERB, ASP",
    pattern: /<%=[\s\S]{0,80}%>/
  },
  // ─── Null byte ────────────────────────────────────────────────────────────
  {
    id: "log-null-byte",
    description: "Null byte: \\x00 or %00 \u2014 can truncate log entries in C-backed loggers",
    pattern: /\x00|%00/
  },
  // ─── ANSI escape injection ────────────────────────────────────────────────
  {
    id: "log-ansi-escape",
    description: "ANSI escape sequence: ESC[ \u2014 can manipulate terminal output when logs are tailed",
    pattern: /\x1b\[/
  }
];
var log_default = LOG_PATTERNS;

// node_modules/is-unsafe/src/contexts/sql-strict.js
var SQL_STRICT_EXTRA = [
  {
    id: "sql-line-comment",
    description: "SQL line comment: -- followed by whitespace or end of string",
    pattern: /--(?:\s|$)/
  },
  {
    id: "sql-stacked-query",
    description: "Stacked queries: semicolon immediately followed by a SQL keyword",
    pattern: /;\s{0,10}(?:SELECT|INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|EXEC)\b/i
  },
  {
    id: "sql-hex-encoding",
    description: "Hex-encoded string injection: 0x41414141 style (MySQL)",
    pattern: /\b0x[0-9a-f]{4,}/i
  }
];
var SQL_STRICT_PATTERNS = [...sql_default, ...SQL_STRICT_EXTRA];
var sql_strict_default = SQL_STRICT_PATTERNS;

// node_modules/is-unsafe/src/index.js
html_default.label = "HTML";
xml_default.label = "XML";
svg_default.label = "SVG";
sql_default.label = "SQL";
sql_strict_default.label = "SQL-STRICT";
shell_default.label = "SHELL";
redos_default.label = "REDOS";
nosql_default.label = "NOSQL";
log_default.label = "LOG";
var VALID_CONTEXTS = Object.freeze({
  HTML: html_default,
  XML: xml_default,
  SVG: svg_default,
  SQL: sql_default,
  "SQL-STRICT": sql_strict_default,
  SHELL: shell_default,
  REDOS: redos_default,
  NOSQL: nosql_default,
  LOG: log_default
});
function assertString(value) {
  if (typeof value !== "string") {
    throw new TypeError(
      `is-unsafe: first argument must be a string, got ${typeof value}`
    );
  }
}
function assertContext(context) {
  if (context instanceof RegExp) return;
  if (Array.isArray(context)) {
    if (context.length === 0) {
      throw new TypeError("is-unsafe: context must not be an empty array");
    }
    if (Array.isArray(context[0])) {
      for (const list of context) {
        if (!Array.isArray(list) || list.length === 0) {
          throw new TypeError(
            "is-unsafe: each context in the array must be a non-empty pattern array (PatternList)"
          );
        }
      }
    }
    return;
  }
  throw new TypeError(
    `is-unsafe: second argument must be a PatternList (e.g. HTML), an array of PatternLists (e.g. [HTML, XML]), or a RegExp. Got: ${typeof context}`
  );
}
function normalise(context) {
  if (context instanceof RegExp) return { lists: null, regex: context };
  if (Array.isArray(context[0])) return { lists: context, regex: null };
  return { lists: [context], regex: null };
}
function matchList(value, list) {
  const label = list.label ?? "CUSTOM";
  for (const rule of list) {
    if (rule.pattern.test(value)) {
      return { context: label, id: rule.id, description: rule.description, pattern: rule.pattern };
    }
  }
  return null;
}
function isUnsafe(value, context) {
  assertString(value);
  assertContext(context);
  const { lists, regex } = normalise(context);
  if (regex) return regex.test(value);
  for (const list of lists) {
    if (matchList(value, list) !== null) return true;
  }
  return false;
}

// node_modules/fast-xml-parser/src/xmlparser/OrderedObjParser.js
function extractRawAttributes(prefixedAttrs, options) {
  if (!prefixedAttrs) return {};
  const attrs = options.attributesGroupName ? prefixedAttrs[options.attributesGroupName] : prefixedAttrs;
  if (!attrs) return {};
  const rawAttrs = {};
  for (const key in attrs) {
    if (key.startsWith(options.attributeNamePrefix)) {
      const rawName = key.substring(options.attributeNamePrefix.length);
      rawAttrs[rawName] = attrs[key];
    } else {
      rawAttrs[key] = attrs[key];
    }
  }
  return rawAttrs;
}
function extractNamespace(rawTagName) {
  if (!rawTagName || typeof rawTagName !== "string") return void 0;
  const colonIndex = rawTagName.indexOf(":");
  if (colonIndex !== -1 && colonIndex > 0) {
    const ns = rawTagName.substring(0, colonIndex);
    if (ns !== "xmlns") {
      return ns;
    }
  }
  return void 0;
}
var OrderedObjParser = class {
  constructor(options, externalEntities) {
    this.options = options;
    this.currentNode = null;
    this.tagsNodeStack = [];
    this.parseXml = parseXml;
    this.parseTextData = parseTextData;
    this.resolveNameSpace = resolveNameSpace;
    this.buildAttributesMap = buildAttributesMap;
    this.isItStopNode = isItStopNode;
    this.replaceEntitiesValue = replaceEntitiesValue;
    this.readStopNodeData = readStopNodeData;
    this.saveTextToParentTag = saveTextToParentTag;
    this.addChild = addChild;
    this.ignoreAttributesFn = getIgnoreAttributesFn(this.options.ignoreAttributes);
    this.entityExpansionCount = 0;
    this.currentExpandedLength = 0;
    this.doctypefound = false;
    let namedEntities = { ...XML };
    if (this.options.entityDecoder) {
      this.entityDecoder = this.options.entityDecoder;
    } else {
      if (typeof this.options.htmlEntities === "object") namedEntities = this.options.htmlEntities;
      else if (this.options.htmlEntities === true) namedEntities = { ...COMMON_HTML, ...CURRENCY };
      this.entityDecoder = new EntityDecoder({
        namedEntities: { ...namedEntities, ...externalEntities },
        numericAllowed: this.options.htmlEntities,
        limit: {
          maxTotalExpansions: this.options.processEntities.maxTotalExpansions,
          maxExpandedLength: this.options.processEntities.maxExpandedLength,
          applyLimitsTo: this.options.processEntities.appliesTo
        },
        // onExternalEntity: (name, value) => isUnsafe(value) ? 'block' : 'allow',
        onInputEntity: (name, value) => (
          //TODO: VALID_CONTEXTS.HTML should be set only if this.options.htmlEntities
          isUnsafe(value, [html_default, xml_default]) ? ENTITY_ACTION.BLOCK : ENTITY_ACTION.ALLOW
        )
        //postCheck: resolved => resolved
      });
    }
    this.matcher = new Matcher();
    this.readonlyMatcher = this.matcher.readOnly();
    this.isCurrentNodeStopNode = false;
    this.stopNodeExpressionsSet = new ExpressionSet();
    const stopNodesOpts = this.options.stopNodes;
    if (stopNodesOpts && stopNodesOpts.length > 0) {
      for (let i = 0; i < stopNodesOpts.length; i++) {
        const stopNodeExp = stopNodesOpts[i];
        if (typeof stopNodeExp === "string") {
          this.stopNodeExpressionsSet.add(new Expression(stopNodeExp));
        } else if (stopNodeExp instanceof Expression) {
          this.stopNodeExpressionsSet.add(stopNodeExp);
        }
      }
      this.stopNodeExpressionsSet.seal();
    }
  }
};
function parseTextData(val, tagName, jPath, dontTrim, hasAttributes, isLeafNode, escapeEntities) {
  const options = this.options;
  if (val !== void 0) {
    if (options.trimValues && !dontTrim) {
      val = val.trim();
    }
    if (val.length > 0) {
      if (!escapeEntities) val = this.replaceEntitiesValue(val, tagName, jPath);
      const jPathOrMatcher = options.jPath ? jPath.toString() : jPath;
      const newval = options.tagValueProcessor(tagName, val, jPathOrMatcher, hasAttributes, isLeafNode);
      if (newval === null || newval === void 0) {
        return val;
      } else if (typeof newval !== typeof val || newval !== val) {
        return newval;
      } else if (options.trimValues) {
        return parseValue(val, options.parseTagValue, options.numberParseOptions);
      } else {
        const trimmedVal = val.trim();
        if (trimmedVal === val) {
          return parseValue(val, options.parseTagValue, options.numberParseOptions);
        } else {
          return val;
        }
      }
    }
  }
}
function resolveNameSpace(tagname) {
  if (this.options.removeNSPrefix) {
    const tags = tagname.split(":");
    const prefix = tagname.charAt(0) === "/" ? "/" : "";
    if (tags[0] === "xmlns") {
      return "";
    }
    if (tags.length === 2) {
      tagname = prefix + tags[1];
    }
  }
  return tagname;
}
var attrsRegx = new RegExp(`([^\\s=]+)\\s*(=\\s*(['"])([\\s\\S]*?)\\3)?`, "gm");
function buildAttributesMap(attrStr, jPath, tagName, force = false) {
  const options = this.options;
  if (force === true || options.ignoreAttributes !== true && typeof attrStr === "string") {
    const matches = getAllMatches(attrStr, attrsRegx);
    const len = matches.length;
    const attrs = {};
    const processedVals = new Array(len);
    let hasRawAttrs = false;
    const rawAttrsForMatcher = {};
    for (let i = 0; i < len; i++) {
      const attrName = this.resolveNameSpace(matches[i][1]);
      const oldVal = matches[i][4];
      if (attrName.length && oldVal !== void 0) {
        let val = oldVal;
        if (options.trimValues) val = val.trim();
        val = this.replaceEntitiesValue(val, tagName, this.readonlyMatcher);
        processedVals[i] = val;
        rawAttrsForMatcher[attrName] = val;
        hasRawAttrs = true;
      }
    }
    if (hasRawAttrs && typeof jPath === "object" && jPath.updateCurrent) {
      jPath.updateCurrent(rawAttrsForMatcher);
    }
    const jPathStr = options.jPath ? jPath.toString() : this.readonlyMatcher;
    let hasAttrs = false;
    for (let i = 0; i < len; i++) {
      const attrName = this.resolveNameSpace(matches[i][1]);
      if (this.ignoreAttributesFn(attrName, jPathStr)) continue;
      let aName = options.attributeNamePrefix + attrName;
      if (attrName.length) {
        if (options.transformAttributeName) {
          aName = options.transformAttributeName(aName);
        }
        aName = sanitizeName(aName, options);
        if (matches[i][4] !== void 0) {
          const oldVal = processedVals[i];
          const newVal = options.attributeValueProcessor(attrName, oldVal, jPathStr);
          if (newVal === null || newVal === void 0) {
            attrs[aName] = oldVal;
          } else if (typeof newVal !== typeof oldVal || newVal !== oldVal) {
            attrs[aName] = newVal;
          } else {
            attrs[aName] = parseValue(oldVal, options.parseAttributeValue, options.numberParseOptions);
          }
          hasAttrs = true;
        } else if (options.allowBooleanAttributes) {
          attrs[aName] = true;
          hasAttrs = true;
        }
      }
    }
    if (!hasAttrs) return;
    if (options.attributesGroupName && !options.preserveOrder) {
      const attrCollection = {};
      attrCollection[options.attributesGroupName] = attrs;
      return attrCollection;
    }
    return attrs;
  }
}
var parseXml = function(xmlData) {
  xmlData = xmlData.replace(/\r\n?/g, "\n");
  const xmlObj = new XmlNode("!xml");
  let currentNode = xmlObj;
  let textData = "";
  this.matcher.reset();
  this.entityDecoder.reset();
  this.entityExpansionCount = 0;
  this.currentExpandedLength = 0;
  this.doctypefound = false;
  const options = this.options;
  const docTypeReader = new DocTypeReader(options.processEntities);
  const xmlLen = xmlData.length;
  for (let i = 0; i < xmlLen; i++) {
    const ch = xmlData[i];
    if (ch === "<") {
      const c1 = xmlData.charCodeAt(i + 1);
      if (c1 === 47) {
        const closeIndex = findClosingIndex(xmlData, ">", i, "Closing Tag is not closed.");
        let tagName = xmlData.substring(i + 2, closeIndex).trim();
        if (options.removeNSPrefix) {
          const colonIndex = tagName.indexOf(":");
          if (colonIndex !== -1) {
            tagName = tagName.substr(colonIndex + 1);
          }
        }
        tagName = transformTagName(options.transformTagName, tagName, "", options).tagName;
        if (currentNode) {
          textData = this.saveTextToParentTag(textData, currentNode, this.readonlyMatcher);
        }
        const lastTagName = this.matcher.getCurrentTag();
        if (tagName && options.unpairedTagsSet.has(tagName)) {
          throw new Error(`Unpaired tag can not be used as closing tag: </${tagName}>`);
        }
        if (lastTagName && options.unpairedTagsSet.has(lastTagName)) {
          this.matcher.pop();
          this.tagsNodeStack.pop();
        }
        this.matcher.pop();
        this.isCurrentNodeStopNode = false;
        currentNode = this.tagsNodeStack.pop();
        textData = "";
        i = closeIndex;
      } else if (c1 === 63) {
        let tagData = readTagExp(xmlData, i, false, "?>");
        if (!tagData) throw new Error("Pi Tag is not closed.");
        textData = this.saveTextToParentTag(textData, currentNode, this.readonlyMatcher);
        const attsMap = this.buildAttributesMap(tagData.tagExp, this.matcher, tagData.tagName, true);
        if (attsMap) {
          const ver = attsMap[this.options.attributeNamePrefix + "version"];
          this.entityDecoder.setXmlVersion(Number(ver) || 1);
          docTypeReader.setXmlVersion(Number(ver) || 1);
        }
        if (options.ignoreDeclaration && tagData.tagName === "?xml" || options.ignorePiTags) {
        } else {
          const childNode = new XmlNode(tagData.tagName);
          childNode.add(options.textNodeName, "");
          if (tagData.tagName !== tagData.tagExp && tagData.attrExpPresent && options.ignoreAttributes !== true) {
            childNode[":@"] = attsMap;
          }
          this.addChild(currentNode, childNode, this.readonlyMatcher, i);
        }
        i = tagData.closeIndex + 1;
      } else if (c1 === 33 && xmlData.charCodeAt(i + 2) === 45 && xmlData.charCodeAt(i + 3) === 45) {
        const endIndex = findClosingIndex(xmlData, "-->", i + 4, "Comment is not closed.");
        if (options.commentPropName) {
          const comment = xmlData.substring(i + 4, endIndex - 2);
          textData = this.saveTextToParentTag(textData, currentNode, this.readonlyMatcher);
          currentNode.add(options.commentPropName, [{ [options.textNodeName]: comment }]);
        }
        i = endIndex;
      } else if (c1 === 33 && xmlData.charCodeAt(i + 2) === 68) {
        if (this.doctypefound) throw new Error("Multiple DOCTYPE declarations found.");
        this.doctypefound = true;
        const result = docTypeReader.readDocType(xmlData, i);
        this.entityDecoder.addInputEntities(result.entities);
        i = result.i;
      } else if (c1 === 33 && xmlData.charCodeAt(i + 2) === 91) {
        const closeIndex = findClosingIndex(xmlData, "]]>", i, "CDATA is not closed.") - 2;
        const tagExp = xmlData.substring(i + 9, closeIndex);
        textData = this.saveTextToParentTag(textData, currentNode, this.readonlyMatcher);
        let val = this.parseTextData(tagExp, currentNode.tagname, this.readonlyMatcher, true, false, true, true);
        if (val == void 0) val = "";
        if (options.cdataPropName) {
          currentNode.add(options.cdataPropName, [{ [options.textNodeName]: tagExp }]);
        } else {
          currentNode.add(options.textNodeName, val);
        }
        i = closeIndex + 2;
      } else {
        let result = readTagExp(xmlData, i, options.removeNSPrefix);
        if (!result) {
          const context = xmlData.substring(Math.max(0, i - 50), Math.min(xmlLen, i + 50));
          throw new Error(`readTagExp returned undefined at position ${i}. Context: "${context}"`);
        }
        let tagName = result.tagName;
        const rawTagName = result.rawTagName;
        let tagExp = result.tagExp;
        let attrExpPresent = result.attrExpPresent;
        let closeIndex = result.closeIndex;
        ({ tagName, tagExp } = transformTagName(options.transformTagName, tagName, tagExp, options));
        if (options.strictReservedNames && (tagName === options.commentPropName || tagName === options.cdataPropName || tagName === options.textNodeName || tagName === options.attributesGroupName)) {
          throw new Error(`Invalid tag name: ${tagName}`);
        }
        if (currentNode && textData) {
          if (currentNode.tagname !== "!xml") {
            textData = this.saveTextToParentTag(textData, currentNode, this.readonlyMatcher, false);
          }
        }
        const lastTag = currentNode;
        if (lastTag && options.unpairedTagsSet.has(lastTag.tagname)) {
          currentNode = this.tagsNodeStack.pop();
          this.matcher.pop();
        }
        let isSelfClosing = false;
        if (tagExp.length > 0 && tagExp.lastIndexOf("/") === tagExp.length - 1) {
          isSelfClosing = true;
          if (tagName[tagName.length - 1] === "/") {
            tagName = tagName.substr(0, tagName.length - 1);
            tagExp = tagName;
          } else {
            tagExp = tagExp.substr(0, tagExp.length - 1);
          }
          attrExpPresent = tagName !== tagExp;
        }
        let prefixedAttrs = null;
        let rawAttrs = {};
        let namespace = void 0;
        namespace = extractNamespace(rawTagName);
        if (tagName !== xmlObj.tagname) {
          this.matcher.push(tagName, {}, namespace);
        }
        if (tagName !== tagExp && attrExpPresent) {
          prefixedAttrs = this.buildAttributesMap(tagExp, this.matcher, tagName);
          if (prefixedAttrs) {
            rawAttrs = extractRawAttributes(prefixedAttrs, options);
          }
        }
        if (tagName !== xmlObj.tagname) {
          this.isCurrentNodeStopNode = this.isItStopNode();
        }
        const startIndex = i;
        if (this.isCurrentNodeStopNode) {
          let tagContent = "";
          if (isSelfClosing) {
            i = result.closeIndex;
          } else if (options.unpairedTagsSet.has(tagName)) {
            i = result.closeIndex;
          } else {
            const result2 = this.readStopNodeData(xmlData, rawTagName, closeIndex + 1);
            if (!result2) throw new Error(`Unexpected end of ${rawTagName}`);
            i = result2.i;
            tagContent = result2.tagContent;
          }
          const childNode = new XmlNode(tagName);
          if (prefixedAttrs) {
            childNode[":@"] = prefixedAttrs;
          }
          childNode.add(options.textNodeName, tagContent);
          this.matcher.pop();
          this.isCurrentNodeStopNode = false;
          this.addChild(currentNode, childNode, this.readonlyMatcher, startIndex);
        } else {
          if (isSelfClosing) {
            ({ tagName, tagExp } = transformTagName(options.transformTagName, tagName, tagExp, options));
            const childNode = new XmlNode(tagName);
            if (prefixedAttrs) {
              childNode[":@"] = prefixedAttrs;
            }
            this.addChild(currentNode, childNode, this.readonlyMatcher, startIndex);
            this.matcher.pop();
            this.isCurrentNodeStopNode = false;
          } else if (options.unpairedTagsSet.has(tagName)) {
            const childNode = new XmlNode(tagName);
            if (prefixedAttrs) {
              childNode[":@"] = prefixedAttrs;
            }
            this.addChild(currentNode, childNode, this.readonlyMatcher, startIndex);
            this.matcher.pop();
            this.isCurrentNodeStopNode = false;
            i = result.closeIndex;
            continue;
          } else {
            const childNode = new XmlNode(tagName);
            if (this.tagsNodeStack.length > options.maxNestedTags) {
              throw new Error("Maximum nested tags exceeded");
            }
            this.tagsNodeStack.push(currentNode);
            if (prefixedAttrs) {
              childNode[":@"] = prefixedAttrs;
            }
            this.addChild(currentNode, childNode, this.readonlyMatcher, startIndex);
            currentNode = childNode;
          }
          textData = "";
          i = closeIndex;
        }
      }
    } else {
      textData += xmlData[i];
    }
  }
  return xmlObj.child;
};
function addChild(currentNode, childNode, matcher, startIndex) {
  if (!this.options.captureMetaData) startIndex = void 0;
  const jPathOrMatcher = this.options.jPath ? matcher.toString() : matcher;
  const result = this.options.updateTag(childNode.tagname, jPathOrMatcher, childNode[":@"]);
  if (result === false) {
  } else if (typeof result === "string") {
    childNode.tagname = result;
    currentNode.addChild(childNode, startIndex);
  } else {
    currentNode.addChild(childNode, startIndex);
  }
}
function replaceEntitiesValue(val, tagName, jPath) {
  const entityConfig = this.options.processEntities;
  if (!entityConfig || !entityConfig.enabled) {
    return val;
  }
  if (entityConfig.allowedTags) {
    const jPathOrMatcher = this.options.jPath ? jPath.toString() : jPath;
    const allowed = Array.isArray(entityConfig.allowedTags) ? entityConfig.allowedTags.includes(tagName) : entityConfig.allowedTags(tagName, jPathOrMatcher);
    if (!allowed) {
      return val;
    }
  }
  if (entityConfig.tagFilter) {
    const jPathOrMatcher = this.options.jPath ? jPath.toString() : jPath;
    if (!entityConfig.tagFilter(tagName, jPathOrMatcher)) {
      return val;
    }
  }
  return this.entityDecoder.decode(val);
}
function saveTextToParentTag(textData, parentNode, matcher, isLeafNode) {
  if (textData) {
    if (isLeafNode === void 0) isLeafNode = parentNode.child.length === 0;
    textData = this.parseTextData(
      textData,
      parentNode.tagname,
      matcher,
      false,
      parentNode[":@"] ? Object.keys(parentNode[":@"]).length !== 0 : false,
      isLeafNode
    );
    if (textData !== void 0 && textData !== "")
      parentNode.add(this.options.textNodeName, textData);
    textData = "";
  }
  return textData;
}
function isItStopNode() {
  if (this.stopNodeExpressionsSet.size === 0) return false;
  return this.matcher.matchesAny(this.stopNodeExpressionsSet);
}
function tagExpWithClosingIndex(xmlData, i, closingChar = ">") {
  let attrBoundary = 0;
  const len = xmlData.length;
  const closeCode0 = closingChar.charCodeAt(0);
  const closeCode1 = closingChar.length > 1 ? closingChar.charCodeAt(1) : -1;
  let result = "";
  let segmentStart = i;
  for (let index = i; index < len; index++) {
    const code = xmlData.charCodeAt(index);
    if (attrBoundary) {
      if (code === attrBoundary) attrBoundary = 0;
    } else if (code === 34 || code === 39) {
      attrBoundary = code;
    } else if (code === closeCode0) {
      if (closeCode1 !== -1) {
        if (xmlData.charCodeAt(index + 1) === closeCode1) {
          result += xmlData.substring(segmentStart, index);
          return { data: result, index };
        }
      } else {
        result += xmlData.substring(segmentStart, index);
        return { data: result, index };
      }
    } else if (code === 9 && !attrBoundary) {
      result += xmlData.substring(segmentStart, index) + " ";
      segmentStart = index + 1;
    }
  }
}
function findClosingIndex(xmlData, str, i, errMsg) {
  const closingIndex = xmlData.indexOf(str, i);
  if (closingIndex === -1) {
    throw new Error(errMsg);
  } else {
    return closingIndex + str.length - 1;
  }
}
function findClosingChar(xmlData, char, i, errMsg) {
  const closingIndex = xmlData.indexOf(char, i);
  if (closingIndex === -1) throw new Error(errMsg);
  return closingIndex;
}
function readTagExp(xmlData, i, removeNSPrefix, closingChar = ">") {
  const result = tagExpWithClosingIndex(xmlData, i + 1, closingChar);
  if (!result) return;
  let tagExp = result.data;
  const closeIndex = result.index;
  const separatorIndex = tagExp.search(/\s/);
  let tagName = tagExp;
  let attrExpPresent = true;
  if (separatorIndex !== -1) {
    tagName = tagExp.substring(0, separatorIndex);
    tagExp = tagExp.substring(separatorIndex + 1).trimStart();
  }
  const rawTagName = tagName;
  if (removeNSPrefix) {
    const colonIndex = tagName.indexOf(":");
    if (colonIndex !== -1) {
      tagName = tagName.substr(colonIndex + 1);
      attrExpPresent = tagName !== result.data.substr(colonIndex + 1);
    }
  }
  return {
    tagName,
    tagExp,
    closeIndex,
    attrExpPresent,
    rawTagName
  };
}
function readStopNodeData(xmlData, tagName, i) {
  const startIndex = i;
  let openTagCount = 1;
  const xmllen = xmlData.length;
  for (; i < xmllen; i++) {
    if (xmlData[i] === "<") {
      const c1 = xmlData.charCodeAt(i + 1);
      if (c1 === 47) {
        const closeIndex = findClosingChar(xmlData, ">", i, `${tagName} is not closed`);
        let closeTagName = xmlData.substring(i + 2, closeIndex).trim();
        if (closeTagName === tagName) {
          openTagCount--;
          if (openTagCount === 0) {
            return {
              tagContent: xmlData.substring(startIndex, i),
              i: closeIndex
            };
          }
        }
        i = closeIndex;
      } else if (c1 === 63) {
        const closeIndex = findClosingIndex(xmlData, "?>", i + 1, "StopNode is not closed.");
        i = closeIndex;
      } else if (c1 === 33 && xmlData.charCodeAt(i + 2) === 45 && xmlData.charCodeAt(i + 3) === 45) {
        const closeIndex = findClosingIndex(xmlData, "-->", i + 3, "StopNode is not closed.");
        i = closeIndex;
      } else if (c1 === 33 && xmlData.charCodeAt(i + 2) === 91) {
        const closeIndex = findClosingIndex(xmlData, "]]>", i, "StopNode is not closed.") - 2;
        i = closeIndex;
      } else {
        const tagData = readTagExp(xmlData, i, false);
        if (tagData) {
          const openTagName = tagData && tagData.tagName;
          if (openTagName === tagName && tagData.tagExp[tagData.tagExp.length - 1] !== "/") {
            openTagCount++;
          }
          i = tagData.closeIndex;
        }
      }
    }
  }
}
function parseValue(val, shouldParse, options) {
  if (shouldParse && typeof val === "string") {
    const newval = val.trim();
    if (newval === "true") return true;
    else if (newval === "false") return false;
    else return toNumber(val, options);
  } else {
    if (isExist(val)) {
      return val;
    } else {
      return "";
    }
  }
}
function transformTagName(fn, tagName, tagExp, options) {
  if (fn) {
    const newTagName = fn(tagName);
    if (tagExp === tagName) {
      tagExp = newTagName;
    }
    tagName = newTagName;
  }
  tagName = sanitizeName(tagName, options);
  return { tagName, tagExp };
}
function sanitizeName(name, options) {
  if (criticalProperties.includes(name)) {
    throw new Error(`[SECURITY] Invalid name: "${name}" is a reserved JavaScript keyword that could cause prototype pollution`);
  } else if (DANGEROUS_PROPERTY_NAMES.includes(name)) {
    return options.onDangerousProperty(name);
  }
  return name;
}

// node_modules/fast-xml-parser/src/xmlparser/node2json.js
var METADATA_SYMBOL2 = XmlNode.getMetaDataSymbol();
function stripAttributePrefix(attrs, prefix) {
  if (!attrs || typeof attrs !== "object") return {};
  if (!prefix) return attrs;
  const rawAttrs = {};
  for (const key in attrs) {
    if (key.startsWith(prefix)) {
      const rawName = key.substring(prefix.length);
      rawAttrs[rawName] = attrs[key];
    } else {
      rawAttrs[key] = attrs[key];
    }
  }
  return rawAttrs;
}
function prettify(node, options, matcher, readonlyMatcher) {
  return compress(node, options, matcher, readonlyMatcher);
}
function compress(arr3, options, matcher, readonlyMatcher) {
  let text;
  const compressedObj = {};
  for (let i = 0; i < arr3.length; i++) {
    const tagObj = arr3[i];
    const property = propName(tagObj);
    if (property !== void 0 && property !== options.textNodeName) {
      const rawAttrs = stripAttributePrefix(
        tagObj[":@"] || {},
        options.attributeNamePrefix
      );
      matcher.push(property, rawAttrs);
    }
    if (property === options.textNodeName) {
      if (text === void 0) text = tagObj[property];
      else text += "" + tagObj[property];
    } else if (property === void 0) {
      continue;
    } else if (tagObj[property]) {
      let val = compress(tagObj[property], options, matcher, readonlyMatcher);
      const isLeaf = isLeafTag(val, options);
      if (Object.keys(val).length === 0 && options.alwaysCreateTextNode) {
        val[options.textNodeName] = "";
      }
      if (tagObj[":@"]) {
        assignAttributes(val, tagObj[":@"], readonlyMatcher, options);
      } else if (Object.keys(val).length === 1 && val[options.textNodeName] !== void 0 && !options.alwaysCreateTextNode) {
        val = val[options.textNodeName];
      } else if (Object.keys(val).length === 0) {
        if (options.alwaysCreateTextNode) val[options.textNodeName] = "";
        else val = "";
      }
      if (tagObj[METADATA_SYMBOL2] !== void 0 && typeof val === "object" && val !== null) {
        val[METADATA_SYMBOL2] = tagObj[METADATA_SYMBOL2];
      }
      if (compressedObj[property] !== void 0 && Object.prototype.hasOwnProperty.call(compressedObj, property)) {
        if (!Array.isArray(compressedObj[property])) {
          compressedObj[property] = [compressedObj[property]];
        }
        compressedObj[property].push(val);
      } else {
        const jPathOrMatcher = options.jPath ? readonlyMatcher.toString() : readonlyMatcher;
        if (options.isArray(property, jPathOrMatcher, isLeaf)) {
          compressedObj[property] = [val];
        } else {
          compressedObj[property] = val;
        }
      }
      if (property !== void 0 && property !== options.textNodeName) {
        matcher.pop();
      }
    }
  }
  if (typeof text === "string") {
    if (text.length > 0) compressedObj[options.textNodeName] = text;
  } else if (text !== void 0) compressedObj[options.textNodeName] = text;
  return compressedObj;
}
function propName(obj) {
  const keys = Object.keys(obj);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    if (key !== ":@") return key;
  }
}
function assignAttributes(obj, attrMap, readonlyMatcher, options) {
  if (attrMap) {
    const keys = Object.keys(attrMap);
    const len = keys.length;
    for (let i = 0; i < len; i++) {
      const atrrName = keys[i];
      const rawAttrName = atrrName.startsWith(options.attributeNamePrefix) ? atrrName.substring(options.attributeNamePrefix.length) : atrrName;
      const jPathOrMatcher = options.jPath ? readonlyMatcher.toString() + "." + rawAttrName : readonlyMatcher;
      if (options.isArray(atrrName, jPathOrMatcher, true, true)) {
        obj[atrrName] = [attrMap[atrrName]];
      } else {
        obj[atrrName] = attrMap[atrrName];
      }
    }
  }
}
function isLeafTag(obj, options) {
  const { textNodeName } = options;
  const propCount = Object.keys(obj).length;
  if (propCount === 0) {
    return true;
  }
  if (propCount === 1 && (obj[textNodeName] || typeof obj[textNodeName] === "boolean" || obj[textNodeName] === 0)) {
    return true;
  }
  return false;
}

// node_modules/fast-xml-parser/src/xmlparser/XMLParser.js
var XMLParser = class {
  constructor(options) {
    this.externalEntities = {};
    this.options = buildOptions(options);
  }
  /**
   * Parse XML dats to JS object 
   * @param {string|Uint8Array} xmlData 
   * @param {boolean|Object} validationOption 
   */
  parse(xmlData, validationOption) {
    if (typeof xmlData !== "string" && xmlData.toString) {
      xmlData = xmlData.toString();
    } else if (typeof xmlData !== "string") {
      throw new Error("XML data is accepted in String or Bytes[] form.");
    }
    if (validationOption) {
      if (validationOption === true) validationOption = {};
      const result = validate(xmlData, validationOption);
      if (result !== true) {
        throw Error(`${result.err.msg}:${result.err.line}:${result.err.col}`);
      }
    }
    const orderedObjParser = new OrderedObjParser(this.options, this.externalEntities);
    const orderedResult = orderedObjParser.parseXml(xmlData);
    if (this.options.preserveOrder || orderedResult === void 0) return orderedResult;
    else return prettify(orderedResult, this.options, orderedObjParser.matcher, orderedObjParser.readonlyMatcher);
  }
  /**
   * Add Entity which is not by default supported by this library
   * @param {string} key 
   * @param {string} value 
   */
  addEntity(key, value) {
    if (value.indexOf("&") !== -1) {
      throw new Error("Entity value can't have '&'");
    } else if (key.indexOf("&") !== -1 || key.indexOf(";") !== -1) {
      throw new Error("An entity must be set without '&' and ';'. Eg. use '#xD' for '&#xD;'");
    } else if (value === "&") {
      throw new Error("An entity with value '&' is not permitted");
    } else {
      this.externalEntities[key] = value;
    }
  }
  /**
   * Returns a Symbol that can be used to access the metadata
   * property on a node.
   * 
   * If Symbol is not available in the environment, an ordinary property is used
   * and the name of the property is here returned.
   * 
   * The XMLMetaData property is only present when `captureMetaData`
   * is true in the options.
   */
  static getMetaDataSymbol() {
    return XmlNode.getMetaDataSymbol();
  }
};

// metric-binding.ts
var canon = (f) => (f || "").replace(/\s+/g, "");
function metricRefOrInline(inline, masterName, metrics) {
  if (typeof inline !== "string" || !metrics || metrics.length === 0) return inline;
  const want = canon(inline.split(`[${masterName}/`).join("["));
  for (const m of metrics) {
    if (m && m.name && m.formula && canon(m.formula) === want) return `[Metrics/${m.name}]`;
  }
  return inline;
}

// workbook-features.ts
var VIZ_KIND = {
  "com.ibm.vis.clusteredbar": "bar-chart",
  "com.ibm.vis.stackedbar": "bar-chart",
  "com.ibm.vis.clusteredcolumn": "bar-chart",
  "com.ibm.vis.stackedcolumn": "bar-chart",
  "com.ibm.vis.line": "line-chart",
  "com.ibm.vis.spline": "line-chart",
  "com.ibm.vis.area": "area-chart",
  "com.ibm.vis.stackedarea": "area-chart",
  "com.ibm.vis.pie": "pie-chart",
  "com.ibm.vis.donut": "donut-chart",
  "com.ibm.vis.clusteredcombination": "combo-chart",
  "com.ibm.vis.stackedcombination": "combo-chart",
  "com.ibm.vis.bubble": "scatter-chart",
  "com.ibm.vis.scatter": "scatter-chart",
  // Released in workbook code: required shape is source + columns + yAxis.
  "com.ibm.vis.waterfall": "waterfall-chart",
  "com.ibm.vis.waterfallchart": "waterfall-chart"
};
var VIZ_NO_ANALOG = {
  "com.ibm.vis.network": "network diagram",
  "com.ibm.vis.wordcloud": "word cloud",
  "com.ibm.vis.packedbubble": "packed bubble",
  "com.ibm.vis.treemap": "treemap"
};
var VIZ_GATED = {
  "com.ibm.vis.box": "box plot",
  "com.ibm.vis.boxplot": "box plot",
  "com.ibm.vis.boxandwhisker": "box-and-whisker plot"
};
function workbookGap(feature, detail) {
  return `\u26D4 WORKBOOK FEATURE GAP [${feature}]: ${detail}`;
}

// ../scripts/lib/code_rep.mjs
var isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
function flattenElements(doc) {
  if (!isObj(doc) || !Array.isArray(doc.pages)) return doc;
  const nested = [];
  const pages = doc.pages.map((page) => {
    const copy = { ...page };
    if (Array.isArray(copy.elements)) nested.push(...copy.elements);
    delete copy.elements;
    return copy;
  });
  const elements = [];
  const seen = /* @__PURE__ */ new Set();
  for (const element of [...Array.isArray(doc.elements) ? doc.elements : [], ...nested]) {
    const id = isObj(element) ? element.id : null;
    if (id && seen.has(id)) continue;
    if (id) seen.add(id);
    elements.push(element);
  }
  return { ...doc, pages, elements };
}
function canonicalizeLayout(layoutXml) {
  return String(layoutXml || "").replace(/<([/]?)LayoutElement\b/g, "<$1Element").replace(/<([/]?)GridContainer\b/g, "<$1Container");
}
function wrap(doc, extra = {}) {
  const flattened = flattenElements(doc);
  const canonical = isObj(flattened) && "layout" in flattened ? { ...flattened, layout: canonicalizeLayout(flattened.layout) } : flattened;
  return { ...extra, document: canonical };
}

// cognos-report.ts
var xmlParser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  trimValues: true,
  isArray: (n) => [
    "query",
    "dataItem",
    "list",
    "page",
    "detailFilter",
    "summaryFilter",
    "dataItemValue",
    "dataItemLabel",
    "listColumn",
    "reportPage",
    "crosstab",
    "crosstabNode",
    "crosstabNodeMember",
    "vizControl",
    "vcDataSet",
    "vcSlotData",
    "vcSlotDsColumn",
    "reportDataStore"
  ].includes(n)
});
var arr2 = (v) => Array.isArray(v) ? v : v == null ? [] : [v];
var txt = (v) => v == null ? "" : typeof v === "object" ? v["#text"] ?? "" : String(v);
function findAll(node, tag, out = []) {
  if (node && typeof node === "object") {
    for (const [k, v] of Object.entries(node)) {
      if (k === tag) arr2(v).forEach((x) => out.push(x));
      arr2(v).forEach((x) => x && typeof x === "object" && findAll(x, tag, out));
    }
  }
  return out;
}
var xmlEsc = (s) => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
function buildAuthoritativeLayout(pages, byPage, containerChildren) {
  const blocks = pages.map((page) => {
    const elements = byPage.get(page.id) || [];
    const nested = new Set([...containerChildren.values()].flat());
    const lines = [];
    let row = 1;
    for (let i = 0; i < elements.length; i++) {
      const element = elements[i];
      if (nested.has(element.id)) continue;
      const children = containerChildren.get(element.id);
      if (children?.length) {
        const height2 = Math.max(6, children.length * 11);
        const inner = children.map(
          (id, n) => `    <Element elementId="${xmlEsc(id)}" gridColumn="1 / 25" gridRow="${1 + n * 11} / ${1 + (n + 1) * 11}"/>`
        ).join("\n");
        lines.push(`  <Container elementId="${xmlEsc(element.id)}" type="grid" gridColumn="1 / 25" gridRow="${row} / ${row + height2}" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
${inner}
  </Container>`);
        row += height2;
        continue;
      }
      if (element.kind === "page-break") {
        lines.push(`  <Element elementId="${xmlEsc(element.id)}" gridColumn="1 / 25" gridRow="${row} / ${row + 1}"/>`);
        row += 1;
        continue;
      }
      if (element.kind === "kpi-chart") {
        const run = [];
        let j = i;
        while (j < elements.length && !nested.has(elements[j].id) && elements[j].kind === "kpi-chart" && run.length < 4) {
          run.push(elements[j]);
          j++;
        }
        const span = Math.floor(24 / run.length);
        run.forEach((kpi, n) => {
          const c0 = 1 + n * span;
          const c1 = n === run.length - 1 ? 25 : c0 + span;
          lines.push(`  <Element elementId="${xmlEsc(kpi.id)}" gridColumn="${c0} / ${c1}" gridRow="${row} / ${row + 6}"/>`);
        });
        row += 6;
        i = j - 1;
        continue;
      }
      const next = elements[i + 1];
      const isChart = element.kind.endsWith("-chart") && element.kind !== "kpi-chart";
      const nextIsChart = !!next && !nested.has(next.id) && next.kind.endsWith("-chart") && next.kind !== "kpi-chart";
      if (isChart && nextIsChart) {
        lines.push(`  <Element elementId="${xmlEsc(element.id)}" gridColumn="1 / 13" gridRow="${row} / ${row + 11}"/>`);
        lines.push(`  <Element elementId="${xmlEsc(next.id)}" gridColumn="13 / 25" gridRow="${row} / ${row + 11}"/>`);
        row += 11;
        i += 1;
        continue;
      }
      const height = element.kind === "control" || element.kind === "navigation" || element.kind === "text" ? 3 : element.visibleAsSource === false ? 1 : 12;
      lines.push(`  <Element elementId="${xmlEsc(element.id)}" gridColumn="1 / 25" gridRow="${row} / ${row + height}"/>`);
      row += height;
    }
    return `<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="${xmlEsc(page.id)}">
${lines.join("\n")}
</Page>`;
  });
  return `<?xml version="1.0" encoding="utf-8"?>
${blocks.join("\n")}`;
}
function convertCognosReportToSigma(xml2, options = {}) {
  resetIds();
  const warnings = [];
  const parsed = xmlParser.parse(xml2);
  const report = parsed.report || parsed;
  const reportName = txt(report.reportName) || options.workbookName || "Cognos Report";
  const queries = /* @__PURE__ */ new Map();
  for (const q of findAll(report.queries || report, "query")) {
    const name = q["@_name"] || "query";
    const items = /* @__PURE__ */ new Map();
    let subject = "";
    for (const di of findAll(q, "dataItem")) {
      const dn = di["@_name"];
      if (!dn) continue;
      const expr = txt(di.expression);
      const dataType = findAll(di, "XMLAttribute").find((x) => x["@_name"] === "RS_dataType")?.["@_value"];
      items.set(dn, { name: dn, expression: expr, aggregate: di["@_aggregate"], dataType });
      const m = expr.match(/\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]\.\[[^\]]+\]/);
      if (m && !subject) subject = m[1];
    }
    const filters = findAll(q, "detailFilter").map((f) => txt(f.filterExpression || f.expression)).filter(Boolean);
    queries.set(name, { name, subject, items, filters });
  }
  const prompts = /* @__PURE__ */ new Map();
  for (const sv of findAll(report, "selectValue")) {
    const p = sv["@_parameter"];
    if (!p) continue;
    const meta = prompts.get(p) || { options: [], valueRefs: {} };
    for (const o of findAll(sv, "selectOption")) {
      const v = o["@_useValue"];
      if (v && !meta.options.includes(v)) meta.options.push(v);
    }
    const d = txt(findAll(sv, "defaultSimpleSelection")[0]);
    if (d && meta.def == null) meta.def = d;
    prompts.set(p, meta);
  }
  for (const cc of findAll(report, "customControl")) {
    try {
      const cfg = JSON.parse(txt(cc.configuration));
      const p = cfg?.["Parameter"];
      if (p && cfg["Button label"] && cfg["Button value"]) {
        const meta = prompts.get(p) || { options: [], valueRefs: {} };
        meta.valueRefs[cfg["Button label"]] = String(cfg["Button value"]);
        if (!meta.options.includes(cfg["Button label"])) meta.options.push(cfg["Button label"]);
        prompts.set(p, meta);
      }
    } catch {
    }
  }
  const controls = /* @__PURE__ */ new Map();
  const registerPrompt = (p) => {
    if (controls.has(p)) return;
    const meta = prompts.get(p);
    const ctrl = {
      id: sigmaShortId(),
      kind: "control",
      controlId: p,
      name: sigmaDisplayName(p),
      controlType: "segmented",
      source: { kind: "manual", valueType: "text", values: [...meta?.options || []], labels: (meta?.options || []).map(() => null) },
      value: meta?.def ?? meta?.options?.[0] ?? null
    };
    if (!meta?.options?.length) {
      warnings.push(`prompt '${p}': no <selectValue> options found in the report \u2014 emitted an empty segmented control; add its values in Sigma.`);
    }
    controls.set(p, ctrl);
  };
  const translateModelRef = (ref) => ref.replace(/\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]\.\[([^\]]+)\]/g, (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`).replace(/\[([^\]/]+)\]\.\[([^\]]+)\]/g, (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`);
  const translate = (expr, q) => {
    const warns = [];
    let f = (expr || "").trim();
    if (f.startsWith("#") || /#\s*sql\s*\(|'token'/.test(f)) {
      const norm = (s) => s.replace(/[\s'"]+/g, "");
      const mA = f.match(/^#\s*prompt\(\s*'([^']+)'\s*,\s*'token'\s*(?:,\s*'([^']*)')?\s*\)\s*#$/s);
      if (mA) {
        const [, p, defRef] = mA;
        registerPrompt(p);
        const meta = prompts.get(p);
        const defaultFormula = defRef ? translateModelRef(defRef) : void 0;
        const defaultOption = defRef && meta ? Object.keys(meta.valueRefs).find((k) => norm(meta.valueRefs[k]) === norm(defRef)) : void 0;
        const branches = [];
        for (const opt2 of meta?.options || []) {
          if (opt2 === defaultOption) continue;
          let refFormula = meta.valueRefs[opt2] ? translateModelRef(meta.valueRefs[opt2]) : void 0;
          if (!refFormula) {
            const di = q.items.get(opt2) || [...q.items.values()].find((d) => d.name.toLowerCase() === opt2.toLowerCase());
            if (di && !di.expression.trim().startsWith("#")) refFormula = translateModelRef(di.expression.trim());
          }
          if (refFormula) branches.push(`"${opt2}", ${refFormula}`);
          else warns.push(`prompt '${p}' option "${opt2}" could not be mapped to a model column \u2014 left out of the Switch; add the branch manually.`);
        }
        if (defaultFormula && branches.length) {
          return { formula: `Switch([${p}], ${branches.join(", ")}, ${defaultFormula})`, warns };
        }
        if (defaultFormula) {
          warns.push(`prompt '${p}': no swap options resolved \u2014 emitted only the macro's default column.`);
          return { formula: defaultFormula, warns };
        }
      }
      const mB = f.match(/^#\s*'([^']*)'\s*\+\s*prompt\(\s*'([^']+)'\s*,\s*'token'\s*\)\s*\+\s*'([^']*)'\s*#$/s);
      if (mB) {
        const [, pre, p, suf] = mB;
        registerPrompt(p);
        const meta = prompts.get(p);
        if (meta?.options?.length) {
          const def = meta.def && meta.options.includes(meta.def) ? meta.def : meta.options[meta.options.length - 1];
          const branches = meta.options.filter((o) => o !== def).map((o) => `"${o}", ${translateModelRef(pre + o + suf)}`);
          const defaultFormula = translateModelRef(pre + def + suf);
          return { formula: branches.length ? `Switch([${p}], ${branches.join(", ")}, ${defaultFormula})` : defaultFormula, warns };
        }
        warns.push(`dataItem builds a column ref from prompt '${p}' but the report carries no option list for it \u2014 emitted a placeholder.`);
        return { formula: `/* MACRO \u2014 manual: ${f.slice(0, 60)} */`, warns };
      }
      const promptName = (f.match(/prompt\(\s*'([^']+)'/) || [])[1];
      if (promptName) registerPrompt(promptName);
      warns.push(`dataItem uses a Cognos macro (#\u2026#${promptName ? `, prompt '${promptName}'` : ""}) that builds the column/SQL at runtime \u2014 model it in Sigma as a control + Switch([Control], \u2026). Emitted a placeholder.`);
      return { formula: promptName ? `Switch([${promptName}] /* map prompt tokens to columns */)` : `/* MACRO \u2014 manual: ${f.slice(0, 60)} */`, warns };
    }
    f = f.replace(
      /\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]\.\[([^\]]+)\]/g,
      (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`
    );
    f = f.replace(/\[([^\]]+)\]\.\[([^\]]+)\]/g, (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`);
    f = f.replace(/\[([^\]\/]+)\]/g, (whole, nm) => q.items.has(nm) ? `[${sigmaDisplayName(nm)}]` : whole);
    f = f.replace(/prompt\(\s*'([^']+)'[^)]*\)/g, (_m, p) => {
      registerPrompt(p);
      return `[${p}]`;
    });
    const dsl = translateCognosExpr(
      f,
      { identifier: q.subject || "Q", items: [] },
      () => "",
      {}
    );
    dsl.warnings.forEach((w) => warns.push(w));
    return { formula: dsl.formula, warns };
  };
  const formatFromNode = (node) => {
    const cf = findAll(node, "currencyFormat")[0];
    const pf = findAll(node, "percentFormat")[0];
    const nf = findAll(node, "numberFormat")[0];
    const dec = (x, d) => x?.["@_decimalSize"] != null ? Number(x["@_decimalSize"]) : d;
    const scaled = (x) => x?.["@_scale"] != null || /[KMB]/.test(String(x?.["@_pattern"] || ""));
    if (cf) return { kind: "number", formatString: scaled(cf) ? `$,.${dec(cf, 1) + 2}s` : `$,.${dec(cf, 2)}f` };
    if (pf) return { kind: "number", formatString: `,.${dec(pf, 0)}%` };
    if (nf) return { kind: "number", formatString: scaled(nf) ? `$,.${dec(nf, 1) + 2}s` : `,.${dec(nf, 2)}f` };
    return void 0;
  };
  const reportPages = findAll(report.layouts || report, "reportPage").concat(findAll(report.layouts || report, "page"));
  const pageNodes = reportPages.length ? reportPages : [{ "@_name": "Report" }];
  const pages = pageNodes.map((p) => ({
    id: sigmaShortId(),
    name: p["@_name"] || "Report"
  }));
  const pageIdBySourceNode = /* @__PURE__ */ new WeakMap();
  pageNodes.forEach((pageNode, i) => {
    if (!pageNode || typeof pageNode !== "object") return;
    for (const tag of ["singleton", "list", "crosstab", "vizControl", "pageBreak", "repeater", "repeaterTable", "block"]) {
      for (const node of findAll(pageNode, tag)) {
        if (node && typeof node === "object") pageIdBySourceNode.set(node, pages[i].id);
      }
    }
  });
  const elementsByPage = new Map(pages.map((p) => [p.id, []]));
  const elementsBySourceNode = /* @__PURE__ */ new WeakMap();
  const containerChildren = /* @__PURE__ */ new Map();
  const lists = findAll(report, "list");
  const pageEls = [];
  const addToPage = (pageId, element) => {
    elementsByPage.get(pageId).push(element);
    if (element.kind !== "control") pageEls.push(element);
  };
  const addElement = (sourceNode, element) => {
    const pageId = sourceNode && typeof sourceNode === "object" ? pageIdBySourceNode.get(sourceNode) || pages[0].id : pages[0].id;
    addToPage(pageId, element);
    if (sourceNode && typeof sourceNode === "object") {
      const current = elementsBySourceNode.get(sourceNode) || [];
      current.push(element);
      elementsBySourceNode.set(sourceNode, current);
    }
  };
  const dmSource = (q) => ({ kind: "data-model", dataModelId: options.dataModelId || "<DM_ID \u2014 wire after posting the data model>", elementId: q.subject ? sigmaDisplayName(q.subject) : "<element>" });
  const bindMeasure = (formula, q) => {
    const map = options.metrics || {};
    const subjects = q.subject ? [sigmaDisplayName(q.subject), ...Object.keys(map)] : Object.keys(map);
    for (const s of subjects) {
      const out = metricRefOrInline(formula, s, map[s]);
      if (out !== formula) return out;
    }
    return formula;
  };
  const ensureFilterCol = (el, q, itemName) => {
    const di = q.items.get(itemName);
    if (!di) return void 0;
    const want = sigmaDisplayName(di.name);
    const existing = (el.columns || []).find((c) => c.name === want);
    if (existing) return existing.id;
    const { formula, warns } = translate(di.expression, q);
    warns.forEach((w) => warnings.push(`"${q.name}.${itemName}": ${w}`));
    const id = sigmaShortId();
    (el.columns ||= []).push({ id, name: want, formula, hidden: true });
    return id;
  };
  const applyQueryFilters = (el, q) => {
    for (const fx of q.filters) {
      const m = fx.match(/^\s*\[([^\]]+)\]\s+(in)\s*\(([^)]*)\)\s*$/i) || fx.match(/^\s*\[([^\]]+)\]\s*(=)\s*(.+?)\s*$/);
      const fail = (why) => warnings.push(`filter "${fx.slice(0, 80)}" on query "${q.name}": ${why} \u2014 re-create as a Sigma element/page filter.`);
      if (!m) {
        fail("not a simple =/in filter");
        continue;
      }
      const [, nm, op, rhs] = m;
      if (!q.items.has(nm)) {
        fail(`[${nm}] is not a dataItem in the query`);
        continue;
      }
      const colId = ensureFilterCol(el, q, nm);
      if (!colId) {
        fail("filter column could not be added");
        continue;
      }
      const col = el.columns.find((c) => c.id === colId);
      const textCol = /^Text\(/.test(col.formula);
      const lit = (s) => {
        const t = s.trim().replace(/^['"](.*)['"]$/, "$1");
        return t !== "" && /^-?[\d.]+$/.test(t) && !Number.isNaN(Number(t)) && !textCol ? Number(t) : t;
      };
      const prompt = rhs.trim().match(/^\?(\w+)\?$/);
      if (prompt && op === "=") {
        const p = prompt[1];
        registerPrompt(p);
        const boolId = sigmaShortId();
        el.columns.push({ id: boolId, name: `${col.name} = ${p}`, formula: `[${col.name}] = [${p}]`, hidden: true });
        (el.filters ||= []).push({ id: sigmaShortId(), columnId: boolId, kind: "list", mode: "include", values: [true] });
      } else if (op.toLowerCase() === "in") {
        const values = rhs.split(",").map((s) => lit(s)).filter((v) => v !== "");
        (el.filters ||= []).push({ id: sigmaShortId(), columnId: colId, kind: "list", mode: "include", values });
      } else if (rhs.trim().startsWith("?")) {
        fail("unsupported prompt comparison");
      } else {
        (el.filters ||= []).push({ id: sigmaShortId(), columnId: colId, kind: "list", mode: "include", values: [lit(rhs)] });
      }
    }
  };
  for (const sg of findAll(report, "singleton")) {
    const qName2 = sg["@_refQuery"];
    const q = queries.get(qName2);
    if (!q) {
      warnings.push(`<singleton> "${sg["@_name"]}" refQuery="${qName2}" has no matching query \u2014 skipped.`);
      continue;
    }
    const ref = findAll(sg, "dataItemValue").map((d) => d["@_refDataItem"]).find(Boolean);
    const di = ref ? q.items.get(ref) : void 0;
    if (!di) {
      warnings.push(`<singleton> "${sg["@_name"]}" has no resolvable dataItem ("${ref}") \u2014 skipped.`);
      continue;
    }
    const cols = [];
    const idByName = /* @__PURE__ */ new Map();
    const addKpiCol = (nm) => {
      if (idByName.has(nm)) return idByName.get(nm);
      const d = q.items.get(nm);
      if (!d) return void 0;
      for (const sm of d.expression.matchAll(/\[([^\]/.]+)\]/g)) {
        if (sm[1] !== nm && q.items.has(sm[1])) addKpiCol(sm[1]);
      }
      const { formula, warns } = translate(d.expression, q);
      warns.forEach((w) => warnings.push(`"${qName2}.${nm}": ${w}`));
      const referencesSibling = [...q.items.keys()].some((k) => k !== nm && formula.toLowerCase().includes(`[${sigmaDisplayName(k).toLowerCase()}]`));
      const hasAgg = /\b(Sum|Avg|Min|Max|Count|CountDistinct|Median)\s*\(/.test(formula);
      const id = sigmaShortId();
      cols.push({ id, name: sigmaDisplayName(nm), formula: bindMeasure(referencesSibling || hasAgg ? formula : `Sum(${formula})`, q) });
      idByName.set(nm, id);
      return id;
    };
    const valId = addKpiCol(ref);
    const fmt = formatFromNode(sg);
    if (fmt) cols.find((c) => c.id === valId).format = fmt;
    if (findAll(sg, "conditionalStyleRef").length) {
      warnings.push(`singleton "${sg["@_name"]}" (${ref}) uses conditional styling (e.g. up/down KPI icons) \u2014 not portable to a Sigma kpi-chart spec; the VALUE is preserved, re-create the icon rule manually.`);
    }
    const el = {
      id: sigmaShortId(),
      kind: "kpi-chart",
      name: di.name,
      source: dmSource(q),
      columns: cols,
      order: cols.map((c) => c.id),
      value: { columnId: valId }
    };
    applyQueryFilters(el, q);
    addElement(sg, el);
  }
  for (const L of lists) {
    const qName2 = L["@_refQuery"];
    const q = queries.get(qName2);
    if (!q) {
      warnings.push(`<list> refQuery="${qName2}" has no matching query \u2014 skipped.`);
      continue;
    }
    const colRefs = findAll(L, "dataItemValue").map((d) => d["@_refDataItem"]).filter(Boolean);
    const refs = colRefs.length ? colRefs : [...q.items.keys()];
    const columns = [];
    const AGG = { total: "Sum", summary: "Sum", aggregate: "Sum", calculated: "Sum", average: "Avg", count: "Count", maximum: "Max", minimum: "Min" };
    const isMeasureItem = (d) => !!d.aggregate && d.aggregate !== "none";
    const grouped = refs.some((r) => {
      const d = q.items.get(r);
      return d && isMeasureItem(d);
    }) && refs.some((r) => {
      const d = q.items.get(r);
      return d && !isMeasureItem(d);
    });
    const dimIds = [];
    const measureIds = [];
    const footerRefs = [];
    for (const r of refs) {
      const di = q.items.get(r);
      if (!di) {
        const m = r.match(/^(Total|Summary|Aggregate|Average|Count|Maximum|Minimum)\((.+?)\)\d*$/i);
        if (m && q.items.get(m[2])) {
          if (grouped) {
            footerRefs.push(r);
            continue;
          }
          columns.push({ id: sigmaShortId(), name: sigmaDisplayName(r), formula: `${AGG[m[1].toLowerCase()]}([${sigmaDisplayName(m[2])}])` });
          continue;
        }
        warnings.push(`list column "${r}" not found in query "${qName2}" \u2014 skipped.`);
        continue;
      }
      const { formula, warns } = translate(di.expression, q);
      warns.forEach((w) => warnings.push(`"${qName2}.${r}": ${w}`));
      const id = sigmaShortId();
      if (grouped && isMeasureItem(di)) {
        const _aggk = di.aggregate.toLowerCase();
        if (!AGG[_aggk]) warnings.push(`list measure "${di.name}" (query "${qName2}"): unmapped Cognos aggregate '${di.aggregate}' \u2014 defaulted to Sum (degraded); verify parity or add the mapping (refs/cognos-coverage.md).`);
        const fn = AGG[_aggk] || "Sum";
        columns.push({ id, name: sigmaDisplayName(di.name), formula: bindMeasure(/^\s*(Sum|Avg|Min|Max|Count|CountDistinct)\s*\(/.test(formula) ? formula : `${fn}(${formula})`, q) });
        measureIds.push(id);
      } else {
        columns.push({ id, name: sigmaDisplayName(di.name), formula });
        if (grouped) dimIds.push(id);
      }
    }
    if (footerRefs.length) {
      warnings.push(`list "${qName2}": footer total(s) ${footerRefs.join(", ")} \u2014 the grouped Sigma table already aggregates per group; add a grand-total via the table's totals UI (a duplicate Sum column would double-aggregate).`);
    }
    for (const si of findAll(L, "sortItem")) {
      if (si["@_refDataItem"]) warnings.push(`list "${qName2}" sorts by "${si["@_refDataItem"]}" (${si["@_sortOrder"] || "ascending"}) \u2014 table sort isn't part of the Sigma workbook spec; apply the sort in the UI.`);
    }
    const condRefs = [...new Set(findAll(L, "conditionalStyleRef").map((c) => c["@_refConditionalStyle"]).filter(Boolean))];
    if (condRefs.length) warnings.push(`list "${qName2}" uses conditional style(s) ${condRefs.map((r) => `"${r}"`).join(", ")} \u2014 threshold-driven formats/styles aren't portable to the Sigma spec; set a column format (e.g. $,.3s) or conditional formatting in the UI.`);
    const el = {
      id: sigmaShortId(),
      kind: "table",
      name: `${q.subject ? sigmaDisplayName(q.subject) + " \u2014 " : ""}${qName2}`,
      source: dmSource(q),
      columns,
      order: columns.map((c) => c.id)
    };
    if (grouped && dimIds.length && measureIds.length) {
      el.groupings = [{ id: sigmaShortId(), groupBy: dimIds, calculations: measureIds }];
    }
    applyQueryFilters(el, q);
    addElement(L, el);
  }
  const isTotal = (r) => /^(Total|Summary|Aggregate|Average|Count|Maximum|Minimum)\(/i.test(r || "");
  for (const X of findAll(report, "crosstab")) {
    const qName2 = X["@_refQuery"];
    const q = queries.get(qName2);
    if (!q) {
      warnings.push(`<crosstab> refQuery="${qName2}" has no matching query \u2014 skipped.`);
      continue;
    }
    const edge = (subtree) => [...new Set(findAll(subtree || {}, "crosstabNodeMember").map((m) => m["@_refDataItem"]).filter((r) => r && !isTotal(r)))];
    const rowRefs = edge(X.crosstabRows);
    const colRefs = edge(X.crosstabColumns);
    let measRefs = [...new Set(findAll(X.crosstabCorner || {}, "dataItemLabel").map((d) => d["@_refDataItem"]).filter((r) => r && !isTotal(r)))];
    if (!measRefs.length) measRefs = [...q.items.keys()].filter((k) => !rowRefs.includes(k) && !colRefs.includes(k) && !isTotal(k));
    const cols = [];
    const mk = (ref, agg) => {
      const di = q.items.get(ref);
      if (!di) {
        warnings.push(`crosstab "${qName2}" member "${ref}" not in query \u2014 skipped.`);
        return null;
      }
      const { formula, warns } = translate(di.expression, q);
      warns.forEach((w) => warnings.push(`"${qName2}.${ref}": ${w}`));
      const id = sigmaShortId();
      cols.push({ id, name: sigmaDisplayName(di.name), formula: agg ? bindMeasure(`Sum(${formula})`, q) : formula });
      return { id };
    };
    const rowsBy = rowRefs.map((r) => mk(r, false)).filter(Boolean);
    const columnsBy = colRefs.map((c) => mk(c, false)).filter(Boolean);
    const values = measRefs.map((m) => mk(m, true)).filter(Boolean).map((o) => o.id);
    if (!values.length || !rowsBy.length && !columnsBy.length) warnings.push(`crosstab "${qName2}" missing a measure or both edges \u2014 review the pivot.`);
    const el = {
      id: sigmaShortId(),
      kind: "pivot-table",
      name: `${q.subject ? sigmaDisplayName(q.subject) + " \u2014 " : ""}${qName2} (crosstab)`,
      source: dmSource(q),
      columns: cols,
      order: cols.map((c) => c.id),
      rowsBy,
      columnsBy,
      values
    };
    applyQueryFilters(el, q);
    addElement(X, el);
  }
  const dsToQuery = /* @__PURE__ */ new Map();
  for (const ds of findAll(report, "reportDataStore")) {
    const nm = ds["@_name"];
    const rq = findAll(ds, "dsV5ListQuery").map((x) => x["@_refQuery"]).find(Boolean);
    if (nm && rq) dsToQuery.set(nm, rq);
  }
  const ROLLUP_AGG = { total: "Sum", sum: "Sum", average: "Avg", avg: "Avg", count: "Count", countdistinct: "CountDistinct", maximum: "Max", minimum: "Min" };
  const isMapViz = (t) => /tiledmap|choropleth|\bmap\b/.test(t);
  const chartSource = dmSource;
  const COGNOS_SCHEME = {
    // sequential (single-hue ramps)
    blue: ["#deebf7", "#9ecae1", "#3182bd"],
    blues: ["#deebf7", "#9ecae1", "#3182bd"],
    green: ["#e5f5e0", "#a1d99b", "#31a354"],
    greens: ["#e5f5e0", "#a1d99b", "#31a354"],
    orange: ["#fee6ce", "#fdae6b", "#e6550d"],
    oranges: ["#fee6ce", "#fdae6b", "#e6550d"],
    red: ["#fee0d2", "#fc9272", "#de2d26"],
    reds: ["#fee0d2", "#fc9272", "#de2d26"],
    purple: ["#efedf5", "#bcbddc", "#756bb1"],
    heat: ["#ffffcc", "#fd8d3c", "#bd0026"],
    sequential: ["#ffffcc", "#fd8d3c", "#bd0026"],
    // diverging
    diverging: ["#a50026", "#f46d43", "#fee090", "#74add1", "#313695"],
    redblue: ["#a50026", "#f46d43", "#fee090", "#74add1", "#313695"],
    redgreen: ["#d73027", "#fee08b", "#1a9850"]
  };
  const SEQ_DEFAULT = COGNOS_SCHEME.sequential;
  const schemeFromSignal = (sig) => {
    const key = String(sig || "").toLowerCase().replace(/[^a-z]/g, "");
    for (const k of Object.keys(COGNOS_SCHEME)) if (key.includes(k)) return [...COGNOS_SCHEME[k]];
    return [...SEQ_DEFAULT];
  };
  const vizColorSignal = (V) => {
    for (const pv of findAll(V, "vizPropertyValues")) {
      for (const [, v] of Object.entries(pv)) {
        for (const p of arr2(v)) {
          const nm = String(p?.["@_name"] || "");
          if (/palette|colou?r.?scheme|colou?rmodel/i.test(nm)) {
            const val = txt(p);
            if (val) return val;
          }
        }
      }
    }
    const pal = findAll(V, "vcSlotData").map((s) => s["@_refPaletteDefinition"] || s["@_refPalette"]).find(Boolean) || V["@_refPaletteDefinition"] || V["@_refPalette"];
    return pal ? String(pal) : void 0;
  };
  const legendFromViz = (V) => {
    let seen = false;
    let visibility;
    let position;
    for (const tag of ["vizPropertyBooleanValue", "vizPropertyEnumValue", "vizPropertyStringValue"]) {
      for (const prop of findAll(V, tag)) {
        const name = String(prop["@_name"] || "");
        if (!/legend/i.test(name)) continue;
        seen = true;
        const value = String(prop["@_value"] ?? txt(prop)).toLowerCase();
        if (/visible|show|display/i.test(name)) visibility = /^(false|hidden|none|off|0)$/.test(value) ? "hidden" : "shown";
        if (/position|placement|location/i.test(name)) {
          const side = ["top", "bottom", "left", "right"].find((x) => value.includes(x));
          if (side) position = side;
        }
      }
    }
    return seen ? { ...visibility ? { visibility } : {}, ...position ? { position } : {} } : void 0;
  };
  const styleFromNode = (node) => {
    const css = findAll(node, "CSS").map((x) => String(x["@_value"] || txt(x))).join(";");
    const style = {};
    const background = css.match(/background(?:-color)?\s*:\s*(#[0-9a-f]{3,8})/i)?.[1];
    if (background) style.backgroundColor = background;
    const radius = css.match(/border-radius\s*:\s*([^;]+)/i)?.[1]?.trim();
    if (radius && radius !== "0" && radius !== "0px") style.borderRadius = "round";
    return Object.keys(style).length ? style : void 0;
  };
  const buildRefMarks = (V, q, vizName) => {
    const nodes = [...findAll(V, "baseline"), ...findAll(V, "vizBaseline")];
    const out = [];
    for (const b of nodes) {
      if (String(b["@_visible"] ?? b["@_show"] ?? "true").toLowerCase() === "false") continue;
      const onX = /^(category|categories|x|item|itemaxis)$/i.test(String(b["@_refAxis"] || b["@_axis"] || ""));
      const axis = onX ? "axis" : "series";
      let formula = "";
      const di = b["@_refDataItem"] ? q.items.get(b["@_refDataItem"]) : void 0;
      if (di) {
        const { formula: f, warns } = translate(di.expression, q);
        warns.forEach((w) => warnings.push(`"${vizName}.baseline ${b["@_refDataItem"]}": ${w}`));
        formula = /^\s*(Sum|Avg|Min|Max|Count|CountDistinct|Median)\s*\(/.test(f) ? f : `Avg(${f})`;
      } else {
        const v = b["@_value"] ?? b["@_position"] ?? txt(b.value) ?? txt(b);
        if (v != null && String(v).trim() !== "" && /^-?[\d.]+$/.test(String(v).trim())) formula = String(v).trim();
      }
      if (!formula) {
        warnings.push(`chart "${vizName}": a reference line / baseline had no static value or data-item measure \u2014 skipped (re-add it in the workbook).`);
        continue;
      }
      const rm = {
        type: "line",
        axis,
        value: { type: "formula", formula },
        line: { color: String(b["@_color"] || b["@_lineColor"] || "#ef4444"), width: 2 }
      };
      const label = b["@_label"] || b["@_text"] || (di ? sigmaDisplayName(di.name) : void 0);
      if (label) rm.label = { visibility: "shown", text: String(label) };
      out.push(rm);
    }
    return out;
  };
  for (const V of findAll(report, "vizControl")) {
    const vizType = String(V["@_type"] || "").toLowerCase();
    const vizName = V["@_name"] || "Chart";
    const dsName = findAll(V, "vcDataSet").map((d) => d["@_refDataStore"]).find(Boolean);
    const qName2 = dsName ? dsToQuery.get(dsName) : void 0;
    const q = qName2 ? queries.get(qName2) : void 0;
    if (!q) {
      warnings.push(`<vizControl> "${vizName}" (${vizType}): no resolvable query (dataStore "${dsName}") \u2014 chart skipped.`);
      continue;
    }
    const slot = (id) => {
      const out = [];
      for (const sd of findAll(V, "vcSlotData")) {
        if (String(sd["@_idSlot"] || "").toLowerCase() !== id) continue;
        for (const c of findAll(sd, "vcSlotDsColumn")) if (c["@_refDsColumn"]) {
          out.push({ ref: c["@_refDsColumn"], rollup: c["@_rollupMethod"], sort: c["@_dsSort"], format: formatFromNode(c) });
        }
      }
      return out;
    };
    const cols = [];
    const seen = /* @__PURE__ */ new Map();
    const addCol = (e, measure, categorical = false) => {
      if (!e) return void 0;
      const di = q.items.get(e.ref);
      if (!di) {
        warnings.push(`chart "${vizName}" column "${e.ref}" not in query "${qName2}" \u2014 skipped.`);
        return void 0;
      }
      const nm = sigmaDisplayName(di.name);
      if (seen.has(nm)) return seen.get(nm);
      let { formula, warns } = translate(di.expression, q);
      warns.forEach((w) => warnings.push(`"${vizName}.${e.ref}": ${w}`));
      if (categorical && !measure && (di.dataType === "1" || di.dataType === "2")) formula = `Text(${formula})`;
      const id = sigmaShortId();
      let fn = "";
      if (measure) {
        const _rk = String(e.rollup || "").toLowerCase();
        if (_rk && !ROLLUP_AGG[_rk]) warnings.push(`chart "${vizName}" measure "${nm}": unmapped Cognos rollup '${e.rollup}' \u2014 defaulted to Sum (degraded); verify parity (refs/cognos-coverage.md).`);
        fn = ROLLUP_AGG[_rk] || "Sum";
      }
      const col = { id, name: nm, formula: measure ? bindMeasure(`${fn}(${formula})`, q) : formula };
      if (e.format) col.format = e.format;
      cols.push(col);
      seen.set(nm, id);
      return id;
    };
    const cats = slot("categories"), series = slot("series"), vals = slot("values");
    const sizes = slot("size"), xs = slot("x"), ys = slot("y"), colorSlot = slot("color");
    const kind = VIZ_KIND[vizType];
    if (/progress|bullet|gauge/.test(vizType)) {
      const valueEntry = vals[0] || sizes[0] || ys[0];
      const valueId = addCol(valueEntry, true);
      const valueCol = cols.find((c) => c.id === valueId);
      if (!valueCol) {
        warnings.push(workbookGap("progress", `chart "${vizName}" had no resolvable value measure; no progress element was emitted.`));
        continue;
      }
      const sourceName = `${vizName} (progress source)`;
      const source = {
        id: sigmaShortId(),
        kind: "table",
        name: sourceName,
        source: chartSource(q),
        columns: cols,
        order: cols.map((c) => c.id),
        visibleAsSource: false
      };
      const percent = valueEntry?.format?.formatString?.includes("%");
      const progress = {
        id: sigmaShortId(),
        kind: "progress",
        name: vizName,
        min: "0",
        max: percent ? "1" : "100",
        value: { columnId: valueId },
        mode: percent ? "percent" : "value",
        shape: /ring|radial|gauge/.test(vizType) ? "ring" : "bar"
      };
      progress.value = `[${sourceName}/${valueCol.name}]`;
      addElement(V, source);
      addElement(V, progress);
      continue;
    }
    if (isMapViz(vizType)) {
      const lat = slot("latlonglocations.latitude")[0] || slot("latitude")[0];
      const lon = slot("latlonglocations.longitude")[0] || slot("longitude")[0];
      const region = slot("locations")[0] || slot("location")[0];
      if (lat && lon) {
        const latId = addCol(lat, false), lonId = addCol(lon, false);
        const sizeId = addCol(slot("latlongsize")[0] || sizes[0], true);
        const colorId = addCol(slot("latlongcolor")[0] || colorSlot[0], true);
        const el2 = { id: sigmaShortId(), kind: "point-map", name: vizName, source: chartSource(q), columns: cols, order: [] };
        const legend2 = legendFromViz(V);
        if (legend2) el2.legend = legend2;
        if (latId) el2.latitude = { id: latId };
        if (lonId) el2.longitude = { id: lonId };
        if (sizeId) el2.size = { id: sizeId };
        if (colorId) el2.color = { by: "scale", column: colorId };
        el2.order = cols.map((c) => c.id);
        if (!cols.length) {
          warnings.push(`<vizControl> map "${vizName}" had no resolvable lat/long columns \u2014 skipped.`);
          continue;
        }
        applyQueryFilters(el2, q);
        addElement(V, el2);
      } else if (region) {
        const regId = addCol(region, false);
        const colorId = addCol(slot("locationcolor")[0] || colorSlot[0] || slot("locationheight")[0], true);
        if (!regId) {
          warnings.push(`<vizControl> map "${vizName}" had no resolvable location column \u2014 skipped.`);
          continue;
        }
        const el2 = { id: sigmaShortId(), kind: "region-map", name: vizName, source: chartSource(q), columns: cols, order: cols.map((c) => c.id), region: { id: regId, regionType: "country" } };
        const legend2 = legendFromViz(V);
        if (legend2) el2.legend = legend2;
        if (colorId) el2.color = { by: "scale", column: colorId };
        warnings.push(`chart "${vizName}" \u2192 region-map: defaulted regionType to "country" \u2014 set it to match your data (country / us-state / us-county / us-zipcode / us-cbsa / us-postal-place / ca-province).`);
        applyQueryFilters(el2, q);
        addElement(V, el2);
      } else {
        for (const c of findAll(V, "vcSlotDsColumn")) if (c["@_refDsColumn"]) addCol({ ref: c["@_refDsColumn"], rollup: c["@_rollupMethod"] }, !!c["@_rollupMethod"]);
        if (!cols.length) {
          warnings.push(`<vizControl> map "${vizName}" (${vizType}) had no resolvable columns \u2014 skipped.`);
          continue;
        }
        warnings.push(`chart "${vizName}" is a Cognos map (${vizType}) with no lat/long or named-location slot \u2014 emitted its data as a table; add geographic columns + a map in the workbook.`);
        const fb = { id: sigmaShortId(), kind: "table", name: `${vizName} (was map)`, source: chartSource(q), columns: cols, order: cols.map((c) => c.id) };
        const measures = cols.filter((c) => /^\s*(Sum|Avg|Min|Max|Count|CountDistinct)\s*\(/.test(c.formula)).map((c) => c.id);
        const dimensions = cols.filter((c) => !measures.includes(c.id)).map((c) => c.id);
        if (measures.length && dimensions.length) fb.groupings = [{ id: sigmaShortId(), groupBy: dimensions, calculations: measures }];
        applyQueryFilters(fb, q);
        addElement(V, fb);
      }
      continue;
    }
    if (!kind) {
      const gated = VIZ_GATED[vizType];
      const label = gated || VIZ_NO_ANALOG[vizType] || vizType.replace("com.ibm.vis.", "");
      for (const c of findAll(V, "vcSlotDsColumn")) if (c["@_refDsColumn"]) addCol({ ref: c["@_refDsColumn"], rollup: c["@_rollupMethod"] }, !!c["@_rollupMethod"]);
      if (!cols.length) {
        warnings.push(`<vizControl> "${vizName}" (${vizType}) had no resolvable columns \u2014 skipped.`);
        continue;
      }
      warnings.push(workbookGap(
        gated ? "box-chart (workspace gated)" : `visual ${vizType}`,
        gated ? `chart "${vizName}" is a Cognos ${label}; Sigma box-chart is workspace-gated, so the converter preserved its data as a table instead of risking a masked entitlement failure. Enable and verify box-chart before replacing it.` : `chart "${vizName}" is a Cognos ${label}; no grounded Sigma mapping is cataloged. Its data was preserved as a table.`
      ));
      const fb = { id: sigmaShortId(), kind: "table", name: `${vizName} (was ${label})`, source: chartSource(q), columns: cols, order: cols.map((c) => c.id) };
      const measures = cols.filter((c) => /^\s*(Sum|Avg|Min|Max|Count|CountDistinct)\s*\(/.test(c.formula)).map((c) => c.id);
      const dimensions = cols.filter((c) => !measures.includes(c.id)).map((c) => c.id);
      if (measures.length && dimensions.length) fb.groupings = [{ id: sigmaShortId(), groupBy: dimensions, calculations: measures }];
      applyQueryFilters(fb, q);
      addElement(V, fb);
      continue;
    }
    const el = { id: sigmaShortId(), kind, name: vizName, source: chartSource(q), columns: [], order: [] };
    const legend = legendFromViz(V);
    if (legend) el.legend = legend;
    if (kind === "pie-chart" || kind === "donut-chart") {
      const colorId = addCol(cats[0] || colorSlot[0], false);
      const valId = addCol(vals[0] || sizes[0], true);
      if (colorId) el.color = { id: colorId };
      if (valId) el.value = { id: valId };
    } else if (kind === "scatter-chart") {
      const dimSlot = series[0] || colorSlot[0];
      const xId = addCol(xs[0] || cats[0], true);
      const yId = addCol(ys[0] || vals[0] || sizes[0], true);
      const dId = dimSlot ? addCol(dimSlot, false) : void 0;
      const szId = sizes[0] && sizes[0] !== (ys[0] || vals[0]) ? addCol(sizes[0], true) : void 0;
      if (xId && yId && dId) {
        const grpId = sigmaShortId();
        const srcName = `${vizName} (scatter source)`;
        const src = {
          id: sigmaShortId(),
          kind: "table",
          name: srcName,
          source: chartSource(q),
          columns: cols,
          order: cols.map((c) => c.id),
          groupings: [{ id: grpId, groupBy: [dId], calculations: szId ? [xId, yId, szId] : [xId, yId] }],
          visibleAsSource: false
        };
        applyQueryFilters(src, q);
        const byId = new Map(cols.map((c) => [c.id, c]));
        const raw = (srcColId) => {
          const sc = byId.get(srcColId);
          return { id: sigmaShortId(), name: sc.name, formula: `[${srcName}/${sc.name}]` };
        };
        const sDim = raw(dId), sX = raw(xId), sY = raw(yId);
        const scols = [sDim, sX, sY];
        el.source = { kind: "table", elementId: src.id, groupingId: grpId };
        el.xAxis = { columnId: sX.id };
        el.yAxis = { columnIds: [sY.id] };
        el.color = { by: "category", column: sDim.id };
        if (szId) {
          const sSz = raw(szId);
          scols.push(sSz);
          el.size = { id: sSz.id };
        }
        el.columns = scols;
        el.order = scols.map((c) => c.id);
        const sRefMarks2 = buildRefMarks(V, q, vizName);
        if (sRefMarks2.length) el.refMarks = sRefMarks2;
        addElement(V, src);
        addElement(V, el);
        continue;
      }
      if (xId) el.xAxis = { columnId: xId };
      if (yId) el.yAxis = { columnIds: [yId] };
      if (dId) el.color = { by: "category", column: dId };
      const sRefMarks = buildRefMarks(V, q, vizName);
      if (sRefMarks.length) el.refMarks = sRefMarks;
    } else {
      const xId = addCol(cats[0], false, true);
      if (xId && kind !== "waterfall-chart") {
        el.xAxis = { columnId: xId };
        if (cats[0]?.sort) el.xAxis.sort = { by: xId, direction: /desc/i.test(cats[0].sort) ? "descending" : "ascending" };
      }
      if (cats.length > 1) {
        warnings.push(`chart "${vizName}": Cognos used ${cats.length} category levels; Sigma x-axis takes one \u2014 bound the first, kept the rest as columns.`);
        cats.slice(1).forEach((c) => addCol(c, false, true));
      }
      const yIds = [...vals, ...sizes].map((v) => addCol(v, true)).filter(Boolean);
      if (yIds.length) el.yAxis = { columnIds: yIds };
      else warnings.push(`chart "${vizName}" (${kind}) resolved no measure for the value axis \u2014 add a measure in the workbook.`);
      const colorE = colorSlot[0];
      const colorIsMeasure = !series[0] && !!colorE && !!colorE.rollup && !!q.items.get(colorE.ref);
      if (colorIsMeasure) {
        const baseId = addCol(colorE, true);
        const base = cols.find((c) => c.id === baseId);
        if (base) {
          const dupId = sigmaShortId();
          const dup = { id: dupId, name: `${base.name} (color)`, formula: base.formula };
          if (base.format) dup.format = base.format;
          cols.push(dup);
          el.color = { by: "scale", column: dupId, scheme: schemeFromSignal(vizColorSignal(V)) };
        }
      } else {
        const cId = addCol(series[0] || colorE, false);
        if (cId) el.color = { by: "category", column: cId };
      }
      const refMarks = buildRefMarks(V, q, vizName);
      if (refMarks.length) el.refMarks = refMarks;
      if (kind === "bar-chart") {
        el.stacking = /stacked/.test(vizType) ? "stacked" : "none";
        if (/\bbar\b/.test(vizType) && !/column/.test(vizType)) el.orientation = "horizontal";
      }
      if (kind === "combo-chart" && yIds.length > 1) warnings.push(`chart "${vizName}" \u2192 combo-chart: all measures placed on the primary axis as the same mark \u2014 set per-series shape / secondary axis in the workbook.`);
      if (kind === "waterfall-chart" && cats.length > 1) {
        warnings.push(workbookGap(
          "waterfall category hierarchy",
          `chart "${vizName}" has ${cats.length} Cognos category levels, but released waterfall-chart code exposes no xAxis hierarchy. All category columns were retained; verify the rendered step labels.`
        ));
      }
    }
    el.columns = cols;
    el.order = cols.map((c) => c.id);
    if (!cols.length) {
      warnings.push(`<vizControl> "${vizName}" (${vizType}) had no resolvable slot columns \u2014 skipped.`);
      continue;
    }
    applyQueryFilters(el, q);
    addElement(V, el);
  }
  for (const pageBreak of findAll(report, "pageBreak")) {
    addElement(pageBreak, { id: sigmaShortId(), kind: "page-break" });
  }
  for (const drill of findAll(report, "drillBehavior")) {
    if (!drill || typeof drill !== "object" || Object.keys(drill).length === 0) continue;
    const id = sigmaShortId();
    addToPage(pages[0].id, {
      id,
      kind: "control",
      controlId: `drill-${id}`,
      name: "Drill",
      controlType: "drill"
    });
  }
  for (const reportDrill of findAll(report, "reportDrill")) {
    const name = reportDrill["@_name"] || "unnamed report drill";
    const path = findAll(reportDrill, "reportPath")[0]?.["@_path"];
    warnings.push(workbookGap(
      "cross-report drill-through",
      `"${name}" targets ${path || "another Cognos report"}. The released Sigma drill control is hierarchy drill, not cross-document navigation; wire a converted target page/document explicitly.`
    ));
  }
  for (const repeater of [...findAll(report, "repeater"), ...findAll(report, "repeaterTable")]) {
    const qName2 = repeater["@_refQuery"];
    const q = queries.get(qName2);
    if (!q) {
      warnings.push(workbookGap("repeater", `refQuery="${qName2 || "(missing)"}" has no matching query; repeater was not emitted.`));
      continue;
    }
    const refs = [...new Set(findAll(repeater, "dataItemValue").map((x) => x["@_refDataItem"]).filter(Boolean))];
    const sourceName = `${repeater["@_name"] || qName2} source`;
    const sourceColumns = refs.flatMap((ref) => {
      const di = q.items.get(ref);
      if (!di) return [];
      const translated = translate(di.expression, q);
      translated.warns.forEach((w) => warnings.push(`"${qName2}.${ref}": ${w}`));
      return [{ id: sigmaShortId(), name: sigmaDisplayName(di.name), formula: translated.formula }];
    });
    const source = {
      id: sigmaShortId(),
      kind: "table",
      name: sourceName,
      source: dmSource(q),
      columns: sourceColumns,
      order: sourceColumns.map((c) => c.id),
      visibleAsSource: false
    };
    addElement(repeater, source);
    const rc = {
      id: sigmaShortId(),
      kind: "repeated-container",
      name: repeater["@_name"] || `${qName2} repeater`,
      source: { kind: "table", elementId: source.id },
      arrangement: "list",
      cardSize: "small",
      noDataText: "No rows",
      cardStyle: styleFromNode(repeater)
    };
    addElement(repeater, rc);
    const children = [];
    for (const ref of refs) {
      const di = q.items.get(ref);
      if (!di) continue;
      const child = {
        id: sigmaShortId(),
        kind: "text",
        body: `{{[${sourceName} repeated container/${sigmaDisplayName(di.name)}]}}`
      };
      addElement(repeater, child);
      children.push(child.id);
    }
    if (children.length) containerChildren.set(rc.id, children);
    else warnings.push(workbookGap(
      "repeater content",
      `"${rc.name}" had no resolvable dataItemValue children. The repeated-container shell was preserved, but its card content must be authored.`
    ));
  }
  const claimedPanelChildren = /* @__PURE__ */ new Set();
  for (const block of findAll(report, "block")) {
    if (!block["@_name"]) continue;
    const children = [];
    for (const tag of ["singleton", "list", "crosstab", "vizControl", "repeater", "repeaterTable"]) {
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
    const panel = {
      id: sigmaShortId(),
      kind: "container",
      name: sigmaDisplayName(block["@_name"]),
      ...styleFromNode(block) ? { style: styleFromNode(block) } : {}
    };
    addElement(block, panel);
    containerChildren.set(panel.id, children);
  }
  const controlEls = [...controls.values()];
  controlEls.forEach((control) => addToPage(pages[0].id, control));
  if (pages.length > 1 && report["@_viewPagesAsTabs"]) {
    const pageLabels = pages.map((p) => ({ pageId: p.id, label: p.name }));
    for (const page of pages) {
      const nav = {
        id: sigmaShortId(),
        kind: "navigation",
        mode: "auto",
        pageLabels
      };
      elementsByPage.get(page.id).unshift(nav);
    }
  }
  for (const fnode of findAll(report, "summaryFilter")) {
    const fexpr = txt(fnode.filterExpression || fnode.expression);
    if (fexpr) warnings.push(`summary filter: "${fexpr.slice(0, 80)}" \u2014 post-aggregation filter; re-create as a Sigma filter on the aggregated column.`);
  }
  const panels = [];
  pageNodes.forEach((pageNode, i) => {
    const header = findAll(pageNode, "pageHeader")[0];
    if (header) {
      const style = styleFromNode(header);
      panels.push({
        id: sigmaShortId(),
        type: "header",
        title: `${pages[i].name} header`,
        pages: [pages[i].id],
        config: {
          scroll: "none",
          borderStyle: "none",
          ...style?.backgroundColor ? { backgroundColor: style.backgroundColor } : {}
        }
      });
    }
    if (findAll(pageNode, "pageFooter").length) {
      warnings.push(workbookGap(
        "page footer panel",
        `page "${pages[i].name}" has a Cognos pageFooter, but released workbook panels support header/sidebar only. Preserve footer content as ordinary page elements or a page-break print section.`
      ));
    }
  });
  const stats = {
    queries: queries.size,
    tables: pageEls.filter((e) => e.kind === "table").length,
    pivots: pageEls.filter((e) => e.kind === "pivot-table").length,
    kpis: pageEls.filter((e) => e.kind === "kpi-chart").length,
    charts: pageEls.filter((e) => e.kind.endsWith("-chart") && e.kind !== "kpi-chart").length,
    maps: pageEls.filter((e) => e.kind.endsWith("-map")).length,
    columns: pageEls.reduce((n, e) => n + (e.columns?.length || 0), 0),
    filters: pageEls.reduce((n, e) => n + (e.filters?.length || 0), 0),
    controls: controls.size,
    refMarks: pageEls.reduce((n, e) => n + (e.refMarks?.length || 0), 0),
    scaleColors: pageEls.filter((e) => e.color?.by === "scale").length,
    pages: pages.length,
    progress: pageEls.filter((e) => e.kind === "progress").length,
    repeaters: pageEls.filter((e) => e.kind === "repeated-container").length,
    panels: pageEls.filter((e) => e.kind === "container").length,
    pagePanels: panels.length,
    pageBreaks: pageEls.filter((e) => e.kind === "page-break").length
  };
  const elements = pages.flatMap((page) => elementsByPage.get(page.id) || []);
  const document = {
    schemaVersion: 1,
    kind: "workbook",
    pages,
    elements,
    layout: buildAuthoritativeLayout(pages, elementsByPage, containerChildren),
    ...panels.length ? { panels } : {}
  };
  return {
    workbook: wrap(document, { name: reportName }),
    warnings,
    stats
  };
}

// cli.ts
function loadLearnedRules() {
  try {
    const p = join(homedir(), ".cognos-to-sigma", "learned-rules.json");
    const rules = JSON.parse(readFileSync(p, "utf8"));
    const arr3 = Array.isArray(rules) ? rules : rules.rules || [];
    if (arr3.length) console.error(`[learned-rules] applying ${arr3.length} customer rule(s) from ${p}`);
    return arr3;
  } catch {
    return [];
  }
}
var args = process.argv.slice(2);
var file = args.find((a) => !a.startsWith("--"));
var opt = (k, d = "") => {
  const i = args.indexOf("--" + k);
  return i >= 0 ? args[i + 1] : d;
};
if (!file) {
  console.error("usage: cli.ts <module.json|report.xml> [--connection X --database DB --schema S --dm ID]");
  process.exit(1);
}
function loadMetrics() {
  const p = opt("metrics");
  if (!p) return void 0;
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch (e) {
    console.error(`[metrics] could not read ${p} (${e.message}); measures stay inline`);
    return void 0;
  }
}
var xml = readFileSync(file, "utf8");
var isReport = file.endsWith(".xml") || xml.trimStart().startsWith("<");
var res = isReport ? convertCognosReportToSigma(xml, { dataModelId: opt("dm", "<DM_ID>"), metrics: loadMetrics() }) : convertCognosToSigma(xml, { connectionId: opt("connection", "<CONNECTION_ID>"), database: opt("database"), schema: opt("schema"), learnedRules: loadLearnedRules() });
var payload = isReport ? res.workbook : res.model;
process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
console.error(`
[${isReport ? "report\u2192workbook" : "module\u2192data-model"}] stats: ${JSON.stringify(res.stats)}`);
var security = res.security;
if (security?.length) {
  const out = opt("security-out", "security.json");
  writeFileSync(out, JSON.stringify(security, null, 2));
  console.error(`SECURITY: ${security.length} rule(s) detected \u2192 ${out} \u2014 run scripts/apply_sigma_rls.py after posting the model (see SKILL.md "Security").`);
}
if (res.warnings.length) {
  console.error(`warnings (${res.warnings.length}) \u2014 translated where possible, flagged where not:`);
  res.warnings.forEach((w) => console.error("  ! " + w));
}
