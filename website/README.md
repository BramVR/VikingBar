# VikingBar website

The page introduces VikingBar's data-balance features. The Source panel links to the Swift source and account setup. The interactive menu follows the approved design in GitHub issue #22. SIMs, bundles, refresh, units, and menu-label settings use synthetic data and never connect to Mobile Vikings.

## Run the page

From this directory, install the locked dependencies:

```sh
	npm ci
```

Start the local preview:

```sh
	npm run dev -- --host 127.0.0.1 --port 4173 --strictPort
```

Open the address printed by Vite. Select a sample SIM to change the demonstration balance. Select a source file to read its description. **Get VikingBar** opens development-build information and links to the repository's download and account guides.

## Check the page

Build the production files:

```sh
	npm run build
```

Verify the bundled static-server behavior:

```sh
	npm run test:sites
```

The build writes `dist/client` and the bundled hosting adapter. No site is published by these commands.

## Adjust the content

Edit `src/App.jsx` for hero copy, source references, and links. Edit `src/styles.css` for layout and motion.

The hero uses a hollow, rounded Three.js helmet with curved horns and a curved allowance strip. ImageGen supplies the ceramic texture, fallback, and three storyboard thumbnails. `src/helmet-model.js` owns the geometry and material; `src/HelmetScene.jsx` owns lighting, depth of field, ambient occlusion, restrained bloom, and interaction. Drag the helmet to rotate, use arrow keys, or press Home to reset. Drag the larger plus-sign stars to move them; they spring back onto the spiral. Touch users can drag horizontally while preserving vertical page scrolling.

`src/star-field.js` uses upright slender plus signs with Astra-inspired light and subtle halos in warm ivory, vermilion/coral and restrained violet. Near stars move along a closed curved path; 320 tiny orbital stars and 420 distant stars add depth. Drag empty space to turn the field; drag the helmet to rotate it, with a smaller delayed orbit in the stars. `src/allowance-motion.js` controls the illustrative 12-second full-to-empty/refill cycle. The storyboard buttons select a phase; when motion is paused, Refill shows its midpoint. These controls never alter the native card's sample allowance.

**Pause motion** freezes automatic animation. Reduced motion is respected, and hidden/offscreen rendering is suspended. All scene geometry, textures, render targets, and effects are disposed on unmount. WebGL failure uses a static ImageGen fallback. The sample card's cyan meter tracks the selected synthetic allowance.

Run `node --test tests/*.test.mjs` for website checks, including the animation boundaries and outward horn normals.

Edit `src/BalanceDemo.jsx` for the isolated demo data and interactions. Sample dates are anchored to 8 September 2026. The menu-bar helmet and label agree with the selected sample. Settings affect only this page session; refresh is a simulated interaction.

Design exploration files under `output/` are local and excluded from the repository. The website's runtime assets are in `public/assets`. See [reference observations](design-reference-notes.md).

Barlow Condensed and DM Sans are self-hosted. Their license files are in `public/assets/fonts`.

## Product information

`src/InfoSections.jsx` adds setup steps, requirements, a compact menu-bar example, native disclosure FAQs, and build/setup/source links. Copy stays factual; connection details remain in the setup guide.

## GitHub Pages and search

Public URL: https://vikingbar.bramvanrompuy.be/.

`.github/workflows/pages.yml` builds and tests pull requests. Changes to the website on `main` publish `dist/client` to GitHub Pages through the `github-pages` environment. The workflow can also be dispatched manually. Repository Settings → Pages must use GitHub Actions as its source.

Reproduce the Pages build locally:

```sh
VITE_BASE_PATH=/ npm run build
npm test
VITE_BASE_PATH=/ npm run preview -- --host 127.0.0.1 --port 4183 --strictPort
```

Open `http://127.0.0.1:4183/`. Production and development previews use `/`.

Set the repository's Pages custom domain to `vikingbar.bramvanrompuy.be`. In Antagonist DNS for `bramvanrompuy.be`, use a `CNAME` named `vikingbar` pointing to `bramvr.github.io.`. Enable HTTPS enforcement after GitHub issues the certificate. GitHub Actions deployments use the Pages setting and do not require a `CNAME` file.

The build pre-renders the React page, then hydrates the same content for interactions. Search crawlers receive product information, requirements, setup, and FAQ answers without executing JavaScript. `src/site.js` owns production metadata; `src/questions.js` supplies both visible FAQ answers and JSON-LD. The build emits canonical and social tags, WebSite/SoftwareApplication/FAQPage structured data, a sitemap, a noindex 404 page, and a factual `llms.txt`. Sample balances are marked `data-nosnippet`.

The social image comes from `docs/assets/vikingbar-header.png`. No invented ratings, prices, or official-provider affiliation appear in structured data. FAQ markup describes the content; it does not promise a Google rich result. Google removed FAQ rich results in May 2026.

The custom domain serves `robots.txt` at its root and lists `https://vikingbar.bramvanrompuy.be/sitemap.xml`. Submit that sitemap through a verified Search Console or Bing Webmaster Tools property if available. No ownership verification, search indexing, or ranking is implied by deployment. `llms.txt` is an optional convenience for readers and tools, not a search-engine requirement.

References: [Google AI search guidance](https://developers.google.com/search/docs/appearance/ai-features), [Google search documentation updates](https://developers.google.com/search/updates), [OpenAI crawler documentation](https://developers.openai.com/api/docs/bots), and [GitHub Pages workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).
