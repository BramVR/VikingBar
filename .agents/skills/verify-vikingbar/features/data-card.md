# Data card

## Sub-features

Status meter, used percentage, used and remaining amounts, expiry, last update, and Quit.

## How to get to it (user POV)

Start the fixture app. Click its **Fixture** status item.

## Driving it with Peekaboo

Run `make smoke-app-fixture`. Inspect `before.png`, `click.json`, and `card.png` in the printed proof directory. Require a visible fixture marker, finite percentage, decimal GB amounts, expiry, and last update. The bundle must have no Dock icon. For keyboard coverage, use a fresh snapshot to target the fixture picker and Quit button.

## Gotchas

An AX item outside the display is not clickable proof. Missing card content fails the smoke command. A no-argument launch shows setup information instead of fixture balances.
