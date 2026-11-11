defmodule FluxValeWeb.Router do
  use FluxValeWeb, :router

  import PhoenixStorybook.Router
  import AshAdmin.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {FluxValeWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    # Locale rides the fetched session — applies before any rendering.
    plug(FluxValeWeb.Locale)
    # #138: the edge geo header rides the session as checkout location
    # evidence (the wizard reads it in mount).
    plug(FluxValeWeb.Plugs.CaptureIpCountry)
    # #164 (ADR-00025 §4): every non-canonical host is noindex — staging,
    # PR review envs, local dev. Canonical prod host: no-op.
    plug(FluxValeWeb.Plugs.SeoNoindex)
  end

  # #164 (ADR-00025 §3): the public catalog is a marketing surface —
  # display-only session resolution for the navbar chrome; never an auth
  # gate (reads ride the public read policies, the deploy CTA links at
  # the auth-gated /apps/:slug/deploy route).
  pipeline :public_seo do
    plug(FluxValeWeb.Plugs.MaybeResolveUser)
  end

  # #164: the sitemap — XML only, no session, no root layout. URLs are
  # canonical prod origin always (staging serves prod URLs by design,
  # ADR-00025); the noindex plug still rides so a staging sitemap request
  # gets the header too.
  pipeline :sitemap do
    plug(:accepts, ["xml"])
    plug(:put_secure_browser_headers)
    plug(FluxValeWeb.Plugs.SeoNoindex)
  end

  pipeline :api do
    # "json" maps to the JSON:API media type (config.exs, per the ash_json_api
    # installer) — accepts ["json"] negotiates application/vnd.api+json
    plug(:accepts, ["json"])
  end

  # #24: resolve (Authenticate) then gate (RequireActor) — the machine-client
  # 401/403 contract. fetch_session rides here so the session fallback can
  # read the token-backed session cookie (v1's :api pipeline did the same).
  # #360: AuthorizeApiScopes closes the boundary — scopes for PAT callers,
  # read-only sessions (ADR-0019 Am. 1); ApiAudit and ApiRateLimit ride
  # BEFORE the gates, audit first so a halted conn (401/403/429) still gets
  # its audit row (slice 5), the meter right behind it so EVERY
  # PAT-authenticated call is counted — denials included: a valid-but-
  # refused token writes audit rows, so an unmetered denial flood would
  # hammer the trail with no ceiling (ADR-0019 §4).
  pipeline :api_auth do
    plug(:fetch_session)
    plug(FluxValeWeb.Plugs.Authenticate)
    # #484: bridge the resolved PAT's scopes into the Ash request
    # context — /me's token introspection reads them there (right
    # after the boundary resolves the row; no PAT means no entry).
    plug(FluxValeWeb.Plugs.PutPatScopesInAshContext)
    plug(FluxValeWeb.Plugs.ApiAudit)
    plug(FluxValeWeb.Plugs.ApiRateLimit)
    plug(FluxValeWeb.Plugs.RequireActor)
    plug(FluxValeWeb.Plugs.AuthorizeApiScopes)
  end

  # #360 slice 4: the spec this scope serves must equal the committed
  # artifact byte-for-byte — pin its render modules on every request
  # (the plug's moduledoc explains the cold-boot probe this cures).
  pipeline :api_spec_pin do
    plug(FluxValeWeb.Plugs.PinOpenApiRender)
  end

  scope "/", FluxValeWeb do
    pipe_through(:api)

    # Kubernetes probes + deploy-pipeline poll target (docs/deployment.md):
    # liveness must stay dependency-free; readiness gates traffic on the DB.
    get("/health", HealthController, :show)
    get("/health/ready", HealthController, :ready)

    # #203 (ADR-0036): the activity beacon Traefik's forwardAuth
    # consults on every forwarded request — method-blind (the beacon
    # only reads the query), never authed (Traefik is the INTENDED
    # caller; the route is public, which adds nothing over hitting the
    # instance's own URL — visiting IS traffic).
    match(:*, "/internal/edge/touch", EdgeTouchController, :touch)
  end

  # #203: the wake endpoint — instance-host requests land here after
  # EdgeHost's rewrite onto the reserved prefix (arbitrary visitor
  # paths, so a glob; the prefix is ours alone, no collisions). The
  # controller keys off the marker header; no pipeline — anonymous
  # edge traffic, no session/CSRF/accepts, HTML negotiated in the
  # controller (browsers the interstitial, machines 503+Retry-After).
  scope "/", FluxValeWeb do
    match(:*, "/_fluxvale_edge/*path", EdgeWakeController, :wake)
  end

  # #273 (ADR-0039 §6): the gateway's asleep serve target — tailscale
  # serve proxies the visitor's path onto this prefix. Anonymous traffic
  # with no session/CSRF/accepts (the gateway pod is the intended
  # caller; in dev/staging the platform's own host also answers it, so
  # the pairing row in the path — an unguessable (gateway, instance)
  # uuid pair — is the WHOLE gate, not a network boundary; the wake it
  # grants is the same start the org's own panel offers, and its
  # balance already pays for). Revisit trigger: a measured abuse of the
  # path from outside the cluster.
  scope "/", FluxValeWeb do
    match(:*, "/internal/access/:gateway_id/:instance_id/*path", AccessWakeController, :wake)
  end

  # PromEx scrape endpoint (#98, ADR-0012) — gated + dispatched by
  # FluxValeWeb.Plugs.MetricsEndpoint (bearer token when :metrics_token
  # is set; exact-path only). Answers 503 while the PromEx tree is down
  # (dev/test); the fleet overlays add the prometheus.io scrape
  # annotations and the token env.
  forward("/metrics", FluxValeWeb.Plugs.MetricsEndpoint)

  # The storybook workshop (#178): the design system's living reference
  # (FluxValeWeb.Storybook). live_storybook/3 defines its own scope with
  # `pipeline: false`, so this :storybook_browser pipeline is the one it
  # pipe_throughs — the gate rides here, mirroring the TestInbox: routes
  # compile into every release, the plug 404s unless STORYBOOK_ENABLED.
  # Internal-only exposure is the fleet's hostname routing.
  pipeline :storybook_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(FluxValeWeb.Plugs.StorybookEnabled)
  end

  scope "/" do
    # Tool JS/CSS from the dep itself (Plug.Static on priv, no app
    # data) — deliberately ungated; the LiveView above is the surface.
    storybook_assets()
  end

  live_storybook("/storybook",
    backend_module: FluxValeWeb.Storybook,
    pipeline: false
  )

  # Third-party gateway webhooks (#136, ADR-0029): unauthenticated —
  # the caller is the gateway; auth is the HMAC signature each
  # controller verifies against the raw body. Per-provider paths keep
  # the concurrent-gateways option open: new provider, new controller
  # + route, no dispatch table.
  scope "/webhooks", FluxValeWeb.Webhooks do
    pipe_through(:api)

    post("/hitpay", HitPayController, :create)
    post("/polar", PolarController, :create)
  end

  # #362 (T3, OQ #9): the RFC 8628 device-flow wire — PLAIN JSON, not
  # JSON:API: the bodies are bare application/json (RFC 8628 §3.1/§3.5)
  # and the callers are unauthenticated BY DESIGN (the device has no
  # token yet — the flow is how it earns one). So: mounted outside the
  # ash_json_api router, BEFORE the /api/v1 forward below (route match
  # is source order and that forward is a catch-all), on the plain
  # :api pipeline. No ApiAudit/ApiRateLimit — both key on a PAT, which
  # the flow doesn't have; the controller logs its own lines (never a
  # code or token value). IP limiting is v1's named follow-up.
  scope "/api/v1/device", FluxValeWeb do
    pipe_through(:api)

    post("/code", Api.DeviceFlowController, :create_code)
    post("/token", Api.DeviceFlowController, :poll_token)
  end

  # /api/v1 — the versioned JSON:API surface (#24 settles OQ #9: URL-prefix
  # versioning; the scaffold's /api/json named the format, not a version,
  # and died while zero clients existed). Everything under the prefix rides
  # the auth gate, the OpenAPI spec included — client generation renders
  # the spec offline from compiled resources anyway (v1's pattern), and
  # swaggerui authenticates through the session fallback in dev.
  scope "/api/v1" do
    pipe_through([:api, :api_auth, :api_spec_pin])

    forward("/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/v1/open_api",
      default_model_expand_depth: 4
    )

    forward("/", FluxValeWeb.AshJsonApiRouter)
  end

  # #164: the public SEO routes — programmatic-SEO catalog pages, the
  # anonymous-OK SSR mirrors of the authenticated CatalogLive browse. The
  # authenticated live_session below is untouched: anonymous deploy clicks
  # 302 to /sign-in exactly as today.
  scope "/", FluxValeWeb do
    pipe_through([:browser, :public_seo])

    get("/catalog", CatalogController, :index)
    get("/catalog/:slug", CatalogController, :show)

    # #396: the published pricing — the cost-truth surface, public and
    # anonymous-OK like the catalog above.
    get("/pricing", PricingController, :show)

    # #412 T9: the roadmap — a public SSR view over the board's post
    # statuses (planned, started, completed). Top-level ON PURPOSE: a
    # nested /feedback/roadmap would be eaten by :show's /feedback/:slug
    # below (clauses compile in source order), and /roadmap is the
    # better shared URL.
    get("/roadmap", FeedbackController, :roadmap)

    # #412 T5: the composer — the fixed path the comment below reserved,
    # declared BEFORE :show's /feedback/:slug (router clauses compile in
    # source order, and a later fixed route would be eaten by the :slug
    # route — the /blog/feed lesson).
    live("/feedback/new", FeedbackLive.Composer)

    # #412 T4: the public feedback board — the same SSR pattern as the
    # catalog above.
    get("/feedback", FeedbackController, :index)
    get("/feedback/:slug", FeedbackController, :show)
  end

  scope "/", FluxValeWeb do
    pipe_through(:sitemap)

    get("/sitemap.xml", SitemapController, :show)
  end

  # The blog's feed + the ADR's original URL (ADR-00025 §1 + Am. 1):
  # pipeline-less on purpose — plug :accepts on "xml" would 406 a feed
  # reader's `Accept: application/atom+xml`, and any client (browser,
  # reader, curl) should get the feed regardless of its Accept header
  # (CodeRabbit #326). The controller sets the content type itself.
  # Both stay BEFORE the /blog/:slug scope below so "feed" is never
  # captured as a slug.
  scope "/", FluxValeWeb do
    get("/blog/feed", FeedController, :show)
    get("/feed.xml", FeedController, :legacy)
  end

  # The blog (ADR-00025 §1): markdown posts from the synced docs/blog
  # copy in priv (ADR-0044 §2), SSR-only — crawlers get the full
  # document with zero JS. Draft policy rides the controller (404 on
  # the canonical host, preview everywhere else), keeping it next to
  # the noindex plug's predicate. Lives AFTER the feed scopes above:
  # /blog/feed must match the xml route before this :slug route could
  # eat it.
  scope "/", FluxValeWeb do
    pipe_through([:browser, :public_seo])

    get("/blog", BlogController, :index)
    get("/blog/:slug", BlogController, :show)
  end

  # The public docs (ADR-0044 §5): markdown pages synced from
  # docs/public into priv/content/docs (mix content.sync — the
  # gitignored copy), SSR-only like the blog above. The sectioned
  # sidebar ships as plain HTML, zero JS. Section pages and pages 404
  # as real unknowns (a section with no pages is "not here" by
  # design).
  scope "/", FluxValeWeb do
    pipe_through([:browser, :public_seo])

    get("/docs", DocsController, :index)
    get("/docs/:section", DocsController, :section)
    get("/docs/:section/:slug", DocsController, :show)
  end

  # #205: the session-aware root. `:public_seo`'s display-only
  # resolution feeds PageController's GitHub-style swap (anonymous ->
  # landing dead view, signed-in -> dashboard LiveView) and the
  # landing's own signed-in chrome. The plug stays display-only —
  # the swap decision is the controller's, the auth gate is the
  # dashboard LiveView's on_mount.
  scope "/", FluxValeWeb do
    pipe_through([:browser, :public_seo])

    get("/", PageController, :home)
    get("/about", PageController, :about)

    # #140: the published policies — public and anonymous-OK; the top-up
    # flow links the refund policy before payment. #365 adds the Terms
    # of Service and the Acceptable Use Policy beside it. fv332 D5 adds
    # the privacy policy (Google sign-in branding asks for it, and it
    # should exist on its own merits).
    get("/policies/refund", PolicyController, :refund)
    get("/policies/terms", PolicyController, :terms)
    get("/policies/acceptable-use", PolicyController, :acceptable_use)
    get("/policies/privacy", PolicyController, :privacy)

    # #511: the sign-in-with-Pocket ID guide — public and anonymous-OK
    # like the policies. The wiring steps are identical before and
    # after sign-in, and the honest weights (an identity instance wants
    # always-on, destroying one loses the identities it holds) inform
    # the deploy that usually comes first.
    get("/guides/sign-in-with-pocket-id", GuideController, :sign_in_with_pocket_id)
  end

  scope "/", FluxValeWeb do
    pipe_through(:browser)

    # #21: passwordless sign-in — LiveView flow + the POST-only session
    # write (token in the body, never a URL)
    live("/sign-in", AuthLive.SignIn, :email)
    # #219: the native fallback's two hops — the request-code POST and
    # its PRG landing (the code step, address riding the session), so
    # sign-in completes with the WebSocket handshake blocked. The
    # verify POST is the session write below, in its code arm.
    post("/auth/sign-in", SignInController, :create)
    live("/sign-in/code", AuthLive.SignIn, :code)
    # #502: the invitee's accept landing — anonymous by design (the
    # invitee has no session yet, acceptance mints one), so it sits
    # beside /sign-in, OUTSIDE the :authenticated live_session below.
    live("/invites/accept", AuthLive.InviteAccept)
    post("/auth/session", SessionController, :create)
    delete("/auth/session", SessionController, :delete)

    # #642 (plan §3.2): the Google OIDC arm's two hops. GETs on
    # purpose — no CSRF token is needed. The CSRF story, honestly: the
    # AUTHORIZE hop does write the caller's session (it parks the
    # round trip), and SameSite=Lax carries the cookie exactly there —
    # a top-level navigation is how the flow works. A cross-site
    # trigger can force one, but the worst case is overwriting the
    # visitor's OWN pending round trip; no action is taken on their
    # behalf. The CALLBACK's defense is the OIDC state + nonce bound
    # to those session_params (assent validates both before anything
    # outbound). Both hops are per-IP throttled in the controller
    # (GoogleRateLimit, the D-abuse window).
    get("/auth/google", GoogleController, :authorize)
    get("/auth/google/callback", GoogleController, :callback)

    # #74: the authenticated app surface — catalog browse, deploy stepper,
    # instance status. The on_mount gate resolves the actor from the M2
    # session and redirects to /sign-in without one. #276 rides after it:
    # OrgNav assigns the actor's orgs for the chrome's switcher — data
    # only, never a gate.
    live_session :authenticated,
      on_mount: [
        # Locale first: applies in the LiveView process before any rendering.
        {FluxValeWeb.Locale, :set_locale},
        {FluxValeWeb.UserAuth, :ensure_authenticated},
        {FluxValeWeb.OrgNav, :assign_orgs},
        {FluxValeWeb.NavSection, :derive}
      ] do
      live("/apps", CatalogLive.Index)
      live("/apps/:slug", CatalogLive.Show)
      live("/apps/:slug/deploy", CatalogLive.Deploy)
      live("/instances", InstanceLive.Index)
      live("/instances/:id", InstanceLive.Show)
      live("/billing", BillingLive.Index)
      # #137: the top-up wizard — steps live in LiveView state; the
      # return route is the gateway's landing (its reference query
      # param; the DB row is the truth, the status param is ignored).
      live("/billing/topup", BillingLive.Topup)
      live("/billing/topup/return", BillingLive.Topup)
      # #276: org settings — slug-keyed like the catalog.
      live("/organizations/:slug/settings", OrganizationLive.Settings)
      live("/organizations/:slug/settings/members", OrganizationLive.Members)
      # #408 slice 4: the invitation landing — the raw token rides the
      # query param and IS the invitee-side credential; signed-in only
      # (this session's gate — anonymous hits the sign-in redirect, the
      # email names the address to sign in with).
      live("/invitations/accept", OrganizationLive.InviteAccept)
      # #273 (ADR-0039): the private-access gateway's owner surface — the
      # Access tab. Owners-only in the panel (the UX gate); the actions'
      # own policies stay the authority.
      live("/organizations/:slug/settings/access", OrganizationLive.Access)
      # #276: the org billing view — the /billing shape scoped to the
      # URL's org; slug-keyed like the catalog.
      live("/organizations/:slug/billing", OrganizationLive.Billing)
      # #408: the org-context top-up — the wizard mounted for the URL's
      # org; the return route is its gateway landing. Named action (:org)
      # so the mount arms stay apart (/settings/access's posture:
      # LiveView merges query params into mount params, and the personal
      # wizard's contract is no slug).
      live("/organizations/:slug/billing/topup", BillingLive.Topup, :org)
      live("/organizations/:slug/billing/topup/return", BillingLive.Topup, :org)
      # #408: org creation — the switcher footer entry's target. The
      # literal beats :slug by definition order; "new" rides the
      # reservation list so the actor-create path cannot mint an org at
      # the creation page's own address. Rename and the JIT signup path
      # can still land an org on reserved words (ReservedSlug's
      # moduledoc) — such an org's home serves this page; no redirect.
      live("/organizations/new", OrganizationLive.New)
      # #276: the org home — the switcher rows' target, slug-keyed like
      # the catalog.
      live("/organizations/:slug", OrganizationLive.Home)
      # #285 T5: account settings — the username rename + email
      # management, linked from the user menu.
      live("/settings", SettingsLive)
      # S5: the personal account's access panel — OrganizationLive.Access
      # mounted WITHOUT a slug serves the actor's personal org (the
      # slug-keyed org route redirects here). Named action (:personal) so
      # the mount can refuse a ?slug= query param — LiveView merges
      # query params into mount params, and an unnamed head would let a
      # crafted query string mount the org frame on this route.
      live("/settings/access", OrganizationLive.Access, :personal)
      # #635: the developer settings page — the Device sign-ins (#362)
      # and API tokens (#483) sections moved here from /settings/access
      # (the gateway panel keeps its namesake page). Actor-scoped like
      # the rest of the settings cluster: no org at mount, so no slug
      # contract and no named action — the device flow's
      # /settings/access/device landing redirects here at its anchor.
      live("/settings/developer", DeveloperSettingsLive)
      # #484 W5: the agent quickstart — the remote MCP server's recipe
      # (server URL, per-client configs, scopes, the destructive gate),
      # one click from the developer page's tokens section and from
      # the sidebar. Static content: no org, no reads.
      live("/settings/agents", SettingsLive.Agents)
    end
  end

  # #362: the device flow's verification_uri target — a controller
  # redirect to the developer settings page at the Device sign-ins
  # section (the fragment; #635 moved the section off /settings/access).
  # Outside the live_session above on purpose: a plain GET
  # can't ride on_mount gates, and the controller checks the same
  # session chain (UserAuth.resolve_user) — anonymous visitors go to
  # sign-in, the panel's own gate would bounce them there anyway.
  scope "/", FluxValeWeb do
    pipe_through(:browser)

    get("/settings/access/device", DeviceFlowEntryController, :entry)
  end

  # Other scopes may use custom stacks.
  # scope "/api", FluxValeWeb do
  #   pipe_through :api
  # end

  # #22: the gated TestInbox (ADR-0003 Am. 2, ADR-0023 Am. 3+5) — the
  # admin-auth'd mailbox viewer + JSON endpoint over Swoosh Local storage.
  # Lives outside /api/v1 on purpose: a config-gated dev/ops surface, not
  # the versioned client contract (#24). The gate is a runtime plug, not
  # compile_env mounting — staging flips the same release via
  # TEST_INBOX_ENABLED (runtime.exs); under prod config it 404s, which is
  # the route-absent exit criterion.
  pipeline :test_inbox_api do
    plug(:fetch_session)
    plug(FluxValeWeb.Plugs.TestInboxEnabled)
    plug(FluxValeWeb.Plugs.Authenticate)
    plug(FluxValeWeb.Plugs.RequirePlatformAdmin, :json)
  end

  # No protect_from_forgery, deliberately: the stock Swoosh preview's
  # clear-mailbox form carries no CSRF token, and the only POST it enables
  # clears a non-prod, admin-gated test inbox — no asset worth the 403s.
  pipeline :test_inbox_browser do
    plug(:fetch_session)
    plug(:put_secure_browser_headers)
    plug(FluxValeWeb.Plugs.TestInboxEnabled)
    plug(FluxValeWeb.Plugs.Authenticate)
    plug(FluxValeWeb.Plugs.RequirePlatformAdmin, :html)
  end

  scope "/test-inbox", FluxValeWeb do
    pipe_through(:test_inbox_api)

    get("/api/mails", TestInboxController, :index)
    get("/api/mails/latest", TestInboxController, :latest)
  end

  scope "/test-inbox" do
    pipe_through(:test_inbox_browser)

    # The stock Swoosh preview (list + per-mail pages) behind the gates;
    # the wrapper injects the runtime storage driver per-request
    forward("/", FluxValeWeb.Plugs.TestInboxPreview)
  end

  # The admin surface (ADR-0027 §2, built with #288; Am. 3 Nov 7,
  # 2026): ALWAYS MOUNTED in every environment — the runtime
  # ADMIN_MOUNT_KEY gate is retired (Am. 2); the platform-admin auth IS
  # the gate. §2's route-level auth: the platform-admin session, the
  # same stack the TestInbox rides. Every surface below adds the
  # on_mount re-check at every socket mount — a LiveView socket never
  # re-enters the router, so without it a demoted admin's session token
  # outlives the demotion for the life of the tab. Which domains render
  # in AshAdmin is the §3 opt-in (`admin show?` per domain, config.exs —
  # Identity/Accounts stay out); AshAdmin resolves that set at runtime,
  # so nothing about the exposure is baked into these routes.
  pipeline :admin_auth do
    plug(FluxValeWeb.Plugs.Authenticate)
    plug(FluxValeWeb.Plugs.RequirePlatformAdmin, :html)
  end

  # The scope stays alias-less on purpose: a scope alias would prefix
  # the FULL module names the macros below compile against — including
  # AshAdmin's own AshAdmin.PageLive, which it inlines directly in this
  # scope (unlike live_dashboard, which wraps itself in an
  # `alias: false` scope) — so `scope "/admin", FluxValeWeb` breaks the
  # mount. The one module of ours here is fully qualified instead.
  scope "/admin" do
    pipe_through([:browser, :admin_auth])

    # The custom operator console (Am. 3, #501; Am. 4, Nov 8): the
    # surfaces live in the :admin live_session, each rendered beside
    # the shared section sidebar (AdminShell — the #568 account-settings
    # idiom). There is no homepage: `/admin` is the People mount's
    # :home action, which pushes navigation to the first live section.
    # The session carries the same arms for the same jobs as the app's
    # :authenticated session: Locale first (the LiveView process
    # re-resolves from the session), then the AdminGate socket re-check
    # (the demotion window), then the per-event demotion seam (#671:
    # the AdminDemotionGate hooks, extracted) BEFORE the chrome so its
    # info gate halts ahead of the badge hook — and the route gate is
    # the scope's :admin_auth pipeline.
    live_session :admin,
      on_mount: [
        {FluxValeWeb.Locale, :set_locale},
        {FluxValeWeb.AdminGate, :ensure_admin},
        {FluxValeWeb.AdminDemotionGate, :attach},
        {FluxValeWeb.AdminChrome, :assign_chrome}
      ] do
      live("/", FluxValeWeb.AdminLive.People, :home)

      # The people surface (#501): the invitation list, the invite form,
      # and the per-invitation support actions. Every read and write
      # rides the identity domain with the platform-admin actor and
      # authorize?: true — the domain policies decide, never the UI.
      live("/people", FluxValeWeb.AdminLive.People)

      # The catalog + pricing surgery surface (#501): the lane's first
      # write surface. Every write rides the resource actions with the
      # platform-admin actor and authorize?: true — the domain policies
      # decide, never the UI.
      live("/catalog", FluxValeWeb.AdminLive.Catalog)
      live("/catalog/sizes", FluxValeWeb.AdminLive.Sizes)
      live("/catalog/sizes/:id", FluxValeWeb.AdminLive.SizeEdit)
      live("/catalog/versions/:id", FluxValeWeb.AdminLive.VersionEdit)

      # The wallets + billing oversight surface (#501): the wallet table
      # (org-first, the domain's stated operator contract) and the
      # per-wallet detail with its ledger, the waiver flip, and the
      # goodwill credit. Reads and writes ride the billing domain with
      # the platform-admin actor and authorize?: true — the domain
      # policies decide, never the UI. The reversal rides the
      # `LedgerEntry :reverse` action (#577), policy-gated like the
      # goodwill credit.
      live("/billing", FluxValeWeb.AdminLive.Billing)
      live("/billing/wallets/:id", FluxValeWeb.AdminLive.WalletDetail)

      # The feedback moderation surface (#501): the board's posts with
      # their comments, votes, and tags. Every read and write rides the
      # feedback domain with the platform-admin actor and authorize?:
      # true — the domain policies decide, never the UI.
      live("/moderation", FluxValeWeb.AdminLive.Moderation)

      # The generic resource console (#595, slice 1: reads; slice 2: the
      # write mounts). Segments resolve against the exposure registry
      # (FluxValeWeb.AdminConsole — the security boundary); unknown
      # segments bounce with an honest flash. "new" is literal BEFORE
      # the :id clause — the /organizations/new idiom; ids are UUIDs
      # and can never be "new".
      live("/resources", FluxValeWeb.AdminLive.Resources, :domains)
      live("/resources/:domain", FluxValeWeb.AdminLive.Resources, :domain)
      live("/resources/:domain/:resource/new", FluxValeWeb.AdminLive.Resources, :new)
      live("/resources/:domain/:resource", FluxValeWeb.AdminLive.Resources, :index)
      live("/resources/:domain/:resource/:id/edit", FluxValeWeb.AdminLive.Resources, :edit)
      live("/resources/:domain/:resource/:id", FluxValeWeb.AdminLive.Resources, :show)

      # The orgs + instances overview surface (#501): read-only by
      # design — the v1 plan reserved this section's writes. Every read
      # rides the existing seams with the platform-admin actor and
      # authorize?: true: org names ride the flagged :admin_lookup,
      # wallet state rides the wallet read policy's admin arm, and
      # instances render exactly as far as the members-only instance
      # read policy admits the admin (the orgs they belong to). No
      # writes anywhere on the surface, and no new domain actions.
      live("/orgs", FluxValeWeb.AdminLive.Orgs)
      live("/orgs/:id", FluxValeWeb.AdminLive.OrgDetail)

      # The access gateways + domains oversight surface (#501): the
      # last v1 section, read-only by design — registration and key
      # writes belong to the product surfaces. Reads ride the
      # infrastructure domain with the platform-admin actor and
      # authorize?: true — the domain policies decide, never the UI.
      # The gateway and domain read policies are members-only filters
      # with no platform-admin arm, so the section renders exactly the
      # rows those policies admit and says so honestly. With the orgs
      # section live above it, the v1 surface set is complete and the
      # shell's Coming grammar has retired.
      live("/gateways", FluxValeWeb.AdminLive.Gateways)
      live("/gateways/:id", FluxValeWeb.AdminLive.GatewayDetail)

      # The storage-request approval queue (#250, ADR-0046 D5): a
      # purpose-built workflow section — approve/reject/retry, with the
      # capability and wallet context the decision needs. Reads and
      # writes ride the Infrastructure domain with the platform-admin
      # actor and authorize?: true; the instance's decision context is a
      # scoped system read after the admin gate (the member Instance
      # read policy gains no admin arm here).
      live("/storage-requests", FluxValeWeb.AdminLive.StorageRequests)

      # The audit trail's window (#645, ADR-0048): the business set's
      # version rows in one cross-resource view, resource/actor/record
      # filters riding query params. Each read rides the selected
      # Version resource's own admin-only policy (the shared
      # VersionMixin) with the platform-admin actor — the mixin
      # decides, never the UI.
      live("/audit", FluxValeWeb.AdminLive.Audit, :index)

      # The health section (#702, ADR-0050): the instance fleet at a
      # glance — build stamp, status spread, the newest deploys. Before
      # the generated-tool mounts below: those carry segment wildcards
      # and router clauses compile in source order (the ORDER MATTERS
      # note on the dashboard mount).
      live("/health", FluxValeWeb.AdminLive.Health)
    end

    # LiveDashboard on the debug subpath (Am. 3): this node's BEAM and
    # Ecto telemetry, the LiveDashboard docs' prod pattern — no more
    # /dev-only mount. The SAME gate stack as everything on this
    # surface (the :browser pipeline, the :admin_auth route pipeline —
    # session auth plus the platform-admin role — and the on_mount
    # socket re-check), plus the per-event demotion seam (#671) and
    # its periodic sibling: the AdminGate re-check answers per MOUNT,
    # a socket outlives a demotion, and the seam's info halt is quiet
    # — so the AdminDemotionRecheck tick (Am. 6) sits BETWEEN them:
    # ordered before the seam so its redirect wins on the tick, it
    # re-resolves the actor every cadence and yanks a dead session's
    # tab to /sign-in, bounding the residue the seam measured (the
    # cid-targeted table controls that push_patch and re-run
    # handle_params ungated) to one cadence. Business telemetry (Telemetry.Metric
    # definitions in FluxValeWeb.Telemetry) renders here;
    # alert-worthy metrics ALSO flow to Grafana where the alert rules
    # live.
    #
    # ORDER MATTERS: this mount must precede ash_admin — AshAdmin's
    # page routes end in a segment wildcard, and router clauses compile
    # in source order: dashboard-after-ash_admin compiles (with a
    # warning) into unreachable clauses, every /admin/* path landing in
    # AshAdmin instead.
    live_dashboard("/debug/dashboard",
      metrics: FluxValeWeb.Telemetry,
      ecto_repos: [FluxVale.Repo],
      on_mount: [
        {FluxValeWeb.AdminGate, :ensure_admin},
        {FluxValeWeb.AdminDemotionRecheck, :attach},
        {FluxValeWeb.AdminDemotionGate, :attach}
      ]
    )

    # AshAdmin on the debug subpath (Am. 3): the generated superuser
    # surface, kept for emergency data surgery — it lands LAST because
    # its own wildcard route would swallow any clause after it in this
    # scope. The demotion seam (#671) rides it too, with its honest
    # limits: the seam sees VIEW-level events (nav, the authorizing
    # toggle, actor/tenant ops), while the rest of AshAdmin's
    # component-level UI — the save/destroy forms, generic actions,
    # table filters — targets its own LiveComponents
    # (`phx-target={@myself}`) and no view-level hook can see those.
    # The AdminDemotionRecheck tick (Am. 6) bounds that residue from
    # the socket side — a dead session's tab redirects within the
    # cadence — and sits BETWEEN AdminGate and the seam so its
    # redirect wins on the tick message.
    ash_admin("/ash",
      on_mount: [
        {FluxValeWeb.AdminGate, :ensure_admin},
        {FluxValeWeb.AdminDemotionRecheck, :attach},
        {FluxValeWeb.AdminDemotionGate, :attach}
      ]
    )
  end
end
