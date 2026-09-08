defmodule FluxValeWeb.Router do
  use FluxValeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FluxValeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    # "json" maps to the JSON:API media type (config.exs, per the ash_json_api
    # installer) — accepts ["json"] negotiates application/vnd.api+json
    plug :accepts, ["json"]
  end

  # #24: resolve (Authenticate) then gate (RequireActor) — the machine-client
  # 401/403 contract. fetch_session rides here so the session fallback can
  # read the token-backed session cookie (v1's :api pipeline did the same).
  pipeline :api_auth do
    plug :fetch_session
    plug FluxValeWeb.Plugs.Authenticate
    plug FluxValeWeb.Plugs.RequireActor
  end

  scope "/", FluxValeWeb do
    pipe_through :api

    # Kubernetes probes + deploy-pipeline poll target (docs/deployment.md):
    # liveness must stay dependency-free; readiness gates traffic on the DB.
    get "/health", HealthController, :show
    get "/health/ready", HealthController, :ready
  end

  # /api/v1 — the versioned JSON:API surface (#24 settles OQ #9: URL-prefix
  # versioning; the scaffold's /api/json named the format, not a version,
  # and died while zero clients existed). Everything under the prefix rides
  # the auth gate, the OpenAPI spec included — client generation renders
  # the spec offline from compiled resources anyway (v1's pattern), and
  # swaggerui authenticates through the session fallback in dev.
  scope "/api/v1" do
    pipe_through [:api, :api_auth]

    forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/v1/open_api",
      default_model_expand_depth: 4

    forward "/", FluxValeWeb.AshJsonApiRouter
  end

  scope "/", FluxValeWeb do
    pipe_through :browser

    get "/", PageController, :home

    # #21: passwordless sign-in — LiveView flow + the POST-only session
    # write (token in the body, never a URL)
    live "/sign-in", AuthLive.SignIn
    post "/auth/session", SessionController, :create
  end

  # Other scopes may use custom stacks.
  # scope "/api", FluxValeWeb do
  #   pipe_through :api
  # end

  # #22: the gated TestInbox (ADR-0003 Am. 2, ADR-0023 Am. 3+4) — the
  # admin-auth'd mailbox viewer + JSON endpoint over Swoosh Local storage.
  # Lives outside /api/v1 on purpose: a config-gated dev/ops surface, not
  # the versioned client contract (#24). The gate is a runtime plug, not
  # compile_env mounting — staging flips the same release via
  # TEST_INBOX_ENABLED (runtime.exs); under prod config it 404s, which is
  # the route-absent exit criterion.
  pipeline :test_inbox_api do
    plug :fetch_session
    plug FluxValeWeb.Plugs.TestInboxEnabled
    plug FluxValeWeb.Plugs.Authenticate
    plug FluxValeWeb.Plugs.RequirePlatformAdmin, :json
  end

  # No protect_from_forgery, deliberately: the stock Swoosh preview's
  # clear-mailbox form carries no CSRF token, and the only POST it enables
  # clears a non-prod, admin-gated test inbox — no asset worth the 403s.
  pipeline :test_inbox_browser do
    plug :fetch_session
    plug :put_secure_browser_headers
    plug FluxValeWeb.Plugs.TestInboxEnabled
    plug FluxValeWeb.Plugs.Authenticate
    plug FluxValeWeb.Plugs.RequirePlatformAdmin, :html
  end

  scope "/test-inbox", FluxValeWeb do
    pipe_through :test_inbox_api

    get "/api/mails", TestInboxController, :index
    get "/api/mails/latest", TestInboxController, :latest
  end

  scope "/test-inbox" do
    pipe_through :test_inbox_browser

    # The stock Swoosh preview (list + per-mail pages) behind the gates;
    # the wrapper injects the runtime storage driver per-request
    forward "/", FluxValeWeb.Plugs.TestInboxPreview
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
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FluxValeWeb.Telemetry
      # No Swoosh /dev/mailbox here: ADR-0023 Am. 3 — the gated TestInbox
      # above (#22) is the only sanctioned mail viewer; the stock mount
      # is public-by-design (it displays live login codes)
    end
  end

  if Application.compile_env(:flux_vale, :dev_routes) do
    # AshAdmin cannot render with zero admin-ENABLED domains (nil action_type
    # upstream) — registered-but-not-exposed domains don't count, so the
    # swap key is `ash_admin_domains` (opt-in, ADR-0027 §3), not `ash_domains`.
    # Identity is registered but stays out of AshAdmin; Ops opts in with #25.
    if Application.compile_env(:flux_vale, :ash_admin_domains) == [] do
      scope "/admin", FluxValeWeb do
        pipe_through :browser

        get "/", AdminPlaceholderController, :home
      end
    else
      import AshAdmin.Router

      scope "/admin" do
        pipe_through :browser

        ash_admin "/"
      end
    end
  end
end
