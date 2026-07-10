// sigma-rest.mjs — fetch-based Sigma REST helper. Zero unix-CLI dependency:
// no curl (uses global fetch), no jq (uses native JSON). Cross-platform as-is.
//
// Improves on cognos-to-sigma/scripts/lib/sigma-rest.mjs by taking creds from the
// shell-neutral auth.mjs loader instead of assuming an already-`eval`-ed env.
import { loadSigmaAuth } from './auth.mjs';

export function makeClient(workdir) {
  const { base, token } = loadSigmaAuth(workdir);

  async function api(method, path, body) {
    const res = await fetch(base + path, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: body == null ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
    });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch { /* Sigma /spec POST can return YAML or empty */ }
    return { status: res.status, ok: res.ok, text, json };
  }

  return { base, api };
}

// Sigma POST /spec returns JSON ({"workbookId":...}) OR YAML (workbookId: ...). Pull either.
export function extractId(r, field) {
  if (r.json && r.json[field]) return r.json[field];
  const m = r.text.match(new RegExp(`${field}:\\s*"?([0-9a-f-]{36})`, 'i'));
  return m ? m[1] : null;
}

// Tiny --flag parser: returns { flag: value | true }.
export function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith('--')) continue;
    const k = argv[i].slice(2);
    const next = argv[i + 1];
    out[k] = (next == null || next.startsWith('--')) ? true : (i++, next);
  }
  return out;
}
