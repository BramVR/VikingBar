# Fixture selection

## Sub-features

Finite, unlimited, exhausted, stale, error, Not connected, two synthetic SIMs with separate bundles, and simulated Refresh.

## How to get to it

Launch with `--fixture finite`, open the helmet, then footer **Settings**. Choose **Fixture state** and press **Back**. Live launches have no fixture picker. Selecting Not connected from an explicit fixture launch cannot create an account worker or read real settings, Keychain, or network data.

## Native proof

`make smoke-app-fixture` covers five fixtures and Not connected in icon-only and amount modes. It preserves status crops and settled balance captures for each selection. Read the [data card recipe](data-card.md) for navigation, selectors, and cleanup.

- Finite shows 36 GB remaining of 50 GB, 14 GB used, and 72% remaining.
- Unlimited shows usage without a finite percentage and an infinity mark.
- Exhausted shows zero remaining and an empty inset.
- Stale retains its known amount and fill, with the old update date and warning.
- Error shows unavailable amounts and a question mark.
- Not connected shows a clear setup state without a fabricated allowance or unavailable-value stack. The fixture launch stays isolated.

Default status title is empty. Amount mode shows `36 GB`, `Unlimited`, `0 GB`, `36 GB`, and `Unavailable` for the five fixtures. Not connected shows `Unavailable` in amount mode. Snapshot provenance remains explicit in tooltip, accessibility, and CLI. Fixture-only Settings also explains isolation.

Use `vikingbar.subscriptionPicker` and `vikingbar.bundlePicker` on the balance. Example SIM has Monthly data with 36/50 GB and Extra data with 4/5 GB. Travel SIM has Monthly data with 8/10 GB and Extra data with 1/2 GB. Each SIM switch selects its monthly bundle. Verify identity and allowance together. Settings and Back preserve the current selection.

Refresh displays a synthetic busy interval then advances its update timestamp, preserving amounts and the selected fixture state. It never calls the account worker. Verify the disabled refresh and selectors during that interval.

## Appearance and persistence

The smoke launches app-local light, dark, high-contrast-light, and high-contrast-dark appearances. The final launch also requests reduced transparency. Use `--fixture-appearance` and `--fixture-reduce-transparency` only with `--fixture`; never change global appearance preferences.

The display preference uses the smoke's new isolated settings file. Require default off, saved on after relaunch, saved off after relaunch, and four native Quit exits. Current redesigned native proof remains pending until the real gate and screenshot inspection pass.
