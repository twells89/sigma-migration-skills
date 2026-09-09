#!/usr/bin/env node
// post-and-readback.mjs — POST a Metabase-converted DM or workbook spec, then read it
// back and FAIL LOUDLY on any error-typed column (a spec can POST 200 yet have
// formulas that don't resolve at query time — those surface as type "error").
//
// Workbook POSTs additionally run the SHARED layout + control lints on the
// readback spec (scripts/lib/layout_lint.rb / control_lint.rb — vendored
// byte-identical across the sigma-migration-skills plugins; gate 6/7 of
// assert-phase6-ran.rb re-checks the same thing later). The control lint picks
// up the control-scope.json sidecar next to --spec (or --control-scope PATH).
//
// Usage:
//   eval "$(scripts/get-token.sh)"
//   node scripts/post-and-readback.mjs --type datamodel|workbook --spec spec.json --folder <folderId> \
//     [--name N] [--out map.json] [--control-scope scope.json]
//     [--keep-rejected-bindings]   # legacy behavior: if the org rejects
//                                  # control→DM-parameter bindings, keep the
//                                  # (now-decorative) controls and only strip
//                                  # the binding. Default is to DROP them: a
//                                  # control that provably drives nothing is
//                                  # the exact furniture gate 7 exists to block
//                                  # (the customer-feedback issue was "controls
//                                  # not driving anything"). The DM {{tag}}
//                                  # controls still carry the filter — re-add a
//                                  # workbook control synced to the DM
//                                  # parameter in the UI when the org enables it.
//
// Prints { dataModelId|workbookId, errors:[...] } and exits non-zero if any error
// columns (exit 1) or lint violations (exit 4 = control, exit 5 = layout).
import { readFileSync, writeFileSync, appendFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { api, extractId, parseArgs, elementsOf } from './lib/sigma-rest.mjs';
import { document, metadata, workbookElements, wrap } from './lib/code_rep.mjs';

const a = parseArgs(process.argv.slice(2));
if (!a.type || !a.spec || !a.folder) { console.error('need --type datamodel|workbook --spec <spec.json> --folder <folderId>'); process.exit(2); }
const idField = a.type === 'datamodel' ? 'dataModelId' : 'workbookId';
const postPath = a.type === 'datamodel' ? '/v2/dataModels/spec' : '/v2/workbooks/spec';
const colsPath = (id) => a.type === 'datamodel' ? `/v2/dataModels/${id}/columns` : `/v2/workbooks/${id}/columns`;
const SCRIPTS = dirname(fileURLToPath(import.meta.url));
const WORKDIR = dirname(a.spec);
const scopePath = a['control-scope'] || join(WORKDIR, 'control-scope.json');

const spec = JSON.parse(readFileSync(a.spec, 'utf8'));
const name = a.name || spec.name || `metabase ${a.type} ${Date.now()}`;
// Workbook writes require the released code-representation envelope. Data-model
// writes deliberately remain flat; that API does not accept `document`.
const body = a.type === 'workbook'
  ? wrap(document(spec), { ...metadata(spec), folderId: a.folder, name })
  : { folderId: a.folder, ...spec, name };
let post = await api('POST', postPath, body);
// Control→DM-parameter bindings (remap --dm-spec) can be rejected by orgs where
// data-model parameter targeting isn't enabled. Default: DROP the affected
// controls entirely (a control that provably drives nothing is furniture — the
// control lint would rightly fail it) and patch the control-scope sidecar.
// --keep-rejected-bindings keeps them with only the binding stripped (legacy;
// gate 7 WILL flag them dead until you sync each control in the UI:
// control → Settings → "Sync with data source parameter").
if (!post.ok && /Invalid parameter on control/.test(post.text)) {
  const bound = (c) => c?.kind === 'control' && c.parameters;
  const dropped = [];
  if (a['keep-rejected-bindings']) {
    let stripped = 0;
    const strip = (c) => { if (bound(c)) { delete c.parameters; stripped++; } };
    for (const element of workbookElements(body)) strip(element);
    if (stripped) {
      console.error(`WARN: org rejected control→data-model parameter bindings — stripped ${stripped} and retrying (--keep-rejected-bindings). These controls POST but DRIVE NOTHING until you sync each to its DM control in the UI; the control lint (gate 7) will flag them dead until then.`);
      post = await api('POST', postPath, body);
    }
  } else {
    for (const element of workbookElements(body)) if (bound(element)) dropped.push(element.controlId);
    const droppedElementIds = new Set(
      (body.document.elements || []).filter((element) => bound(element)).map((element) => element.id),
    );
    body.document.elements = (body.document.elements || []).filter((element) => !bound(element));
    if (droppedElementIds.size && typeof body.document.layout === 'string') {
      body.document.layout = body.document.layout.replace(
        /<Element\b[^>]*\belementId="([^"]*)"[^>]*\/>/g,
        (node, elementId) => droppedElementIds.has(elementId) ? '' : node,
      );
    }
    if (dropped.length) {
      console.error(`WARN: org rejected control→data-model parameter bindings — DROPPED ${dropped.length} control(s) [${dropped.join(', ')}] and retrying. The filters still live on the DM's {{tag}} controls; re-add a workbook control synced to the DM parameter in the UI when the org enables data-model parameter targeting (or re-run with --keep-rejected-bindings to keep decorative controls and sync them by hand).`);
      // patch the control-scope sidecar so gate 7 doesn't expect the dropped controls
      if (existsSync(scopePath)) {
        try {
          const scope = JSON.parse(readFileSync(scopePath, 'utf8'));
          scope.controls = (scope.controls || []).filter((c) => !dropped.includes(c.controlId));
          const specControls = workbookElements(body).filter((e) => e.kind === 'control').length;
          if (!specControls) {
            scope.note = `sourceFilterSignals zeroed by post-and-readback: the org rejected control→DM-parameter bindings for [${dropped.join(', ')}] — the signals are non-portable here; the DM {{tag}} controls carry the filters.`;
            scope.sourceFilterSignals = 0;
          }
          writeFileSync(scopePath, JSON.stringify(scope, null, 2));
          console.error(`patched ${scopePath} (removed ${dropped.length} sidecar entr${dropped.length === 1 ? 'y' : 'ies'})`);
        } catch { console.error(`WARN: could not patch ${scopePath} — fix it by hand before gate 7.`); }
      }
      post = await api('POST', postPath, body);
    }
  }
}
const id = extractId(post, idField);
if (!id) { console.error(`POST failed (HTTP ${post.status}): ${post.text.slice(0, 500)}`); process.exit(1); }
console.error(`POST ok → ${idField}=${id}`);

// Gate-2 sentinel (assert-phase6-ran.rb orphan check): every POSTed workbook is
// recorded; >1 unique id without a cleanup marker blocks GREEN.
if (a.type === 'workbook') {
  appendFileSync(join(WORKDIR, 'posted-workbooks.jsonl'), JSON.stringify({ id, name: body.name, at: new Date().toISOString() }) + '\n');
  writeFileSync(join(WORKDIR, 'wb-ids.json'), JSON.stringify({ workbookId: id }, null, 2));
}

// Silent-error guard: scan resolved column types; type "error" = formula didn't resolve.
const cols = await api('GET', colsPath(id));
const errors = [];
const list = cols.json?.entries || cols.json?.columns || (Array.isArray(cols.json) ? cols.json : []);
for (const c of (Array.isArray(list) ? list : [])) {
  const t = c.type?.type || c.columnType || c.type;
  if (String(t).toLowerCase() === 'error') errors.push(c.name || c.columnName || c.columnId);
}
const elements = elementsOf((await api('GET', a.type === 'datamodel' ? `/v2/dataModels/${id}/elements` : `/v2/workbooks/${id}/elements`)).json);
const result = { [idField]: id, elements, errors };
if (a.out) writeFileSync(a.out, JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 2));
if (errors.length) { console.error(`FAIL: ${errors.length} error-typed column(s): ${errors.join(', ')}`); process.exit(1); }
console.error(`readback clean: ${elements.length} element(s), 0 error columns`);

// ── shared lint pass (workbooks): layout_lint + control_lint on the READBACK spec
if (a.type === 'workbook') {
  const rb = await api('GET', `/v2/workbooks/${id}/spec`);
  const rbPath = join(WORKDIR, 'workbook-readback.spec.json');
  writeFileSync(rbPath, rb.json ? JSON.stringify(rb.json, null, 2) : rb.text);
  const run = (script, args) => spawnSync('ruby', [join(SCRIPTS, 'lib', script), ...args], { stdio: 'inherit' });
  // layout lint: pre-apply-layout this only catches raw-id display names; the
  // full check re-runs in apply-layout.mjs and as gate 6.
  const lay = run('layout_lint.rb', [rbPath]);
  if (lay.status !== 0) { console.error('FAIL: layout lint violations on the readback spec (see above).'); process.exit(5); }
  const ctl = run('control_lint.rb', existsSync(scopePath) ? [rbPath, scopePath] : [rbPath]);
  if (ctl.status !== 0) {
    console.error('FAIL: control lint violations on the readback spec (see above). Fix the wiring');
    console.error('      (refs/control-parity.md repair recipes) or annotate intent in control-scope.json, then re-run.');
    process.exit(4);
  }
}
