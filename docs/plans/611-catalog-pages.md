# Plan: catalog app pages at PikaPods depth (#611)

Status: **APPROVED — Terence, Nov 8 2026.** All D1-D12 settled as
recommended; §11 records the ruling. Slices fan out per §10, S1 first.

Evidence base: the four reference screenshots of
[pikapods.com/apps/docmost](https://pikapods.com/apps/docmost)
(captured 2026-11-08, read in full), the shipped catalog code, the seed
data for all six apps, and the ADRs cited inline.

## 1. The design in one paragraph

Turn the public app page (`/catalog/:slug`, SSR, the programmatic-SEO
surface of [ADR-00025](../adr/00025-seo-content-architecture.md)) into
the full PikaPods shape: a hero with honest prose beside a
transactional deploy card, real-UI screenshots, a feature grid, a
platform benefits grid, a two-column FAQ with one answer open, similar
apps, and a closing CTA. The split is **generated with curated
overrides**: everything the platform already knows (price, size,
version, region, backups, SSO support, file access, first-run posture,
category peers) renders from metadata, and only app-specific truth the
metadata cannot derive (caveats, alternatives, screenshots, feature
cards, app FAQ) is authored. Every generated section always renders, so
no app page is ever empty. Curated sections appear when authored and
disappear without a layout hole when not.

## 2. What the reference actually does

| # | Section | Reference content | The job it does |
|---|---|---|---|
| 1 | Hero | Icon, "Docmost Hosting", one-line lead, three paragraphs: what it is, use cases plus caveats, "an alternative to X" | Answers "what is this, is it for me, what is wrong with it" before any button |
| 1a | Pricing card | "From $2.80/month", minimum specs, four checkmarks, deploy CTA, billing fine print | The transaction, visible in the first screen |
| 1b | Stats card | Version, last updated, GitHub stars, contributors | Currency and trust signals |
| 1c | Link row | Source, documentation, community, FAQ | The reader's exits |
| 2 | In action | Two real-UI screenshots with captions | Proof, not claims |
| 3 | Feature grid | 2x2 capability cards with icons | The app's own value |
| 4 | Benefits | 2-column checklist of platform promises | Why host it here |
| 5 | FAQ | Two columns ("Setting up", "About X and the platform"), one answer open (data ownership) | Removes objections |
| 6 | Similar apps | 2x2 cross-links with name, blurb, price | Keeps the reader in the catalog |
| 7 | CTA | "Ready to deploy X?" plus one button | The second chance to convert |

Notes that matter for our adaptation:

- The honesty is load-bearing. The reference names caveats in the hero
  (licensing, email setup, enterprise features) and answers data
  ownership plainly. Copy that only sells reads as generic.
- "From" pricing is a **minimum allocation** claim. Our stepper starts
  at the version's recommended size and users can move it. We say
  "Starts at" and show the recommended size, which is true at the
  deploy step's first paint.
- The stats card is vanity metrics. We have facts worth more to a
  buyer: region, backups, SSO, file access, wake time.

## 3. Section to field map

Legend: **E** existing field, **N** new field (this plan), **G**
generated from metadata, **C** platform constant.

| Reference section | Rendered content | Source | Kind | When absent |
|---|---|---|---|---|
| Breadcrumb, icon, name | `App.name`, `icon_url`, `category.name` | E | E | icon falls back to initial (existing idiom) |
| Hero title | "{name} hosting" | name | G | never absent |
| Hero lead | "Managed {name}, ready in minutes." | name | G | never absent |
| Hero paragraph 1 | What the app is | `App.description` | E | page still renders; lint flags |
| Hero paragraph 2 | Who it suits | `Category.audience` | **N** | paragraph omitted |
| Hero caveats | "Worth knowing" block | `App.caveats` | **N** | block omitted |
| Hero positioning | "An alternative to X and Y." | `App.alternatives` | **N** | line omitted |
| Link row | Source, Docs, Community, FAQ anchor | `source_url`, `docs_url` (E), `community_url` (**N**), `#faq` | E/N/G | individual links omitted |
| Pricing card rate | "Starts at {recommended monthly}/mo" + "billed hourly" | `Pricing.version_rates/1` on newest version | E/G | card's rate hidden on a sizeless version |
| Pricing card specs | CPU, RAM, storage at the recommendation | `AppVersion` defaults | E | never absent |
| Pricing card checklist | Welcome credit, HTTPS, sleep/wake, backups, (SSO), (file access) | `FluxVale.Accounts.welcome_grant_cents/0`, platform truths, `oidc_callback_path`, `file_access` | C/E | rows drop out individually |
| Pricing card fine print | Monthly equivalent, storage while stopped, VAT on top-ups | C | C | never absent |
| Facts card | Version, updated, wake estimate, region, backups, SSO, file access | newest version + `published_at`, `WakeStats`, C, `oidc_callback_path`, `file_access` | E/G/C | rows drop out individually |
| In action heading + intro | "{name} in action" + one line | name + `App.in_action_intro` | G/**N** | section omitted |
| In action images | Real-UI screenshots with captions | `App.screenshots` | **N** | section omitted |
| Feature grid | 2x2 app capability cards | `App.features` | **N** | section omitted |
| Benefits grid | Seven platform promises plus up to two app-conditional rows | C + `oidc_callback_path` + `file_access` | C/E | never absent |
| FAQ, setup column | Setup, cost, sleep, backups, add-ons | `first_run.guidance`, pricing, C, OIDC, file access | E/G/C | items drop out individually |
| FAQ, about column | Data ownership (open), export, region, what it replaces, app questions | C, `alternatives`, `App.faq` | C/N | platform items always present |
| Similar apps | Same-category peers, max 4 | `Category.apps` | G | "Browse the catalog" card when fewer than 2 peers |
| Closing CTA | "Ready to run {name}?" + button | name + welcome credit | G | never absent |
| Structured data | `SoftwareApplication` plus `FAQPage` | everything above | G | never absent |

**Reads stay public.** All new fields are public-readable on a public
marketing surface (the `App` read policy is already `always()`), and
none of them may carry secrets. The existing JSON:API `default_fields`
lists stay unchanged in v1 so no new field leaks onto the API by
accident. Widening them is a separate decision.

## 4. Metadata model

All new **App** fields are nullable or defaulted to `[]`. Old rows and
fixture YAML keep working; seed convergence adds content where it
exists.

### 4.1 New App fields

| Field | Type | Shape and limits | Why a field |
|---|---|---|---|
| `caveats` | array of strings | 1-6 items, each 20-280 chars | Honest limits are app truth, not derivable. The reference puts them in the hero. |
| `alternatives` | array of strings | 1-5 names, each 1-60 chars | The "alternative to X" line, plus the FAQ answer and search intent. |
| `in_action_intro` | string | max 160 chars | One line under the screenshots heading. Optional. |
| `screenshots` | array of maps | 1-4 items: `src`, `alt`, `caption` (optional); `src` must start `/images/catalog/` and end `.png` or `.webp`; `alt` 10-140 chars required | The proof section. Generate by rendering the app, not by inventing. |
| `features` | array of maps | 1-4 items: `icon` (allowlist), `title` 3-60, `body` 20-220 | The app's own capabilities. The 2x2 shape caps it at 4. |
| `faq` | array of maps | 0-4 items: `question` 8-120 ending "?", `answer` 20-600 | App-specific objections (SSH support, licensing, multi-user). |
| `community_url` | string | https URL | Community link row entry. |

### 4.2 New Category field

| Field | Type | Shape | Why |
|---|---|---|---|
| `audience` | string | one sentence, max 180 chars | Answers "who is this for" for every app in the category with one authored sentence per category instead of one per app. |

### 4.3 Validation

Follow the house pattern for structured catalog data
(`Types.FirstRunContract`, `Types.OidcWiring`): cast and validate in
the type, one enforcement point for seeds, admin, and the API.

- Three new types: `Types.ScreenshotList`, `Types.FeatureList`,
  `Types.FaqList`. Plain strings use `{:array, :string}` with item
  constraints.
- Reject unknown keys in each map (the `KnownFields` precedent).
- Icon allowlist lives in `Types.FeatureList` and is reused by the
  renderer, so a bad icon fails the seed, not the page.
- Copy lint in the types: reject em dashes and semicolons (D10).
- A CI test asserts every `screenshots.src` in the seed YAML exists in
  `priv/static` (file existence at seed time would couple writes to
  assets that may not be staged in tests).
- `mix catalog.lint` (new) reports curation completeness per app. It
  does not fail CI in v1 (D1); malformed content always fails.

### 4.4 Seed loader

`Seeds.CatalogData` gains raw pass-through for the six App fields and
`Category.audience`. Normalization stays out of the loader for
structured fields, exactly like `first_run` and `oidc_wiring`: the
types validate at write time.

## 5. Curation rules

The rule that keeps six apps and the next sixty maintainable:

1. **If the platform can derive it, nobody authors it.** Price, size,
   version, updated date, region, backups, sleep, SSO support, file
   access, first-run posture, category peers, welcome credit, VAT
   note.
2. **If it is app-specific and not derivable, it is a curated field.**
   Caveats, alternatives, screenshots, feature cards, app FAQ,
   community link. Never freeform HTML or markdown blobs.
3. **Platform promises live in one constants module.** The benefits
   grid, the data-ownership answer, billing fine print, the export
   answer, and the region answer are shared by every app page. One
   edit changes every page.
4. **Curated values override the generated slot, never the section.**
   A curated FAQ answer can replace a generated one for the same
   question. A curated section never replaces the generated benefits
   or CTA.
5. **Omission is a designed state.** A missing curated section renders
   nothing and leaves no gap. A missing generated fact drops one row.
   No placeholder text, no fake content.

What a new catalog entry must author, by tier:

| Tier | Fields | Page result |
|---|---|---|
| Minimum (today's contract) | name, tagline, description, icon, source, docs, versions | Complete page: hero, pricing, facts, benefits, FAQ, similar apps, CTA. Lint reports what is missing. |
| Recommended | plus `caveats`, `alternatives` | Honest hero and a real "what it replaces" answer. |
| Full parity | plus `screenshots`, `features`, `faq`, `in_action_intro`, `community_url` | The PikaPods shape end to end. |

## 6. The template

### 6.1 Where it lives

- Surface: `FluxValeWeb.CatalogController.show/2` and
  `catalog_html/show.html.heex`. SSR, no JavaScript, same public chrome
  and canonical URL as today. The page is a marketing surface: **no
  `appgram` console grammar**, no tables, no mono panels.
- New scope: `.catalog-page` plus `assets/css/catalog.css` for the
  display type block only. This mirrors the per-lane pattern already
  shipped in `blog.css` and `docs.css` (eyebrow plus `.display-h2`,
  scoped to the lane).
- New component module `FluxValeWeb.CatalogPageComponents`
  (`use FluxValeWeb, :html`) holds the sections, the constants module
  holds the copy. Controller HTML keeps only the page composition, so
  the authenticated page can reuse the same components in S6.
- Measure: the public layout's existing 64rem column. No new layout
  grammar, no full-bleed bands. Sections separate with hairline
  seams (`border-t border-line`) and generous spacing, per the
  border-first depth rule of #277.

### 6.2 Type and rhythm

The three voices of #557 (shipped in #563):

- **Hero title**: Instrument Serif via `.catalog-page .display`,
  `clamp(40px, 6vw, 64px)`, one line where possible. "Forgejo hosting"
  reads as a marketing headline, not an app title.
- **Section headings**: Instrument Serif via `.display-h2`,
  `clamp(30px, 4vw, 44px)`, preceded by a mono uppercase eyebrow with
  the amber dash (the blog and docs idiom).
- **Everything else**: Switzer. **Numbers, versions, prices**: JetBrains
  Mono. Prices use `Pricing.format_monthly_rate/1` where the hourly
  qualifier belongs, and a mono figure inside the card where the
  qualifier is on its own line.

Spacing: hero `pt-6 pb-12`, sections `py-14 sm:py-16`, card padding
`p-6`, grid gaps `gap-4` (cards) and `gap-10` (columns). Nothing
tighter than today's catalog.

### 6.3 Wireframe

```
[<- Catalog]                                        (64rem column)
CATEGORY EYEBROW
Forgejo hosting                                     +----------------------+
Managed Forgejo, ready in minutes.                  | Starts at            |
                                                    | $3.35/mo             |
<description, 2 short paragraphs>                   | billed hourly        |
                                                    | 0.5 CPU 512 MB 10 GB |
[Worth knowing]                                     | ✓ $3 welcome credit  |
- HTTPS only, SSH is disabled                       | ✓ Free HTTPS         |
- SQLite on a single volume                         | ✓ Sleeps when idle   |
                                                    | ✓ Backups, your bucket|
An alternative to GitHub and GitLab.                | [ Deploy Forgejo ]   |
                                                    | fine print           |
Source · Docs · Community · FAQ                     +----------------------+
                                                    | Version      16.0.5  |
                                                    | Updated      3d ago  |
                                                    | Wakes in     ~4s     |
                                                    | Region       Nuremberg|
                                                    | Backups      Your S3 |
                                                    | SSO          Pocket ID|
                                                    +----------------------+
────────────────────────────────────────────────────────────────────────────
IN ACTION
Forgejo in action
<lead line>
[ screenshot 1 ]            [ screenshot 2 ]
caption                     caption
────────────────────────────────────────────────────────────────────────────
FEATURES
What you can do with Forgejo
[icon] Repositories      [icon] Pull requests
[icon] Actions CI        [icon] Issue tracking
────────────────────────────────────────────────────────────────────────────
WHY FLUXVALE
Benefits of hosting Forgejo on FluxVale
✓ Predictable pricing     ✓ Sleep by default
✓ Your data stays yours   ✓ Backups to your bucket
✓ Free HTTPS, your domain ✓ Pinned, tested versions
✓ One region, honestly    ✓ SSO with Pocket ID
How FluxVale works ->
────────────────────────────────────────────────────────────────────────────
FAQ
Setting up Forgejo                  About Forgejo and FluxVale
[details rows]                      [details rows, data ownership open]
────────────────────────────────────────────────────────────────────────────
SIMILAR APPS
Similar apps on FluxVale
[card] [card]
────────────────────────────────────────────────────────────────────────────
Ready to run Forgejo?
New accounts start with $3 in welcome credit.
[ Deploy Forgejo ]
```

### 6.4 Section specs

**Hero.** `grid gap-10 lg:grid-cols-[minmax(0,1fr)_22rem]`. Left column
is prose at `max-w-prose`; the description keeps today's
`whitespace-pre-line` rendering so authored paragraph breaks survive.
Right column is the two cards, `lg:sticky lg:top-20`. On mobile the
cards stack after the prose. The caveats block is a bordered panel with
a mono eyebrow, not a warning callout: these are facts, not errors. The
link row uses the icon plus text pattern from the reference, with
`hero-arrow-top-right-on-square`, `hero-book-open`,
`hero-chat-bubble-left-right`, `hero-question-mark-circle`.

**Pricing card.** Rate in mono, `text-3xl`. The spec line is one mono
row (`0.5 CPU`, `512 MB`, `10 GB`). Checklist rows use
`hero-check` in `text-success`. The CTA is full width and lands on the
existing auth-gated deploy route, so anonymous clicks hit sign-in with
the return path and signed-in clicks open the stepper. The CTA hides
when the app has no versions, matching the authenticated page's rule.
Fine print at `text-xs text-ink-subtle`.

**Facts card.** A `<dl>` of icon plus label plus mono value. Rows:
Version, Updated (relative, full date in `title`), Wakes in (only when
`WakeStats.median_total_by_app/0` has a value, read through the same
safe wrapper the catalog index uses), Region (Nuremberg, EU), Backups
(Your S3 bucket), SSO (Pocket ID when the version declares
`oidc_callback_path` or `oidc_wiring`), File access (WebDAV when
`file_access`). No GitHub stats (D7).

**In action.** Heading, optional intro, then a 2-column grid of
screenshots in `rounded-panel border border-line-strong` frames with
`loading="lazy"`, fixed aspect ratio (16:10), explicit width and
height, and a `text-sm text-ink-muted` caption underneath. One
screenshot still renders as a single wide frame; three or four wrap
2x2.

**Feature grid.** 2x2 at `sm`, one column below. Icon in the
`primary-muted` tile (the catalog card idiom), title in Switzer
semibold, body muted. No hover lift: these cards are not links.

**Benefits.** 2-column checklist, `gap-x-10 gap-y-6`. App-conditional
rows: SSO only when the app supports OIDC, file access only when
`file_access` is true. Everything else is a platform constant. Trailing
link to `/docs/getting-started/first-app`.

**FAQ.** Two columns at `lg`, stacked below. Each column is one
bordered panel with `divide-y divide-line`. Rows are native
`<details>`/`<summary>`: zero JavaScript, keyboard native, crawlable
when closed (the answer stays in the DOM). Chevron rotates with
`[open]`. One row carries `open` (D11). Column headers are mono
eyebrows.

**Similar apps.** Same category, excluding self, max 4, name order.
Cards mirror the catalog index: icon tile, name, two-line tagline,
price footer ("From $2.59/mo plus storage", computed once like the
index). Fewer than two peers: one "Browse the catalog" card, no
invented similarity. Today's seed has one app per category, so most
pages show the browse card until the catalog grows. That is the honest
result, not a bug.

**Closing CTA.** Centered, `display-h2`, welcome credit line from
`FluxVale.Accounts.welcome_grant_cents/0`, one primary deploy button
and one ghost catalog link.

### 6.5 Responsive, motion, accessibility

- Breakpoints: one column below `sm`, 2x2 grids at `sm`, hero two
  columns at `lg`, FAQ two columns at `lg`.
- Motion: hover shadow and 1px lift on linked cards only, token
  durations, `motion-safe`. Details chevron rotation. No scroll
  reveals on an SSR page.
- Accessibility: one `h1`, every section labelled by its `h2`;
  `summary` is the interactive element; focus uses `outline-focus`;
  alt text required by validation; captions are visible text, not
  `title` attributes; the icon-only chevron is `aria-hidden`.
- Images: fixed aspect ratio, `decoding="async"`, no CLS.

## 7. Generated content and copy

All static copy is gettext-extracted, the public surfaces' existing
rule. Drafted copy below obeys the copy rules: no em dashes, no
semicolons, short sentences, honest caveats. Figures come from code,
never literals.

### 7.1 Hero

- Lead: `Managed {name}, ready in minutes.`
- Positioning: `An alternative to {a} and {b}.` (Oxford-free join for
  two, comma list for more)
- Caveats eyebrow: `Worth knowing`

### 7.2 Pricing card

- Rate label: `Starts at` then mono `{monthly}/mo`, then
  `billed hourly from your wallet`
- Specs: `Recommended size` then `{cpu} CPU`, `{memory} MB RAM`,
  `{storage} GB storage`
- Checklist: `Start with {amount} in welcome credit`, `Free HTTPS on a
  fluxvale.app address`, `Sleeps when idle, wakes on the next visit`,
  `Nightly backups to your own S3 bucket`, plus `Sign in with your
  Pocket ID` when wired and `Move files in over WebDAV` when file
  access is on
- CTA: `Deploy {name}`
- Fine print: `Monthly equivalent, billed hourly. Storage bills while
  stopped. VAT is added to top-ups for EU customers.`

### 7.3 Category audience lines (drafted, D5)

| Category | Audience line |
|---|---|
| Developer Tools | `A fit for teams that want their own source control and CI without running the servers.` |
| Media & Entertainment | `A fit for personal libraries and households that want their own media server.` |
| Productivity | `A fit for people who want their notes in one place, on their own terms.` |
| Security | `A fit for anyone who would rather hold their own passwords and keys.` |
| Identity | `A fit for households and teams that want one sign-in they control.` |
| Finance | `A fit for households that want their budget data under their own roof.` |

### 7.4 Benefits (platform constants, drafted, D8)

| Title | Body |
|---|---|
| Predictable pricing | `One rate for the resources you pick, billed hourly. No subscriptions.` |
| Sleep by default | `An idle app sleeps after an hour and wakes on the next visit, usually in seconds.` |
| Your data stays yours | `No ads, no profiling, no platform-side copies of your app data.` |
| Backups to your own bucket | `Nightly encrypted snapshots to your S3-compatible storage, restorable in place.` |
| Free HTTPS, your own domain | `Every instance gets a fluxvale.app address and a certificate. Custom domains ride the private-access lane.` |
| Pinned, tested upstream versions | `We publish one tested version per app and track upstream releases.` |
| One region, honestly | `Everything runs in Nuremberg, EU. More regions are planned.` |
| SSO with Pocket ID | `Connect apps that speak OpenID Connect to your own Pocket ID.` (conditional) |
| Files over WebDAV | `Move a library in over WebDAV, no SSH needed.` (conditional) |

Deliberately absent: any automatic-update claim. The platform pins and
tests versions. An update flow is not shipped, so the page must not
promise one.

### 7.5 FAQ (generated plus curated)

Setup column, in order, each item dropped when its source is absent:

| Question | Answer source |
|---|---|
| `How do I set up {name}?` | `first_run.guidance`, else `Deploy it and open the URL. {name} is ready to use out of the box.` |
| `Do I need my own server or Docker?` | Constant: `No. FluxVale runs it on managed Kubernetes. You pick a name and resources, and the platform handles the rest.` |
| `What does {name} cost?` | `Starts at {monthly}/mo at the recommended size, billed hourly from your wallet. Storage bills per GB and keeps billing while the app sleeps.` |
| `Does it stop when nobody uses it?` | Constant: sleep answer plus always-on. |
| `How do I back it up?` | Constant: BYO bucket, nightly, restore from the instance page. |
| `Can I sign in with my Pocket ID?` | Only when the version declares OIDC. Constant answer plus link to `/docs/guides/sso`. |
| `How do I move files in?` | Only when `file_access`. Constant WebDAV answer, with the `/dav` address and credentials shown on the instance page. |
| Curated app questions | `App.faq` appended. |

About column:

| Question | Answer source |
|---|---|
| `Who owns the data I keep on FluxVale?` | Constant: `You do. Your app data lives on your instance's volume. Enable file access or your own backup bucket and it is there to download, migrate, edit, or delete. The platform takes no copies.` Open by default. |
| `What does {name} replace?` | `alternatives` when present. |
| `Can I export my data and leave?` | Constant: upstream formats plus restic backups. |
| `Which region does it run in?` | Constant: Nuremberg, EU. |
| Curated app questions | `App.faq` appended. |

### 7.6 Similar apps, closing CTA

- `Similar apps on FluxVale`, cards as specified.
- `Ready to run {name}?` / `New accounts start with {amount} in
  welcome credit. Deploy in minutes.` / `Deploy {name}`.

## 8. Retro-fill strategy

No app waits for curation. The order is:

1. **Generated page ships first (S3).** Every app, including the six
   shipped ones, gets the complete generated page with zero new
   content. The page promise: hero, pricing card, facts card, benefits,
   FAQ, similar apps, CTA. This is the floor, not a placeholder.
2. **Facts already in the seeds move into fields (S1).** The six
   descriptions already carry caveats and positioning in prose. S1
   promotes them instead of inventing:
   - Forgejo: HTTPS-only git, SSH disabled, SQLite volume.
   - Kavita: file ingest needs WebDAV, scans are image-heavy.
   - Memos: single SQLite file, host account on first open.
   - Vaultwarden: admin panel off, sign-ups open, SSO is deploy-time
     only.
   - Pocket ID: wants always-on, encryption key custody, load-bearing
     for other apps.
   - ActualBudget: one shared password, bank sync needs a SimpleFIN
     token.
   Each entry gets 2-4 caveats, 1-3 alternatives, and the category
   audience line. Descriptions are rewritten to the copy rules.
3. **Screenshots and feature cards land per app (S7).** Capture from
   our own instances with seeded demo data (Playwright, the
   `apps/e2e` pattern), two per app, committed under
   `apps/platform/priv/static/images/catalog/<slug>/`. No upstream
   marketing screenshots (D2).
4. **New entries inherit the floor.** YAML gains the fields as content
   is authored. `mix catalog.lint` names what is missing. No DB
   backfill is ever needed: nullable fields plus seed convergence.

Accepted debt: an app published between S1 and S7 has no screenshots
or feature grid until its content pass. The page is complete without
them, and the lint makes the gap visible.

## 9. SEO

- Canonical stays `/catalog/<slug>`. No URL move. The sitemap already
  lists these pages with `updated_at`.
- The page title becomes `{name} hosting · FluxVale`, matching the H1
  and the search intent. The canonical URL is unchanged.
- `SoftwareApplication` JSON-LD grows: `description` from the
  description's first paragraph, `offers` with the recommended monthly
  figure and `priceCurrency: USD`, `screenshot` absolute URLs, and
  `featureList` from feature titles.
- Add `FAQPage` JSON-LD built from the questions actually rendered,
  including the open one. Keep the `:html_safe` encoding.
- Keep the non-canonical-host noindex plug untouched.
- The authenticated `/apps/<slug>` (S6) stays behind auth, so it cannot
  compete as duplicate content.
- Third-party reference screenshots are not committed to the repo.
  The plan links the live PikaPods URL instead.

## 10. Slices

Each slice is one PR with `Closes` only if it completes #611.

**PR body format (owner rule, Nov 8 2026).** No hard word wrap: each paragraph is one unbroken line and GitHub's renderer wraps it. Hard-wrapped prose renders as ragged blocks. Tables, code blocks, and lists format normally. When a slice embeds screenshots, open with a table indexing the captures (capture, what it shows), then embed the images directly beneath the table. S2-S7 carry screenshots, so every one follows the table-then-images shape.

**S1. Catalog marketing metadata (data only)**
Add the six App fields plus `Category.audience`, three typed list
types with validation, seed loader pass-through, migration, and the
retro-filled YAML for the six apps.
Done when: `mix ci` green; seeds run twice with zero diffs; every
validation rejection has a test; all six apps carry caveats,
alternatives, and their category's audience line; nothing renders yet.

**S2. Public page hero and transactional cards**
Rebuild `/catalog/:slug`'s hero: breadcrumb, eyebrow, serif title,
lead, description, caveats block, alternatives, link row, pricing card,
facts card, catalog.css display scope, responsive stacking.
Done when: all six apps render at 1440 and 390 in light and dark; the
card's rate and specs equal the deploy stepper's first paint; updated
tests pass; before/after captures embedded in the PR.

**S3. Generated sections: benefits, FAQ, similar apps, CTA**
Add the constants module and the four generated sections, with
conditional rows and a native-details accordion (data ownership open).
Done when: an app with zero curated content renders the hero plus four
complete generated sections with no empty state; generator tests cover
nil `first_run`, no OIDC, no file access, and a one-app category; copy
passes the lint; captures embedded.

**S4. Curated sections: in action, features, app FAQ**
Render screenshots (2x2, captions, lazy, fixed aspect), the feature
grid, curated FAQ items, and the community link; omit cleanly when
absent.
Done when: present and absent cases both tested; images carry
dimensions and alt text; sections absent leave no gap; seeded content
renders; captures embedded.

**S5. Structured data**
Extend `SoftwareApplication` (offers, screenshots, feature list) and
add `FAQPage`, both from rendered data only.
Done when: JSON parses in tests; FAQPage matches visible questions;
the offer price equals the card rate; the `</script>` breakout test
still passes.

**S6. Authenticated page parity**
Extract the sections into `CatalogPageComponents`; render the same
content on `/apps/:slug` in the console chrome above the existing
versions, with deploy actions intact.
Done when: both routes render the same sections; existing catalog and
deploy tests pass; captures embedded.

**S7. Launch content pass for the six apps**
Capture two screenshots per app from our own instances, author four
feature cards, two to four app FAQ items, the in-action intro, and
rewrite descriptions to the copy rules.
Done when: the content checklist holds for all six (2 screenshots, 4
features, 2 FAQ, caveats, alternatives); no em dashes or semicolons in
curated copy; assets committed; final page captures embedded.

**S8. Admin authoring (only if D4 says yes)**
Add an admin form for the new fields, reusing the types' validation.
Done when: every field round-trips through the admin form and seeds
still converge.

Dependencies: S1 first. S2 needs S1. S3 can run beside S1 (existing
fields only). S4 needs S1 and S2. S5 after S4. S6 after S4. S7 starts
after S1 and gates launch if D9 says so.

## 11. Decisions for Terence

**Settled Nov 8 2026: approved, all twelve as recommended.** The text
below is the record. Two clarifications from the ruling: D2 captures
come from our staging instances, and D9 makes S7 a launch gate.

Each has a recommendation. Answer inline on the issue.

**D1. Authoring contract for the new fields.**
Recommend: all six optional. A page is complete on today's fields.
`mix catalog.lint` reports missing curation without failing CI.
Rejected: making caveats and alternatives required in seeds, which
blocks new entries on copy.
*Why it matters: this decides what future catalog entries must author.*

**D2. Screenshot source and storage.**
Recommend: repo assets under
`apps/platform/priv/static/images/catalog/<slug>/`, captured from our
staging instances (Playwright, seeded demo data), reviewed in the PR.
No upstream marketing shots, no hotlinks, no admin uploads in v1.
*Who captures: the implementation agent. Who approves: you.*

**D3. Surface scope.**
Recommend: both. Public `/catalog/:slug` first (S2-S5), then the same
content on the authenticated `/apps/:slug` above the versions (S6), so
signed-in buyers do not see a thinner page than visitors.

**D4. Authoring path.**
Recommend: YAML seeds as the source of truth, content as PRs
([ADR-0044](../adr/00044-public-docs-surface.md)'s discipline). Admin
editing is S8 only if you want it now.

**D5. Category audience field.**
Recommend: add `Category.audience` and approve the six lines in §7.3.
It gives every app a "who it suits" paragraph for one sentence per
category.

**D6. Similar apps.**
Recommend: category-generated, max 4, fallback to a browse card. No
curated app-to-app relation in v1.

**D7. The stats card.**
Recommend: our facts card (version, updated, wake estimate, region,
backups, SSO, file access) instead of GitHub stars and contributors.
No stats sync job.

**D8. Benefits copy and the update claim.**
Recommend: the nine-row list in §7.4, with no automatic-update claim.
Confirm the wording, especially "Pinned, tested upstream versions".

**D9. Launch depth for the six shipped apps.**
Recommend: S7 is a launch gate, so all six pages ship at full parity.
Alternative: ship generated pages now and backfill later.

**D10. Copy lint enforcement.**
Recommend: reject em dashes and semicolons at write time in the new
curated fields, and clean the existing `first_run.guidance` text in S1
(it currently contains em dashes).

**D11. Which FAQ answer starts open.**
Recommend: the data-ownership answer, matching the reference and
carrying the strongest promise.

**D12. Versions on the authenticated page.**
Recommend: keep the version cards and release notes below the
marketing content, so deployers still get the technical detail.

## 12. Risks and rejected alternatives

- **Copy drift from shipped behavior.** The page will claim backups,
  sleep, and domains. Each claim maps to an ADR
  ([ADR-0036](../adr/00036-scale-to-zero-wake-on-use.md),
  [ADR-0037](../adr/00037-instance-backups-s3.md),
  [ADR-0040](../adr/00040-strong-private-access-and-custom-domains.md)).
  Reviewers check claims against the ADR, not against marketing habit.
- **Curation debt.** The lint makes it visible. The generated floor
  keeps pages complete while it is paid down.
- **Screenshot staleness.** Accepted. Screenshots are refreshed with
  major upstream UI changes, not every release. The version fact on
  the page states what is actually running.
- **i18n.** New copy must be gettext msgids. Placeholders keep word
  order flexible. Data never becomes a msgid.
- **Page weight.** Lazy images, fixed dimensions, no new JS. The page
  stays SSR with zero client JavaScript.

Rejected:

- **One markdown body per app.** It would match PikaPods' authoring
  freedom but lose section structure, SEO markup, and the
  generated/override split. Copy would drift per app.
- **LiveView for the public page.** Crawlers lose the document and the
  page gains a socket. The blog and docs already proved the SSR lane.
- **An external CMS.** A second pipeline and a second design system
  ([ADR-0044](../adr/00044-public-docs-surface.md)'s rejected
  alternative).
- **Committing PikaPods screenshots as reference assets.** Third-party
  content. The plan links the live page.
- **A curated similar-apps relation in v1.** Category membership
  already gives honest similarity, and a relation adds an authoring
  step nobody asked for.
- **Full-bleed alternating bands.** Tempting for the PikaPods look, but
  it needs a new layout grammar on the bounded public column. Hairline
  seams and spacing stay on the design system.

## 13. Out of scope (settled elsewhere)

- Canonical URL stays `/catalog/<slug>`
  ([ADR-00025](../adr/00025-seo-content-architecture.md)).
- Public page stays SSR and anonymous-readable.
- Region reality is Nuremberg only. The copy says so.
- Welcome credit is $3 (code-clamped), not PikaPods' $5.
- No per-app OG images in v1 (ADR-0025 defers them).
- No pricing or billing changes.
- No new dependencies and no client-side JavaScript.
