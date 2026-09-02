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

console.log('pick-destination My Documents resolver: PASS');
