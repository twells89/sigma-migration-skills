// Fetch-based Sigma REST helper for the metabase-to-sigma live scripts.
// Preserves valid caller tokens, refreshes known-stale tokens through the
// browser-first provider, and refreshes/retries exactly once after any 401.
// Tolerates YAML responses (Sigma's /spec POST returns YAML) when pulling an id.
import {
  loadSigmaAuth,
  refreshSigmaAuth,
  sigmaWorkdir,
} from './auth.mjs';

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

export function sigmaEnv(workdir = sigmaWorkdir()) {
  try {
    const { base, token } = loadSigmaAuth(workdir);
    return { base, token };
  } catch (error) {
    console.error(`Sigma authentication unavailable: ${error.message}`);
    process.exit(2);
  }
}

export function makeClient(workdir = sigmaWorkdir(), options = {}) {
  const loadAuth = options.loadAuth || loadSigmaAuth;
  const refreshAuth = options.refreshAuth || refreshSigmaAuth;
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  let auth = loadAuth(workdir);
  validateBase(auth.base);

  async function request(method, path, body) {
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

  return { base: auth.base, api: request };
}

let defaultClient;
export async function api(method, path, body) {
  if (!defaultClient) {
    const workdir = sigmaWorkdir();
    defaultClient = makeClient(workdir, { loadAuth: () => sigmaEnv(workdir) });
  }
  return defaultClient.api(method, path, body);
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
