import { asset } from './site.js';
import * as THREE from 'three';
import { allowanceAt } from './allowance-motion.js';

export function createHornGeometry(side) {
  const curve = new THREE.CatmullRomCurve3([
    new THREE.Vector3(side * .95, .48, 0),
    new THREE.Vector3(side * 1.15, .68, .015),
    new THREE.Vector3(side * 1.29, 1.04, 0),
    new THREE.Vector3(side * 1.24, 1.48, -.05),
  ]);
  const frames = curve.computeFrenetFrames(48, false);
  const positions = [], indices = [], uvs = [];
  for (let i = 0; i <= 48; i++) {
    const p = curve.getPointAt(i / 48);
    const radius = .29 * Math.pow(1 - i / 48, .62) + .002;
    for (let j = 0; j <= 32; j++) {
      const a = j / 32 * Math.PI * 2;
      const v = p.clone().addScaledVector(frames.normals[i], Math.cos(a) * radius)
        .addScaledVector(frames.binormals[i], Math.sin(a) * radius);
      positions.push(v.x, v.y, v.z); uvs.push(j / 32, i / 48);
      if (i < 48 && j < 32) {
        const k = i * 33 + j;
        // Counter-clockwise from outside; reversing this exposes the interior on rotation.
        indices.push(k, k + 1, k + 33, k + 1, k + 34, k + 33);
      }
    }
  }
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  geometry.setAttribute('uv', new THREE.Float32BufferAttribute(uvs, 2));
  geometry.setIndex(indices); geometry.computeVertexNormals();
  geometry.addGroup(0, 3 * 32 * 6, 1);
  geometry.addGroup(3 * 32 * 6, indices.length - 3 * 32 * 6, 0);
  return geometry;
}

// Bend the entire rounded strip around the bowl, including the moving fill edge.
function curvedStrip(width, height, radius, y, material) {
  const positions = [], indices = [];
  const columns = 64, rows = 12, corner = height / 2;
  for (let row = 0; row <= rows; row++) {
    const v = row / rows * height;
    const inset = corner - Math.sqrt(Math.max(0, corner * corner - (v - corner) ** 2));
    for (let col = 0; col <= columns; col++) {
      positions.push(inset + col / columns * (width - inset * 2), v, 0);
      if (row < rows && col < columns) {
        const k = row * (columns + 1) + col;
        indices.push(k, k + 1, k + columns + 1, k + 1, k + columns + 2, k + columns + 1);
      }
    }
  }
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  geometry.setIndex(indices);
  const source = geometry.attributes.position.array.slice();
  const mesh = new THREE.Mesh(geometry, material);
  const setFill = (fraction = 1) => {
    const attr = geometry.attributes.position;
    for (let i = 0; i < attr.count; i++) {
      const angle = (source[i * 3] * fraction - width / 2) / radius;
      attr.setXYZ(i, Math.sin(angle) * radius, y + source[i * 3 + 1] - height / 2, Math.cos(angle) * radius);
    }
    attr.needsUpdate = true;
    geometry.computeVertexNormals();
    mesh.visible = fraction > .001;
  };
  setFill();
  return { mesh, setFill };
}

export function createHelmet(onTextureReady) {
  const helmet = new THREE.Group();
  const grain = new THREE.TextureLoader().load(asset('ceramic-reference.png'), onTextureReady);
  grain.wrapS = grain.wrapT = THREE.RepeatWrapping;
  grain.repeat.set(2, 1);
  grain.colorSpace = THREE.SRGBColorSpace;
  const ceramic = new THREE.MeshPhysicalMaterial({
    color: '#ffffff', map:grain, roughness: .36, metalness: .03,
    clearcoat: .6, clearcoatRoughness: .17, bumpMap: grain, bumpScale: .12,
  });
  // A hollow lathed shell: outside dome, crown, then the inside back to the open rim.
  const points = [new THREE.Vector2(1.18, -.78), new THREE.Vector2(1.18, -.45), new THREE.Vector2(1.16, -.12)];
  for (let i = 0; i <= 48; i++) {
    const a = i / 48 * Math.PI / 2;
    points.push(new THREE.Vector2(1.16 * Math.cos(a), -.12 + 1.25 * Math.sin(a)));
  }
  for (let i = 48; i >= 0; i--) {
    const a = i / 48 * Math.PI / 2;
    points.push(new THREE.Vector2(1.07 * Math.cos(a), -.12 + 1.16 * Math.sin(a)));
  }
  points.push(new THREE.Vector2(1.09, -.45), new THREE.Vector2(1.09, -.78), new THREE.Vector2(1.18, -.78));
  const shell = new THREE.LatheGeometry(points, 128);
  // Flatten each horn seat against its collar's mounting plane. The collar
  // starts at this plane, so the round dome cannot poke through its metal band.
  const seatNormal = new THREE.Vector3(1, 1, .075).normalize();
  const vertex = new THREE.Vector3();
  for (let slice = 0; slice <= 128; slice++) {
    for (let point = 0; point <= 51; point++) {
      const index = slice * points.length + point;
      vertex.fromBufferAttribute(shell.attributes.position, index);
      const side = vertex.x < 0 ? -1 : 1;
      const normal = seatNormal.clone(); normal.x *= side;
      const relative = vertex.clone().sub(new THREE.Vector3(side * .95, .48, 0));
      const distance = relative.dot(normal);
      const radial = relative.addScaledVector(normal, -distance).length();
      if (distance > 0 && radial < .44) {
        const weight = 1 - THREE.MathUtils.smoothstep(radial, .31, .44);
        vertex.addScaledVector(normal, -distance * weight);
        shell.attributes.position.setXYZ(index, vertex.x, vertex.y, vertex.z);
      }
    }
  }
  shell.computeVertexNormals();
  const distances = [0];
  for (let i = 1; i <= 51; i++) distances.push(distances[i - 1] + points[i].distanceTo(points[i - 1]));
  for (let slice = 0; slice <= 128; slice++) {
    for (let point = 0; point <= 51; point++) {
      shell.attributes.uv.setY(slice * points.length + point, distances[point] / distances[51]);
    }
  }
  const segments = points.length - 1;
  const outside = [], inside = [], indices = shell.index.array;
  for (let segment = 0; segment < 128; segment++) {
    const start = segment * segments * 6;
    outside.push(...indices.slice(start, start + 51 * 6));
    inside.push(...indices.slice(start + 51 * 6, start + segments * 6));
  }
  shell.setIndex([...outside, ...inside]);
  shell.addGroup(0, outside.length, 0);
  shell.addGroup(outside.length, inside.length, 1);
  const lining = new THREE.MeshStandardMaterial({color:'#181410',roughness:.85});
  helmet.add(new THREE.Mesh(shell, [ceramic, lining]));
  const metal = new THREE.MeshPhysicalMaterial({color:'#a39c90',metalness:1,roughness:.19,clearcoat:.35,clearcoatRoughness:.12});
  for (const side of [-1, 1]) helmet.add(new THREE.Mesh(createHornGeometry(side), [ceramic, metal]));
  const rimProfile = [[1.18,-.79],[1.2,-.77],[1.2,-.61],[1.18,-.59],[1.17,-.61],[1.17,-.77],[1.18,-.79]];
  helmet.add(new THREE.Mesh(new THREE.LatheGeometry(rimProfile.map(p => new THREE.Vector2(...p)), 128), metal));
  const surround = curvedStrip(1.86, .31, 1.192, -.435, metal);
  const track = curvedStrip(1.78, .24, 1.203, -.435, new THREE.MeshStandardMaterial({color:'#070606',roughness:.25}));
  const red = new THREE.MeshPhysicalMaterial({color:'#d50700', emissive:'#f91403',emissiveIntensity:.7,roughness:.23,clearcoat:1});
  const fill = curvedStrip(1.68, .16, 1.216, -.435, red);
  helmet.add(surround.mesh, track.mesh, fill.mesh);
  const fastenerMaterial = new THREE.MeshStandardMaterial({color:'#25211d',metalness:.75,roughness:.45});
  for (const side of [-1,1]) {
    const fastener = new THREE.Mesh(new THREE.SphereGeometry(.022, 16, 8), fastenerMaterial);
    const angle = side * .73;
    fastener.position.set(Math.sin(angle) * 1.21, -.435, Math.cos(angle) * 1.21);
    fastener.scale.set(1,1,.4);
    fastener.rotation.y = angle;
    helmet.add(fastener);
  }
  const glow = new THREE.PointLight('#ff1708', .12, 1.2, 2);
  glow.position.set(-.3, -.415, 1.3);
  helmet.add(glow);
  let previousFill = -1;
  helmet.userData.animate = seconds => {
    const fraction = allowanceAt(seconds);
    if (fraction !== previousFill) { fill.setFill(fraction); previousFill = fraction; }
    glow.intensity = fraction * .14;
    red.emissiveIntensity = .55 + (seconds % 12 > 9.2 ? Math.sin(Math.min(1, (seconds % 12 - 9.2) / 1.8) * Math.PI) * .5 : 0);
  };
  helmet.userData.animate(0);
  return helmet;
}

export function disposeHelmet(root) {
  const geometries = new Set(), materials = new Set(), textures = new Set();
  root.traverse(object => {
    if (object.geometry) geometries.add(object.geometry);
    for (const material of [object.material].flat().filter(Boolean)) {
      materials.add(material);
      if (material.map) textures.add(material.map);
      if (material.bumpMap) textures.add(material.bumpMap);
    }
  });
  geometries.forEach(geometry => geometry.dispose());
  materials.forEach(material => material.dispose());
  textures.forEach(texture => texture.dispose());
}
