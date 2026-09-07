# Fixture selection

## Sub-features

Finite, unlimited, exhausted, stale, error, and **Not connected**.

## How to get to it

In an explicit fixture launch, open the helmet's **Data** tab and choose **Fixture state**. **Not connected** shows setup information without synthetic balances. Launching without `--fixture` restores a stored live session and can access Keychain and the provider; it has no fixture picker.

## Native proof

`make smoke-app-fixture` covers all five fixtures and Not connected in both icon-only and optional amount modes. It preserves status crops and card captures for each selection.

For a targeted selection, press `vikingbar.fixturePicker`, re-read the tree until the desired `AXMenuItem` appears, then press its title. Require the selected card state and updated status tooltip/accessibility label before capturing.

- Finite has used and remaining amounts and a partial inset bar.
- Unlimited has usage without a fabricated percentage and an internal infinity mark.
- Exhausted has zero remaining and an empty inset.
- Stale retains its known fill and displays its old update date and warning.
- Error shows unavailable amounts and an internal question mark.

Every fixture retains visible provenance in the card and Settings and explicit provenance in status tooltip, accessibility label, and CLI. Default status title is empty. Optional amount titles are `36 GB`, `Unlimited`, `0 GB`, `36 GB`, and `Unavailable` for those five states.

For **Not connected**, require **No account connected**, **Unavailable**, and **Not connected**, with no `vikingbar.fixtureMarker` or fabricated allowance. The status title is empty when amount mode is off and `Unavailable` when on. Tooltip and accessibility description contain `Not connected` and `No successful update` without `FIXTURE`. Capture the card through the settled popover window ID and finish with the real [Quit action](data-card.md).

## Gotchas

Fixture selection changes in-memory synthetic data only. It does not contact the provider. The display preference has separate [isolated persistence rules](helmet-and-display-setting.md). Choosing **Not connected** in the fixture picker preserves fixture isolation.
