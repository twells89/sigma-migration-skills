import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadSigmaAuth } from './auth.mjs';
import { makeClient } from './sigma-rest.mjs';

const BASE = 'https://api.sigmacomputing.com';
const KEYS = [
  'SIGMA_BASE_URL', 'SIGMA_API_TOKEN', 'SIGMA_TOKEN_MINTED_AT',
  'SIGMA_AUTH_METHOD', 'SIGMA_AUTH_MODE', 'SIGMA_CLIENT_ID',
  'SIGMA_CLIENT_SECRET', 'SIGMA_TOKEN_PROVIDER', 'SIGMA_PYTHON',
  'SIGMA_WORKDIR', 'TEST_PROVIDER_METHOD', 'TEST_EXPECT_CLIENT',
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

async function withFakeProvider(authMethod, fn) {
  const root = mkdtempSync(join(tmpdir(), 'metabase-sigma-auth-'));
  const workdir = join(root, 'work');
  const provider = join(root, 'provider.mjs');
  writeFileSync(provider, `
    import { mkdirSync, writeFileSync } from 'node:fs';
    import { join } from 'node:path';
    const flag = process.argv.indexOf('--workdir');
    const workdir = flag >= 0 ? process.argv[flag + 1] : '';
    if (!workdir) process.exit(8);
    if (process.env.TEST_EXPECT_CLIENT === '1' &&
        (process.env.SIGMA_AUTH_MODE !== 'client-credentials' ||
         !process.env.SIGMA_CLIENT_ID || !process.env.SIGMA_CLIENT_SECRET)) process.exit(9);
    mkdirSync(workdir, { recursive: true });
    writeFileSync(join(workdir, 'auth.json'), JSON.stringify({
      SIGMA_BASE_URL: ${JSON.stringify(BASE)},
      SIGMA_API_TOKEN: process.env.TEST_PROVIDER_METHOD + '-token',
      SIGMA_TOKEN_MINTED_AT: '2026-10-05T20:00:00Z',
      SIGMA_AUTH_METHOD: process.env.TEST_PROVIDER_METHOD,
    }));
  `);
  process.env.SIGMA_TOKEN_PROVIDER = provider;
  process.env.SIGMA_PYTHON = process.execPath;
  process.env.TEST_PROVIDER_METHOD = authMethod;
  try {
    return await fn(workdir);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test('unknown-age caller token is reused without invoking the provider', async () => {
  await withCleanEnv(async () => {
    const workdir = mkdtempSync(join(tmpdir(), 'metabase-sigma-caller-'));
    try {
      writeFileSync(join(workdir, 'auth.json'), JSON.stringify({
        SIGMA_BASE_URL: BASE,
        SIGMA_API_TOKEN: 'old-file-token',
        SIGMA_TOKEN_MINTED_AT: '2020-01-01T00:00:00Z',
        SIGMA_AUTH_METHOD: 'client-credentials',
      }));
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

test('known-stale token refreshes through the browser provider without client credentials', async () => {
  await withCleanEnv(async () => {
    await withFakeProvider('browser', async (workdir) => {
      process.env.SIGMA_BASE_URL = BASE;
      process.env.SIGMA_API_TOKEN = 'stale-token';
      process.env.SIGMA_TOKEN_MINTED_AT = '2026-10-05T19:00:00Z';
      const auth = loadSigmaAuth(workdir, {
        now: Date.parse('2026-10-05T20:00:00Z'),
      });
      assert.equal(auth.token, 'browser-token');
      assert.equal(auth.authMethod, 'browser');
      assert.equal(process.env.SIGMA_CLIENT_ID, undefined);
    });
  });
});

test('missing token refreshes through the client-credentials provider route', async () => {
  await withCleanEnv(async () => {
    await withFakeProvider('client-credentials', async (workdir) => {
      process.env.SIGMA_BASE_URL = BASE;
      process.env.SIGMA_AUTH_MODE = 'client-credentials';
      process.env.SIGMA_CLIENT_ID = 'client-id';
      process.env.SIGMA_CLIENT_SECRET = 'client-secret';
      process.env.TEST_EXPECT_CLIENT = '1';
      const auth = loadSigmaAuth(workdir);
      assert.equal(auth.token, 'client-credentials-token');
      assert.equal(auth.authMethod, 'client-credentials');
    });
  });
});

test('401 refreshes and retries exactly once', async () => {
  await withCleanEnv(async () => {
    const authorizations = [];
    let refreshes = 0;
    const client = makeClient('/work', {
      loadAuth: () => ({ base: BASE, token: 'caller-token' }),
      refreshAuth: () => {
        refreshes += 1;
        return { base: BASE, token: 'browser-token', authMethod: 'browser' };
      },
      fetchImpl: async (_url, options) => {
        authorizations.push(options.headers.Authorization);
        return { status: 401, ok: false, text: async () => 'unauthorized' };
      },
    });

    const result = await client.api('GET', '/v2/whoami');
    assert.equal(result.status, 401);
    assert.equal(refreshes, 1);
    assert.deepEqual(authorizations, ['Bearer caller-token', 'Bearer browser-token']);
  });
});
