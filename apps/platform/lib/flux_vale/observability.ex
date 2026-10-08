defmodule FluxVale.Observability do
  @moduledoc """
  Instrumentation wiring (#98, ADR-0012 Am. 1): OTEL tracing + the
  env-gated PromEx metrics tree.

  The env questions live here so runtime.exs and the supervision tree
  ask one module — the contract settled on the issue: PromEx on only in
  prod-shaped runs (`PROMEX_ENABLED`, fleet overlays), OTEL export on
  only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set (in-cluster Alloy;
  unset = spans are created, nothing ships).
  """

  alias OpentelemetryEcto
  alias OpentelemetryPhoenix

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
end
