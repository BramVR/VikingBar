# VikingBar website

The page introduces VikingBar's balance, 30-day SIM history, cycle estimates, Bills, Viking Points, and saved app settings. Bills includes a locally generated bank-transfer QR and copyable transfer fields. The Source panel links to the Swift source and account setup. The interactive menu follows the approved design in GitHub issue #22. SIMs, bundles, refresh, units, and menu-label settings use synthetic data and never connect to Mobile Vikings.

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

The hero uses a hollow, rounded Three.js helmet with curved horns and a curved allowance strip. ImageGen supplies the ceramic texture and fallback. `src/helmet-model.js` owns the geometry and material; `src/HelmetScene.jsx` owns lighting, depth of field, ambient occlusion, restrained bloom, and interaction. Drag the helmet to rotate, use arrow keys, or press Home to reset. Drag the larger plus-sign stars to move them; they spring back onto the spiral. Touch users can drag horizontally while preserving vertical page scrolling.

`src/star-field.js` uses upright slender plus signs with Astra-inspired light and subtle halos in warm ivory, vermilion/coral and restrained violet. Near stars move along a closed curved path; 320 tiny orbital stars and 420 distant stars add depth. Drag empty space to turn the field; drag the helmet to rotate it, with a smaller delayed orbit in the stars. `src/allowance-motion.js` controls the illustrative 12-second full-to-empty/refill cycle. The animation never alters the native card's sample allowance. The Full/Empty/Refill strip is omitted; motion remains controllable in the footer.

**Pause motion** freezes automatic animation. Reduced motion is respected, and hidden/offscreen rendering is suspended. All scene geometry, textures, render targets, and effects are disposed on unmount. WebGL failure uses a static ImageGen fallback. The sample card's cyan meter tracks the selected synthetic allowance.

Run `node --test tests/*.test.mjs` for website checks, including the animation boundaries and outward horn normals.

`src/BalanceDemo.jsx` owns two independent interactive menus. The main showcase opens its detailed history panel by default; the second starts in Bills. Both retain SIM and bundle selection, Bills/Points/Settings navigation, used/remaining display, units, and simulated refresh. Preferences affect only that menu's page session. No account or system settings change.

`src/demo-data.js` holds synthetic balances and history anchored to 16 September 2026. `src/HistoryDemo.jsx` shares day selection between compact and detailed charts. Hover selects a day; click opens details; arrow keys select days and Escape closes the panel. A SIM or bundle change resets history selection. Current-cycle totals exclude earlier days, and estimates exclude today. The detail panel sits beside the main menu on wide screens and inside it on narrower screens.

`src/BillingDemo.jsx` follows the supplied Bills design. Invoice selection distinguishes issued and paid samples, refresh temporarily hides the QR, and each copy button writes only its labeled field. IBAN copies without spaces. Public recipient details match the approved provider configuration; invoice identity, amounts, and reference are synthetic. The QR contains inert demo text, never payment instructions. `src/demo.css` loads after the main stylesheet to preserve companion layout.

Open PDF is disabled in the website template. Local fixture PDFs remain available as demo assets. Regenerate them with `scripts/generate-demo-invoices.py` using Python with ReportLab. On macOS, `swift scripts/generate-demo-qr.swift` regenerates the QR and independently decodes its payload with Vision. Assets are checked in; neither generator nor its tooling runs in the website or its build.

Design exploration files under `output/` are local and excluded from the repository. The website's runtime assets are in `public/assets`. See [reference observations](design-reference-notes.md).

Barlow Condensed and DM Sans are self-hosted. Their license files are in `public/assets/fonts`.

`public/THIRD_PARTY_LICENSES.txt` contains the licenses for bundled React, React DOM, Scheduler, and Three.js. Update their versions and license text from the installed packages when changing dependencies.

## Product information

`src/InfoSections.jsx` adds setup steps, requirements, a compact menu-bar example, native disclosure FAQs, and build/setup/source links. `src/App.jsx` owns the product articles. Layout follows `output/imagegen/vikingbar-info-refined-concept.png` in the repository root. Copy stays factual; connection details remain in the setup guide. The QR text reflects merged PR #33: local generation with a bundled helper, copyable transfer fields, and review in a banking app. VikingBar does not execute payments; users need no Go installation.

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

`src/DriftBackground.jsx` extends the hero motif through the page with sparse decorative pluses. CSS drift shares the footer motion toggle, respects reduced motion, and never intercepts pointer input. Mobile shows half the symbols.
