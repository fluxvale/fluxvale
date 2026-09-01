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
    plug :accepts, ["json"]
  end

  scope "/", FluxValeWeb do
    pipe_through :api

    # Kubernetes probes + deploy-pipeline poll target (docs/deployment.md):
    # liveness must stay dependency-free; readiness gates traffic on the DB.
    get "/health", HealthController, :show
    get "/health/ready", HealthController, :ready
  end

  scope "/api/json" do
    pipe_through [:api]

    forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/json/open_api",
      default_model_expand_depth: 4

    forward "/", FluxValeWeb.AshJsonApiRouter
  end

  scope "/", FluxValeWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", FluxValeWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
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
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  if Application.compile_env(:flux_vale, :dev_routes) do
    if Application.compile_env(:flux_vale, :ash_domains) == [] do
      # AshAdmin cannot render with zero domains (nil action_type upstream);
      # swap to the real dashboard automatically once M2's first domain lands
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
