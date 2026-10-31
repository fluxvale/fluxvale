import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# Build identity for /health — injected at image-build time (docs/deployment.md)
config :flux_vale, build_sha: System.get_env("BUILD_SHA")

# Observability env gates (#98) — resolved by FluxVale.Observability so
# the same question has one answering module (testable, and runtime.exs
# stays thin). PromEx rides prod-shaped runs only (fleet overlays set
# PROMEX_ENABLED); test env is pinned off below.
if config_env() != :test do
  config :flux_vale, :prom_ex_enabled, FluxVale.Observability.prom_ex_enabled?()
end

# OTEL export on = one env var (the contract settled on #98): the app
# pushes OTLP to the in-cluster Alloy receiver. Unset (dev/test) keeps
# config.exs's exporter-less processor — spans are created, nothing ships.
# otel_exporter_traces_otlp is the traces exporter (merges the standard
# OTLP env itself); the generic otel_exporter_otlp has no export/3 —
# the batch processor's calls would crash (CodeRabbit, verified in
# source).
if FluxVale.Observability.otel_exporter_on?() do
  config :opentelemetry,
    processors: [{:otel_batch_processor, %{exporter: {:otel_exporter_traces_otlp, %{}}}}]
end

# /metrics bearer gate (FluxValeWeb.Plugs.MetricsEndpoint) — unset in
# dev/test leaves the endpoint open on the cluster network; the fleet
# overlays set it from BWS alongside the Alloy scrape credentials.
case System.get_env("METRICS_TOKEN") do
  nil -> :ok
  token -> config :flux_vale, :metrics_token, token
end

# Instance runtime overrides (config.exs's local defaults, #116): the
# fleet overlays set these per env — INSTANCES_BASE_DOMAIN (staging:
# fluxvale.app, served by the edge wildcard) and INSTANCE_RBAC_SA_NAMESPACE
# (the platform SA's namespace: local runs fluxvale-dev, each deployed
# env its own — a RoleBinding naming the wrong namespace grants the
# workload role to a nonexistent identity). Unset — or "" (the classic
# empty-Secret shape) — keeps the local defaults, so a plain
# `mix phx.server` needs no env.
case System.get_env("INSTANCES_BASE_DOMAIN") do
  domain when domain in [nil, ""] -> :ok
  domain -> config :flux_vale, :instances_base_domain, domain
end

# ADR-0040 S3's runtime wiring (the INSTANCES_BASE_DOMAIN pattern): the
# fleet overlays may still set the access edge (the gateway tunnel's
# target) and the shared resolver IP (the advertised /32 + claim target)
# from env — the env override wins in every branch. Invalid values raise
# at boot: a typo'd port or resolver IP would otherwise poison every
# claim silently.
#
# The access-edge DEFAULTS are the fleet's landed shape (infra #119):
# the `access` entrypoint on the fleet Traefik, ports 8444/8080. Inert
# on a local stack — without `:access_dns` nothing claims, and without
# a claim nothing rides the tunnel limb (the ts.net port config is
# byte-identical, pinned by test) — so a plain `mix phx.server` still
# needs no env.
parse_port = fn var_name, default ->
  case System.get_env(var_name) do
    value when value in [nil, ""] ->
      default

    value ->
      case Integer.parse(value) do
        {port, ""} when port in 1..65_535 ->
          port

        _invalid ->
          raise ArgumentError,
                "#{var_name}=#{inspect(value)} is not an integer in 1..65535"
      end
  end
end

case System.get_env("ACCESS_EDGE_SERVICE") do
  service when service in [nil, ""] ->
    config :flux_vale, :access_edge,
      service: "traefik.traefik.svc.cluster.local",
      https_port: parse_port.("ACCESS_EDGE_HTTPS_PORT", 8444),
      http_port: parse_port.("ACCESS_EDGE_HTTP_PORT", 8080)

  service ->
    config :flux_vale, :access_edge,
      service: service,
      https_port: parse_port.("ACCESS_EDGE_HTTPS_PORT", 8444),
      http_port: parse_port.("ACCESS_EDGE_HTTP_PORT", 8080)
end

# Dotted-quad with octets in range — loose enough for any private
# service CIDR the fleet reserves from, strict enough that garbage
# cannot become a route.
valid_ipv4? = fn ip ->
  octets = String.split(ip, ".")

  Enum.count(octets) == 4 and
    Enum.all?(octets, fn octet ->
      Regex.match?(~r/\A\d{1,3}\z/, octet) and String.to_integer(octet) <= 255
    end)
end

# P3-11: the API base URL must be https and must carry no userinfo —
# every claims call rides a Bearer token in the Authorization header,
# and plain http would ship it in cleartext while a user:pass@host
# URL would confuse which credential authenticates what. Fail at boot;
# these are config typos, not runtime conditions.
valid_api_url? = fn url ->
  uri = URI.parse(url)
  uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and uri.userinfo == nil
end

case System.get_env("TAILSCALE_API_URL") do
  url when url in [nil, ""] ->
    :ok

  url ->
    if valid_api_url?.(url) do
      config :flux_vale, :tailscale_api, base_url: url
    else
      raise ArgumentError,
            "TAILSCALE_API_URL=#{inspect(url)} must be an https:// URL with no userinfo"
    end
end

case System.get_env("ACCESS_DNS_RESOLVER_IP") do
  ip when ip in [nil, ""] ->
    :ok

  ip ->
    unless valid_ipv4?.(ip) do
      raise ArgumentError, "ACCESS_DNS_RESOLVER_IP=#{inspect(ip)} is not an IPv4 address"
    end

    config :flux_vale, :access_dns, resolver_ip: ip
end

# #203: the idle-sleep threshold (ADR-0036's settled 1h default lives in
# config.exs). The E2E stack shortens it via the bootstrap — a real
# 1-hour wait would blow the suite's budget; the same override is the
# knob for any environment that wants a different promise. Test is
# excluded: a stray value in the suite's shell must not shorten every
# unit test's clock (the INSTANCES_SLUG_PREFIX stance).
if config_env() != :test do
  case System.get_env("IDLE_SLEEP_AFTER_SECONDS") do
    seconds when seconds in [nil, ""] ->
      :ok

    seconds ->
      case Integer.parse(seconds) do
        {parsed, ""} when parsed > 0 ->
          config :flux_vale, :idle_sleep_after_seconds, parsed

        _invalid ->
          raise ArgumentError,
                "IDLE_SLEEP_AFTER_SECONDS=#{inspect(seconds)} is not a positive integer"
      end
  end
end

# #210 part 3: the idle sweep's cadence (ADR-0036's settled */5 default
# lives in config.exs's crontab). The E2E bootstrap sets an
# every-minute sweep (and the timers CI leg a 45s threshold too), so
# a sleep lands within ~4 minutes (105s on the timers leg) instead
# of one ~8-minute cycle; the nightly full-cadence run keeps the
# real pair proven daily. Same stance as IDLE_SLEEP_AFTER_SECONDS:
# test excluded, invalid values raise at boot (Oban's parser would
# raise too, but the message wouldn't name the env var).
if config_env() != :test do
  case System.get_env("IDLE_SWEEP_CRONEXPR") do
    cron when cron in [nil, ""] ->
      :ok

    cron ->
      case Oban.Plugins.Cron.parse(cron) do
        {:ok, _expression} ->
          # Reslot ONLY the idle-sweep entry of the compiled crontab —
          # Application.get_env reads what config.exs already set by
          # the time runtime.exs evaluates; rebuilding the list here
          # would fork the other three entries' home. Both entry
          # shapes: Oban's crontab allows {expr, worker, opts}.
          oban_config = Application.get_env(:flux_vale, Oban, [])
          plugins = Keyword.get(oban_config, :plugins, [])

          plugins =
            Enum.map(plugins, fn
              {Oban.Plugins.Cron, opts} ->
                crontab = Keyword.get(opts, :crontab, [])

                crontab =
                  Enum.map(crontab, fn
                    {_expr, FluxVale.Workers.IdleInstanceSweep} ->
                      {cron, FluxVale.Workers.IdleInstanceSweep}

                    {_expr, FluxVale.Workers.IdleInstanceSweep, entry_opts} ->
                      {cron, FluxVale.Workers.IdleInstanceSweep, entry_opts}

                    entry ->
                      entry
                  end)

                {Oban.Plugins.Cron, Keyword.put(opts, :crontab, crontab)}

              plugin ->
                plugin
            end)

          config :flux_vale, Oban, plugins: plugins

        {:error, _exception} ->
          raise ArgumentError,
                "IDLE_SWEEP_CRONEXPR=#{inspect(cron)} is not a valid cron expression"
      end
  end
end

# Env-scoped slug prefix (#155): the deployed envs share the
# *.fluxvale.app wildcard and slug uniqueness is per cluster only, so a
# non-prod env prefixes its labels (staging: stg) and can never take a
# prod one; prod — unset, or "" (the classic empty-Secret shape) — mints
# bare labels. Invalid values raise at boot: a bad prefix would break
# every instance URL minted after it. Test is excluded (same as the
# Postmark/PromEx gates): a stray INSTANCES_SLUG_PREFIX in the suite's
# shell must not prefix every minted slug.
if config_env() != :test do
  case System.get_env("INSTANCES_SLUG_PREFIX") do
    value when value in [nil, ""] ->
      :ok

    value ->
      FluxVale.Infrastructure.Instance.GenerateSlug.validate_prefix!(value)
      config :flux_vale, :instances_slug_prefix, value
  end
end

case System.get_env("INSTANCE_RBAC_SA_NAMESPACE") do
  namespace when namespace in [nil, ""] ->
    :ok

  namespace ->
    rbac = Application.fetch_env!(:flux_vale, :instance_rbac)
    config :flux_vale, :instance_rbac, Keyword.put(rbac, :service_account_namespace, namespace)
end

# #196: which platform env this app is — namespace label at deploy,
# orphan-sweep scope (see config.exs). The label value must be a valid
# k8s label value; raise at boot rather than mint namespaces the sweep
# can't match. In :prod the env var is REQUIRED, not defaulted: staging
# and production deploy the same image simultaneously (ADR-0011) onto
# one shared cluster (ADR-0010) — an unset PLATFORM_ENV would default
# both envs to the same value and re-open the exact cross-env deletion
# this label exists to close. Test keeps the local default (same
# exclusion stance as INSTANCES_SLUG_PREFIX — a stray PLATFORM_ENV in
# the suite's shell must not flip every label assertion).
if config_env() != :test do
  case {config_env(), System.get_env("PLATFORM_ENV")} do
    {:prod, value} when value in [nil, ""] ->
      raise ArgumentError,
            "PLATFORM_ENV is required in production (staging | production): it scopes the " <>
              "instance-namespace label and the orphan sweep (#196) — unset, every env " <>
              "would claim the same namespaces"

    {_env, value} when value in [nil, ""] ->
      :ok

    {_env, value} ->
      # \z, not $ — PCRE's $ matches before a trailing newline, and a
      # value like "staging\n" (a mounted-Secret read) must fail HERE,
      # not at the k8s label rejection on the first deploy.
      unless value =~ ~r/^[a-zA-Z0-9]([a-zA-Z0-9._-]{0,61}[a-zA-Z0-9])?\z/ do
        raise ArgumentError,
              "PLATFORM_ENV=#{inspect(value)} is not a valid k8s label value — expected e.g. staging | production | local"
      end

      config :flux_vale, :platform_env, value
  end
end

# HitPay gateway (#136, ADR-0029): BWS-injected in the cluster
# (ADR-0021), never committed. Unset in dev/test — checkout answers
# {:error, :missing_config} and the top-up UI says so plainly; sandbox
# runs set real sandbox keys via env. base_url keeps config.exs's
# sandbox default unless overridden (production flips it when the
# registrations gate, #142, lifts).
case System.get_env("HITPAY_API_KEY") do
  nil -> :ok
  api_key -> config :flux_vale, :hitpay, api_key: api_key
end

case System.get_env("HITPAY_WEBHOOK_SALT") do
  nil -> :ok
  salt -> config :flux_vale, :hitpay, webhook_salt: salt
end

case System.get_env("HITPAY_BASE_URL") do
  base_url when base_url in [nil, ""] -> :ok
  base_url -> config :flux_vale, :hitpay, base_url: base_url
end

# Postmark mailer (ADR-0003 Am. 1, #165): POSTMARK_API_KEY moves delivery
# off the Local adapter (config.exs) onto Postmark's API. nil and "" (the
# classic empty-Secret shape) both mean unconfigured — a prod release
# without the token still boots; sign-in codes just never leave the box.
# The value is a Postmark *server* token, injected as env by the BWS
# operator (ADR-0021); env vars don't hot-reload, so rotation needs a
# pod restart. The adapter needs only api_key (prod.exs already sets
# Swoosh.ApiClient.Req); message_stream is a per-email provider option —
# unset sends Postmark's default outbound stream.
# test is excluded: test.exs pins Swoosh.Adapters.Test, and a stray
# exported key must not flip the suite onto a network adapter. dev is
# excluded too — config.exs pins Swoosh.Adapters.Local there, and a key
# exported in a dev shell must not flip dev's delivery shape onto the
# network (dev exercises the same local-mail shape staging adds a split
# to).
if config_env() not in [:test, :dev] do
  case System.get_env("POSTMARK_API_KEY") do
    key when key in [nil, ""] ->
      :ok

    api_key ->
      config :flux_vale, FluxVale.Mailer,
        adapter: Swoosh.Adapters.Postmark,
        api_key: api_key
  end
end

# TestInbox gate (#22, ADR-0003 Am. 2 / ADR-0023 Am. 3): dev/test enable
# via their config files; staging — the same prod-mode release as prod
# (ADR-0010) — flips this env var, and the recipient split then captures
# only test-account mail while Postmark delivers the humans'. Prod leaves
# it unset: the routes 404, which is the absent-under-prod contract.
#
# :local must flip with it: prod.exs sets it false (no storage in prod),
# but capture/serving run on Swoosh's Memory driver, and Swoosh's own
# application only starts its Storage.Manager when :local is true —
# without this line a TEST_INBOX_ENABLED release answers 500s (found
# live on staging by the #99 smoke: requests fine, reads crashed).
# Gated on the VALUE, not the env var's presence: "" / "false" (a
# classic empty-Secret shape) must not start storage on a prod release
# whose inbox stays disabled.
if System.get_env("TEST_INBOX_ENABLED") in ["true", "1"] do
  config :flux_vale, :test_inbox, enabled: true
  config :swoosh, :local, true
end

# The storybook workshop (#178): same gated-release shape as the
# TestInbox — staging (the same prod-mode release as prod, ADR-0010)
# flips it where the fleet attaches storybook.fluxvale.com; prod leaves
# it unset and /storybook 404s (= absent).
if System.get_env("STORYBOOK_ENABLED") in ["true", "1"] do
  config :flux_vale, :storybook_enabled, true
end

# The AshAdmin mount gate (#288, ADR-0027 §2): same gated-release shape
# — staging sets ADMIN_MOUNT_KEY (BWS-rendered env) to serve /admin;
# prod leaves it unset and /admin answers a bare 404. The value is a
# secret, never presented per-request (the credential is the
# platform-admin session behind the gate). Fail-closed parsing lives in
# the gate plug (AdminEnabled.enabled?/0 — the one answer the route and
# the socket re-check share): blank and off-intent literals stay off,
# so this pass-through stores whatever was set and the plug decides.
case System.get_env("ADMIN_MOUNT_KEY") do
  key when key in [nil, ""] -> :ok
  key -> config :flux_vale, :admin_mount_key, key
end

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
        ~r"lib/flux_vale_web/(controllers|live|components)/.*\.(ex|heex)$"E,
        # Storybook stories (#178) — reload the workshop on story edits
        ~r"storybook/.*\.exs$"E
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

  # The storybook host rides the same endpoint (#178): the LiveView
  # socket's Origin check would otherwise reject it (check_origin
  # defaults to PHX_HOST's origin only), leaving the workshop's UI
  # dead on its own hostname. Widened only while the gate is on.
  storybook_origins =
    if System.get_env("STORYBOOK_ENABLED") in ["true", "1"] do
      ["https://" <> (System.get_env("STORYBOOK_HOST") || "storybook.fluxvale.com")]
    else
      []
    end

  config :flux_vale, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :flux_vale, FluxValeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: ["https://" <> host | storybook_origins],
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

  # Mailer: delivery flips to Postmark when POSTMARK_API_KEY is set — the
  # env gate sits with the other optional-env cases above. prod.exs already
  # sets Swoosh.ApiClient.Req, the api_client the adapter needs.
end
