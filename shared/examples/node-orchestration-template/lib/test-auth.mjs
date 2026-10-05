import test from 'node:test';
import assert from 'node:assert/strict';
import { loadSigmaAuth } from './auth.mjs';
import { makeClient } from './sigma-rest.mjs';

const BASE = 'https://api.sigmacomputing.com';
const KEYS = [
  'SIGMA_BASE_URL', 'SIGMA_API_TOKEN', 'SIGMA_TOKEN_MINTED_AT',
  'SIGMA_AUTH_METHOD', 'SIGMA_CLIENT_ID', 'SIGMA_CLIENT_SECRET',
];

function withCleanEnv(fn) {
  const saved = Object.fromEntries(KEYS.map((key) => [key, process.env[key]]));
  for (const key of KEYS) delete process.env[key];
  try {
    return fn();
  } finally {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

test('unknown-age caller token is preserved without invoking the provider', () => {
  withCleanEnv(() => {
    process.env.SIGMA_BASE_URL = BASE;
    process.env.SIGMA_API_TOKEN = 'caller-token';
    const auth = loadSigmaAuth('/unused', {
      refresh: () => assert.fail('provider should not run for an age-unknown caller token'),
    });
    assert.equal(auth.token, 'caller-token');
  });
});

test('known-stale browser token refreshes without client credentials', () => {
  withCleanEnv(() => {
    process.env.SIGMA_BASE_URL = BASE;
    process.env.SIGMA_API_TOKEN = 'stale-token';
    process.env.SIGMA_TOKEN_MINTED_AT = '2026-10-05T19:00:00Z';
    const auth = loadSigmaAuth('/work', {
      now: Date.parse('2026-10-05T20:00:00Z'),
      refresh: () => ({
        base: BASE,
        token: 'browser-token',
        mintedAt: '2026-10-05T20:00:00Z',
        authMethod: 'browser',
      }),
    });
    assert.equal(auth.token, 'browser-token');
    assert.equal(auth.authMethod, 'browser');
  });
});

test('401 refreshes once regardless of SIGMA_CLIENT_ID', async () => {
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
        authorizations.push(options.headers.Authorization);
        return responses.shift();
      },
    });

    const result = await client.api('GET', '/v2/whoami');
    assert.equal(result.ok, true);
    assert.equal(refreshes, 1);
    assert.deepEqual(authorizations, ['Bearer caller-token', 'Bearer browser-token']);
  });
});
