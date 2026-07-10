#!/usr/bin/env node
// orchestrate.mjs — minimal, fully bash-free Node orchestration TEMPLATE.
//
// This is the convergence reference for Phase 1 of shared/refs/portability-strategy.md:
// a skill orchestrator that runs identically on macOS, Linux, and native Windows
// PowerShell/cmd — no bash, no eval, no /tmp literal, no curl, no jq, no `unzip`.
//
// Two modes:
//   node orchestrate.mjs --self-test
//       Exercises the cross-platform primitives (workdir, py_resolve, zip round-trip)
//       and prints a PASS/FAIL report. Needs NO Sigma credentials — safe in CI.
//   node orchestrate.mjs --workdir <W>
//       Real run: shell-neutral auth (env or <W>/auth.json) → a live Sigma GET.
//
// Compare with cognos-to-sigma/scripts/migrate-cognos.mjs, which is the same shape but
// still shells to bash for its token (migrate-cognos.mjs:102) — the one thing to fix.
import { spawnSync } from 'node:child_process';
import { writeFileSync, existsSync } from 'node:fs';
import { makeClient, parseArgs } from './lib/sigma-rest.mjs';
import { resolveWorkdir, workPath } from './lib/paths.mjs';
import { pythonArgv } from './lib/py_resolve.mjs';
import { extractZip } from './lib/extract-zip.mjs';

const a = parseArgs(process.argv.slice(2));

// ---- self-test: prove the cross-platform primitives, no creds needed ----
if (a['self-test']) {
  const results = [];
  const check = (name, fn) => {
    try { const detail = fn(); results.push({ name, ok: true, detail }); }
    catch (e) { results.push({ name, ok: false, detail: e.message }); }
  };

  check('workdir resolves cross-platform (no /tmp literal)', () => {
    const w = resolveWorkdir(null, 'sigma-template-selftest');
    if (w.includes('/tmp/')) throw new Error(`workdir hardcoded /tmp: ${w}`);
    return w;
  });

  check('py_resolve finds a real Python (Store-stub-safe)', () => {
    const PY = pythonArgv();
    const v = spawnSync(PY[0], [...PY.slice(1), '--version'], { encoding: 'utf8' });
    if (v.status !== 0) throw new Error('no real python found');
    return `${PY.join(' ')} → ${(v.stdout || v.stderr).trim()}`;
  });

  check('zip round-trip via Python stdlib (no `unzip` binary)', () => {
    const w = resolveWorkdir(null, 'sigma-template-selftest');
    const zip = workPath(w, 'sample.zip');
    const dest = workPath(w, 'unzipped');
    const PY = pythonArgv();
    // build a tiny zip with stdlib, then extract it with our helper
    const mk = spawnSync(PY[0], [...PY.slice(1), '-c',
      'import sys,zipfile;z=zipfile.ZipFile(sys.argv[1],"w");z.writestr("hello.txt","hi");z.close()',
      zip], { encoding: 'utf8' });
    if (mk.status !== 0) throw new Error(`could not build sample zip: ${mk.stderr}`);
    extractZip(zip, dest);
    if (!existsSync(workPath(dest, 'hello.txt'))) throw new Error('extracted file missing');
    return `${zip} → ${dest}/hello.txt`;
  });

  check('fetch is available (no curl dependency)', () => {
    if (typeof fetch !== 'function') throw new Error('global fetch missing — need Node >= 18');
    return `fetch present (Node ${process.version})`;
  });

  const pass = results.every((r) => r.ok);
  for (const r of results) console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}\n        ${r.detail}`);
  console.log(`\n${pass ? 'ALL PASS' : 'FAILURES PRESENT'} — platform=${process.platform}, node=${process.version}`);
  process.exit(pass ? 0 : 1);
}

// ---- real run: shell-neutral auth → a live Sigma call ----
const workdir = resolveWorkdir(a.workdir, 'sigma-migration');
const { base, api } = makeClient(workdir); // reads env → <workdir>/auth.json (never bash/eval)

console.error(`[template] base=${base} workdir=${workdir}`);
const me = await api('GET', '/v2/members?limit=1'); // harmless read to prove auth
if (!me.ok) {
  console.error(`Sigma call failed (HTTP ${me.status}): ${me.text.slice(0, 300)}`);
  process.exit(1);
}
const out = workPath(workdir, 'orchestrate-result.json');
writeFileSync(out, JSON.stringify({ base, status: me.status, sample: me.json }, null, 2));
console.log(`OK — authenticated against ${base}; wrote ${out}`);
