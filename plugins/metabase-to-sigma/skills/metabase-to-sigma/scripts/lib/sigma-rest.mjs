// Minimal Sigma REST helper for the metabase-to-sigma verify scripts.
// Reads SIGMA_BASE_URL + SIGMA_API_TOKEN from env — run `eval "$(scripts/get-token.sh)"` first.
// Tolerates YAML responses (Sigma's /spec POST returns YAML) when pulling an id.

export function sigmaEnv() {
  const base = process.env.SIGMA_BASE_URL, token = process.env.SIGMA_API_TOKEN;
  if (!base || !token) {
    console.error('Missing SIGMA_BASE_URL / SIGMA_API_TOKEN. Run: eval "$(scripts/get-token.sh)"');
    process.exit(2);
  }
  return { base: base.replace(/\/$/, ''), token };
}

export async function api(method, path, body) {
  const { base, token } = sigmaEnv();
  const res = await fetch(base + path, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: body == null ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
  });
  const text = await res.text();
  let json = null; try { json = JSON.parse(text); } catch { /* YAML or empty */ }
  return { status: res.status, ok: res.ok, text, json };
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
