The catalog icons — each app directory's `icon.png` / `icon.svg` — are
the upstream projects' own brand marks, vendored so the public catalog
loads every icon same-origin (#716: a hotlinked icon whose host hangs
holds the page's load event hostage). Bytes are verbatim from the
provenance URL recorded beside each `icon_url` in
`apps/platform/priv/repo/seeds/catalog_data.yaml`, minus the DOCTYPE
line naming an external DTD in kavita's and pocket-id's SVGs (dead
weight in a vendored icon). The marks identify the catalogued apps and
are not covered by the repository's FSL license. Screenshots in these
directories are our own captures of FluxVale-deployed instances (the
#611 plan's D2), not upstream assets.
