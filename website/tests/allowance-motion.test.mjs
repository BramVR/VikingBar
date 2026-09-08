import {test} from 'node:test';
import assert from 'node:assert/strict';
import {allowanceAt, CYCLE_SECONDS, PHASE_STARTS} from '../src/allowance-motion.js';

test('allowance holds full and empty, then refills without a jump at loop boundary', () => {
  assert.equal(allowanceAt(PHASE_STARTS[0]), 1);
  assert.equal(allowanceAt(1), 1);
  assert.equal(allowanceAt(PHASE_STARTS[1]), 0);
  assert.equal(allowanceAt(9), 0);
  assert.ok(Math.abs(allowanceAt(10.1) - .5) < 1e-10);
  assert.equal(allowanceAt(CYCLE_SECONDS - .001), 1);
  assert.equal(allowanceAt(CYCLE_SECONDS), 1);
});
test('fill remains bounded and drains monotonically before the refill', () => {
  for (let i = 0; i < 2400; i++) {
    const value = allowanceAt(i / 100);
    assert.ok(value >= 0 && value <= 1);
    if (i >= 120 && i < 800) assert.ok(value <= allowanceAt((i - 1) / 100));
  }
});
