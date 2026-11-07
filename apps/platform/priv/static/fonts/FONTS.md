# Vendored fonts (#557)

All families self-hosted as woff2 in this directory. No external font
services, no CDN requests at runtime. Licenses below. Each permits
webfont self-hosting for the licensee's own sites and applications.

## Switzer - `switzer-latin-wght-normal.woff2`

- Variable sans (wght 100-900), the interface voice everywhere.
- Source: [Fontshare](https://www.fontshare.com/fonts/switzer)
  (Indian Type Foundry), downloaded directly from Fontshare.
- License: **ITF Free Font License (FFL)**, free for personal and
  commercial use. The FFL explicitly permits self-hosting "for use on
  your own websites and applications, including through standard
  webfont technologies such as CSS @font-face" and calls it
  "permitted and recommended". Files are vendored **unmodified**
  (no subsetting, no recompilation, both prohibited).
- **Known tension**: this repository is public, and the FFL prohibits
  distributing the font through repositories or publicly accessible
  servers. A public source repo carrying the binary sits in that gray
  zone: cloning the repo delivers the file, though the sanctioned
  channel is a direct Fontshare download per recipient. The FFL's
  self-hosting grant covers the font's real use here: served to this
  application's own visitors. Resolution options (ITF written consent
  for repo hosting, fetching at build time, or an OFL sans) are
  maintainer calls.
- License text: <https://www.fontshare.com/licenses/itf-ffl>

## Instrument Serif - `instrument-serif-latin-400-normal.woff2`

- Static regular (the face's only weight), the display voice for
  marketing headings.
- Source: Google Fonts.
- License: **SIL Open Font License 1.1**. Self-hosting and web
  embedding permitted. Redistribution allowed with the license
  (bundled here, per OFL requirements).

## JetBrains Mono - `jetbrains-mono-latin-wght-normal.woff2`

- Variable mono (wght 100-800), the code/identifier/price/digest voice.
- Source: Google Fonts.
- License: **SIL Open Font License 1.1**. Self-hosting and web
  embedding permitted. Redistribution allowed with the license
  (bundled here, per OFL requirements).
