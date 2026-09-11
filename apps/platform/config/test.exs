import Config
config :flux_vale, token_signing_secret: "fQ9tibmTqr1r2HdqiKrkOofKnY6OQDNK"
config :bcrypt_elixir, log_rounds: 1
config :ash, disable_async?: true

# Cache-off (#26): every test reads the access_rules table directly —
# instantly consistent, and no test ever reads through the cache process
# (which sits outside the SQL sandbox). The cache has its own dedicated
# test with the TTL enabled per-case.
config :flux_vale, access_rules_cache_ttl_seconds: 0

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :flux_vale, FluxVale.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "flux_vale_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :flux_vale, FluxValeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "lFp+naePZvFguRNIJ3gkEqmbbbm8si/dA5t8la7Ojp733r2Al06iwWrUv+aRrgA7",
  server: false

# In test we don't send emails
config :flux_vale, FluxVale.Mailer, adapter: Swoosh.Adapters.Test

# Oban: run enqueued jobs inline during tests — the testing engine needs
# no jobs table and cron never fires inside a test run (v1's posture)
config :flux_vale, Oban, testing: :inline

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The gated TestInbox (#22) — enabled so the recipient-split and endpoint
# tests exercise the real config; the Swoosh.Test adapter stays the
# configured delivery path for non-test-account mail.
config :flux_vale, :test_inbox, enabled: true
