# VikingBar

Know how much mobile data remains without opening My Viking.

## Product

A small native Mac menu bar app. The icon communicates current usage; the menu explains the allowance, expiry, and freshness. Data balance is primary. History, forecasts, Viking Points, and bills add detail without delaying or hiding that balance.

## Principles

- Provider-reported balances are authoritative. Forecasts are labeled estimates.
- Show unknown, stale, unavailable, and zero as distinct states.
- Keep each SIM's data separate. Points belong to the customer; grouped invoices may span subscriptions.
- Read account data only. Account changes, payments, plan changes, and SIM operations are outside the product.
- Keep credentials and account data local. Hosted CI uses synthetic fixtures.
- Follow CodexBar's native UI and shared-core approach. Add abstractions only when VikingBar needs them.

## First release scope

Live data allowance, renewal/expiry, extra charges, refresh control, SIM selection, and local installation. History, points, and bills can follow as independent slices. A first development build does not promise notarization, automatic updates, Intel support, or public distribution.

## Success

The installed app shows the same bundle figures as the API, survives token refresh and relaunch, and explains stale data. Each feature has repeatable proof against its real dependency where required by its issue.
