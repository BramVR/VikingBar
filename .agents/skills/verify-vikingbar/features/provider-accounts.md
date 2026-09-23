# Provider accounts and services

## Behavior

Provider and Account pickers retain separate account slots. Add account creates a new slot; reconnect replaces the selected slot's connection. Each account keeps its own credentials, cache, lease, last result, and errors. The app runs one active worker and rejects delayed replies from a previous account. Failed or cancelled Add attempts to restore the prior account; restoration failures remain explicit. Choosing a provider selects its first catalog account, not a remembered last account for that provider.

Production currently exposes Mobile Vikings. Home internet is a synthetic adapter used to prove shared presentation and isolation. The separate Telenet feasibility proof does not register a native provider; Proximus is not implemented.

## Drive

Run `make smoke-app-fixture` under the parent skill's launch/doctor/cleanup contract. Inspect the provider/account controls and the named captures. Switch to the home provider: first service has 980 GB remaining, second 960 GB. Bills, Points, mobile bundle details, and My Viking are absent. Visit the failing home account, return to the original mobile account (36 GB), select the second mobile account (60 GB), then return to the original again. Match identity and allowance together; another account's success must not become the failed account's data.

Use the explicit synthetic CLI path for credential-free checks:

```sh
.build/debug/vikingbar fixture-accounts
.build/debug/vikingbar fixture-accounts --service second-service
.build/debug/vikingbar fixture-accounts --account mobile-vikings/00000000-0000-0000-0000-000000000002
.build/debug/vikingbar fixture-accounts --account fixture-home/00000000-0000-0000-0000-000000000004
```

The generic CLI mobile fixture is 60 GB, including its legacy account key; the native original mobile fixture is 36 GB. Keep those fixture expectations separate.

Normal `accounts list` reads the real catalog. `accounts add` and `accounts select` mutate it; do not use them as fixture diagnostics. Authorized `live --account ACCOUNT --cached` targets only that invocation; it does not change the shared selection. Read [live balance](live-balance.md) before opening a stored live session.

## Evidence and limits

Require native fixture success and owned Quit cleanup, inspect home/mobile/failure captures, and retain JSON receipts. On `d7b0e14`, the maintenance fixture pass verified this switching sequence. It does not prove multiple live accounts, a live Telenet home card, or Telenet mobile. The Mobile Vikings fixture-state picker governs mobile synthetic states; its presence on a home fixture is not evidence that it changes that home's data.

Source entry points: `Sources/VikingBar/PopoverView.swift`, `AppSession.swift`, `AccountDirectoryClient.swift`, `Sources/VikingBarCore/Accounts.swift`, `ProviderAccounts.swift`, `FixtureProviderAccount.swift`, and `Sources/VikingBarCLI/AccountCommands.swift`.
