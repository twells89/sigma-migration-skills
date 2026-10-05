#!/usr/bin/env node
// Regression test for the authoritative workbook layout gate. The gate must
// consume the current wrapped/flat representation and must not synthesize or
// PUT a replacement layout after creation.
//
// Runs IN-PROCESS (stubs `globalThis.fetch` + `process.exit`, then dynamically
// imports apply-layout.mjs) rather than spawning `node apply-layout.mjs` as a
// child process: a spawned child in this sandbox cannot reach a local HTTP
// server started by the parent test process (verified — the child's fetch to
// 127.0.0.1 hangs until ETIMEDOUT), so a real-socket child-process test isn't
// viable here. Stubbing fetch in-process still exercises the real api()/
// Sigma::CodeRep call sites, just without a real socket.
//
//   node scripts/test-apply-layout.mjs

import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = pathToFileURL(join(HERE, 'apply-layout.mjs')).href;
const fails = [];
const check = (cond, msg) => { console.error(`  ${cond ? 'PASS' : 'FAIL'}  ${msg}`); if (!cond) fails.push(msg); };

// The LIVE shape: metadata-only pages + flat elements + required layout.
const NESTED_DOC = {
  workbookId: 'wb-test',
  name: 'Test WB',
  folderId: 'home-1',
  document: {
    schemaVersion: 3,
    pages: [{ id: 'pg1', name: 'Page 1' }],
    elements: [{ id: 'c1', kind: 'bar-chart' }],
    layout: '<?xml version="1.0"?><Page id="pg1"><Element elementId="c1" gridColumn="1 / 25" gridRow="1 / 12"/></Page>',
  },
};

let getCount = 0;
let putCount = 0;

const realFetch = globalThis.fetch;
globalThis.fetch = async (url, init = {}) => {
  const u = String(url);
  const method = (init.method || 'GET').toUpperCase();
  if (!u.endsWith('/v2/workbooks/wb-test/spec')) return new Response('not found', { status: 404 });
  if (method === 'GET') {
    getCount += 1;
    return new Response(JSON.stringify(NESTED_DOC), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }
  if (method === 'PUT') {
    putCount += 1;
    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }
  return new Response('unsupported method', { status: 405 });
};

const authKeys = [
  'SIGMA_BASE_URL', 'SIGMA_API_TOKEN', 'SIGMA_TOKEN_MINTED_AT',
  'SIGMA_AUTH_METHOD', 'SIGMA_ALLOW_INSECURE_BASE_URL',
];
const savedAuthEnv = Object.fromEntries(authKeys.map((key) => [key, process.env[key]]));
process.env.SIGMA_BASE_URL = 'http://stub.invalid';
process.env.SIGMA_API_TOKEN = 'dummy-test-token';
process.env.SIGMA_ALLOW_INSECURE_BASE_URL = '1';
delete process.env.SIGMA_TOKEN_MINTED_AT;
delete process.env.SIGMA_AUTH_METHOD;
process.argv = ['node', 'apply-layout.mjs', '--workbook', 'wb-test', '--skip-layout-lint', '--skip-visual-qa'];

const logs = [];
const realLog = console.log;
console.log = (...args) => { logs.push(args.map(String).join(' ')); };

class ExitSignal extends Error {}
let exitCode = null;
const realExit = process.exit;
process.exit = (code) => { exitCode = code ?? 0; throw new ExitSignal(String(exitCode)); };

let threw = null;
try {
  await import(SCRIPT);
} catch (e) {
  if (!(e instanceof ExitSignal)) threw = e;
}

console.log = realLog;
process.exit = realExit;
globalThis.fetch = realFetch;
for (const [key, value] of Object.entries(savedAuthEnv)) {
  if (value === undefined) delete process.env[key];
  else process.env[key] = value;
}

check(exitCode === null && !threw,
  `apply-layout.mjs runs to completion without exiting/throwing (exit=${exitCode}, threw=${threw ? threw.message : 'no'})`);
check(putCount === 0, `no replacement PUT issued (got ${putCount})`);

const out = logs.join('\n');
let parsed = null;
try { parsed = JSON.parse(out); } catch { /* left null */ }
check(!!parsed && parsed.layoutOnReadback === true,
  `authoritative nested readback passes (got stdout: ${out.slice(0, 200)})`);
check(!!parsed && parsed.elementsLaidOut === 1, 'gate counted the flat document element');
check(getCount === 1, `exactly one authoritative GET issued (got ${getCount})`);

console.log();
if (fails.length) { console.log(`${fails.length} FAILURE(S):`); fails.forEach((f) => console.log(`  - ${f}`)); process.exit(1); }
console.log('ALL PASS');
