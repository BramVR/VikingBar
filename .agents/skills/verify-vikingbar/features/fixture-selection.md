# Fixture selection

## Sub-features

Finite, unlimited, exhausted, stale, and error states.

## How to get to it (user POV)

Open the fixture data card and select a state with its fixture picker.

## Driving it with Peekaboo

Launch the bundle with `--fixture finite`. Read `.build/inspect-ui <pid>`, press `vikingbar.fixturePicker` with its `press` argument, read the tree again, then press the state title. The smoke command drives all five states automatically. Capture each resulting card.

Require finite used and remaining amounts; unlimited usage without a percentage; exhausted zero remaining; stale balance with its old update date and warning; error with unavailable amounts rather than zero. Every state retains its fixture marker in the card and status item. Quit through the card and verify the process exits.

## Gotchas

Do not reuse old element IDs after selection. Selection changes in-memory synthetic data only. Fixture errors simulate unavailable data; they do not contact the provider.
