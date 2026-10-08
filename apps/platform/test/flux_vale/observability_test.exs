defmodule FluxVale.ObservabilityTest do
  @moduledoc false

  # async: false — the request-span test swaps the batch exporter
  # (VM-global state, see FluxVale.TestSupport.Tracing).
  use FluxValeWeb.ConnCase, async: false

  # The global mutations in the env tests (env vars, the
  # :prom_ex_enabled app env) are captured and restored via on_exit.

  alias FluxVale.Observability
  alias FluxVale.TestSupport.Tracing

  describe "prom_ex_enabled?/0" do
    test "off unless PROMEX_ENABLED says true" do
      with_env("PROMEX_ENABLED", nil, fn ->
        refute Observability.prom_ex_enabled?()
      end)

      with_env("PROMEX_ENABLED", "false", fn ->
        refute Observability.prom_ex_enabled?()
      end)
    end

    test "on for true/1" do
      with_env("PROMEX_ENABLED", "true", fn ->
        assert Observability.prom_ex_enabled?()
      end)

      with_env("PROMEX_ENABLED", "1", fn ->
        assert Observability.prom_ex_enabled?()
      end)
    end
  end

  describe "otel_exporter_on?/0" do
    test "off when no OTLP endpoint is configured (dev/test shape)" do
      with_env("OTEL_EXPORTER_OTLP_ENDPOINT", nil, fn ->
        refute Observability.otel_exporter_on?()
      end)
    end

    test "on when the OTLP endpoint env is present" do
      with_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://alloy:4318", fn ->
        assert Observability.otel_exporter_on?()
      end)
    end
  end

  describe "prom_ex_child/0" do
    setup do
      original = Application.get_env(:flux_vale, :prom_ex_enabled)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:flux_vale, :prom_ex_enabled)
          value -> Application.put_env(:flux_vale, :prom_ex_enabled, value)
        end
      end)

      :ok
    end

    test "no children when disabled (the dev/test shape)" do
      Application.put_env(:flux_vale, :prom_ex_enabled, false)

      assert Observability.prom_ex_child() == []
    end

    test "the PromEx supervision tree when enabled" do
      Application.put_env(:flux_vale, :prom_ex_enabled, true)

      assert Observability.prom_ex_child() == [FluxVale.PromEx]
    end
  end

  describe "setup_instrumentation/0" do
    test "the request and query tracing handlers are attached at boot" do
      handlers = :telemetry.list_handlers([])
      handler_ids = Enum.map(handlers, & &1.id)

      assert Enum.any?(handler_ids, &match?({OpentelemetryBandit, _}, &1))
      assert {OpentelemetryPhoenix, :router_dispatch_start} in handler_ids
      assert {OpentelemetryEcto, [:flux_vale, :repo, :query]} in handler_ids
    end

    test "a real HTTP request exports a server span" do
      # The bandit instrumentation is what turns HTTP requests into
      # spans — ConnTest dispatches around Bandit entirely, so assert
      # against a real listener, not just handler attachment.
      Tracing.export_spans_to(self())

      on_exit(fn ->
        Tracing.restore()
      end)

      {:ok, server} =
        start_supervised({Bandit, scheme: :http, plug: FluxValeWeb.Endpoint, port: 0})

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      assert %{status: 200} = Req.get!("http://127.0.0.1:#{port}/health")

      # the phoenix instrumentation renames the bandit span to the route
      span = Tracing.span_matching("GET /health", :"http.request.method", :GET)

      assert Tracing.attribute_map(span)[:"url.path"] == "/health"
    end
  end

  defp with_env(name, value, fun) do
    original = System.get_env(name)

    on_exit(fn ->
      case original do
        nil -> System.delete_env(name)
        set -> System.put_env(name, set)
      end
    end)

    case value do
      nil -> System.delete_env(name)
      set -> System.put_env(name, set)
    end

    fun.()
  end
end
