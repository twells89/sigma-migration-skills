// ../../../Users/tjwells/sigma-data-model-mcp/build/sigma-ids.js
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
    id = Array.from({ length: len }, () => SIGMA_CHARS[Math.floor(Math.random() * SIGMA_CHARS.length)]).join("");
  } while (_usedIds.has(id));
  _usedIds.add(id);
  return id;
}
function sigmaDisplayName(s) {
  const normalized = (s || "").replace(/([a-z])([A-Z])/g, "$1_$2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2").replace(/([A-Za-z])([0-9])/g, "$1_$2").replace(/([0-9])([A-Za-z])/g, "$1_$2");
  const words = normalized.toLowerCase().split(/[_\s]+/).filter(Boolean);
  return words.map((w, i) => i === 0 || !SIGMA_LOWERCASE_WORDS.has(w) ? w.charAt(0).toUpperCase() + w.slice(1) : w).join(" ");
}
function formatFromMask(mask) {
  if (!mask || typeof mask !== "string")
    return null;
  const s = mask.trim();
  if (!s || /general|date|time|@|yy|dd/i.test(s))
    return null;
  const decM = s.match(/\.([0#]+)/);
  const decimals = decM ? decM[1].length : 0;
  const isPercent = /%/.test(s);
  const isCurrency = /[$£€¥]/.test(s);
  if (isPercent)
    return { kind: "number", formatString: `,.${decimals}%` };
  if (isCurrency)
    return { kind: "number", formatString: `$,.${decimals}f`, currencySymbol: "$" };
  if (/[0#]/.test(s))
    return { kind: "number", formatString: `,.${decimals}f` };
  return null;
}
function inferSigmaFormat(formula, displayName, sourceMask) {
  const fromMask = formatFromMask(sourceMask);
  if (fromMask)
    return fromMask;
  if (!formula)
    return null;
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
function _securityElementName(el) {
  if (el?.name)
    return el.name;
  const path = el?.source?.path;
  return path && path.length ? String(path[path.length - 1]) : void 0;
}
function makeRlsSecurity(opts) {
  const attrs = [...opts.formula.matchAll(/CurrentUserAttributeText\(\s*"([^"]+)"/g)].map((m) => m[1]);
  const teams = [...opts.formula.matchAll(/CurrentUserInTeam\(\s*"([^"]+)"/g)].map((m) => m[1]);
  const usesEmail = /\bCurrentUserEmail\(/.test(opts.formula);
  const provision = [
    attrs.length ? `provision/assign Sigma user attribute(s): ${[...new Set(attrs)].join(", ")}` : "",
    teams.length ? `create Sigma team(s) + membership: ${[...new Set(teams)].join(", ")}` : "",
    usesEmail && !attrs.length && !teams.length ? "uses CurrentUserEmail() \u2014 no provisioning needed" : ""
  ].filter(Boolean).join("; ");
  return {
    kind: "rls",
    source: opts.source,
    elementId: opts.element.id,
    elementName: _securityElementName(opts.element),
    rls: {
      name: opts.name,
      formula: opts.formula,
      userAttributes: attrs.length ? [...new Set(attrs)] : void 0,
      teams: teams.length ? [...new Set(teams)] : void 0,
      usesCurrentUserEmail: usesEmail || void 0
    },
    note: `Fail-closed RLS (boolean calc + element filter, only True rows). ${provision || "review"}. The skill provisions then applies \u2014 the converter does NOT inject it.`
  };
}
function makeClsSecurity(opts) {
  return {
    kind: "cls",
    source: opts.source,
    elementId: opts.element.id,
    elementName: _securityElementName(opts.element),
    cls: { restrictedColumnIds: opts.columnIds, restrictedColumnNames: opts.columnNames, criteria: { kind: "no-one-can-view" } },
    note: opts.note || "Column-level security: restrict via columnSecurities (no-one-can-view, or re-scope to a team/attribute allowlist). The skill applies it \u2014 the converter does NOT inject it."
  };
}
function buildDerivedElements(elements) {
  const derived = [];
  for (const srcEl of elements) {
    if (!srcEl.relationships?.length)
      continue;
    if (srcEl.source?.kind !== "warehouse-table")
      continue;
    const srcPath = srcEl.source.path || [];
    const srcTableName = srcPath[srcPath.length - 1] || "";
    const baseName = srcEl.name || srcTableName;
    const derivedName = `${srcEl.name || sigmaDisplayName(srcTableName)} View`;
    const viewCols = [];
    const viewOrder = [];
    for (const col of srcEl.columns || []) {
      if (!col.formula || col.formula.startsWith("/*"))
        continue;
      let dispName;
      const fm = col.formula.match(/^\[([^\/\]]+)\/([^\]]+)\]$/);
      if (fm)
        dispName = fm[2];
      else if (col.name)
        dispName = String(col.name);
      if (!dispName)
        continue;
      if (dispName.includes("/"))
        continue;
      const cId = sigmaShortId();
      viewCols.push({ id: cId, formula: `[${baseName}/${dispName}]` });
      viewOrder.push(cId);
    }
    for (const rel of srcEl.relationships) {
      if (!rel.name)
        continue;
      const tgtEl = elements.find((e) => e.id === rel.targetElementId);
      if (!tgtEl || tgtEl.source?.kind !== "warehouse-table" && tgtEl.source?.kind !== "sql")
        continue;
      const tgtKeyIds = new Set((rel.keys || []).map((k) => k.targetColumnId));
      for (const col of tgtEl.columns || []) {
        if (tgtKeyIds.has(col.id))
          continue;
        if (!col.formula || col.formula.startsWith("/*"))
          continue;
        let dispName;
        if (col.name) {
          dispName = String(col.name);
        } else {
          const fm = col.formula.match(/^\[([^\]]+)\]$/);
          if (fm) {
            const inner = fm[1];
            const s = inner.indexOf("/");
            dispName = s >= 0 ? inner.slice(s + 1) : inner;
          }
        }
        if (!dispName)
          continue;
        if (dispName.includes("/"))
          continue;
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

// ../../../Users/tjwells/sigma-data-model-mcp/build/qlik.js
function convertQlikToSigma(rawJson, options = {}) {
  resetIds();
  const { connectionId = "<CONNECTION_ID>", database: dbOverride = "", schema: schOverride = "" } = options;
  const warnings = [];
  const security = [];
  const workbookPatterns = [];
  const { tables, masterMeasures, masterDimensions, appName } = qlikParseInput(rawJson);
  const modelName = rawJson.appName || rawJson.appId || appName || "Qlik App";
  if (!tables.length)
    throw new Error("No tables found in input. Check the JSON format.");
  const userTables = tables.filter((t) => t.name && !t.name.startsWith("$") && !/^%.*%$/.test(t.name));
  if (userTables.length < tables.length) {
    warnings.push(`${tables.length - userTables.length} system table(s) skipped ($\u2026 and %%name%% synthetic key tables).`);
  }
  const elements = [];
  const tableElementMap = {};
  for (const t of userTables) {
    const elementId = sigmaShortId();
    const columns = [];
    const order = [];
    const colMap = {};
    const tablePrefix = t.name.toUpperCase();
    const visibleFields = (t.fields || []).filter((f) => f.name && !f.isSystem && !f.isHidden && !f.name.startsWith("$"));
    for (const f of visibleFields) {
      const displayName = sigmaDisplayName(f.name);
      const colId = sigmaShortId();
      columns.push({ id: colId, formula: `[${tablePrefix}/${displayName}]` });
      order.push(colId);
      colMap[f.name] = { colId, displayName };
    }
    const pathParts = [];
    if (dbOverride)
      pathParts.push(dbOverride);
    if (schOverride)
      pathParts.push(schOverride);
    pathParts.push(tablePrefix);
    const element = {
      id: elementId,
      kind: "table",
      source: { connectionId, kind: "warehouse-table", path: pathParts },
      columns,
      order
    };
    elements.push(element);
    tableElementMap[t.name] = { elementId, colMap, element, rowCount: t.noOfRows || 0, fields: t.fields || [] };
  }
  const qlikColToDisplayName = {};
  for (const info of Object.values(tableElementMap)) {
    for (const [fieldName, colInfo] of Object.entries(info.colMap)) {
      qlikColToDisplayName[fieldName] = colInfo.displayName;
    }
  }
  const fieldToTables = {};
  for (const t of userTables) {
    for (const f of (t.fields || []).filter((f2) => f2.name && !f2.name.startsWith("$"))) {
      if (!fieldToTables[f.name])
        fieldToTables[f.name] = [];
      fieldToTables[f.name].push(t.name);
    }
  }
  const createdRels = /* @__PURE__ */ new Set();
  for (const [fieldName, tableNames] of Object.entries(fieldToTables)) {
    if (tableNames.length < 2)
      continue;
    if (tableNames.length > 2) {
      warnings.push(`Field "${fieldName}" links ${tableNames.length} tables (${tableNames.join(", ")}). Complex association \u2014 review relationships in Sigma.`);
    }
    for (let i = 0; i < tableNames.length - 1; i++) {
      for (let j = i + 1; j < tableNames.length; j++) {
        const infoA = tableElementMap[tableNames[i]];
        const infoB = tableElementMap[tableNames[j]];
        if (!infoA || !infoB)
          continue;
        const relKey = [infoA.elementId, infoB.elementId].sort().join("|") + "|" + fieldName;
        if (createdRels.has(relKey))
          continue;
        createdRels.add(relKey);
        const aField = infoA.fields.find((f) => f.name === fieldName);
        const bField = infoB.fields.find((f) => f.name === fieldName);
        const aDistinct = aField ? aField.distinctValueCount || 0 : 0;
        const bDistinct = bField ? bField.distinctValueCount || 0 : 0;
        const aRatio = infoA.rowCount > 0 && aDistinct > 0 ? aDistinct / infoA.rowCount : 0;
        const bRatio = infoB.rowCount > 0 && bDistinct > 0 ? bDistinct / infoB.rowCount : 0;
        const hasPkSide = aRatio >= 0.9 || bRatio >= 0.9;
        const noInfo = aRatio === 0 && bRatio === 0;
        if (!hasPkSide && !noInfo)
          continue;
        const toInfo = aRatio >= bRatio ? infoA : infoB;
        const fromInfo = aRatio >= bRatio ? infoB : infoA;
        const fromColInfo = fromInfo.colMap[fieldName];
        const toColInfo = toInfo.colMap[fieldName];
        if (!fromColInfo || !toColInfo)
          continue;
        if (!fromInfo.element.relationships)
          fromInfo.element.relationships = [];
        const tgtPath = toInfo.element.source?.path;
        fromInfo.element.relationships.push({
          id: sigmaShortId(),
          targetElementId: toInfo.elementId,
          keys: [{ sourceColumnId: fromColInfo.colId, targetColumnId: toColInfo.colId }],
          name: tgtPath ? tgtPath[tgtPath.length - 1].toUpperCase() : fieldName.toUpperCase()
        });
      }
    }
  }
  for (const rel of rawJson.relationships || []) {
    const fromInfo = tableElementMap[rel.fromTable];
    const toInfo = tableElementMap[rel.toTable];
    if (!fromInfo || !toInfo)
      continue;
    const fromColInfo = fromInfo.colMap[rel.fromField];
    const toColInfo = toInfo.colMap[rel.toField];
    if (!fromColInfo || !toColInfo) {
      warnings.push(`Explicit relationship ${rel.fromTable}.${rel.fromField} \u2192 ${rel.toTable}.${rel.toField}: column not found, skipped.`);
      continue;
    }
    const relKey = [fromInfo.elementId, toInfo.elementId].sort().join("|") + "|" + rel.fromField;
    if (createdRels.has(relKey))
      continue;
    createdRels.add(relKey);
    if (!fromInfo.element.relationships)
      fromInfo.element.relationships = [];
    const expPath = toInfo.element.source?.path;
    fromInfo.element.relationships.push({
      id: sigmaShortId(),
      targetElementId: toInfo.elementId,
      keys: [{ sourceColumnId: fromColInfo.colId, targetColumnId: toColInfo.colId }],
      name: expPath ? expPath[expPath.length - 1].toUpperCase() : rel.toTable.toUpperCase()
    });
  }
  const measuresByElement = {};
  for (const el of elements)
    measuresByElement[el.id] = [];
  const aggrElements = [];
  for (const m of masterMeasures) {
    const title = m.title || m.qTitle || "Metric";
    const exprRaw = m.expr || m.qDef || m.expression || "";
    const ctx = { patterns: workbookPatterns };
    let sigmaFormula = qlikExprToSigma(exprRaw, warnings, title, ctx);
    if (!sigmaFormula)
      continue;
    if (sigmaFormula.startsWith(QLIK_AGGR_SENTINEL)) {
      const aggrExpr = sigmaFormula.slice(QLIK_AGGR_SENTINEL.length);
      const lowered = lowerQlikAggr(aggrExpr, title, tableElementMap, connectionId, warnings);
      if (!lowered)
        continue;
      aggrElements.push(lowered.element);
      const metric2 = { id: sigmaShortId(), formula: lowered.metricFormula, name: title };
      if (m.description || m.qDescription)
        metric2.description = m.description || m.qDescription;
      const fmt2 = inferSigmaFormat(lowered.metricFormula, title);
      if (fmt2)
        metric2.format = fmt2;
      if (!lowered.element.metrics)
        lowered.element.metrics = [];
      lowered.element.metrics.push(metric2);
      continue;
    }
    if (sigmaFormula.startsWith(QLIK_FSV_SENTINEL)) {
      const fsvExpr = sigmaFormula.slice(QLIK_FSV_SENTINEL.length);
      const lowered = lowerQlikFirstSortedValue(fsvExpr, title, tableElementMap, connectionId, warnings);
      if (lowered) {
        aggrElements.push(lowered.element);
        const metric2 = { id: sigmaShortId(), formula: lowered.metricFormula, name: title };
        if (m.description || m.qDescription)
          metric2.description = m.description || m.qDescription;
        if (!lowered.element.metrics)
          lowered.element.metrics = [];
        lowered.element.metrics.push(metric2);
      } else {
        const fp = fsvRankPattern(fsvExpr, warnings, title);
        if (fp.formula) {
          fp.formula = tidyFormula(bracketKnownBareFields(fp.formula, qlikColToDisplayName).replace(/\[([^\]\/]+)\]/g, (_m2, colName) => qlikColToDisplayName[colName] ? `[${qlikColToDisplayName[colName]}]` : _m2));
        }
        workbookPatterns.push(fp);
        warnings.push(`\u2139 "${title}": FirstSortedValue() \u2192 Rank=n-filter workbook pattern (result.workbookPatterns) \u2014 build it in a GROUPED workbook element and VERIFY values against Qlik.`);
      }
      continue;
    }
    sigmaFormula = bracketKnownBareFields(sigmaFormula, qlikColToDisplayName).replace(/\[([^\]\/]+)\]/g, (_m, colName) => qlikColToDisplayName[colName] ? `[${qlikColToDisplayName[colName]}]` : _m);
    let bestElementId = elements[0]?.id;
    outer: for (const [, info] of Object.entries(tableElementMap)) {
      for (const [fn, dn] of Object.entries(info.colMap)) {
        if (sigmaFormula.includes(`[${dn.displayName}]`) || sigmaFormula.includes(`[${fn}]`)) {
          bestElementId = info.elementId;
          break outer;
        }
      }
    }
    if (ctx.window) {
      const bestEl = elements.find((e) => e.id === bestElementId);
      const bestPath = bestEl?.source?.path;
      workbookPatterns.push({
        kind: ctx.kind || "rank",
        name: title,
        source: exprRaw,
        formula: tidyFormula(sigmaFormula),
        requires: QLIK_GROUPED_REQUIRES,
        elementId: bestElementId,
        elementName: bestEl?.name || (bestPath ? bestPath[bestPath.length - 1] : void 0),
        ...ctx.verify ? { verify: true } : {},
        note: ctx.notes?.length ? ctx.notes.join(" ") : "Translated Qlik inter-record expression."
      });
      warnings.push(`\u2139 "${title}": inter-record/window expression \u2192 ready Sigma formula in result.workbookPatterns \u2014 place as a calculation in a GROUPED workbook element (group by the chart's dimension); not emitted as a DM metric (a metric aggregates across rows, so it can't express a per-row window; native window funcs belong in a workbook element or a DM-element calc column).`);
      continue;
    }
    if (!measuresByElement[bestElementId])
      measuresByElement[bestElementId] = [];
    const metric = { id: sigmaShortId(), formula: sigmaFormula, name: title };
    if (m.description || m.qDescription)
      metric.description = m.description || m.qDescription;
    const fmt = inferSigmaFormat(sigmaFormula, title);
    if (fmt)
      metric.format = fmt;
    measuresByElement[bestElementId].push(metric);
  }
  for (const el of elements) {
    const metrics = measuresByElement[el.id];
    if (metrics?.length)
      el.metrics = metrics;
  }
  for (const ae of aggrElements)
    elements.push(ae);
  const derivedEls = buildDerivedElements(elements);
  for (const de of derivedEls)
    elements.push(de);
  const displayNameToElementIds = {};
  for (const el of elements) {
    if (el.source?.kind !== "warehouse-table")
      continue;
    for (const c of el.columns || []) {
      if (!c.formula)
        continue;
      const m = c.formula.match(/^\[[^\]\/]+\/([^\]]+)\]$/);
      if (!m)
        continue;
      const dn = m[1].toUpperCase();
      if (!displayNameToElementIds[dn])
        displayNameToElementIds[dn] = /* @__PURE__ */ new Set();
      displayNameToElementIds[dn].add(el.id);
    }
  }
  const qlikNameToElementIds = {};
  for (const [tableName, info] of Object.entries(tableElementMap)) {
    void tableName;
    for (const fieldName of Object.keys(info.colMap)) {
      const k = fieldName.toUpperCase();
      if (!qlikNameToElementIds[k])
        qlikNameToElementIds[k] = /* @__PURE__ */ new Set();
      qlikNameToElementIds[k].add(info.elementId);
    }
  }
  const relatedNameMapBySrc = {};
  for (const srcEl of elements) {
    if (srcEl.source?.kind !== "warehouse-table")
      continue;
    if (!srcEl.relationships?.length)
      continue;
    const srcPath = srcEl.source.path || [];
    const srcBaseName = srcEl.name || srcPath[srcPath.length - 1] || "";
    if (!srcBaseName)
      continue;
    const map = {};
    for (const rel of srcEl.relationships || []) {
      if (!rel.name)
        continue;
      const tgtEl = elements.find((e) => e.id === rel.targetElementId);
      if (!tgtEl || tgtEl.source?.kind !== "warehouse-table")
        continue;
      for (const tc of tgtEl.columns || []) {
        if (!tc.formula || tc.formula.startsWith("/*"))
          continue;
        const fm = tc.formula.match(/^\[([^\]]+)\]$/);
        if (!fm)
          continue;
        const inner = fm[1];
        const s = inner.lastIndexOf("/");
        const dispName = s >= 0 ? inner.slice(s + 1) : inner;
        if (!(dispName in map))
          map[dispName] = `${srcBaseName}/${rel.name}/${dispName}`;
      }
    }
    relatedNameMapBySrc[srcEl.id] = map;
  }
  const derivedBySrc = {};
  for (const de of derivedEls) {
    const srcId = de.source?.elementId;
    if (srcId)
      derivedBySrc[srcId] = de;
  }
  for (const d of masterDimensions) {
    const title = d.title || d.qTitle || "Dimension";
    const exprRaw = d.fieldDef || d.qFieldDef || d.expr || d.expression || "";
    const isCalc = exprRaw.trim().startsWith("=") || /\b(If|Sum|Count|Avg|Concat|Year|Month|Day|Left|Right|Upper|Lower|Trim|Class|Dual|Range\w+|Floor|Ceil|Round|Pick|Match|Mid|Replace|WeekDay|Date|Num|Rank|HRank|Above|Below|Peek|Previous|FirstSortedValue)\s*\(/i.test(exprRaw);
    if (!isCalc)
      continue;
    const ctx = { patterns: workbookPatterns };
    let sigmaFormula = qlikExprToSigma(exprRaw, warnings, title, ctx);
    if (!sigmaFormula)
      continue;
    if (sigmaFormula.startsWith(QLIK_FSV_SENTINEL)) {
      const fp = fsvRankPattern(sigmaFormula.slice(QLIK_FSV_SENTINEL.length), warnings, title);
      if (fp.formula) {
        fp.formula = tidyFormula(bracketKnownBareFields(fp.formula, qlikColToDisplayName).replace(/\[([^\]\/]+)\]/g, (_m2, colName) => qlikColToDisplayName[colName] ? `[${qlikColToDisplayName[colName]}]` : _m2));
      }
      fp.note += " (Qlik master dimension.)";
      workbookPatterns.push(fp);
      warnings.push(`\u2139 Calc dimension "${title}": FirstSortedValue() \u2192 Rank=n-filter workbook pattern (result.workbookPatterns) \u2014 build in a GROUPED workbook element and VERIFY.`);
      continue;
    }
    sigmaFormula = bracketKnownBareFields(sigmaFormula, qlikColToDisplayName);
    const refsRaw = (sigmaFormula.match(/\[([^\]\/]+)\]/g) || []).map((r) => r.slice(1, -1)).filter((r) => !/^(true|false|null)$/i.test(r));
    const elementHits = {};
    for (const ref of refsRaw) {
      const upper = ref.toUpperCase();
      const ids = qlikNameToElementIds[upper] || displayNameToElementIds[upper] || /* @__PURE__ */ new Set();
      for (const id of ids)
        elementHits[id] = (elementHits[id] || 0) + 1;
    }
    sigmaFormula = sigmaFormula.replace(/\[([^\]\/]+)\]/g, (_m, colName) => qlikColToDisplayName[colName] ? `[${qlikColToDisplayName[colName]}]` : _m);
    if (ctx.window) {
      workbookPatterns.push({
        kind: ctx.kind || "rank",
        name: title,
        source: exprRaw,
        formula: tidyFormula(sigmaFormula),
        requires: QLIK_GROUPED_REQUIRES,
        ...ctx.verify ? { verify: true } : {},
        note: (ctx.notes?.length ? ctx.notes.join(" ") : "Translated Qlik inter-record expression.") + " (Qlik master dimension.)"
      });
      warnings.push(`\u2139 Calc dimension "${title}": inter-record/window expression \u2192 ready Sigma formula in result.workbookPatterns \u2014 place in a GROUPED workbook element; not emitted as a DM column (native window funcs also resolve in a DM-element calc column; grouped here for the partition/order that match the Qlik chart).`);
      continue;
    }
    const distinctElIds = Object.keys(elementHits);
    const colId = sigmaShortId();
    const fmt = inferSigmaFormat(sigmaFormula, title);
    const col = { id: colId, formula: sigmaFormula, name: title };
    if (fmt)
      col.format = fmt;
    if (distinctElIds.length === 1) {
      const targetEl = elements.find((e) => e.id === distinctElIds[0]);
      if (!targetEl)
        continue;
      targetEl.columns.push(col);
      targetEl.order.push(colId);
    } else if (distinctElIds.length > 1) {
      const srcElId = distinctElIds.sort((a, b) => (elementHits[b] || 0) - (elementHits[a] || 0))[0];
      const de = derivedBySrc[srcElId];
      const srcEl = elements.find((e) => e.id === srcElId);
      const relMap = relatedNameMapBySrc[srcElId] || {};
      if (!de) {
        warnings.push(`\u26A0 Calc dimension "${title}" has cross-element refs but no derived element exists for ${srcEl ? srcEl.name : srcElId} \u2014 column dropped`);
        continue;
      }
      col.formula = col.formula.replace(/\[([^\]\/]+)\]/g, (m, refName) => {
        return relMap[refName] ? `[${relMap[refName]}]` : m;
      });
      de.columns.push(col);
      de.order.push(colId);
      warnings.push(`\u2139 Calc dimension "${title}" placed on derived "${de.name}" (cross-element refs)`);
    } else {
      const targetEl = elements.find((e) => e.source?.kind === "warehouse-table");
      if (!targetEl)
        continue;
      targetEl.columns.push(col);
      targetEl.order.push(colId);
    }
  }
  const sa = rawJson.sectionAccess;
  if (typeof sa === "string") {
    warnings.push("\u26A0 Qlik SECTION ACCESS supplied as raw script \u2014 not auto-parsed. Pass a parsed { reductionFields[], omitFields[], keyedBy } object to port it.");
  } else if (sa && typeof sa === "object") {
    const findField = (name) => {
      const up = (name || "").toUpperCase().replace(/\s+/g, "_");
      for (const info of Object.values(tableElementMap)) {
        for (const [fn, ci] of Object.entries(info.colMap)) {
          if (fn.toUpperCase() === up || ci.displayName.toUpperCase().replace(/\s+/g, "_") === up)
            return { el: info.element, disp: ci.displayName, colId: ci.colId };
        }
      }
      return null;
    };
    const keyedBy = (sa.keyedBy || "group").toLowerCase();
    const reductions = sa.reductionFields || (sa.reductionField ? [sa.reductionField] : []);
    for (const rf of reductions) {
      const hit = findField(rf);
      if (!hit) {
        warnings.push(`\u26A0 Section Access REDUCTION field "${rf}" not found in the model \u2014 re-apply RLS manually.`);
        continue;
      }
      const formula = keyedBy === "userid" ? `CurrentUserAttributeText("${sigmaDisplayName(rf)}") = [${hit.disp}]` : `CurrentUserInTeam([${hit.disp}])`;
      security.push(makeRlsSecurity({ source: `Qlik Section Access REDUCTION on [${hit.disp}]`, element: hit.el, name: `RLS: ${hit.disp}`, formula }));
      warnings.push(`\u{1F510} Qlik Section Access REDUCTION on [${hit.disp}] \u2192 row-level security DETECTED (reported in result.security, not injected; strict-exclusion \u2261 fail-closed). ${keyedBy === "userid" ? `The skill provisions user attribute "${sigmaDisplayName(rf)}" per user (multi-value reductions need an or-chain)` : `The skill recreates the Qlik GROUP values as Sigma teams`} and applies the RLS calc + filter.`);
    }
    for (const om of sa.omitFields || (sa.omitField ? [sa.omitField] : [])) {
      const hit = findField(om);
      if (!hit)
        continue;
      security.push(makeClsSecurity({ source: `Qlik Section Access OMIT [${hit.disp}]`, element: hit.el, columnIds: [hit.colId], columnNames: [hit.disp], note: "Qlik OMIT is per-user/group; Sigma CLS is no-one-can-view (or re-scope to a team/attribute allowlist). The skill applies it \u2014 not injected." }));
      warnings.push(`\u{1F510} Qlik Section Access OMIT [${hit.disp}] \u2192 column-level security DETECTED (reported in result.security, not injected).`);
    }
  }
  const stats = {
    elements: elements.length,
    columns: elements.reduce((n, e) => n + (e.columns?.length || 0), 0),
    metrics: elements.reduce((n, e) => n + (e.metrics?.length || 0), 0),
    relationships: elements.reduce((n, e) => n + (e.relationships?.length || 0), 0)
  };
  return {
    model: { name: sigmaDisplayName(modelName), schemaVersion: 1, pages: [{ id: sigmaShortId(), name: "Page 1", elements }] },
    warnings,
    ...security.length ? { security } : {},
    ...workbookPatterns.length ? { workbookPatterns } : {},
    stats
  };
}
function _decodeXmlEntity(s) {
  return s.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'");
}
function _xmlText(scope, tag) {
  const m = scope.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`));
  return m ? _decodeXmlEntity(m[1].trim()) : "";
}
function _xmlSection(scope, tag) {
  const m = scope.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`));
  return m ? m[1] : "";
}
function parseQvdHeader(buf) {
  const len = buf.length;
  let endIdx = -1;
  for (let i = 0; i < len; i++) {
    if (buf[i] === 0) {
      endIdx = i;
      break;
    }
  }
  if (endIdx < 0)
    throw new Error("QVD header: no NUL terminator found \u2014 not a valid QVD file");
  const xml = Buffer.from(buf.slice(0, endIdx)).toString("utf8");
  if (!xml.includes("<QvdTableHeader>"))
    throw new Error("QVD header: missing <QvdTableHeader> root element");
  const tableName = _xmlText(xml, "TableName");
  const noOfRecords = parseInt(_xmlText(xml, "NoOfRecords") || "0", 10);
  const fieldsScope = _xmlSection(xml, "Fields");
  const fields = [];
  const fieldRe = /<QvdFieldHeader>([\s\S]*?)<\/QvdFieldHeader>/g;
  let m;
  while (m = fieldRe.exec(fieldsScope)) {
    const f = m[1];
    const name = _xmlText(f, "FieldName");
    const numFmt = _xmlSection(f, "NumberFormat");
    const type = _xmlText(numFmt, "Type") || "UNKNOWN";
    const tagsScope = _xmlSection(f, "Tags");
    const tagRe = /<String>([^<]+)<\/String>/g;
    const tags = [];
    let tm;
    while (tm = tagRe.exec(tagsScope))
      tags.push(tm[1]);
    const noOfSymbols = parseInt(_xmlText(f, "NoOfSymbols") || "0", 10);
    if (name)
      fields.push({ name, type, tags, noOfSymbols });
  }
  return { tableName: tableName || "", noOfRecords, fields };
}
function _qvdHeaderToQtrTable(h, fallbackName) {
  return {
    qName: h.tableName || fallbackName,
    qNoOfRows: h.noOfRecords,
    qFields: h.fields.map((f) => ({
      qName: f.name,
      qnTotalDistinctValues: f.noOfSymbols,
      qnRows: h.noOfRecords,
      qTags: f.tags
    }))
  };
}
function convertQvdsToSigma(qvds, options = {}) {
  const headers = [];
  const warnings = [];
  for (const qf of qvds) {
    try {
      const h = parseQvdHeader(qf.buffer);
      headers.push(h);
    } catch (e) {
      warnings.push(`${qf.name}: failed to parse QVD header \u2014 ${e.message}`);
    }
  }
  const qtr = headers.map((h, i) => {
    const qf = qvds[i];
    const fallback = (qf.name || "").replace(/\.qvd$/i, "").toUpperCase();
    return _qvdHeaderToQtrTable(h, fallback);
  });
  const synthetic = {
    appName: "Qlik QVDs",
    qtr,
    masterMeasures: [],
    masterDimensions: []
  };
  const result = convertQlikToSigma(synthetic, options);
  result.warnings = [...warnings, ...result.warnings];
  return result;
}
function qlikParseInput(raw) {
  let tables = [], masterMeasures = [], masterDimensions = [], appName = "";
  if (Array.isArray(raw?.qtr)) {
    appName = raw.appName || raw.qAppId || "Qlik App";
    tables = raw.qtr.map((t) => ({
      name: t.qName || "",
      noOfRows: t.qNoOfRows || 0,
      fields: (t.qFields || []).map((f) => ({
        name: f.qName || "",
        distinctValueCount: f.qnTotalDistinctValues || f.qnPresentDistinctValues || 0,
        noOfRows: f.qnRows || t.qNoOfRows || 0,
        isSystem: (f.qName || "").startsWith("$")
      }))
    }));
    masterMeasures = raw.masterMeasures || [];
    masterDimensions = raw.masterDimensions || [];
  } else if (Array.isArray(raw?.tables)) {
    appName = raw.appName || raw.appId || "Qlik App";
    tables = raw.tables.map((t) => ({
      name: t.name || t.qName || "",
      noOfRows: t.noOfRows || t.qNoOfRows || 0,
      fields: (t.fields || t.qFields || []).map((f) => ({
        name: f.name || f.qName || "",
        distinctValueCount: f.distinctValueCount || f.qDistinctCount || f.qnTotalDistinctValues || 0,
        noOfRows: t.noOfRows || t.qNoOfRows || 0,
        isSystem: f.isSystem || (f.name || f.qName || "").startsWith("$") || false,
        isHidden: f.isHidden || false
      }))
    }));
    masterMeasures = raw.masterMeasures || [];
    masterDimensions = raw.masterDimensions || [];
  }
  return { tables, masterMeasures, masterDimensions, appName };
}
var QLIK_SET_AGGS = ["Sum", "Count", "Avg", "Min", "Max", "Median", "Only"];
function matchClose(s, open, oc, cc) {
  let depth = 0;
  for (let i = open; i < s.length; i++) {
    const ch = s[i];
    if (ch === "'" || ch === '"') {
      const q = ch;
      i++;
      while (i < s.length && s[i] !== q)
        i++;
      continue;
    }
    if (ch === oc)
      depth++;
    else if (ch === cc) {
      depth--;
      if (depth === 0)
        return i;
    }
  }
  return -1;
}
function splitTopLevel(s, delim) {
  const out = [];
  let depth = 0, start = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "'" || ch === '"') {
      const q = ch;
      i++;
      while (i < s.length && s[i] !== q)
        i++;
      continue;
    }
    if (ch === "{" || ch === "(" || ch === "[")
      depth++;
    else if (ch === "}" || ch === ")" || ch === "]")
      depth--;
    else if (depth === 0 && ch === delim) {
      out.push(s.slice(start, i));
      start = i + 1;
    }
  }
  out.push(s.slice(start));
  return out;
}
function lowerRangeFns(f, warnings, name) {
  const re = /\bRange(Sum|Avg|Min|Max)\s*\(/i;
  let guard = 0;
  let m;
  while ((m = f.match(re)) && guard++ < 50) {
    const fn = m[1].toLowerCase();
    const idx = m.index;
    const open = f.indexOf("(", idx);
    const close = matchClose(f, open, "(", ")");
    if (close < 0)
      break;
    const args = splitTopLevel(f.slice(open + 1, close), ",").map((a) => a.trim()).filter((a) => a.length);
    if (args.length === 0)
      break;
    let repl;
    if (fn === "sum") {
      repl = "(" + args.map((a) => `Coalesce(${a}, 0)`).join(" + ") + ")";
    } else if (fn === "avg") {
      repl = "((" + args.map((a) => `Coalesce(${a}, 0)`).join(" + ") + `) / ${args.length})`;
      warnings?.push(`"${name}": RangeAvg() translated with a fixed denominator (${args.length}); Qlik excludes nulls from the divisor.`);
    } else if (fn === "min") {
      repl = `Least(${args.join(", ")})`;
    } else {
      repl = `Greatest(${args.join(", ")})`;
    }
    f = f.slice(0, idx) + repl + f.slice(close + 1);
  }
  return f;
}
function lowerClass(f, warnings, name) {
  const re = /\bClass\s*\(/i;
  let guard = 0;
  let m;
  while ((m = f.match(re)) && guard++ < 50) {
    const idx = m.index;
    const open = f.indexOf("(", idx);
    const close = matchClose(f, open, "(", ")");
    if (close < 0)
      break;
    const args = splitTopLevel(f.slice(open + 1, close), ",").map((a) => a.trim());
    const val = args[0];
    const bs = args[1] || "1";
    const start = args[3];
    const repl = start ? `(Floor((${val} - ${start}) / ${bs}) * ${bs} + ${start})` : `(Floor(${val} / ${bs}) * ${bs})`;
    warnings?.push(`"${name}": Class() lowered to each bin's numeric lower bound (Floor); the textual "lo<=x<hi" label is not reproduced.`);
    f = f.slice(0, idx) + repl + f.slice(close + 1);
  }
  return f;
}
function setValueToCondition(field, rawVal, op) {
  let v = rawVal.trim();
  const qm = v.match(/^['"](.*)['"]$/);
  if (qm) {
    const inner = qm[1].trim();
    const cmp = inner.match(/^(>=|<=|<>|>|<|=)\s*(.+)$/);
    if (cmp) {
      let cop = cmp[1];
      if (op === "<>") {
        const neg = { ">=": "<", "<=": ">", ">": "<=", "<": ">=", "=": "<>", "<>": "=" };
        cop = neg[cop] || cop;
      }
      const rhs = cmp[2].trim();
      const rhsNum = /^-?\d+(\.\d+)?$/.test(rhs);
      return `[${field}]${cop}${rhsNum ? rhs : `"${rhs}"`}`;
    }
    return `[${field}]${op}"${inner}"`;
  }
  if (/^-?\d+(\.\d+)?$/.test(v))
    return `[${field}]${op}${v}`;
  if (/^[A-Za-z0-9_]+$/.test(v))
    return `[${field}]${op}"${v}"`;
  return null;
}
function clauseToCondition(clause) {
  const m = clause.match(/^\s*\[?([A-Za-z0-9_ .]+?)\]?\s*(-=|\+=|=)\s*\{([\s\S]*)\}\s*$/);
  if (!m)
    return null;
  const field = m[1].trim();
  const setOp = m[2];
  const op = setOp === "-=" ? "<>" : "=";
  const body = m[3].trim();
  if (body === "")
    return null;
  if (/[+\-*/](?![=\d])/.test(body) && /\}|\{/.test(body))
    return null;
  if (/\b[PE]\s*\(/.test(body))
    return null;
  const vals = splitTopLevel(body, ",").map((v) => v.trim()).filter(Boolean);
  const conds = [];
  for (const v of vals) {
    const c = setValueToCondition(field, v, op);
    if (!c)
      return null;
    conds.push(c);
  }
  if (!conds.length)
    return null;
  if (conds.length === 1)
    return conds[0];
  const joiner = op === "<>" ? " and " : " or ";
  return `(${conds.join(joiner)})`;
}
function bracketBareFields(expr) {
  const tokens = [];
  const SENT = "";
  const stash = (mm) => {
    tokens.push(mm);
    return ` ${SENT}${tokens.length - 1}${SENT} `;
  };
  let s = expr.replace(/'[^']*'|"[^"]*"|\[[^\]]+\]/g, stash);
  s = s.replace(/\b([A-Za-z_][A-Za-z0-9_]*)\b(\s*\()?/g, (full, ident, call) => {
    if (call)
      return full;
    if (/^(null|true|false)$/i.test(ident))
      return full;
    return `[${ident}]`;
  });
  s = s.replace(new RegExp(SENT + "(\\d+)" + SENT, "g"), (_m, i) => tokens[+i]);
  return s.replace(/ {2,}/g, " ").trim();
}
function bracketKnownBareFields(expr, displayMap) {
  const tokens = [];
  const SENT = "";
  const stash = (mm) => {
    tokens.push(mm);
    return ` ${SENT}${tokens.length - 1}${SENT} `;
  };
  let s = expr.replace(/'[^']*'|"[^"]*"|\[[^\]]+\]/g, stash);
  s = s.replace(/\b([A-Za-z_][A-Za-z0-9_]*)\b(\s*\()?/g, (full, ident, call) => {
    if (call)
      return full;
    return displayMap[ident] ? `[${ident}]` : full;
  });
  s = s.replace(new RegExp(SENT + "(\\d+)" + SENT, "g"), (_m, i) => tokens[+i]);
  return s.replace(/ {2,}/g, " ").trim();
}
function translateSetAnalysis(f, warnings, name) {
  const aggRe = new RegExp(`\\b(${QLIK_SET_AGGS.join("|")})\\s*\\(\\s*\\{`, "i");
  let guard = 0;
  while (aggRe.test(f) && guard++ < 50) {
    const m = aggRe.exec(f);
    if (!m)
      break;
    const aggFn = m[1];
    const parenOpen = f.indexOf("(", m.index);
    const parenClose = matchClose(f, parenOpen, "(", ")");
    if (parenClose < 0)
      return null;
    const argStr = f.slice(parenOpen + 1, parenClose);
    const braceOpen = argStr.indexOf("{");
    const braceClose = matchClose(argStr, braceOpen, "{", "}");
    if (braceClose < 0)
      return null;
    const setSpec = argStr.slice(braceOpen, braceClose + 1);
    const expr = argStr.slice(braceClose + 1).trim();
    const inner = setSpec.replace(/^\{/, "").replace(/\}$/, "").trim();
    const ltIdx = inner.indexOf("<");
    const gtIdx = inner.lastIndexOf(">");
    if (ltIdx < 0 || gtIdx < 0) {
      const ident = inner.replace(/[$1\s]/g, "");
      if (ident) {
        warnings?.push(`"${name}": Set Analysis uses alternate state "${ident}" \u2014 left untranslated.`);
        return null;
      }
      f = f.slice(0, m.index) + `${aggFn}(${bracketBareFields(expr)})` + f.slice(parenClose + 1);
      continue;
    }
    const setIdent = inner.slice(0, ltIdx).trim();
    if (setIdent && !/^[$1]$/.test(setIdent)) {
      warnings?.push(`"${name}": Set Analysis uses alternate state "${setIdent}" \u2014 left untranslated.`);
      return null;
    }
    const modifiers = inner.slice(ltIdx + 1, gtIdx);
    if (/\$\(/.test(modifiers)) {
      warnings?.push(`"${name}": Set Analysis contains a $-expansion macro \u2014 left untranslated.`);
      return null;
    }
    const clauses = splitTopLevel(modifiers, ",").map((c) => c.trim()).filter(Boolean);
    const conds = [];
    for (const cl of clauses) {
      const c = clauseToCondition(cl);
      if (!c) {
        warnings?.push(`"${name}": Set Analysis clause "${cl}" could not be translated \u2014 left untranslated.`);
        return null;
      }
      conds.push(c);
    }
    if (!conds.length || !expr)
      return null;
    const condJoined = conds.length === 1 ? conds[0] : conds.join(" and ");
    const exprBracketed = bracketBareFields(expr);
    const replacement = `${aggFn}(If(${condJoined}, ${exprBracketed}, 0))`;
    f = f.slice(0, m.index) + replacement + f.slice(parenClose + 1);
  }
  if (/\{\s*[\$1<][^}]*\}/.test(f) || /\{\s*<[^}]*>\s*\}/.test(f)) {
    warnings?.push(`"${name}": Set Analysis construct could not be fully translated \u2014 left untranslated.`);
    return null;
  }
  return f;
}
var QLIK_AGGR_SENTINEL = "__QLIK_AGGR__";
var QLIK_AGG_TO_SQL = {
  SUM: "SUM",
  COUNT: "COUNT",
  AVG: "AVG",
  MIN: "MIN",
  MAX: "MAX",
  MEDIAN: "MEDIAN",
  ONLY: "MIN",
  COUNTDISTINCT: "COUNT(DISTINCT",
  NODISTINCT: ""
};
function lowerQlikAggr(expr, name, tableElementMap, connectionId, warnings) {
  const m = expr.match(/^\s*([A-Za-z_]+)\s*\(\s*Aggr\s*\(/i);
  if (!m) {
    warnings?.push(`"${name}": Aggr() not wrapped in a single outer aggregation \u2014 left untranslated.`);
    return null;
  }
  const outerFn = m[1];
  const outerSql = QLIK_AGG_TO_SQL[outerFn.toUpperCase()];
  if (!outerSql || outerSql === "" || outerSql.includes("(")) {
    warnings?.push(`"${name}": Aggr() outer function "${outerFn}" not supported \u2014 left untranslated.`);
    return null;
  }
  const aggrOpen = expr.toLowerCase().indexOf("aggr(", m.index ?? 0);
  const aggrParen = expr.indexOf("(", aggrOpen);
  const aggrClose = matchClose(expr, aggrParen, "(", ")");
  if (aggrClose < 0)
    return null;
  const aggrArgs = splitTopLevel(expr.slice(aggrParen + 1, aggrClose), ",").map((s) => s.trim());
  if (aggrArgs.length < 2) {
    warnings?.push(`"${name}": Aggr() missing grain dimension \u2014 left untranslated.`);
    return null;
  }
  const innerExpr = aggrArgs[0];
  const dims = aggrArgs.slice(1);
  if (/\bAggr\s*\(/i.test(innerExpr)) {
    warnings?.push(`"${name}": nested Aggr() \u2014 left untranslated.`);
    return null;
  }
  const im = innerExpr.match(/^\s*([A-Za-z_]+)\s*\(\s*\[?([A-Za-z0-9_ .]+?)\]?\s*\)\s*$/);
  if (!im) {
    warnings?.push(`"${name}": Aggr() inner expression "${innerExpr}" too complex \u2014 left untranslated.`);
    return null;
  }
  const innerFn = im[1];
  const innerField = im[2].trim();
  const innerSql = QLIK_AGG_TO_SQL[innerFn.toUpperCase()];
  if (innerSql === void 0 || innerSql === "") {
    warnings?.push(`"${name}": Aggr() inner function "${innerFn}" not supported \u2014 left untranslated.`);
    return null;
  }
  const dimFields = dims.map((d) => d.replace(/^\[|\]$/g, "").trim());
  let owner = null;
  for (const info of Object.values(tableElementMap)) {
    const has = (n) => Object.keys(info.colMap).some((k) => k.toUpperCase() === n.toUpperCase());
    if (has(innerField) && dimFields.every(has)) {
      owner = info;
      break;
    }
  }
  if (!owner) {
    warnings?.push(`"${name}": Aggr() grain spans tables or fields not found in one table \u2014 left untranslated.`);
    return null;
  }
  const path = owner.element.source?.path || [];
  if (!path.length) {
    warnings?.push(`"${name}": Aggr() source table path unknown \u2014 left untranslated.`);
    return null;
  }
  const fromSql = path.map((p) => `"${p}"`).join(".");
  const realName = (n) => Object.keys(owner.colMap).find((k) => k.toUpperCase() === n.toUpperCase()) || n;
  const dimCols = dimFields.map(realName);
  const innerCol = realName(innerField);
  const innerAlias = "inner_agg";
  const innerAggSql = innerSql.includes("(") ? `${innerSql} "${innerCol}")` : `${innerSql}("${innerCol}")`;
  const selectCols = [
    ...dimCols.map((c) => `"${c}"`),
    `${innerAggSql} AS "${innerAlias}"`
  ];
  const groupBy = dimCols.map((_c, i) => i + 1).join(", ");
  const statement = `SELECT ${selectCols.join(", ")} FROM ${fromSql} GROUP BY ${groupBy}`;
  const cols = [];
  const order = [];
  for (const dc of dimCols) {
    const id = sigmaShortId();
    cols.push({ id, name: sigmaDisplayName(dc), formula: `[Custom SQL/${dc}]` });
    order.push(id);
  }
  const innerColId = sigmaShortId();
  const innerDisplay = sigmaDisplayName(innerAlias);
  cols.push({ id: innerColId, name: innerDisplay, formula: `[Custom SQL/${innerAlias}]` });
  order.push(innerColId);
  const element = {
    id: sigmaShortId(),
    kind: "table",
    // SQL elements use the implicit "Custom SQL" element name for column-ref
    // prefixes; a descriptive element name is fine (matches QuickSight helper).
    name: `${name} (Aggr)`,
    source: { connectionId, kind: "sql", statement },
    columns: cols,
    order
  };
  const metricFormula = `${outerFn}([${innerDisplay}])`;
  return { element, metricFormula };
}
var QLIK_FSV_SENTINEL = "__QLIK_FSV__";
function tidyFormula(f) {
  return f.replace(/\(\s+/g, "(").replace(/\s+\)/g, ")").replace(/\s+,/g, ",").replace(/ {2,}/g, " ").trim();
}
var QLIK_GROUPED_REQUIRES = "Place as a calculation in a GROUPED workbook element: group by the Qlik chart's dimension(s), sort the element to match the chart's sort order, and put this formula at the grouping level. (Spec gotcha, live-verified 2026-06-11: the element-level `sort` field 400s on grouped tables \u2014 'Sort column not found' \u2014 so a grouped element computes Lag/Lead over the group key ASCENDING at POST time; apply any other sort in the UI afterwards, or pick the grouping key so ascending order matches the Qlik chart.) When placing in a workbook element, prefix base-column refs with the source element name ([Element/Col]). Native window functions (Rank/RankDense/Lag/Lead/RowNumber/Cumulative*/Moving*) resolve in DM-element calc columns and in workbook tables (grouped OR ungrouped/master) \u2014 live-verified 2026-07-15; only the *Over family (SumOver/CountOver/...) errors in every spec context. A GROUPED element is still the recommended placement here because it gives Lag/Lead the partition + ordering that match the Qlik chart.";
var QLIK_IR_RE = /\b(Rank|HRank|VRank|Above|Below|Before|After|Top|Bottom|Previous|Peek)\s*\(/i;
function lowerInterRecordFns(f, warnings, name, original, ctx) {
  const flagUnsupported = (note2) => {
    warnings?.push(`\u26A0 "${name}": ${note2} \u2014 left untranslated (flagged in workbookPatterns).`);
    ctx?.patterns?.push({ kind: "unsupported", name, source: original, note: note2 });
    return null;
  };
  const setKind = (k) => {
    if (!ctx)
      return;
    ctx.window = true;
    if (k === "rank" || !ctx.kind)
      ctx.kind = k;
  };
  const note = (msg) => {
    if (ctx && !(ctx.notes || []).includes(msg))
      (ctx.notes = ctx.notes || []).push(msg);
  };
  let guard = 0;
  let m;
  while ((m = f.match(QLIK_IR_RE)) && guard++ < 50) {
    const fn = m[1].toLowerCase();
    const idx = m.index;
    const open = f.indexOf("(", idx);
    const close = matchClose(f, open, "(", ")");
    if (close < 0)
      return flagUnsupported(`unbalanced parentheses in ${m[1]}()`);
    const args = splitTopLevel(f.slice(open + 1, close), ",").map((a) => a.trim());
    if (fn === "hrank" || fn === "vrank") {
      return flagUnsupported(`${m[1]}() ranks across a pivot table's COLUMN dimension (horizontal rank); Sigma pivots have no spec-level cross-column calculation (that axis is UI-only)`);
    }
    if (fn === "before" || fn === "after" || fn === "top" || fn === "bottom") {
      return flagUnsupported(`${m[1]}() walks a pivot's column segments (chart-position on the column axis); Sigma has no spec-level equivalent`);
    }
    let repl;
    if (fn === "rank") {
      const inner = (args[0] || "").replace(/^total\b\s*/i, "");
      if (!inner)
        return flagUnsupported("Rank() missing expression argument");
      if (args.length > 1 && args[1] && args[1] !== "0") {
        warnings?.push(`"${name}": Rank() mode/fmt argument(s) (${args.slice(1).join(", ")}) ignored \u2014 Sigma Rank uses standard competition ranking (ties share the lowest rank, gap after); verify tie handling.`);
        if (ctx)
          ctx.verify = true;
      }
      repl = `__SIGMA_RANK__(${inner}, "desc")`;
      setKind("rank");
      note(`Qlik Rank(expr) ranks the chart's dimension values by expr descending \u2014 Sigma Rank(expr, "desc") at the grouping level.`);
    } else if (fn === "above" || fn === "below") {
      let effFn = fn === "above" ? "LAG" : "LEAD";
      const inner = (args[0] || "").replace(/^total\b\s*/i, "");
      if (!inner)
        return flagUnsupported(`${m[1]}() missing expression argument`);
      let offset = 1;
      if (args.length > 1 && args[1]) {
        if (!/^-?\d+$/.test(args[1]))
          return flagUnsupported(`${m[1]}() offset "${args[1]}" is not a literal integer`);
        offset = parseInt(args[1], 10);
      }
      if (offset < 0) {
        effFn = effFn === "LAG" ? "LEAD" : "LAG";
        offset = -offset;
      }
      let count = 1;
      if (args.length > 2 && args[2]) {
        if (!/^\d+$/.test(args[2]))
          return flagUnsupported(`${m[1]}() count "${args[2]}" is not a literal integer`);
        count = parseInt(args[2], 10);
      }
      if (count > 1) {
        if (!/\bRange(?:Sum|Avg|Min|Max)\s*\(\s*$/i.test(f.slice(0, idx))) {
          return flagUnsupported(`${m[1]}(expr, offset, ${count}) range form outside a RangeSum/Avg/Min/Max aggregation`);
        }
        if (count > 24)
          return flagUnsupported(`${m[1]}() range count ${count} too large to expand to a Lag/Lead list`);
        const items = [];
        for (let i = 0; i < count; i++) {
          const off = offset + i;
          items.push(off === 0 ? inner : `__SIGMA_${effFn}__(${inner}, ${off})`);
        }
        repl = items.join(", ");
      } else {
        repl = offset === 0 ? inner : `__SIGMA_${effFn}__(${inner}, ${offset})`;
      }
      setKind(effFn === "LAG" ? "lag" : "lead");
      note(`Qlik ${m[1]}() reads a neighbouring chart row \u2014 Sigma ${effFn === "LAG" ? "Lag" : "Lead"} follows the grouped element's sort order; sort it to match the Qlik chart.`);
      if (ctx)
        ctx.verify = true;
    } else if (fn === "previous") {
      const inner = args[0] || "";
      if (!inner)
        return flagUnsupported("Previous() missing expression argument");
      repl = `__SIGMA_LAG__(${inner}, 1)`;
      setKind("lag");
      if (ctx)
        ctx.verify = true;
      warnings?.push(`"${name}": Previous() is a Qlik LOAD-ORDER (script) function \u2014 translated to Lag(expr, 1), which follows the grouped element's SORT order. Sort the element to reproduce load order, and verify.`);
    } else {
      if (args.length > 2 && args[2]) {
        return flagUnsupported(`Peek() with a table argument reads another table's load buffer (script-time semantics, not chart semantics)`);
      }
      const fieldRaw = (args[0] || "").trim().replace(/^['"\[]/, "").replace(/['"\]]$/, "");
      if (!fieldRaw)
        return flagUnsupported("Peek() missing field argument");
      let row = -1;
      if (args.length > 1 && args[1]) {
        if (!/^-?\d+$/.test(args[1]))
          return flagUnsupported(`Peek() row argument "${args[1]}" is not a literal integer`);
        row = parseInt(args[1], 10);
      }
      if (row >= 0) {
        return flagUnsupported(`Peek('${fieldRaw}', ${row}) addresses an ABSOLUTE load-order row index (script-time semantics, not chart semantics)`);
      }
      repl = `__SIGMA_LAG__([${fieldRaw}], ${-row})`;
      setKind("lag");
      if (ctx)
        ctx.verify = true;
      warnings?.push(`"${name}": Peek() is a Qlik LOAD-ORDER (script) function \u2014 translated to Lag([${fieldRaw}], ${-row}), which follows the grouped element's SORT order. Sort the element to reproduce load order, and verify.`);
    }
    f = f.slice(0, idx) + repl + f.slice(close + 1);
  }
  return f.replace(/__SIGMA_(RANK|LAG|LEAD)__/g, (_s, w) => w === "RANK" ? "Rank" : w === "LAG" ? "Lag" : "Lead");
}
function lowerQlikFirstSortedValue(expr, name, tableElementMap, connectionId, warnings) {
  const m = expr.match(/^\s*FirstSortedValue\s*\(/i);
  if (!m)
    return null;
  const open = expr.indexOf("(", m.index);
  const close = matchClose(expr, open, "(", ")");
  if (close < 0)
    return null;
  const args = splitTopLevel(expr.slice(open + 1, close), ",").map((a) => a.trim());
  if (args.length < 2)
    return null;
  let valueArg = args[0];
  const distinct = /^distinct\s+/i.test(valueArg);
  if (distinct)
    valueArg = valueArg.replace(/^distinct\s+/i, "");
  const vm = valueArg.match(/^\[?([A-Za-z0-9_ .]+?)\]?$/);
  if (!vm)
    return null;
  const valueField = vm[1].trim();
  let weightArg = args[1];
  let dir = "ASC";
  if (/^-/.test(weightArg)) {
    dir = "DESC";
    weightArg = weightArg.slice(1).trim();
  }
  if (/[{}]/.test(weightArg))
    return null;
  let n = 1;
  if (args.length > 2 && args[2]) {
    if (!/^\d+$/.test(args[2]))
      return null;
    n = parseInt(args[2], 10);
  }
  let weightField = "", weightAggSql = "";
  const am = weightArg.match(/^([A-Za-z_]+)\s*\(\s*\[?([A-Za-z0-9_ .]+?)\]?\s*\)$/);
  if (am) {
    const aggSql = QLIK_AGG_TO_SQL[am[1].toUpperCase()];
    if (!aggSql)
      return null;
    weightField = am[2].trim();
    weightAggSql = aggSql;
  } else {
    const wm = weightArg.match(/^\[?([A-Za-z0-9_ .]+?)\]?$/);
    if (!wm)
      return null;
    weightField = wm[1].trim();
  }
  let owner = null;
  for (const info of Object.values(tableElementMap)) {
    const has = (nm) => Object.keys(info.colMap).some((k) => k.toUpperCase() === nm.toUpperCase());
    if (has(valueField) && has(weightField)) {
      owner = info;
      break;
    }
  }
  if (!owner)
    return null;
  const path = owner.element.source?.path || [];
  if (!path.length)
    return null;
  const fromSql = path.map((p) => `"${p}"`).join(".");
  const realName = (nm) => Object.keys(owner.colMap).find((k) => k.toUpperCase() === nm.toUpperCase()) || nm;
  const valCol = realName(valueField);
  const wCol = realName(weightField);
  const alias = "fsv_value";
  let statement;
  if (weightAggSql) {
    const aggExpr = weightAggSql.includes("(") ? `${weightAggSql} "${wCol}")` : `${weightAggSql}("${wCol}")`;
    statement = `SELECT "${valCol}" AS "${alias}" FROM ${fromSql} GROUP BY 1 QUALIFY ROW_NUMBER() OVER (ORDER BY ${aggExpr} ${dir}) = ${n}`;
  } else {
    statement = `SELECT ${distinct ? "DISTINCT " : ""}"${valCol}" AS "${alias}" FROM ${fromSql} QUALIFY ROW_NUMBER() OVER (ORDER BY "${wCol}" ${dir}) = ${n}`;
  }
  const colId = sigmaShortId();
  const display = sigmaDisplayName(alias);
  const element = {
    id: sigmaShortId(),
    kind: "table",
    name: `${name} (FirstSortedValue)`,
    source: { connectionId, kind: "sql", statement },
    columns: [{ id: colId, name: display, formula: `[Custom SQL/${alias}]` }],
    order: [colId]
  };
  warnings?.push(`\u2139 "${name}": FirstSortedValue() lowered to a SQL QUALIFY helper element (ROW_NUMBER ${dir} = ${n}). Tie caveat: Qlik returns NULL on a tie at position ${n}; the SQL picks one row \u2014 verify.`);
  return { element, metricFormula: `Min([${display}])` };
}
function fsvRankPattern(expr, warnings, name) {
  const base = {
    kind: "first-sorted-value",
    name,
    source: expr,
    requires: QLIK_GROUPED_REQUIRES + " Group by the value field's dimension; aggregate the result with Max() (or Min()) to surface the single picked value.",
    verify: true,
    note: "FirstSortedValue(value, weight[, n]) = the value at sorted-weight position n. Emitted as the Rank=n-filter pattern: rank the groups by the weight and keep rank = n. Tie caveat: Qlik returns NULL on a tie, this pattern picks one row \u2014 VERIFY against Qlik."
  };
  const m = expr.match(/^\s*FirstSortedValue\s*\(/i);
  if (!m)
    return { ...base, kind: "unsupported" };
  const open = expr.indexOf("(", m.index);
  const close = matchClose(expr, open, "(", ")");
  if (close < 0)
    return { ...base, kind: "unsupported" };
  const args = splitTopLevel(expr.slice(open + 1, close), ",").map((a) => a.trim());
  if (args.length < 2)
    return { ...base, kind: "unsupported" };
  const valueArg = args[0].replace(/^distinct\s+/i, "");
  let weightArg = args[1];
  let dir = "asc";
  if (/^-/.test(weightArg)) {
    dir = "desc";
    weightArg = weightArg.slice(1).trim();
  }
  let n = "1";
  if (args.length > 2 && /^\d+$/.test(args[2] || ""))
    n = args[2];
  const weightSigma = qlikExprToSigma(weightArg, warnings, `${name} (weight)`);
  if (!weightSigma || weightSigma.startsWith(QLIK_AGGR_SENTINEL) || weightSigma.startsWith(QLIK_FSV_SENTINEL)) {
    return { ...base, kind: "unsupported" };
  }
  const valueRef = /^\[.*\]$/.test(valueArg) ? valueArg : /^[A-Za-z_][A-Za-z0-9_]*$/.test(valueArg) ? `[${valueArg}]` : valueArg;
  return { ...base, formula: `If(Rank(${weightSigma}, "${dir}") = ${n}, ${valueRef}, Null)` };
}
function qlikExprToSigma(expr, warnings, name, ctx) {
  if (!expr?.trim())
    return null;
  let f = expr.trim();
  if (f.startsWith("="))
    f = f.slice(1).trim();
  f = f.replace(/\bDual\s*\(/gi, (_m, off) => "DUAL(");
  if (f.includes("DUAL(")) {
    let guard = 0;
    while (f.includes("DUAL(") && guard++ < 50) {
      const idx = f.indexOf("DUAL(");
      const open = f.indexOf("(", idx);
      const close = matchClose(f, open, "(", ")");
      if (close < 0)
        break;
      const args = splitTopLevel(f.slice(open + 1, close), ",");
      const textPart = (args[0] || "").trim();
      const numPart = (args[1] || "").trim();
      let chosen = numPart || textPart || "0";
      if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(chosen) && !/^(null|true|false)$/i.test(chosen))
        chosen = `[${chosen}]`;
      f = f.slice(0, idx) + chosen + f.slice(close + 1);
    }
  }
  const fsvM = f.match(/^FirstSortedValue\s*\(/i);
  if (fsvM && matchClose(f, f.indexOf("("), "(", ")") === f.length - 1) {
    return QLIK_FSV_SENTINEL + f;
  }
  if (/\bFirstSortedValue\s*\(/i.test(f)) {
    warnings?.push(`\u26A0 "${name}": FirstSortedValue() nested inside a larger expression \u2014 left untranslated (flagged in workbookPatterns).`);
    ctx?.patterns?.push({ kind: "unsupported", name, source: expr, note: "FirstSortedValue() nested inside a larger expression; only the standalone form is lowered (SQL QUALIFY helper element or the Rank=n-filter workbook pattern)." });
    return null;
  }
  if (/\{\s*[\$1<][^}]*\}/.test(f) || /\{\s*<[^}]*>\s*\}/.test(f)) {
    const translated = translateSetAnalysis(f, warnings, name);
    if (translated === null)
      return null;
    f = translated;
  }
  if (/\bAggr\s*\(/i.test(f)) {
    return QLIK_AGGR_SENTINEL + f;
  }
  if (/\bGet(?:Field)?(?:Selections?|CurrentSelections?|PossibleCount|SelectedCount|AlternativeCount|ExcludedCount)\s*\(/i.test(f)) {
    warnings?.push(`"${name}": uses a Qlik selection-state function \u2014 no Sigma equivalent.`);
    return null;
  }
  const ir = lowerInterRecordFns(f, warnings, name, expr, ctx);
  if (ir === null)
    return null;
  f = ir;
  f = lowerRangeFns(f, warnings, name);
  f = lowerClass(f, warnings, name);
  if (/\bRange(?:Count|Stdev|Mode|Skew|Kurtosis|Correl|Fractile)\s*\(/i.test(f)) {
    warnings?.push(`"${name}": uses a Qlik Range statistical function \u2014 no direct Sigma equivalent.`);
    return null;
  }
  f = f.replace(/\bOnly\s*\(\s*(\[[^\]]+\])\s*\)/gi, "$1");
  f = f.replace(/\bMinString\s*\(/gi, "Min(").replace(/\bMaxString\s*\(/gi, "Max(");
  f = f.replace(/\bFabs\s*\(/gi, "Abs(");
  f = f.replace(/\bFrac\s*\(\s*([^)]+)\)/gi, "$1 - Trunc($1)");
  f = f.replace(/\bSqrt\s*\(/gi, "Sqrt(");
  f = f.replace(/\bPow\s*\(\s*([^,]+),\s*([^)]+)\)/gi, "Power($1, $2)");
  f = f.replace(/\bLog10\s*\(/gi, "Log10(").replace(/\bLog\s*\(/gi, "Ln(");
  f = f.replace(/\bExp\s*\(/gi, "Exp(");
  f = f.replace(/\bCeil\s*\(/gi, "Ceiling(");
  f = f.replace(/\bFmod\s*\(\s*([^,]+),\s*([^)]+)\)/gi, "Mod($1, $2)");
  f = f.replace(/\bDiv\s*\(\s*([^,]+),\s*([^)]+)\)/gi, "Trunc($1 / $2)");
  f = f.replace(/\bSubStringCount\s*\(/gi, "RegexpCount(");
  f = f.replace(/\bIndex\s*\(\s*([^,]+),\s*([^,)]+)(?:,\s*([^)]+))?\)/gi, (_m, s, sub, occ) => occ ? `IndexOf(${s}, ${sub}, ${occ})` : `IndexOf(${s}, ${sub})`);
  f = f.replace(/\bLTrim\s*\(/gi, "Ltrim(").replace(/\bRTrim\s*\(/gi, "Rtrim(");
  f = f.replace(/\bRepeat\s*\(/gi, "Repeat(");
  f = f.replace(/\bConcat\s*\(/gi, "ListAgg(");
  f = f.replace(/\bNum\s*\(\s*([^,)]+)(,([^)]+))?\)/gi, (_m, val, hasComma, fmt) => {
    if (hasComma && warnings)
      warnings.push(`"${name}": Num() format argument "${(fmt || "").trim()}" stripped.`);
    return val.trim();
  });
  f = f.replace(/\bText\s*\(/gi, "ToString(").replace(/\bDate\$\s*\(/gi, "ToString(");
  f = f.replace(/\bIsNum\s*\(/gi, "IsNumber(");
  f = f.replace(/\bIsText\s*\(\s*([^)]+)\)/gi, "!IsNumber($1)");
  f = f.replace(/\bNull\s*\(\s*\)/gi, "null");
  f = f.replace(/\bWeekDay\s*\(/gi, "Weekday(");
  f = f.replace(/\bYearToDate\s*\(\s*([^)]+)\)/gi, (_m, field) => {
    warnings?.push(`"${name}": YearToDate() approximated as Year(${field.trim()}) = Year(Today())`);
    return `Year(${field}) = Year(Today())`;
  });
  f = f.replace(/'([^']*)'/g, '"$1"');
  return f.trim();
}
export {
  QLIK_AGGR_SENTINEL,
  QLIK_FSV_SENTINEL,
  QLIK_GROUPED_REQUIRES,
  convertQlikToSigma,
  convertQvdsToSigma,
  parseQvdHeader
};
