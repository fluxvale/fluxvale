# ADR-0044: Content home — `docs/public` + `docs/blog` source, synced priv copies, `/docs` SSR pages

**Status**: Accepted
**Date**: 2026-11-07

**Context**: the product ships with real behavior and no user-facing
docs. ADR-0017 settled where *engineering* docs live (`docs/`, this
tree) and ADR-00025 settled the blog's shape (markdown in the app's
priv, boot-compiled, SSR, frontmatter linted by a mix task). User
documentation needs the same discipline — authored as PRs, versioned,
previewed, CI-gated — and no page may ever leak the engineering tree
(ADRs, pricing notes, runbooks) onto the public site. Two content
lanes with one grammar (markdown + frontmatter, boot-compiled,
persistent_term reads) argue for one home and one pull mechanism
rather than two.

**Decision**:

1. **The content home is `docs/` at the repo root, with exactly two
   servable subtrees.**
   - `docs/public/` — the user-facing docs, one markdown file per
     page, organized one directory per section (`getting-started/`,
     `guides/`, `automation/`, `help/`), served at `/docs`.
   - `docs/blog/` — the blog's posts, moved verbatim (git mv, history
     preserved) from `apps/platform/priv/content/blog/` (ADR-00025
     §1's original location; URLs, slugs, frontmatter, and the feed
     are unchanged — ADR-00025's URL guarantees hold).
   **Hard boundary**: these two subtrees are the ONLY paths from
   `docs/` to the public site. The rest of the tree (ADRs, pricing
   calibration, runbooks, screenshots) has no route into the serving
   layer — structurally, not conventionally (see §6).
2. **A sync step copies both subtrees into the app's priv** —
   `scripts/sync-content.sh`, exposed as the `mix content.sync` alias:
   `docs/public/**` → `apps/platform/priv/content/docs/` and
   `docs/blog/**` → `apps/platform/priv/content/blog/`, wired
   everywhere the loaders' priv content must be fresh: the
   `test`/`coveralls.json`/`setup` alias chains, the CI release-image
   job and e2e bootstrap (both docker-build with
   `context=apps/platform`, so the gitignored priv copies are staged
   before the build), and the Tiltfile (`tilt up` runs the sync;
   live_update's priv sync carries later re-runs into the container).
   Both priv copies are gitignored — one source of truth per tree.
3. **The loaders keep reading priv; semantics unchanged.**
   `FluxVale.Blog` keeps its exact loader/lint/post shape (ADR-00025
   §1) reading `priv/content/blog`; the new `FluxVale.Docs` mirrors
   it (`Docs.Lint` validates, `Docs.Loader` lints + renders once
   through mdex and publishes to `:persistent_term` at boot, before
   the supervision tree starts — a bad page stops the boot, never
   serves half-parsed; `Docs.Page` is the compiled shape;
   `Docs.Sections` is the fixed section list shared by lint and web).
   Dev hot reload rides the blog's flag pattern
   (`:docs_hot_reload`). The shared markdown mechanics (frontmatter
   split, mdex render options) live in `FluxVale.Markdown` — two
   content lanes, one markdown grammar.
4. **Both lints target the SOURCE trees.** `mix blog.lint` and
   `mix docs.lint` default to `docs/blog/` and `docs/public/`
   respectively (resolved from the app dir), running side by side in
   `mix ci`. `docs.lint` enforces the docs' shape: every regular file
   under `docs/public` must be a `.md` page living directly inside a
   known section directory — no root-level files, no nested
   directories, no non-markdown, no unknown sections — plus the
   frontmatter rules (`title`, `description`, `order`, `slug`
   required; types checked; slug format and stem match; unknown-field
   rejection). The blog's rules are unchanged. The loaders re-check
   the priv copies at boot, so invalid content cannot deploy either.
5. **Docs routes**: `/docs` (index), `/docs/:section` (section page),
   `/docs/:section/:slug` (page) — plain controller + HEEx on the
   `:public_seo` pipeline like the blog (crawlers get the full
   document, zero JS), a sectioned sidebar on the section and page
   templates, the same design system, and a `Docs` link in the site
   footer. Blog routes, URLs, feed, and draft policy are untouched.
6. **Why the boundary holds**: the sync copies exactly the two
   subtrees; the loaders read exactly the two fixed priv paths; the
   lint rejects anything in `docs/public` that is not a conforming
   page (and `blog.lint` the blog tree). An internal doc reaches the
   public site only by being deliberately moved into one of the two
   servable subtrees under conforming frontmatter.

**Rejected alternatives**:

- **Authoring directly in the app's priv** (the blog's original
  shape) — splits content authorship away from `docs/`, and the
  convenience buys a worse failure mode: the same directory tree
  would hold user-facing pages one `mv` away from internal
  engineering docs. The `docs/` source + fixed sync keeps the
  boundary structural, not conventional, for BOTH lanes.
- **A static-site generator or docs framework (Docusaurus &co.)** — a
  second publishing pipeline, a Node toolchain the platform app
  deliberately lacks (AGENTS.md), and a second design system to keep
  in step. The blog already proved the in-app lane.
- **Serving `docs/` directly with an allowlist** — an allowlist is a
  policy that can be mis-edited; the copy is a structural guarantee.
- **Pointing the blog loader straight at `docs/blog`** (no sync) —
  the release image must carry content inside the OTP release
  (ADR-00025 §1: "posts are files inside the release"), the build
  context is `apps/platform`, and unifying on one pull channel keeps
  one wiring story for tests, Tilt, e2e, and the deploy image.

**Deliberate follow-ups** (not this ADR's scope): docs URLs in
`sitemap.xml` (evergreen pages have no honest `lastmod` — the sitemap
entry needs its own semantics), per-page OG images, and a possible
future migration of `/guides/sign-in-with-pocket-id` into
`docs/public` (cross-linked for now, never mirrored — ADR-0017's
rule).
