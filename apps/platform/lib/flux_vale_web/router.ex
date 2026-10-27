defmodule FluxValeWeb.Router do
  use FluxValeWeb, :router

  import PhoenixStorybook.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {FluxValeWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
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
  pipeline :api_auth do
    plug(:fetch_session)
    plug(FluxValeWeb.Plugs.Authenticate)
    plug(FluxValeWeb.Plugs.RequireActor)
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
  end

  # /api/v1 — the versioned JSON:API surface (#24 settles OQ #9: URL-prefix
  # versioning; the scaffold's /api/json named the format, not a version,
  # and died while zero clients existed). Everything under the prefix rides
  # the auth gate, the OpenAPI spec included — client generation renders
  # the spec offline from compiled resources anyway (v1's pattern), and
  # swaggerui authenticates through the session fallback in dev.
  scope "/api/v1" do
    pipe_through([:api, :api_auth])

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
  end

  scope "/", FluxValeWeb do
    pipe_through(:sitemap)

    get("/sitemap.xml", SitemapController, :show)
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
    # flow links the refund policy before payment.
    get("/policies/refund", PolicyController, :refund)
  end

  scope "/", FluxValeWeb do
    pipe_through(:browser)

    # #21: passwordless sign-in — LiveView flow + the POST-only session
    # write (token in the body, never a URL)
    live("/sign-in", AuthLive.SignIn)
    post("/auth/session", SessionController, :create)
    delete("/auth/session", SessionController, :delete)

    # #74: the authenticated app surface — catalog browse, deploy stepper,
    # instance status. The on_mount gate resolves the actor from the M2
    # session and redirects to /sign-in without one. #276 rides after it:
    # OrgNav assigns the actor's orgs for the chrome's switcher — data
    # only, never a gate.
    live_session :authenticated,
      on_mount: [
        {FluxValeWeb.UserAuth, :ensure_authenticated},
        {FluxValeWeb.OrgNav, :assign_orgs}
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
      # #276: org settings — slug-keyed like the catalog; the org home
      # route at /organizations/:slug lands with its own ticket.
      live("/organizations/:slug/settings", OrganizationLive.Settings)
      # #276: the org billing view — the /billing shape scoped to the
      # URL's org; slug-keyed like the catalog.
      live("/organizations/:slug/billing", OrganizationLive.Billing)
    end
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

  # Enable LiveDashboard in development
  if Application.compile_env(:flux_vale, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: FluxValeWeb.Telemetry)
      # No Swoosh /dev/mailbox here: ADR-0023 Am. 3 — the gated TestInbox
      # above (#22) is the only sanctioned mail viewer; the stock mount
      # is public-by-design (it displays live login codes)
    end
  end

  if Application.compile_env(:flux_vale, :dev_routes) do
    # AshAdmin cannot render with zero admin-ENABLED domains (nil action_type
    # upstream) — registered-but-not-exposed domains don't count, so the
    # swap key is `ash_admin_domains` (opt-in, ADR-0027 §3), not `ash_domains`.
    # Identity is registered but stays out of AshAdmin; Ops opted in with
    # #25, Catalog with #70, Infrastructure with #72, Pricing with #125,
    # Billing with #140.
    if Application.compile_env(:flux_vale, :ash_admin_domains) == [] do
      scope "/admin", FluxValeWeb do
        pipe_through(:browser)

        get("/", AdminPlaceholderController, :home)
      end
    else
      import AshAdmin.Router

      scope "/admin" do
        pipe_through(:browser)

        ash_admin("/")
      end
    end
  end
end
