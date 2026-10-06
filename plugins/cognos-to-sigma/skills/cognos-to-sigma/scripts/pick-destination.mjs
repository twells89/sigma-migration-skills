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
// Auth is browser-first via the co-located provider. A valid caller token is
// preserved, client credentials remain the provider's fallback, and a 401 is
// refreshed/retried once.
import { api } from './lib/sigma-rest.mjs';

async function call(method, p, body) {
  const r = await api(method, p, body);
  if (!r.ok) { console.error(`${method} ${p} -> ${r.status} ${r.text.slice(0, 300)}`); process.exit(1); }
  return r.json || {};
}
async function myDocumentsId() {
  try {
    const uid = (await call('GET', '/v2/whoami'))?.userId;
    if (!uid) return null;
    const home = (await call('GET', `/v2/members/${uid}`))?.homeFolderId;
    if (home) return home;
    // Legacy fallback: use the folder's id, never its parentId.
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
