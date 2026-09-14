#!/usr/bin/env node
/**
 * score-coverage.mjs — converter-coverage scorer for the cognos-assessment skill.
 *
 * For every Cognos Data Module JSON (*.module.json), report-spec XML
 * (*.report.xml) and Framework Manager project XML (model.xml), classify features
 * into auto / hint / manual / unhandled by detecting the EXACT gap signals the
 * cognos-to-sigma converter (cognos.ts + cognos-report.ts + cognos-fm.ts)
 * translates cleanly vs. flags. This does NOT re-run the converter — it detects
 * the same patterns so the estate's auto-migration % matches what the tool will
 * actually do.
 *
 * Zero external dependencies (Node built-ins only) — module JSON is parsed with
 * JSON.parse; report and Framework Manager XML are scanned with tolerant regexes
 * (gap detection needs signals, not a full parse tree, and an enterprise model.xml
 * runs to tens of MB), exactly the surface the converter warns on.
 *
 *   node score-coverage.mjs --in <dir-of-specs> --out <dir>
 *
 * Reads --in for *.module.json + any *.xml (recurses one level into specs/); XML is
 * dispatched by ROOT ELEMENT, since a Framework Manager model and a report spec are
 * both `.xml`. Writes <out>/coverage.json. Read-only.
 *
 * NOTE Framework Manager is scored WHOLE-MODEL, while the converter runs one
 * presentation subject area at a time — treat FM counts as an estate-size and gap
 * profile, not a single migration unit.
 */
import { readFileSync, readdirSync, statSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { join, basename, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));

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
      // Any .xml is collected and sniffed later — a Framework Manager export is
      // conventionally just `model.xml`, so an extension filter would miss it.
      if (st.isFile() && (f.endsWith('.module.json') || f.endsWith('.xml'))) out.push(p);
    }
  };
  tryDir(dir);
  tryDir(join(dir, 'specs'));
  return [...new Set(out)];
}

// ============================================================================
// GAP SIGNAL DEFINITIONS — each maps to a converter behavior.
// ============================================================================

// Window/running constructs the converter explicitly warns on (cognos.ts L315).
const RUNNING = ['running-total', 'running-count', 'running-average', 'running-difference',
  'moving-total', 'moving-average', 'rank', 'percentile', 'quantile', 'tertile'];

// Functions the converter's translateCognosExpr KNOWS how to map (cognos.ts).
// Anything else as `bareword(` is flagged "no confirmed Sigma mapping".
const KNOWN_FNS = new Set([
  'total', 'sum', 'average', 'avg', 'count', 'maximum', 'minimum', 'min', 'max',
  'if', 'substring', 'substr', 'upper', 'lower', 'trim', 'substitute', 'coalesce',
  '_add_days', '_add_months', '_add_years', '_days_between', 'extract',
  'cast', 'varchar', 'nvarchar', 'char', 'decimal', 'double', 'float', 'number', 'abs',
]);
const RESERVED = new Set(['and', 'or', 'not', 'in', 'like', 'between', 'then', 'else', 'end',
  'case', 'when', 'for', 'as', 'is', 'null']);

// ---- module scorer (mirrors cognos.ts) ----
function scoreModule(text, name) {
  let root;
  try { root = JSON.parse(text); } catch { return null; }
  const arr = (x) => Array.isArray(x) ? x : x == null ? [] : [x];
  const lc = (s) => String(s ?? '').toLowerCase();

  const gaps = [];
  let nAuto = 0, nHint = 0, nManual = 0, nUnhandled = 0;
  const add = (signal, bucket, reason, remediation) => {
    let g = gaps.find((x) => x.signal === signal);
    if (!g) { g = { signal, bucket, count: 0, reason, remediation }; gaps.push(g); }
    g.count++;
    if (bucket === 'auto') nAuto++; else if (bucket === 'hint') nHint++;
    else if (bucket === 'manual') nManual++; else nUnhandled++;
  };

  const qsList = arr(root.querySubject || root.querySubjects || root.module?.querySubject);
  const rels = arr(root.relationship || root.relationships);
  const useSpec = arr(root.useSpec);

  // file-backed sources → hint (land in warehouse first)
  const fileSources = useSpec.filter((u) => lc(u.type) === 'file').length;
  if (fileSources) add('file-backed source (useSpec.type:"file")', 'hint', fileSources + ' uploaded file source(s) back this module',
    'Land the file(s) in the warehouse first (the original upload is not re-downloadable via REST), then point the Sigma data model at the warehouse table.');
  // layered base+presentation (module-type useSpec alongside file/db) → hint
  const moduleRefs = useSpec.filter((u) => lc(u.type) === 'module').length;
  if (moduleRefs) add('layered module (base + presentation subjects)', 'hint', moduleRefs + ' referenced sub-module(s)',
    'Layered modules expose base + presentation query subjects; both convert. Dedupe to the physical-table layer in Sigma to avoid redundant elements.');

  // query subjects + items
  for (const qs of qsList) {
    add('query subject → table element', 'auto', 'maps to a Sigma warehouse-table element', '—');
    const subjId = qs.identifier || qs.label || 'QS';
    for (const raw of arr(qs.item || qs.items)) {
      const qi = raw.queryItem || raw.calculation || raw.measure;
      if (!qi || !(qi.identifier || qi.label)) continue;
      const expr = qi.expression || '';
      const ident = qi.identifier || qi.label;
      const isCalc = !!raw.calculation ||
        (expr && !(new RegExp(`^${escapeRe(ident)}$`, 'i').test(expr.trim())) &&
         !/^[A-Za-z_][\w ]*$/.test(expr.trim()) &&
         !/^\[?[\w]+\]?\.\[?[\w]+\]?$/.test(expr.replace(/[[\]]/g, '').trim()));
      const agg = lc(qi.regularAggregate || qi.aggregate || qi.aggregateFunction);
      const usage = lc(qi.usage);
      if (isCalc) {
        classifyExpr(expr, `${subjId}.${ident}`, add);
      } else if ((usage === 'fact' || usage === 'measure') && agg && agg !== 'none') {
        add('measure item (fact + aggregate)', 'auto', 'fact + regularAggregate → Sigma metric', '—');
      } else {
        add('plain column item', 'auto', 'attribute → Sigma column (business label preserved)', '—');
      }
    }
  }

  // relationships
  for (const rel of rels) {
    const links = arr(rel.link);
    const composite = links.length > 1;
    const expr = rel.expression || rel.linkExpression || '';
    const nonEqui = expr && (/\band\b|\bor\b/i.test(expr) || /[<>]=?|<>|!=/.test(expr));
    if (composite || nonEqui) {
      add('composite / non-equi join', 'manual',
        composite ? 'relationship has >1 join column (link[] length > 1)' : 'join expression is not a simple equi-join',
        'The converter handles single equi-joins only; re-create this relationship (and its key columns) by hand in the Sigma data model.');
    } else {
      add('equi-join relationship', 'auto', 'single equi-join (link.leftRef = link.rightRef) → DM relationship', '—');
    }
  }

  return finalize({ type: 'module', name, gaps, nAuto, nHint, nManual, nUnhandled });
}

// ---- Framework Manager scorer (mirrors cognos-fm.ts) ----

/** Root-element sniff — an FM model and a report spec are both `.xml`. */
function isFrameworkManagerXml(text) {
  const head = String(text || '').slice(0, 4000);
  return /<project[\s>]/.test(head) && /schemas\/bmt\//.test(head);
}

function decodeXmlEntities(s) {
  return String(s ?? '')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

/**
 * Score a Framework Manager model. Regex-based like the report scorer — gap detection
 * needs signals, not a parse tree, and an enterprise `model.xml` runs to tens of MB.
 *
 * NOTE this scores the WHOLE model. The converter works one presentation subject area at
 * a time (`cli.mjs <model.xml> --list`), so treat these counts as the estate-wide size and
 * gap profile, not a single migration unit.
 */
function scoreFrameworkManager(text, name) {
  const gaps = [];
  let nAuto = 0, nHint = 0, nManual = 0, nUnhandled = 0;
  const addN = (signal, bucket, reason, remediation, n = 1) => {
    if (n <= 0) return;
    let g = gaps.find((x) => x.signal === signal);
    if (!g) { g = { signal, bucket, count: 0, reason, remediation }; gaps.push(g); }
    g.count += n;
    if (bucket === 'auto') nAuto += n; else if (bucket === 'hint') nHint += n;
    else if (bucket === 'manual') nManual += n; else nUnhandled += n;
  };
  const add = (signal, bucket, reason, remediation) => addN(signal, bucket, reason, remediation, 1);
  const countOf = (re) => (text.match(re) || []).length;

  // Relationship and filter expressions are scored on their own terms below; pull them
  // out so they are not mistaken for calculations.
  const relBlocks = [...text.matchAll(/<relationship\b[^>]*>([\s\S]*?)<\/relationship>/gi)].map((m) => m[1]);
  const body = text
    .replace(/<relationship\b[^>]*>[\s\S]*?<\/relationship>/gi, '')
    .replace(/<filterDefinition\b[^>]*>[\s\S]*?<\/filterDefinition>/gi, '');

  // ── Structure ──────────────────────────────────────────────────────────────
  // Counts EVERY layer (database + logical), so it exceeds the element count of any one
  // subject area — it is an estate-size signal, not a per-conversion element count.
  addN('query subject (all layers)', 'auto',
    'FM query subjects resolve to Sigma warehouse-table (or sql) elements, scoped per subject area', '—',
    countOf(/<querySubject\b/gi));

  // Physical definitions: a plain `Select * From [ds].TABLE` is a table; anything else
  // becomes a Sigma `sql` source (converts, but review the statement).
  let simple = 0, custom = 0, macroSql = 0;
  for (const m of text.matchAll(/<dbQuery>[\s\S]*?<sql\b[^>]*>([\s\S]*?)<\/sql>/gi)) {
    const sql = decodeXmlEntities(m[1].replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim();
    if (/^\s*select\s+(?:\*|[\w$]+\s*\.\s*\*)\s*from\s*\[[^\]]+\]\s*\.\s*\[?[\w$]+\]?(?:\s+(?:as\s+)?[\w$]+)?\s*$/i.test(sql)) simple++;
    else { custom++; if (/#[^#]{1,400}#/.test(sql)) macroSql++; }
  }
  addN('table passthrough query subject', 'auto', 'Select * From [ds].TABLE → warehouse-table source', '—', simple);
  addN('custom-SQL query subject', 'hint', 'query subject is defined by a query, not a table',
    'Converts to a Sigma `sql` source with [datasource].TABLE rewritten to catalog.schema.table. Review the statement — warehouse dialect differences are not translated.', custom);
  addN('runtime macro in query subject SQL', 'unhandled',
    'Cognos `#...#` macro (e.g. $account.personalInfo.email) embedded in the SQL',
    'The macro is passed through VERBATIM and will not execute in Sigma. This is usually the model\'s row-level-security join — replace it with CurrentUserEmail() and apply the rule via the skill\'s RLS flow.', macroSql);

  // Role-playing dimension aliases — handled, but they multiply the element count.
  // Covers both role-playing dimension aliases (database layer) and presentation-layer
  // exposure; a regex cannot tell them apart without resolving each target.
  const aliases = countOf(/<treatAs>\s*alias\s*<\/treatAs>/gi);
  addN('alias shortcut', 'auto',
    'alias shortcut — a role-playing dimension becomes its own Sigma element (keeping join grain correct); a presentation shortcut resolves through to its query subject', '—', aliases);

  // ── Relationships ──────────────────────────────────────────────────────────
  for (const blk of relBlocks) {
    // Scan the EXPRESSION only. The relationship's <name> often contains an arrow
    // ("A <-> B"), which would otherwise read as a comparison operator.
    const em = /<expression>([\s\S]*?)<\/expression>/i.exec(blk);
    if (!em) continue;
    const bare = decodeXmlEntities(em[1].replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim();
    const conds = bare.split(/\band\b/i).length;
    if (/\bor\b/i.test(bare) || /<>|!=|>=|<=|[<>]/.test(bare)) {
      add('non-equi join', 'manual', 'relationship condition is not a conjunction of equalities',
        'Sigma relationships are equi-joins. Re-create this join by hand, or push it into a sql source.');
    } else if (conds > 1) {
      add('composite join', 'auto', 'multi-column equi-join → one relationship with several key pairs', '—');
    } else {
      add('equi-join relationship', 'auto', 'single equi-join → DM relationship (source = many side)', '—');
    }
  }

  // ── Calculations ───────────────────────────────────────────────────────────
  // ~95% of a real FM model's expressions are pure reference passthroughs needing no
  // translation at all; only the remainder are genuine expressions.
  let passthrough = 0;
  for (const m of body.matchAll(/<expression>([\s\S]*?)<\/expression>/gi)) {
    const raw = m[1];
    const bare = raw
      .replace(/<refobjViaShortcut>[\s\S]*?<\/refobjViaShortcut>/gi, '')
      .replace(/<refobj>[\s\S]*?<\/refobj>/gi, '')
      .replace(/<[^>]*>/g, '').trim();
    if (!bare) { passthrough++; continue; }
    const readable = decodeXmlEntities(raw.replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim();
    classifyExpr(readable, `${name} calc`, add);
  }
  addN('passthrough query item', 'auto', 'item is a plain reference to a physical column — no translation needed', '—', passthrough);

  // ── Flagged, never faked ───────────────────────────────────────────────────
  addN('DMR dimension (hierarchy/levels)', 'unhandled',
    'dimensionally-modelled relational metadata (hierarchies, levels, member rollups)',
    'Sigma has no OLAP hierarchy equivalent. Re-author drill paths in the workbook.',
    countOf(/<dimension\b[^>]*>/gi));
  addN('determinant (declared grain)', 'hint',
    'determinant declares uniqueness / multi-grain aggregation behavior',
    'Sigma has no determinant concept. Verify aggregate correctness where a dimension is joined at more than one grain.',
    countOf(/<determinant>/gi));
  addN('embedded model filter', 'manual',
    'filter embedded on a query subject, applied on every query',
    'Not applied to the Sigma model. Re-create as a data-model filter if it is a governance rule.',
    countOf(/<filterDefinition\b/gi));
  addN('parameter map', 'manual',
    'session-parameter substitution map',
    'Not translated. Any SQL or filter depending on it needs manual review.',
    countOf(/<parameterMap\b/gi));
  addN('security view (object security)', 'manual',
    'package-scoped include/exclude/hide rules over model objects',
    'Object-level security is not ported. Inventory these and re-create as Sigma folder/document permissions or column-level security.',
    countOf(/<securityView>/gi));

  return finalize({ type: 'framework-manager', name, gaps, nAuto, nHint, nManual, nUnhandled });
}

// Classify a single Cognos expression the way translateCognosExpr would.
function classifyExpr(expr, where, add) {
  const e = String(expr || '');
  const lower = e.toLowerCase();
  let flagged = false;

  // unhandled: running / moving / rank / percentile windows
  for (const bad of RUNNING) {
    if (new RegExp(`\\b${bad}\\b`, 'i').test(e)) {
      add(`${bad} (window/running calc)`, 'unhandled', `calc "${where}" uses Cognos ${bad}`,
        'The converter maps running-total/moving-*/rank onto the Sigma-NATIVE window family (CumulativeSum / MovingSum / MovingAvg / Rank) and drops any "for" partition with a warning. Never use the *Over names — they hard-reject a DM-spec POST with 400. Verify the partition, or push the window into a sql source.');
      flagged = true;
    }
  }
  // unhandled: GetResourceString (localization)
  if (/\bGetResourceString\s*\(/i.test(e)) {
    add('GetResourceString (localization)', 'unhandled', `calc "${where}" pulls a localized string resource`,
      'Sigma has no localization-resource lookup. Replace with the literal label, or model a lookup table.');
    flagged = true;
  }
  // manual: CASE WHEN ... END (converter only does if/then/else)
  if (/\bcase\b[\s\S]*\bwhen\b[\s\S]*\bend\b/i.test(e)) {
    add('CASE…WHEN…END expression', 'manual', `calc "${where}" uses a CASE block`,
      'The converter translates a searched CASE to nested If() and a simple CASE to Switch(), but warns when the block is nested or non-standard. Budget a review pass; re-author by hand only where the warning fires.');
    flagged = true;
  }
  // manual: "for" window scope → *Over (window function)
  if (/\b(total|sum|average|count|maximum|minimum)\s*\([^()]*\bfor\b/i.test(e)) {
    add('aggregate "… for …" scope (partition dropped)', 'manual', `calc "${where}" scopes an aggregate with "for"`,
      'Sigma has no spec-valid partitioned aggregate, so the converter emits the plain aggregate and DROPS the partition (with a warning). Re-create the grouping as a grouped element, a model metric, or a sql source.');
    flagged = true;
  }
  // unhandled: unknown bareword function with no Sigma mapping
  for (const m of e.matchAll(/\b([a-z_][a-z0-9_-]*)\s*\(/gi)) {
    const fn = m[1].toLowerCase();
    if (KNOWN_FNS.has(fn) || RESERVED.has(fn) || RUNNING.includes(fn)) continue;
    if (/getresourcestring/i.test(fn)) continue; // already counted
    add(`unmapped function ${fn}()`, 'unhandled', `calc "${where}" calls ${fn}() — no confirmed Sigma mapping`,
      'Review and translate this function by hand; the converter passes it through with a warning.');
    flagged = true;
  }
  if (!flagged) {
    add('translatable calc (if/agg/date/string/cast)', 'auto', `calc "${where}" maps via translateCognosExpr`, '—');
  }
}

// ---- report scorer (mirrors cognos-report.ts + format-shapes.md) ----
function scoreReport(text, name) {
  const gaps = [];
  let nAuto = 0, nHint = 0, nManual = 0, nUnhandled = 0;
  const add = (signal, bucket, reason, remediation) => {
    let g = gaps.find((x) => x.signal === signal);
    if (!g) { g = { signal, bucket, count: 0, reason, remediation }; gaps.push(g); }
    g.count++;
    if (bucket === 'auto') nAuto++; else if (bucket === 'hint') nHint++;
    else if (bucket === 'manual') nManual++; else nUnhandled++;
  };
  const countMatches = (re) => (text.match(re) || []).length;

  // layout containers → elements
  const nLists = countMatches(/<list\b/g);
  for (let i = 0; i < nLists; i++) add('list → table element', 'auto', 'a Cognos list maps to a Sigma table', '—');
  const nCross = countMatches(/<crosstab\b/g);
  for (let i = 0; i < nCross; i++) add('crosstab → pivot table', 'auto', 'a Cognos crosstab maps to a Sigma pivot', '—');

  // RAVE2 viz controls
  const SUPPORTED_VIZ = /com\.ibm\.vis\.(clusteredBar|stackedBar|clusteredColumn|stackedColumn|line|spline|area|pie|donut|clusteredCombination|bubble|scatter|tiledmap)\b/gi;
  for (const m of text.matchAll(SUPPORTED_VIZ)) {
    const kind = m[1].toLowerCase();
    const label = /tiledmap/.test(kind) ? 'map (tiledmap → region/point map)' :
      /combination/.test(kind) ? 'combo chart' :
      /bubble|scatter/.test(kind) ? 'scatter/bubble chart' :
      /pie|donut/.test(kind) ? 'pie/donut chart' :
      /line|spline|area/.test(kind) ? 'line/area chart' : 'bar/column chart';
    add(`${label} (RAVE2 viz)`, 'auto', `${m[1]} → a native Sigma chart element`, '—');
  }
  // viz with NO Sigma analog → unhandled
  const NO_ANALOG = { treemap: 'treemap', network: 'network', wordcloud: 'word cloud', packedbubble: 'packed bubble' };
  for (const [k, label] of Object.entries(NO_ANALOG)) {
    const re = new RegExp(`com\\.ibm\\.vis\\.${k}\\b`, 'gi');
    const n = countMatches(re);
    for (let i = 0; i < n; i++) add(`${label} viz (no Sigma analog)`, 'unhandled', `${label} chart has no native Sigma element`,
      'Data is preserved as a flagged table; re-pick the closest Sigma element (e.g. bar / heatmap) in the workbook.');
  }

  // runtime macros: # … prompt(...,'token') … #  → swap-measure / dynamic column build
  // Match a data-item expression that both starts a macro (#) and uses a 'token' prompt.
  const macroExprs = text.match(/<expression>\s*#[\s\S]*?#\s*<\/expression>/gi) || [];
  let macroCount = 0;
  for (const me of macroExprs) {
    if (/'token'/.test(me) || /prompt\(/.test(me)) macroCount++;
  }
  for (let i = 0; i < macroCount; i++) add("runtime macro (#…prompt(…,'token')…#)", 'unhandled',
    'a data item builds its column/SQL at runtime via a Cognos macro (e.g. swap-measure picker)',
    'No static Sigma analog. Model as a Sigma control + Switch([Control], …) mapping prompt tokens to real columns. The converter emits a placeholder.');

  // rank() inside a data item expression → unhandled
  const rankCount = countMatches(/\brank\s*\(/gi);
  for (let i = 0; i < rankCount; i++) add('rank() data item', 'unhandled', 'rank() in a report data item',
    'Re-author as a Sigma Rank window function in a grouped element.');

  // standard prompts → controls (auto)
  const promptNames = new Set();
  for (const m of text.matchAll(/prompt\(\s*'([^']+)'/gi)) promptNames.add(m[1]);
  // count parameter-token prompts (?p?) too
  for (const m of text.matchAll(/\?([A-Za-z_]\w*)\?/g)) promptNames.add(m[1]);
  for (let i = 0; i < promptNames.size; i++) add('prompt → control', 'auto', 'a Cognos prompt maps to a Sigma control', '—');

  // detail / summary filters → manual (re-create)
  const nFilters = countMatches(/<detailFilter\b/g) + countMatches(/<summaryFilter\b/g);
  for (let i = 0; i < nFilters; i++) add('detail/summary filter', 'manual', 'a report filter must be re-created',
    'Re-create as a Sigma element/page filter (the converter surfaces it as a warning, does not auto-apply).');

  // drill-through → manual (Sigma actions)
  const nDrill = countMatches(/<drillThrough\b|drillThroughDef|<reportDrillThrough/gi);
  for (let i = 0; i < nDrill; i++) add('drill-through', 'manual', 'a drill-through definition',
    'Re-implement as a Sigma action (cross-element navigation / open-link); not auto-converted.');

  // ---- duplicate-detection signals (sources / fields / viz) for dup-dashboards.py ----
  // sources = the package / data module a report reads (modelPath) + the model
  // namespace(s) referenced in data-item expressions (e.g. [C].[C_Fred_Data_Module]).
  const sources = new Set();
  for (const m of text.matchAll(/<modelPath[^>]*>([\s\S]*?)<\/modelPath>/gi)) {
    for (const mm of m[1].matchAll(/(?:module|package|model)\[@name='([^']+)'\]/gi)) sources.add(mm[1]);
  }
  for (const m of text.matchAll(/\[[A-Za-z0-9_]+\]\.\[([A-Za-z0-9_]+)\]\.\[/g)) sources.add(m[1]);
  // fields = the data-item names the report surfaces (named once per definition).
  const fields = new Set();
  for (const m of text.matchAll(/<dataItem[^>]*\bname="([^"]+)"/gi)) fields.add(m[1]);
  // viz = native chart-kind tokens (RAVE2), normalized to the converter's labels.
  const viz = new Set();
  for (const m of text.matchAll(/com\.ibm\.vis\.([A-Za-z0-9]+)\b/gi)) viz.add(m[1].toLowerCase());

  return finalize({
    type: 'report', name, gaps, nAuto, nHint, nManual, nUnhandled,
    signals: { sources: [...sources], fields: [...fields], viz: [...viz] },
  });
}

function escapeRe(s) { return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

function finalize(r) {
  const nFeatures = r.nAuto + r.nHint + r.nManual + r.nUnhandled;
  const cost = 10 * r.nUnhandled + 3 * r.nManual + 1 * r.nHint;
  const value = 10 * nFeatures;
  const score = Math.round((value / (1 + cost)) * 100) / 100;
  const complexity = r.nUnhandled > 0 ? 'high' : r.nManual > 0 ? 'medium' : 'low';
  let tag;
  if (r.nUnhandled >= 1) tag = 'needs-review';
  else if (r.nManual + r.nUnhandled === 0) tag = 'migrate-first';
  else if (score >= 10) tag = 'easy-win';
  else tag = 'moderate';
  const out = {
    id: r.name, type: r.type, name: r.name,
    n_features: nFeatures, n_auto: r.nAuto, n_hint: r.nHint, n_manual: r.nManual, n_unhandled: r.nUnhandled,
    complexity, gaps: r.gaps, value, cost, score, tag,
  };
  if (r.signals) out._dup_signals = r.signals;   // internal: fed to dup-dashboards.py, not rendered per-artifact
  return out;
}

// ============================================================================
// main
// ============================================================================
const files = collect(inDir);
if (!files.length) {
  console.error(`no *.module.json / *.report.xml / Framework Manager model.xml found under ${inDir}`);
  process.exit(1);
}

const artifacts = [];
for (const f of files) {
  const text = readFileSync(f, 'utf8');
  const name = basename(f).replace(/\.(module\.json|report\.xml|fm\.xml|xml)$/, '');
  // Dispatch on CONTENT, not extension: an FM model and a report spec are both `.xml`.
  const res = f.endsWith('.module.json') ? scoreModule(text, name)
    : isFrameworkManagerXml(text) ? scoreFrameworkManager(text, name)
      : scoreReport(text, name);
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
// (auto + hint count as auto-migratable; hint is a one-time decision, not rework.)
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
const gapHistogram = Object.values(histo).sort((a, b) => (b.bucket === 'unhandled' ? 1 : 0) - (a.bucket === 'unhandled' ? 1 : 0) || b.count - a.count);

const byComplexity = { low: 0, medium: 0, high: 0 };
const byTag = {};
for (const a of artifacts) { byComplexity[a.complexity]++; byTag[a.tag] = (byTag[a.tag] || 0) + 1; }

const rollup = {
  generated_at: new Date().toISOString().slice(0, 10),
  n_artifacts: artifacts.length,
  n_modules: artifacts.filter((a) => a.type === 'module').length,
  n_reports: artifacts.filter((a) => a.type === 'report').length,
  n_framework_manager: artifacts.filter((a) => a.type === 'framework-manager').length,
  totals,
  pct_auto_migratable: pctAuto,
  gap_histogram: gapHistogram,
  by_complexity: byComplexity,
  by_tag: byTag,
};

// ---- duplicate / consolidation detection (shared, tool-neutral detector) ----
// Flag reports that are the same report rebuilt (shared data module + overlapping
// data items + near-identical name) so the estate migrates ONCE, not N times.
// Shells out to dup-dashboards.py (byte-identical across all assessments); a
// python3 failure must NEVER fail the assessment — dedup is purely additive.
let duplicateDashboards = null;
try {
  const dashboards = artifacts
    .filter((a) => a.type === 'report' && a._dup_signals)
    .map((a) => {
      const s = a._dup_signals;
      const d = { id: a.id, name: a.name };          // only id+name required; rest omitted when absent
      if (s.sources && s.sources.length) d.sources = s.sources;
      if (s.fields && s.fields.length) d.fields = s.fields;
      if (s.viz && s.viz.length) d.viz = s.viz;
      // usage (run/view counts) NOT exposed by the Cognos REST surface — omit, never fake.
      return d;
    });
  if (dashboards.length >= 2) {
    const normPath = join(outDir, 'dup-dashboards.input.json');
    const groupsPath = join(outDir, 'dup-groups.json');
    const fragPath = join(outDir, 'dup-frag.html');
    writeFileSync(normPath, JSON.stringify(dashboards, null, 2));
    execFileSync('python3', [join(__dirname, 'dup-dashboards.py'),
      '--in', normPath, '--out', groupsPath, '--html', fragPath], { stdio: ['ignore', 'ignore', 'inherit'] });
    const result = JSON.parse(readFileSync(groupsPath, 'utf8'));
    const html = existsSync(fragPath) ? readFileSync(fragPath, 'utf8') : null;
    duplicateDashboards = { ...result, html };
  }
} catch (e) {
  console.error(`[score-coverage] duplicate detection skipped: ${e && e.message ? e.message : e}`);
}

// Drop the internal dedup signals before persisting (they are not part of the readout).
const cleanArtifacts = artifacts.map(({ _dup_signals, ...rest }) => rest);

const out = { rollup, artifacts: cleanArtifacts };
if (duplicateDashboards) out.duplicate_dashboards = duplicateDashboards;
writeFileSync(join(outDir, 'coverage.json'), JSON.stringify(out, null, 2));
const dupMsg = duplicateDashboards
  ? ` — ${duplicateDashboards.summary.duplicate_groups} duplicate group(s), ${duplicateDashboards.summary.conversions_avoided} conversion(s) avoidable`
  : '';
const mix = [
  `${rollup.n_modules} modules`,
  `${rollup.n_reports} reports`,
  ...(rollup.n_framework_manager ? [`${rollup.n_framework_manager} framework-manager`] : []),
].join(', ');
console.log(`scored ${artifacts.length} artifacts (${mix}) — ${pctAuto}% auto-migratable${dupMsg} -> ${join(outDir, 'coverage.json')}`);
