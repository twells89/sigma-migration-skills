#!/usr/bin/env node
// Shared destination picker for the *-to-sigma migration skills (Node port).
// Produces the folderId where a migrated data model + workbook should land.
// The SKILL drives the *asking*; this script lists candidates and creates folders.
//
//   node pick-destination.mjs list
//       -> { workspaces:[{id,name}], folders:[{id,name,parentId,parentName}], myDocuments }
//   node pick-destination.mjs create --name "<NAME>" [--parent "<workspace-or-folder-id>"]
//       -> { id, name, parentId }
//
// Auth: SIGMA_API_TOKEN + SIGMA_BASE_URL if set; else minted from
// SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET (sourced from ~/.sigma-migration/env).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

function loadNeutralEnv() {
  if (process.env.SIGMA_CLIENT_ID || process.env.SIGMA_API_TOKEN) return;
  const p = path.join(os.homedir(), '.sigma-migration', 'env');
  if (!fs.existsSync(p)) return;
  for (const line of fs.readFileSync(p, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#') || !t.includes('=')) continue;
    const idx = t.indexOf('=');
    const k = t.slice(0, idx).trim();
    const v = t.slice(idx + 1).trim().replace(/^["']|["']$/g, '');
    if (process.env[k] === undefined) process.env[k] = v;
  }
}

const BASE = () => (process.env.SIGMA_BASE_URL || 'https://aws-api.sigmacomputing.com').replace(/\/$/, '');
let TOK = null;
async function token() {
  if (process.env.SIGMA_API_TOKEN) return process.env.SIGMA_API_TOKEN;
  loadNeutralEnv();
  const body = new URLSearchParams({ grant_type: 'client_credentials',
    client_id: process.env.SIGMA_CLIENT_ID, client_secret: process.env.SIGMA_CLIENT_SECRET });
  const r = await fetch(BASE() + '/v2/auth/token', { method: 'POST', body });
  return (await r.json()).access_token;
}
async function call(method, p, body) {
  if (!TOK) TOK = await token();
  const r = await fetch(BASE() + p, { method,
    headers: { Authorization: 'Bearer ' + TOK, 'Content-Type': 'application/json' },
    body: body !== undefined ? JSON.stringify(body) : undefined });
  const raw = await r.text();
  if (!r.ok) { console.error(`${method} ${p} -> ${r.status} ${raw.slice(0, 300)}`); process.exit(1); }
  return raw ? JSON.parse(raw) : {};
}
async function myDocumentsId() {
  try {
    const uid = (await call('GET', '/v2/whoami'))?.userId;
    if (!uid) return null;
    const entries = (await call('GET', `/v2/members/${uid}/files?typeFilters=folder&limit=500`))?.entries || [];
    const hit = entries.find(e => e.name === 'My Documents' || e.path === 'My Documents');
    return hit ? hit.id : null;
  } catch { return null; }
}
async function cmdList() {
  const ws = ((await call('GET', '/v2/workspaces?limit=500')).entries || [])
    .map(w => ({ id: w.workspaceId || w.id, name: w.name }));
  const wsName = Object.fromEntries(ws.map(w => [w.id, w.name]));
  const folders = ((await call('GET', '/v2/files?typeFilters=folder&limit=500')).entries || [])
    .filter(f => f.permission === 'edit')
    .map(f => ({ id: f.id, name: f.name, parentId: f.parentId, parentName: wsName[f.parentId] || null }));
  console.log(JSON.stringify({ workspaces: ws, folders, myDocuments: await myDocumentsId() }, null, 2));
}
async function cmdCreate(argv) {
  let name = null, parent = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--name') { name = argv[++i]; }
    else if (argv[i] === '--parent') { parent = argv[++i]; }
  }
  if (!name) { console.error('pick-destination create: --name is required'); process.exit(1); }
  if (!parent) parent = await myDocumentsId();
  const body = { type: 'folder', name };
  if (parent) body.parentId = parent;
  const res = await call('POST', '/v2/files', body);
  console.log(JSON.stringify({ id: res.id, name: res.name, parentId: res.parentId }, null, 2));
}
const cmd = process.argv[2] || 'list';
if (cmd === 'list') await cmdList();
else if (cmd === 'create') await cmdCreate(process.argv.slice(3));
else { console.error('usage: pick-destination.mjs [list | create --name NAME [--parent ID]]'); process.exit(1); }
