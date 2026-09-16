import assert from 'node:assert/strict';
import test from 'node:test';
import { cycleSummary, formatData, historyDays } from '../src/demo-data.js';

test('cycle totals exclude previous-cycle days and forecasts exclude partial today', () => {
  const days = [{gb: null}, {gb: 90}, {gb: 1}, {gb: 2}, {gb: 3}, {gb: 8}];
  assert.deepEqual(cycleSummary(days, {cycleStart: 2, cycleDays: 30}), {observed: 14, estimate: 60});
});

test('missing current-cycle data withholds estimates while confirmed zero stays zero', () => {
  assert.deepEqual(cycleSummary([{gb: 0}, {gb: 0}, {gb: 0}, {gb: 0}], {cycleStart: 0, cycleDays: 30}), {observed: 0, estimate: 0});
  assert.deepEqual(cycleSummary([{gb: 1}, {gb: null}, {gb: 3}, {gb: 2}], {cycleStart: 0, cycleDays: 30}), {observed: null, estimate: null});
  assert.deepEqual(cycleSummary([{gb: 1}, {gb: 2}, {gb: 3}], {cycleStart: 0, cycleDays: 30}), {observed: 6, estimate: null});
});

test('display units convert amounts without presenting missing data as zero', () => {
  assert.equal(formatData(1.073741824, 'GiB'), '1 GiB');
  assert.equal(formatData(0, 'GB'), '0 GB');
  assert.equal(formatData(null, 'GB'), 'Unavailable');
});

test('SIM history stays independent and contains thirty fixed calendar days', () => {
  const personal = historyDays('personal');
  const work = historyDays('work');
  assert.equal(personal.length, 30);
  assert.equal(personal[0].date, '2026-08-18');
  assert.equal(personal[29].date, '2026-09-16');
  assert.equal(personal[0].gb, 0.42);
  assert.equal(work[0].gb, 0.294);
  assert.equal(personal[1].gb, null);
  assert.equal(work[1].gb, null);
});
