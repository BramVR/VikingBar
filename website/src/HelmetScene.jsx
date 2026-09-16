import { useEffect, useRef, useState } from 'react';
import * as THREE from 'three';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { createHelmet, disposeHelmet } from './helmet-model.js';
import { createStarField } from './star-field.js';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { BokehPass } from 'three/addons/postprocessing/BokehPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { SSAOPass } from 'three/addons/postprocessing/SSAOPass.js';

export function HelmetScene({ motion }) {
  const host = useRef(null);
  const runtime = useRef(null);
  const [ready, setReady] = useState(false);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const element = host.current;
    let renderer;
    try {
      renderer = new THREE.WebGLRenderer({ alpha: true, antialias: true, powerPreference: 'low-power' });
    } catch {
      setFailed(true);
      return;
    }
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 1.5));
    renderer.setClearColor(0x000000, 0);
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = .92;
    renderer.domElement.setAttribute('aria-hidden', 'true');
    element.appendChild(renderer.domElement);

    const scene = new THREE.Scene();
    const room = new RoomEnvironment();
    const generator = new THREE.PMREMGenerator(renderer);
    const environment = generator.fromScene(room, .04);
    scene.environment = environment.texture;
    scene.environmentIntensity = .3;
    room.dispose();
    generator.dispose();
    const camera = new THREE.PerspectiveCamera(32, 1, .1, 30);
    camera.position.set(0, .1, 7.3);
    const pivot = new THREE.Group();
    pivot.scale.setScalar(1);
    const helmet = createHelmet(() => runtime.current?.requestDraw());
    pivot.add(helmet);
    scene.add(pivot);
    const bars = createStarField();
    scene.add(bars);
    const raycaster = new THREE.Raycaster();
    const pointer = new THREE.Vector2();
    const dragPlane = new THREE.Plane();
    const intersection = new THREE.Vector3();
    const setRay = event => {
      const box = element.getBoundingClientRect();
      pointer.set((event.clientX - box.left) / box.width * 2 - 1, -(event.clientY - box.top) / box.height * 2 + 1);
      raycaster.setFromCamera(pointer, camera);
    };
    const key = new THREE.DirectionalLight('#fff0d9', 1.9);
    key.position.set(-3, 4, 2);
    const rim = new THREE.DirectionalLight('#ffe1c2', 1.6);
    rim.position.set(3, 1, -2);
    const fill = new THREE.DirectionalLight('#e1e9ff', .25);
    fill.position.set(2, 2, 5);
    scene.add(key, rim, fill);
    const composer = new EffectComposer(renderer);
    composer.renderTarget1.samples = 4;
    composer.renderTarget2.samples = 4;
    const renderPass = new RenderPass(scene, camera);
    const occlusion = new SSAOPass(scene, camera, 1, 1, 12);
    occlusion.kernelRadius = .18;
    occlusion.minDistance = .001;
    occlusion.maxDistance = .07;
    const bokeh = new BokehPass(scene, camera, {focus:6.35,aperture:.0013,maxblur:.009});
    const bloom = new UnrealBloomPass(new THREE.Vector2(1,1), .075, .3, 3.5);
    const output = new OutputPass();
    composer.addPass(renderPass); composer.addPass(occlusion); composer.addPass(bokeh); composer.addPass(bloom); composer.addPass(output);

    const state = {
      motion: false, visible: true, frame: 0, yaw: -.55, pitch: -.26,
      targetYaw: -.55, targetPitch: -.26, pointer: 0, scroll: 0,
      dragging: false, pointerID: null, lastX: 0, lastY: 0,
      destroyed: false, elapsed: 0, orbitTime: 0, depth: 0, lastTime: 0, chip: null, fieldDragging: false, fieldYaw: 0, fieldPitch: 0, starFollowYaw: 0, starFollowPitch: 0,
    };
    const draw = time => {
      state.frame = 0;
      if (state.destroyed || !state.visible || document.hidden) return;
      const dt = state.lastTime ? Math.min((time - state.lastTime) / 1000, .04) : 0;
      if (state.motion) {
        state.elapsed += dt;
        state.orbitTime += dt;
        state.depth = state.scroll;
      }
      state.lastTime = time;
      const easing = state.motion ? .10 : 1;
      state.yaw = THREE.MathUtils.lerp(state.yaw, state.targetYaw, easing);
      state.pitch = THREE.MathUtils.lerp(state.pitch, state.targetPitch, easing);
      pivot.rotation.set(state.pitch, state.yaw, -.10);
      helmet.userData.animate(state.elapsed);
      // Follow a little behind the helmet; keep the independent field drag additive.
      const followEasing = state.motion ? 1 - Math.exp(-3 * dt) : 1;
      state.starFollowYaw = THREE.MathUtils.lerp(state.starFollowYaw, Math.sin(state.yaw + .55) * .22, followEasing);
      state.starFollowPitch = THREE.MathUtils.lerp(state.starFollowPitch, (state.pitch + .26) * .25, followEasing);
      bars.rotation.set(state.fieldPitch + state.starFollowPitch, state.fieldYaw + state.starFollowYaw, 0);
      bars.userData.animate(state.orbitTime, state.motion, dt, state.chip);
      pivot.rotation.y += Math.sin(state.orbitTime * .3) * .025 + state.depth * .13;
      pivot.position.y = -.12 + Math.sin(state.orbitTime * .65) * .025 - state.depth * .12;
      key.position.x = -3 + state.pointer * 1.4;
      camera.position.z = 7.3 - state.depth * .22;
      composer.render();
      if (state.motion) requestDraw();
    };
    const requestDraw = () => {
      if (!state.frame && state.visible && !document.hidden && !state.destroyed) state.frame = requestAnimationFrame(draw);
    };
    const resize = () => {
      const { width, height } = element.getBoundingClientRect();
      if (!width || !height) return;
      renderer.setSize(width, height);
      composer.setSize(width, height);
      camera.aspect = width / height;
      // Preserve the horn tips in narrow canvases without changing the model.
      camera.fov = THREE.MathUtils.radToDeg(2 * Math.atan(Math.max(3.3, 3.65 / camera.aspect) / (2 * 7.3)));
      camera.updateProjectionMatrix();
      occlusion.setSize(Math.round(width), Math.round(height));
      bokeh.uniforms.aspect.value = camera.aspect;
      const span = 2 * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)) * 7.3 * camera.aspect;
      pivot.position.x = width > 900 ? span * .185 : 0;
      bars.position.x = pivot.position.x;
      bars.scale.setScalar(width > 900 ? .9 : .72);
      requestDraw();
    };
    const onScroll = () => {
      const box = element.getBoundingClientRect();
      state.scroll = Math.max(0, Math.min(1, -box.top / box.height));
      requestDraw();
    };
    const onVisibility = () => {
      state.lastTime = 0;
      if (document.hidden) { cancelAnimationFrame(state.frame); state.frame = 0; }
      else requestDraw();
    };
    const onDown = event => {
      if (event.button !== 0 || !event.isPrimary) return;
      state.dragging = true;
      state.pointerID = event.pointerId;
      state.lastX = event.clientX;
      state.lastY = event.clientY;
      setRay(event);
      const hit = raycaster.intersectObjects([pivot, bars], true)[0];
      state.chip = hit?.object.userData.isStar ? hit.object : null;
      let hitParent = hit?.object;
      while (hitParent && hitParent !== pivot && hitParent !== bars) hitParent = hitParent.parent;
      state.fieldDragging = !state.chip && hitParent !== pivot;
      if (state.chip) {
        const world = state.chip.getWorldPosition(new THREE.Vector3());
        dragPlane.setFromNormalAndCoplanarPoint(new THREE.Vector3(0, 0, 1), world);
      }
      element.setPointerCapture(event.pointerId);
      element.classList.add('is-dragging');
    };
    const onMove = event => {
      if (state.dragging && event.pointerId === state.pointerID) {
        if (state.chip) {
          setRay(event);
          if (raycaster.ray.intersectPlane(dragPlane, intersection)) state.chip.position.copy(bars.worldToLocal(intersection));
          state.chip.userData.velocity.set(0, 0, 0);
        } else if (state.fieldDragging) {
          state.fieldYaw += (event.clientX - state.lastX) * .004;
          state.fieldPitch = THREE.MathUtils.clamp(state.fieldPitch + (event.clientY - state.lastY) * .002, -.35, .35);
        } else {
          state.targetYaw += (event.clientX - state.lastX) * .009;
          if (event.pointerType !== 'touch') state.targetPitch = THREE.MathUtils.clamp(state.targetPitch + (event.clientY - state.lastY) * .004, -.4, .25);
        }
        state.lastX = event.clientX;
        state.lastY = event.clientY;
        requestDraw();
      } else if (state.motion && event.pointerType !== 'touch') {
        const box = element.getBoundingClientRect();
        state.pointer = (event.clientX - box.left) / box.width - .5;
        requestDraw();
      }
    };
    const onUp = event => {
      if (event.pointerId !== state.pointerID) return;
      state.dragging = false;
      state.chip = null;
      state.pointerID = null;
      element.classList.remove('is-dragging');
      if (element.hasPointerCapture(event.pointerId)) element.releasePointerCapture(event.pointerId);
      requestDraw();
    };
    const onKey = event => {
      if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home'].includes(event.key)) return;
      event.preventDefault();
      if (event.key === 'ArrowLeft') state.targetYaw -= .2;
      if (event.key === 'ArrowRight') state.targetYaw += .2;
      if (event.key === 'ArrowUp') state.targetPitch -= .08;
      if (event.key === 'ArrowDown') state.targetPitch += .08;
      if (event.key === 'Home') { state.targetYaw = -.55; state.targetPitch = -.26; state.fieldYaw = 0; state.fieldPitch = 0; }
      state.targetPitch = THREE.MathUtils.clamp(state.targetPitch, -.4, .25);
      requestDraw();
    };
    const onContextLost = event => {
      event.preventDefault();
      cancelAnimationFrame(state.frame);
      state.frame = 0;
      state.destroyed = true;
      setReady(false);
      setFailed(true);
    };
    const observer = new IntersectionObserver(([entry]) => {
      state.visible = entry.isIntersecting;
      state.lastTime = 0;
      if (state.visible) requestDraw();
      else { cancelAnimationFrame(state.frame); state.frame = 0; }
    });
    observer.observe(element);
    const sizeObserver = new ResizeObserver(resize);
    sizeObserver.observe(element);
    const listeners = { pointerdown: onDown, pointermove: onMove, pointerup: onUp, pointercancel: onUp, lostpointercapture: onUp, keydown: onKey };
    Object.entries(listeners).forEach(([type, listener]) => element.addEventListener(type, listener));
    renderer.domElement.addEventListener('webglcontextlost', onContextLost);
    window.addEventListener('scroll', onScroll, { passive: true });
    document.addEventListener('visibilitychange', onVisibility);
    runtime.current = { state, requestDraw };
    resize();
    setReady(true);
    return () => {
      state.destroyed = true;
      cancelAnimationFrame(state.frame);
      observer.disconnect();
      sizeObserver.disconnect();
      Object.entries(listeners).forEach(([type, listener]) => element.removeEventListener(type, listener));
      window.removeEventListener('scroll', onScroll);
      document.removeEventListener('visibilitychange', onVisibility);
      renderer.domElement.removeEventListener('webglcontextlost', onContextLost);
      disposeHelmet(pivot);
      disposeHelmet(bars);
      environment.dispose();
      renderPass.dispose(); occlusion.dispose(); bokeh.dispose(); bloom.dispose(); output.dispose(); composer.dispose();
      renderer.dispose();
      renderer.domElement.remove();
      runtime.current = null;
    };
  }, []);

  useEffect(() => {
    if (!runtime.current) return;
    runtime.current.state.motion = motion;
    runtime.current.state.lastTime = 0;
    if (!motion) runtime.current.state.pointer = 0;
    runtime.current.requestDraw();
  }, [motion, ready]);



  return <div className="helmet-viewer">
    {(!ready || failed) && <div className="helmet-fallback rounded-fallback" role="img" aria-label="Rounded ivory VikingBar helmet with a red allowance bar"/>}
    <div ref={host} className={`helmet-canvas ${failed ? 'scene-unavailable' : ''}`} role={ready ? 'group' : undefined} tabIndex={ready ? 0 : -1} aria-label={ready ? 'Interactive Viking helmet. Drag or use arrow keys to rotate. Press Home to reset.' : undefined} />
  </div>;
}
