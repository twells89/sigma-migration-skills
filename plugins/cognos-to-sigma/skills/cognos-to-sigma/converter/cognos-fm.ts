/**
 * IBM Cognos **Framework Manager** (BMT project XML) → the shared `CognosModule` IR.
 *
 * FM is Cognos's legacy semantic layer — the desktop modeller whose project lives in a
 * `.cpf` workspace alongside a `model.xml` holding the whole model. Data Modules (CA 11.x)
 * replaced it, but large, long-lived estates are still on FM.
 *
 * This file is INGEST ONLY. It produces the same `CognosModule` IR that
 * `normalizeCognosDataModule()` produces, so `convertCognosIR()` — element/column/metric
 * emission, relationship direction, `translateCognosExpr()` — is reused unchanged. That is
 * the same "one IR, two ingests, one shared core" split `bobj.ts` documents.
 *
 * ── The FM model shape ──────────────────────────────────────────────────────────────
 * A conventional FM model is layered, all inside one `model.xml`:
 *
 *   Database Layer      querySubject + definition/dbQuery (Cognos SQL + dataSourceRef),
 *                       and the physical relationships
 *   Logical Layer       querySubject + definition/modelQuery, whose queryItems are
 *                       `refobjViaShortcut` pointers down into the Database Layer
 *   Presentation Layer  namespaces of `shortcut`s — the SUBJECT AREAS report authors see
 *   Dimension Layer     DMR dimension/hierarchy/level (flagged, not converted)
 *
 * Two rules govern every lookup here, and both are easy to get wrong:
 *
 *  1. **Folders are not part of the identifier path.** A `refobj` like
 *     `[Database Layer].[DATE_DIM].[ID]` skips every `folder` / `queryItemFolder` in
 *     between. The index must mirror that or nothing resolves.
 *
 *  2. **`refobjViaShortcut` is a 2-tuple** `(alias-shortcut, physical-item)`. The alias is
 *     how FM models ROLE-PLAYING dimensions — one physical `DATE_DIM` exposed as
 *     `..._ORDER_DATE`, `..._SHIP_DATE`, … Each alias must become its OWN Sigma element
 *     over the same table, or every role collapses into one and the joins go wrong.
 *
 * Scoping: a real FM model is far too large for one Sigma data model (enterprise models run
 * to thousands of query subjects), so conversion is scoped to ONE presentation subject area
 * at a time — see `listFrameworkManagerSubjectAreas()`.
 *
 * Deliberately NOT converted (flagged, never faked): DMR dimensions/hierarchies/levels,
 * determinant-driven multi-grain aggregation, parameter maps, non-equi joins, and any
 * residual `#...#` runtime macro.
 */

import { XMLParser } from 'fast-xml-parser';
import type {
  CognosModule, CognosQuerySubject, CognosItem, CognosRelationship, CognosSecurityFilter,
} from './cognos.js';

// ── Parsing ──────────────────────────────────────────────────────────────────

// Nodes whose inner XML we keep as a RAW string. `expression` is mixed content —
// text interleaved with <refobj> elements — which a tree parser would shred; we need the
// original interleaving to rebuild the Cognos expression. Same for dbQuery <sql>.
const STOP_NODES = ['*.expression', '*.sql'];

const ALWAYS_ARRAY = new Set([
  'namespace', 'folder', 'queryItemFolder', 'querySubject', 'queryItem', 'shortcut',
  'calculation', 'relationship', 'determinant', 'filterDefinition', 'dataSource',
  'securityView', 'package', 'dimension', 'refobj', 'set', 'parameterMap',
]);

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  parseTagValue: false,       // keep everything as strings — no surprise numeric coercion
  parseAttributeValue: false,
  trimValues: true,
  stopNodes: STOP_NODES,
  isArray: (tag: string) => ALWAYS_ARRAY.has(tag),
});

const asArray = <T,>(x: T | T[] | undefined | null): T[] =>
  Array.isArray(x) ? x : x == null ? [] : [x];

/** Text of a node that may be a bare string, or `{ '#text': …, '@_locale': 'en' }`. */
function text(v: any): string {
  if (v == null) return '';
  if (typeof v === 'string') return v;
  if (typeof v === 'object' && '#text' in v) return String((v as any)['#text'] ?? '');
  return '';
}
const nameOf = (el: any): string => text(el?.name).trim();

/** Does this look like an FM project XML (vs a Cognos report spec, vs Data Module JSON)? */
export function isFrameworkManagerXml(xml: string): boolean {
  const head = (xml || '').slice(0, 4000);
  return /<project[\s>]/.test(head) && /schemas\/bmt\//.test(head);
}

// ── Path index ───────────────────────────────────────────────────────────────

type FmKind = 'namespace' | 'querySubject' | 'shortcut' | 'calculation' | 'queryItem' | 'dimension';
interface FmObj { kind: FmKind; el: any; path: string; parent: string }

/** `[A].[B].[C]` — the Cognos refobj form. */
const joinPath = (segs: string[]) => segs.map((s) => `[${s}]`).join('.');

/** Child tags we descend through, in the order FM nests them. */
const CHILD_TAGS: Array<FmKind | 'folder' | 'queryItemFolder'> = [
  'namespace', 'folder', 'queryItemFolder', 'querySubject', 'shortcut', 'calculation',
  'queryItem', 'dimension',
];
// Rule 1: folders are path-transparent — they do NOT contribute an identifier segment.
const PATH_TRANSPARENT = new Set(['folder', 'queryItemFolder']);

function buildIndex(rootNamespace: any): Map<string, FmObj> {
  const index = new Map<string, FmObj>();
  const walk = (node: any, segs: string[]) => {
    for (const tag of CHILD_TAGS) {
      for (const el of asArray(node?.[tag])) {
        const n = nameOf(el);
        if (!n) continue;
        const transparent = PATH_TRANSPARENT.has(tag);
        const childSegs = transparent ? segs : [...segs, n];
        if (!transparent) {
          const path = joinPath(childSegs);
          // First writer wins: FM allows duplicate labels in different folders; the
          // shallowest/earliest is the one a refobj of this path means.
          if (!index.has(path)) {
            index.set(path, { kind: tag as FmKind, el, path, parent: joinPath(segs) });
          }
        }
        walk(el, childSegs);
      }
    }
  };
  walk(rootNamespace, []);
  return index;
}

/** Follow `shortcut` hops to the concrete object. Returns null on a dangling/cyclic ref. */
function resolve(index: Map<string, FmObj>, path: string, depth = 0): FmObj | null {
  if (depth > 12) return null;
  const o = index.get(path);
  if (!o) return null;
  if (o.kind === 'shortcut') {
    const target = text(o.el?.refobj?.[0] ?? o.el?.refobj);
    return target ? resolve(index, target.trim(), depth + 1) : null;
  }
  return o;
}

// ── Expressions ──────────────────────────────────────────────────────────────

const RE_VIA = /<refobjViaShortcut>([\s\S]*?)<\/refobjViaShortcut>/gi;
const RE_REF = /<refobj>([\s\S]*?)<\/refobj>/gi;

/**
 * `stopNodes` hands back the RAW inner XML, so entity references survive. A Cognos
 * comparison is authored as `&lt;`, and leaving it encoded produces the literal formula
 * `If([Net Amount] &lt; 100, …)` — which Sigma compiles to type "error". Decode `&amp;`
 * LAST so `&amp;lt;` does not turn into `<`.
 */
function decodeEntities(s: string): string {
  return String(s ?? '')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_m, d) => String.fromCodePoint(Number(d)))
    .replace(/&#x([0-9a-f]+);/gi, (_m, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&amp;/g, '&');
}

/** Every object path an expression references, in order. */
function expressionRefs(raw: string): string[] {
  const out: string[] = [];
  const scan = String(raw || '');
  // refobjViaShortcut wraps 2 refs (alias, physical item) — take the LAST, the real item.
  const viaSpans: Array<[number, number]> = [];
  let m: RegExpExecArray | null;
  RE_VIA.lastIndex = 0;
  while ((m = RE_VIA.exec(scan))) {
    viaSpans.push([m.index, m.index + m[0].length]);
    const inner = [...String(m[1]).matchAll(/<refobj>([\s\S]*?)<\/refobj>/gi)].map((x) => x[1].trim());
    if (inner.length) out.push(inner[inner.length - 1]);
  }
  RE_REF.lastIndex = 0;
  while ((m = RE_REF.exec(scan))) {
    const inside = viaSpans.some(([a, b]) => m!.index >= a && m!.index < b);
    if (!inside) out.push(String(m[1]).trim());
  }
  return out;
}

/**
 * An expression is a PURE PASSTHROUGH when it is nothing but a reference — no operators, no
 * functions, no literals. ~95% of a real FM model's expressions are exactly this, and they
 * need no translation at all: the item is simply the physical column.
 */
function isPassthrough(raw: string): boolean {
  const stripped = String(raw || '')
    .replace(RE_VIA, '')
    .replace(RE_REF, '')
    .replace(/<[^>]*>/g, '')
    .trim();
  return stripped === '';
}

/**
 * Rebuild a Cognos expression as plain text, with each reference rendered as its bracket
 * path so `translateCognosExpr()` can reduce it to a Sigma column ref.
 */
function expressionText(raw: string): string {
  const stripped = String(raw || '')
    .replace(RE_VIA, (_m, inner) => {
      const refs = [...String(inner).matchAll(/<refobj>([\s\S]*?)<\/refobj>/gi)].map((x) => x[1].trim());
      return refs.length ? refs[refs.length - 1] : '';
    })
    .replace(RE_REF, (_m, p1) => String(p1).trim())
    .replace(/<[^>]*\/>/g, '')
    .replace(/<[^>]*>/g, '');
  // Decode AFTER tag stripping so an encoded `&lt;` can never be mistaken for a tag.
  return decodeEntities(stripped).replace(/\s+/g, ' ').trim();
}

/** Last segment of `[A].[B].[C]` → `C`. */
const leafOf = (path: string): string => {
  const segs = String(path || '').match(/\[([^\]]*)\]/g) || [];
  return segs.length ? segs[segs.length - 1].replace(/[[\]]/g, '') : '';
};
/** Drop the last segment: `[A].[B].[C]` → `[A].[B]`. */
const parentOf = (path: string): string => {
  const segs = String(path || '').match(/\[[^\]]*\]/g) || [];
  return segs.slice(0, -1).join('.');
};

// ── Data sources ─────────────────────────────────────────────────────────────

interface FmDataSource { name: string; catalog?: string; schema?: string }

function readDataSources(project: any): Map<string, FmDataSource> {
  const out = new Map<string, FmDataSource>();
  for (const ds of asArray(project?.dataSources?.dataSource)) {
    const n = nameOf(ds);
    if (!n) continue;
    out.set(n, { name: n, catalog: text(ds.catalog) || undefined, schema: text(ds.schema) || undefined });
  }
  return out;
}

// A Database Layer query subject is a plain table passthrough when its SQL is just
// `Select * From [datasource].TABLE [alias]`. Anything else is genuine custom SQL.
const RE_SIMPLE_SELECT =
  /^\s*select\s+(?:\*|[\w$]+\s*\.\s*\*)\s*from\s*\[([^\]]+)\]\s*\.\s*\[?([\w$]+)\]?(?:\s+(?:as\s+)?[\w$]+)?\s*$/i;

/** `#sq($account.personalInfo.email)#` and friends — Cognos's runtime macro syntax. */
const RE_MACRO = /#[^#]{1,400}#/g;

// ── Subject areas ────────────────────────────────────────────────────────────

export interface FmSubjectArea {
  /** Display name of the namespace. */
  name: string;
  /** Full bracket path, e.g. `[Presentation Layer].[Sales]` — unambiguous selector. */
  path: string;
  /** Shortcuts exposed beneath it (recursively) — a rough size signal. */
  objects: number;
}

function countShortcuts(el: any): number {
  let n = asArray(el?.shortcut).length;
  for (const tag of ['namespace', 'folder', 'queryItemFolder'] as const) {
    for (const child of asArray(el?.[tag])) n += countShortcuts(child);
  }
  return n;
}

function collectShortcuts(el: any, out: any[] = []): any[] {
  for (const sc of asArray(el?.shortcut)) out.push(sc);
  for (const tag of ['namespace', 'folder', 'queryItemFolder'] as const) {
    for (const child of asArray(el?.[tag])) collectShortcuts(child, out);
  }
  return out;
}

interface FmParsed { project: any; root: any; index: Map<string, FmObj> }

function parseFm(xml: string): FmParsed {
  const doc = parser.parse(xml);
  const project = doc?.project;
  if (!project) throw new Error('not a Framework Manager project XML (no <project> root)');
  const root = asArray(project.namespace)[0];
  if (!root) throw new Error('Framework Manager model has no root <namespace>');
  return { project, root, index: buildIndex(root) };
}

/**
 * The presentation layer is the top-level layer namespace exposing the most shortcuts.
 * Naming it "Presentation Layer" is a strong convention but NOT guaranteed, so pick by
 * shape rather than by name.
 */
function pickPresentationLayer(root: any): any | null {
  let best: any = null; let bestN = 0;
  for (const ns of asArray(root?.namespace)) {
    const n = countShortcuts(ns);
    if (n > bestN) { best = ns; bestN = n; }
  }
  return bestN > 0 ? best : null;
}

/** Enumerate the convertible subject areas, largest first. */
export function listFrameworkManagerSubjectAreas(xml: string): FmSubjectArea[] {
  const { root } = parseFm(xml);
  const layer = pickPresentationLayer(root);
  const areas: FmSubjectArea[] = [];
  if (layer) {
    const layerName = nameOf(layer);
    for (const ns of asArray(layer.namespace)) {
      areas.push({ name: nameOf(ns), path: joinPath([layerName, nameOf(ns)]), objects: countShortcuts(ns) });
    }
    // A layer may also hold loose shortcuts that belong to no sub-namespace; expose the
    // layer itself so they are reachable.
    if (asArray(layer.shortcut).length) {
      areas.push({ name: layerName, path: joinPath([layerName]), objects: countShortcuts(layer) });
    }
  } else {
    // No shortcut-based presentation layer (some models publish the logical layer
    // directly) — fall back to the layer namespaces themselves.
    for (const ns of asArray(root?.namespace)) {
      const n = asArray(ns.querySubject).length
        + asArray(ns.folder).reduce((a: number, f: any) => a + asArray(f.querySubject).length, 0);
      if (n) areas.push({ name: nameOf(ns), path: joinPath([nameOf(ns)]), objects: n });
    }
  }
  return areas.sort((a, b) => b.objects - a.objects);
}

// ── Ingest ───────────────────────────────────────────────────────────────────

export interface FmOptions {
  /** Subject-area name or full bracket path. Required unless `all`. */
  subjectArea?: string;
  /** Convert the whole presentation layer (large — prefer one subject area). */
  all?: boolean;
}

/** Framework Manager project XML → the shared `CognosModule` IR. */
export function normalizeCognosFrameworkManager(xml: string, opts: FmOptions = {}): CognosModule {
  const ingestWarnings: string[] = [];
  const warn = (m: string) => { ingestWarnings.push(m); };
  const { project, root, index } = parseFm(xml);
  const dataSources = readDataSources(project);
  const modelName = nameOf(root) || text(project.name) || 'Cognos Framework Manager model';

  // ── Select scope ───────────────────────────────────────────────────────────
  const layer = pickPresentationLayer(root);
  let scopeEl: any; let scopeName: string;
  if (opts.all) {
    scopeEl = layer || root;
    scopeName = nameOf(scopeEl) || modelName;
  } else {
    const want = (opts.subjectArea || '').trim();
    if (!want) throw new Error('Framework Manager conversion needs --subject-area (or --all). Run with --list to see them.');
    const areas = listFrameworkManagerSubjectAreas(xml);
    const hit = areas.find((a) => a.path === want)
      || areas.find((a) => a.name.toLowerCase() === want.toLowerCase())
      || areas.find((a) => a.path.toLowerCase() === want.toLowerCase());
    if (!hit) {
      throw new Error(`subject area "${want}" not found. Available: ${areas.map((a) => a.name).join(' | ')}`);
    }
    const found = index.get(hit.path);
    if (!found) throw new Error(`subject area "${hit.path}" is not indexable`);
    scopeEl = found.el; scopeName = hit.name;
  }

  // ── Resolve the subject area's shortcuts down to query subjects ────────────
  const querySubjects: CognosQuerySubject[] = [];
  const byIdentifier = new Map<string, CognosQuerySubject>();
  // Database-Layer path → the IR subject representing it. Alias paths are registered
  // first and are never overwritten, so role-playing dimensions stay distinct (rule 2).
  const anchorToIr = new Map<string, string>();
  const claimAnchor = (path: string, ident: string) => { if (path && !anchorToIr.has(path)) anchorToIr.set(path, ident); };

  const exposed = collectShortcuts(scopeEl);
  if (!exposed.length) {
    // Layer published directly (no shortcuts) — take its query subjects as-is.
    const direct: Array<{ obj: FmObj; label: string }> = [];
    for (const [path, obj] of index) {
      if (obj.kind === 'querySubject' && path.startsWith(joinPath([scopeName]))) {
        direct.push({ obj, label: nameOf(obj.el) });
      }
    }
    for (const d of direct) addSubject(d.obj, d.label, d.obj.path);
  }

  for (const sc of exposed) {
    const label = nameOf(sc);
    const targetPath = text(sc.refobj?.[0] ?? sc.refobj).trim();
    if (!targetPath) continue;
    const target = resolve(index, targetPath);
    if (!target) { warn(`subject area "${scopeName}": shortcut "${label}" → ${targetPath} does not resolve — skipped.`); continue; }
    if (target.kind !== 'querySubject') {
      warn(`subject area "${scopeName}": shortcut "${label}" targets a ${target.kind}, not a query subject — skipped.`);
      continue;
    }
    addSubject(target, label, targetPath);
  }

  /** Turn one resolved query subject into an IR subject named by its presentation label. */
  function addSubject(target: FmObj, label: string, viaPath: string) {
    const identifier = label || leafOf(target.path);
    if (byIdentifier.has(identifier)) return;   // already exposed under this name

    const qsEl = target.el;
    const items: CognosItem[] = [];
    // Which Database-Layer query subject do this subject's items physically come from?
    const tableVotes = new Map<string, number>();
    const aliasVotes = new Map<string, number>();

    const rawItems: Array<{ el: any; isCalc: boolean }> = [
      ...asArray(qsEl.queryItem).map((el: any) => ({ el, isCalc: false })),
      ...asArray(qsEl.calculation).map((el: any) => ({ el, isCalc: true })),
    ];
    // queryItemFolder groups items for display only — flatten it (rule 1).
    for (const f of asArray(qsEl.queryItemFolder)) {
      for (const el of asArray(f.queryItem)) rawItems.push({ el, isCalc: false });
      for (const el of asArray(f.calculation)) rawItems.push({ el, isCalc: true });
    }

    for (const { el, isCalc } of rawItems) {
      const label2 = nameOf(el);
      if (!label2) continue;
      const rawExpr = text(el.expression) || (typeof el.expression === 'string' ? el.expression : '');
      const usage = text(el.usage) || undefined;
      const aggregate = text(el.regularAggregate) || undefined;
      const hidden = text(el.hidden) === 'true';

      if (!isCalc && rawExpr && isPassthrough(rawExpr)) {
        // Plain passthrough: the item IS a physical column. Walk to it for the real name.
        const refs = expressionRefs(rawExpr);
        const physPath = refs[refs.length - 1] || '';
        const physItem = physPath ? resolve(index, physPath) : null;
        const physName = physItem ? (text(physItem.el.externalName) || nameOf(physItem.el)) : leafOf(physPath);
        const ownerPath = physItem ? parentOf(physItem.path) : parentOf(physPath);
        if (ownerPath) tableVotes.set(ownerPath, (tableVotes.get(ownerPath) || 0) + 1);
        // The FIRST ref of a refobjViaShortcut is the alias — the role-playing context.
        const viaAlias = firstViaAlias(rawExpr);
        if (viaAlias) aliasVotes.set(viaAlias, (aliasVotes.get(viaAlias) || 0) + 1);
        items.push({
          identifier: physName || label2,
          label: label2,
          usage, aggregate,
          datatype: text(el.datatype) || undefined,
          isCalculation: false,
          ...(hidden ? { hidden: true } as any : {}),
          ...(ownerPath ? { __owner: ownerPath } as any : {}),
        });
      } else if (rawExpr) {
        // Genuine expression — hand the rebuilt Cognos text to the shared translator.
        items.push({
          identifier: label2, label: label2, usage, aggregate,
          datatype: text(el.datatype) || undefined,
          expression: expressionText(rawExpr),
          isCalculation: true,
        });
      } else {
        // Database-Layer item: no expression, the name IS the column.
        const physName = text(el.externalName) || label2;
        items.push({
          identifier: physName, label: label2, usage, aggregate,
          datatype: text(el.datatype) || undefined, isCalculation: false,
        });
        tableVotes.set(target.path, (tableVotes.get(target.path) || 0) + 1);
      }
    }

    // Dominant physical table. A logical subject that spans several is not expressible as
    // one Sigma table source — keep the dominant one and flag the remainder.
    const ranked = [...tableVotes.entries()].sort((a, b) => b[1] - a[1]);
    const ownerPath = ranked[0]?.[0] || target.path;
    if (ranked.length > 1) {
      const dropped = ranked.slice(1).reduce((n, [, c]) => n + c, 0);
      warn(`"${identifier}": logical query subject spans ${ranked.length} physical tables; ` +
        `sourcing from ${leafOf(ownerPath)} and DROPPING ${dropped} item(s) from the others. ` +
        `Re-author as a sql source or split the subject if those columns are needed.`);
    }
    const keptOwner = ownerPath;
    const usable = items.filter((it: any) => !it.__owner || it.__owner === keptOwner);
    usable.forEach((it: any) => { delete it.__owner; });

    // Physical definition of the owning Database-Layer subject.
    const owner = resolve(index, keptOwner) || target;
    const phys = readPhysical(owner, dataSources, warn, identifier);

    const subject: CognosQuerySubject = {
      identifier,
      label,
      items: usable,
      ...phys,
    };
    const grain = readDeterminantGrain(owner.el);
    if (grain.length) subject.grain = grain;
    const filters = readEmbeddedFilters(qsEl, owner.el);
    if (filters.length) {
      subject.filters = filters;
      warn(`"${identifier}": ${filters.length} embedded Framework Manager filter(s) ` +
        `(${filters.map((f) => f.name).join(', ')}) are NOT applied to the Sigma model — ` +
        `re-create as data-model filters if they are governance rules.`);
    }

    // Anchors for relationship matching: the alias (role) wins over the shared table.
    const alias = [...aliasVotes.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
    if (alias) { subject.aliasOf = leafOf(keptOwner); claimAnchor(alias, identifier); }
    claimAnchor(viaPath, identifier);
    claimAnchor(target.path, identifier);
    if (!alias) claimAnchor(keptOwner, identifier);

    querySubjects.push(subject);
    byIdentifier.set(identifier, subject);
  }

  // ── Relationships ──────────────────────────────────────────────────────────
  const relationships: CognosRelationship[] = [];
  for (const relEl of allRelationships(root)) {
    const leftPath = text(relEl.left?.refobj?.[0] ?? relEl.left?.refobj).trim();
    const rightPath = text(relEl.right?.refobj?.[0] ?? relEl.right?.refobj).trim();
    const leftIr = anchorToIr.get(leftPath);
    const rightIr = anchorToIr.get(rightPath);
    if (!leftIr || !rightIr || leftIr === rightIr) continue;   // outside this subject area

    const rawExpr = text(relEl.expression) || (typeof relEl.expression === 'string' ? relEl.expression : '');
    const parsed = parseFmJoin(rawExpr, leftPath, rightPath);
    if (!parsed.keys.length) {
      warn(`relationship ${leafOf(leftPath)} → ${leafOf(rightPath)}: join condition is not a simple ` +
        `equi-join (${parsed.reason}) — add it by hand in Sigma.`);
      continue;
    }
    if (parsed.nonEqui) {
      warn(`relationship ${leafOf(leftPath)} → ${leafOf(rightPath)}: extra non-equality condition(s) ` +
        `dropped — Sigma relationships are equi-joins only. Verify the result set.`);
    }
    relationships.push({
      left: leftIr, right: rightIr,
      leftKey: parsed.keys[0].leftKey, rightKey: parsed.keys[0].rightKey,
      keys: parsed.keys,
      leftCard: text(relEl.left?.maxcard) || undefined,
      rightCard: text(relEl.right?.maxcard) || undefined,
    });
  }

  // ── Security (detect-only) ─────────────────────────────────────────────────
  const securityFilters: CognosSecurityFilter[] = [];
  for (const qs of querySubjects) {
    for (const macro of String(qs.sql || '').match(RE_MACRO) || []) {
      securityFilters.push({
        type: 'framework-manager-macro',
        subject: qs.identifier,
        name: 'runtime macro in query subject SQL',
        expression: macro,
      });
    }
  }
  for (const sv of asArray(project?.securityViews?.securityView)) {
    const sets = asArray(sv.definition?.set);
    securityFilters.push({
      type: 'framework-manager-security-view',
      name: nameOf(sv),
      expression: sets.map((s: any) =>
        `${s['@_includeRule'] || 'include'}: ${asArray(s.refobj).map((r: any) => text(r)).join(', ')}`).join(' | '),
    });
  }
  const paramMaps = asArray(project?.parameterMaps?.parameterMap).map((p: any) => nameOf(p)).filter(Boolean);
  if (paramMaps.length) {
    warn(`model defines ${paramMaps.length} parameter map(s) (${paramMaps.join(', ')}) — session-parameter ` +
      `substitution is NOT translated. Any SQL or filter depending on them needs manual review.`);
  }
  const dmr = asArray(root?.namespace).reduce((n: number, ns: any) => n + countDimensions(ns), 0);
  if (dmr) {
    warn(`model defines ${dmr} DMR dimension(s) (hierarchies/levels) — dimensional metadata is NOT ` +
      `converted; Sigma has no OLAP hierarchy equivalent. Re-author drill paths in the workbook.`);
  }

  return { name: `${modelName} — ${scopeName}`, querySubjects, relationships, securityFilters, ingestWarnings };
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/** The alias (role-playing) half of the first refobjViaShortcut in an expression. */
function firstViaAlias(raw: string): string | null {
  RE_VIA.lastIndex = 0;
  const m = RE_VIA.exec(String(raw || ''));
  if (!m) return null;
  const inner = [...String(m[1]).matchAll(/<refobj>([\s\S]*?)<\/refobj>/gi)].map((x) => x[1].trim());
  return inner.length > 1 ? inner[0] : null;
}

/** Physical source of a Database-Layer query subject: a table path, or custom SQL. */
function readPhysical(
  owner: FmObj, dataSources: Map<string, FmDataSource>, warn: (m: string) => void, subjectName: string,
): Partial<CognosQuerySubject> {
  const dbQuery = owner.el?.definition?.dbQuery;
  if (!dbQuery) return { table: leafOf(owner.path) };   // modelQuery-only — name is all we have

  const sqlRaw = text(dbQuery.sql) || (typeof dbQuery.sql === 'string' ? dbQuery.sql : '');
  const sql = decodeEntities(String(sqlRaw).replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim();
  const dsRef = text(dbQuery.sources?.dataSourceRef);
  const dsName = leafOf(dsRef);
  const ds = dataSources.get(dsName);

  const simple = RE_SIMPLE_SELECT.exec(sql);
  if (simple) {
    const table = simple[2];
    return { table, database: ds?.catalog, schema: ds?.schema };
  }
  // Genuine custom SQL → a Sigma `sql` source. Rewrite Cognos's `[datasource].TABLE`
  // bracket form into a fully-qualified warehouse name so the statement runs as-is.
  let statement = sql;
  statement = statement.replace(/\[([^\]]+)\]\s*\.\s*\[?([\w$]+)\]?/g, (m0, dsn, tbl) => {
    const d = dataSources.get(String(dsn));
    if (!d) return m0;
    return [d.catalog, d.schema, tbl].filter(Boolean).join('.');
  });
  if (RE_MACRO.test(statement)) {
    RE_MACRO.lastIndex = 0;
    warn(`"${subjectName}": custom SQL contains a Cognos runtime macro — it is passed through ` +
      `VERBATIM and will not execute in Sigma. Replace it (e.g. $account.personalInfo.email → ` +
      `CurrentUserEmail()) before posting.`);
  }
  return { sql: statement };
}

/** `<determinant><key><refobj>…` → the declared grain columns. */
function readDeterminantGrain(el: any): string[] {
  const out: string[] = [];
  for (const d of asArray(el?.determinants?.determinant ?? el?.determinant)) {
    if (text(d.identifiesRow) !== 'true' && !asArray(d.key?.refobj).length) continue;
    for (const r of asArray(d.key?.refobj)) out.push(leafOf(text(r)));
  }
  return [...new Set(out.filter(Boolean))];
}

function readEmbeddedFilters(...els: any[]): Array<{ name: string; expression: string; apply?: string }> {
  const out: Array<{ name: string; expression: string; apply?: string }> = [];
  for (const el of els) {
    for (const fd of asArray(el?.filters?.filterDefinition)) {
      const raw = text(fd.expression) || (typeof fd.expression === 'string' ? fd.expression : '');
      out.push({
        name: text(fd.displayName) || nameOf(fd) || 'filter',
        expression: expressionText(raw),
        apply: fd['@_apply'] || undefined,
      });
    }
  }
  return out;
}

function allRelationships(node: any, out: any[] = []): any[] {
  for (const r of asArray(node?.relationship)) out.push(r);
  for (const tag of ['namespace', 'folder', 'queryItemFolder'] as const) {
    for (const child of asArray(node?.[tag])) allRelationships(child, out);
  }
  return out;
}

function countDimensions(node: any): number {
  let n = asArray(node?.dimension).length;
  for (const tag of ['namespace', 'folder'] as const) {
    for (const child of asArray(node?.[tag])) n += countDimensions(child);
  }
  return n;
}

/**
 * Parse an FM relationship expression into equi-join key pairs.
 * Shape: `<refobjViaShortcut>alias, item</refobjViaShortcut> = <refobj>item</refobj>`,
 * optionally several joined by AND (a composite key).
 */
function parseFmJoin(raw: string, leftPath: string, rightPath: string): {
  keys: Array<{ leftKey: string; rightKey: string }>; nonEqui: boolean; reason: string;
} {
  const keys: Array<{ leftKey: string; rightKey: string }> = [];
  let nonEqui = false;
  let reason = 'no equality condition found';

  // Split on AND at the top level. FM writes conditions flat, so a plain split is safe;
  // an OR anywhere means the condition is not a conjunction of equalities.
  const body = String(raw || '');
  if (/\bor\b/i.test(body.replace(/<[^>]*>/g, ' '))) {
    return { keys: [], nonEqui: true, reason: 'contains OR' };
  }
  const conds = body.split(/\band\b/i);

  for (const cond of conds) {
    const sides = cond.split('=');
    if (sides.length !== 2) { if (cond.trim()) nonEqui = true; continue; }
    const a = sideRef(sides[0]); const b = sideRef(sides[1]);
    if (!a || !b) { nonEqui = true; continue; }
    // Assign each side to the relationship's declared left/right endpoint.
    const aIsLeft = belongsTo(a, leftPath);
    const bIsLeft = belongsTo(b, leftPath);
    if (aIsLeft && !bIsLeft) keys.push({ leftKey: a.column, rightKey: b.column });
    else if (bIsLeft && !aIsLeft) keys.push({ leftKey: b.column, rightKey: a.column });
    else keys.push({ leftKey: a.column, rightKey: b.column });   // ambiguous — declared order
  }
  if (keys.length) reason = '';
  return { keys, nonEqui, reason };
}

/** One side of a join condition → `{ owner, column }`. */
function sideRef(chunk: string): { owner: string; column: string } | null {
  const refs = expressionRefs(chunk);
  if (!refs.length) return null;
  const alias = firstViaAlias(chunk);
  const item = refs[refs.length - 1];
  return { owner: alias || parentOf(item), column: leafOf(item) };
}

function belongsTo(side: { owner: string; column: string }, endpointPath: string): boolean {
  if (!side.owner || !endpointPath) return false;
  return side.owner === endpointPath || leafOf(side.owner) === leafOf(endpointPath);
}
