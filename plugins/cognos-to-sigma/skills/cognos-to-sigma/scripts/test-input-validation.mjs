#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const work = mkdtempSync(join(tmpdir(), 'cognos-input-'));
const cli = fileURLToPath(new URL('../converter/cli.mjs', import.meta.url));
const input = join(work, 'report.xml'), output = join(work, 'output.json');
try {
  for (const [label, content, expected] of [
    ['invalid UTF-8', Buffer.concat([Buffer.from('<report><reportName>'), Buffer.from([0xbf]), Buffer.from('</reportName></report>')]), /UTF-8/],
    ['unclosed XML', Buffer.from('<report><layouts>'), /invalid Cognos report XML/i],
    ['mismatched XML', Buffer.from('<report><layouts></report>'), /invalid Cognos report XML/i],
    ['unsupported declaration', Buffer.from('<?xml version="1.0" encoding="windows-1252"?><report/>'), /encoding/i],
  ]) {
    writeFileSync(input, content); writeFileSync(output, 'prior output');
    const result = spawnSync(process.execPath, [cli, input, '--print', '--out', output], { encoding: 'utf8' });
    assert.notEqual(result.status, 0, label);
    assert.match(result.stderr, expected, label);
    assert.equal(result.stdout, '', label);
    assert.equal(readFileSync(output, 'utf8'), 'prior output', label);
  }
  writeFileSync(input, '\uFEFF<?xml version="1.0" encoding="UTF-8"?><report><reportName>Caf\u00e9</reportName></report>');
  const result = spawnSync(process.execPath, [cli, input], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).name, 'Caf\u00e9');
  console.log('test-input-validation: PASS');
} finally { rmSync(work, { recursive: true, force: true }); }
