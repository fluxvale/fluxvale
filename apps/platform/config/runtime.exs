import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# Build identity for /health — injected at image-build time (docs/deployment.md)
config :flux_vale, build_sha: System.get_env("BUILD_SHA")

# Repo connection: DATABASE_URL wins; otherwise discrete DB_* vars compose
# it (the in-cluster shape — Kubernetes can't template a URL from Secret
# refs, so the Deployment passes DB_USER/DB_PASSWORD via secretKeyRef).
database_url =
  System.get_env("DATABASE_URL") ||
    if host = System.get_env("DB_HOST") do
      user = System.get_env("DB_USER") || raise "DB_USER required when DB_HOST is set"
      password = System.get_env("DB_PASSWORD") || ""
      name = System.get_env("DB_NAME") || "flux_vale"
      port = System.get_env("DB_PORT") || "5432"

      encode = fn value -> URI.encode(value, &URI.char_unreserved?/1) end
      "ecto://#{encode.(user)}:#{encode.(password)}@#{host}:#{port}/#{name}"
    end

# In-cluster dev container (k3d/Tilt, ADR-0020) — discrete vars present:
# override config/dev.exs's localhost defaults. Plain `mix phx.server` on
# the host (no DB_HOST) keeps those defaults.
if config_env() == :dev and database_url do
  config :flux_vale, FluxVale.Repo, url: database_url
end

# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/flux_vale start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :flux_vale, FluxValeWeb.Endpoint, server: true
end

config :flux_vale, FluxValeWeb.Endpoint,
  # In containers (PHX_SERVER set) bind all interfaces — k8s probes and
  # Service routing hit the pod IP, not loopback. Host `mix phx.server`
  # (no PHX_SERVER) keeps config/dev.exs's 127.0.0.1.
  http: [
    ip: if(System.get_env("PHX_SERVER"), do: {0, 0, 0, 0}, else: {127, 0, 0, 1}),
    port: String.to_integer(System.get_env("PORT", "4000"))
  ]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :flux_vale, FluxValeWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/flux_vale_web/router\.ex$"E,
        ~r"lib/flux_vale_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    database_url ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :flux_vale, FluxVale.Repo,
    # TLS stance (ADR-0008/0009): in prod the app talks to the in-cluster
    # CNPG cluster over the pod network, with NetworkPolicies restricting
    # access — plaintext pod-to-pod is the accepted baseline. Two triggers
    # tighten this: (1) the fleet repo mounting CNPG's CA at M4 — then use
    # ssl: [verify: :verify_peer, cacerts: ...]; (2) the managed-PostgreSQL
    # migration path (ADR-0009) — a remote DB makes TLS mandatory. NB
    # Postgrex 0.22: ssl defaults to false and bare `ssl: true` is
    # deprecated (no cert verification) — always a verify_peer keyword list.
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :flux_vale, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :flux_vale, FluxValeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :flux_vale,
    # In-cluster this is injected by the BWS operator (ADR-0021)
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :flux_vale, FluxValeWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :flux_vale, FluxValeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :flux_vale, FluxVale.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
