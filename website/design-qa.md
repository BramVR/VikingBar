# Website design QA

Checked 8 September 2026. Local preview only.

## Selected references

- Header and floating bars: `../output/imagegen/vikingbar-round-03.png`.
- Full, empty, refill storyboard: `../output/imagegen/vikingbar-round-01.png`.
- Native menu: `../output/references/issue-22-card.png`.
- The user explicitly corrected the selection to floating bars, not elastic threads, and requested close visual fidelity, rounded geometry, correct horns, spiral placement, and depth effects.

## Changes and corrections

- Replaced the flat extruded icon with a hollow rounded shell, short thick horns, flush metal collar sections, a curved allowance strip, and a metal rim.
- Fixed inward horn triangle winding. Regression test failed on the original mesh, passed after reversing the triangles. Browser rotation checked both horns from the back.
- Remapped shell UVs by profile distance to eliminate vertical texture stretching. ImageGen supplied a more detailed ceramic texture.
- Matched the compact desktop header, headline width, button position, and full-width scene. Source details now open in a panel. Mobile retains Source and Get VikingBar.
- Placed bars using coordinates and depths from the selected image, then moved them along a loose closed spiral. Larger foreground bars and smaller distant bars have different apparent size and lens softness. Individual bars are draggable and spring back to the path.
- Added depth of field, ambient occlusion, warm rim lighting, subtle bloom, and multisampled rendering. Reduced excessive bloom found during the side-by-side comparison.
- Added the full-to-empty/refill sequence and clickable storyboard. Pausing freezes automatic motion; the controls can still show full, empty, or the refill midpoint. The sample menu balance is independent.

## Evidence

- `qa/rounded-header-desktop.png`: 1513 × 1040 viewport, matching the source dimensions. It includes the header and storyboard.
- `qa/rounded-header-mobile.png`: 390 × 844 viewport. Mobile Source/Get navigation was verified after this capture.
- Source and implementation were inspected together. Main differences from the generated concept remain the reconstructed mesh/material details and moving bar positions; the source is a static illustration, not an available 3D model. No pixel-identical claim.

## Verification

- Browser: full/empty/refill controls, pause, individual bar drag, keyboard rotation through the back, Home reset, mobile Source and download dialogs, demo SIM and bundle selection.
- Work SIM / Extra data: 1.5 GB of 3 GB, 50%, expiry 25 September, €1.20 extra charges.
- Mobile page width equals viewport width, 390 px. No horizontal overflow. Browser error log empty. Viewport override reset and preview left open.
- Website production build and seven Node tests pass. The tests include outward horn normals, animation boundaries, and static-server behavior.
- Repository `make check` passes, including format, lint, Swift build/tests, CLI fixture smoke, docs, and 62 Python tests. Log: `.build/website-final-check.log` at repository root.
- No native app code or account/Keychain state changed. No deployment, commit, or push.

## Limits

- Touch layout checked in a browser viewport, not on a physical phone.
- Reduced-motion and WebGL-failure paths reviewed in code; pause/manual controls tested in the browser.
- Vite reports a large Three.js/effects bundle, approximately 803 kB minified / 216 kB gzip.

## Plus-star revision

Latest request replaces the bricks with Mobile Vikings' plus signs as stars in space. Inspected the live site's decorative SVG pattern: a 6 × 6 plus with approximately 0.918-unit strokes, purple `#AA25EE`, rotated 45 degrees. Reused those proportions in flat Three.js glyphs. Near stars retain the draggable curved path; 180 faint instanced crosses form the distant field. A few brighter ivory and muted red crosses provide foreground depth. Helmet and refill sequence retained.

Desktop and 390 px mobile appearance inspected; no browser errors. Evidence: `qa/plus-stars-desktop.png`. Production build and all seven website tests pass. The latest Three.js bundle is approximately 821 kB / 221 kB gzip. Earlier bar-specific findings above describe the superseded revision.


## Upright luminous plus revision

Latest direction supersedes the rotated purple crosses: upright slender + signs, cool-white and warm-white light, sparse halos, 320 tiny orbital plus signs and 420 distant stars. Astra's live hero inspected for density, brightness variation and depth. Background dragging turns the field; direct helmet dragging remains separate. Desktop and narrow layout inspected with no browser errors. Build and seven tests pass.


## Colored stars and helmet response

Palette updated to vermilion/coral, warm ivory and restrained violet across foreground, orbital and distant stars, with matching halo colors. Helmet rotation now induces a smaller delayed field rotation; explicit field drag stays additive. Reduced motion applies the response immediately without ongoing easing. Build and seven tests pass.


## Horn seats and lower rim

Flattened the shell locally to each horn collar's mounting plane, blending back into the dome outside the contact patch. Lowered the allowance assembly by 0.075 model units so its surround meets the bottom rim. Metal now uses a clean physical material (metalness 1, roughness 0.19) without the ceramic grain map. Front and opposite-side views checked against the small ImageGen helmets. The live mesh remains a recreation of those raster references, not an identical source model. Build and seven tests pass.


## Informational sections and access prerequisites

Implemented the refined informational concept: three setup columns, concise requirements, an illustrative menu-bar strip, native disclosure FAQs, and build/setup/source links. Desktop and 390 px mobile layouts inspected; no horizontal overflow. FAQ expansion and link destinations verified. The latest correction adds the API access request before setup, links the provider instructions and email address, and explicitly states the current configured 1Password dependency in setup, FAQ and download details. Direct account connection is only a draft ticket, not a shipped feature. Full `make check`, the website build, seven website tests and docs checks passed.
