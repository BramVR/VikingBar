# Website

## Behavior

Public product page with a rotating helmet, optional background motion, synthetic balance/history/Bills/Points/account views, setup/FAQ, source references, and an unsigned-preview download dialog. Demo preferences affect only the page session. The sample menu starts with its GB label visible; the native app defaults to icon-only.

## Launch and doctor

From `website/`, run `npm ci`, `npm run build`, then `npm test`; tests inspect built output. Check port 4173 is free. Start one owned server with `npm run dev -- --host 127.0.0.1 --port 4173 --strictPort`. Record listener PID, parent, start time, and command. Require matching process identity, HTTP success, and the VikingBar document before opening one browser tab. Verify the **Your data. One glance.** hero. After a failed drive, recheck process and HTTP health; reload only if the page is wedged.

## Drive

1. Inspect the rendered helmet or static WebGL fallback. Exercise arrows and Home reset. Use the footer **Pause motion** / **Enable motion** button. There is no Refill control. While paused, expand a FAQ and check background positions stay anchored.
2. Scope actions to **Interactive sample VikingBar menu**; a separate billing showcase has duplicate navigation controls. The history companion starts open. Inspect missing, confirmed-zero, and partial-today days and the labeled estimate; close and reopen it.
3. Personal SIM Monthly data starts at 36/50 GB. Work SIM Monthly data is 8/20 GB; Work Extra data is 1.5/3 GB with its own expiry and €1.20 charges. Expand Bundle details and verify Work-specific text. Refresh must briefly disable itself, then show **Sample refreshed just now**.
4. In Settings, use the **Data units** combobox for GiB and uncheck **Show remaining GB in menu bar**. Work Extra reads 1.4/2.8 GiB; the sample menu loses its amount. Remaining/Used, refresh interval, and launch-at-login controls remain demo-only. Inspect Account and customer-wide Points, including expanded signed transaction states.
5. Scope the second showcase to **Interactive sample billing menu**. Issued SAMPLE-2026-001 has €15 total, €10 due, €5 reduction, 5 points, and grouped scope. Its QR is explicitly illustrative and contains no payment instructions; Open PDF is disabled. Paid SAMPLE-2026-002 has €0 due and no bank transfer. Refresh must settle at **Updated just now**. Copy controls touch the clipboard; skip them unless that mutation is authorized.
6. Open Source, select DataCard.swift, and inspect its description and link. Get VikingBar opens **Try the unsigned preview.** Verify macOS 14+, Apple Silicon, unsigned/not notarized status, download without a GitHub account, API approval/public-client prerequisite, direct sign-in and optional 1Password helper. Inspect release/setup destinations without downloading or entering an account flow.

Read current DOM roles before acting. Native AX can describe an HTML button as a checkbox; browser automation must use the rendered DOM role. Failed selector resolution does not authorize repeating an uncertain action.

## Evidence and cleanup

Keep named observations and any saved captures under a task-owned proof directory. Inspect actual screenshots for visual claims. Close only the owned tab and stop only the recorded server. Confirm its PID and port are gone and evidence remains. Local preview does not prove deployed GitHub Pages identity, native behavior, clipboard success, or real payment/PDF behavior.

On 2026-09-23 at `d7b0e14`, build and 16 website tests passed. One browser pass covered the rendered helmet, motion toggle/Home, missing/zero history, separate SIM/bundle amounts, details, refresh, GiB/menu preference, Account, Points transactions, issued/paid Bills, disabled PDF, source/download dialogs, FAQ, and unchanged paused background geometry. Copy and external links were not activated. Named observations survived tab/server cleanup. Browser content export was unavailable; no exported DOM or saved screenshot was claimed.
