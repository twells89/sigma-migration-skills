import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadSigmaAuth, refreshSigmaAuth } from './auth.mjs';
import { makeClient } from './sigma-rest.mjs';

const BASE = 'https://api.sigmacomputing.com';
const PROVIDER = fileURLToPath(new URL('../get_token.py', import.meta.url));
const KEYS = [
  'SIGMA_BASE_URL', 'SIGMA_API_TOKEN', 'SIGMA_TOKEN_MINTED_AT',
  'SIGMA_AUTH_METHOD', 'SIGMA_CLIENT_ID', 'SIGMA_CLIENT_SECRET',
  'SIGMA_AUTH_MODE', 'SIGMA_TOKEN_PROVIDER', 'SIGMA_PYTHON',
  'SIGMA_WORKDIR', 'SIGMA_ALLOW_INSECURE_BASE_URL',
];

async function withCleanEnv(fn) {
  const saved = Object.fromEntries(KEYS.map((key) => [key, process.env[key]]));
  for (const key of KEYS) delete process.env[key];
  try {
    return await fn();
  } finally {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

function providerHarness(dir, route) {
  const path = join(dir, `provider-${route}.py`);
  writeFileSync(path, `\
import importlib.util

spec = importlib.util.spec_from_file_location("sigma_get_token", ${JSON.stringify(PROVIDER)})
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)
provider._load_neutral_env = lambda *args, **kwargs: None
provider._verify_token = lambda result: result

if ${JSON.stringify(route)} == "browser":
    def browser(base, now=None):
        return provider.TokenResult(base, "browser-token", "2026-10-05T20:00:00Z", "browser")
    def no_client(*args, **kwargs):
        raise AssertionError("client credentials must not run when browser auth succeeds")
    provider._mint_browser_refresh = browser
    provider._mint_client_credentials = no_client
else:
    def unavailable(base, now=None):
        raise provider.BrowserUnavailable("no browser session")
    def client(base, client_id, client_secret, now=None):
        assert client_id == "client-id"
        assert client_secret == "client-secret"
        return provider.TokenResult(base, "client-token", "2026-10-05T20:00:00Z", "client-credentials")
    provider._mint_browser_refresh = unavailable
    provider._mint_client_credentials = client

raise SystemExit(provider.main())
`);
  return path;
}

test('unknown-age caller token is reused without invoking the provider', async () => {
  await withCleanEnv(async () => {
    const workdir = mkdtempSync(join(tmpdir(), 'cognos-auth-caller-'));
    try {
      process.env.SIGMA_BASE_URL = BASE;
      process.env.SIGMA_API_TOKEN = 'caller-token';
      const auth = loadSigmaAuth(workdir, {
        refresh: () => assert.fail('provider should not run for an age-unknown caller token'),
      });
      assert.equal(auth.token, 'caller-token');
    } finally {
      rmSync(workdir, { recursive: true, force: true });
    }
  });
});

test('known-stale token refreshes before a request', async () => {
  await withCleanEnv(async () => {
    process.env.SIGMA_BASE_URL = BASE;
    process.env.SIGMA_API_TOKEN = 'stale-token';
    process.env.SIGMA_TOKEN_MINTED_AT = '2026-10-05T19:00:00Z';
    let refreshes = 0;
    const auth = loadSigmaAuth('/unused', {
      now: Date.parse('2026-10-05T20:00:00Z'),
      refresh: () => {
        refreshes += 1;
        return {
          base: BASE,
          token: 'fresh-token',
          mintedAt: '2026-10-05T20:00:00Z',
          authMethod: 'browser',
        };
      },
    });
    assert.equal(auth.token, 'fresh-token');
    assert.equal(refreshes, 1);
  });
});

test('browser-first provider route works without client credentials', async () => {
  await withCleanEnv(async () => {
    const workdir = mkdtempSync(join(tmpdir(), 'cognos-auth-browser-'));
    try {
      process.env.SIGMA_BASE_URL = BASE;
      process.env.SIGMA_TOKEN_PROVIDER = providerHarness(workdir, 'browser');
      const auth = refreshSigmaAuth(workdir);
      assert.equal(auth.token, 'browser-token');
      assert.equal(auth.authMethod, 'browser');
    } finally {
      rmSync(workdir, { recursive: true, force: true });
    }
  });
});

test('provider falls back from browser auth to client credentials', async () => {
  await withCleanEnv(async () => {
    const workdir = mkdtempSync(join(tmpdir(), 'cognos-auth-client-'));
    try {
      process.env.SIGMA_BASE_URL = BASE;
      process.env.SIGMA_CLIENT_ID = 'client-id';
      process.env.SIGMA_CLIENT_SECRET = 'client-secret';
      process.env.SIGMA_TOKEN_PROVIDER = providerHarness(workdir, 'client');
      const auth = refreshSigmaAuth(workdir);
      assert.equal(auth.token, 'client-token');
      assert.equal(auth.authMethod, 'client-credentials');
    } finally {
      rmSync(workdir, { recursive: true, force: true });
    }
  });
});

test('a 401 refreshes and retries exactly once', async () => {
  await withCleanEnv(async () => {
    const authorizations = [];
    const responses = [
      { status: 401, ok: false, text: async () => 'unauthorized' },
      { status: 200, ok: true, text: async () => '{"ok":true}' },
    ];
    let refreshes = 0;
    const client = makeClient('/work', {
      loadAuth: () => ({ base: BASE, token: 'caller-token' }),
      refreshAuth: () => {
        refreshes += 1;
        return { base: BASE, token: 'browser-token', authMethod: 'browser' };
      },
      fetchImpl: async (_url, options) => {
        authorizations.push(options.headers.get('Authorization'));
        return responses.shift();
      },
    });

    const result = await client.api('GET', '/v2/whoami');
    assert.equal(result.ok, true);
    assert.equal(refreshes, 1);
    assert.deepEqual(authorizations, ['Bearer caller-token', 'Bearer browser-token']);
  });
});
