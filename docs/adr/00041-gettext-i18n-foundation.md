# ADR-0041: Gettext i18n foundation — en-only, future-ready

**Status**: Accepted (the wiring — config pin, `FluxValeWeb.Locale`
seam, ci gate — ships with the in-flight i18n-infrastructure change;
this ADR is the decision's record)
**Date**: 2026-10-31

## Context

UI copy is hard-coded English, and every string added without an
extraction mechanism is future refactor tax. The machinery already
exists unused: the Phoenix-generated `FluxValeWeb.Gettext` backend
(`apps/platform/lib/flux_vale_web/gettext.ex`), `use Gettext, backend:
FluxValeWeb.Gettext` wired into every controller/template/component
via `flux_vale_web.ex`, and the errors domain carrying the stock Ecto
msgids (`priv/gettext/errors.pot`).

## Decision

Adopt Gettext as the copy mechanism for UI surfaces. **One locale —
`en` — now.** The point is preparedness: adding a locale later is
config + PO files, never a refactor.

- `default_locale: "en"` pinned in `config/config.exs`; the committed
  default-domain POT/PO baseline sits beside the existing errors
  domain under `priv/gettext/`.
- Locale resolution owns one seam, `FluxValeWeb.Locale`:
  `session["locale"]` when it names a known locale, else the app
  default. It lands as a `:browser`-pipeline plug for dead views and
  an `on_mount` on the authenticated `live_session` for LiveViews.
- The root layout's `lang` attribute will track the resolved locale.
- Extension points, documented but unwired: a signed-in user
  preference (a future sign-in writes the same session key) and
  Accept-Language negotiation (a future source ahead of the default).

## Extraction discipline

- **Phase 1 (this decision)**: infrastructure + reference extraction
  on stable surfaces only — the public landing
  (`page_html/home.html.heex`) and the already-gettext'd chrome
  strings (`layouts.ex`, `core_components.ex`). Authed surfaces are
  deliberately NOT extracted: the app-wide redesign lane is rebuilding
  every authed surface, and phase 2 extracts against the redesign's
  FINAL shapes — no template is touched twice.
- **Phase 2 (post-redesign)**: authed-surface extraction. Email copy
  rides phase 2 with an API decision of its own: `FluxVale.Mailer`
  sits in the domain layer (`lib/flux_vale`), so gettext calls there
  would invert the lib boundary, and sweep-triggered deliveries have
  no request to resolve a locale from — each delivery names its locale
  explicitly. An API, not a string wrap.
- **Hygiene gate**: `mix gettext.extract --check-up-to-date` in
  `mix ci` — POT files must match the gettext calls in the tree.
  Operational note: a PR that shifts lines in files carrying gettext
  calls (`core_components.ex`, `layouts.ex`) must re-run
  `mix gettext.extract` and commit the POT churn (location references
  change even when strings do not). Extraction is MIX_ENV-dependent —
  re-run it in the same env as the failing gate (`mix ci` gates in
  dev), or a gettext call in test/support leaves dev- and test-env
  extractions diverged. Templates with no gettext calls
  are invisible to the check — which is why authed templates cannot
  trip it pre-extraction.

## Adding a locale (runbook, not implementation)

1. `mix gettext.merge priv/gettext --locale <locale>` — PO files per
   domain.
2. The `FluxValeWeb.Locale` known-locales guard accepts it as-is — no
   guard change.
3. Translation sourcing decision (human/vendor — separate decision).
4. Wire the new resolution sources: user preference persisted and
   written to the session at sign-in; Accept-Language negotiation
   ahead of the default.
5. `lang` attribute — covered by the wiring above; nothing per-locale.
6. PO plural-forms headers per locale.
7. Date/number/currency formatting is NOT gettext — a CLDR decision
   (`ex_cldr` or equivalent) is its own future ADR.
8. Emails: explicit locale per delivery (the phase-2 mailer API).
9. E2E specs asserting English copy gain locale awareness.

## Rejected alternatives

- **Defer i18n until a second locale is real** — the refactor tax
  lands on every string added in between.
- **Hand-rolled copy indirection** (per-surface copy modules) — no
  extraction tooling, no PO ecosystem, no plural handling.
- **Adopting ex_cldr/CLDR now** — formatting is not the bottleneck;
  overbuild.
- **Extracting authed surfaces now** — collides with the live
  redesign; extract once against final shapes.
