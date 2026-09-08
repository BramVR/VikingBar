import assert from 'node:assert/strict';
import test from 'node:test';
import { createStarField } from '../src/star-field.js';

test('pause freezes moving stars and preserves a released drag position', () => {
  const field = createStarField();
  const stars = field.children.filter(child => child.userData.isStar);
  for (let frame = 0; frame < 60; frame++) field.userData.animate(frame / 60, true, 1 / 60, null);
  stars[0].position.x += 2;
  const paused = stars.map(star => star.position.toArray());
  field.userData.animate(1, false, 1 / 60, null);
  field.userData.animate(2, false, 1 / 60, null);
  assert.deepEqual(stars.map(star => star.position.toArray()), paused);
  field.userData.animate(2, true, 1 / 60, null);
  assert.notDeepEqual(stars.map(star => star.position.toArray()), paused);
});
