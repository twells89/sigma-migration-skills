#!/usr/bin/env node
// Offline behavioral test for the My Documents resolver.
import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(new URL('./pick-destination.mjs', import.meta.url), 'utf8');
const match = source.match(/async function myDocumentsId\(\) \{[\s\S]*?\n\}/);
assert.ok(match, 'myDocumentsId function is present');

function resolverWith(call) {
  return new Function('call', `${match[0]}; return myDocumentsId;`)(call);
}

{
  const calls = [];
  const responses = {
    '/v2/whoami': { userId: 'member-1' },
    '/v2/members/member-1': { homeFolderId: 'home-folder-id' },
  };
  const resolver = resolverWith(async (method, path) => {
    calls.push([method, path]);
    return responses[path];
  });

  assert.equal(await resolver(), 'home-folder-id');
  assert.deepEqual(calls, [
    ['GET', '/v2/whoami'],
    ['GET', '/v2/members/member-1'],
  ]);
}

{
  const responses = {
    '/v2/whoami': { userId: 'member-1' },
    '/v2/members/member-1': {},
    '/v2/members/member-1/files?typeFilters=folder&limit=500': {
      entries: [{
        id: 'my-documents-id',
        parentId: 'wrong-parent-id',
        path: 'My Documents',
      }],
    },
  };
  const resolver = resolverWith(async (_method, path) => responses[path]);

  assert.equal(await resolver(), 'my-documents-id');
}

const orchestratorSource = fs.readFileSync(
  new URL('./migrate-cognos.mjs', import.meta.url), 'utf8');
const orchestratorMatch = orchestratorSource.match(
  /async function resolveFolder\(\) \{[\s\S]*?\n\}/);
assert.ok(orchestratorMatch, 'orchestrator resolveFolder function is present');

function orchestratorResolverWith(api) {
  const die = (message) => { throw new Error(message); };
  const line = () => {};
  return new Function(
    'api', 'die', 'line', `${orchestratorMatch[0]}; return resolveFolder;`
  )(api, die, line);
}

{
  const calls = [];
  const resolver = orchestratorResolverWith(async (method, path) => {
    calls.push([method, path]);
    if (path === '/v2/whoami') return { status: 200, json: { userId: 'member-1' } };
    if (path === '/v2/members/member-1') {
      return { status: 200, json: { homeFolderId: 'home-folder-id' } };
    }
    throw new Error(`unexpected API call: ${path}`);
  });

  assert.equal(await resolver(), 'home-folder-id');
  assert.deepEqual(calls, [
    ['GET', '/v2/whoami'],
    ['GET', '/v2/members/member-1'],
  ]);
}

{
  const resolver = orchestratorResolverWith(async (_method, path) => {
    if (path === '/v2/whoami') return { status: 200, json: { userId: 'member-1' } };
    if (path === '/v2/members/member-1') return { status: 200, json: {} };
    if (path === '/v2/members/member-1/files') {
      return {
        status: 200,
        json: {
          entries: [{
            id: 'my-documents-id',
            parentId: 'wrong-parent-id',
            path: 'My Documents',
          }],
        },
      };
    }
    throw new Error(`unexpected API call: ${path}`);
  });

  assert.equal(await resolver(), 'my-documents-id');
}

console.log('pick-destination My Documents resolver: PASS');
