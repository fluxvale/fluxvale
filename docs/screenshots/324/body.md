The social-share card was still pre-Grove art — an orange flame mark on
a navy field, from a brand two identities ago. Every link shared in a
chat advertised work that isn't ours anymore.

The card now IS the product: a real render of the Offset-grammar
landing hero at exactly 1200x630 — First Light mark in the header,
the display headline, the live status panel (ghostboard / wiki /
forum with their badges), the deploy chip. Not a logo on a color field.

What changed:

- `apps/platform/priv/static/images/og-default.png` — new pixels, same
  path and format (`seo.ex` keeps `/images/og-default.png`; no code
  change, and the og:image URL assertion in the controller test holds
  untouched).
- `apps/e2e/og_screenshot.mjs` — the repeatable capture (a
  `landing_screenshot.mjs` sibling): 1200x630 viewport, dark + light,
  resting animation state, a 110px scroll so the full copy block and
  CTAs sit inside the OG frame, captured at 2x and downsampled to the
  exact og:image size. Dark ships (the brand's primary mode); light
  rides along as evidence both modes compose.

## Card size (1200x630)

Before — pre-Grove art, wrong brand:

![before, 1200x630](https://github.com/fluxvale/fluxvale/raw/refs/heads/chore/og-default-card/docs/screenshots/324/before-og-default.png)

After — the live landing hero, dark (shipped asset):

![after dark, 1200x630](https://github.com/fluxvale/fluxvale/raw/refs/heads/chore/og-default-card/docs/screenshots/324/after-og-default.png)

After — light variant (not shipped; og:image is one file):

![after light, 1200x630](https://github.com/fluxvale/fluxvale/raw/refs/heads/chore/og-default-card/docs/screenshots/324/after-og-default-light.png)

## Chat-preview thumbnail (~400px wide)

Before:

![before, 400px](https://github.com/fluxvale/fluxvale/raw/refs/heads/chore/og-default-card/docs/screenshots/324/thumbnail-before.png)

After, dark (shipped):

![after dark, 400px](https://github.com/fluxvale/fluxvale/raw/refs/heads/chore/og-default-card/docs/screenshots/324/thumbnail-after.png)

After, light:

![after light, 400px](https://github.com/fluxvale/fluxvale/raw/refs/heads/chore/og-default-card/docs/screenshots/324/thumbnail-after-light.png)

At thumbnail size the headline stays legible and the status panel's
badges still carry — the card reads as a product, not a sticker.
