// ../wt-pbi-dax-fidelity/build/sigma-ids.js
var SIGMA_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
var _usedIds = /* @__PURE__ */ new Set();
var _idCounter = 0;
function encodeBase62(n, len) {
  let x = n, s = "";
  while (x > 0) {
    s = SIGMA_CHARS[x % 62] + s;
    x = Math.floor(x / 62);
  }
  return s.padStart(len, SIGMA_CHARS[0]);
}
function fnv1a32(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}
var NS_MODULUS = 62 ** 4;
var NS_BLOCK = 1e6;
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
function resetIds(seed) {
  _usedIds.clear();
  _idCounter = seed == null ? 0 : fnv1a32(seed) % NS_MODULUS * NS_BLOCK;
}
function clampId(id, max = 64) {
  if (id.length <= max)
    return id;
  const suffix = "~" + encodeBase62(fnv1a32(id) % 62 ** 6, 6);
  return id.slice(0, max - suffix.length) + suffix;
}
function sigmaShortId(len = 10) {
  let id;
  do {
    id = encodeBase62(++_idCounter, len);
  } while (_usedIds.has(id));
  _usedIds.add(id);
  return id;
}
function sigmaInodeId(identifier, casing = "upper") {
  const phys = casing === "lower" ? identifier.toLowerCase() : identifier.toUpperCase();
  return clampId(`inode-${sigmaShortId(22)}/${phys}`);
}
function sigmaPhysicalName(s, casing = "upper") {
  const r = (s || "").trim();
  const verbatim = casing === "lower" ? /^[a-z0-9_]+$/ : /^[A-Z0-9_]+$/;
  if (verbatim.test(r))
    return r;
  const normalized = r.replace(/[^A-Za-z0-9_\s]/g, " ").replace(/([a-z])([A-Z])/g, "$1_$2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2").replace(/([A-Za-z])([0-9])/g, "$1_$2").replace(/([0-9])([A-Za-z])/g, "$1_$2");
  const joined = normalized.split(/[_\s]+/).filter(Boolean).join("_");
  return casing === "lower" ? joined.toLowerCase() : joined.toUpperCase();
}
function sigmaDisplayName(s) {
  const normalized = (s || "").replace(/([a-z])([A-Z])/g, "$1_$2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2").replace(/([A-Za-z])([0-9])/g, "$1_$2").replace(/([0-9])([A-Za-z])/g, "$1_$2");
  const words = normalized.toLowerCase().split(/[_\s/-]+/).filter(Boolean);
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

// ../wt-pbi-dax-fidelity/build/powerbi.js
var PBI_COMMUNITY_LINKS = {
  lod: "community.sigmacomputing.com/t/tableau-level-of-detail-or-lod-calculations-in-sigma/6427",
  groupings: "community.sigmacomputing.com/t/how-to-use-groupings-aggregate-calculations/2003",
  rollup: "community.sigmacomputing.com/t/rollup-perform-aggregate-calculations-across-a-group-of-values-without-using-a-group-by/4367",
  biDiffs: "community.sigmacomputing.com/t/sigma-differences-from-other-bi-tools-overview-for-new-sigma-creators/3285",
  leveled: "community.sigmacomputing.com/t/how-to-implement-complex-leveled-aggregations-in-sigma-lods-dax/5203",
  pop: "community.sigmacomputing.com/t/which-logic-to-use-for-period-over-period-comparisons/3206"
};
function splitCallArgs(s, startIdx) {
  const args = [];
  let depth = 1, argStart = startIdx, i = startIdx;
  let inStr = null;
  for (; i < s.length; i++) {
    const ch = s[i];
    if (inStr) {
      if (ch === inStr)
        inStr = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      inStr = ch;
      continue;
    }
    if (ch === "(" || ch === "[" || ch === "{")
      depth++;
    else if (ch === ")" || ch === "]" || ch === "}") {
      depth--;
      if (depth === 0) {
        args.push(s.slice(argStart, i).trim());
        i++;
        break;
      }
    } else if (ch === "," && depth === 1) {
      args.push(s.slice(argStart, i).trim());
      argStart = i + 1;
    }
  }
  return { args, endPos: i };
}
function rewriteDateDiff(f) {
  const re = /\bDATEDIFF\s*\(/gi;
  let cursor = 0;
  for (let guard = 0; guard < 200; guard++) {
    re.lastIndex = cursor;
    const m = re.exec(f);
    if (!m)
      break;
    const openIdx = m.index + m[0].length;
    const { args, endPos } = splitCallArgs(f, openIdx);
    if (args.length < 3) {
      cursor = openIdx;
      continue;
    }
    const start = args[0];
    const end = args[1];
    const unit = args[2].replace(/^\[|\]$/g, "").trim().toLowerCase();
    const replacement = `DateDiff("${unit}", ${start}, ${end})`;
    f = f.slice(0, m.index) + replacement + f.slice(endPos);
    cursor = m.index + replacement.length;
  }
  return f;
}
function rewriteWeeknum(f) {
  const re = /\bWEEKNUM\s*\(/gi;
  let cursor = 0;
  for (let guard = 0; guard < 200; guard++) {
    re.lastIndex = cursor;
    const m = re.exec(f);
    if (!m)
      break;
    const openIdx = m.index + m[0].length;
    const { args, endPos } = splitCallArgs(f, openIdx);
    if (args.length < 1) {
      cursor = openIdx;
      continue;
    }
    const dateArg = args[0].trim();
    const rt = args.length >= 2 ? args[1].replace(/^\[|\]$/g, "").trim() : "1";
    const off = rt === "2" ? 5 : 6;
    const yearStart = `DateTrunc("year", ${dateArg})`;
    const replacement = `Floor((DateDiff("day", ${yearStart}, ${dateArg}) + Mod(Weekday(${yearStart}) + ${off}, 7)) / 7) + 1`;
    f = f.slice(0, m.index) + replacement + f.slice(endPos);
    cursor = m.index + replacement.length;
  }
  return f;
}
function rewriteSwitchTrue(f) {
  const re = /\bSWITCH\s*\(\s*TRUE\s*\(\s*\)\s*,/gi;
  for (let guard = 0; guard < 200; guard++) {
    re.lastIndex = 0;
    const m = re.exec(f);
    if (!m)
      break;
    const openIdx = m.index + m[0].length;
    const { args, endPos } = splitCallArgs(f, openIdx);
    if (args.length < 2)
      break;
    const hasDefault = args.length % 2 === 1;
    const def = hasDefault ? args[args.length - 1] : null;
    const pairCount = Math.floor(args.length / 2);
    let nested = def !== null ? def : "null";
    for (let p = pairCount - 1; p >= 0; p--) {
      const cond = args[p * 2];
      const val = args[p * 2 + 1];
      nested = `If(${cond}, ${val}, ${nested})`;
    }
    f = f.slice(0, m.index) + nested + f.slice(endPos);
  }
  return f;
}
function rewriteEarlierRank(f) {
  const re = /\bCOUNTROWS\s*\(\s*FILTER\s*\(/gi;
  for (let guard = 0; guard < 50; guard++) {
    re.lastIndex = 0;
    const m = re.exec(f);
    if (!m)
      break;
    const filterOpen = m.index + m[0].length;
    const { args: filterArgs, endPos: filterEnd } = splitCallArgs(f, filterOpen);
    if (filterArgs.length < 2)
      break;
    let j = filterEnd;
    while (j < f.length && /\s/.test(f[j]))
      j++;
    if (f[j] !== ")")
      break;
    let after = j + 1;
    const tail = f.slice(after).match(/^\s*\+\s*1\b/);
    if (!tail)
      break;
    const fullEnd = after + tail[0].length;
    const pred = filterArgs.slice(1).join(", ");
    const cmp = pred.match(/(['"]?[\w ]*'?\[[^\]]+\]|\[[^\]]+\])\s*(>|<)\s*EARLIER\s*\(\s*([^)]+?)\s*\)/i);
    if (!cmp)
      break;
    const rankRefRaw = cmp[1];
    const dir = cmp[2] === ">" ? "desc" : "asc";
    const partRefs = [];
    for (const term of pred.split(/&&/)) {
      const pm = term.match(/(['"]?[\w ]*'?\[[^\]]+\]|\[[^\]]+\])\s*=\s*EARLIER\s*\(\s*[^)]+?\s*\)/i);
      if (pm)
        partRefs.push(pm[1].trim());
    }
    const bare = (x) => x.replace(/'[^']+'\[([^\]]+)\]/g, "[$1]").replace(/\b[A-Za-z_]\w*\[([^\]]+)\]/g, "[$1]").trim();
    const rankRef = bare(rankRefRaw);
    let replacement = `RankDense(${rankRef}, "${dir}")`;
    if (partRefs.length) {
      const parts = partRefs.map(bare).join(", ");
      replacement = `RankDense(${rankRef}, "${dir}", ${parts})`;
    }
    f = f.slice(0, m.index) + replacement + f.slice(fullEnd);
  }
  return f;
}
function rewriteStatIterators(f) {
  const specs = [
    { re: /\bMEDIANX\s*\(/i, build: (a) => a.length >= 2 ? `Median(${a[1]})` : null },
    { re: /\bPERCENTILEX\.INC\s*\(/i, build: (a) => a.length >= 3 ? `PercentileCont(${a[1]}, ${a[2]})` : null },
    { re: /\bPERCENTILEX\.EXC\s*\(/i, build: (a) => a.length >= 3 ? `PercentileCont(${a[1]}, ${a[2]})` : null },
    { re: /\bSTDEVX\.P\s*\(/i, build: (a) => a.length >= 2 ? `Sqrt(VariancePop(${a[1]}))` : null },
    { re: /\bSTDEVX\.S\s*\(/i, build: (a) => a.length >= 2 ? `Sqrt(Variance(${a[1]}))` : null },
    { re: /\bVARX\.P\s*\(/i, build: (a) => a.length >= 2 ? `VariancePop(${a[1]})` : null },
    { re: /\bVARX\.S\s*\(/i, build: (a) => a.length >= 2 ? `Variance(${a[1]})` : null },
    { re: /\bGEOMEANX\s*\(/i, build: (a) => a.length >= 2 ? `Exp(Avg(Ln(${a[1]})))` : null }
  ];
  for (const spec of specs) {
    for (let guard = 0; guard < 50; guard++) {
      const reG = new RegExp(spec.re.source, "gi");
      reG.lastIndex = 0;
      const m = reG.exec(f);
      if (!m)
        break;
      const { args, endPos } = splitCallArgs(f, m.index + m[0].length);
      const rep = spec.build(args);
      if (rep === null)
        break;
      f = f.slice(0, m.index) + rep + f.slice(endPos);
    }
  }
  return f;
}
function rewriteCombineValues(f) {
  const re = /\bCOMBINEVALUES\s*\(/gi;
  for (let guard = 0; guard < 50; guard++) {
    re.lastIndex = 0;
    const m = re.exec(f);
    if (!m)
      break;
    const { args, endPos } = splitCallArgs(f, m.index + m[0].length);
    if (args.length < 2)
      break;
    const sep = args[0];
    const vals = args.slice(1);
    const joined = vals.join(` & ${sep} & `);
    f = f.slice(0, m.index) + joined + f.slice(endPos);
  }
  return f;
}
function rewriteFormatNumeric(f) {
  const re = /\bFORMAT\s*\(/gi;
  for (let guard = 0; guard < 20; guard++) {
    re.lastIndex = 0;
    const m = re.exec(f);
    if (!m)
      break;
    const { args, endPos } = splitCallArgs(f, m.index + m[0].length);
    if (args.length !== 2)
      break;
    const expr = args[0].trim();
    if (/^[A-Za-z0-9_()\-+*/. ]+$/.test(expr) && /[A-Za-z]\s*\(/.test(expr) && !/["'\[]/.test(expr)) {
      const rep = `Text(${recaseDateFns(expr)})`;
      f = f.slice(0, m.index) + rep + f.slice(endPos);
      continue;
    }
    break;
  }
  return f;
}
function rewriteSearch(f) {
  const re = /\b(SEARCH|FIND)\s*\(/g;
  for (let guard = 0; guard < 50; guard++) {
    re.lastIndex = 0;
    const m = re.exec(f);
    if (!m)
      break;
    const { args, endPos } = splitCallArgs(f, m.index + m[0].length);
    if (args.length < 2)
      break;
    const findText = args[0];
    const withinText = args[1];
    const passthrough = args.slice(2, 3);
    const newArgs = [withinText, findText, ...passthrough].map((a) => a.trim());
    const rep = `Find(${newArgs.join(", ")})`;
    f = f.slice(0, m.index) + rep + f.slice(endPos);
  }
  return f;
}
function rewriteSingleValue(f) {
  {
    const re = /\bIF\s*\(\s*HASONEVALUE\s*\(/gi;
    for (let guard = 0; guard < 50; guard++) {
      re.lastIndex = 0;
      const m = re.exec(f);
      if (!m)
        break;
      const ifOpen = m.index + "IF(".length;
      const { args, endPos } = splitCallArgs(f, ifOpen);
      if (args.length < 3)
        break;
      const hovM = args[0].match(/^\s*HASONEVALUE\s*\(/i);
      const svM = args[1].match(/^\s*SELECTEDVALUE\s*\(/i);
      if (!hovM || !svM)
        break;
      const hovArgs = splitCallArgs(args[0], hovM.index + hovM[0].length).args;
      const svArgs = splitCallArgs(args[1], svM.index + svM[0].length).args;
      if (hovArgs.length < 1 || svArgs.length < 1)
        break;
      const col = svArgs[0];
      const def = args[2];
      const rep = `If(CountDistinct(${col}) = 1, Min(${col}), ${def})`;
      f = f.slice(0, m.index) + rep + f.slice(endPos);
    }
  }
  {
    const re = /\bSELECTEDVALUE\s*\(/gi;
    for (let guard = 0; guard < 50; guard++) {
      re.lastIndex = 0;
      const m = re.exec(f);
      if (!m)
        break;
      const { args, endPos } = splitCallArgs(f, m.index + m[0].length);
      if (args.length < 1)
        break;
      const col = args[0];
      const def = args.length >= 2 ? args[1] : "null";
      const rep = `If(CountDistinct(${col}) = 1, Min(${col}), ${def})`;
      f = f.slice(0, m.index) + rep + f.slice(endPos);
    }
  }
  {
    const re = /\bHASONEVALUE\s*\(/gi;
    for (let guard = 0; guard < 50; guard++) {
      re.lastIndex = 0;
      const m = re.exec(f);
      if (!m)
        break;
      const { args, endPos } = splitCallArgs(f, m.index + m[0].length);
      if (args.length < 1)
        break;
      const rep = `CountDistinct(${args[0]}) = 1`;
      f = f.slice(0, m.index) + rep + f.slice(endPos);
    }
  }
  return f;
}
function rewriteCountRowsFilter(f) {
  const re = /\b(?:COUNTROWS|COUNT)\s*\(/gi;
  for (let guard = 0; guard < 50; guard++) {
    re.lastIndex = 0;
    let replaced = false;
    let m;
    while ((m = re.exec(f)) !== null) {
      const { args, endPos } = splitCallArgs(f, m.index + m[0].length);
      if (args.length !== 1)
        continue;
      const inner = args[0].trim();
      const fm = inner.match(/^FILTER\s*\(/i);
      if (!fm)
        continue;
      const fr = splitCallArgs(inner, fm[0].length);
      if (fr.args.length < 2)
        continue;
      let pred = fr.args.slice(1).join(", ").trim();
      pred = pred.replace(/'[^']+'\[([^\]]+)\]/g, "[$1]").replace(/\b[A-Za-z_]\w*\[([^\]]+)\]/g, "[$1]");
      f = f.slice(0, m.index) + `CountIf(${pred})` + f.slice(endPos);
      replaced = true;
      break;
    }
    if (!replaced)
      break;
  }
  return f;
}
function rewriteVarReturn(f) {
  if (!/^\s*VAR\b/i.test(f) || !/\bRETURN\b/i.test(f))
    return f;
  const marks = [];
  let depth = 0, inStr = null;
  for (let i = 0; i < f.length; i++) {
    const ch = f[i];
    if (inStr) {
      if (ch === inStr)
        inStr = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      inStr = ch;
      continue;
    }
    if (ch === "(" || ch === "[")
      depth++;
    else if (ch === ")" || ch === "]")
      depth--;
    else if (depth === 0) {
      const m = f.slice(i).match(/^(VAR|RETURN)\b/i);
      if (m) {
        marks.push({ kw: m[1].toUpperCase(), pos: i, end: i + m[1].length });
        i += m[1].length - 1;
      }
    }
  }
  const ret = marks.find((m) => m.kw === "RETURN");
  if (!ret || marks[0].kw !== "VAR")
    return f;
  const vars = [];
  for (let k = 0; k < marks.length; k++) {
    if (marks[k].kw !== "VAR")
      continue;
    const segEnd = k + 1 < marks.length ? marks[k + 1].pos : f.length;
    const body = f.slice(marks[k].end, segEnd);
    const eq = body.indexOf("=");
    if (eq < 0)
      return f;
    const name = body.slice(0, eq).trim();
    let expr = body.slice(eq + 1).trim();
    if (!/^[A-Za-z_]\w*$/.test(name))
      return f;
    for (const v of vars) {
      expr = expr.replace(new RegExp(`\\b${v.name}\\b`, "g"), `(${v.expr})`);
    }
    vars.push({ name, expr });
  }
  let out = f.slice(ret.end).trim();
  for (const v of [...vars].sort((a, b) => b.name.length - a.name.length)) {
    out = out.replace(new RegExp(`\\b${v.name}\\b`, "g"), `(${v.expr})`);
  }
  if (/\bVAR\b|\bRETURN\b/i.test(out))
    return f;
  return out;
}
function rewriteSimpleIterator(f) {
  const ITER = { SUMX: "Sum", AVERAGEX: "Avg", MINX: "Min", MAXX: "Max" };
  const re = /\b(SUMX|AVERAGEX|MINX|MAXX)\s*\(/gi;
  for (let guard = 0; guard < 50; guard++) {
    re.lastIndex = 0;
    const m = re.exec(f);
    if (!m)
      break;
    const fn = m[1].toUpperCase();
    const { args, endPos } = splitCallArgs(f, m.index + m[0].length);
    if (args.length !== 2)
      break;
    const tbl = args[0].trim();
    const body = args[1].trim();
    const bareTable = /^'[^']+'$/.test(tbl) || /^[A-Za-z_]\w*$/.test(tbl);
    const bodyHasAgg = /\b(SUM|AVERAGE|MIN|MAX|COUNT|COUNTROWS|DISTINCTCOUNT|CALCULATE|SUMX|AVERAGEX|MINX|MAXX|COUNTAX|RANKX)\s*\(/i.test(body);
    if (!bareTable || bodyHasAgg)
      break;
    const bareBody = body.replace(/'[^']+'\[([^\]]+)\]/g, "[$1]").replace(/\b[A-Za-z_]\w*\[([^\]]+)\]/g, "[$1]");
    f = f.slice(0, m.index) + `${ITER[fn]}(${bareBody})` + f.slice(endPos);
  }
  return f;
}
function rewriteCalcGrandTotal(f) {
  const re = /\bCALCULATE\s*\(/gi;
  for (let guard = 0; guard < 50; guard++) {
    re.lastIndex = 0;
    let replaced = false;
    let m;
    while ((m = re.exec(f)) !== null) {
      const { args, endPos } = splitCallArgs(f, m.index + m[0].length);
      if (args.length !== 2)
        continue;
      const filt = args[1].trim();
      if (!/^(ALL|REMOVEFILTERS)\s*\(\s*'?[A-Za-z_][\w ]*'?\s*\)$/i.test(filt))
        continue;
      f = f.slice(0, m.index) + `GrandTotal(${args[0].trim()})` + f.slice(endPos);
      replaced = true;
      break;
    }
    if (!replaced)
      break;
  }
  return f;
}
function splitInList(body) {
  const out = [];
  let start = 0, inStr = null, depth = 0;
  for (let i = 0; i < body.length; i++) {
    const ch = body[i];
    if (inStr) {
      if (ch === inStr)
        inStr = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      inStr = ch;
      continue;
    }
    if (ch === "(" || ch === "{")
      depth++;
    else if (ch === ")" || ch === "}")
      depth--;
    else if (ch === "," && depth === 0) {
      out.push(body.slice(start, i).trim());
      start = i + 1;
    }
  }
  const last = body.slice(start).trim();
  if (last)
    out.push(last);
  return out.filter(Boolean);
}
function translateDaxPredicate(predRaw) {
  let p = (predRaw || "").trim();
  if (!p)
    return { ok: false, reason: "empty predicate" };
  {
    const capDp = (s) => ({ MONTH: "Month", YEAR: "Year", DAY: "Day" })[s.toUpperCase()] || s;
    const bareDp = (x) => x.replace(/'[^']+'\[([^\]]+)\]/g, "[$1]").replace(/\b[A-Za-z_]\w*\[([^\]]+)\]/g, "[$1]");
    const DP_TODAY = String.raw`(MONTH|YEAR|DAY)\s*\(\s*TODAY\s*\(\s*\)\s*\)`;
    const DP_COL = String.raw`(MONTH|YEAR|DAY)\s*\(\s*('?[A-Za-z_][\w ]*'?\[[^\]]+\])\s*\)`;
    const OP = String.raw`(<>|>=|<=|=|>|<)`;
    let dpm = p.match(new RegExp(`^\\s*${DP_TODAY}\\s*${OP}\\s*${DP_COL}\\s*$`, "i"));
    if (dpm)
      return { ok: true, sigma: `${capDp(dpm[1])}(Today()) ${dpm[2] === "<>" ? "!=" : dpm[2]} ${capDp(dpm[3])}(${bareDp(dpm[4])})` };
    dpm = p.match(new RegExp(`^\\s*${DP_COL}\\s*${OP}\\s*${DP_TODAY}\\s*$`, "i"));
    if (dpm)
      return { ok: true, sigma: `${capDp(dpm[1])}(${bareDp(dpm[2])}) ${dpm[3] === "<>" ? "!=" : dpm[3]} ${capDp(dpm[4])}(Today())` };
  }
  if (/\b(CALCULATE|FILTER|ALL|ALLEXCEPT|ALLSELECTED|REMOVEFILTERS|KEEPFILTERS|VALUES|RELATEDTABLE|EARLIER|TREATAS|USERELATIONSHIP|SELECTEDVALUE)\s*\(/i.test(p)) {
    return { ok: false, reason: `predicate contains filter-context functions (${p.slice(0, 60)})` };
  }
  const inRe = /(\bNOT\s+)?((?:'[^']+'|\b[A-Za-z_][\w ]*)?\[[^\]]+\])\s+(NOT\s+)?IN\s*\{/i;
  for (let guard = 0; guard < 20; guard++) {
    const m = p.match(inRe);
    if (!m)
      break;
    const ref = m[2];
    const negate = !!(m[1] || m[3]);
    const open = m.index + m[0].length;
    let depth = 1, i = open, inStr = null;
    for (; i < p.length; i++) {
      const ch = p[i];
      if (inStr) {
        if (ch === inStr)
          inStr = null;
        continue;
      }
      if (ch === '"') {
        inStr = ch;
        continue;
      }
      if (ch === "{")
        depth++;
      else if (ch === "}") {
        depth--;
        if (!depth)
          break;
      }
    }
    if (depth)
      return { ok: false, reason: "unbalanced IN { \u2026 } list" };
    const items = splitInList(p.slice(open, i));
    if (!items.length)
      return { ok: false, reason: "empty IN { } list" };
    const chain = negate ? items.map((v) => `${ref} != ${v}`).join(" and ") : items.map((v) => `${ref} = ${v}`).join(" or ");
    p = p.slice(0, m.index) + `(${chain})` + p.slice(i + 1);
  }
  p = p.replace(/\bNOT\s*\(/gi, "Not (");
  p = p.replace(/\bISBLANK\s*\(/gi, "IsNull(");
  p = p.replace(/\bTRUE\s*\(\s*\)/gi, "True").replace(/\bFALSE\s*\(\s*\)/gi, "False");
  p = p.replace(/<>/g, "!=");
  p = p.replace(/&&/g, " and ").replace(/\|\|/g, " or ");
  p = p.replace(/'[^']+'\[([^\]]+)\]/g, "[$1]").replace(/\b[A-Za-z_]\w*\[([^\]]+)\]/g, "[$1]");
  for (const term of p.split(/\b(?:and|or)\b/i)) {
    const c = term.match(/(=|!=|>=|<=|>|<)([\s\S]*)$/);
    if (c && /\[[^\]]+\]/.test(c[2])) {
      return { ok: false, reason: `compares against an aggregate/measure (${c[2].trim().slice(0, 50)})` };
    }
  }
  return { ok: true, sigma: p.replace(/\s+/g, " ").trim() };
}
var CALC_TIME_INTEL_DEFER_RE = /\b(TOTALYTD|TOTALQTD|TOTALMTD|SAMEPERIODLASTYEAR|DATEADD|DATESYTD|DATESINPERIOD|PARALLELPERIOD|PREVIOUSMONTH|PREVIOUSQUARTER|PREVIOUSYEAR|PREVIOUSDAY|NEXTMONTH|NEXTQUARTER|NEXTYEAR)\s*\(/i;
function recaseDateFns(expr) {
  const map = { TODAY: "Today", NOW: "Now", DATE: "Date", YEAR: "Year", MONTH: "Month", DAY: "Day" };
  return expr.replace(/\b(TODAY|NOW|DATE|YEAR|MONTH|DAY)\b/gi, (w) => map[w.toUpperCase()] || w);
}
function expandMeasureRefs(dax, measureDax) {
  let out = String(dax).trim();
  for (let depth = 0; depth < 8; depth++) {
    let changed = false;
    out = out.replace(/(^|[^\w\]')])\[([^\[\]]+)\]/g, (full, pre, name) => {
      const body = measureDax[name];
      if (body === void 0)
        return full;
      changed = true;
      const b = Array.isArray(body) ? body.join("\n") : String(body);
      return `${pre}(${b.trim()})`;
    });
    if (!changed)
      return out;
  }
  return null;
}
var SIMPLE_AGG_RE = /\b(SUM|AVERAGE|MIN|MAX|COUNT|COUNTA|COUNTROWS|DISTINCTCOUNT)\s*\(([^()]*)\)/gi;
function isAggCombination(expr) {
  const stripped = String(expr).replace(SIMPLE_AGG_RE, "1");
  return /\d/.test(stripped) && /^[\d\s+\-*/().]+$/.test(stripped);
}
function rewriteCalculateConditionals(fIn, warnings, measureName, measureDax, rawDax) {
  let f = fIn;
  const daxNote = String(rawDax).replace(/\s+/g, " ").trim().slice(0, 220);
  const bareRef = (x) => x.replace(/'[^']+'\[([^\]]+)\]/g, "[$1]").replace(/\b[A-Za-z_]\w*\[([^\]]+)\]/g, "[$1]");
  const wholeTableStripRe = /^(ALL|REMOVEFILTERS)\s*\(\s*'?[A-Za-z_][\w ]*'?\s*\)$/i;
  const re = /\bCALCULATE\s*\(/gi;
  let cursor = 0;
  for (let guard = 0; guard < 30; guard++) {
    re.lastIndex = cursor;
    const m = re.exec(f);
    if (!m)
      break;
    const { args, endPos } = splitCallArgs(f, m.index + m[0].length);
    if (!args.length) {
      cursor = m.index + m[0].length;
      continue;
    }
    if (args.length === 1) {
      f = f.slice(0, m.index) + args[0].trim() + f.slice(endPos);
      continue;
    }
    if (CALC_TIME_INTEL_DEFER_RE.test(args.join(","))) {
      cursor = m.index + m[0].length;
      continue;
    }
    let aggExpr = args[0].trim();
    const aggRefM = aggExpr.match(/^\[([^\]]+)\]$/);
    if (aggRefM && measureDax[aggRefM[1]]) {
      const refDax = measureDax[aggRefM[1]].trim();
      if (/^(SUM|AVERAGE|MIN|MAX|COUNT|COUNTA|COUNTROWS|DISTINCTCOUNT)\s*\([^()]*\)$/i.test(refDax)) {
        aggExpr = refDax;
      }
    }
    const aggM = aggExpr.match(/^\s*(SUM|AVERAGE|MIN|MAX|COUNT|COUNTA|COUNTROWS|DISTINCTCOUNT)\s*\(([\s\S]*)\)\s*$/i);
    let composite = null;
    if (!aggM) {
      const expanded = expandMeasureRefs(aggExpr, measureDax);
      if (expanded && isAggCombination(expanded))
        composite = expanded;
      else {
        cursor = m.index + m[0].length;
        continue;
      }
    }
    const sigmaAggPlain = (fn, arg) => {
      const F = fn.toUpperCase();
      if (F === "COUNTROWS" || F === "COUNT" && !arg.trim())
        return "Count()";
      const map = { SUM: "Sum", AVERAGE: "Avg", MIN: "Min", MAX: "Max", COUNT: "Count", COUNTA: "Count", DISTINCTCOUNT: "CountDistinct" };
      return `${map[F]}(${bareRef(arg.trim())})`;
    };
    const sigmaAggCond = (fn, arg, combined2) => {
      const F = fn.toUpperCase();
      const col = bareRef(arg.trim());
      const hasCol = /\[[^\]]+\]/.test(col);
      if (F === "COUNTROWS" || (F === "COUNT" || F === "COUNTA") && !hasCol)
        return `CountIf(${combined2})`;
      if (F === "COUNT" || F === "COUNTA")
        return `CountIf(${combined2} and IsNotNull(${col}))`;
      if (F === "DISTINCTCOUNT")
        return `CountDistinct(If(${combined2}, ${col}, null))`;
      const map = { SUM: "SumIf", AVERAGE: "AvgIf", MIN: "MinIf", MAX: "MaxIf" };
      return `${map[F] || "SumIf"}(${col}, ${combined2})`;
    };
    let grandTotal = false;
    const preds = [];
    const filterRemovalCols = [];
    let flagged = null;
    for (let a of args.slice(1).map((x) => x.trim())) {
      const km = a.match(/^KEEPFILTERS\s*\(/i);
      if (km) {
        const kr = splitCallArgs(a, km[0].length);
        if (kr.args.length >= 1)
          a = kr.args.join(", ").trim();
      }
      if (wholeTableStripRe.test(a)) {
        grandTotal = true;
        continue;
      }
      const colStrip = a.match(/^(ALL|REMOVEFILTERS)\s*\(\s*('?[A-Za-z_][\w ]*'?\[[^\]]+\])\s*\)$/i);
      if (colStrip) {
        filterRemovalCols.push(colStrip[2]);
        if (warnings)
          warnings.push(`\u26A0 "${measureName}": ${colStrip[1].toUpperCase()}(${colStrip[2]}) removes filter context on ONE column \u2014 translated as a filter-scoped metric that IGNORES any control bound to ${colStrip[2].replace(/^.*\[/, "[")}. Configure this metric in the workbook to ignore that control; it must NOT collapse to a GrandTotal. Original DAX: ${daxNote}`);
        continue;
      }
      if (/^(ALLEXCEPT|ALLSELECTED|ALL|REMOVEFILTERS)\s*\(/i.test(a)) {
        flagged = `\u26A0 "${measureName}": CALCULATE filter ${a.slice(0, 70)} re-scopes filter context (subtotal semantics) \u2014 no faithful Sigma scalar-metric equivalent. Recreate as a grouped workbook element (group by the kept dimensions, aggregate, then window-total). Original DAX: ${daxNote}`;
        break;
      }
      const dbm = a.match(/^DATESBETWEEN\s*\(/i);
      if (dbm) {
        const dbr = splitCallArgs(a, dbm[0].length);
        const colM = dbr.args.length === 3 ? dbr.args[0].match(/('?[A-Za-z_][\w ]*'?\[[^\]]+\])\s*$/) : null;
        if (colM) {
          const col = bareRef(colM[1]);
          const start = recaseDateFns(dbr.args[1].trim());
          const end = recaseDateFns(dbr.args[2].trim());
          preds.push(`${col} >= ${start} and ${col} <= ${end}`);
          continue;
        }
        flagged = `\u26A0 "${measureName}": DATESBETWEEN filter isn't the <date column>, <start>, <end> shape \u2014 recreate the window manually. Original DAX: ${daxNote}`;
        break;
      }
      const fm = a.match(/^FILTER\s*\(/i);
      if (fm) {
        const fr = splitCallArgs(a, fm[0].length);
        if (fr.args.length < 2) {
          flagged = `\u26A0 "${measureName}": malformed FILTER in CALCULATE. Original DAX: ${daxNote}`;
          break;
        }
        const scope = fr.args[0].trim();
        if (wholeTableStripRe.test(scope))
          grandTotal = true;
        else if (!/^'?[A-Za-z_][\w ]*'?$/.test(scope)) {
          flagged = `\u26A0 "${measureName}": FILTER iterates a derived row set (${scope.slice(0, 50)}) \u2014 not a plain table; no row-level conditional-aggregate equivalent. Recreate with a grouped workbook element. Original DAX: ${daxNote}`;
          break;
        }
        const t2 = translateDaxPredicate(fr.args.slice(1).join(", "));
        if (!t2.ok) {
          flagged = `\u26A0 "${measureName}": CALCULATE filter ${t2.reason}. Needs a windowed comparison or grouping \u2014 add manually. Original DAX: ${daxNote} See: ${PBI_COMMUNITY_LINKS.leveled}`;
          break;
        }
        preds.push(t2.sigma);
        continue;
      }
      const t = translateDaxPredicate(a);
      if (!t.ok) {
        flagged = `\u26A0 "${measureName}": CALCULATE filter ${t.reason}. Needs a windowed comparison or grouping \u2014 add manually. Original DAX: ${daxNote} See: ${PBI_COMMUNITY_LINKS.leveled}`;
        break;
      }
      preds.push(t.sigma);
    }
    if (flagged) {
      if (warnings)
        warnings.push(flagged);
      return { f, dropped: true };
    }
    const aggFnEarly = aggM ? aggM[1].toUpperCase() : "";
    const plainAgg = () => {
      if (composite)
        return `(${composite.replace(SIMPLE_AGG_RE, (_mm, fn, arg) => sigmaAggPlain(fn, arg))})`;
      if (aggFnEarly === "COUNTROWS")
        return "Count()";
      const map = { SUM: "Sum", AVERAGE: "Avg", MIN: "Min", MAX: "Max", COUNT: "Count", COUNTA: "Count", DISTINCTCOUNT: "CountDistinct" };
      return `${map[aggFnEarly]}(${bareRef(aggM[2].trim())})`;
    };
    if (!preds.length) {
      if (grandTotal) {
        const gOut = `GrandTotal(${plainAgg()})`;
        f = f.slice(0, m.index) + gOut + f.slice(endPos);
        cursor = m.index + gOut.length;
        continue;
      }
      if (filterRemovalCols.length) {
        const frOut = plainAgg();
        f = f.slice(0, m.index) + frOut + f.slice(endPos);
        cursor = m.index + frOut.length;
        continue;
      }
      cursor = m.index + m[0].length;
      continue;
    }
    const combined = preds.length === 1 ? preds[0] : preds.map((p) => /\b(or)\b/i.test(p) ? `(${p})` : p).join(" and ");
    const aggFn = aggFnEarly;
    let out;
    if (composite) {
      out = `(${composite.replace(SIMPLE_AGG_RE, (_mm, fn, arg) => sigmaAggCond(fn, arg, combined))})`;
    } else {
      out = sigmaAggCond(aggFn, aggM[2], combined);
    }
    if (grandTotal)
      out = `GrandTotal(${out})`;
    f = f.slice(0, m.index) + out + f.slice(endPos);
    cursor = m.index + out.length;
  }
  return { f, dropped: false };
}
function pruneDanglingMetrics(metrics, droppedNames, warnings) {
  for (let pass = 0; pass < 10; pass++) {
    const before = metrics.length;
    for (let i = metrics.length - 1; i >= 0; i--) {
      const refs = (String(metrics[i].formula).match(/\[([^\]\/]+)\]/g) || []).map((r) => r.slice(1, -1));
      const bad = refs.find((r) => droppedNames.has(r));
      if (bad) {
        if (warnings)
          warnings.push(`\u26A0 "${metrics[i].name}": references "[${bad}]" which did not translate \u2014 dropped to avoid a dangling reference.`);
        droppedNames.add(metrics[i].name);
        metrics.splice(i, 1);
      }
    }
    if (metrics.length === before)
      break;
  }
}
function hasBareWindowFn(formula) {
  const noStr = String(formula).replace(/"[^"]*"/g, "").replace(/'[^']*'/g, "");
  return /\b(Rank|RankDense|Lag|Lead|RowNumber|NTile|FirstValue|LastValue)\s*\(/.test(noStr);
}
function pbiDaxToSigma(dax, warnings, measureName, measureDax = {}) {
  if (Array.isArray(dax))
    dax = dax.join("\n");
  if (typeof dax !== "string" || !dax.trim())
    return null;
  let f = dax.trim();
  f = rewriteEarlierRank(f);
  if (/\bEARLIER\s*\(/i.test(f)) {
    if (warnings)
      warnings.push(`\u26A0 "${measureName}": unrecognized EARLIER row-context pattern \u2014 not auto-translated (recognized idioms: rank, running total, group share/total, peer count). Recreate as a window calc in a grouped workbook element. Original DAX: ${String(dax).replace(/\s+/g, " ").trim().slice(0, 220)}`);
    return null;
  }
  f = rewriteStatIterators(f);
  f = rewriteCombineValues(f);
  f = rewriteFormatNumeric(f);
  f = rewriteSearch(f);
  f = rewriteSingleValue(f);
  f = rewriteSwitchTrue(f);
  f = rewriteCountRowsFilter(f);
  f = rewriteVarReturn(f);
  f = rewriteSimpleIterator(f);
  f = rewriteCalcGrandTotal(f);
  f = f.replace(/\bDISTINCTCOUNTNOBLANK\s*\(/gi, "CountDistinct(");
  if (/\bUSERELATIONSHIP\s*\(/i.test(f)) {
    if (warnings)
      warnings.push(`\u26A0 "${measureName}": USERELATIONSHIP outside a model measure \u2014 no alternate join path can be activated here. Original DAX: ${String(dax).replace(/\s+/g, " ").trim().slice(0, 220)}`);
    return null;
  }
  if (/\bCALCULATE\s*\(/i.test(f)) {
    const r = rewriteCalculateConditionals(f, warnings, measureName, measureDax, dax);
    if (r.dropped)
      return null;
    f = r.f;
  }
  if (/\bCALCULATE\s*\(/i.test(f) && /\b(ALL|ALLEXCEPT|REMOVEFILTERS|ALLSELECTED)\s*\(/i.test(f)) {
    if (warnings)
      warnings.push(`\u26A0 "${measureName}": uses CALCULATE with filter context manipulation. In Sigma, use groupings. See: ${PBI_COMMUNITY_LINKS.leveled}`);
    return null;
  }
  if (/\b(SUMX|AVERAGEX|MINX|MAXX|COUNTAX|CONCATENATEX)\s*\(/i.test(f)) {
    const fn = f.match(/\b(SUMX|AVERAGEX|MINX|MAXX|COUNTAX|CONCATENATEX)/i)[1];
    if (warnings)
      warnings.push(`\u26A0 "${measureName}": uses DAX iterator (${fn}). Use groupings or calculated columns. See: ${PBI_COMMUNITY_LINKS.groupings}`);
    return null;
  }
  if (/\b(RANKX|RANK\.EQ|RANK\.AVG|RANK)\s*\(/i.test(f)) {
    const fn = f.match(/\b(RANKX|RANK\.EQ|RANK\.AVG|RANK)/i)[1];
    if (warnings)
      warnings.push(`\u26A0 "${measureName}": uses DAX ranking (${fn}). No data-model-metric equivalent \u2014 add a workbook Rank() in an ordered table, or a grouped element. See: ${PBI_COMMUNITY_LINKS.groupings}`);
    return null;
  }
  if (/\b(ISINSCOPE|ISFILTERED|ISCROSSFILTERED|SELECTEDMEASURE)\s*\(/i.test(f)) {
    const fn = f.match(/\b(ISINSCOPE|ISFILTERED|ISCROSSFILTERED|SELECTEDMEASURE)/i)[1];
    if (warnings)
      warnings.push(`\u26A0 "${measureName}": uses DAX scope introspection (${fn}). No static data-model equivalent \u2014 express the level explicitly with groupings, or drop. See: ${PBI_COMMUNITY_LINKS.leveled}`);
    return null;
  }
  if (/\b(TOTALYTD|TOTALQTD|TOTALMTD|SAMEPERIODLASTYEAR|DATEADD|DATESYTD|PARALLELPERIOD|PREVIOUSMONTH|PREVIOUSQUARTER|PREVIOUSYEAR)\s*\(/i.test(f)) {
    const fn = f.match(/\b(TOTALYTD|TOTALQTD|TOTALMTD|SAMEPERIODLASTYEAR|DATEADD|DATESYTD|PARALLELPERIOD|PREVIOUSMONTH|PREVIOUSQUARTER|PREVIOUSYEAR)/i)[1];
    if (warnings)
      warnings.push(`\u26A0 "${measureName}": uses DAX time intelligence (${fn}). Use Period over Period feature. See: ${PBI_COMMUNITY_LINKS.pop}`);
    return null;
  }
  if (/\bCALCULATE\s*\(/i.test(f)) {
    if (warnings)
      warnings.push(`\u26A0 "${measureName}": complex CALCULATE expression. Use groupings. See: ${PBI_COMMUNITY_LINKS.leveled}`);
    return null;
  }
  if (/\bVAR\b/i.test(f) && /\bRETURN\b/i.test(f)) {
    if (warnings)
      warnings.push(`\u26A0 "${measureName}": uses DAX VAR/RETURN. Break into multiple calculated columns. See: ${PBI_COMMUNITY_LINKS.biDiffs}`);
    return null;
  }
  f = rewriteDateDiff(f);
  f = rewriteWeeknum(f);
  const divideMatch = f.match(/\bDIVIDE\s*\(/i);
  if (divideMatch) {
    const startIdx = divideMatch.index + divideMatch[0].length;
    const divArgs = [];
    let depth = 1, argStart = startIdx;
    for (let i = startIdx; i < f.length && depth > 0; i++) {
      if (f[i] === "(")
        depth++;
      else if (f[i] === ")") {
        depth--;
        if (depth === 0) {
          divArgs.push(f.slice(argStart, i).trim());
          break;
        }
      } else if (f[i] === "," && depth === 1) {
        divArgs.push(f.slice(argStart, i).trim());
        argStart = i + 1;
      }
    }
    if (divArgs.length >= 2) {
      const num = divArgs[0], den = divArgs[1], alt = divArgs[2];
      let d2 = 1, endPos = startIdx;
      for (; endPos < f.length && d2 > 0; endPos++) {
        if (f[endPos] === "(")
          d2++;
        else if (f[endPos] === ")")
          d2--;
      }
      let replacement;
      if (alt && alt.trim()) {
        replacement = `If((${den}) = 0, ${alt.trim()}, (${num}) / (${den}))`;
      } else {
        replacement = `(${num}) / NullIf((${den}), 0)`;
      }
      f = f.slice(0, divideMatch.index) + replacement + f.slice(endPos);
    }
  }
  f = f.replace(/\bDISTINCTCOUNT\s*\(/gi, "CountDistinct(");
  f = f.replace(/\bCOUNTROWS\s*\(\s*'?[^)]*'?\s*\)/gi, "Count()");
  f = f.replace(/\bCOUNTA\s*\(/gi, "CountIf(IsNotNull(");
  f = f.replace(/\bSUM\s*\(/gi, "Sum(");
  f = f.replace(/\bAVERAGE\s*\(/gi, "Avg(");
  f = f.replace(/\bMIN\s*\(/gi, "Min(");
  f = f.replace(/\bMAX\s*\(/gi, "Max(");
  f = f.replace(/\bCOUNT\s*\(/gi, "Count(");
  const hadRelated = /\bRELATED\s*\(/i.test(f);
  if (hadRelated && warnings) {
    warnings.push(`\u2139 Calculated column "${measureName}": uses RELATED() \u2014 column will be moved to a derived "<Table> View" element with cross-element refs rewritten to [SRC/REL/Col] form.`);
  }
  f = f.replace(/\bRELATEDTABLE\s*\([^)]*\)/gi, "/* RELATEDTABLE - use relationship */");
  f = f.replace(/\bIF\s*\(/gi, "If(");
  f = f.replace(/\bSWITCH\s*\(/gi, "Switch(");
  f = f.replace(/\bISBLANK\s*\(/gi, "IsNull(");
  f = f.replace(/\bCOALESCE\s*\(/gi, "Coalesce(");
  f = f.replace(/\bBLANK\s*\(\s*\)/gi, "null");
  f = f.replace(/\bNOT\s*\(/gi, "Not (");
  f = f.replace(/\bTRUE\s*\(\s*\)/gi, "True");
  f = f.replace(/\bFALSE\s*\(\s*\)/gi, "False");
  f = f.replace(/&&/g, " and ");
  f = f.replace(/\|\|/g, " or ");
  f = f.replace(/\bCONCATENATE\s*\(/gi, "Concat(");
  f = f.replace(/\bLEN\s*\(/gi, "Len(");
  f = f.replace(/\bUPPER\s*\(/gi, "Upper(");
  f = f.replace(/\bLOWER\s*\(/gi, "Lower(");
  f = f.replace(/\bTRIM\s*\(/gi, "Trim(");
  f = f.replace(/\bLEFT\s*\(/gi, "Left(");
  f = f.replace(/\bRIGHT\s*\(/gi, "Right(");
  f = f.replace(/\bMID\s*\(/gi, "Mid(");
  f = f.replace(/\bSUBSTITUTE\s*\(/gi, "Replace(");
  f = f.replace(/\bFORMAT\s*\(/gi, "DateFormat(");
  f = f.replace(/\bABS\s*\(/gi, "Abs(");
  f = f.replace(/\bROUND\s*\(/gi, "Round(");
  f = f.replace(/\bINT\s*\(/gi, "Int(");
  f = f.replace(/\bSQRT\s*\(/gi, "Sqrt(");
  f = f.replace(/\bPOWER\s*\(/gi, "Power(");
  f = f.replace(/\bMOD\s*\(/gi, "Mod(");
  f = f.replace(/\bEXP\s*\(/gi, "Exp(");
  f = f.replace(/\bLN\s*\(/gi, "Ln(");
  f = f.replace(/\bLOG10\s*\(/gi, "Log(");
  f = f.replace(/\bLOG\s*\(/gi, "Log(");
  f = f.replace(/\bCEILING\s*\(([^(),]+),\s*([^()]+)\)/gi, "Ceiling($1 / $2) * $2");
  f = f.replace(/\bFLOOR\s*\(([^(),]+),\s*([^()]+)\)/gi, "Floor($1 / $2) * $2");
  f = f.replace(/\bCEILING\s*\(/gi, "Ceiling(");
  f = f.replace(/\bFLOOR\s*\(/gi, "Floor(");
  f = f.replace(/\bYEAR\s*\(/gi, "Year(");
  f = f.replace(/\bMONTH\s*\(/gi, "Month(");
  f = f.replace(/\bDAY\s*\(/gi, "Day(");
  f = f.replace(/\bHOUR\s*\(/gi, "Hour(");
  f = f.replace(/\bMINUTE\s*\(/gi, "Minute(");
  f = f.replace(/\bSECOND\s*\(/gi, "Second(");
  f = f.replace(/\bTODAY\s*\(\s*\)/gi, "Today()");
  f = f.replace(/\bNOW\s*\(\s*\)/gi, "Now()");
  f = f.replace(/\bDATE\s*\(/gi, "MakeDate(");
  f = f.replace(/\bDATEDIFF\s*\(/gi, "DateDiff(");
  const quotedTablePrefixes = (f.match(/'([^']+)'\[/g) || []).map((m) => m.replace(/'\[$/g, "").replace(/^'/g, ""));
  const unquotedTablePrefixes = (f.match(/\b([A-Za-z_]\w*)\[/g) || []).map((m) => m.replace(/\[$/, ""));
  const allTablePrefixes = [.../* @__PURE__ */ new Set([...quotedTablePrefixes, ...unquotedTablePrefixes])].filter((p) => !/^(If|Switch|Not|And|Or|Sum|Avg|Min|Max|Count|CountIf|CountDistinct|CumulativeSum|Coalesce|Nullif|Round|Floor|Ceiling|Abs|Upper|Lower|Trim|Left|Right|Mid|Replace|Find|Len|Year|Month|Day|Hour|Minute|Second|Today|Now|MakeDate|DateDiff|DateAdd|DateTrunc|DateFormat|IsNull|IsNotNull|Int|Number|Text|Sqrt|Power|Concat|In|GrandTotal|CumulativeAvg|Weekday|Mod|DateTrunc)$/.test(p));
  if (allTablePrefixes.length > 1 && warnings) {
    const tableNames = allTablePrefixes.join(", ");
    warnings.push(`\u26A0 Calculated column "${measureName}": references columns from multiple tables (${tableNames}). Column context has been simplified \u2014 verify formula references the correct columns.`);
  }
  f = f.replace(/'[^']+'\[([^\]]+)\]/g, "[$1]");
  f = f.replace(/\b[A-Za-z_]\w*\[([^\]]+)\]/g, "[$1]");
  f = f.replace(/\bRELATED\s*\(\s*(\[[^\]]+\])\s*\)/gi, "$1");
  f = f.replace(/(\[[^\]]+\])(\s*&)/g, "Text($1)$2");
  f = f.replace(/(&\s*)(\[[^\]]+\])/g, "$1Text($2)");
  return f.trim();
}
function pbiExtractPathFromM(mExpr) {
  if (!mExpr)
    return null;
  const sqlDbMatch = mExpr.match(/Sql\.Database\s*\(\s*"[^"]*"\s*,\s*"([^"]+)"/i);
  const schemaMatch = mExpr.match(/\{[^}]*\[Schema\s*=\s*"([^"]+)"\]/i) || mExpr.match(/\{[^}]*\[Name\s*=\s*"([^"]+)"\s*,\s*Kind\s*=\s*"Schema"\]/i);
  const tableKindMatch = mExpr.match(/\{[^}]*\[Name\s*=\s*"([^"]+)"\s*,\s*Kind\s*=\s*"Table"\]/i);
  if (sqlDbMatch && tableKindMatch) {
    const db = sqlDbMatch[1];
    const table = tableKindMatch[1];
    const schema = schemaMatch ? schemaMatch[1] : null;
    if (schema)
      return [db.toUpperCase(), schema.toUpperCase(), table.toUpperCase()];
    return [db.toUpperCase(), table.toUpperCase()];
  }
  const kindNavMatches = [...mExpr.matchAll(/\[\s*Name\s*=\s*"([^"]+)"\s*,\s*Kind\s*=\s*"(Database|Schema|Table|View)"\s*\]/gi)];
  if (kindNavMatches.length) {
    let db = null, sch = null, tbl = null;
    for (const m of kindNavMatches) {
      const kind = m[2].toLowerCase();
      if (kind === "database")
        db = m[1];
      else if (kind === "schema")
        sch = m[1];
      else if (kind === "table" || kind === "view")
        tbl = m[1];
    }
    if (tbl) {
      const parts = [db, sch, tbl].filter((s) => !!s);
      if (parts.length >= 2)
        return parts.map((s) => s.toUpperCase());
    }
  }
  const nameNavMatches = [...mExpr.matchAll(/\{\s*\[Name\s*=\s*"([^"]+)"\s*\]\s*\}\s*\[\s*Data\s*\]/gi)];
  if (nameNavMatches.length >= 3) {
    return [
      nameNavMatches[0][1].toUpperCase(),
      nameNavMatches[1][1].toUpperCase(),
      nameNavMatches[2][1].toUpperCase()
    ];
  }
  if (nameNavMatches.length === 2) {
    return [nameNavMatches[0][1].toUpperCase(), nameNavMatches[1][1].toUpperCase()];
  }
  const tblMatch = mExpr.match(/FROM\s+(?:\[?(\w+)\]?\.)?\[?(\w+)\]?\.\[?(\w+)\]?/i);
  if (tblMatch) {
    return [tblMatch[1] || "", tblMatch[2], tblMatch[3]].filter(Boolean).map((s) => s.toUpperCase());
  }
  return null;
}
function daxCalendarDerivedToSql(expr) {
  const e = expr.trim();
  if (/^\[[^\]]+\]$/.test(e))
    return "d";
  let m;
  if (m = e.match(/^YEAR\s*\(\s*\[[^\]]+\]\s*\)$/i))
    return "EXTRACT(YEAR FROM d)";
  if (m = e.match(/^MONTH\s*\(\s*\[[^\]]+\]\s*\)$/i))
    return "EXTRACT(MONTH FROM d)";
  if (m = e.match(/^DAY\s*\(\s*\[[^\]]+\]\s*\)$/i))
    return "EXTRACT(DAY FROM d)";
  if (m = e.match(/^QUARTER\s*\(\s*\[[^\]]+\]\s*\)$/i))
    return "EXTRACT(QUARTER FROM d)";
  if (m = e.match(/^WEEKDAY\s*\(\s*\[[^\]]+\]/i))
    return "DAYOFWEEK(d)";
  if (m = e.match(/^FORMAT\s*\(\s*\[[^\]]+\]\s*,\s*"([^"]+)"\s*\)$/i)) {
    const fmt = m[1];
    if (/^MMMM$/.test(fmt))
      return "TO_CHAR(d, 'MMMM')";
    if (/^MMM$/.test(fmt))
      return "TO_CHAR(d, 'Mon')";
    if (/^YYYY$/.test(fmt))
      return "TO_CHAR(d, 'YYYY')";
    return "TO_CHAR(d, '" + fmt.replace(/MMMM/g, "MMMM").replace(/MMM/g, "Mon") + "')";
  }
  return null;
}
function buildCalendarSpineSql(dax, colDisplayNames) {
  const cm = dax.match(/\bCALENDAR\s*\(/i);
  if (!cm)
    return { ok: false, reason: "not a CALENDAR expression" };
  const { args } = splitCallArgs(dax, cm.index + cm[0].length);
  if (args.length < 2)
    return { ok: false, reason: "CALENDAR with non-literal bounds \u2014 recreate the date spine manually." };
  const parseDate = (a) => {
    const dm = a.match(/DATE\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)/i);
    if (!dm)
      return null;
    const [, y, mo, d] = dm;
    return `${y.padStart(4, "0")}-${mo.padStart(2, "0")}-${d.padStart(2, "0")}`;
  };
  const startStr = parseDate(args[0]);
  const endStr = parseDate(args[1]);
  if (!startStr || !endStr)
    return { ok: false, reason: "CALENDAR bounds are not literal DATE(y,m,d) \u2014 recreate the date spine manually." };
  const startMs = Date.parse(startStr + "T00:00:00Z");
  const endMs = Date.parse(endStr + "T00:00:00Z");
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs < startMs) {
    return { ok: false, reason: "CALENDAR bounds invalid \u2014 recreate the date spine manually." };
  }
  const rowCount = Math.round((endMs - startMs) / 864e5) + 1;
  const derived = [];
  const am = dax.match(/\bADDCOLUMNS\s*\(/i);
  if (am) {
    const { args: addArgs } = splitCallArgs(dax, am.index + am[0].length);
    for (let i = 1; i + 1 < addArgs.length; i += 2) {
      const name = addArgs[i].trim().replace(/^"|"$/g, "");
      derived.push({ name, expr: addArgs[i + 1].trim() });
    }
  }
  const dateColName = colDisplayNames[0] || "Date";
  const selects = [`d AS "${dateColName}"`];
  const unconverted = [];
  derived.forEach((dv, idx) => {
    const display = colDisplayNames[idx + 1] || dv.name;
    const sqlExpr = daxCalendarDerivedToSql(dv.expr);
    if (sqlExpr) {
      selects.push(`${sqlExpr} AS "${display}"`);
    } else {
      selects.push(`NULL AS "${display}"`);
      unconverted.push(display);
    }
  });
  const sql = `SELECT ${selects.join(", ")}
FROM (
  SELECT DATEADD('day', SEQ4(), CAST('${startStr}' AS DATE)) AS d
  FROM TABLE(GENERATOR(ROWCOUNT => ${rowCount}))
)`;
  if (unconverted.length) {
    return { ok: true, sql: sql + `
-- NOTE: derived column(s) ${unconverted.join(", ")} had a DAX expression that could not be auto-translated \u2014 emitted as NULL; fill in manually.` };
  }
  return { ok: true, sql };
}
function buildCalcTableSql(dax, seriesColName, colDisplayNames = []) {
  if (/\bCALENDAR\s*\(/i.test(dax)) {
    return buildCalendarSpineSql(dax, colDisplayNames);
  }
  if (/\b(TODAY|NOW)\s*\(\s*\)/i.test(dax) && !/\bGENERATESERIES|\bADDCOLUMNS/i.test(dax) && !/\[[^\]]+\]/.test(dax)) {
    const isNow = /\bNOW\s*\(\s*\)/i.test(dax);
    const col2 = seriesColName || (isNow ? "Now" : "Date");
    return { ok: true, sql: `SELECT ${isNow ? "CURRENT_TIMESTAMP" : "CURRENT_DATE"} AS "${col2}"` };
  }
  const braceList = dax.match(/\{\s*([^{}]*?)\s*\}/);
  if (braceList && braceList[1].trim() && !/\[[^\]]+\]/.test(braceList[1])) {
    const items = splitInList(braceList[1]).filter(Boolean);
    const isLiteral = (v) => /^(".*"|'.*'|-?\d+(\.\d+)?)$/.test(v.trim());
    if (items.length && items.every(isLiteral)) {
      const col2 = seriesColName || "Value";
      const rows2 = items.map((v) => {
        const tkn = v.trim();
        const sqlv = /^["']/.test(tkn) ? `'${tkn.slice(1, -1).replace(/'/g, "''")}'` : tkn;
        return `SELECT ${sqlv} AS "${col2}"`;
      }).join(" UNION ALL ");
      return { ok: true, sql: rows2 };
    }
  }
  const gm = dax.match(/\bGENERATESERIES\s*\(/i);
  if (!gm) {
    return { ok: false, reason: "DAX calculated table is not a GENERATESERIES / CALENDAR / TODAY / literal-list constructor \u2014 no warehouse source exists; recreate manually as a Sigma SQL element or input table." };
  }
  const { args } = splitCallArgs(dax, gm.index + gm[0].length);
  if (args.length < 2) {
    return { ok: false, reason: "GENERATESERIES with non-literal bounds \u2014 recreate the series manually." };
  }
  const start = Number(args[0]);
  const stop = Number(args[1]);
  const step = args.length >= 3 ? Number(args[2]) : 1;
  if (!Number.isFinite(start) || !Number.isFinite(stop) || !Number.isFinite(step) || step === 0) {
    return { ok: false, reason: "GENERATESERIES with non-literal/zero bounds \u2014 recreate the series manually." };
  }
  const vals = [];
  if (step > 0) {
    for (let v = start; v <= stop && vals.length < 1e4; v += step)
      vals.push(v);
  } else {
    for (let v = start; v >= stop && vals.length < 1e4; v += step)
      vals.push(v);
  }
  if (!vals.length)
    return { ok: false, reason: "GENERATESERIES yields an empty series \u2014 recreate manually." };
  const rows = vals.map((v) => `(${v})`).join(", ");
  const col = seriesColName || "Value";
  const sql = `SELECT v AS "${col}" FROM (VALUES ${rows}) AS t(v)`;
  return { ok: true, sql };
}
function _pbiColToSql(raw) {
  const r = (raw || "").trim();
  const m = r.match(/\[([^\]]+)\]\s*$/);
  const col = m ? m[1] : r;
  return col.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase();
}
function pbiParseSimpleAgg(dax) {
  const d = (dax || "").trim();
  let m = d.match(/^(SUM|AVERAGE|MIN|MAX|COUNT|DISTINCTCOUNT)\s*\(\s*'?[^'\[]*'?\[([^\]]+)\]\s*\)$/i);
  if (m) {
    const fnMap = { SUM: "SUM", AVERAGE: "AVG", MIN: "MIN", MAX: "MAX", COUNT: "COUNT", DISTINCTCOUNT: "COUNT_DISTINCT" };
    return { fn: fnMap[m[1].toUpperCase()], colSql: _pbiColToSql(m[2]) };
  }
  if (/^COUNTROWS\s*\(\s*'?[A-Za-z_][\w ]*'?\s*\)$/i.test(d)) {
    return { fn: "COUNT", colSql: "*" };
  }
  return null;
}
function pbiBuildMeasureAggMap(model) {
  const out = {};
  for (const t of model.tables || []) {
    for (const meas of t.measures || []) {
      const dax = Array.isArray(meas.expression) ? meas.expression.join("\n") : String(meas.expression || "");
      out[meas.name] = pbiParseSimpleAgg(dax);
    }
  }
  return out;
}
function pbiParseRankx(dax, measureAggMap) {
  const d = (dax || "").trim();
  const rm = d.match(/^RANKX\s*\(/i);
  if (!rm)
    return null;
  const { args, endPos } = splitCallArgs(d, rm.index + rm[0].length);
  if (endPos < d.length)
    return null;
  if (args.length < 2)
    return null;
  const scope = args[0].trim();
  const sm = scope.match(/^ALL\s*\(\s*'?[A-Za-z_][\w ]*'?\s*\[([^\]]+)\]\s*\)$/i);
  if (!sm)
    return null;
  const rankedDim = _pbiColToSql(sm[1]);
  const orderExpr = args[1].trim();
  let orderFn = "", orderColSql = "";
  const refM = orderExpr.match(/^\[([^\]]+)\]$/);
  if (refM) {
    const agg = measureAggMap[refM[1]];
    if (!agg)
      return null;
    orderFn = agg.fn;
    orderColSql = agg.colSql;
  } else {
    const inline = pbiParseSimpleAgg(orderExpr);
    if (!inline)
      return null;
    orderFn = inline.fn;
    orderColSql = inline.colSql;
  }
  let dir = "DESC";
  let dense = false;
  for (let i = 2; i < args.length; i++) {
    const a = args[i].trim().toUpperCase();
    if (a === "ASC" || a === "DESC")
      dir = a;
    else if (a === "DENSE")
      dense = true;
    else if (a === "SKIP")
      dense = false;
  }
  return {
    _isWindow: true,
    op: dense ? "DENSE_RANK" : "RANK",
    grainRaw: [rankedDim],
    partitionRaw: [],
    orderFn,
    orderColSql,
    orderDir: dir,
    rowLevel: false
  };
}
function pbiParseEarlierRank(dax) {
  const d = (dax || "").trim();
  const cm = d.match(/^COUNTROWS\s*\(\s*FILTER\s*\(/i);
  if (!cm)
    return null;
  const filterOpen = cm.index + cm[0].length;
  const { args: filterArgs, endPos: filterEnd } = splitCallArgs(d, filterOpen);
  if (filterArgs.length < 2)
    return null;
  let j = filterEnd;
  while (j < d.length && /\s/.test(d[j]))
    j++;
  if (d[j] !== ")")
    return null;
  const after = d.slice(j + 1).trim();
  if (!/^\+\s*1$/.test(after))
    return null;
  const pred = filterArgs.slice(1).join(", ");
  const cmp = pred.match(/(['"]?[\w ]*'?\[[^\]]+\]|\[[^\]]+\])\s*(>|<)\s*EARLIER\s*\(\s*([^)]+?)\s*\)/i);
  if (!cmp)
    return null;
  const orderColSql = _pbiColToSql(cmp[1]);
  const dir = cmp[2] === ">" ? "DESC" : "ASC";
  const partitionRaw = [];
  for (const term of pred.split(/&&/)) {
    const pm = term.match(/(['"]?[\w ]*'?\[[^\]]+\]|\[[^\]]+\])\s*=\s*EARLIER\s*\(\s*[^)]+?\s*\)/i);
    if (pm)
      partitionRaw.push(_pbiColToSql(pm[1]));
  }
  return {
    _isWindow: true,
    op: "DENSE_RANK",
    // the idiom counts strictly-greater rows + 1 = dense rank
    grainRaw: [],
    // row level — no GROUP BY
    partitionRaw,
    orderFn: "",
    orderColSql,
    orderDir: dir,
    rowLevel: true
  };
}
function _parseEarlierTerms(pred) {
  const partition = [];
  let orderCol = null;
  let orderDir = "ASC";
  for (const termRaw of pred.split(/&&/)) {
    const t = termRaw.trim();
    if (!t)
      continue;
    const eq = t.match(/^(['"]?[\w ]*'?\[[^\]]+\]|\[[^\]]+\])\s*=\s*EARLIER\s*\(\s*[^)]+?\s*\)$/i);
    if (eq) {
      partition.push(_pbiColToSql(eq[1]));
      continue;
    }
    const cmp = t.match(/^(['"]?[\w ]*'?\[[^\]]+\]|\[[^\]]+\])\s*(<=|>=)\s*EARLIER\s*\(\s*[^)]+?\s*\)$/i);
    if (cmp && !orderCol) {
      orderCol = _pbiColToSql(cmp[1]);
      orderDir = cmp[2] === "<=" ? "ASC" : "DESC";
      continue;
    }
    return null;
  }
  return { partition, orderCol, orderDir };
}
function _earlierScopeOk(scope) {
  const s = scope.trim();
  return /^'?[A-Za-z_][\w ]*'?$/.test(s) || /^ALL\s*\(\s*'?[A-Za-z_][\w ]*'?\s*\)$/i.test(s);
}
function pbiParseEarlierWindow(dax) {
  const d = (dax || "").trim();
  if (!/\bEARLIER\s*\(/i.test(d))
    return null;
  const AGG_MAP = { SUM: "SUM", AVERAGE: "AVG", MIN: "MIN", MAX: "MAX" };
  const build = (fn, valueColSql, filterExpr) => {
    const fm = filterExpr.trim().match(/^FILTER\s*\(/i);
    if (!fm)
      return null;
    const fr = splitCallArgs(filterExpr.trim(), fm[0].length);
    if (fr.args.length < 2 || fr.endPos !== filterExpr.trim().length)
      return null;
    if (!_earlierScopeOk(fr.args[0]))
      return null;
    const terms = _parseEarlierTerms(fr.args.slice(1).join(", "));
    if (!terms)
      return null;
    if (!terms.orderCol && !terms.partition.length)
      return null;
    return {
      _isWindow: true,
      op: terms.orderCol ? "AGG_RUNNING" : "AGG_PARTITION",
      grainRaw: [],
      partitionRaw: terms.partition,
      orderFn: "",
      orderColSql: terms.orderCol || "",
      orderDir: terms.orderDir,
      rowLevel: true,
      valueFn: fn,
      valueColSql
    };
  };
  let m = d.match(/^CALCULATE\s*\(/i);
  if (m) {
    const { args, endPos } = splitCallArgs(d, m[0].length);
    if (endPos !== d.length || args.length !== 2)
      return null;
    const am = args[0].trim().match(/^(SUM|AVERAGE|MIN|MAX)\s*\(\s*('?[^'\[]*'?\[[^\]]+\])\s*\)$/i);
    if (!am)
      return null;
    return build(AGG_MAP[am[1].toUpperCase()], _pbiColToSql(am[2]), args[1]);
  }
  m = d.match(/^(SUMX|AVERAGEX|MINX|MAXX)\s*\(/i);
  if (m) {
    const { args, endPos } = splitCallArgs(d, m[0].length);
    if (endPos !== d.length || args.length !== 2)
      return null;
    const body = args[1].trim();
    const bm = body.match(/^('?[^'\[]*'?\[[^\]]+\])$/);
    if (!bm)
      return null;
    const fnMap = { SUMX: "SUM", AVERAGEX: "AVG", MINX: "MIN", MAXX: "MAX" };
    return build(fnMap[m[1].toUpperCase()], _pbiColToSql(bm[1]), args[0]);
  }
  m = d.match(/^COUNTROWS\s*\(/i);
  if (m) {
    const { args, endPos } = splitCallArgs(d, m[0].length);
    if (endPos !== d.length || args.length !== 1)
      return null;
    return build("COUNT", "*", args[0]);
  }
  return null;
}
function _pbiWindowAlias(name, used) {
  let b = (name || "WIN_VAL").toUpperCase().replace(/[^A-Z0-9_]+/g, "_").replace(/^_+|_+$/g, "").replace(/_+/g, "_");
  if (!b)
    b = "WIN_VAL";
  let a = b, n = 2;
  while (used.has(a))
    a = `${b}_${n++}`;
  used.add(a);
  return a;
}
function pbiRegisterInnerAgg(helper, fn, colSql) {
  const key = `${fn}::${colSql}`;
  if (helper.innerAggs[key])
    return helper.innerAggs[key].alias;
  const base = colSql === "*" ? "CNT" : colSql.replace(/[^A-Z0-9_]/gi, "_").toUpperCase();
  let alias = base || "VAL", n = 2;
  while (helper.windowAliases.has(alias) || Object.values(helper.innerAggs).some((v) => v.alias === alias)) {
    alias = `${base}_${n++}`;
  }
  helper.innerAggs[key] = { alias };
  return alias;
}
function pbiResolveBaseFrom(srcEl) {
  const src = srcEl.source || {};
  if (src.kind === "warehouse-table" && Array.isArray(src.path) && src.path.length) {
    return src.path.join(".");
  }
  if (src.kind === "sql" && typeof src.statement === "string" && src.statement.trim() && !src.statement.includes("_placeholder") && !/^--/.test(src.statement.trim())) {
    return `(${src.statement.trim().replace(/;\s*$/, "")})`;
  }
  return null;
}
function pbiKnownRawColumns(srcEl) {
  const out = /* @__PURE__ */ new Set();
  for (const c of srcEl.columns || []) {
    const fm = (c.formula || "").match(/^\[[^\]\/]+\/([^\]]+)\]$/);
    if (fm)
      out.add(_pbiColToSql(fm[1]));
  }
  return out;
}
function lowerPBIWindowCalc(win, calcName, srcEl, winCtx, warnings) {
  const baseFromSql = pbiResolveBaseFrom(srcEl);
  if (!baseFromSql) {
    warnings.push(`\u26A0 "${calcName}" (${win.op}): could not resolve a warehouse FROM source for "${srcEl.name}"; degraded to Null.`);
    return false;
  }
  const known = pbiKnownRawColumns(srcEl);
  const checkCol = (c) => c === "*" || known.size === 0 || known.has(c);
  for (const p of win.partitionRaw) {
    if (!checkCol(p)) {
      warnings.push(`\u26A0 "${calcName}" (${win.op}): partition column ${p} not found on "${srcEl.name}"; degraded to Null.`);
      return false;
    }
  }
  for (const g of win.grainRaw) {
    if (!checkCol(g)) {
      warnings.push(`\u26A0 "${calcName}" (${win.op}): rank dimension ${g} not found on "${srcEl.name}"; degraded to Null.`);
      return false;
    }
  }
  if (win.orderColSql && !checkCol(win.orderColSql)) {
    warnings.push(`\u26A0 "${calcName}" (${win.op}): order column ${win.orderColSql} not found on "${srcEl.name}"; degraded to Null.`);
    return false;
  }
  if (win.valueColSql && win.valueColSql !== "*" && !checkCol(win.valueColSql)) {
    warnings.push(`\u26A0 "${calcName}" (${win.op}): value column ${win.valueColSql} not found on "${srcEl.name}"; degraded to Null.`);
    return false;
  }
  const grainKey = win.grainRaw.slice().sort().join(",");
  const partKey = win.partitionRaw.slice().sort().join(",");
  const key = `${baseFromSql}||${win.rowLevel ? "ROW" : "AGG"}||${grainKey}||${partKey}`;
  const passthrough = win.rowLevel ? [.../* @__PURE__ */ new Set([
    ...win.partitionRaw,
    ...win.orderColSql ? [win.orderColSql] : [],
    ...win.valueColSql && win.valueColSql !== "*" ? [win.valueColSql] : []
  ])] : win.grainRaw;
  const OP_LABEL = {
    DENSE_RANK: "Dense Rank",
    RANK: "Rank",
    AGG_RUNNING: "Running",
    AGG_PARTITION: "Group"
  };
  let helper = winCtx.helpers.get(key);
  if (!helper) {
    const cols = [];
    const order = [];
    for (const g of passthrough) {
      if (g === "*")
        continue;
      const id = sigmaShortId();
      cols.push({ id, name: sigmaDisplayName(g), formula: `[Custom SQL/${g}]` });
      order.push(id);
    }
    const el = {
      id: sigmaShortId(),
      kind: "table",
      name: `${OP_LABEL[win.op] || "Window"} ${win.partitionRaw[0] || win.grainRaw[0] || win.orderColSql || "Window"}`,
      source: { connectionId: winCtx.connectionId, kind: "sql", statement: "__PBI_WINDOW_PLACEHOLDER__" },
      columns: cols,
      order
    };
    helper = {
      element: el,
      grainRaw: win.grainRaw,
      partitionRaw: win.partitionRaw,
      rowLevel: win.rowLevel,
      innerAggs: {},
      windowAliases: /* @__PURE__ */ new Set(),
      overParts: [],
      baseFromSql,
      rowCols: new Set(passthrough.filter((c) => c !== "*"))
    };
    winCtx.helpers.set(key, helper);
    winCtx.extraElements.push(el);
  } else if (win.rowLevel) {
    for (const g of passthrough) {
      if (g === "*" || helper.rowCols.has(g))
        continue;
      helper.rowCols.add(g);
      const id = sigmaShortId();
      helper.element.columns.push({ id, name: sigmaDisplayName(g), formula: `[Custom SQL/${g}]` });
      helper.element.order.push(id);
    }
  }
  const partBy = win.partitionRaw.length ? `PARTITION BY ${win.partitionRaw.join(", ")}` : "";
  let overSql;
  if (win.op === "AGG_RUNNING" || win.op === "AGG_PARTITION") {
    const valExpr = win.valueColSql === "*" ? "COUNT(*)" : `${win.valueFn}(${win.valueColSql})`;
    const overBody = win.op === "AGG_RUNNING" ? [partBy, `ORDER BY ${win.orderColSql} ${win.orderDir}`].filter(Boolean).join(" ") : partBy;
    overSql = `${valExpr} OVER (${overBody})`;
  } else {
    const fn = win.op === "DENSE_RANK" ? "DENSE_RANK" : "RANK";
    let orderExprSql;
    if (win.rowLevel) {
      orderExprSql = win.orderColSql;
    } else {
      orderExprSql = pbiRegisterInnerAgg(helper, win.orderFn, win.orderColSql);
    }
    overSql = `${fn}() OVER (${[partBy, `ORDER BY ${orderExprSql} ${win.orderDir}`].filter(Boolean).join(" ")})`;
  }
  const winAlias = _pbiWindowAlias(calcName, winCtx.usedAliases);
  helper.overParts.push(`${overSql} AS ${winAlias}`);
  helper.windowAliases.add(winAlias);
  const calcId = sigmaShortId();
  helper.element.columns.push({ id: calcId, name: stripParens(sigmaDisplayName(calcName)), formula: `[Custom SQL/${winAlias}]` });
  helper.element.order.push(calcId);
  warnings.push(`\u2705 "${calcName}" (${win.op}) \u2192 SQL window helper "${helper.element.name}" alias ${winAlias} (${win.rowLevel ? "row-level" : "grouped by " + win.grainRaw.join(", ")}${win.partitionRaw.length ? ", partition " + win.partitionRaw.join(", ") : ""}${win.op === "AGG_RUNNING" ? ", ordered by " + win.orderColSql + " " + win.orderDir : ""}).`);
  return true;
}
function finalizePBIWindowHelper(helper) {
  if (helper.rowLevel) {
    const proj = [...helper.rowCols, ...helper.overParts];
    helper.element.source.statement = `SELECT ${proj.join(", ")} FROM ${helper.baseFromSql}`;
    return;
  }
  const groupCols = [];
  const seen = /* @__PURE__ */ new Set();
  for (const g of helper.grainRaw) {
    if (g === "*" || seen.has(g))
      continue;
    seen.add(g);
    groupCols.push(g);
  }
  const selectParts = [...groupCols];
  for (const k of Object.keys(helper.innerAggs)) {
    const [fn, colSql] = k.split("::");
    const a = helper.innerAggs[k];
    const sqlFn = fn === "COUNT_DISTINCT" ? `COUNT(DISTINCT ${colSql})` : colSql === "*" ? "COUNT(*)" : `${fn}(${colSql})`;
    selectParts.push(`${sqlFn} AS ${a.alias}`);
  }
  const groupBy = groupCols.length ? ` GROUP BY ${groupCols.map((_, i) => i + 1).join(", ")}` : "";
  const baseSelect = `SELECT ${selectParts.join(", ")} FROM ${helper.baseFromSql}${groupBy}`;
  const innerProj = [...groupCols, ...Object.values(helper.innerAggs).map((v) => v.alias)];
  const outerProj = innerProj.concat(helper.overParts);
  helper.element.source.statement = `WITH base AS (${baseSelect}) SELECT ${outerProj.join(", ")} FROM base`;
}
function _pbiParseQualifiedRef(s) {
  const m = (s || "").trim().match(/^'([^']+)'\s*\[([^\]]+)\]$|^([A-Za-z_][\w ]*?)\s*\[([^\]]+)\]$/);
  if (!m)
    return null;
  return { table: (m[1] || m[3]).trim(), column: (m[2] || m[4]).trim() };
}
function extractUseRelationships(dax) {
  let f = dax;
  const pairs = [];
  const re = /\bUSERELATIONSHIP\s*\(/gi;
  for (let guard = 0; guard < 20; guard++) {
    re.lastIndex = 0;
    const m = re.exec(f);
    if (!m)
      break;
    const { args, endPos } = splitCallArgs(f, m.index + m[0].length);
    if (args.length >= 2) {
      const a = _pbiParseQualifiedRef(args[0]);
      const b = _pbiParseQualifiedRef(args[1]);
      if (a && b)
        pairs.push({ a, b });
    }
    let start = m.index, end = endPos;
    let i = start - 1;
    while (i >= 0 && /\s/.test(f[i]))
      i--;
    if (f[i] === ",")
      start = i;
    else {
      let j = end;
      while (j < f.length && /\s/.test(f[j]))
        j++;
      if (f[j] === ",")
        end = j + 1;
    }
    f = f.slice(0, start) + f.slice(end);
  }
  return { dax: f, pairs };
}
function findModelRelationship(model, p) {
  for (const r of model.relationships || []) {
    const fwd = r.fromTable === p.a.table && r.fromColumn === p.a.column && r.toTable === p.b.table && r.toColumn === p.b.column;
    const rev = r.fromTable === p.b.table && r.fromColumn === p.b.column && r.toTable === p.a.table && r.toColumn === p.a.column;
    if (fwd || rev)
      return r;
  }
  return null;
}
function stripParens(name) {
  return (name || "").replace(/\s*\([^)]*\)/g, "").replace(/[()]/g, "").replace(/\s+/g, " ").trim();
}
function classifyTimeIntel(dax) {
  const d = dax || "";
  if (/\bTOTALYTD\s*\(|\bDATESYTD\s*\(/i.test(d))
    return "ytd";
  if (/FILTER\s*\(\s*ALL\s*\([^)]*\)\s*,[^<]*<=\s*MAX\s*\(/i.test(d))
    return "ytd";
  if (/\bSAMEPERIODLASTYEAR\s*\(/i.test(d))
    return "prior";
  if (/\bDATEADD\s*\([^,]+,\s*-?\d+\s*,\s*(YEAR|QUARTER|MONTH|WEEK|DAY)/i.test(d))
    return "prior";
  if (/SELECTEDVALUE\s*\([^)]*\[Year\]/i.test(d) && /ALL\s*\([^)]*\[Year\]/i.test(d) && /-\s*1\b/.test(d))
    return "prior";
  return null;
}
function viewColDisplay(formula) {
  const p = (formula || "").replace(/^\[|\]$/g, "").split("/");
  return p.length <= 2 ? p[p.length - 1] : `${p[p.length - 1]} (${p[p.length - 2]})`;
}
function emitTimeIntelElements(model, elements, warnings) {
  const AGG = {
    SUM: "Sum",
    AVERAGE: "Avg",
    AVG: "Avg",
    MIN: "Min",
    MAX: "Max",
    COUNT: "Count",
    COUNTA: "Count",
    DISTINCTCOUNT: "CountDistinct"
  };
  const views = elements.filter((e) => e.name && /View$/.test(e.name) && e.source?.kind === "table");
  if (!views.length)
    return;
  const lastSeg = (f) => (f || "").replace(/^\[|\]$/g, "").split("/").pop() || "";
  for (const t of model.tables || []) {
    for (const m of t.measures || []) {
      const dax = Array.isArray(m.expression) ? m.expression.join(" ") : String(m.expression || "");
      const shape = classifyTimeIntel(dax);
      if (!shape)
        continue;
      const am = dax.match(/\b(SUM|AVERAGE|AVG|MIN|MAX|COUNT|DISTINCTCOUNT)\s*\(\s*'?[^'\[]*'?\[([^\]]+)\]/i);
      if (!am)
        continue;
      const agg = AGG[am[1].toUpperCase()];
      const col = am[2];
      const normCol = (s) => (s || "").toUpperCase().replace(/[\s_]/g, "");
      let parent = null, valDisp = "", dateDisp = "";
      for (const v of views) {
        const vc = (v.columns || []).find((c) => normCol(lastSeg(c.formula)) === normCol(col));
        const dc = (v.columns || []).find((c) => /full date/i.test(viewColDisplay(c.formula))) || (v.columns || []).find((c) => /date/i.test(lastSeg(c.formula)) && !/key/i.test(lastSeg(c.formula)));
        if (vc && dc) {
          parent = v;
          valDisp = viewColDisplay(vc.formula);
          dateDisp = viewColDisplay(dc.formula);
          break;
        }
      }
      if (!parent)
        continue;
      const pn = parent.name;
      const b = (m.name || "TI").replace(/[^a-zA-Z0-9]/g, "").slice(0, 14);
      const refTables = [...dax.matchAll(/([A-Za-z_]\w*)\s*\[/g)].map((x) => x[1]);
      const dimTable = refTables.length ? refTables[refTables.length - 1] : null;
      if (dimTable && dimTable !== t.name) {
        const rel = (model.relationships || []).find((r) => r.fromTable === t.name && r.toTable === dimTable);
        if (rel && rel.isActive === false) {
          warnings.push(`\u26A0 "${m.name}": the ${t.name}\u2192${dimTable} relationship is INACTIVE and no measure activates it (USERELATIONSHIP), so the original Power BI measure does not filter by ${dimTable} \u2014 it returns an unfiltered total per ${dimTable} period. The synthesized element groups by ${t.name}'s own date instead, yielding a true per-period prior-year. Confirm this matches intent (the source measure may be silently mis-modeled).`);
        }
      }
      if (shape === "prior") {
        const prior = `${valDisp} (Prior Year)`;
        const cols = [
          { id: `${b}_d`, formula: `DateTrunc("year", [${pn}/${dateDisp}])`, name: "Year" },
          { id: `${b}_v`, formula: `${agg}([${pn}/${valDisp}])`, name: valDisp },
          { id: `${b}_p`, formula: `DateLookback([${valDisp}], [Year], 1, "year")`, name: prior },
          { id: `${b}_y`, formula: `([${valDisp}] - [${prior}]) / [${prior}]`, name: `${valDisp} YoY %`, format: { kind: "number", formatString: ",.1%" } }
        ];
        elements.push({
          id: `${b}PP`,
          kind: "table",
          name: m.name,
          source: { kind: "table", elementId: parent.id },
          columns: cols,
          order: cols.map((c) => c.id),
          groupings: [{ id: `${b}_g`, groupBy: [`${b}_d`], calculations: [`${b}_v`, `${b}_p`, `${b}_y`] }]
        });
        warnings.push(`\u2139 Time-intel measure "${m.name}" \u2192 grouped DateLookback element on "${pn}" (prior-year + YoY %).`);
      } else {
        const cols = [
          { id: `${b}_o`, formula: `DateTrunc("year", [${pn}/${dateDisp}])`, name: "Year" },
          { id: `${b}_i`, formula: `DateTrunc("month", [${pn}/${dateDisp}])`, name: "Month" },
          { id: `${b}_v`, formula: `${agg}([${pn}/${valDisp}])`, name: valDisp },
          { id: `${b}_c`, formula: `CumulativeSum([${valDisp}])`, name: `${valDisp} YTD` }
        ];
        elements.push({
          id: `${b}YT`,
          kind: "table",
          name: m.name,
          source: { kind: "table", elementId: parent.id },
          columns: cols,
          order: cols.map((c) => c.id),
          groupings: [
            { id: `${b}_go`, groupBy: [`${b}_o`] },
            { id: `${b}_gi`, groupBy: [`${b}_i`], calculations: [`${b}_v`, `${b}_c`] }
          ]
        });
        warnings.push(`\u2139 Time-intel measure "${m.name}" \u2192 grouped CumulativeSum (YTD, year-reset) element on "${pn}".`);
      }
    }
  }
}
function convertPowerBIToSigma(modelJson, options = {}) {
  resetIds();
  const { connectionId = "", database = "", schema = "" } = options;
  const model = modelJson.model || modelJson;
  if (!model.tables || !Array.isArray(model.tables)) {
    throw new Error('Invalid model \u2014 no "tables" array found');
  }
  const whLower = /\b(databricks|spark|hive|delta)\b/i.test(options.warehouseType || "");
  const physCasing = whLower ? "lower" : "upper";
  const physCase = (s) => whLower ? String(s).toLowerCase() : String(s).toUpperCase();
  const dbOverride = physCase(database || "");
  const schOverride = physCase(schema || "");
  const warnings = [];
  const security = [];
  const elements = [];
  const tableIdMap = {};
  const tableColMap = {};
  const allPbiToSigmaNames = {};
  const measureToElementId = {};
  const measureAggMap = pbiBuildMeasureAggMap(model);
  const measureDaxMap = {};
  for (const t of model.tables || []) {
    for (const meas of t.measures || []) {
      measureDaxMap[meas.name] = Array.isArray(meas.expression) ? meas.expression.join("\n") : String(meas.expression || "");
    }
  }
  const winCtx = {
    helpers: /* @__PURE__ */ new Map(),
    usedAliases: /* @__PURE__ */ new Set(),
    extraElements: [],
    connectionId: connectionId || "<CONNECTION_ID>"
  };
  const relActivationNames = /* @__PURE__ */ new Map();
  const measureAltPath = {};
  const processUseRelationships = (measureName, expr) => {
    if (!/\bUSERELATIONSHIP\s*\(/i.test(expr))
      return expr;
    const ur = extractUseRelationships(expr);
    for (const pair of ur.pairs) {
      const rel = findModelRelationship(model, pair);
      if (!rel) {
        warnings.push(`\u26A0 "${measureName}": USERELATIONSHIP(${pair.a.table}[${pair.a.column}], ${pair.b.table}[${pair.b.column}]) has no matching model relationship \u2014 filter ignored; verify the grouping path manually.`);
        continue;
      }
      if (rel.isActive === false) {
        let altName = relActivationNames.get(rel);
        if (!altName) {
          altName = `${String(rel.toTable).toUpperCase()}_VIA_${String(rel.fromColumn).toUpperCase()}`.replace(/[^A-Z0-9_]+/g, "_");
          relActivationNames.set(rel, altName);
        }
        measureAltPath[measureName] = altName;
        warnings.push(`\u2705 "${measureName}": CALCULATE over INACTIVE relationship ${rel.fromTable}[${rel.fromColumn}] \u2192 ${rel.toTable}[${rel.toColumn}] \u2014 activated as alternate join path "${altName}". The aggregate itself is unchanged; to reproduce the USERELATIONSHIP grouping, group by the "(${altName})" columns on the derived "${rel.fromTable} View" element (the active-path columns remain "(${rel.toTable})").`);
      } else {
        warnings.push(`\u2139 "${measureName}": USERELATIONSHIP over an already-ACTIVE relationship (${rel.fromTable}[${rel.fromColumn}] \u2192 ${rel.toTable}[${rel.toColumn}]) \u2014 no-op, stripped.`);
      }
    }
    return ur.dax;
  };
  const measureOnlyTables = /* @__PURE__ */ new Set();
  const calcGroupTables = /* @__PURE__ */ new Set();
  for (const t of model.tables) {
    if (t.calculationGroup) {
      calcGroupTables.add(t.name);
      continue;
    }
    const dataCols = (t.columns || []).filter((c) => c.type !== "rowNumber" && !c.isGenerated);
    if (dataCols.length === 0 && (t.measures || []).length > 0) {
      measureOnlyTables.add(t.name);
    }
  }
  for (const t of model.tables) {
    if (calcGroupTables.has(t.name))
      continue;
    if (t.name.startsWith("LocalDateTable_") || t.name.startsWith("DateTableTemplate_"))
      continue;
    for (const c of t.columns || []) {
      if (c.type === "rowNumber" || c.isGenerated)
        continue;
      const sourceCol = c.sourceColumn || c.name;
      if (!sourceCol)
        continue;
      if (!(c.name in allPbiToSigmaNames)) {
        allPbiToSigmaNames[c.name] = sigmaDisplayName(sourceCol);
      }
    }
  }
  const _schemasSeen = /* @__PURE__ */ new Set();
  const _catalogsSeen = /* @__PURE__ */ new Set();
  for (const t of model.tables) {
    if (measureOnlyTables.has(t.name) || calcGroupTables.has(t.name))
      continue;
    if (t.name.startsWith("LocalDateTable_") || t.name.startsWith("DateTableTemplate_"))
      continue;
    const _expr = (t.partitions || [])[0]?.source?.expression;
    const _mp = _expr ? pbiExtractPathFromM(Array.isArray(_expr) ? _expr.join("\n") : String(_expr)) : null;
    if (_mp && _mp.length >= 3) {
      _catalogsSeen.add(_mp[0]);
      _schemasSeen.add(_mp[1]);
    }
  }
  const modelMultiSchema = _schemasSeen.size > 1;
  const modelMultiCatalog = _catalogsSeen.size > 1;
  for (const t of model.tables) {
    if (measureOnlyTables.has(t.name))
      continue;
    if (calcGroupTables.has(t.name))
      continue;
    if (t.name.startsWith("LocalDateTable_") || t.name.startsWith("DateTableTemplate_"))
      continue;
    const elementId = sigmaShortId();
    const tableName = t.name;
    tableIdMap[tableName] = elementId;
    tableColMap[tableName] = {};
    const partition = (t.partitions || [])[0];
    if (partition?.source?.type === "calculated") {
      const ctExpr = Array.isArray(partition.source.expression) ? partition.source.expression.join("\n") : partition.source.expression || "";
      const ctCols = (t.columns || []).filter((c) => c.type !== "rowNumber" && !c.isGenerated);
      const ctColDisplayNames = ctCols.map((c) => sigmaDisplayName((c.sourceColumn || c.name || "").replace(/^\[|\]$/g, "")));
      const firstColName = ctColDisplayNames.length ? ctColDisplayNames[0] : "Value";
      const built = buildCalcTableSql(ctExpr, firstColName, ctColDisplayNames);
      let statement;
      if (built.ok) {
        statement = built.sql;
        if (/\bCALENDAR\s*\(/i.test(ctExpr)) {
          warnings.push(`\u2139 Calculated table "${tableName}": DAX CALENDAR/ADDCOLUMNS \u2192 synthesized a Sigma SQL date-spine element (GENERATOR + DATEADD) with the derived columns translated to SQL.`);
        } else if (ctCols.length > 1) {
          warnings.push(`\u2139 Calculated table "${tableName}": synthesized a SQL VALUES series for column "${firstColName}". The remaining derived column(s) (${ctCols.slice(1).map((c) => sigmaDisplayName(c.sourceColumn || c.name)).join(", ")}) come from DAX ADDCOLUMNS/SELECTCOLUMNS \u2014 add their expressions to the SQL or as Sigma calc columns.`);
        } else {
          warnings.push(`\u2139 Calculated table "${tableName}": DAX GENERATESERIES \u2192 synthesized Sigma SQL element (VALUES list).`);
        }
      } else {
        statement = `-- TODO (beads-sigma-w9s): ${built.reason}
-- Original DAX: ${ctExpr.replace(/\n/g, " ").slice(0, 300)}
SELECT 1 AS _placeholder`;
        warnings.push(`\u26D4 Calculated table "${tableName}": ${built.reason} Emitted a placeholder SQL element (NOT a warehouse-table). Original DAX preserved as a comment.`);
      }
      const ctColumns = [];
      const ctOrder = [];
      const droppedCols = [];
      for (const c of ctCols) {
        const sourceCol = (c.sourceColumn || c.name || "").replace(/^\[|\]$/g, "");
        const displayName = sigmaDisplayName(sourceCol);
        const aliasEmitted = built.ok && new RegExp(`AS\\s+"${displayName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"`, "i").test(statement);
        if (built.ok && !aliasEmitted) {
          droppedCols.push(displayName);
          continue;
        }
        const colId = sigmaInodeId(sigmaPhysicalName(sourceCol || c.name));
        tableColMap[tableName][c.name] = colId;
        allPbiToSigmaNames[c.name] = displayName;
        const col = { id: colId, formula: `[Custom SQL/${displayName}]` };
        if (c.isHidden)
          col.hidden = true;
        if (c.description)
          col.description = c.description;
        ctColumns.push(col);
        ctOrder.push(colId);
      }
      if (droppedCols.length) {
        warnings.push(`\u26A0 Calculated table "${tableName}": dropped column(s) ${droppedCols.join(", ")} \u2014 their DAX (ADDCOLUMNS/SELECTCOLUMNS) expression wasn't translated into the synthesized SQL, so they have no warehouse source. Add them to the SQL statement manually or as Sigma calc columns.`);
      }
      const ctElement = {
        id: elementId,
        kind: "table",
        source: { connectionId: connectionId || "<CONNECTION_ID>", kind: "sql", statement },
        columns: ctColumns,
        order: ctOrder
      };
      if (!built.ok)
        ctElement.ok = false;
      if (t.isHidden)
        ctElement.visibleAsSource = false;
      elements.push(ctElement);
      continue;
    }
    let path = null;
    if (partition?.source) {
      if (partition.source.expression) {
        path = pbiExtractPathFromM(Array.isArray(partition.source.expression) ? partition.source.expression.join("\n") : partition.source.expression);
      }
      if (!path && partition.source.query) {
        const tblMatch = partition.source.query.match(/FROM\s+(?:\[?(\w+)\]?\.)?\[?(\w+)\]?\.\[?(\w+)\]?/i);
        if (tblMatch) {
          path = [tblMatch[1] || "", tblMatch[2], tblMatch[3]].filter(Boolean).map((s) => s.toUpperCase());
        }
      }
    }
    if (path) {
      if (path.length >= 3) {
        if (dbOverride && !modelMultiCatalog)
          path[0] = dbOverride;
        if (schOverride && !modelMultiSchema)
          path[1] = schOverride;
      } else if (schOverride && path.length === 2) {
        path[0] = schOverride;
      }
    } else {
      path = [dbOverride || physCase("DATABASE"), schOverride || physCase("SCHEMA"), physCase(tableName)];
      warnings.push(`\u26A0 Table "${tableName}": could not extract source path from M expression \u2014 using default.`);
    }
    const physPath = whLower && path ? path.map((s) => String(s).toLowerCase()) : path;
    const columns = [];
    const order = [];
    const pbiToSigmaName = {};
    for (const c of t.columns || []) {
      if (c.type === "rowNumber" || c.isGenerated)
        continue;
      if (c.type === "calculated")
        continue;
      if (c.dataType === "binary") {
        warnings.push(`\u26A0 Table "${tableName}": binary column "${c.name}" skipped \u2014 no warehouse/Sigma representation (embedded asset).`);
        continue;
      }
      const sourceCol = c.sourceColumn || c.name;
      const displayName = sigmaDisplayName(sourceCol);
      const colId = sigmaInodeId(sigmaPhysicalName(sourceCol, physCasing), physCasing);
      tableColMap[tableName][c.name] = colId;
      pbiToSigmaName[c.name] = displayName;
      allPbiToSigmaNames[c.name] = displayName;
      const col = { id: colId, formula: `[${tableName.toUpperCase()}/${displayName}]` };
      if (c.isHidden)
        col.hidden = true;
      if (c.description)
        col.description = c.description;
      columns.push(col);
      order.push(colId);
    }
    const srcElProxy = {
      id: elementId,
      kind: "table",
      name: path && path.length ? path[path.length - 1] : tableName.toUpperCase(),
      source: { connectionId: connectionId || "<CONNECTION_ID>", kind: "warehouse-table", path: physPath },
      columns,
      order
    };
    for (const c of t.columns || []) {
      if (c.type !== "calculated")
        continue;
      const cExpr = Array.isArray(c.expression) ? c.expression.join("\n") : String(c.expression || "");
      const cWin = pbiParseEarlierRank(cExpr) || pbiParseEarlierWindow(cExpr);
      if (cWin && lowerPBIWindowCalc(cWin, c.name, srcElProxy, winCtx, warnings)) {
        tableColMap[tableName][c.name] = sigmaShortId();
        pbiToSigmaName[c.name] = c.name;
        continue;
      }
      let sigmaFormula = pbiDaxToSigma(c.expression, warnings, c.name, measureDaxMap);
      if (sigmaFormula && hasBareWindowFn(sigmaFormula)) {
        warnings.push(`\u26D4 "${c.name}": window-function calc column (${sigmaFormula.slice(0, 48)}\u2026) cannot live in a base-table calc column (errors in Sigma) \u2014 express it as a workbook Rank() in an ordered table or a grouped element. Dropped.`);
        sigmaFormula = null;
      }
      if (sigmaFormula) {
        sigmaFormula = sigmaFormula.replace(/\[([^\]\/]+)\]/g, (_m, colName) => {
          if (pbiToSigmaName[colName])
            return `[${pbiToSigmaName[colName]}]`;
          if (allPbiToSigmaNames[colName])
            return `[${allPbiToSigmaNames[colName]}]`;
          return `[${colName}]`;
        });
        const colId = sigmaShortId();
        tableColMap[tableName][c.name] = colId;
        pbiToSigmaName[c.name] = c.name;
        if (["int64", "double", "decimal"].includes(String(c.dataType)) && /&|^\s*(Text|Concat|Format)\s*\(/i.test(sigmaFormula)) {
          sigmaFormula = `Number(${sigmaFormula})`;
        }
        const _calcFmt = inferSigmaFormat(sigmaFormula, c.name, c.formatString);
        const _calcCol = { id: colId, formula: sigmaFormula, name: c.name };
        if (_calcFmt)
          _calcCol.format = _calcFmt;
        columns.push(_calcCol);
        order.push(colId);
        warnings.push(`\u2139 "${c.name}" \u2192 calculated column. Review: ${sigmaFormula.slice(0, 60)}`);
      } else if (!warnings.some((w) => w.includes(c.name))) {
        warnings.push(`\u26D4 "${c.name}": DAX expression could not be converted. Add manually.`);
      }
    }
    const metrics = [];
    for (const m of t.measures || []) {
      if (m.name)
        measureToElementId[m.name] = elementId;
      const mExprRaw = Array.isArray(m.expression) ? m.expression.join("\n") : String(m.expression || "");
      const mExpr = processUseRelationships(m.name, mExprRaw);
      const mWin = pbiParseRankx(mExpr, measureAggMap);
      if (mWin && lowerPBIWindowCalc(mWin, m.name, srcElProxy, winCtx, warnings)) {
        continue;
      }
      let sigmaFormula = pbiDaxToSigma(mExpr, warnings, m.name, measureDaxMap);
      if (sigmaFormula && hasBareWindowFn(sigmaFormula)) {
        warnings.push(`\u26D4 "${m.name}": window-function measure has no Sigma DM-metric equivalent \u2014 use a workbook Rank()/ordered table or a grouped element. Dropped.`);
        sigmaFormula = null;
      }
      if (sigmaFormula) {
        sigmaFormula = sigmaFormula.replace(/\[([^\]\/]+)\]/g, (_m2, colName) => {
          return pbiToSigmaName[colName] ? `[${pbiToSigmaName[colName]}]` : `[${colName}]`;
        });
        const _mFmt = inferSigmaFormat(sigmaFormula, m.name, m.formatString);
        const metric = { id: sigmaShortId(), formula: sigmaFormula, name: m.name };
        if (_mFmt)
          metric.format = _mFmt;
        if (m.description)
          metric.description = m.description;
        metrics.push(metric);
      } else if (!warnings.some((w) => w.includes(`"${m.name}"`))) {
        warnings.push(`\u26D4 "${m.name}": DAX measure could not be auto-converted. Add manually.`);
      }
    }
    {
      const emitted = new Set(metrics.map((mm) => mm.name));
      const dropped = new Set((t.measures || []).map((mm) => mm.name).filter((nm) => nm && !emitted.has(nm)));
      pruneDanglingMetrics(metrics, dropped, warnings);
    }
    {
      const colDisplays = /* @__PURE__ */ new Set([
        ...Object.values(pbiToSigmaName),
        ...Object.keys(pbiToSigmaName)
      ]);
      for (let pass = 0; pass < 5; pass++) {
        const metricNames = new Set(metrics.map((mm) => mm.name));
        const before = metrics.length;
        for (let i = metrics.length - 1; i >= 0; i--) {
          const refs = (String(metrics[i].formula).match(/\[([^\]\/]+)\]/g) || []).map((r) => r.slice(1, -1));
          const bad = refs.find((r) => !colDisplays.has(r) && !metricNames.has(r));
          if (bad) {
            warnings.push(`\u26A0 "${metrics[i].name}": references "[${bad}]" which is not a column or metric on this element (cross-table measure) \u2014 dropped; recreate in a workbook element at the visual's grain (the joined "View" element has the dim columns).`);
            metrics.splice(i, 1);
          }
        }
        if (metrics.length === before)
          break;
      }
    }
    const folders = [];
    const folderMap = {};
    for (const c of [...t.columns || [], ...t.measures || []]) {
      if (c.displayFolder) {
        if (!folderMap[c.displayFolder]) {
          folderMap[c.displayFolder] = { id: sigmaShortId(), name: c.displayFolder, items: [] };
        }
        const colId = tableColMap[tableName][c.name];
        if (colId)
          folderMap[c.displayFolder].items.push(colId);
      }
    }
    for (const folder of Object.values(folderMap)) {
      if (folder.items.length > 0)
        folders.push(folder);
    }
    const baseElementName = path && path.length ? path[path.length - 1] : tableName.toUpperCase();
    const element = {
      id: elementId,
      kind: "table",
      name: baseElementName,
      source: { connectionId: connectionId || "<CONNECTION_ID>", kind: "warehouse-table", path: physPath },
      columns,
      order
    };
    if (metrics.length > 0)
      element.metrics = metrics;
    if (folders.length > 0)
      element.folders = folders;
    if (t.isHidden)
      element.visibleAsSource = false;
    elements.push(element);
  }
  if (measureOnlyTables.size > 0) {
    const factEl = elements.reduce((best, e) => (e.columns || []).length > (best.columns || []).length ? e : best, elements[0]);
    const homeElFor = (rawDax) => {
      const refs = [...String(rawDax).matchAll(/(?:'([^']+)'|\b([A-Za-z_]\w*))\s*\[([^\]]+)\]/g)];
      for (const r of refs) {
        const tbl = (r[1] || r[2] || "").trim();
        const colName = r[3];
        const elId = tableIdMap[tbl];
        if (!elId || !(tableColMap[tbl] && colName in tableColMap[tbl]))
          continue;
        const el = elements.find((e) => e.id === elId);
        if (el && (el.columns || []).length)
          return el;
      }
      return factEl;
    };
    if (factEl) {
      for (const tName of measureOnlyTables) {
        const t = model.tables.find((tb) => tb.name === tName);
        if (!t)
          continue;
        for (const m of t.measures || []) {
          const moExpr = processUseRelationships(m.name, Array.isArray(m.expression) ? m.expression.join("\n") : String(m.expression || ""));
          const homeEl = homeElFor(moExpr);
          if (m.name)
            measureToElementId[m.name] = homeEl.id;
          let sigmaFormula = pbiDaxToSigma(moExpr, warnings, m.name, measureDaxMap);
          if (sigmaFormula && hasBareWindowFn(sigmaFormula)) {
            warnings.push(`\u26D4 "${m.name}": window-function measure has no Sigma DM-metric equivalent \u2014 use a workbook Rank()/ordered table or a grouped element. Dropped.`);
            sigmaFormula = null;
          }
          if (sigmaFormula) {
            sigmaFormula = sigmaFormula.replace(/\[([^\]\/]+)\]/g, (_m2, colName) => {
              return allPbiToSigmaNames[colName] ? `[${allPbiToSigmaNames[colName]}]` : `[${colName}]`;
            });
            if (!homeEl.metrics)
              homeEl.metrics = [];
            const _moFmt = inferSigmaFormat(sigmaFormula, m.name, m.formatString);
            const metric = { id: sigmaShortId(), formula: sigmaFormula, name: m.name };
            if (_moFmt)
              metric.format = _moFmt;
            if (m.description)
              metric.description = m.description;
            homeEl.metrics.push(metric);
            if (homeEl !== factEl) {
              warnings.push(`\u2139 "${m.name}": bound to its home fact element "${homeEl.source?.path?.[homeEl.source.path.length - 1] || homeEl.id}" (the table that owns its aggregated column), not the largest element \u2014 preserves the measure's source fact (dax-fidelity #4).`);
            }
          }
        }
        warnings.push(`\u2139 Measures table "${tName}" \u2192 measures moved to their home fact element(s).`);
      }
    }
  }
  for (const rel of model.relationships || []) {
    const fromTable = rel.fromTable;
    const toTable = rel.toTable;
    const fromCol = rel.fromColumn;
    const toCol = rel.toColumn;
    const isActive = rel.isActive !== false;
    const altName = relActivationNames.get(rel);
    if (!isActive && !altName) {
      warnings.push(`\u2139 Inactive relationship ${fromTable}[${fromCol}] \u2192 ${toTable}[${toCol}] skipped \u2014 no measure activates it via USERELATIONSHIP.`);
      continue;
    }
    const fromElId = tableIdMap[fromTable];
    const toElId = tableIdMap[toTable];
    if (!fromElId || !toElId)
      continue;
    const fromColId = tableColMap[fromTable]?.[fromCol];
    const toColId = tableColMap[toTable]?.[toCol];
    if (!fromColId || !toColId) {
      warnings.push(`\u26A0 Relationship ${fromTable}[${fromCol}] \u2192 ${toTable}[${toCol}]: columns not found`);
      continue;
    }
    {
      const typeOf = (tbl, col) => {
        const t = (model.tables || []).find((x) => x.name === tbl);
        const c = t && (t.columns || []).find((x) => x.name === col);
        return c ? String(c.dataType || "") : "";
      };
      const isNum = (d) => ["int64", "double", "decimal"].includes(d);
      const fromType = typeOf(fromTable, fromCol), toType = typeOf(toTable, toCol);
      if (fromType && toType && isNum(fromType) !== isNum(toType)) {
        const fixSide = (tbl, col, colId, wrap) => {
          const t = (model.tables || []).find((x) => x.name === tbl);
          const c = t && (t.columns || []).find((x) => x.name === col);
          if (!c || c.type !== "calculated")
            return false;
          const el = elements.find((e) => e.id === tableIdMap[tbl]);
          const ec2 = el && (el.columns || []).find((x) => x.id === colId);
          if (!ec2 || typeof ec2.formula !== "string" || ec2.formula.startsWith(`${wrap}(`))
            return false;
          ec2.formula = `${wrap}(${ec2.formula})`;
          warnings.push(`\u2139 Relationship ${fromTable}[${fromCol}] \u2192 ${toTable}[${toCol}]: mixed-type keys (${fromType} vs ${toType}) \u2014 coerced calc column "${col}" with ${wrap}() to match.`);
          return true;
        };
        const fixed = isNum(toType) ? fixSide(fromTable, fromCol, fromColId, "Number") || fixSide(toTable, toCol, toColId, "Text") : fixSide(toTable, toCol, toColId, "Number") || fixSide(fromTable, fromCol, fromColId, "Text");
        if (!fixed) {
          warnings.push(`\u26A0 Relationship ${fromTable}[${fromCol}] \u2192 ${toTable}[${toCol}]: mixed-type keys (${fromType} vs ${toType}) on physical columns \u2014 the Sigma join will error at query time; align the warehouse column types.`);
        }
      }
    }
    const fromElement = elements.find((e) => e.id === fromElId);
    if (fromElement) {
      if (!fromElement.relationships)
        fromElement.relationships = [];
      fromElement.relationships.push({
        id: sigmaShortId(),
        targetElementId: toElId,
        keys: [{ sourceColumnId: fromColId, targetColumnId: toColId }],
        name: isActive ? toTable : altName
      });
    }
  }
  for (const el of elements) {
    const mets = el.metrics || [];
    if (!mets.length)
      continue;
    const kept = [];
    for (const metric of mets) {
      const refs = [...String(metric.formula).matchAll(/\[([^\]\/]+)\]/g)].map((x) => x[1]).filter((n) => n in measureToElementId);
      const paths = new Set(refs.map((r) => measureAltPath[r] || ""));
      if (metric.name in measureAltPath)
        paths.add(measureAltPath[metric.name]);
      if (paths.size > 1) {
        const detail = refs.map((r) => `[${r}] via ${measureAltPath[r] ? `"${measureAltPath[r]}"` : "the active path"}`).join(", ");
        warnings.push(`\u26A0 "${metric.name}": combines measures that resolve through DIFFERENT relationship paths (${detail}). A single-element scalar conflates the paths \u2014 build each operand as its own grouped element on its path's columns, join on the shared period/dimension, then combine. Dropped.`);
        continue;
      }
      kept.push(metric);
    }
    if (kept.length)
      el.metrics = kept;
    else
      delete el.metrics;
  }
  const measureRefRe = /\[([^\]\/]+)\]/g;
  for (const el of elements) {
    const mets = el.metrics || [];
    if (!mets.length)
      continue;
    const kept = [];
    for (const metric of mets) {
      const formula = metric.formula || "";
      const refs = [...formula.matchAll(measureRefRe)].map((m) => m[1]);
      const foreignMeasures = [...new Set(refs)].filter((name) => {
        const owner = measureToElementId[name];
        return owner && owner !== el.id;
      });
      const combines = /[\/*+\-]/.test(formula.replace(/\[[^\]]*\]/g, ""));
      if (foreignMeasures.length && combines) {
        const owners = foreignMeasures.map((n) => {
          const oid = measureToElementId[n];
          const oel = elements.find((e) => e.id === oid);
          return `[${n}] (on ${oel?.name || oid})`;
        }).join(", ");
        warnings.push(`\u26D4 "${metric.name}": cross-table ratio \u2014 references ${owners} from a different element than "${el.name}". Emitting a same-element metric would resolve those aggregates as NULL. In Sigma, reproduce via a constant-key (All Key = 1) relationship Lookup to the foreign element so the foreign aggregate is taken across the FULL related set (e.g. denominator = global headcount, not just rows with a match), then divide. Add this metric manually. See: ${PBI_COMMUNITY_LINKS.leveled}`);
        continue;
      }
      kept.push(metric);
    }
    if (kept.length)
      el.metrics = kept;
    else
      delete el.metrics;
  }
  const pbiCrossElCalcsByElId = {};
  for (const el of elements) {
    if (el.source?.kind !== "warehouse-table")
      continue;
    if (!el.relationships?.length)
      continue;
    const localNames = /* @__PURE__ */ new Set();
    for (const c of el.columns || []) {
      if (c.name)
        localNames.add(c.name.toUpperCase());
      if (!c.formula)
        continue;
      const fm = c.formula.match(/^\[[^\]\/]+\/([^\]]+)\]$/);
      if (fm)
        localNames.add(fm[1].toUpperCase());
    }
    const cross = [];
    const keep = [];
    for (const c of el.columns || []) {
      if (!c.name || !c.formula) {
        keep.push(c);
        continue;
      }
      if (/^\[[^\]\/]+\/[^\]\/]+\/[^\]]+\]$/.test(c.formula)) {
        keep.push(c);
        continue;
      }
      if (/^\[[^\]\/]+\/[^\]\/]+\]$/.test(c.formula)) {
        keep.push(c);
        continue;
      }
      const refs = c.formula.match(/\[([^\]\/]+)\]/g) || [];
      const hasCross = refs.some((ref) => {
        const rn = ref.replace(/^\[|\]$/g, "");
        return !/^(true|false|null)$/i.test(rn) && !localNames.has(rn.toUpperCase());
      });
      if (hasCross) {
        const oi = (el.order || []).indexOf(c.id);
        if (oi >= 0)
          el.order.splice(oi, 1);
        cross.push(c);
      } else {
        keep.push(c);
      }
    }
    el.columns = keep;
    if (cross.length)
      pbiCrossElCalcsByElId[el.id] = cross;
  }
  const metricIndex = {};
  for (let ei = 0; ei < elements.length; ei++) {
    for (const m of elements[ei].metrics || []) {
      if (m.name && m.formula)
        metricIndex[m.name] = { elementIndex: ei, sigmaFormula: m.formula };
    }
  }
  for (const t of model.tables) {
    if (!calcGroupTables.has(t.name))
      continue;
    const cg = t.calculationGroup;
    const items = cg?.calculationItems || [];
    if (items.length === 0)
      continue;
    const groupName = t.name;
    warnings.push(`\u2139 Calculation group "${groupName}" (${items.length} item${items.length !== 1 ? "s" : ""}): ${items.map((i) => i.name).join(", ")} \u2014 derived metric stubs generated. Implement time intelligence using Sigma's Period-over-Period: ${PBI_COMMUNITY_LINKS.pop}`);
    const newMetricsByElement = {};
    for (const item of items) {
      const itemName = item.name || "Unknown";
      const itemExpr = (item.expression || "").trim();
      const isPassthrough = /^SELECTEDMEASURE\s*\(\s*\)\s*$/i.test(itemExpr) || itemName.toLowerCase() === "current" || itemName.toLowerCase() === "actual";
      if (isPassthrough)
        continue;
      let description = `Calculation group "${groupName}" \u2014 ${itemName}. `;
      if (/TOTALYTD|DATESYTD/i.test(itemExpr)) {
        description += `Year-to-date. Implement using DateTrunc + CumulativeSum or Sigma's Period-over-Period: ${PBI_COMMUNITY_LINKS.pop}`;
      } else if (/TOTALQTD/i.test(itemExpr)) {
        description += `Quarter-to-date. Use DateTrunc("quarter", \u2026) + CumulativeSum.`;
      } else if (/TOTALMTD/i.test(itemExpr)) {
        description += `Month-to-date. Use DateTrunc("month", \u2026) + CumulativeSum.`;
      } else if (/SAMEPERIODLASTYEAR|PREVIOUSYEAR/i.test(itemExpr)) {
        description += `Same period last year. Implement using Sigma's Period-over-Period: ${PBI_COMMUNITY_LINKS.pop}`;
      } else if (/PREVIOUSQUARTER|PREVIOUSMONTH/i.test(itemExpr)) {
        description += `Previous period. Implement using DateAdd / Sigma's Period-over-Period: ${PBI_COMMUNITY_LINKS.pop}`;
      } else if (/PARALLELPERIOD|DATEADD/i.test(itemExpr)) {
        description += `Date-shifted period. Implement using DateAdd + Sigma's Period-over-Period: ${PBI_COMMUNITY_LINKS.pop}`;
      } else if (/DIVIDE\s*\(/i.test(itemExpr)) {
        description += `Ratio/variance calculation. Implement as a derived metric using base period formulas.`;
      } else {
        description += `DAX expression: ${itemExpr.slice(0, 120)}`;
      }
      for (const [baseName, ref] of Object.entries(metricIndex)) {
        const derivedName = `${baseName} (${itemName})`;
        const derivedMetric = {
          id: sigmaShortId(),
          name: derivedName,
          // Use base formula as placeholder so the metric is syntactically valid
          formula: ref.sigmaFormula,
          description
        };
        if (!newMetricsByElement[ref.elementIndex])
          newMetricsByElement[ref.elementIndex] = [];
        newMetricsByElement[ref.elementIndex].push(derivedMetric);
      }
    }
    for (const [eiStr, newMetrics] of Object.entries(newMetricsByElement)) {
      const ei = Number(eiStr);
      const el = elements[ei];
      if (!el.metrics)
        el.metrics = [];
      el.metrics.push(...newMetrics);
      if (!el.folders)
        el.folders = [];
      const existingFolder = el.folders.find((f) => f.name === groupName);
      const folderItems = newMetrics.map((m) => m.id);
      if (existingFolder) {
        existingFolder.items.push(...folderItems);
      } else {
        el.folders.push({ id: sigmaShortId(), name: groupName, items: folderItems });
      }
    }
  }
  const pbiDerivedEls = buildDerivedElements(elements);
  for (const de of pbiDerivedEls)
    elements.push(de);
  emitTimeIntelElements(model, elements, warnings);
  const pbiPlacedSrcElIds = {};
  for (const de of pbiDerivedEls) {
    if (de.source?.kind !== "table" || !de.source.elementId)
      continue;
    const srcElId = de.source.elementId;
    const calcs = pbiCrossElCalcsByElId[srcElId];
    if (!calcs?.length)
      continue;
    const srcEl = elements.find((e) => e.id === srcElId);
    if (!srcEl)
      continue;
    const srcBaseName = srcEl.name || srcEl.source?.path?.[srcEl.source.path.length - 1] || "";
    const relatedNameMap = {};
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
        if (!(dispName in relatedNameMap)) {
          relatedNameMap[dispName] = `${srcBaseName}/${rel.name}/${dispName}`;
        }
      }
    }
    for (const c of calcs) {
      if (c.formula && Object.keys(relatedNameMap).length) {
        c.formula = c.formula.replace(/\[([^\]\/]+)\]/g, (match, refName) => {
          const rewritten = relatedNameMap[refName];
          return rewritten ? `[${rewritten}]` : match;
        });
      }
      de.columns.push(c);
      de.order.push(c.id);
    }
    warnings.push(`\u2139 ${calcs.length} calc col(s) moved to derived "${de.name}" (cross-element refs)`);
    pbiPlacedSrcElIds[srcElId] = true;
  }
  for (const elId of Object.keys(pbiCrossElCalcsByElId)) {
    if (pbiPlacedSrcElIds[elId])
      continue;
    for (const c of pbiCrossElCalcsByElId[elId]) {
      warnings.push(`\u26A0 "${c.name}" cross-element refs but no derived element \u2014 column dropped`);
    }
  }
  if (winCtx.extraElements.length) {
    const usedNames = /* @__PURE__ */ new Set();
    for (const e of elements)
      if (e.name)
        usedNames.add(e.name.toLowerCase());
    for (const helper of winCtx.helpers.values()) {
      finalizePBIWindowHelper(helper);
      const el = helper.element;
      let base = el.name || "Window";
      let cand = base, n = 2;
      while (usedNames.has(cand.toLowerCase()))
        cand = `${base} ${n++}`;
      usedNames.add(cand.toLowerCase());
      el.name = cand;
    }
    elements.push(...winCtx.extraElements);
  }
  const rlsTablesSeen = /* @__PURE__ */ new Set();
  for (const role of model.roles || []) {
    for (const tp of role.tablePermissions || []) {
      const el = tableIdMap[tp.name] ? elements.find((e) => e.id === tableIdMap[tp.name]) : null;
      const feRaw = tp.filterExpression;
      if (feRaw && el) {
        let formula = pbiDaxToSigma(feRaw, warnings, `RLS ${role.name}/${tp.name}`, measureDaxMap);
        if (formula && !formula.startsWith("/*")) {
          formula = formula.replace(/\b(?:USERNAME|USERPRINCIPALNAME)\s*\(\s*\)/gi, "CurrentUserEmail()");
          formula = formula.replace(/\[([^\]\/]+)\]/g, (m, n) => allPbiToSigmaNames[n] ? `[${allPbiToSigmaNames[n]}]` : m);
          security.push(makeRlsSecurity({ source: `Power BI role "${role.name}" (table "${tp.name}")`, element: el, name: `RLS: ${role.name}`, formula }));
          warnings.push(`\u{1F510} PBI role "${role.name}" RLS on table "${tp.name}" \u2192 row-level security DETECTED (reported in result.security, not injected): ${formula.slice(0, 70)}. Role membership is bound in the Power BI Service (not the model file); the migration skill provisions the attribute/team + assigns members, then applies the RLS calc + filter.`);
          if (rlsTablesSeen.has(tp.name))
            warnings.push(`\u26A0 Multiple PBI roles apply RLS to "${tp.name}". Power BI unions role filters (OR); stacked Sigma element filters intersect (AND). Review \u2014 you likely want the role conditions OR-combined into one RLS column.`);
          rlsTablesSeen.add(tp.name);
        } else {
          warnings.push(`\u26A0 PBI role "${role.name}" RLS filter on "${tp.name}" ("${String(feRaw).slice(0, 60)}") could not be translated \u2014 re-apply manually as a boolean calc column + element filter.`);
        }
      }
      const hidden = (tp.columnPermissions || []).filter((cp) => (cp.metadataPermission || cp.memberPermission) === "none");
      if (hidden.length && el) {
        const ids = hidden.map((cp) => tableColMap[tp.name]?.[cp.name]).filter(Boolean);
        if (ids.length) {
          security.push(makeClsSecurity({ source: `Power BI OLS role "${role.name}" (table "${tp.name}")`, element: el, columnIds: ids, columnNames: hidden.map((c) => c.name), note: "PBI OLS hides from the role's members; Sigma CLS is per-restriction (no-one-can-view, or re-scope to a team/attribute allowlist). The skill applies it \u2014 not injected." }));
          warnings.push(`\u{1F510} PBI role "${role.name}" object-level security hides [${hidden.map((c) => c.name).join(", ")}] on "${tp.name}" \u2192 CLS DETECTED (reported in result.security, not injected).`);
        }
      }
    }
  }
  if (!connectionId)
    warnings.unshift("\u26A0 Connection ID not set \u2014 update in JSON before saving to Sigma");
  const modelName = modelJson.name || model.name || "Power BI Import";
  const sigmaModel = {
    name: modelName,
    schemaVersion: 1,
    pages: [{ id: sigmaShortId(), name: "Page 1", elements }]
  };
  const ec = elements.length;
  const mc = elements.reduce((n, e) => n + (e.metrics?.length || 0), 0);
  const rc = elements.reduce((n, e) => n + (e.relationships?.length || 0), 0);
  const cgCount = calcGroupTables.size;
  return {
    model: sigmaModel,
    warnings,
    ...security.length ? { security } : {},
    stats: {
      tables: model.tables.filter((t) => !calcGroupTables.has(t.name)).length,
      elements: ec,
      columns: elements.reduce((n, e) => n + (e.columns?.length || 0), 0),
      metrics: mc,
      relationships: rc,
      ...cgCount > 0 ? { calculationGroups: cgCount } : {}
    }
  };
}
export {
  convertPowerBIToSigma,
  expandMeasureRefs,
  extractUseRelationships,
  hasBareWindowFn,
  isAggCombination,
  pbiDaxToSigma,
  pbiParseEarlierWindow
};
