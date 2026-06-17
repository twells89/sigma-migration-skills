#!/usr/bin/env node
// migrate-cognos.mjs — ONE-COMMAND orchestrator for the cognos-to-sigma
// pipeline: module convert → DM-reuse check → DM post (gated) → report convert
// → remap → workbook post (gated) → layout → parity. Mirrors qlik-to-sigma's
// migrate-qlik.rb: every phase prints a visible header + concise result, the
// genuine human decision points surface as a structured OPEN QUESTIONS block
// (exit 10) instead of being silently auto-resolved, and the hard gates
// (post-and-readback error-column scan, apply-layout readback, assert-parity
// --check) are NEVER bypassed — the command fails when a gate fails.
//
// This script does NOT re-implement any phase — it chains the per-phase pieces
// (each independently usable):
//   converter/cli.ts          (Phase 1 — module.json → Sigma DM spec;
//                              Phase 4 — report.xml → Sigma workbook spec)
//   cognos-dm-signature.py + find-or-pick-dm.rb
//                             (Phase 2 — DM-reuse scan; default BUILD NEW,
//                              candidates printed, --reuse-dm opts in)
//   post-and-readback.mjs     (Phase 3 DM + Phase 5 workbook — POST + the
//                              error-typed-column hard gate)
//   remap-wb-to-dm-ids.mjs    (Phase 4 — placeholder elementIds → real DM ids)
//   apply-layout.mjs          (Phase 6 — clean 24-col grid; readback-verified)
//   assert-parity.mjs         (Phase 7 — --plan emits the per-element query
//                              list; --check is the GREEN gate)
//
// Parity is two-pass: pass 1 auto-exports every workbook element to CSV via
// the Sigma REST export API and writes sigma-actuals.json (keys
// "<Element>/<Column>" = column sum, "<Element>/rows" = row count), prints the
// assert-parity --plan query list (mcp-v2 alternative), then exits 10 with
// resume instructions. The EXPECTED numbers must come from the Cognos report —
// they cannot be invented here. Resume with:
//   node scripts/migrate-cognos.mjs --resume --out <WORKDIR> --expected expected.json
// or run end-to-end in one shot when expected.json already exists:
//   ... --expected expected.json
//
// Usage:
//   node scripts/migrate-cognos.mjs \
//     --module <module.json> --report <report.xml> \
//     --connection <SIGMA_CONNECTION_ID> \
//     [--folder <SIGMA_FOLDER_ID>]     # default: YOUR My Documents, resolved
//                                      # via whoami (list candidates with
//                                      # GET /v2/files?typeFilters=folder)
//     [--database CSA] [--schema TJ] [--name '<prefix for DM/workbook names>'] \
//     [--out DIR] [--expected expected.json] [--tol 0.01] \
//     [--reuse-dm [dataModelId]]   # opt IN to DM reuse (default: build new;
//                                  # bare flag = use the picker's recommendation)
//     [--skip-reuse-scan]          # don't scan existing DMs at all
//     [--answers '<json>'] [--yes] # resolve the OPEN QUESTIONS block
//     [--resume]                   # jump to parity against the posted ids in
//                                  # <out>/migrate-state.json
//     [--dry-run]                  # convert only; no Sigma POSTs
//
// Exit codes: 0 = PARITY GREEN; 10 = stopped for human input (open questions
// or expected-values needed — state saved, resume supported); 3 = built but
// parity RED; other = error / gate failure.
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, mkdirSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CONV = join(HERE, '..', 'converter');

// ---------------------------------------------------------------------------
// args
// ---------------------------------------------------------------------------
const argv = process.argv.slice(2);
const opt = {};
for (let i = 0; i < argv.length; i++) {
  if (!argv[i].startsWith('--')) continue;
  const k = argv[i].slice(2);
  const next = argv[i + 1];
  opt[k] = (next == null || next.startsWith('--')) ? true : (i++, next);
}
const die = (m, code = 1) => { console.error(`FATAL: ${m}`); process.exit(code); };

if (!opt.resume) {
  if (!opt.module) die('missing --module <module.json>');
  if (!opt.report) die('missing --report <report.xml>');
  if (!opt.connection) die('missing --connection');
  // --folder is optional (bead eqom): when unset, the caller's My Documents is
  // resolved via whoami right before the first POST (see resolveFolder).
}
const slug = basename((opt.module || opt.out || 'cognos')).replace(/\.[^.]+$/, '').replace(/[^A-Za-z0-9_-]/g, '-');
const WORK = resolve(opt.out || join(homedir(), 'cognos-migration', slug));
mkdirSync(WORK, { recursive: true });
const statePath = join(WORK, 'migrate-state.json');
const TOL = Number(opt.tol ?? 0.01);

const TOTAL = 7;
const hdr = (n, t) => console.log(`\n── Phase ${n}/${TOTAL} · ${t} ──`);
const line = (m) => console.log(`   ${m}`);

// ---------------------------------------------------------------------------
// Sigma env bootstrap — same path as the per-phase scripts: get-token.sh
// (which itself falls back to ~/.sigma-migration/env). All children inherit.
// ---------------------------------------------------------------------------
function sigmaLogin() {
  if (process.env.SIGMA_API_TOKEN && process.env.SIGMA_BASE_URL) return;
  const r = spawnSync('bash', ['-c',
    `[ -f "$HOME/.sigma-migration/env" ] && . "$HOME/.sigma-migration/env"; ` +
    `eval "$('${join(HERE, 'get-token.sh')}')" && env | grep '^SIGMA_'`], { encoding: 'utf8' });
  if (r.status !== 0) die(`Sigma token bootstrap failed:\n${r.stderr || r.stdout}`);
  for (const l of r.stdout.split('\n')) {
    const m = l.match(/^(SIGMA_[A-Z_]+)=(.*)$/);
    if (m) process.env[m[1]] = m[2];
  }
  if (!process.env.SIGMA_API_TOKEN) die('get-token.sh did not yield SIGMA_API_TOKEN');
}

// Run a child, stream output indented; hard-fail unless allowFail.
function run(cmd, args, { allowFail = false, capture = false, cwd = undefined } = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, cwd });
  const out = (r.stdout || '') + (r.stderr || '');
  if (!capture && out.trim()) out.split('\n').forEach((l) => l.trim() && console.log('   ' + l));
  if (r.status !== 0 && !allowFail) die(`command failed (${r.status}): ${cmd} ${args.join(' ')}\n${capture ? out : ''}`);
  return { status: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
}

// Minimal Sigma REST (for the parity auto-export only — builders go through the
// per-phase scripts).
async function api(method, path, body) {
  const base = process.env.SIGMA_BASE_URL.replace(/\/$/, '');
  const res = await fetch(base + path, {
    method,
    headers: { Authorization: `Bearer ${process.env.SIGMA_API_TOKEN}`, 'Content-Type': 'application/json' },
    body: body == null ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null; try { json = JSON.parse(text); } catch { /* csv/yaml */ }
  return { status: res.status, ok: res.ok, text, json };
}

// --folder default (bead eqom; prior art: migrate-tableau.rb's folderId
// default). POST /v2/dataModels/spec and the workbook post both REQUIRE a
// folderId — when none is supplied, resolve the caller's My Documents via
// whoami and use it (never emit a folderless POST, never guess a folder).
async function resolveFolder() {
  const who = await api('GET', '/v2/whoami');
  const uid = who.json?.userId;
  if (!uid) die(`could not resolve My Documents: whoami → HTTP ${who.status} — pass --folder <id>`);
  const mine = await api('GET', `/v2/members/${uid}/files`);
  let entry = (mine.json?.entries || []).find((e) => e.path === 'My Documents');
  if (!entry?.parentId) {
    const all = await api('GET', '/v2/files?typeFilters=folder&limit=500');
    entry = (all.json?.entries || []).find((e) => e.path === 'My Documents' && e.ownerId === uid);
  }
  if (!entry?.parentId) die('could not resolve the caller\'s My Documents folder id — pass --folder <id> (find one via GET /v2/files?typeFilters=folder)');
  line(`no --folder supplied — using your My Documents (${entry.parentId})`);
  return entry.parentId;
}

// Tiny CSV parser (quoted fields, no embedded newlines-in-quotes edge beyond basic).
function parseCsv(text) {
  const rows = [];
  let row = [], field = '', inQ = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQ) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else inQ = false; }
      else field += c;
    } else if (c === '"') inQ = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
    else if (c !== '\r') field += c;
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row); }
  return rows.filter((r) => r.length > 1 || (r.length === 1 && r[0] !== ''));
}

const numish = (s) => {
  if (s == null) return null;
  const t = String(s).replace(/[$,%\s]/g, '');
  return /^-?\d+(\.\d+)?$/.test(t) ? Number(t) : null;
};

// ---------------------------------------------------------------------------
// Parity (Phase 7) — shared by the straight-through path and --resume.
// ---------------------------------------------------------------------------
async function runParity(state) {
  hdr(7, 'Parity');

  // SOURCE-FRESHNESS banner BEFORE any side-by-side (pattern requirement):
  // Cognos report numbers are a snapshot of whenever the report was last run /
  // captured; Sigma queries the LIVE warehouse.
  console.log('   ── SOURCE FRESHNESS (read this before any side-by-side) ──');
  if (state.moduleFile && existsSync(state.moduleFile)) {
    const mt = statSync(state.moduleFile).mtime;
    const days = ((Date.now() - mt.getTime()) / 86400e3).toFixed(1);
    line(`Cognos module export captured ${mt.toISOString()} (~${days} day(s) ago).`);
  }
  line('Sigma queries the LIVE warehouse; expected.json reflects the Cognos report AS CAPTURED.');
  line('If the source tables changed since capture, deltas are STALENESS, not conversion errors —');
  line('re-run the Cognos report (or re-query the source DB) before calling a divergence a bug.');

  // Auto-actuals: export every data-bearing workbook element to CSV via REST
  // and aggregate to "<Element>/<Column>"=sum + "<Element>/rows"=count.
  const els = (state.wbElements || []).filter((e) => !['control', 'text'].includes(String(e.kind)));
  // Duplicate display names (a Cognos report can render the same query twice —
  // e.g. two "Sheet 1 — qMain" tables) would collide on a name-only parity key
  // and only ONE would verify. Disambiguate dupes with an elementId suffix
  // (bead eqom); unique names keep the plain key so existing expected.json
  // files stay valid.
  const nameCounts = {};
  for (const e of els) nameCounts[e.name] = (nameCounts[e.name] || 0) + 1;
  const keyOf = (e) => (nameCounts[e.name] > 1 ? `${e.name} [${e.id}]` : e.name);
  const dupes = Object.entries(nameCounts).filter(([, n]) => n > 1);
  line('');
  line(`exporting ${els.length} element(s) for Sigma actuals…`);
  if (dupes.length) line(`duplicate element name(s) ${dupes.map(([n]) => `'${n}'`).join(', ')} — parity keys get an elementId suffix: "<Name> [<elementId>]"`);
  const actuals = {};
  for (const e of els) {
    const post = await api('POST', `/v2/workbooks/${state.workbookId}/export`,
      { elementId: e.id, format: { type: 'csv' } });
    const qid = post.json?.queryId;
    if (!qid) { line(`WARN: export request failed for '${e.name}' (HTTP ${post.status})`); continue; }
    let body = null;
    const deadline = Date.now() + 240e3;
    while (Date.now() < deadline) {
      const dl = await api('GET', `/v2/query/${qid}/download`);
      if (dl.ok && dl.text && dl.text.trim()) { body = dl.text; break; }
      await new Promise((r) => setTimeout(r, 2000));
    }
    if (!body) { line(`WARN: export never became ready for '${e.name}'`); continue; }
    const rows = parseCsv(body);
    const headers = rows[0] || [];
    const data = rows.slice(1);
    const key = keyOf(e);
    actuals[`${key}/rows`] = data.length;
    headers.forEach((h, ci) => {
      const vals = data.map((r) => numish(r[ci])).filter((v) => v != null);
      if (vals.length === data.length && data.length > 0) {
        actuals[`${key}/${h}`] = Number(vals.reduce((a, b) => a + b, 0).toFixed(6));
      }
    });
    line(`'${key}': ${data.length} row(s), ${headers.length} col(s)`);
  }
  const actualsPath = join(WORK, 'sigma-actuals.json');
  writeFileSync(actualsPath, JSON.stringify(actuals, null, 2));
  line(`Sigma actuals → ${actualsPath} (${Object.keys(actuals).length} key(s))`);

  // The per-element query list (mcp-v2 alternative / drill-down path).
  console.log('');
  run('node', [join(HERE, 'assert-parity.mjs'), '--plan', '--type', 'workbook', '--id', state.workbookId]);

  const expectedPath = opt.expected ? resolve(opt.expected) : state.expectedPath;
  if (!expectedPath || !existsSync(expectedPath)) {
    console.log('\n==================== PARITY INPUT NEEDED ====================');
    console.log('Sigma actuals are exported. The EXPECTED numbers must come from the');
    console.log('Cognos report (run it, or query the source DB) — they cannot be');
    console.log('derived here. Write expected.json using the SAME keys as');
    console.log(`${actualsPath}`);
    console.log('(subset is fine — every key present is checked), then resume:');
    console.log(`  node scripts/migrate-cognos.mjs --resume --out ${WORK} --expected expected.json`);
    console.log('=============================================================');
    state.actualsPath = actualsPath;
    writeFileSync(statePath, JSON.stringify(state, null, 2));
    console.log('\n================ RESULT (parity pending) ================');
    console.log(`dataModelId : ${state.dataModelId}`);
    console.log(`workbookId  : ${state.workbookId}`);
    console.log('PARITY      : PENDING — expected.json needed (see above)');
    console.log('=========================================================');
    process.exit(10);
  }

  const actualArg = opt.actuals ? resolve(opt.actuals) : actualsPath;
  const chk = run('node', [join(HERE, 'assert-parity.mjs'), '--check',
    '--actual', actualArg, '--expected', expectedPath, '--tol', String(TOL)], { allowFail: true });
  const green = chk.status === 0;
  console.log('\n================ RESULT ================');
  console.log(`dataModelId : ${state.dataModelId}${state.reusedDm ? '  (REUSED existing DM)' : ''}`);
  console.log(`workbookId  : ${state.workbookId}`);
  console.log(`PARITY      : ${green ? 'GREEN' : 'RED'} (assert-parity --check, tol ±${TOL * 100}%)`);
  if (state.securityRules) console.log(`security    : ${state.securityRules} RLS rule(s) detected — NOT auto-ported; run apply_sigma_rls.py (see SKILL.md "Security")`);
  console.log('========================================');
  process.exit(green ? 0 : 3);
}

// ---------------------------------------------------------------------------
// --resume: parity-only against saved state.
// ---------------------------------------------------------------------------
if (opt.resume) {
  if (!existsSync(statePath)) die(`--resume: no state at ${statePath} (pass --out <workdir>)`);
  const state = JSON.parse(readFileSync(statePath, 'utf8'));
  if (!state.workbookId) die('--resume: state has no workbookId (the build never completed)');
  sigmaLogin();
  console.log(`resuming parity for workbook ${state.workbookId} (state: ${statePath})`);
  await runParity(state);
}

// ---------------------------------------------------------------------------
// Phase 1 — Convert the Data Module → Sigma DM spec (converter/cli.ts).
// ---------------------------------------------------------------------------
hdr(1, 'Convert data module');
// One-time converter-deps preflight (bead eqom): node_modules existing is NOT
// enough — the converter shells `node --import tsx/esm`, so require the tsx
// binary specifically and fail with a clear, actionable error (not a cryptic
// ERR_MODULE_NOT_FOUND three phases in).
if (!existsSync(join(CONV, 'node_modules', '.bin', 'tsx'))) {
  line('converter deps missing — running npm install (once)…');
  const inst = run('npm', ['install', '--silent'], { cwd: CONV, allowFail: true });
  if (inst.status !== 0 || !existsSync(join(CONV, 'node_modules', '.bin', 'tsx'))) {
    die(`converter dependencies could not be installed automatically.\n` +
        `  Run manually:  cd ${CONV} && npm install\n` +
        `  (requires Node >= 18 and npm on PATH; the converter runs via tsx)`);
  }
}
const modulePath = resolve(opt.module);
const reportPath = resolve(opt.report);
const db = opt.database || 'CSA';
const schema = opt.schema || 'TJ';
const securityPath = join(WORK, 'security.json');
const conv = spawnSync('node', ['--import', 'tsx/esm', join(CONV, 'cli.ts'), modulePath,
  '--connection', opt.connection, '--database', db, '--schema', schema,
  '--security-out', securityPath],
  { encoding: 'utf8', cwd: CONV, maxBuffer: 64 * 1024 * 1024 });
if (conv.status !== 0) die(`module converter failed:\n${conv.stderr}`);
const dmSpec = JSON.parse(conv.stdout);
const dmPath = join(WORK, 'dm.json');
writeFileSync(dmPath, JSON.stringify(dmSpec, null, 2));
const convWarnings = conv.stderr.split('\n').filter((l) => l.trim().startsWith('!')).map((l) => l.replace(/^\s*!\s*/, ''));
const statsLine = (conv.stderr.match(/stats: (\{.*\})/) || [])[1];
const securityDetected = existsSync(securityPath) ? JSON.parse(readFileSync(securityPath, 'utf8')) : [];
line(`module '${dmSpec.name || basename(modulePath)}' → DM spec (${statsLine || 'no stats'}); ${convWarnings.length} warning(s)`);
if (securityDetected.length) line(`SECURITY: ${securityDetected.length} rule(s) detected → ${securityPath} (ported AFTER post via apply_sigma_rls.py — never silently)`);

const namePrefix = typeof opt.name === 'string' ? opt.name : null;
const dmName = namePrefix ? `${namePrefix} ${dmSpec.name || 'Cognos DM'}` : (dmSpec.name || `Cognos DM ${slug}`);

// ---------------------------------------------------------------------------
// Phase 2 — DM-reuse scan (find-or-pick-dm). Default = BUILD NEW; candidates
// are printed so a human can opt in with --reuse-dm.
// ---------------------------------------------------------------------------
hdr(2, 'DM-reuse scan');
let reuseDmId = null;
let match = null;
if (opt['skip-reuse-scan'] || opt['dry-run']) {
  line(opt['dry-run'] ? 'dry-run — skipping the org DM scan' : 'skipped (--skip-reuse-scan)');
} else {
  sigmaLogin();
  const sigPath = join(WORK, 'dm-signature.json');
  run('python3', [join(HERE, 'cognos-dm-signature.py'), '--dm-spec', dmPath, '--out', sigPath]);
  const matchPath = join(WORK, 'dm-match.json');
  run('ruby', [join(HERE, 'find-or-pick-dm.rb'), '--workbook-signature', sigPath, '--out', matchPath,
    '--auto-pick', '--auto-pick-threshold', '0.5'],
    { allowFail: true }); // exit 1 = no candidate ≥ min-score (normal)
  match = existsSync(matchPath) ? JSON.parse(readFileSync(matchPath, 'utf8')) : {};
  const cands = (match.candidates || []).slice(0, 3);
  if (opt['reuse-dm']) {
    reuseDmId = typeof opt['reuse-dm'] === 'string' ? opt['reuse-dm'] : (match.recommended_dm_id || null);
    if (!reuseDmId) die(`--reuse-dm: picker found no candidate ≥ min-score (top: ${cands[0] ? cands[0].score : 'none'}); pass an explicit --reuse-dm <dataModelId> or drop the flag to build new`, 1);
    line(`REUSING data model ${reuseDmId} (Phase 3 skipped). Inherited columns/metrics/RLS come with it.`);
  } else if (match.auto_picked && match.recommended_dm_id) {
    // Reuse-first: picker confirmed the top candidate covers ALL source tables (safe reuse).
    reuseDmId = match.recommended_dm_id;
    line(`   DM-REUSE (auto): ${match.rationale || `covers all source tables → reusing ${reuseDmId}`}`);
    if (match.warning) line(`   warning: ${match.warning}`);
  }
  if (!reuseDmId) {
    if (cands.length) {
      line(`top candidate(s) — none auto-reused (no single DM covers all tables); pass --reuse-dm to opt in:`);
      cands.forEach((c) => line(`  score ${(c.score ?? 0).toFixed(2)}  ${c.dm_id}  '${c.dm_name}'`));
    } else {
      line('no existing DM covers this module — building new');
    }
  }
}

// ---------------------------------------------------------------------------
// DECISIONS CHECKPOINT — genuine human questions ONLY (mechanical POST / remap
// / layout / parity are never asked about).
// ---------------------------------------------------------------------------
const questions = [];
for (const w of convWarnings) {
  questions.push({
    id: 'expression_flagged', severity: 'review', detail: w,
    options: ['proceed (construct flagged, placeholder/warning kept — close via gap-scout later)',
      'abort and re-author manually'],
    default: 'proceed (construct flagged, placeholder/warning kept — close via gap-scout later)',
  });
}
if (securityDetected.length) {
  questions.push({
    id: 'security_detected', severity: 'required',
    detail: `${securityDetected.length} Cognos security filter(s) detected. They are NOT auto-ported — after the model posts, run scripts/apply_sigma_rls.py --from-security ${securityPath} --dm-id <id> (see SKILL.md "Security"). Skipping leaves ALL rows visible to everyone.`,
    options: ['proceed (port security via apply_sigma_rls.py after the post)',
      'abort until security is designed'],
    default: 'proceed (port security via apply_sigma_rls.py after the post)',
  });
}
let answers = null;
if (opt.answers) { try { answers = JSON.parse(opt.answers); } catch { die('--answers is not valid JSON'); } }
if (questions.length && !opt.yes && !answers) {
  console.log('\n==================== OPEN QUESTIONS ====================');
  console.log(JSON.stringify({
    status: 'decisions_needed',
    module: dmSpec.name || basename(modulePath),
    phases_completed: ['1 Convert', '2 DM-reuse scan'],
    note: 'Deterministic mechanical steps (POST, remap, layout, parity) are NOT asked about. ' +
      "Re-run with --yes to accept all defaults, or --answers '{\"<id>\":\"<choice>\"}' to override.",
    open_questions: questions,
  }, null, 2));
  console.log('========================================================');
  console.log(`\n${questions.length} decision(s) need a human. No Sigma objects were created.`);
  process.exit(10);
}
if (questions.length) {
  line(`decisions auto-resolved (${opt.yes ? '--yes: defaults' : '--answers supplied'}):`);
  for (const q of questions) {
    const chosen = (answers && answers[q.id]) || q.default;
    line(`  - ${q.id}: ${chosen}`);
    if (String(chosen).startsWith('abort')) {
      console.log(`   '${q.id}' answered abort — stopping before any Sigma object is created.`);
      process.exit(10);
    }
  }
} else line('no open questions — running straight through');

if (opt['dry-run']) {
  hdr(3, 'Build data model');
  line(`DRY RUN: DM spec → ${dmPath} (no POST)`);
  hdr(4, 'Convert report');
  const rconv = spawnSync('node', ['--import', 'tsx/esm', join(CONV, 'cli.ts'), reportPath, '--dm', 'DRY-RUN'],
    { encoding: 'utf8', cwd: CONV, maxBuffer: 64 * 1024 * 1024 });
  if (rconv.status !== 0) die(`report converter failed:\n${rconv.stderr}`);
  writeFileSync(join(WORK, 'wb.json'), rconv.stdout);
  line(`DRY RUN: workbook spec → ${join(WORK, 'wb.json')} (placeholder DM id, no remap/POST)`);
  console.log('\n================ RESULT (dry run) ================');
  console.log(`specs       : ${WORK}`);
  console.log('==================================================');
  process.exit(0);
}

sigmaLogin();
if (!opt.folder) opt.folder = await resolveFolder();
const state = { workdir: WORK, moduleFile: modulePath, reportFile: reportPath,
  securityRules: securityDetected.length || 0 };

// ---------------------------------------------------------------------------
// Phase 3 — POST the data model + readback (HARD GATE: error-typed columns).
// ---------------------------------------------------------------------------
hdr(3, 'Build data model');
const dmMapPath = join(WORK, 'dm-map.json');
let dmId;
if (reuseDmId) {
  dmId = reuseDmId;
  state.reusedDm = true;
  line(`reusing data model ${dmId} — no POST (remap matches the report to ITS elements by name)`);
} else {
  run('node', [join(HERE, 'post-and-readback.mjs'), '--type', 'datamodel', '--spec', dmPath,
    '--folder', opt.folder, '--name', dmName, '--out', dmMapPath]);
  dmId = JSON.parse(readFileSync(dmMapPath, 'utf8')).dataModelId;
}
state.dataModelId = dmId;
line(`dataModelId = ${dmId}`);
writeFileSync(statePath, JSON.stringify(state, null, 2));

// ---------------------------------------------------------------------------
// Phase 4 — Convert the report → workbook spec, remap to the real DM ids.
// ---------------------------------------------------------------------------
hdr(4, 'Convert report + remap');
const rconv = spawnSync('node', ['--import', 'tsx/esm', join(CONV, 'cli.ts'), reportPath, '--dm', dmId],
  { encoding: 'utf8', cwd: CONV, maxBuffer: 64 * 1024 * 1024 });
if (rconv.status !== 0) die(`report converter failed:\n${rconv.stderr}`);
const wbSpec = JSON.parse(rconv.stdout);
const rWarnings = rconv.stderr.split('\n').filter((l) => l.trim().startsWith('!')).map((l) => l.replace(/^\s*!\s*/, ''));
const rStats = (rconv.stderr.match(/stats: (\{.*\})/) || [])[1];
const wbPath = join(WORK, 'wb.json');
writeFileSync(wbPath, JSON.stringify(wbSpec, null, 2));
line(`report → workbook spec (${rStats || 'no stats'}); ${rWarnings.length} warning(s)`);
rWarnings.forEach((w) => line(`  ! ${w}`));
const wbRemapped = join(WORK, 'wb.remapped.json');
run('node', [join(HERE, 'remap-wb-to-dm-ids.mjs'), '--wb', wbPath, '--dm-id', dmId, '--out', wbRemapped]);

// ---------------------------------------------------------------------------
// Phase 5 — POST the workbook + readback (HARD GATE: error-typed columns).
// ---------------------------------------------------------------------------
hdr(5, 'Build workbook');
const wbName = namePrefix ? `${namePrefix} ${wbSpec.name || 'Cognos report'}` : (wbSpec.name || `Cognos report ${slug}`);
const wbMapPath = join(WORK, 'wb-map.json');
run('node', [join(HERE, 'post-and-readback.mjs'), '--type', 'workbook', '--spec', wbRemapped,
  '--folder', opt.folder, '--name', wbName, '--out', wbMapPath]);
const wbMap = JSON.parse(readFileSync(wbMapPath, 'utf8'));
state.workbookId = wbMap.workbookId;
state.wbElements = wbMap.elements || [];
line(`workbookId = ${state.workbookId} (${state.wbElements.length} element(s), 0 error columns)`);
writeFileSync(statePath, JSON.stringify(state, null, 2));

// ---------------------------------------------------------------------------
// Phase 6 — Layout (HARD GATE: apply-layout verifies the grid survives readback;
// per SKILL.md layout cleanliness is part of parity).
// ---------------------------------------------------------------------------
hdr(6, 'Layout');
run('node', [join(HERE, 'apply-layout.mjs'), '--workbook', state.workbookId]);

// ---------------------------------------------------------------------------
// Phase 7 — Parity.
// ---------------------------------------------------------------------------
state.expectedPath = opt.expected ? resolve(opt.expected) : null;
writeFileSync(statePath, JSON.stringify(state, null, 2));
await runParity(state);
