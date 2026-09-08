import * as THREE from 'three';


// Near stars preserve the selected composition and spiral. x/y are coordinates
// in the 1513 × 1040 concept; distant crosses add the requested space setting.
const layout = [
  [1105,123,-1.8,1,.9], [1200,96,-3,0,.72], [1335,143,-2.7,0,.85],
  [1380,193,-1.2,1,1.05], [1490,165,-3,0,.72], [1480,229,-.6,0,.7],
  [1492,260,-1,2,.65], [1464,283,.2,2,.78], [1380,293,-2.5,0,1.05],
  [1436,475,-1.6,1,.75], [1350,513,.55,0,1.1], [1425,566,.3,2,1.1],
  [1290,596,-.2,1,.55], [1090,682,1.35,1,1.1], [988,700,2.1,2,.8],
  [854,625,1.1,0,1.25], [716,616,1.5,1,1.15], [581,642,2.7,2,.85],
  [777,563,.1,0,.65], [733,556,-.3,2,.82], [655,522,.35,1,.86],
  [711,468,-.7,0,.8], [682,495,-1.4,2,.55], [656,449,-.8,0,.48],
  [699,380,0,1,.96], [733,326,-.4,2,.65], [785,278,-.7,0,.85],
  [683,324,-3.1,0,.72], [700,245,-3.5,2,.68], [779,238,-2.8,1,.78],
  [843,153,-3.5,0,.83], [931,176,-1.8,0,.85], [1064,179,-1.4,1,.65],
];

export function createStarField() {
  const group = new THREE.Group();
  // Upright, slender plus signs; no diagonal rotation into an X.
  const outline = new THREE.Shape();
  const points = [[2.74,0],[2.74,2.74],[0,2.74],[0,3.26],[2.74,3.26],[2.74,6],
    [3.26,6],[3.26,3.26],[6,3.26],[6,2.74],[3.26,2.74],[3.26,0]];
  points.forEach(([x,y], index) => outline[index ? 'lineTo' : 'moveTo']((x-3)*.025,(y-3)*.025));
  outline.closePath();
  const shape = new THREE.ShapeGeometry(outline);
  const materials = ['#ef4939', '#fff0d8', '#b879ee'].map(color => new THREE.MeshBasicMaterial({
    color, transparent:true, opacity:.9, side:THREE.DoubleSide, toneMapped:false,
  }));
  for (const [index, [x,y,z,color,size]] of layout.entries()) {
    const bar = new THREE.Mesh(shape, materials[color]);
    const depth = (7.3 - z) / 7.3;
    const base = new THREE.Vector3(((x / 1513 - .5) * 8.05 * depth - 1.49) / .9,
      (.5 - (y - 90) / 620) * 3.3 * depth / .9, z / .9);
    bar.position.copy(base);
    bar.rotation.z = 0;
    bar.scale.setScalar(size * .65);
    bar.userData = {isStar:true, velocity:new THREE.Vector3(), base};
    group.add(bar);
  }
  const movingStars = [...group.children];
  const spiral = new THREE.CatmullRomCurve3(group.children.slice(0, 27).map(bar => bar.userData.base), true, 'centripetal');
  const destination = new THREE.Vector3();
  const acceleration = new THREE.Vector3();
  group.userData.animate = (seconds, motion, dt, dragged) => {
    // Pausing preserves spring positions, including a star just released after dragging.
    if (!motion) return;
    for (const [index, bar] of movingStars.entries()) {
      if (bar === dragged) continue;
      const {velocity, base} = bar.userData;
      if (index < 27) spiral.getPoint((index / 27 + seconds * .007) % 1, destination);
      else destination.copy(base).add(new THREE.Vector3(Math.sin(seconds * .1 + index) * .05, Math.cos(seconds * .12 + index) * .06, 0));
        acceleration.copy(destination).sub(bar.position).multiplyScalar(24);
        velocity.addScaledVector(acceleration, dt).multiplyScalar(Math.exp(-7 * dt));
        bar.position.addScaledVector(velocity, dt);
    }
  };
  const distantMaterial = new THREE.MeshBasicMaterial({
    color:'#ffffff', transparent:true, opacity:.38, side:THREE.DoubleSide, toneMapped:false,
  });
  const distant = new THREE.InstancedMesh(shape, distantMaterial, 420);
  const transform = new THREE.Object3D();
  // Ivory carries the light; red echoes the allowance, violet adds a cool accent.
  const palette = ['#ffe5be', '#f34a37', '#ff9473', '#fff3df', '#ac68df', '#e74232']
    .map(color => new THREE.Color(color));
  for (let i = 0; i < 420; i++) {
    // Deterministic, irregular placement; a field rather than another ring.
    const x = ((i * .61803398875) % 1 - .5) * 18;
    const y = ((i * .41421356237) % 1 - .5) * 9;
    const z = -2.5 - ((i * .73205080757) % 1) * 6;
    transform.position.set(x,y,z);
    transform.rotation.z = 0;
    transform.scale.setScalar(.10 + (i % 7) * .026);
    transform.updateMatrix(); distant.setMatrixAt(i, transform.matrix);
    distant.setColorAt(i, palette[i % palette.length]);
  }
  distant.instanceMatrix.needsUpdate = true;
  distant.instanceColor.needsUpdate = true;
  group.add(distant);

  // A loose stream of tiny plus signs gives the larger stars a shared orbit.
  const dustMaterial = new THREE.MeshBasicMaterial({
    color:'#ffffff', transparent:true, opacity:.5, side:THREE.DoubleSide, toneMapped:false,
  });
  const dust = new THREE.InstancedMesh(shape, dustMaterial, 320);
  for (let i = 0; i < 320; i++) {
    spiral.getPoint(i / 320, destination);
    transform.position.copy(destination);
    transform.position.x += Math.sin(i * 137.5) * .22;
    transform.position.y += Math.cos(i * 73.3) * .18;
    transform.position.z += Math.sin(i * 39.7) * .35;
    transform.scale.setScalar(.08 + (i % 9) * .022);
    transform.updateMatrix();
    dust.setMatrixAt(i, transform.matrix);
    dust.setColorAt(i, palette[(i * 5) % palette.length]);
  }
  dust.instanceMatrix.needsUpdate = true;
  dust.instanceColor.needsUpdate = true;
  group.add(dust);

  // Soft additive halos surround only the brighter foreground plus signs.
  const pixels = new Uint8Array(32 * 32 * 4);
  for (let y = 0; y < 32; y++) for (let x = 0; x < 32; x++) {
    const radius = Math.hypot((x - 15.5) / 15.5, (y - 15.5) / 15.5);
    const offset = (y * 32 + x) * 4;
    pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = 255;
    pixels[offset + 3] = Math.round(Math.max(0, 1 - radius) ** 3 * 255);
  }
  const haloMap = new THREE.DataTexture(pixels, 32, 32);
  haloMap.needsUpdate = true;
  haloMap.magFilter = THREE.LinearFilter;
  haloMap.minFilter = THREE.LinearFilter;
  const haloMaterials = materials.map(material => new THREE.SpriteMaterial({
    map:haloMap, color:material.color, opacity:.25, blending:THREE.AdditiveBlending,
    depthWrite:false, toneMapped:false,
  }));
  movingStars.forEach((star, index) => {
    if (index % 3 !== 0) return;
    const halo = new THREE.Sprite(haloMaterials[materials.indexOf(star.material)]);
    halo.scale.set(.5, .5, 1);
    halo.raycast = () => {};
    star.add(halo);
  });
  return group;
}
