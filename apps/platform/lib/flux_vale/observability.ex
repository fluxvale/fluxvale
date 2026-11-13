defmodule FluxVale.Observability do
  @moduledoc """
  Instrumentation wiring (#98, ADR-0012 Am. 1): OTEL tracing + the
  env-gated PromEx metrics tree, plus the PostHog error-tracking
  wiring (ADR-0049) — one env var, POSTHOG_API_KEY, arms everything.

  The env questions live here so runtime.exs and the supervision tree
  ask one module — the contract settled on the issue: PromEx on only in
  prod-shaped runs (`PROMEX_ENABLED`, fleet overlays), OTEL export on
  only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set (in-cluster Alloy;
  unset = spans are created, nothing ships).
  """

  alias OpentelemetryEcto
  alias OpentelemetryPhoenix

  # The source-context keys live in the :posthog app env (config.exs) —
  # the same keys `mix posthog.package_source_code` reads; the supervisor
  # carries the identical values so the packaged map and the runtime
  # lookup agree. validate!/1 is the authority on the assembled map
  # (ADR-0049). No exclude-pattern key: mix release cannot serialize
  # Regex config terms, so config.exs scopes the root to lib/ instead
  # (#714, the red-main lesson).
  @posthog_source_context_keys [
    :enable_source_code_context,
    :root_source_code_paths,
    :context_lines
  ]

  # The Bandit adapter's header-capture list (lowercase per its schema):
  # the request span gets these as `http.request.header.*` attributes,
  # the fallback the SDK's span processor reads when process context is
  # empty.
  @posthog_tracing_headers ["x-posthog-session-id", "x-posthog-distinct-id"]

  # The exporter-gated trace chain (ADR-0012 Am. 1): runtime.exs arms this
  # tuple only when the OTLP endpoint env is set.
  @otel_batch_processor {:otel_batch_processor, %{exporter: {:otel_exporter_traces_otlp, %{}}}}

  @doc """
  True when the PromEx metrics tree should start (prod-shaped runs via
  PROMEX_ENABLED; test.exs pins the answer off).
  """
  @spec prom_ex_enabled?() :: boolean()
  def prom_ex_enabled?, do: System.get_env("PROMEX_ENABLED") in ~w(true 1)

  @doc """
  True when an OTLP endpoint is configured — the app pushes spans to
  the in-cluster Alloy receiver (the exporter reads the standard env
  itself, including OTEL_SERVICE_NAME for the resource).
  """
  @spec otel_exporter_on?() :: boolean()
  def otel_exporter_on?, do: match?({:ok, _}, System.fetch_env("OTEL_EXPORTER_OTLP_ENDPOINT"))

  @doc """
  PromEx child spec for the application supervisor — an empty list
  keeps the tree honest about what is actually running.
  """
  @spec prom_ex_child() :: [module()]
  def prom_ex_child do
    if Application.get_env(:flux_vale, :prom_ex_enabled, false), do: [FluxVale.PromEx], else: []
  end

  @doc """
  The business-counter zero-seed child — same gate as
  prom_ex_child/0 (pointless without the tree) and a sibling
  ordered right after it: children start sequentially, so the seed
  runs once per boot with the PromEx handlers attached.
  """
  @spec seed_business_counters_child() :: [module()]
  def seed_business_counters_child do
    if Application.get_env(:flux_vale, :prom_ex_enabled, false),
      do: [FluxVale.PromEx.SeedBusinessCounters],
      else: []
  end

  @doc """
  The PostHog Cloud EU question (ADR-0049): one env var, POSTHOG_API_KEY,
  arms everything — the supervision tree, the Logger handler, and the
  request plugs.

  `nil`, `""`, or whitespace-only (the classic empty-Secret shapes) is
  `:unset`: nothing starts at all, and that is the deliberate default
  in every environment until the fleet repo flips the var (this slice
  ships inert). The trim matters: the SDK trims the key itself, so a
  whitespace-only value would half-arm the tree while sending nothing.
  The api host is the EU cloud per the ADR's region decision. Error
  tracking is default-on via the Logger handler at the SDK's default
  capture level (:error) — that is the DECISION, so there is
  deliberately no disable dial here.
  """
  @spec posthog_config() :: :unset | {:ok, map()}
  def posthog_config do
    case System.get_env("POSTHOG_API_KEY") do
      key when key in [nil, ""] ->
        :unset

      api_key ->
        case String.trim(api_key) do
          "" -> :unset
          trimmed -> {:ok, armed_config(trimmed)}
        end
    end
  end

  defp armed_config(api_key) do
    %{
      api_host: "https://eu.i.posthog.com",
      api_key: api_key,
      in_app_otp_apps: [:flux_vale],
      capture_level: :error,
      metadata: [:request_id]
    }
  end

  @doc """
  PostHog child spec for the application supervisor — an empty list
  keeps the tree honest about what is actually running (the
  prom_ex_child/0 shape). The armed map is assembled with config.exs's
  source-context keys and validated through PostHog.Config.validate!/1
  before the SDK's supervisor sees it — validate!/1 is the authority on
  the map's shape (it fills defaults and resolves in_app_modules).
  """
  @spec posthog_children() :: [{module(), map()}]
  def posthog_children do
    if Application.get_env(:flux_vale, :posthog) do
      [{PostHog.Supervisor, posthog_runtime_config()}]
    else
      []
    end
  end

  @doc """
  The OpenTelemetry processors under the OTLP exporter gate: the batch
  processor, with the PostHog context processor prepended when the
  PostHog tree is configured.

  Prepend is the SDK's contract — its processor documents "before the
  existing export processors". It stamps person and session ids onto
  spans so PostHog traces correlate to the signed-in person (ADR-0049
  D1). Unarmed, the chain is exactly the pre-PostHog one.

  The default reads the app env (the boot truth). runtime.exs passes the
  env answer explicitly: it assembles config before `config :flux_vale,
  :posthog` reaches the app env.
  """
  @spec otel_processors() :: list()
  @spec otel_processors(boolean()) :: list()
  def otel_processors(configured? \\ posthog_configured?()) do
    if configured? do
      [
        {PostHog.OpenTelemetry.ContextSpanProcessor, %{supervisor_name: PostHog}},
        @otel_batch_processor
      ]
    else
      [@otel_batch_processor]
    end
  end

  @doc """
  Bandit adapter options — the PostHog tracing headers when the tree is
  configured, `[]` otherwise.

  opentelemetry_bandit 0.3.0 supports `request_headers` (verified in the
  pinned adapter's schema and docs), so a fetch/XHR request span carries
  the header fallback the SDK's processor reads: correlation covers that
  request span too, not only child spans. Header names are lowercase per
  the adapter, and header-sourced ids are client-controlled (process
  context wins for child spans). Document navigations carry no tracing
  headers. An adapter bump that drops the option fails loudly at boot
  (NimbleOptions validation), not silently.
  """
  @spec bandit_setup_opts() :: keyword()
  def bandit_setup_opts do
    if posthog_configured?(), do: [request_headers: @posthog_tracing_headers], else: []
  end

  @doc """
  Attaches the request/query tracing handlers (called once at boot).
  """
  @spec setup_instrumentation() :: :ok
  def setup_instrumentation do
    # The bandit handler owns the server span (adapter-matched per the
    # opentelemetry_phoenix docs — without it, HTTP requests produce no
    # spans); opentelemetry_phoenix layers router/LiveView events onto it.
    OpentelemetryBandit.setup(bandit_setup_opts())
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:flux_vale, :repo])

    :ok
  end

  @doc """
  Attaches the PostHog error-tracking Logger handler (called once at
  boot, right after setup_instrumentation/0). Unset adds no handler:
  the handler IS error tracking (the always-on ADR-0049 decision), and
  its config is the same validated map the supervision tree carries —
  the SDK's own auto-start wires it the same way (PostHog.Application).
  """
  @spec setup_posthog() :: :ok
  def setup_posthog do
    case Application.get_env(:flux_vale, :posthog) do
      nil ->
        :ok

      _armed ->
        # Deliberate discard wrapping to :ok — :logger.add_handler/3 can
        # answer {error, _}; an attach failure on a misconfigured armed
        # boot surfaces in the handler-config probe (test) and review,
        # not as a boot crash on the happy path.
        :logger.add_handler(:posthog, PostHog.Handler, %{config: posthog_runtime_config()})

        :ok
    end
  end

  # The boot/tree truth: runtime.exs applies this only after the file
  # finishes, so otel_processors/1 takes the env answer separately.
  defp posthog_configured?, do: Application.get_env(:flux_vale, :posthog) != nil

  # The supervisor-facing assembly: the armed map (runtime.exs) with
  # config.exs's :posthog source-context keys merged in, then validate!/1
  # — it rejects unknown keys and nil values alike, so only keys actually
  # set are merged.
  defp posthog_runtime_config do
    armed = Application.fetch_env!(:flux_vale, :posthog)
    options = Map.to_list(armed) ++ posthog_source_context_opts()

    PostHog.Config.validate!(options)
  end

  defp posthog_source_context_opts do
    Enum.flat_map(@posthog_source_context_keys, fn key ->
      case Application.get_env(:posthog, key) do
        nil -> []
        value -> [{key, value}]
      end
    end)
  end
end
