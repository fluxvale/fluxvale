# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

config :spark,
  formatter: [
    "Ash.Resource": [
      section_order: [:authentication, :token, :user_identity, :json_api, :admin, :postgres]
    ],
    "Ash.Domain": [section_order: [:json_api, :admin]]
  ]

config :ash, known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :flux_vale,
  ecto_repos: [FluxVale.Repo],
  # Ash domain registry — first domain landed with Identity (#20), which is
  # deliberately NOT admin-exposed (ADR-0027 §3: User/Token are sensitive).
  # The next two keys interact: /admin serves a placeholder (see the router)
  # until a domain opts into AshAdmin via `ash_admin_domains` — Ops is first
  # (#25).
  ash_domains: [FluxVale.Identity],
  # Domains opted into AshAdmin (exposure is opt-in, ADR-0027 §3). AshAdmin
  # crashes on zero admin-enabled domains (upstream nil action_type bug),
  # so the router keeps the placeholder while this is empty.
  ash_admin_domains: [],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :flux_vale, FluxValeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FluxValeWeb.ErrorHTML, json: FluxValeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: FluxVale.PubSub,
  live_view: [signing_salt: "YdDkESt8"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :flux_vale, FluxVale.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  flux_vale: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  flux_vale: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
