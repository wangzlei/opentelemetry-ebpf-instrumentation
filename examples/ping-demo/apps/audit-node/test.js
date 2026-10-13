'use strict';
// Unit tests for propagate.js + cpuwork.js (node --test test.js). Not shipped in the image.
const test = require('node:test');
const assert = require('node:assert');
const { worstStatus } = require('./propagate');
const cpuwork = require('./cpuwork');

test('worstStatus', () => {
  assert.strictEqual(worstStatus([]), null);
  assert.strictEqual(worstStatus([200, 200]), null);
  assert.strictEqual(worstStatus([null, null]), null);
  assert.strictEqual(worstStatus([304]), null);
  assert.strictEqual(worstStatus([500, 200]), 500);
  assert.strictEqual(worstStatus([null, 503]), 500);
  assert.strictEqual(worstStatus([404, 200]), 500);
  assert.strictEqual(worstStatus([500, 429]), 500);
  assert.strictEqual(worstStatus([429, 404]), 500);
  assert.strictEqual(worstStatus([429, 200]), 429);
  assert.strictEqual(worstStatus([429, 429]), 429);
});

test('resolveShare', () => {
  for (const [i, o] of [['0', 0], ['0.25', 0.25], ['2', 1], ['-1', 0], ['nan', 0], ['inf', 0], ['x', 0], [' 0.5 ', 0.5], ['', 0]]) {
    assert.strictEqual(cpuwork.resolveShare(i), o, i);
  }
});

test('spendCpu runs off the event loop and is CPU-bounded', async () => {
  let ticks = 0;
  const iv = setInterval(() => ticks++, 5);
  const s = await cpuwork.spendCpu(0.1);
  clearInterval(iv);
  assert.ok(s.cpuSeconds >= 0.1 && !s.capped, JSON.stringify(s));
  assert.ok(ticks >= 5, `event loop starved: ${ticks} ticks`);
});
