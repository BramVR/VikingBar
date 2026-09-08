# Website reference observations

Inspected 8 September 2026. Local screenshots are in `../output/references/`.

## Astra flow

[Reference page](https://openai.com/index/gpt-6-astra/). Observed sequential opening scrolls, an interactive tab change, the next visual chapter, and the availability anchor. This was a flow study, not a full audit of every chart, embedded video, or footer link.

1. Opening fills the viewport with an interactive object and minimal title. Persistent navigation stays available. Evidence: `astra-flow-01.png`.
2. Scrolling reduces the object's visual dominance and introduces a short statement. Evidence: `astra-flow-02.png`.
3. A video stage precedes a narrow reading column. Text is given room before controls appear. Evidence: `astra-flow-03.png` captures the reading stage.
4. Tabbed evidence switches in place. Selecting ARC-AGI-3 visibly replaces the chart rather than navigating elsewhere. Evidence: `astra-flow-04.png`.
5. Another large interactive object separates chapters, followed by a heading, explanation, and more switchable evidence. Evidence: `astra-flow-06.png` shows that next reading section.
6. Availability is grouped near the end; the header remains reachable. Detailed evidence continues below it.

Apply the pacing to VikingBar: icon sculpture, short benefit, native menu demo, SIM/preferences interaction, development-build action. Keep manual scrolling and reduced-motion support. Do not adopt the starfield, scientific claims, long article copy, or brand marks.

## Mobile Vikings theme

[Reference page](https://mobilevikings.be/nl/). Evidence: `mobile-vikings-01.png` and `mobile-vikings-02.png`, captured after dismissing optional cookies.

- Black base, condensed uppercase headlines, red/ivory emphasis, red buttons with offset outlines, and contrasting white sections.
- Browser-computed heading/button font is MrAlex. This project retains its self-hosted Barlow Condensed rather than adding an unlicensed font.
- Browser-computed primary button red is RGB 205, 4, 0, adopted as `--red`.
- Use this visual language while keeping VikingBar's own identity and independent-project wording. Generated concepts containing the provider's logo must replace it with VikingBar before implementation.

## Native card

[Issue #22](https://github.com/BramVR/VikingBar/issues/22), approved mock saved as `issue-22-card.png`. Preserve its order, data hierarchy, native typography, hairlines, and restrained cyan accent. Purple is the wallpaper behind native material, not a fixed card fill. The website uses the dark appearance against its black background. The issue explicitly removes the duplicate top settings gear.

## Further image concepts

Built-in ImageGen generated three independent website directions in display order: `vikingbar-flow-01.png`, `vikingbar-flow-02.png`, `vikingbar-flow-03.png`. Exact prompts accompany them. Each call received the actual icon, approved card, user screenshot, Mobile Vikings capture, and Astra transition capture.

These are page-flow explorations. Generated placeholder copy, fabricated source paths, extra navigation, and provider logos are not implementation authority. Preserve verified repository references, available functionality, and independent branding when building a selected direction.
