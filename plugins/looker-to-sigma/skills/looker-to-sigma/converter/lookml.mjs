// ../sigma-data-model-mcp/build/sigma-ids.js
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
function sigmaDisplayName(s) {
  const normalized = (s || "").replace(/([a-z])([A-Z])/g, "$1_$2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2").replace(/([A-Za-z])([0-9])/g, "$1_$2").replace(/([0-9])([A-Za-z])/g, "$1_$2");
  const words = normalized.toLowerCase().split(/[_\s/-]+/).filter(Boolean);
  return words.map((w, i) => i === 0 || !SIGMA_LOWERCASE_WORDS.has(w) ? w.charAt(0).toUpperCase() + w.slice(1) : w).join(" ");
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

// ../sigma-data-model-mcp/build/formulas.js
function stripOuterParens(s) {
  s = s.trim();
  while (s.length > 1 && s.startsWith("(") && s.endsWith(")")) {
    let depth = 0, quote = "", inBracket = false, wraps = true;
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (inBracket) {
        if (c === "]")
          inBracket = false;
        continue;
      }
      if (quote) {
        if (c === quote)
          quote = "";
        continue;
      }
      if (c === "[") {
        inBracket = true;
        continue;
      }
      if (c === "'" || c === '"') {
        quote = c;
        continue;
      }
      if (c === "(")
        depth++;
      else if (c === ")") {
        depth--;
        if (depth === 0 && i < s.length - 1) {
          wraps = false;
          break;
        }
      }
    }
    if (!wraps || depth !== 0)
      break;
    s = s.slice(1, -1).trim();
  }
  return s;
}
function lookColRef(identifier) {
  return `[${sigmaDisplayName(identifier)}]`;
}
var UNSUPPORTED_SIGMA_SQL = [
  { pattern: /\bFLATTEN\s*\(/i, name: "FLATTEN" },
  { pattern: /\bLATERAL\b/i, name: "LATERAL" },
  { pattern: /\bQUALIFY\b/i, name: "QUALIFY" },
  { pattern: /\bPIVOT\s*\(/i, name: "PIVOT" },
  { pattern: /\bUNPIVOT\s*\(/i, name: "UNPIVOT" },
  { pattern: /\bGENERATOR\s*\(/i, name: "GENERATOR" },
  { pattern: /\bTABLESAMPLE\b/i, name: "TABLESAMPLE" },
  { pattern: /\bOBJECT_CONSTRUCT\s*\(/i, name: "OBJECT_CONSTRUCT" },
  { pattern: /\bARRAY_CONSTRUCT\s*\(/i, name: "ARRAY_CONSTRUCT" }
];
function detectUnsupportedSigmaFunction(formula) {
  for (const { pattern, name } of UNSUPPORTED_SIGMA_SQL) {
    if (pattern.test(formula))
      return name;
  }
  return null;
}
function lookIsComplexSql(sql) {
  if (!sql)
    return false;
  const cleaned = sql.replace(/\$\{TABLE\}\./gi, "").replace(/\$\{[^}]+\}/g, "X").trim();
  if (/^(?:CAST|SAFE_CAST|TRY_CAST)\s*\(\s*"?[A-Za-z_][A-Za-z0-9_]*"?\s+AS\s+\w[\w_]*\s*\)$/i.test(cleaned))
    return false;
  if (/^[A-Za-z_][A-Za-z0-9_]*\s*\(/.test(cleaned))
    return true;
  if (/^CASE\b/i.test(cleaned))
    return true;
  if (/\bIN\s*\(/i.test(cleaned))
    return true;
  if (cleaned.includes("||"))
    return true;
  if (/[=<>!+\-*\/%]/.test(cleaned.replace(/'[^']*'/g, "")))
    return true;
  return false;
}
function _splitTopLevelArgs(s) {
  const args = [];
  let depth = 0, quote = "", bracket = false, cur = "";
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (quote) {
      cur += c;
      if (c === quote)
        quote = "";
      continue;
    }
    if (c === "[") {
      bracket = true;
      cur += c;
      continue;
    }
    if (c === "]") {
      bracket = false;
      cur += c;
      continue;
    }
    if (!bracket) {
      if (c === "'" || c === '"') {
        quote = c;
        cur += c;
        continue;
      }
      if (c === "(")
        depth++;
      else if (c === ")")
        depth--;
      else if (c === "," && depth === 0) {
        args.push(cur);
        cur = "";
        continue;
      }
    }
    cur += c;
  }
  args.push(cur);
  return args;
}
var _MYSQL_DIFF_UNIT = { DATEDIFF: "day", TIMEDIFF: "second" };
function _rewriteMysqlDateDiff(expr) {
  const NAME = /\b(DATEDIFF|TIMEDIFF)\s*\(/i;
  let out = "", rest = expr;
  for (; ; ) {
    const m = NAME.exec(rest);
    if (!m) {
      out += rest;
      break;
    }
    const open = m.index + m[0].length - 1;
    let depth = 0, close = -1;
    for (let i = open; i < rest.length; i++) {
      if (rest[i] === "(")
        depth++;
      else if (rest[i] === ")") {
        depth--;
        if (depth === 0) {
          close = i;
          break;
        }
      }
    }
    if (close === -1) {
      out += rest;
      break;
    }
    const inner = rest.slice(open + 1, close);
    const args = _splitTopLevelArgs(inner);
    out += rest.slice(0, m.index);
    if (args.length === 2) {
      const unit = _MYSQL_DIFF_UNIT[m[1].toUpperCase()];
      const end = _rewriteMysqlDateDiff(args[0]).trim();
      const start = _rewriteMysqlDateDiff(args[1]).trim();
      out += `DateDiff("${unit}", ${start}, ${end})`;
    } else {
      out += `${rest.slice(m.index, open + 1)}${_rewriteMysqlDateDiff(inner)})`;
    }
    rest = rest.slice(close + 1);
  }
  return out;
}
var _MYSQL_ADD_SPEC = {
  ADDDATE: { unit: "day", negate: false },
  SUBDATE: { unit: "day", negate: true },
  DATE_ADD: { unit: "day", negate: false },
  DATE_SUB: { unit: "day", negate: true }
};
var _MYSQL_INTERVAL_UNIT = {
  SECOND: "second",
  MINUTE: "minute",
  HOUR: "hour",
  DAY: "day",
  WEEK: "week",
  MONTH: "month",
  QUARTER: "quarter",
  YEAR: "year"
};
function _negateAmount(amount) {
  const t = amount.trim();
  const num = t.match(/^([+-]?)(\d+(?:\.\d+)?)$/);
  if (num)
    return num[1] === "-" ? num[2] : `-${num[2]}`;
  return `-(${t})`;
}
function _rewriteMysqlDateAdd(expr) {
  const NAME = /\b(ADDDATE|SUBDATE|DATE_ADD|DATE_SUB)\s*\(/i;
  let out = "", rest = expr;
  for (; ; ) {
    const m = NAME.exec(rest);
    if (!m) {
      out += rest;
      break;
    }
    const open = m.index + m[0].length - 1;
    let depth = 0, close = -1;
    for (let i = open; i < rest.length; i++) {
      if (rest[i] === "(")
        depth++;
      else if (rest[i] === ")") {
        depth--;
        if (depth === 0) {
          close = i;
          break;
        }
      }
    }
    if (close === -1) {
      out += rest;
      break;
    }
    const inner = rest.slice(open + 1, close);
    const args = _splitTopLevelArgs(inner);
    out += rest.slice(0, m.index);
    const spec = _MYSQL_ADD_SPEC[m[1].toUpperCase()];
    let unit = spec.unit;
    let amount = null;
    if (args.length === 2) {
      const iv = args[1].trim().match(/^INTERVAL\s+(.+?)\s+([A-Za-z_]+)\s*$/i);
      if (iv) {
        const mapped = _MYSQL_INTERVAL_UNIT[iv[2].toUpperCase()];
        if (mapped) {
          unit = mapped;
          amount = _rewriteMysqlDateAdd(iv[1]).trim();
        }
      } else {
        amount = _rewriteMysqlDateAdd(args[1]).trim();
      }
    }
    if (amount !== null) {
      const date = _rewriteMysqlDateAdd(args[0]).trim();
      out += `DateAdd("${unit}", ${spec.negate ? _negateAmount(amount) : amount}, ${date})`;
    } else {
      out += `${rest.slice(m.index, open + 1)}${_rewriteMysqlDateAdd(inner)})`;
    }
    rest = rest.slice(close + 1);
  }
  return out;
}
var LOOK_FUNC_MAP = {
  "MONTH": "Month",
  "YEAR": "Year",
  "DAY": "Day",
  "HOUR": "Hour",
  "MINUTE": "Minute",
  "SECOND": "Second",
  "QUARTER": "Quarter",
  "WEEK": "WeekOfYear",
  "WEEKDAY": "Weekday",
  "DATE_TRUNC": "DateTrunc",
  "DATEADD": "DateAdd",
  "DATEDIFF": "DateDiff",
  "COALESCE": "Coalesce",
  "NVL": "Coalesce",
  "NULLIF": "Nullif",
  "ROUND": "Round",
  "FLOOR": "Floor",
  "CEILING": "Ceiling",
  "ABS": "Abs",
  "UPPER": "Upper",
  "LOWER": "Lower",
  "TRIM": "Trim",
  "LENGTH": "Length",
  "SUBSTR": "Substring",
  "SUBSTRING": "Substring",
  "CONCAT": "Concat",
  "CURRENT_DATE": "Today()",
  "GETDATE": "Now()",
  "IFF": "If",
  "IIF": "If",
  "DECODE": "Switch",
  "ISNULL": "IsNull",
  "IFNULL": "Coalesce",
  "TO_DATE": "ToDate",
  "TO_NUMBER": "ToNumber",
  "TO_VARCHAR": "Text"
};
var _CASE_KW_RE = /^(CASE|WHEN|THEN|ELSE|END)\b/i;
function _scanCase(s, pos) {
  const markers = [];
  let caseDepth = 1, parenDepth = 0, i = pos;
  while (i < s.length) {
    const c = s[i];
    if (c === "[") {
      const close = s.indexOf("]", i + 1);
      i = close === -1 ? s.length : close + 1;
      continue;
    }
    if (c === "(") {
      parenDepth++;
      i++;
      continue;
    }
    if (c === ")") {
      parenDepth--;
      i++;
      continue;
    }
    if (/[A-Za-z]/.test(c) && (i === 0 || !/[A-Za-z0-9_]/.test(s[i - 1]))) {
      const m = _CASE_KW_RE.exec(s.slice(i));
      if (m) {
        const kw = m[1].toUpperCase(), start = i, end = i + m[1].length;
        if (kw === "CASE") {
          caseDepth++;
        } else if (kw === "END") {
          caseDepth--;
          if (caseDepth === 0)
            return { endStart: start, endIndex: end, markers };
        } else if (caseDepth === 1 && parenDepth === 0) {
          markers.push({ type: kw, start, end });
        }
        i = end;
        continue;
      }
    }
    i++;
  }
  return { endStart: -1, endIndex: -1, markers };
}
function _isBalanced(s) {
  let paren = 0, bracket = 0, inStr = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (inStr) {
      if (c === "\\") {
        i++;
        continue;
      }
      if (c === '"')
        inStr = false;
      continue;
    }
    if (c === '"') {
      inStr = true;
      continue;
    }
    if (c === "(")
      paren++;
    else if (c === ")") {
      paren--;
      if (paren < 0)
        return false;
    } else if (c === "[")
      bracket++;
    else if (c === "]") {
      bracket--;
      if (bracket < 0)
        return false;
    }
  }
  return paren === 0 && bracket === 0 && !inStr;
}
var _NESTED_CASE_UNMASK_RE = /(\d+)/g;
function _convertNestedCases(s, lits, onUnparseable = "abort", cdArgs = []) {
  const blocks = [];
  let out = "", last = 0, i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c === "[") {
      const close = s.indexOf("]", i + 1);
      i = close === -1 ? s.length : close + 1;
      continue;
    }
    if (/[A-Za-z]/.test(c) && (i === 0 || !/[A-Za-z0-9_]/.test(s[i - 1])) && /^CASE\b/i.test(s.slice(i))) {
      const caseStart = i;
      const scan = _scanCase(s, i + 4);
      if (scan.endIndex === -1) {
        if (onUnparseable === "abort")
          return null;
        break;
      }
      const rawSpan = _restoreRawCountDistinct(_restoreRawLiterals(s.slice(caseStart, scan.endIndex), lits), cdArgs);
      const converted = lookConvertCase(rawSpan);
      if (converted === null) {
        if (onUnparseable === "abort")
          return null;
        i = scan.endIndex;
        continue;
      }
      out += s.slice(last, caseStart) + `${blocks.push(converted) - 1}`;
      last = scan.endIndex;
      i = scan.endIndex;
      continue;
    }
    i++;
  }
  return { text: out + s.slice(last), blocks };
}
function _spliceNestedCases(s, blocks) {
  return s.replace(_NESTED_CASE_UNMASK_RE, (_m, i) => blocks[Number(i)] ?? _m);
}
function lookConvertCase(expr) {
  const trimmed = expr.trim();
  const head = /^CASE\b/i.exec(trimmed);
  if (!head)
    return null;
  const { masked, lits } = _maskLiterals(trimmed);
  const scan = _scanCase(masked, head[0].length);
  if (scan.endIndex === -1)
    return null;
  if (masked.slice(scan.endIndex).trim() !== "")
    return null;
  const m = scan.markers;
  const firstMarkerStart = m.length ? m[0].start : scan.endStart;
  if (masked.slice(head[0].length, firstMarkerStart).trim() !== "")
    return null;
  const branches = [];
  let elseVal = null;
  let idx = 0;
  while (true) {
    if (idx >= m.length || m[idx].type !== "WHEN")
      return null;
    const whenTok = m[idx++];
    if (idx >= m.length || m[idx].type !== "THEN")
      return null;
    const thenTok = m[idx++];
    const condText = masked.slice(whenTok.end, thenTok.start);
    let valEnd, sawElse = false;
    if (idx < m.length && m[idx].type === "WHEN") {
      valEnd = m[idx].start;
    } else if (idx < m.length && m[idx].type === "ELSE") {
      valEnd = m[idx].start;
      sawElse = true;
    } else if (idx === m.length) {
      valEnd = scan.endStart;
    } else {
      return null;
    }
    branches.push({ cond: condText, val: masked.slice(thenTok.end, valEnd) });
    if (sawElse) {
      const elseTok = m[idx++];
      if (idx !== m.length)
        return null;
      elseVal = masked.slice(elseTok.end, scan.endStart);
      break;
    }
    if (idx === m.length)
      break;
  }
  if (branches.length === 0)
    return null;
  const convertLeaf = (maskedChunk, allowNumber) => {
    const v = maskedChunk.trim();
    if (allowNumber && /^-?\d+(\.\d+)?$/.test(v))
      return v;
    const stripped = stripOuterParens(v);
    const nc = _convertNestedCases(stripped, lits);
    if (nc === null)
      return null;
    const raw = _restoreRawLiterals(nc.text, lits);
    const converted = lookConvertExpression(raw);
    const spliced = _spliceNestedCases(converted, nc.blocks);
    if (!spliced.trim())
      return null;
    return spliced;
  };
  let result = elseVal !== null ? convertLeaf(elseVal, true) : "null";
  if (result === null)
    return null;
  const conv = new Array(branches.length);
  for (let i = branches.length - 1; i >= 0; i--) {
    const sigmaCond = convertLeaf(branches[i].cond, false);
    const sigmaVal = convertLeaf(branches[i].val, true);
    if (sigmaCond === null || sigmaVal === null)
      return null;
    conv[i] = { cond: sigmaCond, val: sigmaVal };
  }
  const flat = _flattenToSwitch(conv, result);
  if (flat !== null)
    return _isBalanced(flat) ? flat : null;
  for (let i = conv.length - 1; i >= 0; i--) {
    result = `If(${conv[i].cond}, ${conv[i].val}, ${result})`;
  }
  if (!_isBalanced(result))
    return null;
  return result;
}
var _SWITCH_MIN_BRANCHES = 45;
var _SWITCH_LITERAL_RE = /^(?:"(?:[^"]|"")*"|-?\d+(?:\.\d+)?)$/;
function _flattenToSwitch(conv, elseVal) {
  if (conv.length < _SWITCH_MIN_BRANCHES)
    return null;
  let subject = null;
  const pairs = [];
  for (const { cond, val } of conv) {
    let subj = null;
    let matches = null;
    const eq = /^(.+?)\s*=\s*(.+)$/.exec(cond);
    if (eq && !/[<>!=]$/.test(eq[1].trim()) && _SWITCH_LITERAL_RE.test(eq[2].trim())) {
      subj = eq[1].trim();
      matches = [eq[2].trim()];
    } else {
      const inm = /^In\(([\s\S]*)\)$/i.exec(cond.trim());
      if (inm) {
        const args = _splitTopLevelArgs(inm[1]);
        if (args.length >= 2) {
          subj = args[0].trim();
          matches = args.slice(1).map((a) => a.trim());
        }
      }
    }
    if (subj === null || matches === null || matches.length === 0)
      return null;
    if (!matches.every((m) => _SWITCH_LITERAL_RE.test(m)))
      return null;
    if (subject === null)
      subject = subj;
    else if (subject !== subj)
      return null;
    for (const m of matches)
      pairs.push(`${m}, ${val}`);
  }
  if (subject === null)
    return null;
  return `Switch(${subject}, ${pairs.join(", ")}, ${elseVal})`;
}
function lookConvertMathExpr(expr) {
  expr = expr.replace(/NULLIF\s*\(([A-Z_][A-Z0-9_]*)\s*,\s*([^)]+)\)/gi, (_, col, val) => `If(${lookColRef(col)} = ${val.trim()}, null, ${lookColRef(col)})`);
  return lookConvertExpression(expr);
}
var _LIT_RE = /'(?:[^']|'')*'/g;
function _maskLiterals(s) {
  const lits = [];
  let out = "";
  let i = 0;
  while (i < s.length) {
    if (s[i] === "[") {
      const close = s.indexOf("]", i + 1);
      if (close !== -1) {
        out += s.slice(i, close + 1);
        i = close + 1;
        continue;
      }
    }
    if (s[i] === "'") {
      _LIT_RE.lastIndex = i;
      const m = _LIT_RE.exec(s);
      if (m && m.index === i) {
        out += `\0${lits.push(m[0]) - 1}`;
        i += m[0].length;
        continue;
      }
    }
    out += s[i];
    i++;
  }
  return { masked: out, lits };
}
function _unmaskLiterals(s, lits) {
  return s.replace(/\u0000(\d+)\u0001/g, (_m, i) => {
    const inner = lits[Number(i)].slice(1, -1).replace(/''/g, "'").replace(/"/g, '\\"');
    return `"${inner}"`;
  });
}
function _restoreRawLiterals(s, lits) {
  return s.replace(/\u0000(\d+)\u0001/g, (_m, i) => lits[Number(i)] ?? _m);
}
function _restoreRawCountDistinct(s, args) {
  return s.replace(/\x02(\d+)\x03/g, (_m, i) => `COUNT(DISTINCT ${args[Number(i)] ?? ""})`);
}
function _maskCountDistinct(s) {
  const args = [];
  const re = /\bCOUNT\s*\(\s*DISTINCT\s+/gi;
  let out = "", last = 0, m;
  while ((m = re.exec(s)) !== null) {
    const argStart = m.index + m[0].length;
    let depth = 1, quote = "", i = argStart;
    for (; i < s.length; i++) {
      const c = s[i];
      if (quote) {
        if (c === quote)
          quote = "";
        continue;
      }
      if (c === "'" || c === '"') {
        quote = c;
        continue;
      }
      if (c === "[") {
        const cl = s.indexOf("]", i + 1);
        if (cl !== -1) {
          i = cl;
          continue;
        }
      }
      if (c === "(")
        depth++;
      else if (c === ")") {
        depth--;
        if (depth === 0)
          break;
      }
    }
    if (depth !== 0)
      break;
    out += s.slice(last, m.index) + `${args.push(s.slice(argStart, i).trim()) - 1}`;
    last = i + 1;
    re.lastIndex = last;
  }
  return { masked: out + s.slice(last), args };
}
function hasResidualCaseKeyword(s) {
  const masked = s.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\[[^\]]*\]/g, " ");
  return /\b(?:CASE|WHEN|THEN|END)\b/i.test(masked);
}
function hasResidualInfixOperator(s) {
  const masked = s.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\[[^\]]*\]/g, " ");
  return /\b(?:LIKE|BETWEEN)\b/i.test(masked);
}
function _unmaskCountDistinct(s, args) {
  return s.replace(/(\d+)/g, (_m, i) => {
    const raw = stripOuterParens(args[Number(i)]);
    const viaRules = lookSqlToSigmaRules(raw);
    const converted = viaRules ?? lookConvertExpression(raw);
    if (viaRules === null && hasResidualCaseKeyword(converted)) {
      return `COUNT(DISTINCT ${raw})`;
    }
    return `CountDistinct(${converted})`;
  });
}
var _SQL_KEYWORD_RE = /^(?:AND|OR|NOT|IN|IS|NULL|CASE|WHEN|THEN|ELSE|END|BETWEEN|LIKE|AS|ON|BY|DISTINCT|TRUE|FALSE|OVER|GROUP|EXISTS)$/i;
function _naiveTitleCase(fn) {
  return fn.charAt(0).toUpperCase() + fn.slice(1).toLowerCase();
}
var _BRACKET_UNMASK_RE = /\x0E(\d+)\x0F/g;
function _bracketSpanFinalText(rawSpan) {
  const inner = rawSpan.slice(1, -1);
  if (/^[A-Z_][A-Z0-9_]*$/.test(inner) && !_SQL_KEYWORD_RE.test(inner)) {
    return lookColRef(inner);
  }
  return rawSpan;
}
function _maskBrackets(s) {
  const spans = [];
  let out = "", i = 0;
  while (i < s.length) {
    if (s[i] === "[") {
      const close = s.indexOf("]", i + 1);
      if (close !== -1) {
        const finalText = _bracketSpanFinalText(s.slice(i, close + 1));
        out += `${spans.push(finalText) - 1}`;
        i = close + 1;
        continue;
      }
    }
    out += s[i];
    i++;
  }
  return { masked: out, spans };
}
function _unmaskBrackets(s, spans) {
  return s.replace(_BRACKET_UNMASK_RE, (_m, i) => spans[Number(i)] ?? _m);
}
function lookConvertExpression(expr) {
  const cd = _maskCountDistinct(expr);
  const { masked, lits } = _maskLiterals(cd.masked);
  expr = masked;
  expr = _rewriteMysqlDateDiff(expr);
  expr = _rewriteMysqlDateAdd(expr);
  const ec = _convertNestedCases(expr, lits, "leave-raw", cd.args);
  expr = ec.text;
  expr = expr.replace(/\b([A-Z_][A-Z0-9_]*)\s*(?=\()/gi, (match, fn) => {
    const upper = fn.toUpperCase();
    if (_SQL_KEYWORD_RE.test(upper))
      return match;
    const mapped = LOOK_FUNC_MAP[upper];
    if (mapped)
      return mapped.endsWith("()") ? mapped.slice(0, -2) : mapped;
    return _naiveTitleCase(fn);
  });
  expr = expr.replace(/(\[[^\]]+\]|[\w\]\)]+(?:\([^)]*\))?)\s+IN\s*\(([^)]+)\)/gi, (_, lhs, list) => {
    return `In(${lhs}, ${list})`;
  });
  {
    const { masked: bracketMasked, spans } = _maskBrackets(expr);
    expr = bracketMasked.replace(/\b([A-Z_][A-Z0-9_]*)\b(?!\s*\()/g, (match) => {
      if (_SQL_KEYWORD_RE.test(match))
        return match;
      if (/^\d+$/.test(match))
        return match;
      return lookColRef(match);
    });
    expr = _unmaskBrackets(expr, spans);
  }
  expr = _spliceNestedCases(expr, ec.blocks);
  return _unmaskCountDistinct(_unmaskLiterals(expr, lits), cd.args).trim();
}
function lookSqlToSigmaRules(sql) {
  let expr = sql.replace(/\$\{TABLE\}\./gi, "").replace(/\$\{[^.}]+\.([^}]+)\}/g, (_, f) => f.toUpperCase()).replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, n) => n.toUpperCase()).replace(/[\r\n]+\s*/g, " ").trim();
  expr = stripOuterParens(expr);
  {
    const m = expr.match(/^([A-Z_][A-Z0-9_]*)\s*=\s*(\d+)$/i);
    if (m)
      return `${lookColRef(m[1])} = ${m[2]}`;
  }
  {
    const m = expr.match(/^([A-Z_][A-Z0-9_]*)\s+IN\s*\(([^)]+)\)$/i);
    if (m) {
      const col = lookColRef(m[1]);
      const vals = m[2].split(",").map((v) => {
        v = v.trim();
        if (/^'[^']*'$/.test(v))
          return `"${v.slice(1, -1)}"`;
        return v;
      });
      return `In(${col}, ${vals.join(", ")})`;
    }
  }
  {
    const m = expr.match(/^(\[[^\]]+\])\s*(>=|<=|!=|<>|>|<|=)\s*(-?\d+(?:\.\d+)?)$/i);
    if (m)
      return `${m[1]} ${m[2] === "<>" ? "!=" : m[2]} ${m[3]}`;
  }
  {
    const m = expr.match(/^(\[[^\]]+\])\s+IN\s*\(([^)]+)\)$/i);
    if (m) {
      const vals = m[2].split(",").map((v) => {
        v = v.trim();
        if (/^'[^']*'$/.test(v))
          return `"${v.slice(1, -1)}"`;
        return v;
      });
      return `In(${m[1]}, ${vals.join(", ")})`;
    }
  }
  if (/^ROUND\s*\(/i.test(expr)) {
    const inner = expr.replace(/^ROUND\s*\(/i, "").replace(/\)\s*$/, "");
    const lastComma = inner.lastIndexOf(",");
    if (lastComma >= 0) {
      const mathExpr = inner.slice(0, lastComma).trim();
      const decimals = inner.slice(lastComma + 1).trim();
      const converted = lookConvertMathExpr(mathExpr);
      return `Round(${converted}, ${decimals})`;
    }
  }
  {
    const m = expr.match(/^DATEDIFF\s*\(\s*'([^']+)'\s*,\s*([A-Z_][A-Z0-9_]*)\s*,\s*([A-Z_][A-Z0-9_]*)\s*\)$/i);
    if (m)
      return `DateDiff("${m[1]}", ${lookColRef(m[2])}, ${lookColRef(m[3])})`;
  }
  if (/^CASE\b/i.test(expr)) {
    return lookConvertCase(expr);
  }
  if (/^[A-Z_][A-Z0-9_]*\s*[+\-*\/]/.test(expr) || /NULLIF/i.test(expr)) {
    return lookConvertMathExpr(expr);
  }
  if (expr.includes("||")) {
    const parts = expr.split("||").map((p) => {
      p = p.trim();
      if (/^'[^']*'$/.test(p))
        return `"${p.slice(1, -1)}"`;
      if (/^\[[^\]]+\]$/.test(p))
        return `Text(${p})`;
      if (/^[A-Z_][A-Z0-9_]*$/i.test(p))
        return `Text(${lookColRef(p)})`;
      return null;
    });
    if (parts.length > 1 && parts.every((p) => p !== null))
      return `Concat(${parts.join(", ")})`;
  }
  return null;
}
var _TC_COL = "(\\[[^\\]]+\\]|[A-Za-z_][A-Za-z0-9_]*)";
var _TC_AGG = "(SUM|AVG|MIN|MAX|COUNT|COUNTD|MEDIAN|STDEV|VAR)";
var _TC_AGG_EXPR = `${_TC_AGG}\\s*\\(\\s*${_TC_COL}\\s*\\)`;
function lookStripSql(sql) {
  if (!sql)
    return "";
  sql = sql.replace(/\$\{TABLE\}\./gi, "").trim();
  sql = sql.replace(/\$\{[^.}]+\.([^}]+)\}/g, "$1");
  sql = sql.replace(/`/g, "");
  sql = sql.replace(/\[([A-Za-z_][A-Za-z0-9_\s]*)\]/g, "$1");
  sql = sql.replace(/::\w[\w_]*/g, "");
  const castMatch = sql.match(/^(?:SAFE_CAST|TRY_CAST|CAST)\s*\(\s*("?[A-Za-z_][A-Za-z0-9_]*"?)\s+AS\s+\w[\w_]*\s*\)$/i);
  if (castMatch)
    sql = castMatch[1];
  sql = sql.replace(/"/g, "").trim();
  const m = sql.match(/^([A-Za-z_][A-Za-z0-9_]*)/);
  return m ? m[1] : sql;
}
function lookSigmaMetric(measureType, colName) {
  const dn = sigmaDisplayName(colName);
  const map = {
    sum: `Sum([${dn}])`,
    count: `CountIf(IsNotNull([${dn}]))`,
    count_distinct: `CountDistinct([${dn}])`,
    average: `Avg([${dn}])`,
    max: `Max([${dn}])`,
    min: `Min([${dn}])`,
    list: `ListAgg([${dn}])`,
    sum_distinct: `Sum(Distinct [${dn}])`,
    average_distinct: `Avg(Distinct [${dn}])`,
    median: `Median([${dn}])`,
    number: `[${dn}]`,
    yesno: `CountIf([${dn}])`
  };
  return map[(measureType || "").toLowerCase()] || `CountIf(IsNotNull([${dn}]))`;
}

// ../sigma-data-model-mcp/build/lookml.js
function lookmlNamedFormat(name) {
  const n = name.trim().toLowerCase();
  const CUR = { usd: "$", gbp: "\xA3", eur: "\u20AC", cad: "$", aud: "$" };
  let m = n.match(/^(usd|gbp|eur|cad|aud)(?:_(\d+))?$/);
  if (m) {
    const sym = CUR[m[1]];
    const dec = m[2] != null ? Number(m[2]) : 2;
    return { kind: "number", formatString: `${sym},.${dec}f`, currencySymbol: sym };
  }
  m = n.match(/^percent(?:_(\d+))?$/);
  if (m) {
    const dec = m[1] != null ? Number(m[1]) : 0;
    return { kind: "number", formatString: `,.${dec}%` };
  }
  m = n.match(/^decimal(?:_(\d+))?$/);
  if (m) {
    const dec = m[1] != null ? Number(m[1]) : 0;
    return { kind: "number", formatString: `,.${dec}f` };
  }
  if (n === "id")
    return { kind: "number", formatString: ",.0f" };
  return null;
}
function lookmlCustomFormat(mask) {
  if (typeof mask !== "string")
    return null;
  const raw = mask.trim();
  if (!raw)
    return null;
  if (/general|date|time|@|yyyy|mmm|\bdd\b/i.test(raw))
    return null;
  const decM = raw.match(/\.([0#]+)/);
  const decimals = decM ? decM[1].length : 0;
  const isPercent = /%/.test(raw);
  const curM = raw.match(/[$£€¥]/);
  const sufM = raw.match(/\\?["']\s*([KMB])\s*\\?["']/i);
  const suffix = sufM ? sufM[1].toUpperCase() : void 0;
  const SYM = { "$": "$", "\xA3": "\xA3", "\u20AC": "\u20AC", "\xA5": "\xA5" };
  if (isPercent) {
    const fmt = { kind: "number", formatString: `,.${decimals}%` };
    if (suffix)
      fmt.suffix = suffix;
    return fmt;
  }
  if (curM) {
    const sym = SYM[curM[0]] || "$";
    const fmt = { kind: "number", formatString: `${sym},.${decimals}f`, currencySymbol: sym };
    if (suffix)
      fmt.suffix = suffix;
    return fmt;
  }
  if (/[0#]/.test(raw)) {
    const fmt = { kind: "number", formatString: `,.${decimals}f` };
    if (suffix)
      fmt.suffix = suffix;
    return fmt;
  }
  return null;
}
function snowflakeNumericMaskFormat(mask) {
  if (typeof mask !== "string")
    return null;
  const m = mask.trim().replace(/^FM/i, "");
  if (!m || !/^[\s$£€¥90,.]+$/.test(m))
    return null;
  const decM = m.match(/\.([90]+)/);
  const decimals = decM ? decM[1].length : 0;
  const curM = m.match(/[$£€¥]/);
  const sep = m.includes(",") ? "," : "";
  if (curM)
    return { kind: "number", formatString: `${curM[0]}${sep}.${decimals}f`, currencySymbol: curM[0] };
  if (/[90]/.test(m))
    return { kind: "number", formatString: `${sep}.${decimals}f` };
  return null;
}
function lookmlFieldFormat(field, warnings) {
  if (!field || typeof field !== "object")
    return void 0;
  const named = field.value_format_name;
  if (typeof named === "string" && named.trim()) {
    const f = lookmlNamedFormat(named);
    if (f)
      return f;
    warnings.push(`\u26A0 "${field._name}": value_format_name "${named}" has no Sigma mapping \u2014 set the column format manually.`);
    return void 0;
  }
  const custom = field.value_format;
  if (typeof custom === "string" && custom.trim()) {
    const f = lookmlCustomFormat(custom);
    if (f)
      return f;
    warnings.push(`\u26A0 "${field._name}": value_format "${custom}" could not be translated \u2014 set the column format manually.`);
    return void 0;
  }
  return void 0;
}
function restoreSqlPlaceholders(obj, map) {
  if (!obj || typeof obj !== "object")
    return;
  for (const key of Object.keys(obj)) {
    const v = obj[key];
    if (typeof v === "string" && map[v] !== void 0) {
      obj[key] = map[v];
    } else if (typeof v === "object") {
      restoreSqlPlaceholders(v, map);
    }
  }
}
function parseLookML(text) {
  text = (() => {
    let out = "";
    let inStr = false;
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (inStr) {
        out += ch;
        if (ch === "\\" && i + 1 < text.length) {
          out += text[++i];
          continue;
        }
        if (ch === '"')
          inStr = false;
        continue;
      }
      if (ch === '"') {
        inStr = true;
        out += ch;
        continue;
      }
      if (ch === "#") {
        while (i < text.length && text[i] !== "\n")
          i++;
        if (i < text.length)
          out += "\n";
        continue;
      }
      out += ch;
    }
    return out;
  })();
  const sqlPlaceholders = {};
  let phIdx = 0;
  text = text.replace(/\b(sql_distinct_key|sql_trigger_value|sql_table_name|sql_where|sql_start|sql_end|sql_on|html|sql)\s*:([\s\S]*?);;/g, (match, keyName, sqlContent) => {
    const key = `__SQLPH${phIdx++}__`;
    sqlPlaceholders[key] = sqlContent.trim();
    return `${keyName}: "${key}" ;;`;
  });
  const tokens = [];
  const re = /;;;?|\$\{[^}]*\}|[\[\]{}]|"(?:[^"\\]|\\.)*"|[^\s\[\]{}:;,"]+|:/g;
  let m;
  while ((m = re.exec(text)) !== null)
    tokens.push(m[0]);
  let pos = 0;
  const peek = (n) => tokens[pos + (n || 0)];
  const consume = () => tokens[pos++];
  const NAMED_BLOCK_KEYS = /* @__PURE__ */ new Set([
    "dimension",
    "measure",
    "dimension_group",
    "filter",
    "parameter",
    "join",
    "set",
    "link",
    "action",
    "form_param",
    "option",
    // Native Derived Table (NDT): `explore_source: <explore> { column ... }`
    "explore_source",
    "column",
    "derived_column"
  ]);
  const SQL_KEYS = /* @__PURE__ */ new Set([
    "sql",
    "sql_on",
    "sql_where",
    "sql_table_name",
    "sql_trigger_value",
    "html",
    "label_from_parameter",
    "sql_start",
    "sql_end",
    "sql_distinct_key"
  ]);
  function parseBlock() {
    const obj = {};
    while (pos < tokens.length) {
      const t = peek();
      if (t === "}") {
        consume();
        break;
      }
      if (t === void 0)
        break;
      const key = consume();
      if (peek() !== ":")
        continue;
      consume();
      const a0 = peek();
      const a1 = peek(1);
      if (SQL_KEYS.has(key)) {
        const parts = [];
        while (pos < tokens.length && peek() !== ";;" && peek() !== ";;;" && peek() !== "}") {
          parts.push(consume());
        }
        if (peek() === ";;" || peek() === ";;;")
          consume();
        let val = parts.join(" ").trim();
        if (val.startsWith('"') && val.endsWith('"'))
          val = val.slice(1, -1);
        obj[key] = val;
      } else if (NAMED_BLOCK_KEYS.has(key) && a0 && a0 !== "{" && a1 === "{") {
        const name = consume().replace(/"/g, "");
        consume();
        const child = parseBlock();
        child._name = name;
        if (obj[key] !== void 0) {
          if (!Array.isArray(obj[key]))
            obj[key] = [obj[key]];
          obj[key].push(child);
        } else {
          obj[key] = [child];
        }
      } else if (a0 === "{") {
        consume();
        const child = parseBlock();
        if (obj[key] !== void 0) {
          if (!Array.isArray(obj[key]))
            obj[key] = [obj[key]];
          obj[key].push(child);
        } else {
          obj[key] = child;
        }
      } else if (a0 === ";;" || a0 === ";;;") {
        consume();
        obj[key] = "";
      } else if (a0 === "[") {
        consume();
        const items = [];
        while (pos < tokens.length && peek() !== "]") {
          const t1 = consume();
          if (t1 === void 0)
            break;
          if (peek() === ":") {
            consume();
            let val = consume() || "";
            if (val.startsWith('"') && val.endsWith('"'))
              val = val.slice(1, -1);
            items.push({ field: t1.replace(/"/g, ""), value: val });
          } else {
            let val = t1;
            if (val.startsWith('"') && val.endsWith('"'))
              val = val.slice(1, -1);
            items.push(val);
          }
        }
        if (peek() === "]")
          consume();
        if (peek() === ";;" || peek() === ";;;")
          consume();
        obj[key] = items;
      } else {
        let val = consume() || "";
        if (val.startsWith('"') && val.endsWith('"'))
          val = val.slice(1, -1);
        if (peek() === ";;" || peek() === ";;;")
          consume();
        obj[key] = val;
      }
    }
    return obj;
  }
  const result = { views: [], explores: [], connection: null, label: null, includes: [] };
  while (pos < tokens.length) {
    const keyword = consume();
    if (!keyword)
      continue;
    if ((keyword === "view" || keyword === "explore") && peek() === ":") {
      consume();
      const name = (consume() || "").replace(/"/g, "");
      if (peek() === "{") {
        consume();
        const block = parseBlock();
        block._name = name;
        result[keyword + "s"].push(block);
      }
    } else if (keyword === "connection" && peek() === ":") {
      consume();
      result.connection = (consume() || "").replace(/"/g, "");
    } else if (keyword === "label" && peek() === ":") {
      consume();
      result.label = (consume() || "").replace(/"/g, "");
    } else if (keyword === "include" && peek() === ":") {
      consume();
      result.includes.push((consume() || "").replace(/"/g, ""));
    } else if (peek() === ":") {
      consume();
      if (peek() === "{") {
        consume();
        parseBlock();
      } else {
        consume();
        if (peek() === ";;" || peek() === ";;;")
          consume();
      }
    }
  }
  restoreSqlPlaceholders(result, sqlPlaceholders);
  return result;
}
var PDT_SQL_PREFIX = "__PDT_SQL__:";
function buildSqlTableNameMap(views) {
  const map = {};
  for (const [name, view] of Object.entries(views)) {
    if (!view)
      continue;
    if (view.derived_table) {
      const sql = (view.derived_table.sql || "").replace(/;;\s*$/, "").trim();
      map[name] = PDT_SQL_PREFIX + sql;
    } else if (view.sql_table_name) {
      map[name] = view.sql_table_name.trim();
    }
  }
  let changed = true;
  for (let i = 0; i < 20 && changed; i++) {
    changed = false;
    for (const name of Object.keys(map)) {
      const val = map[name];
      if (!val.includes("${"))
        continue;
      const next = val.replace(/\$\{(\w+)\.SQL_TABLE_NAME\}/gi, (_m, ref) => {
        const refVal = map[ref];
        if (refVal !== void 0 && !refVal.includes("${") && !refVal.startsWith(PDT_SQL_PREFIX))
          return refVal;
        return _m;
      });
      if (next !== val) {
        map[name] = next;
        changed = true;
      }
    }
  }
  return map;
}
function splitLeadingSqlComments(sql) {
  const m = sql.match(/^(?:\s*--[^\n]*\n|\s+)*/);
  const head = m ? m[0] : "";
  return { head, rest: sql.slice(head.length) };
}
function isCteFragment(sql) {
  return splitLeadingSqlComments(sql).rest.startsWith(",");
}
function resolveSqlTableNameRefs(sql, map, warnings, contextViewName) {
  const ctes = [];
  const cteOk = /* @__PURE__ */ new Set();
  const cteSeen = /* @__PURE__ */ new Set();
  const warnedOnce = /* @__PURE__ */ new Set();
  const stack = /* @__PURE__ */ new Set();
  const scratchTable = (ref) => `LOOKER_SCRATCH.${String(ref).toUpperCase()}`;
  const placeholder = (ref) => `${scratchTable(ref)} /* unresolved Looker view: ${ref} */`;
  function resolveBody(body2) {
    return body2.replace(/\$\{(\w+)\.SQL_TABLE_NAME\}/gi, (_m, ref) => {
      const val = map[ref];
      if (val === void 0) {
        if (!warnedOnce.has(ref)) {
          warnedOnce.add(ref);
          warnings.push(`\u{1F536} UNRESOLVED VIEW "${ref}": view "${contextViewName}" references \${${ref}.SQL_TABLE_NAME} but "${ref}" is not in the provided files. Emitted placeholder table ${scratchTable(ref)} \u2014 this SQL will NOT run until you either (a) re-run the conversion with ${ref}.view.lkml included so its SQL is inlined as a CTE, or (b) replace the placeholder with the real warehouse table behind that view (its Looker scratch-schema PDT or underlying source table).`);
        }
        return placeholder(ref);
      }
      if (val.startsWith(PDT_SQL_PREFIX)) {
        if (stack.has(ref)) {
          if (!warnedOnce.has(ref)) {
            warnedOnce.add(ref);
            warnings.push(`\u26A0 View "${contextViewName}": circular \${${ref}.SQL_TABLE_NAME} reference chain \u2014 emitted placeholder table ${scratchTable(ref)}; break the cycle manually (this is the pattern Looker customers inline as CTEs).`);
          }
          return placeholder(ref);
        }
        if (!cteSeen.has(ref)) {
          cteSeen.add(ref);
          stack.add(ref);
          let depSql = val.slice(PDT_SQL_PREFIX.length);
          depSql = resolveBody(depSql);
          stack.delete(ref);
          if (isCteFragment(depSql)) {
            warnings.push(`\u{1F536} View "${contextViewName}": \${${ref}.SQL_TABLE_NAME} resolves to a derived table whose SQL is itself a CTE-continuation fragment (starts with ", <name> AS ("), so it cannot be wrapped in a CTE. Emitted placeholder table ${scratchTable(ref)} \u2014 include that view's own upstream view files, or replace the placeholder manually.`);
          } else {
            ctes.push({ name: ref, sql: depSql });
            cteOk.add(ref);
          }
        }
        return cteOk.has(ref) ? ref : placeholder(ref);
      }
      if (val.includes("${")) {
        if (!warnedOnce.has(ref)) {
          warnedOnce.add(ref);
          warnings.push(`\u{1F536} View "${contextViewName}": \${${ref}.SQL_TABLE_NAME} could not be fully resolved (missing link in the reference chain) \u2014 emitted placeholder table ${scratchTable(ref)}. Provide the missing view file(s) and re-run.`);
        }
        return placeholder(ref);
      }
      return val;
    });
  }
  let body = resolveBody(sql);
  if (ctes.length) {
    const prelude = "WITH " + ctes.map((c) => `${c.name} AS (
${c.sql}
)`).join(",\n");
    const { head, rest } = splitLeadingSqlComments(body);
    if (rest.startsWith(",")) {
      body = head + prelude + "\n" + rest;
      warnings.push(`\u2139 View "${contextViewName}": inlined ${ctes.length} referenced derived view(s) as CTE(s) \u2014 ${ctes.map((c) => c.name).join(", ")} \u2014 completing the view's CTE-continuation fragment.`);
    } else if (/^WITH\b/i.test(rest)) {
      body = head + prelude + ",\n" + rest.replace(/^WITH\b\s*/i, "");
      warnings.push(`\u2139 View "${contextViewName}": inlined ${ctes.length} referenced derived view(s) as CTE(s) \u2014 ${ctes.map((c) => c.name).join(", ")} \u2014 merged into the view's existing WITH clause.`);
    } else {
      body = head + prelude + "\n" + rest;
      warnings.push(`\u2139 View "${contextViewName}": inlined ${ctes.length} referenced derived view(s) as CTE(s) \u2014 ${ctes.map((c) => c.name).join(", ")}.`);
    }
  }
  return body;
}
function maskFormulaStringLiterals(formula) {
  let marker = "@@LIT@@";
  while (formula.includes(marker))
    marker += "@";
  const literals = [];
  const masked = formula.replace(/"(?:[^"\\]|\\.)*"/g, (lit) => {
    const idx = literals.push(lit) - 1;
    return `${marker}${idx}${marker}`;
  });
  const escapedMarker = marker.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const unmaskRe = new RegExp(`${escapedMarker}(\\d+)${escapedMarker}`, "g");
  return { masked, unmask: (s) => s.replace(unmaskRe, (_m, i) => literals[Number(i)]) };
}
function lookExtractPath(view, sqlTableNameMap) {
  let raw = (view.sql_table_name || view.from || "").trim().replace(/`/g, "");
  if (!raw)
    return [];
  if (sqlTableNameMap && raw.includes("${")) {
    raw = raw.replace(/\$\{(\w+)\.SQL_TABLE_NAME\}/gi, (_m, ref) => {
      const val = sqlTableNameMap[ref];
      if (val && !val.startsWith(PDT_SQL_PREFIX) && !val.includes("${"))
        return val;
      return _m;
    });
  }
  if (raw.includes("${"))
    return [];
  return raw.split(".").map((p) => p.trim().toUpperCase()).filter(Boolean);
}
function lookFindColId(elementResult, colName) {
  if (!elementResult)
    return null;
  const upper = (colName || "").toUpperCase();
  return elementResult.colIdMap[upper] || null;
}
function lookParseFilterExpr(expr, columnId) {
  expr = (expr || "").trim();
  if (/^(?:IS\s+)?NULL$/i.test(expr))
    return { id: sigmaShortId(), columnId, kind: "list", mode: "include", values: [null] };
  if (/^(?:(?:IS\s+)?NOT\s+NULL|-NULL)$/i.test(expr))
    return { id: sigmaShortId(), columnId, kind: "list", mode: "exclude", values: [null] };
  if (/^EMPTY$/i.test(expr))
    return { id: sigmaShortId(), columnId, kind: "list", mode: "include", values: [null, ""] };
  if (/^(?:(?:IS\s+)?NOT\s+EMPTY|-EMPTY)$/i.test(expr))
    return { id: sigmaShortId(), columnId, kind: "list", mode: "exclude", values: [null, ""] };
  if (/^\d+\s+(second|minute|hour|day|week|month|quarter|year)s?$/i.test(expr))
    return null;
  if (/^(this|last|next|current)\s+/i.test(expr))
    return null;
  if (/^\d{4}[\/\-]\d{2}/.test(expr))
    return null;
  if (/^[><!]=?/.test(expr))
    return null;
  if (/^[\[(]/.test(expr))
    return null;
  const expandTokens = (v) => /^NULL$/i.test(v) ? [null] : /^EMPTY$/i.test(v) ? [null, ""] : [v];
  if (expr.startsWith("-")) {
    const vals2 = expr.slice(1).split(/\s*,\s*-?\s*/).map((v) => v.replace(/^"|"$/g, "").trim()).filter(Boolean).flatMap(expandTokens);
    return { id: sigmaShortId(), columnId, kind: "list", mode: "exclude", values: vals2 };
  }
  const vals = expr.split(",").map((v) => v.replace(/^"|"$/g, "").trim()).filter(Boolean).flatMap(expandTokens);
  if (vals.length > 0)
    return { id: sigmaShortId(), columnId, kind: "list", mode: "include", values: vals };
  return null;
}
function resolveNdtToSql(ndtViewName, explSource, ctx, warnings) {
  const exploreName = explSource._name || "";
  const explore = ctx.explores[exploreName];
  if (!explore) {
    warnings.push(`\u26A0 View "${ndtViewName}" is a Native Derived Table on explore "${exploreName}", which was not found in the provided files. Rebuild it as a Sigma data element (aggregate the source element) after import.`);
    return { sql: "", resolved: false };
  }
  const baseViewName = explore.from || exploreName;
  const baseView = ctx.views[baseViewName];
  if (!baseView || baseView.derived_table) {
    warnings.push(`\u26A0 View "${ndtViewName}" (NDT on explore "${exploreName}"): base view "${baseViewName}" is not a simple warehouse table \u2014 cannot auto-generate SQL. Rebuild as a Sigma data element after import.`);
    return { sql: "", resolved: false };
  }
  const basePath = lookExtractPath(baseView);
  if (!basePath.length) {
    warnings.push(`\u26A0 View "${ndtViewName}" (NDT on explore "${exploreName}"): could not resolve base table for view "${baseViewName}". Rebuild as a Sigma data element after import.`);
    return { sql: "", resolved: false };
  }
  const fromTable = basePath.join(".");
  const dimMap = /* @__PURE__ */ new Map();
  const dims = baseView.dimension ? Array.isArray(baseView.dimension) ? baseView.dimension : [baseView.dimension] : [];
  for (const d of dims) {
    if (!d._name || !d.sql)
      continue;
    const expr = d.sql.replace(/\$\{TABLE\}\s*\.\s*/gi, "").replace(/;;\s*$/, "").trim();
    if (/\$\{/.test(expr))
      continue;
    dimMap.set(d._name.toLowerCase(), expr);
  }
  const measureMap = /* @__PURE__ */ new Map();
  const measures = baseView.measure ? Array.isArray(baseView.measure) ? baseView.measure : [baseView.measure] : [];
  for (const ms of measures) {
    if (!ms._name)
      continue;
    const t = (ms.type || "").toLowerCase();
    const aggFn = { sum: "SUM", average: "AVG", avg: "AVG", min: "MIN", max: "MAX", count: "COUNT", count_distinct: "COUNT", median: "MEDIAN" };
    if (!aggFn[t])
      continue;
    let col = "*";
    if (ms.sql) {
      const e = ms.sql.replace(/\$\{TABLE\}\s*\.\s*/gi, "").replace(/;;\s*$/, "").trim();
      if (/\$\{(\w+)\}/.test(e)) {
        const refName = e.match(/\$\{(\w+)\}/)[1].toLowerCase();
        col = dimMap.get(refName) || "*";
        if (col === "*")
          continue;
      } else
        col = e;
    } else if (t !== "count")
      continue;
    const distinct = t === "count_distinct" ? "DISTINCT " : "";
    measureMap.set(ms._name.toLowerCase(), { agg: aggFn[t], col: distinct + col });
  }
  const cols = explSource.column ? Array.isArray(explSource.column) ? explSource.column : [explSource.column] : [];
  const selectParts = [];
  const groupByExprs = [];
  let hasMeasure = false;
  let unresolved = false;
  for (const c of cols) {
    const outName = c._name || "";
    const fieldRef = (c.field || c._name || "").trim();
    const fieldName = (fieldRef.includes(".") ? fieldRef.split(".").pop() : fieldRef).toLowerCase();
    const alias = outName ? ` AS "${outName.toUpperCase()}"` : "";
    if (measureMap.has(fieldName)) {
      const m = measureMap.get(fieldName);
      selectParts.push(`${m.agg}(${m.col})${alias}`);
      hasMeasure = true;
    } else if (dimMap.has(fieldName)) {
      const expr = dimMap.get(fieldName);
      selectParts.push(`${expr}${alias}`);
      groupByExprs.push(expr);
    } else {
      unresolved = true;
      break;
    }
  }
  if (unresolved || selectParts.length === 0) {
    warnings.push(`\u26A0 View "${ndtViewName}" (NDT on explore "${exploreName}"): one or more selected columns reference fields that could not be resolved on the base view (joined/derived fields are not supported here). Rebuild this NDT as a Sigma data element that aggregates the "${sigmaDisplayName(exploreName)}" element after import.`);
    return { sql: "", resolved: false };
  }
  let sql = `SELECT
  ${selectParts.join(",\n  ")}
FROM ${fromTable}`;
  if (hasMeasure && groupByExprs.length) {
    sql += `
GROUP BY ${groupByExprs.join(", ")}`;
  }
  warnings.push(`\u2139 View "${ndtViewName}" \u2192 Native Derived Table on explore "${exploreName}" was translated to a Custom SQL element (aggregation pushed to ${fromTable}). Review the generated SQL and consider rebuilding it as a native Sigma data element for full editability.`);
  return { sql, resolved: true };
}
function lookResolveLiquidIf(sql, paramDefaults) {
  if (!/\{%-?\s*if\b/i.test(sql))
    return { sql, resolved: false };
  const ifCount = (sql.match(/\{%-?\s*if\b/gi) || []).length;
  if (ifCount !== 1)
    return { sql, resolved: false };
  const m = sql.match(/\{%-?\s*if\b([\s\S]*?)\{%-?\s*endif\s*-?%\}/i);
  if (!m)
    return { sql, resolved: false };
  const before = sql.slice(0, m.index);
  const after = sql.slice((m.index || 0) + m[0].length);
  const body = "{% if" + m[1];
  const parts = body.split(/\{%-?\s*(?:els?if|elsif|if|else)\b/i);
  const markers = body.match(/\{%-?\s*(elsif|else if|else|if)\b([^%]*?)-?%\}/gi) || [];
  const branches = [];
  let rest = body;
  for (let i = 0; i < markers.length; i++) {
    const marker = markers[i];
    const start = rest.indexOf(marker);
    const bodyStart = start + marker.length;
    const nextMarker = markers[i + 1];
    const bodyEnd = nextMarker ? rest.indexOf(nextMarker, bodyStart) : rest.length;
    const text = rest.slice(bodyStart, bodyEnd).trim();
    const isElse = /\{%-?\s*else\s*-?%\}/i.test(marker);
    const cond = isElse ? null : marker.replace(/\{%-?\s*(elsif|else if|if)\b/i, "").replace(/-?%\}/i, "").trim();
    branches.push({ cond, text });
  }
  const evalCond = (cond) => {
    const cm = cond.match(/([A-Za-z_][A-Za-z0-9_.]*?)(?:\._parameter_value)?\s*(==|!=)\s*['"]?([^'"]*)['"]?\s*$/);
    if (!cm)
      return false;
    const pname = cm[1].split(".").pop().toLowerCase();
    const op = cm[2];
    const want = cm[3].trim();
    const dv = paramDefaults.get(pname);
    if (dv === void 0)
      return false;
    return op === "==" ? dv === want : dv !== want;
  };
  let chosen = branches.find((b) => b.cond !== null && evalCond(b.cond));
  if (!chosen)
    chosen = branches.find((b) => b.cond === null);
  if (!chosen)
    chosen = branches[0];
  if (!chosen)
    return { sql, resolved: false };
  const out = (before + " " + chosen.text + " " + after).replace(/\s+/g, " ").trim();
  if (/\{%/.test(out))
    return { sql, resolved: false };
  return { sql: out, resolved: true };
}
function lookResolveParamSubst(sql, paramDefaults) {
  let changed = false;
  const out = sql.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (full, name) => {
    const dv = paramDefaults.get(name.toLowerCase());
    if (dv !== void 0) {
      changed = true;
      return dv;
    }
    return full;
  });
  return { sql: out, resolved: changed };
}
function lookCollectDynamicParameters(views) {
  const out = [];
  for (const [viewName, view] of Object.entries(views)) {
    const params = view.parameter ? Array.isArray(view.parameter) ? view.parameter : [view.parameter] : [];
    const defaults = /* @__PURE__ */ new Map();
    for (const p of params) {
      if (p?._name && p.default_value != null)
        defaults.set(p._name.toLowerCase(), String(p.default_value));
    }
    const fields = [];
    for (const [kind, raw] of [
      ["dimension", view.dimension],
      ["dimension_group", view.dimension_group],
      ["measure", view.measure]
    ]) {
      const entries = raw ? Array.isArray(raw) ? raw : [raw] : [];
      for (const field of entries) {
        if (field?._name && typeof field.sql === "string")
          fields.push({ kind, field });
      }
    }
    for (const p of params) {
      if (!p?._name)
        continue;
      const allowedRaw = p.allowed_value ? Array.isArray(p.allowed_value) ? p.allowed_value : [p.allowed_value] : [];
      const allowedValues = allowedRaw.map((entry) => ({
        label: String(entry?.label ?? entry?.value ?? entry?._name ?? ""),
        value: String(entry?.value ?? entry?._name ?? "")
      })).filter((entry) => entry.value);
      const affectedFields = [];
      for (const { kind, field } of fields) {
        const sourceSql = field.sql;
        const escaped = p._name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const liquidRef = new RegExp(`\\b${escaped}(?:\\._parameter_value)?\\b`, "i");
        const substRef = new RegExp(`\\$\\{${escaped}\\}`, "i");
        if (!liquidRef.test(sourceSql) && !substRef.test(sourceSql))
          continue;
        const branches = {};
        for (const allowed of allowedValues) {
          const values = new Map(defaults);
          values.set(p._name.toLowerCase(), allowed.value);
          const liquid = lookResolveLiquidIf(sourceSql, values);
          let branchSql = liquid.resolved ? liquid.sql : sourceSql;
          const substituted = lookResolveParamSubst(branchSql, values);
          if (substituted.resolved)
            branchSql = substituted.sql;
          if (!/\{%|\{\{|\$\{(?!TABLE\})[A-Za-z_][A-Za-z0-9_]*\}/i.test(branchSql)) {
            branches[allowed.value] = branchSql.replace(/\s+/g, " ").trim();
          }
        }
        affectedFields.push({
          field: `${viewName}.${field._name}`,
          label: field.label || sigmaDisplayName(field._name),
          kind,
          sourceSql,
          branches,
          deterministic: allowedValues.length > 0 && Object.keys(branches).length === allowedValues.length
        });
      }
      if (affectedFields.length) {
        out.push({
          view: viewName,
          name: p._name,
          type: p.type || "string",
          defaultValue: p.default_value != null ? String(p.default_value) : allowedValues[0]?.value,
          allowedValues,
          affectedFields
        });
      }
    }
  }
  return out;
}
function lookConvertView(viewName, view, connectionId, warnings, sqlTableNameMap, ndtContext) {
  if (!view) {
    warnings.push(`\u26A0 View "${viewName}" not found \u2014 element will have no columns`);
    const id = sigmaShortId();
    return {
      element: { id, kind: "table", source: { connectionId: connectionId || "<CONNECTION_ID>", kind: "warehouse-table", path: [viewName.toUpperCase()] }, columns: [], order: [] },
      elementId: id,
      colIdMap: {}
    };
  }
  const elementId = sigmaShortId();
  let tableName, element;
  if (view.derived_table !== void 0) {
    let rawSql = (view.derived_table.sql || "").replace(/;;\s*$/, "").trim();
    const explSource = Array.isArray(view.derived_table.explore_source) ? view.derived_table.explore_source[0] : view.derived_table.explore_source;
    if (!rawSql && explSource !== void 0 && ndtContext) {
      const ndt = resolveNdtToSql(viewName, explSource, ndtContext, warnings);
      if (ndt.resolved)
        rawSql = ndt.sql;
    } else if (!rawSql && explSource !== void 0) {
      warnings.push(`\u26A0 View "${viewName}" is a Native Derived Table (explore_source) but explore context was unavailable \u2014 rebuild it as a Sigma data element after import.`);
    }
    if (/\{%\s*incrementcondition\s*%\}/i.test(rawSql)) {
      rawSql = rawSql.replace(/\{%\s*incrementcondition\s*%\}([\s\S]*?)\{%\s*endincrementcondition\s*%\}/gi, (_m, inner) => `1=1 /* Looker incremental condition on ${inner.trim()} \u2014 full scan in Sigma */`);
      warnings.push(`\u{1F536} View "${viewName}": incremental-PDT {% incrementcondition %} was replaced with 1=1 \u2014 Sigma always runs the full SQL. Enable scheduled materialization on this element (Materialization tab in the Sigma UI, or via the API) to keep refreshes warehouse-side; the migration skill can hand off to the materialization flow.`);
    }
    if (sqlTableNameMap && rawSql.includes("${")) {
      rawSql = resolveSqlTableNameRefs(rawSql, sqlTableNameMap, warnings, viewName);
    }
    if (rawSql && isCteFragment(rawSql)) {
      const { head, rest } = splitLeadingSqlComments(rawSql);
      rawSql = head + "WITH " + rest.slice(1);
      warnings.push(`\u2139 View "${viewName}": derived SQL was a CTE-continuation fragment (leading ","), expecting Looker to prepend inlined PDT CTEs. Prepended WITH so it parses standalone \u2014 verify the first CTE no longer depends on a missing upstream CTE.`);
    }
    const PERSIST_HINTS = ["datagroup_trigger", "persist_for", "sql_trigger_value"];
    const dt = view.derived_table;
    for (const prop of PERSIST_HINTS) {
      if (dt[prop] !== void 0) {
        const val = typeof dt[prop] === "string" ? dt[prop] : "";
        warnings.push(`\u2139 View "${viewName}": PDT persistence hint "${prop}"${val ? ` (${val})` : ""} maps to Sigma scheduled materialization. Configure a materialization schedule on this data model (Materialization tab in the Sigma UI, or via the API) to get the equivalent refresh cadence.`);
      }
    }
    if (dt.increment_key !== void 0) {
      const off = dt.increment_offset !== void 0 ? `, increment_offset: ${dt.increment_offset}` : "";
      warnings.push(`\u{1F536} View "${viewName}": incremental PDT (increment_key: "${dt.increment_key}"${off}) has no Sigma equivalent \u2014 the converted element re-computes its full SQL on each refresh. Recommend Sigma scheduled materialization on this element (Materialization tab / API; the migration skill can hand off to the materialization flow).`);
    } else if (dt.increment_offset !== void 0) {
      warnings.push(`\u2139 View "${viewName}": increment_offset is set without increment_key \u2014 ignored.`);
    }
    const PDT_SKIP_PROPS = ["distribution", "sortkeys", "persist_with", "cluster_keys", "partition_keys"];
    for (const prop of PDT_SKIP_PROPS) {
      if (dt[prop] !== void 0) {
        warnings.push(`\u2139 View "${viewName}": PDT property "${prop}" is a warehouse-specific materialization hint and is not converted \u2014 configure this in your warehouse or Sigma dataset settings.`);
      }
    }
    tableName = "Custom SQL";
    element = {
      id: elementId,
      kind: "table",
      // Explicit display name: without it Sigma falls back to "Custom SQL" for
      // every sql element, making [Element/Column] refs ambiguous and breaking
      // the orchestrators' name-based element lookup on readback.
      name: view.label || sigmaDisplayName(viewName),
      source: {
        connectionId: connectionId || "<CONNECTION_ID>",
        statement: rawSql || "",
        kind: "sql"
      },
      columns: [],
      metrics: [],
      order: []
    };
    if (rawSql)
      warnings.push(`\u2139 View "${viewName}" \u2192 Custom SQL element. Review the SQL before saving.`);
    else
      warnings.push(`\u26A0 View "${viewName}" derived_table has no sql \u2014 SQL statement left blank. Add SQL manually in the JSON before saving.`);
  } else {
    const path = lookExtractPath(view, sqlTableNameMap);
    tableName = (path[path.length - 1] || viewName).toUpperCase();
    element = {
      id: elementId,
      kind: "table",
      name: view.label || sigmaDisplayName(viewName),
      source: {
        connectionId: connectionId || "<CONNECTION_ID>",
        kind: "warehouse-table",
        path: path.length > 0 ? path : [viewName.toUpperCase()]
      },
      columns: [],
      metrics: [],
      order: []
    };
  }
  const colIdMap = {};
  const isCustomSql = tableName === "Custom SQL";
  const colLabel = (physCol) => isCustomSql ? physCol : sigmaDisplayName(physCol);
  const makeColId = (physCol) => isCustomSql ? sigmaShortId() : sigmaInodeId(physCol);
  const viewSqls = JSON.stringify(view);
  if (/\{%-?\s*(if|unless|for|assign|capture)\b/i.test(viewSqls)) {
    warnings.push(`\u2139 View "${viewName}": contains Liquid templating ({% if %} blocks). Parameter-driven dimensions are resolved to their DEFAULT branch (see per-dimension \u{1F536} notes); any unresolved Liquid is skipped \u2014 review in Sigma.`);
  }
  const yesnoExprMap = /* @__PURE__ */ new Map();
  const fieldDisplayMap = /* @__PURE__ */ new Map();
  const dimPhysColMap = /* @__PURE__ */ new Map();
  {
    const allDims = view.dimension ? Array.isArray(view.dimension) ? view.dimension : [view.dimension] : [];
    allDims.forEach((yd) => {
      if (!yd._name)
        return;
      const lname = yd._name.toLowerCase();
      if ((yd.type || "").toLowerCase() === "yesno" && yd.sql) {
        const expr = yd.sql.replace(/\$\{TABLE\}\s*\.\s*/gi, "").replace(/\$\{[^.}]+\.([^}]+)\}/g, (_, f) => f.toUpperCase()).replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, n) => n.toUpperCase()).trim();
        yesnoExprMap.set(lname, expr);
      } else {
        let displayName;
        if (yd.sql && !lookIsComplexSql(yd.sql)) {
          const stripped = lookStripSql(yd.sql) || yd._name;
          const physCol = stripped.split(".").pop().replace(/"/g, "").toUpperCase();
          displayName = colLabel(physCol);
          dimPhysColMap.set(lname, physCol);
        } else {
          displayName = yd.label || sigmaDisplayName(yd._name);
        }
        fieldDisplayMap.set(lname, displayName);
      }
    });
  }
  const physColDisplays = /* @__PURE__ */ new Set();
  {
    const allDims = view.dimension ? Array.isArray(view.dimension) ? view.dimension : [view.dimension] : [];
    const allGroups = view.dimension_group ? Array.isArray(view.dimension_group) ? view.dimension_group : [view.dimension_group] : [];
    const scan = (sql) => {
      const re = /\$\{TABLE\}\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)/gi;
      let m;
      while ((m = re.exec(sql || "")) !== null)
        physColDisplays.add(colLabel(m[1].toUpperCase()));
    };
    allDims.forEach((d) => {
      scan(d.sql);
      if (d.case)
        JSON.stringify(d.case).replace(/\$\{TABLE\}\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)/gi, (_, c) => {
          physColDisplays.add(colLabel(c.toUpperCase()));
          return "";
        });
    });
    allGroups.forEach((g) => {
      scan(g.sql);
      scan(g.sql_start);
      scan(g.sql_end);
    });
  }
  function qualifyPhysRefs(formula) {
    return formula.replace(/\[([^\]\/]+)\]/g, (m, disp) => physColDisplays.has(disp) ? `[${tableName}/${disp}]` : m);
  }
  function expandFieldRefs(sql) {
    if (!yesnoExprMap.size && !fieldDisplayMap.size)
      return sql;
    return sql.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (match, n) => {
      const lname = n.toLowerCase();
      const yesnoExpr = yesnoExprMap.get(lname);
      if (yesnoExpr !== void 0)
        return `(${yesnoExpr})`;
      const displayName = fieldDisplayMap.get(lname);
      if (displayName !== void 0)
        return `[${displayName}]`;
      return match;
    });
  }
  const paramDefaults = /* @__PURE__ */ new Map();
  {
    const params = view.parameter ? Array.isArray(view.parameter) ? view.parameter : [view.parameter] : [];
    for (const p of params) {
      if (p && p._name && p.default_value != null && p.default_value !== "") {
        paramDefaults.set(p._name.toLowerCase(), String(p.default_value));
      }
    }
  }
  const dims = view.dimension ? Array.isArray(view.dimension) ? view.dimension : [view.dimension] : [];
  for (const d of dims) {
    if (!d._name)
      continue;
    const colName = d._name.toUpperCase();
    const dFormat = lookmlFieldFormat(d, warnings);
    if (d.sql && /\{%-?\s*if\b/i.test(d.sql)) {
      const liq = lookResolveLiquidIf(d.sql, paramDefaults);
      if (liq.resolved) {
        d.sql = liq.sql;
        warnings.push(`\u{1F536} "${d._name}": Liquid {% if %} field-picker resolved to the parameter DEFAULT branch (\u2192 ${liq.sql.replace(/\s+/g, " ").trim().slice(0, 60)}). To reproduce the dynamic dropdown, add a Sigma parameter control and a Switch()/If() over its value.`);
      }
    }
    if (d.sql && !/\$\{TABLE\}/i.test(d.sql)) {
      const sub = lookResolveParamSubst(d.sql, paramDefaults);
      if (sub.resolved) {
        d.sql = sub.sql;
        warnings.push(`\u{1F536} "${d._name}": LookML parameter \${...} substituted with its DEFAULT value (\u2192 ${sub.sql.replace(/\s+/g, " ").trim().slice(0, 60)}). To reproduce the dynamic behavior, add a Sigma parameter control.`);
      }
    }
    if (d.case && typeof d.case === "object") {
      const whens = Array.isArray(d.case.when) ? d.case.when : d.case.when ? [d.case.when] : [];
      const toCond = (sql) => lookConvertExpression((sql || "").replace(/\$\{TABLE\}\./gi, "").replace(/\$\{[^.}]+\.([^}]+)\}/g, "$1").replace(/[\r\n]+\s*/g, " ").trim());
      let formula = d.case.else != null ? `"${String(d.case.else)}"` : "Null";
      for (let i = whens.length - 1; i >= 0; i--) {
        const w = whens[i];
        if (typeof w !== "object" || !w.sql)
          continue;
        formula = `If(${qualifyPhysRefs(toCond(w.sql))}, "${String(w.label ?? w._name ?? "")}", ${formula})`;
      }
      const caseColId = sigmaShortId();
      colIdMap[colName] = caseColId;
      element.columns.push({ id: caseColId, formula, name: d.label || sigmaDisplayName(d._name) });
      element.order.push(caseColId);
      warnings.push(`\u2705 "${d._name}" (case) \u2192 ${formula.slice(0, 70)}`);
      continue;
    }
    if ((d.type || "").toLowerCase() === "tier" && Array.isArray(d.tiers) && d.tiers.length) {
      const tiers = d.tiers.map((t) => Number(t)).filter((n) => !Number.isNaN(n));
      if (tiers.length) {
        const physCol = (lookStripSql(d.sql) || colName).split(".").pop().replace(/"/g, "").toUpperCase();
        const ref = `[${tableName}/${colLabel(physCol)}]`;
        const allInt = tiers.every((t) => Number.isInteger(t));
        const lbl = (lo, hi) => allInt ? `${lo} to ${hi - 1}` : `${lo} to ${hi}`;
        let formula = `"${tiers[tiers.length - 1]} or Above"`;
        for (let i = tiers.length - 2; i >= 0; i--) {
          formula = `If(${ref} < ${tiers[i + 1]}, "${lbl(tiers[i], tiers[i + 1])}", ${formula})`;
        }
        formula = `If(${ref} < ${tiers[0]}, "Below ${tiers[0]}", ${formula})`;
        const tierColId = sigmaShortId();
        colIdMap[colName] = tierColId;
        element.columns.push({ id: tierColId, formula, name: d.label || sigmaDisplayName(d._name) });
        element.order.push(tierColId);
        const style = (d.style || "classic").toLowerCase();
        if (style !== "integer")
          warnings.push(`\u2139 "${d._name}" (tier, style: ${style}) \u2192 If() buckets emitted with integer-style labels ("lo to hi-1"); verify the labels match Looker's ${style} style and adjust if needed.`);
        else
          warnings.push(`\u2705 "${d._name}" (tier) \u2192 ${formula.slice(0, 70)}\u2026`);
        continue;
      }
    }
    if (/\$\{[^.}]+\}/.test(d.sql || "") && !/\$\{TABLE\}/i.test(d.sql || "")) {
      warnings.push(`\u26A0 "${d._name}": uses LookML parameter substitution \u2014 skipped. Add this dimension manually after configuring parameters in Sigma.`);
      continue;
    }
    if (lookIsComplexSql(d.sql)) {
      const cleanedSql = (d.sql || "").replace(/\$\{TABLE\}\./gi, "").replace(/\$\{[^.}]+\.([^}]+)\}/g, "$1").trim();
      const boolMatch = cleanedSql.match(/^([A-Z_][A-Z0-9_]*)\s*=\s*(\d+)$/i);
      if (boolMatch) {
        const physicalCol2 = boolMatch[1].toUpperCase();
        const val = boolMatch[2];
        let physColId = colIdMap[physicalCol2];
        if (!physColId) {
          physColId = makeColId(physicalCol2);
          colIdMap[physicalCol2] = physColId;
          element.columns.push({ id: physColId, formula: `[${tableName}/${colLabel(physicalCol2)}]` });
          element.order.push(physColId);
        }
        const calcId = sigmaShortId();
        colIdMap[colName] = calcId;
        const baseName = d.label || sigmaDisplayName(d._name);
        const displayName = baseName + " (T-F)";
        element.columns.push({ id: calcId, formula: `[${tableName}/${colLabel(physicalCol2)}] = ${val}`, name: displayName });
        element.order.push(calcId);
        continue;
      }
      const unsupported = detectUnsupportedSigmaFunction(d.sql || "");
      if (unsupported) {
        warnings.push(`\u26A0 "${d._name}": skipped \u2014 contains ${unsupported}() which has no Sigma equivalent. Add this column manually in the Sigma UI.`);
        continue;
      }
      const colId2 = sigmaShortId();
      colIdMap[colName] = colId2;
      const expandedSql = expandFieldRefs(d.sql || "");
      let sigmaFormula = lookSqlToSigmaRules(expandedSql);
      if (!sigmaFormula) {
        const stripped = expandedSql.replace(/\$\{TABLE\}\./gi, "").replace(/\$\{[^.}]+\.([^}]+)\}/g, (_, f) => f.toUpperCase()).replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, n) => n.toUpperCase()).replace(/[\r\n]+\s*/g, " ").trim();
        if (/^[A-Za-z_][A-Za-z0-9_]*\s*\(/.test(stripped)) {
          sigmaFormula = lookConvertExpression(stripped);
        }
      }
      if (sigmaFormula) {
        sigmaFormula = qualifyPhysRefs(sigmaFormula);
        element.columns.push({ id: colId2, formula: sigmaFormula, name: d.label || sigmaDisplayName(d._name), ...dFormat ? { format: dFormat } : {} });
        element.order.push(colId2);
        warnings.push(`\u2139 "${d._name}" \u2192 calculated column: ${sigmaFormula}`);
      } else {
        element.columns.push({ id: colId2, formula: `[${tableName}/${sigmaDisplayName(colName)}]`, name: d.label || sigmaDisplayName(d._name), ...dFormat ? { format: dFormat } : {} });
        element.order.push(colId2);
        warnings.push(`\u26A0 "${d._name}": could not auto-convert. Edit formula manually.`);
      }
      continue;
    }
    const sqlCol = lookStripSql(d.sql) || colName;
    const physicalCol = sqlCol.split(".").pop().replace(/"/g, "").toUpperCase();
    if (colIdMap[physicalCol]) {
      colIdMap[colName] = colIdMap[physicalCol];
      continue;
    }
    const colId = makeColId(physicalCol);
    colIdMap[colName] = colId;
    colIdMap[physicalCol] = colId;
    if (isCustomSql) {
      element.columns.push({ id: colId, formula: `[${tableName}/${colLabel(physicalCol)}]`, name: d.label || sigmaDisplayName(d._name), ...dFormat ? { format: dFormat } : {} });
    } else {
      element.columns.push({ id: colId, formula: `[${tableName}/${colLabel(physicalCol)}]`, ...dFormat ? { format: dFormat } : {} });
    }
    element.order.push(colId);
  }
  const TIMEFRAME_MAP = {
    raw: { suffix: "Raw", formula: (ref) => ref },
    time: { suffix: "Time", formula: (ref) => ref },
    date: { suffix: "Date", formula: (ref) => `DateTrunc("day", ${ref})` },
    week: { suffix: "Week", formula: (ref) => `DateTrunc("week", ${ref})` },
    month: { suffix: "Month", formula: (ref) => `DateTrunc("month", ${ref})` },
    quarter: { suffix: "Quarter", formula: (ref) => `DateTrunc("quarter", ${ref})` },
    year: { suffix: "Year", formula: (ref) => `DateTrunc("year", ${ref})` }
  };
  const DEFAULT_TIMEFRAMES = ["raw", "time", "date", "week", "month", "quarter", "year"];
  const dimGroups = view.dimension_group ? Array.isArray(view.dimension_group) ? view.dimension_group : [view.dimension_group] : [];
  dimGroups.forEach((dg) => {
    if (!dg._name)
      return;
    const colName = dg._name.toUpperCase();
    const dgType = (dg.type || "time").toLowerCase();
    if (dgType === "duration") {
      if (!dg.sql_start || !dg.sql_end) {
        warnings.push(`\u26A0 Duration group "${dg._name}": missing sql_start/sql_end \u2014 skipped.`);
        return;
      }
      const normStart = (dg.sql_start || "").replace(/\$\{TABLE\}\s*\.\s*/gi, "").trim();
      const normEnd = (dg.sql_end || "").replace(/\$\{TABLE\}\s*\.\s*/gi, "").trim();
      const startCol = (normStart.match(/^([A-Za-z_][A-Za-z0-9_]*)/) || ["", ""])[1].toUpperCase() || lookStripSql(dg.sql_start).split(".").pop().replace(/"/g, "").toUpperCase();
      const endCol = (normEnd.match(/^([A-Za-z_][A-Za-z0-9_]*)/) || ["", ""])[1].toUpperCase() || lookStripSql(dg.sql_end).split(".").pop().replace(/"/g, "").toUpperCase();
      for (const pc of [startCol, endCol]) {
        if (pc && !colIdMap[pc]) {
          const cid = makeColId(pc);
          colIdMap[pc] = cid;
          element.columns.push({ id: cid, formula: `[${tableName}/${colLabel(pc)}]` });
          element.order.push(cid);
        }
      }
      const startRef = `[${tableName}/${colLabel(startCol)}]`;
      const endRef = `[${tableName}/${colLabel(endCol)}]`;
      const DG_DURATION = {
        second: "second",
        minute: "minute",
        hour: "hour",
        day: "day",
        week: "week",
        month: "month",
        quarter: "quarter",
        year: "year"
      };
      const intervals = Array.isArray(dg.intervals) ? dg.intervals.map((i) => String(i).toLowerCase()) : ["day"];
      const folderItems2 = [];
      intervals.forEach((interval) => {
        const prec = DG_DURATION[interval];
        if (!prec)
          return;
        const durColId = sigmaShortId();
        const durColName = `${colName}_${interval.toUpperCase()}S`;
        colIdMap[durColName] = durColId;
        element.columns.push({
          id: durColId,
          formula: `DateDiff("${prec}", ${startRef}, ${endRef})`,
          name: sigmaDisplayName(durColName)
        });
        element.order.push(durColId);
        folderItems2.push(durColId);
      });
      if (folderItems2.length > 0) {
        if (!element.folders)
          element.folders = [];
        element.folders.push({
          id: sigmaShortId(),
          name: sigmaDisplayName(dg._name),
          items: folderItems2
        });
      }
      return;
    }
    if (/\$\{[^.}]+\}/.test(dg.sql || "") && !/\$\{TABLE\}/i.test(dg.sql || "")) {
      warnings.push(`\u26A0 "${dg._name}": uses LookML parameter substitution \u2014 skipped. Add this dimension manually after configuring parameters in Sigma.`);
      return;
    }
    if (lookIsComplexSql(dg.sql)) {
      warnings.push(`\u26A0 Dimension group "${dg._name}": complex expression \u2014 skipped.`);
      return;
    }
    const sqlCol = lookStripSql(dg.sql) || colName;
    const physicalCol = sqlCol.split(".").pop().replace(/"/g, "").toUpperCase();
    const rawTimeframes = dg.timeframes ? (Array.isArray(dg.timeframes) ? dg.timeframes : [dg.timeframes]).map((t) => (t.field || t).toLowerCase()) : DEFAULT_TIMEFRAMES;
    const timeframes = rawTimeframes.filter((t) => TIMEFRAME_MAP[t]);
    const displayBase = sigmaDisplayName(dg._name);
    const colRef = `[${tableName}/${colLabel(physicalCol)}]`;
    dimPhysColMap.set(dg._name.toLowerCase(), physicalCol);
    rawTimeframes.forEach((tf) => dimPhysColMap.set(`${dg._name}_${tf}`.toLowerCase(), physicalCol));
    const existingId = colIdMap[physicalCol];
    const rawColId = existingId || makeColId(physicalCol);
    colIdMap[colName] = rawColId;
    colIdMap[physicalCol] = rawColId;
    if (timeframes.length <= 1) {
      if (timeframes[0])
        colIdMap[`${colName}_${timeframes[0].toUpperCase()}`] = rawColId;
      if (!existingId) {
        element.columns.push({ id: rawColId, formula: colRef });
        element.order.push(rawColId);
      }
      return;
    }
    const folderItems = [];
    let rawEmitted = !!existingId;
    timeframes.forEach((tf) => {
      const { suffix, formula } = TIMEFRAME_MAP[tf];
      const tfFormula = formula(colRef);
      const tfName = `${displayBase} ${suffix}`;
      if (tf === "raw" || tf === "time") {
        if (!rawEmitted) {
          colIdMap[`${colName}_${tf.toUpperCase()}`] = rawColId;
          element.columns.push({ id: rawColId, formula: colRef, name: tfName });
          folderItems.push(rawColId);
          rawEmitted = true;
        } else {
          const dupId = sigmaShortId();
          colIdMap[`${colName}_${tf.toUpperCase()}`] = dupId;
          element.columns.push({ id: dupId, formula: colRef, name: tfName });
          folderItems.push(dupId);
          element.order.push(dupId);
        }
      } else {
        const tfId = sigmaShortId();
        colIdMap[`${colName}_${tf.toUpperCase()}`] = tfId;
        element.columns.push({ id: tfId, formula: tfFormula, name: tfName });
        folderItems.push(tfId);
        element.order.push(tfId);
      }
    });
    if (!rawEmitted) {
      element.columns.push({ id: rawColId, formula: colRef, name: `${displayBase} Raw` });
      folderItems.push(rawColId);
      rawEmitted = true;
    }
    if (!element.folders)
      element.folders = [];
    element.folders.push({ id: sigmaShortId(), name: displayBase, items: folderItems });
    if (!existingId)
      element.order.push(rawColId);
  });
  const measures = view.measure ? Array.isArray(view.measure) ? view.measure : [view.measure] : [];
  const CALC_COL_MEASURE_TYPES = /* @__PURE__ */ new Set(["running_total", "percent_of_total"]);
  const measurePhysCol = (ms) => {
    const resolved = (ms.sql || "").replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (m, r) => dimPhysColMap.get(r.toLowerCase()) ?? m);
    const sc = lookStripSql(resolved) || (ms._name || "").toUpperCase();
    return sc.split(".").pop().replace(/"/g, "").toUpperCase();
  };
  const filterCondition = (ms) => {
    const fl = Array.isArray(ms.filters) ? ms.filters : ms.filters ? [ms.filters] : [];
    const conds = [];
    for (const f of fl) {
      if (typeof f !== "object" || !f)
        continue;
      const ff = f.field || f._name, fv = f.value;
      if (!ff || fv == null)
        continue;
      const dn = colLabel(ff.replace(/^.*\./, "").toUpperCase());
      if (fv === "yes" || fv === "true")
        conds.push(`[${dn}] = True`);
      else if (fv === "no" || fv === "false")
        conds.push(`[${dn}] = False`);
      else
        conds.push(`[${dn}] = "${fv}"`);
    }
    if (!conds.length)
      return null;
    return conds.length === 1 ? conds[0] : conds.map((c) => `(${c})`).join(" And ");
  };
  const simpleMeasureFormula = (ms) => {
    const t = (ms.type || "count").toLowerCase();
    const dn = colLabel(measurePhysCol(ms));
    const cond = filterCondition(ms);
    if (cond) {
      const m = {
        sum: `SumIf([${dn}], ${cond})`,
        count: `CountIf(${cond})`,
        count_distinct: `CountDistinctIf([${dn}], ${cond})`,
        average: `AvgIf([${dn}], ${cond})`,
        max: `MaxIf([${dn}], ${cond})`,
        min: `MinIf([${dn}], ${cond})`
      };
      return m[t] || `SumIf([${dn}], ${cond})`;
    }
    if (t === "count")
      return "Count()";
    if (t === "count_distinct")
      return `CountDistinct([${dn}])`;
    if (t === "percentile")
      return `Percentile([${dn}], ${(Number(ms.percentile) || 50) / 100})`;
    if (["sum", "average", "median", "min", "max", "average_distinct", "sum_distinct", "list"].includes(t))
      return lookSigmaMetric(t, measurePhysCol(ms));
    return null;
  };
  const measureSigmaFormula = /* @__PURE__ */ new Map();
  measures.forEach((ms) => {
    if (!ms._name)
      return;
    const f = simpleMeasureFormula(ms);
    if (f)
      measureSigmaFormula.set(ms._name.toLowerCase(), f);
  });
  measures.forEach((ms) => {
    if (!ms._name)
      return;
    const msName = ms._name.toUpperCase();
    const resolvedMsSql = (ms.sql || "").replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (match, refName) => dimPhysColMap.get(refName.toLowerCase()) ?? match);
    const sqlCol = lookStripSql(resolvedMsSql) || msName;
    const physicalCol = sqlCol.split(".").pop().replace(/"/g, "").toUpperCase() || msName.replace(/"/g, "");
    const msType = (ms.type || "count").toLowerCase();
    const msLabel = ms.label || sigmaDisplayName(msName);
    const msFormat = lookmlFieldFormat(ms, warnings) ?? (msType === "percent_of_total" ? { kind: "number", formatString: ",.1%" } : void 0);
    {
      const tcm = resolvedMsSql.trim().replace(/;;\s*$/, "").match(/^TO_(?:CHAR|VARCHAR)\s*\(\s*(SUM|AVG|MIN|MAX|MEDIAN|COUNT)\s*\(\s*(?:\$\{TABLE\}\s*\.\s*)?("?[A-Za-z_][A-Za-z0-9_]*"?)\s*\)\s*,\s*'([^']+)'\s*\)$/i);
      const tcFmt = tcm ? snowflakeNumericMaskFormat(tcm[3]) : null;
      if (tcm && tcFmt) {
        const fnMap = { sum: "Sum", avg: "Avg", min: "Min", max: "Max", median: "Median", count: "Count" };
        const pc = tcm[2].replace(/"/g, "").toUpperCase();
        if (!colIdMap[pc]) {
          const colId = makeColId(pc);
          colIdMap[pc] = colId;
          element.columns.push({ id: colId, formula: `[${tableName}/${colLabel(pc)}]` });
          element.order.push(colId);
        }
        const formula = `${fnMap[tcm[1].toLowerCase()]}([${colLabel(pc)}])`;
        element.metrics.push({ id: sigmaShortId(), formula, name: msLabel, format: msFormat ?? tcFmt });
        warnings.push(`\u2705 "${ms._name}" (TO_CHAR display mask) \u2192 ${formula} + Sigma column format "${(msFormat ?? tcFmt).formatString}" \u2014 value stays numeric, display matches the mask`);
        return;
      }
    }
    if (["date", "datetime", "date_time", "time"].includes(msType)) {
      const am = resolvedMsSql.trim().replace(/;;\s*$/, "").match(/^(MAX|MIN)\s*\(\s*(?:\$\{TABLE\}\s*\.\s*)?("?[A-Za-z_][A-Za-z0-9_]*"?)\s*\)$/i);
      if (am) {
        const fn = am[1].toUpperCase() === "MAX" ? "Max" : "Min";
        const pc = am[2].replace(/"/g, "").toUpperCase();
        if (!colIdMap[pc]) {
          const colId = makeColId(pc);
          colIdMap[pc] = colId;
          element.columns.push({ id: colId, formula: `[${tableName}/${colLabel(pc)}]` });
          element.order.push(colId);
        }
        element.metrics.push({ id: sigmaShortId(), formula: `${fn}([${colLabel(pc)}])`, name: msLabel, ...msFormat ? { format: msFormat } : {} });
        warnings.push(`\u2705 "${ms._name}" (${msType}) \u2192 ${fn}([${colLabel(pc)}])`);
      } else {
        warnings.push(`\u26A0 "${ms._name}": measure type "${msType}" with sql "${(ms.sql || "").trim().replace(/\s+/g, " ").slice(0, 80)}" could not be translated \u2014 add this metric manually in Sigma.`);
      }
      return;
    }
    if (CALC_COL_MEASURE_TYPES.has(msType)) {
      if (!colIdMap[physicalCol]) {
        const colId = makeColId(physicalCol);
        colIdMap[physicalCol] = colId;
        element.columns.push({ id: colId, formula: `[${tableName}/${colLabel(physicalCol)}]` });
        element.order.push(colId);
      }
      const dn = colLabel(physicalCol);
      const calcId = sigmaShortId();
      if (msType === "running_total") {
        element.columns.push({ id: calcId, formula: `CumulativeSum([${dn}])`, name: msLabel, ...msFormat ? { format: msFormat } : {} });
        warnings.push(`\u2705 "${ms._name}" (running_total) \u2192 CumulativeSum([${dn}])`);
      } else {
        element.columns.push({ id: calcId, formula: `Sum([${dn}]) / GrandTotal(Sum([${dn}]))`, name: msLabel, ...msFormat ? { format: msFormat } : {} });
        warnings.push(`\u2705 "${ms._name}" (percent_of_total) \u2192 Sum/GrandTotal`);
      }
      element.order.push(calcId);
      return;
    }
    const measureRefs = [...(ms.sql || "").matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g)].map((mm) => mm[1].toLowerCase());
    const refsOtherMeasure = measureRefs.some((r) => measureSigmaFormula.has(r));
    const isComputed = !ms.filters && (refsOtherMeasure || msType === "number" && ms.sql && lookIsComplexSql(ms.sql));
    if (isComputed) {
      let expr = ms.sql || "";
      expr = expr.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (m, r) => {
        const mf = measureSigmaFormula.get(r.toLowerCase());
        if (mf)
          return `(${mf})`;
        const phys = dimPhysColMap.get(r.toLowerCase());
        return phys ? `[${colLabel(phys.toUpperCase())}]` : m;
      });
      expr = expr.replace(/\bNULLIF\s*\(/gi, "NullIf(").replace(/\b(COALESCE|NVL|IFNULL)\s*\(/gi, "Coalesce(").replace(/\b(IFF|IIF)\s*\(/gi, "If(");
      const RAW_FN = /\b(TO_CHAR|TO_VARCHAR|TO_NUMBER|TO_DATE|LISTAGG|DECODE)\s*\(/i;
      const hasRawFn = RAW_FN.test(expr);
      const hasConcatOp = /\|\|/.test(expr);
      const hasCast = /::\s*\w+/.test(expr);
      const hasCase = /\bCASE\b[\s\S]*\bWHEN\b/i.test(expr);
      if (hasRawFn || hasConcatOp || hasCast || hasCase) {
        let viaRules = null;
        if (hasCase && !hasRawFn && !hasConcatOp && !hasCast) {
          viaRules = lookSqlToSigmaRules(expr.replace(/--[^\n]*/g, ""));
          if (viaRules && (/\b(CASE|WHEN|THEN)\b|\|\||::\s*\w/i.test(viaRules) || hasResidualInfixOperator(viaRules)))
            viaRules = null;
        }
        if (viaRules) {
          element.metrics.push({ id: sigmaShortId(), formula: viaRules.trim(), name: msLabel, ...msFormat ? { format: msFormat } : {} });
          warnings.push(`\u2705 "${ms._name}" (computed CASE) \u2192 ${viaRules.trim().slice(0, 70)}`);
          return;
        }
        const fragMatch = expr.match(/\b(?:TO_CHAR|TO_VARCHAR|TO_NUMBER|TO_DATE|LISTAGG|DECODE)\s*\([^()]*(?:\([^()]*\)[^()]*)*\)/i);
        const frag = (fragMatch ? fragMatch[0] : expr.replace(/--[^\n]*/g, " ").replace(/\s+/g, " ").trim().slice(0, 110)).trim();
        const hint = /TO_CHAR|TO_VARCHAR/i.test(expr) ? " TO_CHAR display masks have no Sigma formula equivalent \u2014 keep the underlying numeric metric and apply a Sigma column format instead." : " Recreate this metric manually in Sigma.";
        warnings.push(`\u26A0 "${ms._name}": measure could not be translated \u2014 untranslatable fragment: ${frag}${hint}`);
        return;
      }
      element.metrics.push({ id: sigmaShortId(), formula: expr.trim(), name: msLabel, ...msFormat ? { format: msFormat } : {} });
      warnings.push(`\u2705 "${ms._name}" (computed) \u2192 ${expr.trim().slice(0, 70)}`);
      return;
    }
    if (ms.filters && (Array.isArray(ms.filters) ? ms.filters.length : false)) {
      const filters = Array.isArray(ms.filters) ? ms.filters : [];
      const conditions = [];
      for (const f of filters) {
        if (typeof f !== "object" || !f)
          continue;
        const fField = f.field || f._name;
        const fVal = f.value;
        if (fField && fVal) {
          const cleanField = fField.replace(/^.*\./, "").toUpperCase();
          const dn = colLabel(cleanField);
          if (!colIdMap[cleanField]) {
            const colId = makeColId(cleanField);
            colIdMap[cleanField] = colId;
            element.columns.push({ id: colId, formula: `[${tableName}/${dn}]` });
            element.order.push(colId);
          }
          if (fVal === "yes" || fVal === "true")
            conditions.push(`[${dn}] = True`);
          else if (fVal === "no" || fVal === "false")
            conditions.push(`[${dn}] = False`);
          else
            conditions.push(`[${dn}] = "${fVal}"`);
        }
      }
      if (conditions.length > 0) {
        const condition = conditions.length === 1 ? conditions[0] : conditions.map((c) => `(${c})`).join(" And ");
        if (msType !== "count" && !colIdMap[physicalCol]) {
          const colId = makeColId(physicalCol);
          colIdMap[physicalCol] = colId;
          element.columns.push({ id: colId, formula: `[${tableName}/${colLabel(physicalCol)}]` });
          element.order.push(colId);
        }
        const dn = colLabel(physicalCol);
        const condAggMap = {
          sum: `SumIf([${dn}], ${condition})`,
          count: `CountIf(${condition})`,
          count_distinct: `CountDistinctIf([${dn}], ${condition})`,
          average: `AvgIf([${dn}], ${condition})`,
          max: `MaxIf([${dn}], ${condition})`,
          min: `MinIf([${dn}], ${condition})`
        };
        const formula = condAggMap[msType] || `SumIf([${dn}], ${condition})`;
        element.metrics.push({ id: sigmaShortId(), formula, name: msLabel, ...msFormat ? { format: msFormat } : {} });
        warnings.push(`\u2705 Filtered "${ms._name}" \u2192 ${formula.slice(0, 60)}`);
        return;
      }
      warnings.push(`\u26A0 "${ms._name}": filters not parsed \u2014 metric created without filter`);
    }
    if (msType === "count") {
      element.metrics.push({ id: sigmaShortId(), formula: "Count()", name: msLabel, ...msFormat ? { format: msFormat } : {} });
    } else if (msType === "count_distinct") {
      const cdCol = physicalCol && physicalCol !== msName ? physicalCol : msName;
      if (!colIdMap[cdCol]) {
        const colId = makeColId(cdCol);
        colIdMap[cdCol] = colId;
        element.columns.push({ id: colId, formula: `[${tableName}/${colLabel(cdCol)}]` });
        element.order.push(colId);
      }
      element.metrics.push({ id: sigmaShortId(), formula: `CountDistinct([${colLabel(cdCol)}])`, name: msLabel, ...msFormat ? { format: msFormat } : {} });
    } else {
      const FN_HEADS = /* @__PURE__ */ new Set(["MAX", "MIN", "SUM", "AVG", "COUNT", "CASE", "CAST", "COALESCE", "NULLIF", "IFF", "TO_CHAR", "TO_NUMBER", "TO_DATE", "ROUND", "ABS", "CONCAT"]);
      if (/\$\{(?!TABLE\})[^.}]+\}/.test(resolvedMsSql) || ms.sql && FN_HEADS.has(physicalCol) && /\(/.test(ms.sql)) {
        warnings.push(`\u26A0 "${ms._name}": measure sql "${(ms.sql || "").trim().replace(/\s+/g, " ").slice(0, 80)}" could not be resolved to a column \u2014 add this metric manually in Sigma.`);
        return;
      }
      if (!colIdMap[physicalCol]) {
        const colId = makeColId(physicalCol);
        colIdMap[physicalCol] = colId;
        element.columns.push({ id: colId, formula: `[${tableName}/${colLabel(physicalCol)}]` });
        element.order.push(colId);
      }
      const dn = colLabel(physicalCol);
      const formula = msType === "percentile" ? `Percentile([${dn}], ${(Number(ms.percentile) || 50) / 100})` : lookSigmaMetric(msType, physicalCol);
      element.metrics.push({ id: sigmaShortId(), formula, name: msLabel, ...msFormat ? { format: msFormat } : {} });
    }
  });
  const pkDims = dims.filter((d) => d && d._name && /^(yes|true)$/i.test(String(d.primary_key ?? "")));
  if (pkDims.length) {
    const ukIds = [];
    const unresolved = [];
    for (const d of pkDims) {
      const id = colIdMap[d._name.toUpperCase()];
      if (id) {
        if (!ukIds.includes(id))
          ukIds.push(id);
      } else
        unresolved.push(d._name);
    }
    if (ukIds.length)
      element.uniqueKeys = ukIds;
    if (unresolved.length) {
      warnings.push(`\u26A0 View "${viewName}": primary_key dimension(s) ${unresolved.join(", ")} did not resolve to a column \u2014 uniqueKeys is incomplete, so fan-out safety on this table is not guaranteed. Set the unique key manually in Sigma.`);
    }
  } else {
    warnings.push(`\u26A0 View "${viewName}": no \`primary_key: yes\` dimension, so the table's grain is undeclared and no uniqueKeys could be emitted. Aggregations reaching this table through a relationship may fan out. Declare the unique key on the element in Sigma.`);
  }
  const sdkMeasures = measures.filter((m) => m && m.sql_distinct_key);
  if (sdkMeasures.length) {
    const spanning = /* @__PURE__ */ new Set();
    for (const m of sdkMeasures) {
      for (const ref of String(m.sql_distinct_key).matchAll(/\$\{([A-Za-z_0-9]+)\.[A-Za-z_0-9]+\}/g)) {
        if (ref[1] !== "TABLE" && ref[1] !== viewName)
          spanning.add(ref[1]);
      }
    }
    if (spanning.size) {
      warnings.push(`\u2139 View "${viewName}": ${sdkMeasures.length} measure(s) use \`sql_distinct_key\` at a grain spanning other view(s) (${[...spanning].join(", ")}) \u2014 a join-expanded de-dup that element-level uniqueKeys cannot express. These measures were converted as ordinary aggregates; re-verify them against the relationship grain, and note that removing the fan-out at its source may make the de-dup unnecessary.`);
    } else {
      warnings.push(`\u2139 View "${viewName}": ${sdkMeasures.length} measure(s) use \`sql_distinct_key\` over local columns only \u2014 confirm it matches the emitted uniqueKeys.`);
    }
  }
  if (element.metrics.length === 0)
    delete element.metrics;
  return { element, elementId, colIdMap };
}
function convertLookMLToSigma(files, options = {}) {
  resetIds();
  const { connectionId = "", joinStrategy = "auto" } = options;
  const views = {};
  const explores = {};
  const warnings = [];
  const security = [];
  for (const file of files) {
    const isModel = file.name.endsWith(".model.lkml") || file.name.includes(".model.");
    try {
      const parsed = parseLookML(file.content);
      if (isModel) {
        parsed.explores.forEach((ex) => {
          explores[ex._name] = ex;
        });
      }
      parsed.views.forEach((v) => {
        views[v._name] = v;
      });
      if (parsed.includes.length > 0) {
        warnings.push(`\u2139 "${file.name}": contains include: directive(s) \u2014 ${parsed.includes.join(", ")} \u2014 cross-file resolution is not supported. Pass all referenced view files explicitly.`);
      }
    } catch (e) {
      throw new Error(`Parse error in ${file.name}: ${e.message}`);
    }
  }
  const dynamicParameters = lookCollectDynamicParameters(views);
  let exploreName = options.exploreName;
  const exploreNames = Object.keys(explores);
  if (exploreNames.length === 0) {
    const viewNames = Object.keys(views);
    if (viewNames.length === 0) {
      throw new Error("No views or explores found in the LookML files.");
    }
    const targets = exploreName && views[exploreName] ? [exploreName] : viewNames;
    warnings.push(`\u2139 No explore/model file provided \u2014 converted ${targets.length} standalone view element(s). Joins and explore settings live in the .model.lkml; include it to carry relationships.`);
    const sqlTableNameMapVO = buildSqlTableNameMap(views);
    const ndtCtx = { views, explores };
    const allElements2 = targets.map((v) => lookConvertView(v, views[v], connectionId, warnings, sqlTableNameMapVO, ndtCtx).element);
    if (!connectionId)
      warnings.unshift("\u26A0 Connection ID not set \u2014 update in JSON before saving to Sigma");
    const model = {
      name: targets.length === 1 ? sigmaDisplayName(targets[0]) : "LookML Views",
      schemaVersion: 1,
      pages: [{ id: sigmaShortId(), name: "Page 1", elements: allElements2 }]
    };
    return {
      model,
      warnings,
      ...dynamicParameters.length ? { dynamicParameters } : {},
      ...security.length ? { security } : {},
      stats: {
        views: viewNames.length,
        explores: 0,
        elements: allElements2.length,
        columns: allElements2.reduce((s, e) => s + (e.columns?.length || 0), 0),
        metrics: allElements2.reduce((s, e) => s + (e.metrics?.length || 0), 0),
        relationships: 0
      }
    };
  }
  if (!exploreName) {
    if (exploreNames.length === 1)
      exploreName = exploreNames[0];
    else
      throw new Error(`Multiple explores found: ${exploreNames.join(", ")}. Specify exploreName.`);
  }
  const explore = explores[exploreName];
  if (!explore)
    throw new Error(`Explore "${exploreName}" not found. Available: ${exploreNames.join(", ")}`);
  const sqlTableNameMap = buildSqlTableNameMap(views);
  const strategy = joinStrategy;
  const baseViewName = explore.from || exploreName;
  const baseAlias = exploreName;
  const isBaseView = (name) => name === baseAlias || name === baseViewName;
  const joinDefs = [];
  const joinsRaw = explore.join ? Array.isArray(explore.join) ? explore.join : [explore.join] : [];
  joinsRaw.forEach((j) => {
    const alias = j._name || j.join;
    const viewName = j.from || alias;
    const rel = (j.relationship || "many_to_one").toLowerCase();
    const jType = (j.type || "left_outer").toLowerCase().replace("_join", "").replace(" ", "_");
    const sqlOnRaw = j.sql_on || "";
    const sqlOn = sqlOnRaw.replace(/\{%\s*condition[\s\S]*?\{%\s*endcondition\s*%\}/gi, " ").replace(/\{%[\s\S]*?%\}/g, " ").replace(/\{\{[\s\S]*?\}\}/g, " ");
    const keys = [...sqlOn.matchAll(/\$\{(\w+)\.(\w+)\}\s*=\s*\$\{(\w+)\.(\w+)\}/g)].map((m) => ({
      leftView: m[1],
      leftCol: m[2].toUpperCase(),
      rightView: m[3],
      rightCol: m[4].toUpperCase()
    }));
    const literalPreds = [...sqlOn.matchAll(/\$\{(\w+)\.(\w+)\}\s*=\s*('[^']*'|-?\d+(?:\.\d+)?)/g)].map((m) => `${m[1]}.${m[2]} = ${m[3]}`);
    if (literalPreds.length) {
      warnings.push(`\u2139 Join "${alias}": sql_on carries ${literalPreds.length} literal predicate(s) that a Sigma relationship cannot express \u2014 ${literalPreds.join(", ")}. Apply as an element filter on the joined table if the scoping matters.`);
    }
    if (!keys.length && sqlOnRaw) {
      const isRangeJoin = /\$\{[^}]+\}\s*[><!]|[><!]=?\s*\$\{/.test(sqlOn);
      if (isRangeJoin) {
        warnings.push(`\u26A0 Join "${alias}": uses range-based sql_on (>=, <=, >, <) which cannot be expressed as a Sigma relationship. Recreate this as a filtered join or custom SQL after import.`);
      } else {
        warnings.push(`\u26A0 Join "${alias}": complex sql_on could not be parsed automatically \u2014 add join keys manually in Sigma's ERD view`);
      }
    }
    joinDefs.push({ alias, viewName, rel, joinType: jType, keys });
  });
  const needsPhysical = (j) => {
    if (strategy === "joins")
      return true;
    if (strategy === "relationships")
      return false;
    return j.rel === "one_to_many" || j.joinType === "full_outer";
  };
  const relJoins = joinDefs.filter((j) => !needsPhysical(j));
  const elementMap = {};
  const physViewMap = {};
  const ndtContext = { views, explores };
  const baseResult = lookConvertView(baseViewName, views[baseViewName], connectionId, warnings, sqlTableNameMap, ndtContext);
  elementMap[baseAlias] = baseResult;
  physViewMap[baseViewName] = baseResult;
  if (baseAlias !== baseViewName)
    elementMap[baseViewName] = baseResult;
  for (const j of joinDefs) {
    if (!physViewMap[j.viewName]) {
      const res = lookConvertView(j.viewName, views[j.viewName], connectionId, warnings, sqlTableNameMap, ndtContext);
      physViewMap[j.viewName] = res;
    }
    elementMap[j.alias] = physViewMap[j.viewName];
    if (!elementMap[j.viewName])
      elementMap[j.viewName] = physViewMap[j.viewName];
  }
  const usedTargetCols = /* @__PURE__ */ new Set();
  relJoins.forEach((j) => {
    const targetRes = elementMap[j.alias] || elementMap[j.viewName];
    if (!targetRes) {
      warnings.push(`\u26A0 Relationship "${j.alias}": target not found`);
      return;
    }
    const isTargetView = (name) => name === j.alias || name === j.viewName;
    const bySource = /* @__PURE__ */ new Map();
    j.keys.forEach((k) => {
      let srcView, srcCol, tgtCol;
      if (isTargetView(k.rightView)) {
        srcView = k.leftView;
        srcCol = k.leftCol;
        tgtCol = k.rightCol;
      } else if (isTargetView(k.leftView)) {
        srcView = k.rightView;
        srcCol = k.rightCol;
        tgtCol = k.leftCol;
      } else {
        warnings.push(`\u26A0 Relationship "${j.alias}": sql_on does not reference the joined view directly \u2014 wired from the base element; verify keys in Sigma.`);
        const baseIsLeft = isBaseView(k.leftView);
        srcView = baseAlias;
        srcCol = baseIsLeft ? k.leftCol : k.rightCol;
        tgtCol = baseIsLeft ? k.rightCol : k.leftCol;
      }
      const srcRes = elementMap[srcView];
      if (!srcRes) {
        warnings.push(`\u26A0 Relationship "${j.alias}": source view "${srcView}" not found in the explore \u2014 skipped`);
        return;
      }
      const srcColId = lookFindColId(srcRes, srcCol);
      const tgtColId = lookFindColId(targetRes, tgtCol);
      if (!srcColId || !tgtColId) {
        warnings.push(`\u26A0 Relationship "${j.alias}": could not resolve column IDs for keys (${k.leftCol} / ${k.rightCol})`);
        return;
      }
      const grp = bySource.get(srcRes.elementId) || { srcRes, pairs: [] };
      if (!grp.pairs.some((p) => p.sourceColumnId === srcColId && p.targetColumnId === tgtColId)) {
        grp.pairs.push({ sourceColumnId: srcColId, targetColumnId: tgtColId });
      }
      bySource.set(srcRes.elementId, grp);
    });
    if (j.keys.length && !bySource.size) {
      warnings.push(`\u26A0 Relationship "${j.alias}": no key pair could be resolved to real columns \u2014 add join keys manually in Sigma's ERD view.`);
    }
    bySource.forEach(({ srcRes, pairs }) => {
      const sig = `${srcRes.elementId}|${targetRes.elementId}|` + pairs.map((p) => `${p.sourceColumnId}>${p.targetColumnId}`).sort().join(",");
      if (usedTargetCols.has(sig)) {
        warnings.push(`\u2139 Join "${j.alias}": duplicate of an existing relationship on the same key set \u2014 skipped.`);
        return;
      }
      usedTargetCols.add(sig);
      let relType = "N:1";
      if (j.rel === "one_to_one")
        relType = "1:1";
      else if (j.rel === "one_to_many")
        relType = "1:N";
      else if (j.rel === "many_to_one")
        relType = "N:1";
      else if (j.rel === "many_to_many") {
        relType = "N:1";
        warnings.push(`\u26A0 Relationship "${j.alias}": LookML relationship is many_to_many, which Sigma does not support natively. Mapped to the closest type (N:1) \u2014 verify cardinality and introduce a bridge/junction table if the join can fan out on both sides (otherwise aggregates may double-count).`);
      } else {
        warnings.push(`\u26A0 Relationship "${j.alias}": unrecognized LookML relationship "${j.rel}" \u2014 defaulted to N:1 (many-to-one); verify the cardinality.`);
      }
      const srcEl = srcRes.element;
      if (!srcEl.relationships)
        srcEl.relationships = [];
      srcEl.relationships.push({
        id: sigmaShortId(),
        targetElementId: targetRes.elementId,
        keys: pairs,
        name: j.alias,
        relationshipType: relType
      });
    });
  });
  const seenIds = /* @__PURE__ */ new Set();
  let allElements = Object.values(physViewMap).filter((r) => {
    if (seenIds.has(r.elementId))
      return false;
    seenIds.add(r.elementId);
    return true;
  }).map((r) => r.element);
  allElements.sort((a, b) => {
    const aHasRel = !!(a.relationships && a.relationships.length > 0);
    const bHasRel = !!(b.relationships && b.relationships.length > 0);
    if (aHasRel === bHasRel)
      return 0;
    return aHasRel ? 1 : -1;
  });
  const accessFilters = explore.access_filter ? Array.isArray(explore.access_filter) ? explore.access_filter : [explore.access_filter] : [];
  for (const af of accessFilters) {
    const field = af.field || "(unspecified field)";
    const ua = af.user_attribute || "(unspecified user_attribute)";
    const dotIdx = field.lastIndexOf(".");
    const viewPart = dotIdx >= 0 ? field.slice(0, dotIdx) : baseViewName;
    const fieldPart = (dotIdx >= 0 ? field.slice(dotIdx + 1) : field).toUpperCase();
    const targetRes = elementMap[viewPart] || elementMap[baseAlias];
    const colId = targetRes ? lookFindColId(targetRes, fieldPart) : null;
    if (!targetRes || !colId) {
      warnings.push(`\u26A0 Explore "${exploreName}": access_filter restricts "${field}" by user_attribute "${ua}" (row-level security), but column "${field}" was not found in the converted model \u2014 re-apply this RLS rule manually in Sigma (boolean calc column CurrentUserAttributeText("${ua}") = [<field>] + an element filter keeping only True).`);
      continue;
    }
    const targetEl = targetRes.element;
    const ownerCol = (targetEl.columns || []).find((c) => c.id === colId);
    let dispName = ownerCol?.name;
    if (!dispName && ownerCol?.formula) {
      const fm = String(ownerCol.formula).match(/^\[(?:[^\]\/]+\/)?([^\]]+)\]$/);
      if (fm)
        dispName = fm[1];
    }
    if (!dispName)
      dispName = sigmaDisplayName(fieldPart);
    security.push(makeRlsSecurity({
      source: `Looker access_filter (explore "${exploreName}")`,
      element: targetEl,
      name: `RLS: ${dispName}`,
      formula: `CurrentUserAttributeText("${ua}") = [${dispName}]`
    }));
    warnings.push(`\u{1F510} Explore "${exploreName}": access_filter "${field}" by user_attribute "${ua}" \u2192 row-level security DETECTED (reported in result.security, not injected). The migration skill provisions/reuses the Sigma user attribute "${ua}" and applies the RLS calc + filter.`);
  }
  const alwaysFilterItems = explore.always_filter?.filters ? Array.isArray(explore.always_filter.filters) ? explore.always_filter.filters : [explore.always_filter.filters] : [];
  for (const af of alwaysFilterItems) {
    const fieldRef = af.field || "";
    const expr = (af.value || "").trim();
    if (!fieldRef || !expr)
      continue;
    const dotIdx = fieldRef.lastIndexOf(".");
    const viewPart = dotIdx >= 0 ? fieldRef.slice(0, dotIdx) : baseViewName;
    const fieldPart = (dotIdx >= 0 ? fieldRef.slice(dotIdx + 1) : fieldRef).toUpperCase();
    const targetRes = elementMap[viewPart] || elementMap[baseAlias];
    if (!targetRes) {
      warnings.push(`\u26A0 always_filter "${fieldRef}": view "${viewPart}" not found \u2014 filter skipped`);
      continue;
    }
    const colId = lookFindColId(targetRes, fieldPart) || lookFindColId(targetRes, fieldPart.replace(/_(?:RAW|TIME|DATE|WEEK|MONTH|QUARTER|YEAR)$/, ""));
    if (!colId) {
      warnings.push(`\u26A0 always_filter "${fieldRef}": column "${fieldPart}" not found in element \u2014 filter skipped`);
      continue;
    }
    const sigmaFilter = lookParseFilterExpr(expr, colId);
    if (!sigmaFilter) {
      warnings.push(`\u26A0 always_filter "${fieldRef}" = "${expr}": date/range expression cannot be auto-converted \u2014 add filter manually in Sigma`);
      continue;
    }
    const targetEl = targetRes.element;
    if (!targetEl.filters)
      targetEl.filters = [];
    targetEl.filters.push(sigmaFilter);
    warnings.push(`\u2705 always_filter "${fieldRef}" = "${expr}" \u2192 element list filter added`);
  }
  if (!connectionId)
    warnings.unshift("\u26A0 Connection ID not set \u2014 update in JSON before saving to Sigma");
  const crossElCalcsByElId = {};
  for (const el of allElements) {
    if (el.source?.kind !== "warehouse-table")
      continue;
    if (!el.relationships?.length)
      continue;
    const localNames = /* @__PURE__ */ new Set();
    for (const c of el.columns || []) {
      if (!c.formula)
        continue;
      const m = c.formula.match(/^\[[^\]\/]+\/([^\]]+)\]$/);
      if (m)
        localNames.add(m[1].toUpperCase());
      if (c.name)
        localNames.add(c.name.toUpperCase());
    }
    const crossEl = [];
    const keep = [];
    for (const c of el.columns || []) {
      if (!c.name || !c.formula) {
        keep.push(c);
        continue;
      }
      if (/^\[[^\]\/]+\/[^\]]+\]$/.test(c.formula)) {
        keep.push(c);
        continue;
      }
      const refs = maskFormulaStringLiterals(c.formula).masked.match(/\[([^\]\/]+)\]/g) || [];
      const hasCross = refs.some((ref) => {
        const n = ref.replace(/^\[|\]$/g, "");
        return !/^(true|false|null)$/i.test(n) && !localNames.has(n.toUpperCase());
      });
      if (hasCross) {
        const oi = (el.order || []).indexOf(c.id);
        if (oi >= 0)
          el.order.splice(oi, 1);
        crossEl.push(c);
      } else {
        keep.push(c);
      }
    }
    el.columns = keep;
    if (crossEl.length)
      crossElCalcsByElId[el.id] = crossEl;
  }
  const derivedElements = buildDerivedElements(allElements);
  allElements = [...allElements, ...derivedElements];
  const placedSrcElIds = {};
  for (const de of derivedElements) {
    if (de.source?.kind !== "table" || !de.source.elementId)
      continue;
    const srcElId = de.source.elementId;
    const calcs = crossElCalcsByElId[srcElId];
    if (!calcs?.length)
      continue;
    const srcEl = allElements.find((e) => e.id === srcElId);
    if (!srcEl)
      continue;
    const srcPath = (srcEl.source?.kind === "warehouse-table" ? srcEl.source.path : []) || [];
    const srcBaseName = srcEl.name || (srcPath.length ? srcPath[srcPath.length - 1] : "");
    const relatedNameMap = {};
    if (srcEl && srcEl.relationships && srcBaseName) {
      for (const rel of srcEl.relationships || []) {
        if (!rel.name)
          continue;
        const tgtEl = allElements.find((e) => e.id === rel.targetElementId);
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
    }
    for (const c of calcs) {
      if (c.formula && Object.keys(relatedNameMap).length) {
        const { masked, unmask } = maskFormulaStringLiterals(c.formula);
        const rewrittenMasked = masked.replace(/\[([^\]\/]+)\]/g, (match, refName) => {
          const rewritten = relatedNameMap[refName];
          return rewritten ? `[${rewritten}]` : match;
        });
        c.formula = unmask(rewrittenMasked);
      }
      de.columns.push(c);
      de.order.push(c.id);
    }
    warnings.push(`\u2139 ${calcs.length} calc col(s) moved to derived "${de.name}" (cross-element refs)`);
    placedSrcElIds[srcElId] = true;
  }
  for (const elId of Object.keys(crossElCalcsByElId)) {
    if (placedSrcElIds[elId])
      continue;
    for (const c of crossElCalcsByElId[elId]) {
      warnings.push(`\u26A0 "${c.name}" cross-element refs but no derived element \u2014 column dropped`);
    }
  }
  const sigmaModel = {
    name: sigmaDisplayName(exploreName),
    schemaVersion: 1,
    pages: [{ id: sigmaShortId(), name: "Page 1", elements: allElements }]
  };
  const totalCols = allElements.reduce((s, e) => s + (e.columns?.length || 0), 0);
  const totalMetrics = allElements.reduce((s, e) => s + (e.metrics?.length || 0), 0);
  const totalRels = allElements.reduce((s, e) => s + (e.relationships?.length || 0), 0);
  return {
    model: sigmaModel,
    warnings,
    ...dynamicParameters.length ? { dynamicParameters } : {},
    ...security.length ? { security } : {},
    stats: {
      views: Object.keys(views).length,
      explores: Object.keys(explores).length,
      elements: allElements.length,
      columns: totalCols,
      metrics: totalMetrics,
      relationships: totalRels
    }
  };
}
function buildDerivedElements(elements) {
  const derived = [];
  for (const srcEl of elements) {
    if (!srcEl.relationships?.length)
      continue;
    if (srcEl.source?.kind !== "warehouse-table")
      continue;
    const srcPath = srcEl.source.path;
    const srcTableName = srcPath[srcPath.length - 1];
    const baseName = srcEl.name || srcTableName;
    const viewCols = [];
    const viewOrder = [];
    for (const col of srcEl.columns ?? []) {
      if (!col.formula || col.formula.startsWith("/*"))
        continue;
      const cId = sigmaShortId();
      if (col.name) {
        if (String(col.name).includes("/"))
          continue;
        viewCols.push({ id: cId, formula: `[${baseName}/${col.name}]` });
        viewOrder.push(cId);
        continue;
      }
      const fm = col.formula.match(/^\[([^\/\]]+)\/([^\]]+)\]$/);
      viewCols.push({ id: cId, formula: fm ? `[${baseName}/${fm[2]}]` : col.formula });
      viewOrder.push(cId);
    }
    for (const rel of srcEl.relationships ?? []) {
      if (!rel.name)
        continue;
      const tgtEl = elements.find((e) => e.id === rel.targetElementId);
      if (!tgtEl || tgtEl.source?.kind !== "warehouse-table" && tgtEl.source?.kind !== "sql")
        continue;
      const tgtKeyIds = new Set((rel.keys ?? []).map((k) => k.targetColumnId));
      for (const col of tgtEl.columns ?? []) {
        if (tgtKeyIds.has(col.id))
          continue;
        if (!col.formula || col.formula.startsWith("/*"))
          continue;
        let dispName;
        if (col.name) {
          dispName = col.name;
        } else {
          const fm = col.formula.match(/^\[([^\]]+)\]$/);
          if (!fm)
            continue;
          const inner = fm[1];
          const slashIdx = inner.lastIndexOf("/");
          dispName = slashIdx >= 0 ? inner.slice(slashIdx + 1) : inner;
        }
        const cId = sigmaShortId();
        viewCols.push({ id: cId, formula: `[${baseName}/${rel.name}/${dispName}]` });
        viewOrder.push(cId);
      }
    }
    if (viewCols.length > 0) {
      derived.push({
        id: sigmaShortId(),
        kind: "table",
        // " View" suffix matches sigma-ids.ts buildDerivedElements — without it
        // the derived element collides with the (now-named) source element.
        name: `${srcEl.name ?? sigmaDisplayName(srcTableName)} View`,
        source: { kind: "table", elementId: srcEl.id },
        columns: viewCols,
        order: viewOrder
      });
    }
  }
  return derived;
}
export {
  convertLookMLToSigma,
  maskFormulaStringLiterals,
  parseLookML
};
