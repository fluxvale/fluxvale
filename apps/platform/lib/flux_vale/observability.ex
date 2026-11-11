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

  # `enable_error_tracking` is a *convenience* option — only the SDK's own
  # auto-start reads it, and `config :posthog, enable: false` (config.exs)
  # keeps that off; the supervisor schema rejects unknown keys, so it is
  # dropped before PostHog.Config.validate!/1 sees the assembled options.
  @posthog_convenience_keys [:enable_error_tracking]
  # The source-context keys live in the :posthog app env (config.exs) —
  # the same keys `mix posthog.package_source_code` reads. validate!/1 is
  # the authority on the assembled map (ADR-0049).
  @posthog_source_context_keys [
    :enable_source_code_context,
    :root_source_code_paths,
    :context_lines
  ]

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

  `nil` or `""` (the classic empty-Secret shape) is `:unset`: nothing
  starts at all, and that is the deliberate default in every environment
  until the fleet repo flips the var (this slice ships inert). The api
  host is the EU cloud per the ADR's region decision. Error tracking is
  default-on via the Logger handler at the SDK's default capture level
  (:error) — that is the DECISION, so there is deliberately no disable
  dial here.
  """
  @spec posthog_config() :: :unset | {:ok, map()}
  def posthog_config do
    case System.get_env("POSTHOG_API_KEY") do
      key when key in [nil, ""] ->
        :unset

      api_key ->
        {:ok,
         %{
           api_host: "https://eu.i.posthog.com",
           api_key: api_key,
           in_app_otp_apps: [:flux_vale],
           capture_level: :error,
           metadata: [:request_id],
           # Documents the always-on error-tracking decision; dropped at
           # assembly time (see @posthog_convenience_keys).
           enable_error_tracking: true
         }}
    end
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
  Attaches the request/query tracing handlers (called once at boot).
  """
  @spec setup_instrumentation() :: :ok
  def setup_instrumentation do
    # The bandit handler owns the server span (adapter-matched per the
    # opentelemetry_phoenix docs — without it, HTTP requests produce no
    # spans); opentelemetry_phoenix layers router/LiveView events onto it.
    OpentelemetryBandit.setup()
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
        :logger.add_handler(:posthog, PostHog.Handler, %{config: posthog_runtime_config()})
    end
  end

  # The supervisor-facing assembly: the armed map (runtime.exs) with
  # config.exs's :posthog source-context keys merged in and the
  # convenience-only key dropped, then validate!/1 — it rejects unknown
  # keys and nil values alike, so only keys actually set are merged.
  defp posthog_runtime_config do
    armed = Application.fetch_env!(:flux_vale, :posthog)
    supervisor_only = Map.drop(armed, @posthog_convenience_keys)
    options = Map.to_list(supervisor_only) ++ posthog_source_context_opts()

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
