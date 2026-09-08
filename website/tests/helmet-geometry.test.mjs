import {test} from 'node:test';
import assert from 'node:assert/strict';
import {Vector3} from 'three';
import {createHornGeometry} from '../src/helmet-model.js';

test('both horns face outward around the entire tube, including the back', () => {
  for (const side of [-1, 1]) {
    const geometry = createHornGeometry(side);
    const positions = geometry.attributes.position;
    const normals = geometry.attributes.normal;
    for (const ring of [8, 24, 40]) {
      const center = new Vector3();
      for (let point = 0; point < 32; point++) center.add(new Vector3().fromBufferAttribute(positions, ring * 33 + point));
      center.divideScalar(32);
      for (const point of [0, 8, 16, 24]) {
        const index = ring * 33 + point;
        const radial = new Vector3().fromBufferAttribute(positions, index).sub(center).normalize();
        const normal = new Vector3().fromBufferAttribute(normals, index);
        assert.ok(normal.dot(radial) > .7, `Horn ${side}, ring ${ring}, point ${point} must face outward`);
      }
    }
    geometry.dispose();
  }
});
