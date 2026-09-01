# ADR-00025: SEO & content architecture — in-app blog, catalog as programmatic SEO

**Status**: Accepted
**Date**: 2026-09-01

**Context**: SEO compounds over 6–18 months, so starting at launch is
correct *because* it is slow. FluxVale's customers search exactly the
long-tail a self-hosting blog wins ("self-host Kavita", "ebook server
setup"), and the catalog itself is a page-per-app SEO surface. Key
structural rule: content lives under **subdirectories** of the canonical
domain (`fluxvale.com/blog`, `fluxvale.com/apps/<slug>`), never subdomains —
subdomains split domain authority.

**Decision**:

1. **The blog lives inside the Phoenix app** at `/blog` — markdown files in
   the repo (`apps/platform/priv/content/blog/`), rendered by plain
   **Phoenix controllers + HEEx (not LiveView)** for crawl speed and zero-JS
   readability. Posts are code: written as PRs (agent-assistable),
   versioned, and **previewed as drafts on review environments**
   ([ADR-0024](00024-e2e-review-environments.md) synergy: every post PR gets
   a live rendered preview). Rendering: `mdex` (CommonMark + server-side
   tree-sitter syntax highlighting — no client JS), Tailwind typography
   styles. Posts load at boot into `:persistent_term`; a deploy publishes.
2. **The catalog is a programmatic SEO engine**: one public SSR page per app
   (`/apps/<slug>`) with description/screenshots/install CTA and
   `SoftwareApplication` JSON-LD. **The first five posts are the launch
   guides for the first five catalog apps** (OQ #3) — content that doubles
   as onboarding docs and catalog enrichment.
3. **Technical hygiene, day one**: `sitemap.xml` (static + catalog + posts),
   `robots.txt`, canonical URLs always pointing at the prod host, OG/Twitter
   meta + `Article` JSON-LD on posts, RSS feed (`/feed.xml` — the
   self-hosting crowd still lives on RSS), one default OG image (per-app
   images from catalog assets later), `www`/apex pick-one redirect.
4. **Non-prod hosts are `noindex`**: a plug injects
   `<meta name="robots" content="noindex,nofollow">` + `X-Robots-Tag` header
   whenever the host isn't the canonical prod domain — covering
   `staging.*`, `pr-*.review.*` (which duplicate the whole site per PR!),
   and local dev hosts. Canonicals to prod regardless of serving host.
5. **Discovery tooling day one**: Google Search Console + Bing Webmaster
   (DNS TXT verification); analytics via **Cloudflare Web Analytics** (free,
   privacy-friendly, fits the vendor consolidation of
   [ADR-00012](00012-observability-grafana-cloud.md)).
6. **What we don't do**: keyword-tool subscriptions, link schemes, AI
   mass-content, client-side SEO hacks. One good guide per catalog app,
   honest build-in-public engineering posts (the Talos/Flux story earns
   backlinks), then cadence.

**Content model**: markdown + frontmatter (`title`, `description`,
`published_at` or filename-dated `YYYY-MM-DD-slug.md`, `tags`, `draft`,
`og_image`); drafts render only on non-prod hosts. Reading time computed at
load. A mix task validates frontmatter so agent-authored posts fail CI
loudly on missing fields.
