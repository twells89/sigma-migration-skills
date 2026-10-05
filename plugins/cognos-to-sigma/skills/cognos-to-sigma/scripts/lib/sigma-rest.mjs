// Sigma REST helper for the Cognos Node stack. A valid caller token is reused;
// missing or known-stale auth refreshes through the browser-first provider, and
// every request refreshes/retries exactly once after a 401.
import { loadSigmaAuth, refreshSigmaAuth, resolveAuthWorkdir } from './auth.mjs';

function validateBase(base) {
  let url;
  try { url = new URL(base); } catch { throw new Error(`invalid SIGMA_BASE_URL: ${base}`); }
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
  const resolvedWorkdir = resolveAuthWorkdir(workdir);
  const loadAuth = options.loadAuth || loadSigmaAuth;
  const refreshAuth = options.refreshAuth || refreshSigmaAuth;
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  let auth = loadAuth(resolvedWorkdir);
  validateBase(auth.base);

  async function request(path, init = {}) {
    let res;
    for (let attempt = 0; attempt < 2; attempt++) {
      const headers = new Headers(init.headers || {});
      headers.set('Authorization', `Bearer ${auth.token}`);
      if (!headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
      if (!headers.has('Accept')) headers.set('Accept', 'application/json');
      res = await fetchImpl(auth.base + path, { ...init, headers });
      if (res.status !== 401 || attempt === 1) break;
      auth = refreshAuth(resolvedWorkdir);
      validateBase(auth.base);
    }
    return res;
  }

  async function api(method, path, body) {
    const res = await request(path, {
      method,
      body: body == null ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
    });
    const text = await res.text();
    let json = null; try { json = JSON.parse(text); } catch { /* YAML or empty */ }
    return { status: res.status, ok: res.ok, text, json };
  }

  return { base: auth.base, api, request };
}

let defaultClient;
function client() {
  if (!defaultClient) defaultClient = makeClient();
  return defaultClient;
}

export function sigmaEnv(workdir) {
  const auth = loadSigmaAuth(resolveAuthWorkdir(workdir));
  validateBase(auth.base);
  return { base: auth.base, token: auth.token };
}

export async function sigmaFetch(path, init) {
  return client().request(path, init);
}

export async function api(method, path, body) {
  return client().api(method, path, body);
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

// DM/workbook element listings come back under a few shapes — normalize to [{id,name,kind}].
export function elementsOf(json) {
  const list = json?.entries || json?.elements || (Array.isArray(json) ? json : []);
  return (Array.isArray(list) ? list : []).map((e) => ({
    id: e.elementId || e.id, name: e.name || e.elementName || '', kind: e.kind || e.type,
  })).filter((e) => e.id);
}
