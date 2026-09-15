# Prototype Instructions

Run the local server yourself and open the preview in the browser available to this environment. Do not give the user server-start instructions when you can run it.

Before making substantial visual changes, use the Product Design plugin's `get-context` skill when the visual source is unclear or no longer matches the current goal. When the user gives durable prototype-specific design feedback, preferences, or decisions, record them in `AGENTS.md`.

When implementing from a selected generated mock, treat that image as the source of truth for layout, component anatomy, density, spacing, color, typography, visible content, and hierarchy.

Build app UI in `src/`. Keep `.openai/hosting.json`, `worker/index.js`, `scripts/prepare-sites-build.mjs`, and `tests/sites-worker.test.mjs` intact so the same local prototype can be handed to Sites. Before a Sites handoff, run `npm run build` and `npm run test:sites`; the build must leave `dist/client/index.html`, `dist/server/index.js`, and `dist/.openai/hosting.json`.

## VikingBar direction

- Minimal dark long page, red accents, ceramic helmet with immersive lighting and depth.
- Prefer factual product information over sales copy. Use plain headings and concise explanations; avoid persuasive slogans, oversized sales banners, roadmap or future-feature claims.
- Technical setup and source details belong in the reference panel and download details.
- Keep the sample balances visibly labelled. Never connect the website to an account.
- Keep motion optional and respect reduced-motion preferences.
- Use real Three.js geometry. Base header: `output/imagegen/vikingbar-round-03.png`. Latest direction replaces its bricks with Mobile Vikings plus-sign stars in space. Selected animation sequence: `vikingbar-round-01.png`. No elastic threads.
- Match the reference closely: rounded hollow helmet, short thick upward horns, flush metal collars, warm textured ceramic, curved allowance strip. No extruded flat logo or chin guard.
- Stars must be upright + signs, never rotated Xs. Follow Astra's fine luminous field: tiny stars in warm ivory, vermilion/coral and restrained violet, sparse brighter plus signs, subtle halos and a loose spiral with depth. Near plus signs stay draggable. Helmet rotation gently carries the star field with a delayed, smaller orbit; independent background dragging remains available.
- Animation drains full to empty, holds, then refills smoothly. Keep this illustrative sequence separate from the native sample balances.
- Use Mobile Vikings' condensed display typography, black/ivory contrast, and vermilion red more strongly. Preserve independent VikingBar identity.
- Demo menu follows issue #22: native system typography, cyan allowance, SIM/bundle selection, expiry, details/charges, refresh, account link, footer settings. Synthetic data only.

- Keep sections free of small explanatory captions: no animation disclaimer, below-card sample caption, or helmet drag hint. Retain the demo label inside the sample menu.

- Horn collars require flat mounting seats, with no bowl clipping through metal. Allowance surround meets the lower metal rim. Metal is polished and reflective, matching the small helmet references.

- Setup starts with requesting Mobile Vikings API access by email and waiting for the approved public client ID. Present direct native sign-in first and the configured 1Password helper as optional. State that no client secret is required; a Mobile Vikings account alone remains insufficient.
