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
function sigmaInodeId(identifier) {
  return `inode-${sigmaShortId(22)}/${identifier.toUpperCase()}`;
}
function sigmaDisplayName(s) {
  const normalized = (s || "").replace(/([a-z])([A-Z])/g, "$1_$2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2").replace(/([A-Za-z])([0-9])/g, "$1_$2").replace(/([0-9])([A-Za-z])/g, "$1_$2");
  const words = normalized.toLowerCase().split(/[_\s]+/).filter(Boolean);
  return words.map((w, i) => i === 0 || !SIGMA_LOWERCASE_WORDS.has(w) ? w.charAt(0).toUpperCase() + w.slice(1) : w).join(" ");
}
function sigmaColFormula(tableName, identifier) {
  return `[${tableName}/${sigmaDisplayName(identifier)}]`;
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

// ../../../Users/tjwells/sigma-data-model-mcp/build/quicksight.js
function rewriteSqlRefs(formula, colMap) {
  const byDisplay = /* @__PURE__ */ new Map();
  for (const e of colMap.values())
    byDisplay.set(e.display.toLowerCase(), e);
  return formula.replace(/\[([^\]\/]+)\]/g, (match, refName) => {
    const hit = byDisplay.get(String(refName).trim().toLowerCase());
    if (hit && hit.sql)
      return `[Custom SQL/${hit.raw}]`;
    return match;
  });
}
function convertQuickSightToSigma(files, options = {}) {
  resetIds();
  const { connectionId = "<CONNECTION_ID>", database = "", schema = "" } = options;
  const dbOverride = database.trim().toUpperCase();
  const schemaOverride = schema.trim().toUpperCase();
  const analyses = [];
  const datasets = [];
  const warnings = [];
  const security = [];
  for (const file of files) {
    let parsed;
    try {
      parsed = JSON.parse(file.content);
    } catch (e) {
      warnings.push(`${file.name}: JSON parse error \u2014 ${e.message}`);
      continue;
    }
    const classified = classifyQuickSightJson(parsed);
    if (classified.kind === "analysis") {
      analyses.push(classified.value);
    } else if (classified.kind === "dataset") {
      datasets.push(classified.value);
    } else {
      warnings.push(`${file.name}: unrecognized QuickSight JSON shape \u2014 skipped (no AnalysisDefinition or DataSet found)`);
    }
  }
  if (analyses.length === 0 && datasets.length === 0) {
    return {
      model: emptyModel("QuickSight Model"),
      warnings: warnings.length ? warnings : ["No QuickSight analysis or dataset JSON found in the provided files"],
      stats: {}
    };
  }
  const datasetRegistry = /* @__PURE__ */ new Map();
  const elements = [];
  const winCtx = {
    helpers: /* @__PURE__ */ new Map(),
    usedAliases: /* @__PURE__ */ new Set(),
    extraElements: [],
    connectionId
  };
  for (const ds of datasets) {
    const entry = buildElementsForDataset(ds, { connectionId, dbOverride, schemaOverride, winCtx }, warnings, security);
    elements.push(...entry.elements);
    if (ds.Arn)
      datasetRegistry.set(ds.Arn, entry);
    if (ds.DataSetId)
      datasetRegistry.set(ds.DataSetId, entry);
    if (ds.Name)
      datasetRegistry.set(ds.Name, entry);
  }
  const derivedViewBySrcId = /* @__PURE__ */ new Map();
  const sourceEls = elements.filter((e) => e.source?.kind === "warehouse-table" && (e.relationships?.length ?? 0) > 0);
  for (const srcEl of sourceEls) {
    const view = buildDerivedView(srcEl, elements);
    if (view) {
      elements.push(view);
      derivedViewBySrcId.set(srcEl.id, view);
    }
  }
  const controls = [];
  let totalCalcFields = 0;
  let totalParams = 0;
  for (const analysis of analyses) {
    const def = analysis.Definition || {};
    const visualDimsByDataset = collectVisualGroupingDims(def);
    const identifierMap = /* @__PURE__ */ new Map();
    for (const decl of def.DataSetIdentifierDeclarations || []) {
      const ident = decl.Identifier;
      const arn = decl.DataSetArn;
      let entry;
      if (arn && datasetRegistry.has(arn))
        entry = datasetRegistry.get(arn);
      else if (ident && datasetRegistry.has(ident))
        entry = datasetRegistry.get(ident);
      if (!entry) {
        entry = synthesizeStubDataset(ident || arn || "Unknown", { connectionId, dbOverride, schemaOverride }, warnings);
        elements.push(...entry.elements);
        warnings.push(`\u2139 Analysis references dataset "${ident}" (ARN ${arn || "?"}) \u2014 no DescribeDataSet JSON supplied; emitted a Custom-SQL stub element so calc fields have a home. Re-run with the dataset JSON to resolve warehouse columns.`);
      }
      if (ident)
        identifierMap.set(ident, entry);
    }
    for (const cf of def.CalculatedFields || []) {
      totalCalcFields++;
      const entry = cf.DataSetIdentifier ? identifierMap.get(cf.DataSetIdentifier) : void 0;
      if (!entry) {
        warnings.push(`\u26A0 Analysis calc field "${cf.Name}": DataSetIdentifier "${cf.DataSetIdentifier}" not in DataSetIdentifierDeclarations \u2014 skipped`);
        continue;
      }
      const grain = cf.DataSetIdentifier && visualDimsByDataset.get(cf.DataSetIdentifier) || [];
      addAnalysisCalcCol(entry, cf.Name, cf.Expression, derivedViewBySrcId, elements, winCtx, grain, warnings);
    }
    for (const decl of def.ParameterDeclarations || []) {
      const ctl = parameterDeclarationToControl(decl, warnings);
      if (ctl) {
        controls.push(ctl);
        totalParams++;
      }
    }
    const filterCount = (def.FilterGroups || []).length;
    if (filterCount > 0) {
      warnings.push(`\u2139 ${filterCount} analysis-level FilterGroup(s) skipped \u2014 these are visual page filters in QuickSight. Re-create as workbook filters/page controls in Sigma.`);
    }
  }
  for (const helper of winCtx.helpers.values())
    finalizeQSWindowHelper(helper);
  if (winCtx.extraElements.length) {
    elements.push(...winCtx.extraElements);
  }
  dedupeElementNames(elements);
  for (const el of elements) {
    if (el.metrics?.length === 0)
      delete el.metrics;
    if (el.relationships?.length === 0)
      delete el.relationships;
  }
  const page = {
    id: sigmaShortId(),
    name: "Page 1",
    elements
  };
  if (controls.length)
    page.controls = controls;
  const modelName = analyses.length === 1 ? sigmaDisplayName(String(analyses[0].Name || analyses[0].AnalysisId || "QuickSight Analysis")) : datasets.length === 1 ? sigmaDisplayName(String(datasets[0].Name || datasets[0].DataSetId || "QuickSight DataSet")) : "QuickSight Model";
  return {
    model: { name: modelName, schemaVersion: 1, pages: [page] },
    warnings,
    ...security.length ? { security } : {},
    stats: {
      analyses: analyses.length,
      datasets: datasets.length,
      elements: elements.length,
      columns: elements.reduce((s, e) => s + (e.columns?.length ?? 0), 0),
      relationships: elements.reduce((s, e) => s + (e.relationships?.length ?? 0), 0),
      controls: controls.length,
      calcFields: totalCalcFields,
      params: totalParams
    }
  };
}
function classifyQuickSightJson(obj) {
  if (!obj || typeof obj !== "object")
    return { kind: "unknown" };
  if (obj.Definition?.DataSetIdentifierDeclarations) {
    return { kind: "analysis", value: obj };
  }
  if (obj.AnalysisDefinition?.Definition?.DataSetIdentifierDeclarations) {
    return { kind: "analysis", value: { ...obj, Definition: obj.AnalysisDefinition.Definition, Name: obj.AnalysisDefinition.Name } };
  }
  if (obj.Analysis?.Definition?.DataSetIdentifierDeclarations) {
    return { kind: "analysis", value: { ...obj.Analysis } };
  }
  if (obj.DataSet?.PhysicalTableMap) {
    return { kind: "dataset", value: obj.DataSet };
  }
  if (obj.PhysicalTableMap) {
    return { kind: "dataset", value: obj };
  }
  if (obj.QuickSightDataSet?.PhysicalTableMap) {
    return { kind: "dataset", value: obj.QuickSightDataSet };
  }
  return { kind: "unknown" };
}
function buildElementsForDataset(ds, ctx, warnings, security = []) {
  const elementsByLogical = /* @__PURE__ */ new Map();
  const logicalToPhysical = /* @__PURE__ */ new Map();
  const physicalToLogical = /* @__PURE__ */ new Map();
  const colMaps = /* @__PURE__ */ new Map();
  const phys = ds.PhysicalTableMap || {};
  const logical = ds.LogicalTableMap || {};
  const dsName = ds.Name || ds.DataSetId || "QuickSight DataSet";
  for (const [logicalId, lt] of Object.entries(logical)) {
    if (lt.Source?.PhysicalTableId) {
      const physId = lt.Source.PhysicalTableId;
      const phyTable = phys[physId];
      if (!phyTable) {
        warnings.push(`\u26A0 Dataset "${dsName}": logical table "${lt.Alias || logicalId}" references missing PhysicalTableId "${physId}" \u2014 skipped`);
        continue;
      }
      const { element, colMap } = buildElementFromPhysicalTable(phyTable, lt.Alias || logicalId, ctx, warnings);
      elementsByLogical.set(logicalId, element);
      logicalToPhysical.set(logicalId, physId);
      physicalToLogical.set(physId, logicalId);
      colMaps.set(logicalId, colMap);
      applyTransformsToElement(element, lt.DataTransforms || [], colMap, dsName, lt.Alias || logicalId, warnings, ctx.winCtx);
    }
  }
  if (elementsByLogical.size === 0) {
    for (const [physId, phyTable] of Object.entries(phys)) {
      const alias = inferPhysicalAlias(phyTable, physId);
      const { element, colMap } = buildElementFromPhysicalTable(phyTable, alias, ctx, warnings);
      elementsByLogical.set(physId, element);
      logicalToPhysical.set(physId, physId);
      physicalToLogical.set(physId, physId);
      colMaps.set(physId, colMap);
    }
  }
  const resolveOperand = (operandId, seen = /* @__PURE__ */ new Set()) => {
    if (elementsByLogical.has(operandId))
      return operandId;
    if (seen.has(operandId))
      return operandId;
    seen.add(operandId);
    const inner = logical[operandId]?.Source?.JoinInstruction;
    if (inner)
      return resolveOperand(inner.LeftOperand, seen);
    return operandId;
  };
  for (const [logicalId, lt] of Object.entries(logical)) {
    const join = lt.Source?.JoinInstruction;
    if (!join)
      continue;
    const leftOperandId = resolveOperand(join.LeftOperand);
    const rightOperandId = resolveOperand(join.RightOperand);
    const leftEl = elementsByLogical.get(leftOperandId);
    const rightEl = elementsByLogical.get(rightOperandId);
    if (!leftEl || !rightEl) {
      warnings.push(`\u26A0 Dataset "${dsName}": join "${lt.Alias || logicalId}" left/right operand not resolvable \u2014 relationship skipped`);
      continue;
    }
    const leftColMap = colMaps.get(leftOperandId);
    const rightColMap = colMaps.get(rightOperandId);
    const parsed = parseJoinOnClause(join.OnClause || "", join.LeftOperand, join.RightOperand);
    let leftColId;
    let rightColId;
    if (parsed && leftColMap && rightColMap) {
      leftColId = leftColMap.get(parsed.leftCol.toLowerCase())?.id;
      rightColId = rightColMap.get(parsed.rightCol.toLowerCase())?.id;
    }
    const rightPath = rightEl.source?.path || [];
    const rightAlias = (rightPath[rightPath.length - 1] || logical[rightOperandId]?.Alias || rightOperandId).toString().toUpperCase().replace(/\s+/g, "_");
    const rel = {
      id: sigmaShortId(),
      targetElementId: rightEl.id,
      name: rightAlias,
      relationshipType: join.Type === "INNER" ? "N:1" : join.Type === "RIGHT" ? "1:N" : "N:1"
    };
    if (leftColId && rightColId) {
      rel.keys = [{ sourceColumnId: leftColId, targetColumnId: rightColId }];
    } else {
      warnings.push(`\u2139 Dataset "${dsName}": join "${lt.Alias || logicalId}" OnClause "${join.OnClause}" \u2014 could not resolve FK/PK column IDs; relationship added without keys`);
    }
    (leftEl.relationships ??= []).push(rel);
    applyTransformsToElement(leftEl, lt.DataTransforms || [], leftColMap || /* @__PURE__ */ new Map(), dsName, lt.Alias || logicalId, warnings, ctx.winCtx);
  }
  const allEls = Array.from(elementsByLogical.values());
  const primary = allEls.length === 1 ? allEls[0] : allEls.slice().sort((a, b) => (b.relationships?.length ?? 0) - (a.relationships?.length ?? 0))[0];
  let primaryColMap;
  for (const [lid, el] of elementsByLogical.entries()) {
    if (el === primary) {
      primaryColMap = colMaps.get(lid);
      break;
    }
  }
  applyDatasetSecurity(ds, primary, primaryColMap, dsName, warnings, security);
  return {
    elements: allEls,
    byLogicalId: elementsByLogical,
    logicalToPhysical,
    primary,
    primaryColMap
  };
}
function applyDatasetSecurity(ds, primary, colMap, dsName, warnings, security) {
  if (!primary)
    return;
  const el = primary;
  for (const tr of ds.RowLevelPermissionTagConfiguration?.TagRules || []) {
    const ce = colMap?.get((tr.ColumnName || "").toLowerCase());
    if (!ce) {
      warnings.push(`\u26A0 Dataset "${dsName}": tag-RLS rule on column "${tr.ColumnName}" \u2014 column not found on the primary element; re-apply manually (CurrentUserAttributeText("${tr.TagKey}") = [${tr.ColumnName}]).`);
      continue;
    }
    let formula = `CurrentUserAttributeText("${tr.TagKey}") = [${ce.display}]`;
    if (tr.MatchAllValue)
      formula = `(${formula}) or (CurrentUserAttributeText("${tr.TagKey}") = "${tr.MatchAllValue}")`;
    security.push(makeRlsSecurity({ source: `QuickSight tag-based RLS (dataset "${dsName}")`, element: el, name: `RLS: ${ce.display}`, formula }));
    warnings.push(`\u{1F510} Dataset "${dsName}": tag-based RLS on [${ce.display}] \u2192 row-level security DETECTED (reported in result.security, not injected) via user attribute "${tr.TagKey}". The migration skill assigns the attribute per user (embed/JWT) and applies the RLS calc + filter.`);
  }
  const rlsDs = ds.RowLevelPermissionDataSet;
  if (rlsDs && (rlsDs.Arn || rlsDs.PermissionPolicy)) {
    warnings.push(`\u26A0 Dataset "${dsName}": a QuickSight RLS rule dataset is applied (${rlsDs.PermissionPolicy || "GRANT_ACCESS"}), but its user/group\u2192value grant rows live in a separate dataset not in this export. Re-create as a Sigma user attribute + a boolean RLS column (CurrentUserAttributeText("<col>") = [<col>]) + element filter on each permission column.${/DENY/i.test(rlsDs.PermissionPolicy || "") ? ' NOTE: DENY_ACCESS \u2014 invert to filter mode "exclude".' : ""}`);
  }
  for (const rule of ds.ColumnLevelPermissionRules || []) {
    const ids = (rule.ColumnNames || []).map((n) => colMap?.get(n.toLowerCase())?.id).filter(Boolean);
    if (!ids.length)
      continue;
    security.push(makeClsSecurity({ source: `QuickSight column-level security (dataset "${dsName}")`, element: el, columnIds: ids, columnNames: rule.ColumnNames, note: "QuickSight names principals who CANNOT view; Sigma CLS is an allowlist (no-one-can-view, or re-scope to a team/attribute for who SHOULD see it). The skill applies it \u2014 not injected." }));
    warnings.push(`\u{1F510} Dataset "${dsName}": column-level security on [${(rule.ColumnNames || []).join(", ")}] \u2192 CLS DETECTED (reported in result.security, not injected).`);
  }
}
function inferPhysicalAlias(phy, physId) {
  if (phy.RelationalTable?.Name)
    return phy.RelationalTable.Name;
  if (phy.CustomSql?.Name)
    return phy.CustomSql.Name;
  if (phy.S3Source?.UploadSettings)
    return physId;
  return physId;
}
function buildElementFromPhysicalTable(phy, alias, ctx, warnings) {
  const colMap = /* @__PURE__ */ new Map();
  if (phy.RelationalTable) {
    const rt = phy.RelationalTable;
    const tableName = (rt.Name || alias).toString();
    let path = [];
    if (rt.Catalog)
      path.push(rt.Catalog.toUpperCase());
    if (rt.Schema)
      path.push(rt.Schema.toUpperCase());
    path.push(tableName.toUpperCase());
    if (path.length === 1) {
      const t = path[0];
      if (ctx.dbOverride && ctx.schemaOverride)
        path = [ctx.dbOverride, ctx.schemaOverride, t];
      else if (ctx.schemaOverride)
        path = [ctx.schemaOverride, t];
      else if (ctx.dbOverride)
        path = [ctx.dbOverride, t];
    } else if (path.length === 2 && ctx.dbOverride) {
      path = [ctx.dbOverride, path[0], path[1]];
    }
    const tablePathTail = path[path.length - 1];
    const element = {
      id: sigmaShortId(),
      kind: "table",
      name: stripParens(sigmaDisplayName(tableName)),
      source: { connectionId: ctx.connectionId, kind: "warehouse-table", path },
      columns: [],
      metrics: [],
      order: []
    };
    for (const ic of rt.InputColumns || []) {
      const id = sigmaInodeId(ic.Name.toUpperCase());
      const display = sigmaDisplayName(ic.Name);
      colMap.set(ic.Name.toLowerCase(), { id, display, raw: ic.Name, sql: false });
      element.columns.push({ id, formula: sigmaColFormula(tablePathTail, ic.Name) });
      element.order.push(id);
    }
    return { element, colMap };
  }
  if (phy.CustomSql) {
    const cs = phy.CustomSql;
    const element = {
      id: sigmaShortId(),
      kind: "table",
      name: stripParens(sigmaDisplayName(cs.Name || alias)),
      source: { connectionId: ctx.connectionId, kind: "sql", statement: cs.SqlQuery || "" },
      columns: [],
      metrics: [],
      order: []
    };
    const cols = cs.Columns || [];
    if (cols.length === 0) {
      warnings.push(`\u26A0 CustomSql "${cs.Name}" has no Columns metadata \u2014 the SQL element will have no surfaced columns. Add them manually after save.`);
    }
    for (const ic of cols) {
      const id = sigmaInodeId(ic.Name.toUpperCase());
      const display = sigmaDisplayName(ic.Name);
      colMap.set(ic.Name.toLowerCase(), { id, display, raw: ic.Name, sql: true });
      element.columns.push({ id, name: display, formula: `[Custom SQL/${ic.Name}]` });
      element.order.push(id);
    }
    return { element, colMap };
  }
  if (phy.S3Source) {
    warnings.push(`\u2139 S3Source "${alias}" \u2014 Sigma has no direct S3 file connection; emitted as Custom SQL stub. Replace with an external table or warehouse-loaded equivalent.`);
    const element = {
      id: sigmaShortId(),
      kind: "table",
      name: stripParens(sigmaDisplayName(alias)),
      source: { connectionId: ctx.connectionId, kind: "sql", statement: `-- TODO: replace with warehouse SELECT for S3 source "${alias}"
SELECT 1 AS _placeholder` },
      columns: [],
      metrics: [],
      order: []
    };
    for (const ic of phy.S3Source.InputColumns || []) {
      const id = sigmaInodeId(ic.Name.toUpperCase());
      const display = sigmaDisplayName(ic.Name);
      colMap.set(ic.Name.toLowerCase(), { id, display, raw: ic.Name, sql: true });
      element.columns.push({ id, name: display, formula: `[Custom SQL/${ic.Name}]` });
      element.order.push(id);
    }
    return { element, colMap };
  }
  if (phy.SaaSTable) {
    warnings.push(`\u2139 SaaSTable "${alias}" \u2014 Sigma has no direct SaaS connector equivalent; emitted as Custom SQL stub.`);
    const sa = phy.SaaSTable;
    const element = {
      id: sigmaShortId(),
      kind: "table",
      name: stripParens(sigmaDisplayName(alias)),
      source: { connectionId: ctx.connectionId, kind: "sql", statement: `-- TODO: replace with warehouse SELECT for SaaS source "${alias}" (${(sa.TablePath || []).join(".")})
SELECT 1 AS _placeholder` },
      columns: [],
      metrics: [],
      order: []
    };
    for (const ic of sa.InputColumns || []) {
      const id = sigmaInodeId(ic.Name.toUpperCase());
      const display = sigmaDisplayName(ic.Name);
      colMap.set(ic.Name.toLowerCase(), { id, display, raw: ic.Name, sql: true });
      element.columns.push({ id, name: display, formula: `[Custom SQL/${ic.Name}]` });
      element.order.push(id);
    }
    return { element, colMap };
  }
  warnings.push(`\u26A0 Physical table "${alias}" has no recognized variant (RelationalTable/CustomSql/S3Source/SaaSTable) \u2014 emitted empty stub`);
  return {
    element: {
      id: sigmaShortId(),
      kind: "table",
      name: stripParens(sigmaDisplayName(alias)) || "Stub",
      source: { connectionId: ctx.connectionId, kind: "sql", statement: "-- empty placeholder" },
      columns: [],
      metrics: [],
      order: []
    },
    colMap
  };
}
function applyTransformsToElement(element, transforms, colMap, dsName, logicalAlias, warnings, winCtx) {
  for (const tx of transforms) {
    if (tx.CastColumnTypeOperation) {
      const op = tx.CastColumnTypeOperation;
      const existing = colMap.get(op.ColumnName.toLowerCase());
      if (!existing) {
        warnings.push(`\u26A0 ${dsName}/${logicalAlias}: Cast on missing column "${op.ColumnName}" \u2014 skipped`);
        continue;
      }
      const col = element.columns.find((c) => c.id === existing.id);
      if (!col)
        continue;
      const castFn = sigmaCastForType(op.NewColumnType);
      if (castFn)
        col.formula = `${castFn}(${col.formula})`;
    } else if (tx.CreateColumnsOperation) {
      const elemIsSql = element.source?.kind === "sql";
      for (const newCol of tx.CreateColumnsOperation.Columns || []) {
        const id = sigmaInodeId(newCol.ColumnName.toUpperCase());
        const display = stripParens(sigmaDisplayName(newCol.ColumnName));
        const win = winCtx ? quicksightParseWindow(newCol.Expression || "") : null;
        if (win && winCtx) {
          const ok = lowerQSWindowCalc(win, newCol.ColumnName, element, colMap, winCtx.helpers, winCtx.usedAliases, winCtx.extraElements, winCtx.connectionId, [], warnings);
          if (ok)
            continue;
        }
        const { formula, description } = quicksightFormulaToSigmaEx(newCol.Expression || "", warnings);
        const rewritten = elemIsSql ? rewriteSqlRefs(formula, colMap) : formula;
        const col = { id, formula: rewritten, name: display };
        if (description)
          col.description = description;
        colMap.set(newCol.ColumnName.toLowerCase(), { id, display, raw: newCol.ColumnName, sql: elemIsSql });
        element.columns.push(col);
        element.order.push(id);
      }
    } else if (tx.RenameColumnOperation) {
      const op = tx.RenameColumnOperation;
      const existing = colMap.get(op.ColumnName.toLowerCase());
      if (!existing)
        continue;
      const col = element.columns.find((c) => c.id === existing.id);
      if (!col)
        continue;
      const newDisplay = stripParens(sigmaDisplayName(op.NewColumnName));
      col.name = newDisplay;
      colMap.delete(op.ColumnName.toLowerCase());
      colMap.set(op.NewColumnName.toLowerCase(), { id: existing.id, display: newDisplay, raw: existing.raw, sql: existing.sql });
    } else if (tx.ProjectOperation) {
      const projected = tx.ProjectOperation.ProjectedColumns || [];
      const projectedIds = projected.map((name) => colMap.get(name.toLowerCase())?.id).filter((id) => !!id);
      if (projectedIds.length) {
        const projectedSet = new Set(projectedIds);
        const others = element.order.filter((id) => !projectedSet.has(id));
        element.order = [...projectedIds, ...others];
      }
    } else if (tx.FilterOperation) {
      const op = tx.FilterOperation;
      const elemIsSql = element.source?.kind === "sql";
      let translated = quicksightFormulaToSigma(op.ConditionExpression || "", warnings);
      if (elemIsSql)
        translated = rewriteSqlRefs(translated, colMap);
      const id = sigmaShortId();
      const name = stripParens(`Filter: ${(op.ConditionExpression || "").slice(0, 40)}`);
      element.columns.push({ id, formula: translated, name });
      element.order.push(id);
      warnings.push(`\u26A0 ${dsName}/${logicalAlias}: FilterOperation "${(op.ConditionExpression || "").slice(0, 60)}" \u2014 a true row-filter genuinely cannot move into a warehouse-table data-model element; it is emitted as an UNAPPLIED boolean calc column "${name}". Downstream counts/aggregates stay UNFILTERED. Apply this as a workbook filter on the boolean column, or push it into the SQL element's WHERE clause.`);
    } else if (tx.TagColumnOperation) {
      warnings.push(`\u2139 ${dsName}/${logicalAlias}: TagColumnOperation on "${tx.TagColumnOperation.ColumnName}" skipped (Sigma has no geo-role tagging)`);
    } else if (tx.UntagColumnOperation || tx.OverrideDatasetParameterOperation) {
    } else {
      const keys = Object.keys(tx);
      if (keys.length)
        warnings.push(`\u2139 ${dsName}/${logicalAlias}: unsupported transform "${keys[0]}" skipped`);
    }
  }
}
function sigmaCastForType(t) {
  switch (t.toUpperCase()) {
    case "STRING":
      return "Text";
    case "INTEGER":
      return "Int";
    case "DECIMAL":
      return "Number";
    case "DATETIME":
      return "Datetime";
    default:
      return null;
  }
}
function parseJoinOnClause(onClause, leftId, rightId) {
  const m = onClause.match(/\{([^}\[]+?)(?:\[([^\]]+)\])?\}\s*=\s*\{([^}\[]+?)(?:\[([^\]]+)\])?\}/);
  if (!m)
    return null;
  const [, c1, q1, c2, q2] = m;
  if (q1 && q2) {
    if (q1 === leftId)
      return { leftCol: c1.trim(), rightCol: c2.trim() };
    return { leftCol: c2.trim(), rightCol: c1.trim() };
  }
  if (q2 === rightId || q2 === leftId) {
    return q2 === rightId ? { leftCol: c1.trim(), rightCol: c2.trim() } : { leftCol: c2.trim(), rightCol: c1.trim() };
  }
  return { leftCol: c1.trim(), rightCol: c2.trim() };
}
function collectVisualGroupingDims(def) {
  const out = /* @__PURE__ */ new Map();
  const add = (col) => {
    if (!col || !col.DataSetIdentifier || !col.ColumnName)
      return;
    let s = out.get(col.DataSetIdentifier);
    if (!s) {
      s = /* @__PURE__ */ new Set();
      out.set(col.DataSetIdentifier, s);
    }
    s.add(col.ColumnName);
  };
  const DIM_KEYS = /* @__PURE__ */ new Set(["CategoricalDimensionField", "DateDimensionField", "NumericalDimensionField"]);
  const walk = (o) => {
    if (Array.isArray(o)) {
      for (const x of o)
        walk(x);
      return;
    }
    if (!o || typeof o !== "object")
      return;
    for (const [k, v] of Object.entries(o)) {
      if (DIM_KEYS.has(k) && v && typeof v === "object")
        add(v.Column);
      walk(v);
    }
  };
  walk(def?.Sheets || []);
  const result = /* @__PURE__ */ new Map();
  for (const [k, s] of out)
    result.set(k, Array.from(s));
  return result;
}
var QS_WINDOW_OP = {
  runningsum: "RUNNING_SUM",
  runningavg: "RUNNING_AVG",
  runningcount: "RUNNING_COUNT",
  runningmax: "RUNNING_MAX",
  runningmin: "RUNNING_MIN",
  percentoftotal: "PERCENT_OF_TOTAL",
  rank: "RANK",
  denserank: "DENSE_RANK",
  lag: "LAG",
  lead: "LEAD",
  firstvalue: "FIRST_VALUE",
  lastvalue: "LAST_VALUE",
  difference: "DIFFERENCE",
  percentdifference: "PERCENT_DIFFERENCE",
  // periodOverPeriod* are time-LAG variants — treat like difference/lag with offset -1
  periodoverperioddifference: "DIFFERENCE",
  periodoverperiodpercentdifference: "PERCENT_DIFFERENCE",
  periodoverperiodlastvalue: "LAG",
  windowsum: "WINDOW_SUM",
  windowavg: "WINDOW_AVG",
  windowcount: "WINDOW_COUNT",
  windowmax: "WINDOW_MAX",
  windowmin: "WINDOW_MIN",
  sumover: "OVER_SUM",
  avgover: "OVER_AVG",
  countover: "OVER_COUNT",
  distinctcountover: "OVER_DISTINCT_COUNT",
  maxover: "OVER_MAX",
  minover: "OVER_MIN",
  // statistical OVER windows
  stdevover: "OVER_STDDEV_SAMP",
  stdevpover: "OVER_STDDEV_POP",
  varover: "OVER_VAR_SAMP",
  varpover: "OVER_VAR_POP",
  // windowed percentiles. percentileOver == percentileContOver (continuous).
  percentileover: "OVER_PCT_CONT",
  percentilecontover: "OVER_PCT_CONT",
  percentilediscover: "OVER_PCT_DISC",
  // percentile rank (rank-shaped)
  percentilerank: "PERCENTILE_RANK",
  // periodToDate* — date-anchored running aggregates
  periodtodatesumovertime: "PTD_SUM",
  periodtodateavgovertime: "PTD_AVG",
  periodtodatemaxovertime: "PTD_MAX",
  periodtodateminovertime: "PTD_MIN",
  periodtodatecountovertime: "PTD_COUNT"
};
var QS_AGG_TO_SQL = {
  sum: "SUM",
  avg: "AVG",
  count: "COUNT",
  min: "MIN",
  max: "MAX",
  distinct_count: "COUNT_DISTINCT",
  distinctcount: "COUNT_DISTINCT"
};
function _qsStripBrace(tok) {
  const m = tok.trim().match(/^\{([^{}]+)\}$/);
  let inner = m ? m[1] : tok.trim();
  inner = inner.replace(/\[[^\]]+\]\s*$/, "").trim();
  return inner;
}
function _qsParseSortList(tok) {
  const inner = tok.trim().replace(/^\[/, "").replace(/\]$/, "");
  if (!inner.trim())
    return [];
  return splitTopLevel(inner, ",").map((part) => {
    const mm = part.trim().match(/^(.*?)(?:\s+(ASC|DESC))?$/i);
    const rawField = (mm ? mm[1] : part).trim();
    const dir = mm && mm[2] ? mm[2].toUpperCase() : "ASC";
    return { col: _qsStripBrace(rawField), dir };
  }).filter((f) => f.col);
}
function _qsParsePartitionList(tok) {
  const inner = tok.trim().replace(/^\[/, "").replace(/\]$/, "");
  if (!inner.trim())
    return [];
  return splitTopLevel(inner, ",").map(_qsStripBrace).filter(Boolean);
}
function _qsParseInnerAgg(tok) {
  const m = tok.trim().match(/^([A-Za-z_]+)\s*\(\s*\{([^{}]+)\}\s*\)$/);
  if (!m)
    return null;
  const func = QS_AGG_TO_SQL[m[1].toLowerCase()];
  if (!func)
    return null;
  return { func, col: m[2].replace(/\[[^\]]+\]\s*$/, "").trim() };
}
function _qsColToSql(raw) {
  return raw.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase();
}
function quicksightParseWindow(expr) {
  const s = (expr || "").trim();
  const m = s.match(/^([A-Za-z_]+)\s*\(([\s\S]*)\)\s*$/);
  if (!m)
    return null;
  const fn = m[1].toLowerCase();
  const op = QS_WINDOW_OP[fn];
  if (!op)
    return null;
  const args = splitTopLevel(m[2], ",");
  if (args.length === 0)
    return null;
  const base = (sortFields, partitionFields, inner, extra = {}) => ({
    _isWindow: true,
    op,
    innerAggFunc: inner?.func || "",
    innerColRaw: inner?.col || "",
    innerExprSql: inner ? _qsColToSql(inner.col) : "",
    sortFields,
    partitionFields,
    ...extra
  });
  switch (op) {
    // measure, [sort], [partition?]
    case "RUNNING_SUM":
    case "RUNNING_AVG":
    case "RUNNING_COUNT":
    case "RUNNING_MAX":
    case "RUNNING_MIN": {
      const inner = _qsParseInnerAgg(args[0]);
      if (!inner)
        return null;
      const sort = args[1] ? _qsParseSortList(args[1]) : [];
      const part = args[2] ? _qsParsePartitionList(args[2]) : [];
      if (sort.length === 0)
        return null;
      return base(sort, part, inner);
    }
    // measure, [partition]
    case "PERCENT_OF_TOTAL": {
      const inner = _qsParseInnerAgg(args[0]);
      if (!inner)
        return null;
      const part = args[1] ? _qsParsePartitionList(args[1]) : [];
      return base([], part, inner);
    }
    // sumOver(measure, [partition], calcLevel?) — partition list is the OVER scope
    case "OVER_SUM":
    case "OVER_AVG":
    case "OVER_COUNT":
    case "OVER_DISTINCT_COUNT":
    case "OVER_MAX":
    case "OVER_MIN":
    // statistical *Over share the same arg shape (measure, [partition], calcLevel?)
    case "OVER_STDDEV_SAMP":
    case "OVER_STDDEV_POP":
    case "OVER_VAR_SAMP":
    case "OVER_VAR_POP": {
      const inner = _qsParseInnerAgg(args[0]);
      if (!inner)
        return null;
      const part = args[1] ? _qsParsePartitionList(args[1]) : [];
      return base([], part, inner);
    }
    // percentileOver(measure, percentile, [partition], calcLevel?)
    //   percentile is a literal 0..1 (or 0..100 → normalized).
    case "OVER_PCT_CONT":
    case "OVER_PCT_DISC": {
      const inner = _qsParseInnerAgg(args[0]);
      if (!inner)
        return null;
      const pRaw = (args[1] || "").trim();
      const pNum = parseFloat(pRaw);
      if (!Number.isFinite(pNum))
        return null;
      const percentile = pNum > 1 ? pNum / 100 : pNum;
      if (percentile < 0 || percentile > 1)
        return null;
      const part = args[2] ? _qsParsePartitionList(args[2]) : [];
      return base([], part, inner, { percentile });
    }
    // percentileRank([sort], [partition]) — rank-shaped: order by a measure/dim, no inner agg
    case "PERCENTILE_RANK": {
      const sortTok = args[0] || "";
      const inner = sortTok.replace(/^\[/, "").replace(/\]$/, "").trim();
      const dm = inner.match(/^([\s\S]*?)\s+(ASC|DESC)\s*$/i);
      const exprPart = dm ? dm[1].trim() : inner;
      const dir = dm && dm[2] ? dm[2].toUpperCase() : "ASC";
      let rankSortExprSql = "";
      const innerAgg = _qsParseInnerAgg(exprPart);
      if (innerAgg) {
        rankSortExprSql = innerAgg.func === "COUNT_DISTINCT" ? `COUNT(DISTINCT ${_qsColToSql(innerAgg.col)})` : `${innerAgg.func}(${_qsColToSql(innerAgg.col)})`;
      } else {
        const fld = _qsStripBrace(exprPart);
        if (!fld)
          return null;
        rankSortExprSql = _qsColToSql(fld);
      }
      const part = args[1] ? _qsParsePartitionList(args[1]) : [];
      return base([], part, null, { rankSortExprSql, rankDir: dir });
    }
    // periodToDate*(measure, dateDim, period?) — date-anchored running aggregate
    case "PTD_SUM":
    case "PTD_AVG":
    case "PTD_MAX":
    case "PTD_MIN":
    case "PTD_COUNT": {
      const inner = _qsParseInnerAgg(args[0]);
      if (!inner)
        return null;
      const dateRaw = args[1] ? _qsStripBrace(args[1]) : "";
      if (!dateRaw)
        return null;
      const periodTok = (args[2] || "MONTH").trim().replace(/['"]/g, "").toUpperCase();
      const periodMap = {
        YEAR: "YEAR",
        QUARTER: "QUARTER",
        MONTH: "MONTH",
        WEEK: "WEEK",
        DAY: "DAY"
      };
      const period = periodMap[periodTok] || (["HOUR", "MINUTE", "SECONDS", "SECOND"].includes(periodTok) ? "DAY" : "MONTH");
      return base([{ col: dateRaw, dir: "ASC" }], [], inner, { ptdDateRaw: dateRaw, ptdPeriod: period });
    }
    // rank([sort], [partition]) — sort token may carry a measure expr with ASC/DESC
    case "RANK":
    case "DENSE_RANK": {
      const sortTok = args[0] || "";
      const inner = sortTok.replace(/^\[/, "").replace(/\]$/, "").trim();
      const dm = inner.match(/^([\s\S]*?)\s+(ASC|DESC)\s*$/i);
      const exprPart = dm ? dm[1].trim() : inner;
      const dir = dm && dm[2] ? dm[2].toUpperCase() : "DESC";
      let rankSortExprSql = "";
      const innerAgg = _qsParseInnerAgg(exprPart);
      if (innerAgg) {
        rankSortExprSql = innerAgg.func === "COUNT_DISTINCT" ? `COUNT(DISTINCT ${_qsColToSql(innerAgg.col)})` : `${innerAgg.func}(${_qsColToSql(innerAgg.col)})`;
      } else {
        const fld = _qsStripBrace(exprPart);
        if (!fld)
          return null;
        rankSortExprSql = _qsColToSql(fld);
      }
      const part = args[1] ? _qsParsePartitionList(args[1]) : [];
      return base([], part, null, { rankSortExprSql, rankDir: dir });
    }
    // lag/lead(measure, [sort], offset?, [partition?])
    case "LAG":
    case "LEAD": {
      const inner = _qsParseInnerAgg(args[0]);
      if (!inner)
        return null;
      const sort = args[1] ? _qsParseSortList(args[1]) : [];
      if (sort.length === 0)
        return null;
      let offset = 1;
      let partIdx = 2;
      if (args[2] && /^-?\d+$/.test(args[2].trim())) {
        offset = Math.abs(parseInt(args[2], 10)) || 1;
        partIdx = 3;
      }
      const part = args[partIdx] ? _qsParsePartitionList(args[partIdx]) : [];
      return base(sort, part, inner, { offset });
    }
    case "FIRST_VALUE":
    case "LAST_VALUE": {
      const inner = _qsParseInnerAgg(args[0]);
      if (!inner)
        return null;
      const sort = args[1] ? _qsParseSortList(args[1]) : [];
      if (sort.length === 0)
        return null;
      const part = args[2] ? _qsParsePartitionList(args[2]) : [];
      return base(sort, part, inner);
    }
    // difference(measure, [sort], offset, [partition]) — LAG-based delta
    case "DIFFERENCE":
    case "PERCENT_DIFFERENCE": {
      const inner = _qsParseInnerAgg(args[0]);
      if (!inner)
        return null;
      const sort = args[1] ? _qsParseSortList(args[1]) : [];
      if (sort.length === 0)
        return null;
      let offset = 1;
      let partIdx = 2;
      if (args[2] && /^-?\d+$/.test(args[2].trim())) {
        offset = Math.abs(parseInt(args[2], 10)) || 1;
        partIdx = 3;
      }
      const part = args[partIdx] ? _qsParsePartitionList(args[partIdx]) : [];
      return base(sort, part, inner, { offset });
    }
    // windowSum(measure, startIndex, endIndex, [partition]) — full-partition agg
    case "WINDOW_SUM":
    case "WINDOW_AVG":
    case "WINDOW_COUNT":
    case "WINDOW_MAX":
    case "WINDOW_MIN": {
      const inner = _qsParseInnerAgg(args[0]);
      if (!inner)
        return null;
      const last = args[args.length - 1];
      const part = last && /^\[/.test(last.trim()) ? _qsParsePartitionList(last) : [];
      return base([], part, inner);
    }
  }
  return null;
}
function _qsWindowAlias(name, used) {
  let b = (name || "WIN_VAL").toUpperCase().replace(/[^A-Z0-9_]+/g, "_").replace(/^_+|_+$/g, "").replace(/_+/g, "_");
  if (!b)
    b = "WIN_VAL";
  let a = b, n = 2;
  while (used.has(a))
    a = `${b}_${n++}`;
  used.add(a);
  return a;
}
function lowerQSWindowCalc(win, calcName, primary, primaryColMap, helpers, usedAliases, extraElements, connectionId, visualGrainDims, warnings) {
  const baseFromSql = qsResolveBaseFrom(primary);
  if (!baseFromSql) {
    warnings.push(`\u26A0 Window calc "${calcName}" (${win.op}) \u2014 could not resolve a warehouse FROM source for the primary element; degraded to Null.`);
    return false;
  }
  const knownRaw = qsKnownRawColumns(primary, primaryColMap);
  const resolveRaw = (name) => {
    const hit = knownRaw.find((r) => r.toLowerCase() === name.toLowerCase());
    return hit || (knownRaw.length === 0 ? name : null);
  };
  const partitionRaw = [];
  for (const p of win.partitionFields) {
    const r = resolveRaw(p);
    if (!r) {
      warnings.push(`\u26A0 Window calc "${calcName}" (${win.op}) \u2014 partition field "${p}" not found in source columns; degraded to Null.`);
      return false;
    }
    partitionRaw.push(r);
  }
  const orderSpec = [];
  for (const sf of win.sortFields) {
    const r = resolveRaw(sf.col);
    if (!r) {
      warnings.push(`\u26A0 Window calc "${calcName}" (${win.op}) \u2014 order field "${sf.col}" not found in source columns; degraded to Null.`);
      return false;
    }
    orderSpec.push({ col: r, dir: sf.dir });
  }
  let ptdDateResolved = null;
  if (win.op.startsWith("PTD_")) {
    ptdDateResolved = win.ptdDateRaw ? resolveRaw(win.ptdDateRaw) : null;
    if (!ptdDateResolved) {
      warnings.push(`\u26A0 Window calc "${calcName}" (${win.op}) \u2014 period-to-date date dimension "${win.ptdDateRaw}" not found in source columns; degraded to Null.`);
      return false;
    }
  }
  const needsOrder = [
    "RUNNING_SUM",
    "RUNNING_AVG",
    "RUNNING_COUNT",
    "RUNNING_MAX",
    "RUNNING_MIN",
    "LAG",
    "LEAD",
    "FIRST_VALUE",
    "LAST_VALUE",
    "DIFFERENCE",
    "PERCENT_DIFFERENCE",
    "PTD_SUM",
    "PTD_AVG",
    "PTD_MAX",
    "PTD_MIN",
    "PTD_COUNT"
  ].includes(win.op);
  if (needsOrder && orderSpec.length === 0) {
    warnings.push(`\u26A0 Window calc "${calcName}" (${win.op}) \u2014 no order field could be determined; degraded to Null.`);
    return false;
  }
  const grainRaw = [];
  const grainSeen = /* @__PURE__ */ new Set();
  const pushGrain = (raw) => {
    const a = _qsColToSql(raw);
    if (grainSeen.has(a))
      return;
    grainSeen.add(a);
    grainRaw.push(raw);
  };
  for (const g of visualGrainDims) {
    const r = resolveRaw(g);
    if (r)
      pushGrain(r);
  }
  for (const p of partitionRaw)
    pushGrain(p);
  for (const o of orderSpec)
    pushGrain(o.col);
  const grainKey = grainRaw.map(_qsColToSql).slice().sort().join(",");
  const partKey = partitionRaw.map(_qsColToSql).slice().sort().join(",");
  const orderKey = orderSpec.map((o) => `${_qsColToSql(o.col)} ${o.dir}`).join(",");
  const ptdKey = win.op.startsWith("PTD_") && ptdDateResolved ? `ptd:${win.ptdPeriod}:${_qsColToSql(ptdDateResolved)}` : "";
  const key = `${baseFromSql}||${grainKey}||${partKey}||${orderKey}||${ptdKey}`;
  let helper = helpers.get(key);
  if (!helper) {
    const cols = [];
    const order = [];
    for (const g of grainRaw) {
      const a = _qsColToSql(g);
      const id = sigmaShortId();
      cols.push({ id, name: sigmaDisplayName(g), formula: `[Custom SQL/${a}]` });
      order.push(id);
    }
    const el = {
      id: sigmaShortId(),
      kind: "table",
      // SQL elements normally omit element-level name (DM rule #3), but every
      // element needs a unique name for dedupeElementNames — give a descriptive
      // one (dedupe keeps it unique).
      name: `Window ${partitionRaw.join(", ") || "All"}${orderSpec.length ? " by " + orderSpec.map((o) => o.col).join(", ") : ""}`,
      source: { connectionId, kind: "sql", statement: "__QS_WINDOW_PLACEHOLDER__" },
      columns: cols,
      order
    };
    helper = {
      element: el,
      grainRaw,
      partitionRaw,
      orderSpec,
      innerAggs: {},
      windowAliases: /* @__PURE__ */ new Set(),
      overParts: [],
      baseFromSql,
      ...win.op.startsWith("PTD_") ? { ptdPeriod: win.ptdPeriod, ptdDateRaw: ptdDateResolved || void 0 } : {}
    };
    helpers.set(key, helper);
    extraElements.push(el);
  }
  let innerAlias = "";
  if (win.innerAggFunc && win.innerExprSql) {
    innerAlias = qsRegisterInnerAgg(helper, win.innerAggFunc, win.innerExprSql);
  }
  if ((win.op === "RANK" || win.op === "DENSE_RANK" || win.op === "PERCENTILE_RANK") && win.rankSortExprSql) {
    const am = win.rankSortExprSql.match(/^([A-Z_]+)\s*\(\s*(?:DISTINCT\s+)?([A-Z0-9_]+)\s*\)$/i);
    if (am) {
      const fn = /distinct/i.test(win.rankSortExprSql) ? "COUNT_DISTINCT" : am[1].toUpperCase();
      qsRegisterInnerAgg(helper, fn, am[2].toUpperCase());
    }
  }
  const winAlias = _qsWindowAlias(calcName, usedAliases);
  const overSql = qsBuildOverClause(win, helper, innerAlias);
  if (!overSql) {
    warnings.push(`\u26A0 Window calc "${calcName}" (${win.op}) \u2014 could not build an OVER clause; degraded to Null.`);
    return false;
  }
  helper.overParts.push(`${overSql} AS ${winAlias}`);
  helper.windowAliases.add(winAlias);
  const calcId = sigmaShortId();
  helper.element.columns.push({ id: calcId, name: stripParens(sigmaDisplayName(calcName)), formula: `[Custom SQL/${winAlias}]` });
  helper.element.order.push(calcId);
  warnings.push(`\u2705 Window "${calcName}" (${win.op}) \u2192 SQL helper "${helper.element.name}" alias ${winAlias}`);
  return true;
}
function qsResolveBaseFrom(primary) {
  const src = primary.source || {};
  if (src.kind === "warehouse-table" && Array.isArray(src.path) && src.path.length) {
    return src.path.join(".");
  }
  if (src.kind === "sql" && typeof src.statement === "string" && src.statement.trim() && !src.statement.includes("_placeholder") && !/^--/.test(src.statement.trim())) {
    return `(${src.statement.trim().replace(/;\s*$/, "")})`;
  }
  return null;
}
function qsKnownRawColumns(primary, colMap) {
  const out = [];
  if (colMap)
    for (const e of colMap.values())
      out.push(e.raw);
  return out;
}
function qsRegisterInnerAgg(helper, aggFunc, exprSql) {
  const key = `${aggFunc}::${exprSql}`;
  if (helper.innerAggs[key])
    return helper.innerAggs[key].alias;
  const idMatch = exprSql.match(/[A-Z][A-Z0-9_]*/);
  let alias = idMatch ? idMatch[0] : "VAL";
  let n = 2;
  while (helper.windowAliases.has(alias) || Object.values(helper.innerAggs).some((v) => v.alias === alias)) {
    alias = idMatch ? `${idMatch[0]}_${n++}` : `VAL_${n++}`;
  }
  helper.innerAggs[key] = { alias };
  return alias;
}
function qsBuildOverClause(win, helper, innerAlias) {
  const partBy = helper.partitionRaw.length ? `PARTITION BY ${helper.partitionRaw.map(_qsColToSql).join(", ")}` : "";
  const orderBy = helper.orderSpec.length ? `ORDER BY ${helper.orderSpec.map((o) => `${_qsColToSql(o.col)} ${o.dir}`).join(", ")}` : "";
  const spec = (parts) => parts.filter(Boolean).join(" ");
  switch (win.op) {
    case "RUNNING_SUM":
    case "RUNNING_AVG":
    case "RUNNING_COUNT":
    case "RUNNING_MAX":
    case "RUNNING_MIN": {
      if (!innerAlias || !orderBy)
        return null;
      const fn = win.op.replace("RUNNING_", "");
      return `${fn}(${innerAlias}) OVER (${spec([partBy, orderBy])} ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`;
    }
    case "PERCENT_OF_TOTAL": {
      if (!innerAlias)
        return null;
      return `(${innerAlias} / NULLIF(SUM(${innerAlias}) OVER (${partBy}), 0)) * 100`;
    }
    case "OVER_SUM":
    case "OVER_AVG":
    case "OVER_COUNT":
    case "OVER_DISTINCT_COUNT":
    case "OVER_MAX":
    case "OVER_MIN": {
      if (!innerAlias)
        return null;
      const fn = win.op === "OVER_DISTINCT_COUNT" ? "COUNT" : win.op.replace("OVER_", "");
      return `${fn}(${innerAlias}) OVER (${partBy})`;
    }
    // statistical OVER windows → STDDEV_SAMP / STDDEV_POP / VAR_SAMP / VAR_POP
    case "OVER_STDDEV_SAMP":
    case "OVER_STDDEV_POP":
    case "OVER_VAR_SAMP":
    case "OVER_VAR_POP": {
      if (!innerAlias)
        return null;
      const fn = win.op.replace("OVER_", "");
      return `${fn}(${innerAlias}) OVER (${partBy})`;
    }
    // windowed percentiles. Snowflake supports the OVER form, but the OVER clause
    // may carry ONLY a PARTITION BY (no ORDER BY / frame) — the order lives in the
    // mandatory WITHIN GROUP (ORDER BY ...).
    case "OVER_PCT_CONT":
    case "OVER_PCT_DISC": {
      if (!innerAlias)
        return null;
      if (win.percentile == null)
        return null;
      const fn = win.op === "OVER_PCT_DISC" ? "PERCENTILE_DISC" : "PERCENTILE_CONT";
      return `${fn}(${win.percentile}) WITHIN GROUP (ORDER BY ${innerAlias}) OVER (${partBy})`;
    }
    // percentileRank → PERCENT_RANK() OVER (... ORDER BY <measure>) × 100
    // QuickSight returns 0 (inclusive)..100 (exclusive); PERCENT_RANK gives
    // (rank-1)/(n-1) in [0,1] — lowest value → 0 — so ×100 matches QS semantics.
    case "PERCENTILE_RANK": {
      const sortExpr = win.rankSortExprSql;
      if (!sortExpr)
        return null;
      let orderExpr = sortExpr;
      for (const k of Object.keys(helper.innerAggs)) {
        const [fnK, exprK] = k.split("::");
        const reconstructed = fnK === "COUNT_DISTINCT" ? `COUNT(DISTINCT ${exprK})` : `${fnK}(${exprK})`;
        if (reconstructed === sortExpr) {
          orderExpr = helper.innerAggs[k].alias;
          break;
        }
      }
      return `PERCENT_RANK() OVER (${spec([partBy, `ORDER BY ${orderExpr} ${win.rankDir || "ASC"}`])}) * 100`;
    }
    // periodToDate* → date-anchored running aggregate. Partition by
    // DATE_TRUNC('<period>', date) so the running sum resets each period; order by
    // the date ASC with an UNBOUNDED PRECEDING → CURRENT ROW frame (to-date).
    case "PTD_SUM":
    case "PTD_AVG":
    case "PTD_MAX":
    case "PTD_MIN":
    case "PTD_COUNT": {
      if (!innerAlias)
        return null;
      if (!helper.ptdDateRaw || !helper.ptdPeriod)
        return null;
      const fnMap = {
        PTD_SUM: "SUM",
        PTD_AVG: "AVG",
        PTD_MAX: "MAX",
        PTD_MIN: "MIN",
        PTD_COUNT: "COUNT"
      };
      const fn = fnMap[win.op];
      const dateCol = _qsColToSql(helper.ptdDateRaw);
      const trunc = `DATE_TRUNC('${helper.ptdPeriod}', ${dateCol})`;
      const ptdPart = partBy ? `${partBy}, ${trunc}` : `PARTITION BY ${trunc}`;
      return `${fn}(${innerAlias}) OVER (${ptdPart} ORDER BY ${dateCol} ASC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`;
    }
    case "WINDOW_SUM":
    case "WINDOW_AVG":
    case "WINDOW_COUNT":
    case "WINDOW_MAX":
    case "WINDOW_MIN": {
      if (!innerAlias)
        return null;
      const fn = win.op.replace("WINDOW_", "");
      return `${fn}(${innerAlias}) OVER (${partBy})`;
    }
    case "RANK":
    case "DENSE_RANK": {
      const sortExpr = win.rankSortExprSql;
      if (!sortExpr)
        return null;
      let orderExpr = sortExpr;
      for (const k of Object.keys(helper.innerAggs)) {
        const [fnK, exprK] = k.split("::");
        const reconstructed = fnK === "COUNT_DISTINCT" ? `COUNT(DISTINCT ${exprK})` : `${fnK}(${exprK})`;
        if (reconstructed === sortExpr) {
          orderExpr = helper.innerAggs[k].alias;
          break;
        }
      }
      const fn = win.op === "DENSE_RANK" ? "DENSE_RANK" : "RANK";
      return `${fn}() OVER (${spec([partBy, `ORDER BY ${orderExpr} ${win.rankDir || "DESC"}`])})`;
    }
    case "LAG":
    case "LEAD": {
      if (!innerAlias || !orderBy)
        return null;
      const fn = win.op;
      return `${fn}(${innerAlias}, ${win.offset ?? 1}) OVER (${spec([partBy, orderBy])})`;
    }
    case "FIRST_VALUE":
    case "LAST_VALUE": {
      if (!innerAlias || !orderBy)
        return null;
      const frame = win.op === "LAST_VALUE" ? "ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING" : "";
      return `${win.op}(${innerAlias}) OVER (${spec([partBy, orderBy, frame])})`;
    }
    case "DIFFERENCE": {
      if (!innerAlias || !orderBy)
        return null;
      return `(${innerAlias} - LAG(${innerAlias}, ${win.offset ?? 1}) OVER (${spec([partBy, orderBy])}))`;
    }
    case "PERCENT_DIFFERENCE": {
      if (!innerAlias || !orderBy)
        return null;
      const prev = `LAG(${innerAlias}, ${win.offset ?? 1}) OVER (${spec([partBy, orderBy])})`;
      return `((${innerAlias} - ${prev}) / NULLIF(${prev}, 0)) * 100`;
    }
  }
  return null;
}
function finalizeQSWindowHelper(helper) {
  const selectParts = [];
  const groupCols = [];
  const seen = /* @__PURE__ */ new Set();
  for (const g of helper.grainRaw) {
    const a = _qsColToSql(g);
    if (seen.has(a))
      continue;
    seen.add(a);
    selectParts.push(a);
    groupCols.push(a);
  }
  for (const k of Object.keys(helper.innerAggs)) {
    const [aggFunc, exprSql] = k.split("::");
    const a = helper.innerAggs[k];
    const sqlFn = aggFunc === "COUNT_DISTINCT" ? `COUNT(DISTINCT ${exprSql})` : `${aggFunc}(${exprSql})`;
    selectParts.push(`${sqlFn} AS ${a.alias}`);
  }
  const groupByClause = groupCols.length ? ` GROUP BY ${groupCols.map((_, i) => i + 1).join(", ")}` : "";
  const baseSelect = `SELECT ${selectParts.join(", ")} FROM ${helper.baseFromSql}${groupByClause}`;
  const innerProjection = [
    ...groupCols,
    ...Object.values(helper.innerAggs).map((v) => v.alias)
  ];
  const outerProjection = innerProjection.concat(helper.overParts);
  helper.element.source.statement = `WITH base AS (${baseSelect}) SELECT ${outerProjection.join(", ")} FROM base`;
}
function synthesizeStubDataset(identifier, ctx, _warnings) {
  const element = {
    id: sigmaShortId(),
    kind: "table",
    name: stripParens(sigmaDisplayName(identifier)) || "Stub",
    source: { connectionId: ctx.connectionId, kind: "sql", statement: `-- TODO: replace with the warehouse SELECT for QuickSight dataset "${identifier}"
SELECT 1 AS _placeholder` },
    columns: [],
    metrics: [],
    order: []
  };
  const byLogicalId = /* @__PURE__ */ new Map([["__stub__", element]]);
  const logicalToPhysical = /* @__PURE__ */ new Map([["__stub__", "__stub__"]]);
  return { elements: [element], byLogicalId, logicalToPhysical, primary: element, primaryColMap: /* @__PURE__ */ new Map() };
}
var QS_AGG_FIELD_RE = /\b(sum|avg|min|max|count|distinct_count|median|percentile|percentileCont|percentileDisc|stdev|stdevp|var|varp)(If)?\s*\(/i;
function addAnalysisCalcCol(entry, name, expression, derivedViewBySrcId, allElements, winCtx, visualGrainDims, warnings) {
  const id = sigmaInodeId(name.toUpperCase());
  const display = stripParens(sigmaDisplayName(name));
  const win = quicksightParseWindow(expression || "");
  if (win) {
    const ok = lowerQSWindowCalc(win, name, entry.primary, entry.primaryColMap, winCtx.helpers, winCtx.usedAliases, winCtx.extraElements, winCtx.connectionId, visualGrainDims, warnings);
    if (ok)
      return;
  }
  const ex = quicksightFormulaToSigmaEx(expression || "", warnings);
  let formula = ex.formula;
  const description = ex.description;
  if (formula !== "Null" && QS_AGG_FIELD_RE.test(expression || "")) {
    const dv = derivedViewBySrcId.get(entry.primary.id);
    const target = dv || entry.primary;
    let mFormula = formula;
    if (dv) {
      const srcEl = entry.primary;
      const srcPath = srcEl.source.path || [];
      const srcBaseName = srcEl.name || srcPath[srcPath.length - 1] || "";
      const relatedNameMap = buildRelatedNameMap(srcEl, srcBaseName, allElements);
      mFormula = mFormula.replace(/\[([^\]\/]+)\]/g, (match, refName) => {
        const triple = relatedNameMap[refName];
        if (!triple)
          return match;
        const parts = triple.split("/");
        return parts.length === 3 ? `[${parts[2]} (${parts[1]})]` : match;
      });
    } else if (entry.primary.source?.kind === "sql" && entry.primaryColMap) {
      mFormula = rewriteSqlRefs(mFormula, entry.primaryColMap);
    }
    const metric = { id: sigmaShortId(), name: display, formula: mFormula };
    if (description)
      metric.description = description;
    (target.metrics ||= []).push(metric);
    warnings.push(`\u2139 "${name}": aggregate-level calculated field \u2192 Sigma metric on "${target.name || "primary element"}" (as a calc column the inner aggregate silently collapses to the row value).`);
    return;
  }
  const derivedView = derivedViewBySrcId.get(entry.primary.id);
  if (derivedView) {
    const srcEl = entry.primary;
    const srcPath = srcEl.source.path || [];
    const srcBaseName = srcEl.name || srcPath[srcPath.length - 1] || "";
    const relatedNameMap = buildRelatedNameMap(srcEl, srcBaseName, allElements);
    const localNamesOnView = /* @__PURE__ */ new Set();
    for (const c of derivedView.columns || []) {
      const m = c.formula?.match(/^\[([^\]\/]+)\/([^\]]+)\]$/);
      if (m)
        localNamesOnView.add(m[2].toLowerCase());
    }
    formula = formula.replace(/\[([^\]\/]+)\]/g, (match, refName) => {
      const lower = refName.toLowerCase();
      if (localNamesOnView.has(lower))
        return match;
      const triple = relatedNameMap[refName];
      if (triple)
        return `[${triple}]`;
      const srcCalc = (srcEl.columns || []).find((c) => c.name && c.name.toLowerCase() === lower);
      if (srcCalc) {
        const proxyId = sigmaShortId();
        derivedView.columns.push({ id: proxyId, formula: `[${srcBaseName}/${srcCalc.name}]` });
        derivedView.order.push(proxyId);
        localNamesOnView.add(lower);
        return match;
      }
      return match;
    });
    const dvCol = { id, formula, name: display };
    if (description)
      dvCol.description = description;
    derivedView.columns.push(dvCol);
    derivedView.order.push(id);
  } else {
    if (entry.primary.source?.kind === "sql" && entry.primaryColMap) {
      formula = rewriteSqlRefs(formula, entry.primaryColMap);
    }
    const pCol = { id, formula, name: display };
    if (description)
      pCol.description = description;
    entry.primary.columns.push(pCol);
    entry.primary.order.push(id);
  }
}
function buildRelatedNameMap(srcEl, srcBaseName, allElements) {
  const map = {};
  for (const rel of srcEl.relationships || []) {
    if (!rel.name)
      continue;
    const tgtEl = allElements.find((e) => e.id === rel.targetElementId);
    if (!tgtEl || tgtEl.source?.kind !== "warehouse-table")
      continue;
    for (const c of tgtEl.columns || []) {
      if (!c.formula || c.formula === "Null")
        continue;
      const fm = c.formula.match(/^\[([^\]]+)\]$/);
      if (!fm)
        continue;
      const inner = fm[1];
      const s = inner.lastIndexOf("/");
      const dispName = s >= 0 ? inner.slice(s + 1) : inner;
      if (c.name && !(c.name in map))
        map[c.name] = `${srcBaseName}/${rel.name}/${dispName}`;
      if (!(dispName in map))
        map[dispName] = `${srcBaseName}/${rel.name}/${dispName}`;
    }
  }
  return map;
}
function parameterDeclarationToControl(decl, warnings) {
  const inner = decl.StringParameterDeclaration || decl.IntegerParameterDeclaration || decl.DecimalParameterDeclaration || decl.DateTimeParameterDeclaration;
  if (!inner)
    return null;
  const kind = decl.StringParameterDeclaration ? "text" : decl.IntegerParameterDeclaration ? "number" : decl.DecimalParameterDeclaration ? "number" : "date";
  const id = sigmaShortId();
  const isMulti = inner.ParameterValueType === "MULTI_VALUED";
  const staticDefaults = inner.DefaultValues?.StaticValues || [];
  const control = {
    id,
    name: sigmaDisplayName(inner.Name || "Param"),
    kind,
    multiSelect: isMulti
  };
  if (staticDefaults.length)
    control.defaultValue = isMulti ? staticDefaults : staticDefaults[0];
  if (kind === "number" && isMulti) {
    warnings.push(`\u2139 Parameter "${inner.Name}" is multi-valued numeric \u2014 Sigma multi-numeric controls have known limitations; verify in UI (see beads-sigma-z3y).`);
  }
  return control;
}
function buildDerivedView(srcEl, allElements) {
  const srcPath = srcEl.source.path || [];
  const srcTableName = srcPath[srcPath.length - 1] || "";
  const baseName = srcEl.name || srcTableName;
  const viewCols = [];
  const viewOrder = [];
  for (const col of srcEl.columns || []) {
    if (!col.formula || col.formula === "Null")
      continue;
    if (col.name)
      continue;
    const m = col.formula.match(/^\[([^\/\]]+)\/([^\]]+)\]$/);
    if (!m)
      continue;
    const dispName = m[2];
    const cId = sigmaShortId();
    viewCols.push({ id: cId, formula: `[${baseName}/${dispName}]` });
    viewOrder.push(cId);
  }
  for (const rel of srcEl.relationships || []) {
    if (!rel.name)
      continue;
    const tgtEl = allElements.find((e) => e.id === rel.targetElementId);
    if (!tgtEl || tgtEl.source?.kind !== "warehouse-table")
      continue;
    for (const col of tgtEl.columns || []) {
      if (!col.formula || col.formula === "Null")
        continue;
      const fm = col.formula.match(/^\[([^\]]+)\]$/);
      if (!fm)
        continue;
      const inner = fm[1];
      const s = inner.lastIndexOf("/");
      const dispName = s >= 0 ? inner.slice(s + 1) : inner;
      const cId = sigmaShortId();
      viewCols.push({ id: cId, formula: `[${baseName}/${rel.name}/${dispName}]` });
      viewOrder.push(cId);
    }
  }
  if (viewCols.length === 0)
    return null;
  return {
    id: sigmaShortId(),
    kind: "table",
    name: `${sigmaDisplayName(srcTableName) || "Source"} View`,
    source: { kind: "table", elementId: srcEl.id },
    columns: viewCols,
    order: viewOrder
  };
}
function quicksightFormulaToSigmaEx(expr, warnings) {
  if (!expr || typeof expr !== "string")
    return { formula: "" };
  let s = expr.trim();
  const strings = [];
  s = s.replace(/'((?:[^'\\]|\\.)*)'/g, (_, body) => {
    const idx = strings.length;
    strings.push(`"${body.replace(/"/g, '\\"')}"`);
    return `__STR${idx}__`;
  });
  const windowFns = [
    "sumOver",
    "avgOver",
    "countOver",
    "distinctCountOver",
    "maxOver",
    "minOver",
    "stdevOver",
    "stdevpOver",
    "varOver",
    "varpOver",
    "percentileOver",
    "percentileContOver",
    "percentileDiscOver",
    "percentOfTotal",
    "runningSum",
    "runningAvg",
    "runningCount",
    "runningMax",
    "runningMin",
    "rank",
    "denseRank",
    "percentileRank",
    "lag",
    "lead",
    "firstValue",
    "lastValue",
    "difference",
    "percentDifference",
    "periodOverPeriodDifference",
    "periodOverPeriodLastValue",
    "periodOverPeriodPercentDifference",
    "periodToDateSumOverTime",
    "periodToDateAvgOverTime",
    "periodToDateMaxOverTime",
    "periodToDateMinOverTime",
    "periodToDateCountOverTime",
    "windowSum",
    "windowAvg",
    "windowMax",
    "windowMin",
    "windowCount"
  ];
  const windowRe = new RegExp(`\\b(${windowFns.join("|")})\\s*\\(`, "i");
  if (windowRe.test(s)) {
    warnings.push(`\u26A0 Formula uses a QuickSight table-calculation function (${s.match(windowRe)[1]}) \u2014 not auto-mapped to a native Sigma window function yet (converter follow-up). Degraded to a Null calc column with the original expression in its description; re-author with the native Sigma equivalent (CumulativeSum/MovingAvg/MovingSum/PercentOfTotal/Rank/Lag/Lead), which DOES resolve in DM-element and workbook calc columns (verified 2026-07-15) \u2014 only the *Over family errors.`);
    return { formula: "Null", description: `QuickSight table-calc \u2014 re-author with the native Sigma window fn (NOT the *Over family): ${expr}` };
  }
  const paramRe = /\$\{([^{}]+)\}/;
  if (paramRe.test(s)) {
    const pname = String(s.match(paramRe)[1]).replace(/\[[^\]]+\]\s*$/, "").trim();
    warnings.push(`\u26A0 Formula references QuickSight parameter \${${pname}} \u2014 Sigma controls are workbook-scoped and can't be referenced from a data-model calc column. Degraded to a Null calc column with the original expression in its description; the parameter is emitted as a Sigma control, so re-author this calculation at the workbook layer using the "${sigmaDisplayName(pname)}" control.`);
    return { formula: "Null", description: `QuickSight parameter-dependent calc (re-author at the Sigma workbook layer using the "${sigmaDisplayName(pname)}" control): ${expr}` };
  }
  const noEquivCondAggRe = /\b(medianIf|stdevIf|stdevpIf|varIf|varpIf)\s*\(/i;
  if (noEquivCondAggRe.test(s)) {
    const fn = s.match(noEquivCondAggRe)[1];
    warnings.push(`\u26A0 Formula uses QuickSight ${fn}() \u2014 Sigma has no ${fn}-style conditional aggregate (only SumIf/AvgIf/CountIf/MinIf/MaxIf/CountDistinctIf). Degraded to a Null calc column with the original expression in its description; re-author as a Custom SQL element or a workbook-layer calculation.`);
    return { formula: "Null", description: `QuickSight ${fn} (no Sigma equivalent \u2014 re-author in Sigma): ${expr}` };
  }
  const regexTokenRe = /\b(regexp?_?[A-Za-z_]*)\s*\(/i;
  const regexMapped = /^(regexp_extract|regexpextract|regex_extract|regexp_substr|regexp_replace|regexpreplace|regex_replace|regexp_like|regexp_matches|regexp_match|regexpmatch|rlike|regexp_count|regexpcount)$/i;
  const rm = s.match(regexTokenRe);
  if (rm && !regexMapped.test(rm[1])) {
    warnings.push(`\u26A0 Formula uses regex function ${rm[1]}() \u2014 no 1:1 Sigma equivalent (Sigma offers RegexpExtract/RegexpReplace/RegexpMatch/RegexpCount). Degraded to a Null calc column with the original expression in its description; re-author with a Sigma Regexp* function or a Custom SQL element.`);
    return { formula: "Null", description: `Regex function ${rm[1]} (no 1:1 Sigma equivalent \u2014 re-author in Sigma): ${expr}` };
  }
  s = s.replace(/\{([^{}]+)\}/g, (_, raw) => {
    const cleaned = String(raw).replace(/\[[^\]]+\]\s*$/, "").trim();
    return `[${sigmaDisplayName(cleaned)}]`;
  });
  s = transformIfElse(s);
  s = transformSwitch(s);
  s = qsDropFirstArg(s, "countIf", "CountIf");
  s = qsWrapParse(s, "parseInt");
  s = remapFunctions(s);
  s = s.replace(/<>/g, "!=");
  s = s.replace(/__STR(\d+)__/g, (_, i) => strings[Number(i)]);
  return { formula: s };
}
function quicksightFormulaToSigma(expr, warnings) {
  return quicksightFormulaToSigmaEx(expr, warnings).formula;
}
function transformBalanced(s, fnName, build) {
  let out = s;
  let safety = 0;
  const re = new RegExp(`\\b${fnName}\\s*\\(`, "i");
  while (safety++ < 50) {
    const m = out.match(re);
    if (!m || m.index === void 0)
      break;
    const start = m.index;
    let depth = 1;
    let j = start + m[0].length;
    for (; j < out.length && depth > 0; j++) {
      if (out[j] === "(")
        depth++;
      else if (out[j] === ")")
        depth--;
    }
    if (depth !== 0)
      break;
    const inner = transformBalanced(out.slice(start + m[0].length, j - 1), fnName, build);
    const parts = splitTopLevel(inner, ",");
    out = out.slice(0, start) + build(parts, inner) + out.slice(j);
  }
  return out;
}
function transformIfElse(s) {
  return transformBalanced(s, "ifelse", (parts, inner) => {
    if (parts.length < 3)
      return `If(${inner})`;
    const isOdd = parts.length % 2 === 1;
    let result = isOdd ? parts[parts.length - 1] : "null";
    const limit = isOdd ? parts.length - 1 : parts.length;
    for (let i = limit - 2; i >= 0; i -= 2) {
      result = `If(${parts[i]}, ${parts[i + 1]}, ${result})`;
    }
    return result;
  });
}
function transformSwitch(s) {
  return transformBalanced(s, "switch", (parts, inner) => {
    if (parts.length < 3)
      return `Switch(${inner})`;
    const subject = parts[0];
    const rest = parts.slice(1);
    const isOdd = rest.length % 2 === 1;
    let result = isOdd ? rest[rest.length - 1] : "null";
    const limit = isOdd ? rest.length - 1 : rest.length;
    for (let i = limit - 2; i >= 0; i -= 2) {
      result = `If(${subject} = ${rest[i]}, ${rest[i + 1]}, ${result})`;
    }
    return result;
  });
}
function splitTopLevel(s, sep) {
  const out = [];
  let depth = 0;
  let bracket = 0;
  let cur = "";
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "(")
      depth++;
    else if (ch === ")")
      depth--;
    else if (ch === "[")
      bracket++;
    else if (ch === "]")
      bracket--;
    if (ch === sep && depth === 0 && bracket === 0) {
      out.push(cur.trim());
      cur = "";
      continue;
    }
    cur += ch;
  }
  if (cur.trim())
    out.push(cur.trim());
  return out;
}
function qsDropFirstArg(s, qsFn, sigmaFn) {
  let out = "";
  let i = 0;
  const re = new RegExp(`\\b${qsFn}\\s*\\(`, "gi");
  let m;
  while ((m = re.exec(s)) !== null) {
    out += s.slice(i, m.index);
    let depth = 1, j = re.lastIndex, commaIdx = -1;
    while (j < s.length && depth > 0) {
      const ch = s[j];
      if (ch === "(")
        depth++;
      else if (ch === ")") {
        depth--;
        if (depth === 0)
          break;
      } else if (ch === "," && depth === 1 && commaIdx === -1)
        commaIdx = j;
      j++;
    }
    if (depth !== 0) {
      out += m[0];
      i = re.lastIndex;
      continue;
    }
    const body = commaIdx === -1 ? s.slice(re.lastIndex, j).trim() : s.slice(commaIdx + 1, j).trim();
    out += `${sigmaFn}(${body})`;
    i = j + 1;
    re.lastIndex = i;
  }
  out += s.slice(i);
  return out;
}
function qsWrapParse(s, qsFn) {
  let out = "";
  let i = 0;
  const re = new RegExp(`\\b${qsFn}\\s*\\(`, "gi");
  let m;
  while ((m = re.exec(s)) !== null) {
    out += s.slice(i, m.index);
    let depth = 1, j = re.lastIndex;
    while (j < s.length && depth > 0) {
      const ch = s[j];
      if (ch === "(")
        depth++;
      else if (ch === ")") {
        depth--;
        if (depth === 0)
          break;
      }
      j++;
    }
    if (depth !== 0) {
      out += m[0];
      i = re.lastIndex;
      continue;
    }
    out += `Int(Number(${s.slice(re.lastIndex, j).trim()}))`;
    i = j + 1;
    re.lastIndex = i;
  }
  out += s.slice(i);
  return out;
}
var QS_FUNC_MAP = {
  // aggregate
  sum: "Sum",
  avg: "Avg",
  min: "Min",
  max: "Max",
  count: "Count",
  distinct_count: "CountDistinct",
  distinctcount: "CountDistinct",
  median: "Median",
  percentile: "Percentile",
  percentilecont: "Percentile",
  percentiledisc: "Percentile",
  stdev: "Stdev",
  stdevp: "StdevP",
  var: "Var",
  varp: "VarP",
  // conditional aggregates — QS argument order is (measure, condition) and
  // Sigma's verified order is ALSO (field, condition 1, ...) (SumIf docs +
  // live-verified CountDistinctIf via the ThoughtSpot converter), so these
  // remap 1:1 with no arg swap. countIf is handled by qsDropFirstArg above;
  // the bare entry is a fallback for already-balanced single-condition forms.
  sumif: "SumIf",
  avgif: "AvgIf",
  minif: "MinIf",
  maxif: "MaxIf",
  countif: "CountIf",
  distinct_countif: "CountDistinctIf",
  distinctcountif: "CountDistinctIf",
  // regex — SQL-dialect tokens seen in QS estates → Sigma Regexp* (verified
  // names; same emissions as the Tableau converter). Sigma RegexpExtract /
  // RegexpReplace / RegexpMatch / RegexpCount are (text, pattern[, ...]) like
  // their Snowflake/Presto counterparts. Unmapped regex tokens are flagged
  // earlier in quicksightFormulaToSigmaEx.
  regexp_extract: "RegexpExtract",
  regexpextract: "RegexpExtract",
  regex_extract: "RegexpExtract",
  regexp_substr: "RegexpExtract",
  regexp_replace: "RegexpReplace",
  regexpreplace: "RegexpReplace",
  regex_replace: "RegexpReplace",
  regexp_like: "RegexpMatch",
  regexp_matches: "RegexpMatch",
  regexp_match: "RegexpMatch",
  regexpmatch: "RegexpMatch",
  rlike: "RegexpMatch",
  regexp_count: "RegexpCount",
  regexpcount: "RegexpCount",
  // conditional
  isnull: "IsNull",
  notnull: "IsNotNull",
  coalesce: "Coalesce",
  nullif: "Nullif",
  // string
  concat: "Concat",
  substring: "Mid",
  strlen: "Len",
  tolower: "Lower",
  toupper: "Upper",
  trim: "Trim",
  ltrim: "LTrim",
  rtrim: "RTrim",
  lpad: "LPad",
  rpad: "RPad",
  left: "Left",
  right: "Right",
  replace: "Replace",
  split: "Split",
  locate: "Find",
  contains: "Contains",
  // math
  abs: "Abs",
  ceil: "Ceiling",
  floor: "Floor",
  round: "Round",
  log: "Log",
  exp: "Exp",
  sqrt: "Sqrt",
  mod: "Mod",
  power: "Power",
  pow: "Power",
  sign: "Sign",
  pi: "Pi",
  // date
  now: "Now",
  today: "Today",
  truncdate: "DateTrunc",
  adddatetime: "DateAdd",
  datediff: "DateDiff",
  extract: "DatePart",
  epochdate: "EpochDate",
  formatdate: "Text",
  parsedate: "Date",
  // numeric parse/convert family (parseInt is rewritten to Int(Number(…)) above)
  parsedecimal: "Number",
  decimaltoint: "Int",
  inttodecimal: "Number",
  tostring: "Text",
  // boolean / set
  in: "In"
};
function remapFunctions(s) {
  return s.replace(/\b([A-Za-z_][A-Za-z0-9_]*)\s*(?=\()/g, (match, fn) => {
    const mapped = QS_FUNC_MAP[fn.toLowerCase()];
    return mapped ?? match;
  });
}
function emptyModel(name) {
  return { name, schemaVersion: 1, pages: [{ id: sigmaShortId(), name: "Page 1", elements: [] }] };
}
function stripParens(name) {
  return (name || "").replace(/\s*\([^)]*\)/g, "").replace(/[()]/g, "").replace(/\s+/g, " ").trim();
}
function dedupeElementNames(elements) {
  const seen = /* @__PURE__ */ new Set();
  for (const el of elements) {
    let base = stripParens(el.name || "") || "Element";
    let candidate = base;
    let n = 2;
    while (seen.has(candidate.toLowerCase())) {
      candidate = `${base} ${n++}`;
    }
    seen.add(candidate.toLowerCase());
    el.name = candidate;
  }
}
export {
  convertQuickSightToSigma,
  quicksightFormulaToSigma,
  quicksightFormulaToSigmaEx
};
