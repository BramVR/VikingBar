---
summary: "Install, update, configure, and remove a local VikingBar build."
read_when:
  - Installing or updating VikingBar locally
  - Changing preferences, wake refresh, or launch at login
  - Running installed-app proof
---

# Install a local build

Use a trusted checkout on an Apple Silicon Mac running macOS 14 or later. Run the [development checks](development.md) first.

Choose the exact app destination:

```sh
make install-app INSTALL_TARGET="$HOME/Applications/VikingBar.app"
```

The installer builds a fresh bundle, checks its identity and version metadata, and seals it with a local ad-hoc signature. It refuses an existing destination unless you explicitly request replacement. It does not start the account session.

Ad-hoc sealing uses no certificate or private key. It permits local signature validation and supplies the signed bundle required by ServiceManagement. It does not provide Developer ID trust or notarization. Actual launch-at-login registration still needs verification on the target Mac.

Open the installed app:

```sh
open "$HOME/Applications/VikingBar.app"
```

The app runs in the menu bar without a Dock icon. Open the helmet to see the data card. A normal launch restores the stored account and refreshes it. Follow [account setup](live-account.md) if no account is connected.

The bundled CLI owns the existing Keychain item. A newly built executable may prompt for renewed Keychain access. Authorize the exact installed executable when appropriate. Do not broaden the item's access list or substitute a password exchange to hide a failed stored-session test.

## Update the installed build

Quit VikingBar and finish any standalone VikingBar CLI command before updating. Run the checks in the new checkout, then explicitly replace the same destination:

```sh
make install-app INSTALL_TARGET="$HOME/Applications/VikingBar.app" REPLACE=1
```

The installer refuses unrelated bundles and running destination executables. It retains the previous bundle as a backup and reports the backup path. Open the new bundle and check the data card. Keep the backup until the new build works. Preferences and the account namespace do not change with the install path.

An update reports `existing-target-process-origin-unresolved` if macOS cannot identify a live process's executable, including an unrelated executable deleted while still running. The installer cannot establish that process's original bundle and refuses the update. A fresh absent destination does not need this process check: publication is exclusive and refuses any destination that appears during the build, even with `REPLACE=1`.

The adjacent `.VikingBar.app.install.json` records the installed manifest and executable hashes. Retain it with the bundle for installed proof. Backups and installation receipts remain private in the selected destination directory.

## Choose the display and refresh interval

Open **Settings** and choose **Remaining** or **Used** for the data card. Unlimited allowances show their known used amount without a fabricated percentage. The helmet continues to represent remaining allowance. **Show remaining GB in menu bar** independently controls the optional decimal GB label.

Choose a refresh interval of five minutes, fifteen minutes, thirty minutes, or one hour. The app saves these choices in `~/Library/Application Support/VikingBar/menu-bar-preferences.json`. Settings failures remain visible. Fixture launches use memory or an explicitly supplied isolated settings file.

Choose a SIM in the data card. Its selection persists with the cached balance and connection identity. A different account cannot reuse the previous account's selected SIM or allowance.

Startup restores the last successful balance and its timestamp before refreshing. Wake uses the existing refresh scheduler. An active refresh finishes before another begins. Failed requests preserve known data and use the retry backoff. Changing the regular interval does not bypass that backoff.

## Start VikingBar at login

Open **Settings** and turn on **Launch at login**. Read the status beneath the control. **On** means macOS reports the app eligible to launch. **Approval required** means you must allow it in System Settings. **Unavailable** or an operation error leaves the limitation visible.

Use the Login Items settings action when approval is required. The app rereads the system state when you return. It does not store a separate enabled preference that could disagree with macOS.

To stop automatic launch, turn the control off and confirm **Off**. A successful registration and manual relaunch do not prove that macOS has executed the app at a later login.

## Log out of the account

Quit VikingBar and finish any standalone VikingBar CLI command. Open **Keychain Access**, locate the generic password with service `be.bram.vikingbar.oauth` and account `mobile-vikings`, and delete only that item. Remove `~/Library/Application Support/VikingBar/balance-v1.json` if you also want to erase the saved account display data.

The next normal launch shows account setup. This removes the local connection. It does not change your Mobile Vikings account or revoke sessions on other devices. Display preferences and launch-at-login registration remain separate.

## Uninstall

1. Turn off **Launch at login** and confirm **Off**.
2. Quit VikingBar and finish any standalone VikingBar CLI command.
3. Move the installed `VikingBar.app` to the Trash.
4. Move its adjacent `.VikingBar.app.install.json` receipt to the Trash too. A receipt without its app blocks a later installation at that destination.
5. Follow the logout steps to remove the local account connection.
6. To remove saved preferences too, move `~/Library/Application Support/VikingBar` to the Trash after confirming no VikingBar process is using it.

If the UI cannot open, use the installed app's maintenance command before moving its bundle:

```sh
"$HOME/Applications/VikingBar.app/Contents/MacOS/VikingBarApp" --login-item disable
"$HOME/Applications/VikingBar.app/Contents/MacOS/VikingBarApp" --login-item status
```

Require `status` to report `notRegistered`. These commands operate on login registration without starting the account session. A failed unregister leaves removal incomplete. Keep the bundle available until registration is resolved.

## Verify the installed artifact

Read [installed-app verification](../.agents/skills/verify-vikingbar/features/installed-app.md). The required commands are `make smoke-installed-app` and `make proof-live CHECK=installed-balance`. Both require an explicit reviewed `INSTALL_TARGET` and the coordinator's runtime slots.

The smoke installs a fresh production-identity bundle at an unused task-owned path. It changes only an isolated settings file, requires login registration to start at `notRegistered`, and restores that state automatically. It retains the installed bundle and private evidence after stopping its own processes. It must not replace a user's bundle or alter an existing login registration.

The live gate uses the installed bundle and its bundled CLI with the existing stored session. It compares API, snapshot, and visible card values, refreshes, and verifies relaunch. Missing Keychain access, native visibility, account data, or successful restoration fails the gate. Fixture proof alone does not complete installed live-balance verification.

These gates do not trigger an OS logout or login. While the production login item is registered, macOS can launch the normal live app at a subsequent login. That is why the registration smoke requires the account slot as well as the UI slot.
