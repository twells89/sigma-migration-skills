#!/usr/bin/env node
import { strict as assert } from 'node:assert';
import { parityActuals } from './lib/parity-export.mjs';

const csv = 'Region,Net Loss\r\n"North, East",$1.25\r\nWest,$2.75\r\n';
const json = '[{"Region":"North, East","Net Loss":1.25},{"Region":"West","Net Loss":2.75}]';
const expected = { 'Crosstab/rows': 2, 'Crosstab/Net Loss': 4 };
assert.deepEqual(parityActuals(csv, 'csv', 'Crosstab').actuals, expected);
assert.deepEqual(parityActuals(json, 'json', 'Crosstab').actuals, expected);
assert.deepEqual(parityActuals('{"rows":[{"Net Loss":2}]}', 'json', 'P').actuals, { 'P/rows': 1, 'P/Net Loss': 2 });
assert.deepEqual(parityActuals('{"Net Loss":1.5}\n{"Net Loss":2.5}', 'json', 'P').actuals, { 'P/rows': 2, 'P/Net Loss': 4 });
assert.throws(() => parityActuals('<html>500</html>', 'json', 'P'), /JSON export/);
console.log('test-parity-export: PASS');
