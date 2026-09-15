# Website

## Sub-features

Public product page, interactive helmet and allowance animation, synthetic balance menu, setup and requirements, FAQ, source references, and development-build dialog. The website demo never connects to a Mobile Vikings account. Its settings affect only the page session; the sample menu starts with its GB label visible even though the native app defaults to icon-only.

## Launch and doctor

From `website/`, run `npm ci`, then `npm run build` and `npm test` in that order; the tests read the built `dist/client` files. Check that port 4173 is free, then start `npm run dev -- --host 127.0.0.1 --port 4173 --strictPort` in a task-owned terminal session. Record the listener PID, parent, start time, and exact command. Before opening the page, require that the recorded process still owns the listener and `curl -fsS http://127.0.0.1:4173/` returns the VikingBar document. Open one task-owned browser tab and require the **Your data. One glance.** heading. After any failed browser action, check process and HTTP health again; if the page is wedged despite a healthy server, reload to the known home state before further driving.

## Drive

1. Inspect the hero visually. Require the 3D helmet or its static WebGL fallback. Toggle **Pause motion** and select **Refill**; the allowance strip must reflect the stage. The page also supports drag, arrow keys, and Home reset.
2. Open **Preview**. The card must say **Demo**. Personal SIM Monthly data starts at 36/50 GB; Work SIM Monthly data is 8/20 GB. Work SIM Extra data is 1.5/3 GB with its own expiry and €1.20 charges. Expand Bundle details and check that the text belongs to Work SIM. Press Refresh and observe the temporary disabled state followed by **Sample refreshed just now**.
3. In demo Settings, choose GiB and turn off **Show remaining GB in menu bar**. Return to the balance: Work Extra data reads 1.4/2.8 GiB, while the sample menu loses its adjacent amount. These controls do not change native app preferences.
4. Open **Source**, select `DataCard.swift`, and check its description and repository link. Open **Get VikingBar** and check the development-build, approved public-client API access and private repository prerequisites, plus direct sign-in and the optional configured 1Password helper. Expand a FAQ answer. Inspect link destinations without starting an account or download flow.

Keep task-local observations and any captured screenshots under `.build/proof/<run>/`; verify each named evidence file survives cleanup. Close only the task-owned tab, stop only the recorded Vite process/session, and confirm its PID and port are gone. Local preview proof does not establish that GitHub Pages has deployed the same commit.

## Proof status

On 2026-09-15, the local page at `3a62b144e86b9b8c5b6747ba0ad3c9d63e2a13f4` passed build and all 12 website tests. A browser pass inspected the rendered helmet, Refill with motion paused, both Work SIM bundles, details, refresh, GiB and menu-label settings, source and download dialogs, and FAQ. The task-owned tab and Vite listener exited; the task-local observation receipt remained. No external account or GitHub link was opened.
