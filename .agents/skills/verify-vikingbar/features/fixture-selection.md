# Fixture selection

## Sub-features

Finite, unlimited, exhausted, stale, error, and **Not connected** selection.

## How to get to it (user POV)

Open the data card and choose an option with **Fixture state**. **Not connected** shows setup information without synthetic balances. Launching without `--fixture` starts in that same state.

## Driving it with native AX and Peekaboo

Launch the bundle with `--fixture finite`. Read `.build/inspect-ui <pid>`, run `.build/inspect-ui <pid> press vikingbar.fixturePicker`, read the tree again, then press the state title. The smoke command drives all five fixtures automatically. Capture each resulting card.

Require finite used and remaining amounts; unlimited usage without a percentage; exhausted zero remaining; stale balance with its old update date and warning; error with unavailable amounts rather than zero. Every fixture retains its marker in the card and status item.

To leave fixture mode, run `.build/inspect-ui <pid> press vikingbar.fixturePicker`. Read the open menu, then run `.build/inspect-ui <pid> press 'Not connected'`. Read the card again and require:

- **No account connected**, **Unavailable**, and **Not connected**.
- No `vikingbar.fixtureMarker` element and no fabricated allowance.
- Status title `VikingBar ?` and accessibility description `VikingBar ?, Unavailable, Not connected`.

Capture the card through its exact window ID with Peekaboo. Finish with the [Quit recipe](data-card.md). Smoke cleanup alone does not cover **Not connected** or the Quit button.

## Gotchas

Selection changes in-memory example state only. Fixture errors simulate unavailable data; they do not contact the provider. **Not connected** is not a live account mode. Re-observe between opening a picker and selecting an option.
