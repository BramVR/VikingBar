---
summary: "Connect a Mobile Vikings account and inspect its live balance."
read_when:
  - Connecting or reconnecting a live account
  - Changing live refresh, credential storage, or SIM selection
---

# Connect your Mobile Vikings account

## Before connecting

A Mobile Vikings account does not automatically include API access. Request it by emailing `api@mobilevikings.be`, including your name, the brand (Mobile Vikings), the application name (VikingBar), and its purpose (viewing your own balance). Wait for approval and client details before attempting to connect. See the provider's [API access instructions](https://docs.uwa.mobilevikings.be/).

Direct sign-in is the default connection method. Enter the approved public client ID, account username, and password in the native app. 1Password remains optional. Native live verification of the new direct form is pending; see [the proof prerequisite](live-proof.md#direct-sign-in-proof).

VikingBar's verified integration uses the support-approved public client with no client secret. The generic API documentation also describes confidential clients; confirm that Mobile Vikings approves a compatible public-client setup for your use. Do not put a client secret into the public-client ID field. See [authentication context](../CONTEXT.md#authentication).

## Connect the development app

Build the development app with `make package-app`, then open `.build/app/VikingBar.app`. Open the helmet in the menu bar and choose **Connect account**. Enter your public client ID and username, then enter your password in the masked field. Submit the form to connect. Cancel dismisses the form and clears its password. The app passes credentials through a private pipe to the bundled CLI and clears the form password when you submit. It never saves the password in settings or files. This route requires no 1Password, tmux, Python helper, service account, or credential-reference file.

For the optional method, choose **Connect with 1Password**. Select your approved credential reference file if prompted. The reference contains the vault, item ID, and field labels described in [local proof setup](live-proof.md#setup). It contains no credential values.

The packaged connection helper uses `/usr/bin/python3` and requires tmux, the 1Password CLI, and the authorized service-account setup in `~/.profile`. It sources that profile inside one private named tmux session and reads the configured item once. The helper supplies the OS username as `USER` only to tmux so the profile can select its service-account credential. The 1Password and CLI child environments remain restricted. The app never receives the service-account token. The initial password exchange releases the password before balance retrieval begins.

Opening the app without `--fixture` restores the stored session and refreshes it when connected. Each background refresh uses the stored token.

After connection, choose a SIM and data bundle in the card. Different bundles keep their own amounts, applicability, and expiry. Blank or whitespace-only titles display as `Data bundle N`, where N is the bundle's one-based position in the provider array. The picker and card use the same title, and raw provider values remain unchanged. The helmet represents the selected bundle. Extra charges show the selected SIM's out-of-bundle cost in euros; a missing amount stays unavailable. **Refresh now** requests an update. **Open My Viking** opens the provider's account website.

The app retains the last successful balance when a request fails and marks it stale. An unavailable amount remains unavailable. It never turns a missing response into a zero balance. Revoked credentials and an interrupted token rotation require an explicit reconnect.

Open **Bills** for the latest account invoice or credit note. Grouped totals remain account-level amounts, with the selected SIM's known relationship shown separately. Invoice failures leave the data balance usable. **Open PDF** downloads the requested document and opens its private local file. See [invoice fields, download handling, and proof](invoices.md).

## Viking Points

The Points tab shows the customer's Viking Points once for the account. Available points are spendable. Pending and blocked points remain separate. Switching SIMs does not change the owner of the points or duplicate the customer balance.

Expand recent transactions to inspect each amount and provider state. The list contains up to three pages of 20 transactions. A truncated list is labeled and cannot establish the available balance. The provider's balance endpoint supplies that figure directly.

Usage refresh publishes before points refresh. Points balance and transaction history each retain their last successful data and report failures separately. A points failure does not clear a usable data allowance. **Refresh now** updates both usage and points through the existing account session.

## Inspect the same balance in the CLI

Use the CLI embedded in the development bundle:

```sh
.build/app/VikingBar.app/Contents/MacOS/vikingbar live
.build/app/VikingBar.app/Contents/MacOS/vikingbar live --cached
```

The first command refreshes the stored session and prints the live state, snapshot, and shared menu presentation. The second reads the saved state. Both commands require explicit live access and may read the app's Keychain item. JSON contains private account display values and amounts. Keep that output local.

Use `--subscription ID` or `--bundle INDEX` to select a subscription or one of its provider-ordered bundles. Bundle indices are zero-based positions in the provider bundle array. `--cached` cannot be combined with either selection option. A different subscription starts with its own balance or an unavailable state. It never borrows another SIM's allowance.

An explicit fixture command remains isolated from account access:

```sh
.build/app/VikingBar.app/Contents/MacOS/vikingbar --fixture finite
```

For an automated native connection, pass `--credential-reference /absolute/private/credential-reference.json` to the app. It supplies the file normally chosen in the picker. `--proof-directory /absolute/private/new-proof` writes a redacted `connect-result.json` there. Create the private directory first and use an unused receipt path. Both flags require live mode and reject `--fixture`. You still press **Connect with 1Password** to connect.

## Recover a connection

If the app asks you to reconnect, use direct sign-in or **Connect with 1Password** again. Each successful connection creates a new local connection identity. Cached subscriptions from the previous connection cannot supply the new connection's balance.

The bundled `vikingbar` executable owns the refresh session in macOS Keychain under service `be.bram.vikingbar.oauth` and account `mobile-vikings`. The native app sends commands to that executable over private pipes. It never reads the token directly. Bootstrap and refresh use the same executable identity, and separate CLI processes share a lease around token rotation.

The CLI updates the whole Keychain record during rotation. A rebuilt development executable may require renewed Keychain authorization. VikingBar never grants all applications access to the token.

A pending rotation is recorded before the network exchange. If the process exits before it saves the replacement token, the next launch requires reconnect. The provider's token exchange and local Keychain update cannot form one atomic transaction.

Credential-read retries require explicit authorization. A successful connection, refresh, and relaunch sequence uses one credential read. Background refresh uses the stored refresh token. It never retrieves the password from 1Password. Authentication and approved data reads remain subject to the [request allowlist](live-proof.md#requests-and-auth-limits).

## Verify a live build

With the coordinator's credential and Mac UI slots, run `make proof-live CHECK=balance-ui`. Follow [the live proof guide](live-proof.md) and the project verification skill. The required gate drives a freshly built native app, compares API values with production output, presses native Refresh, and verifies recovery after relaunch. It must also rebuild in release configuration and relaunch with the stored token, without another 1Password read. See [recorded coverage and limits](live-proof.md#recorded-coverage). A missing credential, inaccessible Keychain item, failed request, or hidden status item fails the gate.

Private account values and screenshots stay in the local proof directory. Publish only the redacted pass/fail receipt and build identity. Synthetic tests and fixture screenshots do not complete this live gate.
