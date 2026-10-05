// Fetch-based Sigma REST helper with the same refresh contract as the Ruby and
// Python adapters: preserve a valid caller token, refresh known-stale tokens,
// and refresh/retry exactly once after any 401 (including browser-only auth).
import { loadSigmaAuth, refreshSigmaAuth } from './auth.mjs';

function validateBase(base) {
  const url = new URL(base);
  const host = url.hostname.toLowerCase();
  const insecure = process.env.SIGMA_ALLOW_INSECURE_BASE_URL === '1';
  if (!insecure && (url.protocol !== 'https:' ||
      !(host === 'sigmacomputing.com' || host.endsWith('.sigmacomputing.com')))) {
    throw new Error(`refusing to send a Sigma bearer token to untrusted base URL: ${base}`);
  }
  if (insecure && !['https:', 'http:'].includes(url.protocol)) {
    throw new Error(`refusing non-HTTP Sigma base URL: ${base}`);
  }
}

export function makeClient(workdir, options = {}) {
  const loadAuth = options.loadAuth || loadSigmaAuth;
  const refreshAuth = options.refreshAuth || refreshSigmaAuth;
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  let auth = loadAuth(workdir);
  validateBase(auth.base);

  async function api(method, path, body) {
    let res;
    for (let attempt = 0; attempt < 2; attempt++) {
      res = await fetchImpl(auth.base + path, {
        method,
        headers: {
          Authorization: `Bearer ${auth.token}`,
          'Content-Type': 'application/json',
          Accept: 'application/json',
        },
        body: body == null ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
      });
      if (res.status !== 401 || attempt === 1) break;
      auth = refreshAuth(workdir);
      validateBase(auth.base);
    }
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch { /* Sigma /spec POST can return YAML or empty */ }
    return { status: res.status, ok: res.ok, text, json };
  }

  return { base: auth.base, api };
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
