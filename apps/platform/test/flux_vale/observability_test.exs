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

  describe "seed_business_counters_child/0" do
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

    test "no child when PromEx is disabled (the seeder is pointless without the tree)" do
      Application.put_env(:flux_vale, :prom_ex_enabled, false)

      assert Observability.seed_business_counters_child() == []
    end

    test "the zero-seed Task when PromEx is enabled" do
      Application.put_env(:flux_vale, :prom_ex_enabled, true)

      assert Observability.seed_business_counters_child() == [
               FluxVale.PromEx.SeedBusinessCounters
             ]
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

  describe "posthog_config/0" do
    test "unset when POSTHOG_API_KEY is absent (the suite's shape)" do
      with_env("POSTHOG_API_KEY", nil, fn ->
        assert Observability.posthog_config() == :unset
      end)
    end

    test "unset when POSTHOG_API_KEY is empty (the classic empty-Secret shape)" do
      with_env("POSTHOG_API_KEY", "", fn ->
        assert Observability.posthog_config() == :unset
      end)
    end

    test "armed: the EU host, the app's OTP modules, error-level capture" do
      with_env("POSTHOG_API_KEY", "phc_test_posthog_key", fn ->
        assert Observability.posthog_config() ==
                 {:ok,
                  %{
                    api_host: "https://eu.i.posthog.com",
                    api_key: "phc_test_posthog_key",
                    in_app_otp_apps: [:flux_vale],
                    capture_level: :error,
                    metadata: [:request_id],
                    enable_error_tracking: true
                  }}
      end)
    end
  end

  describe "posthog_children/0" do
    setup do
      original = Application.get_env(:flux_vale, :posthog)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:flux_vale, :posthog)
          value -> Application.put_env(:flux_vale, :posthog, value)
        end
      end)

      :ok
    end

    test "no children when unarmed (the dev/test shape)" do
      Application.delete_env(:flux_vale, :posthog)

      assert Observability.posthog_children() == []
    end

    test "the SDK supervisor over the validated config when armed" do
      with_env("POSTHOG_API_KEY", "phc_test_posthog_key", fn ->
        {:ok, cfg} = Observability.posthog_config()
        Application.put_env(:flux_vale, :posthog, cfg)

        assert [{PostHog.Supervisor, config}] = Observability.posthog_children()

        # validate!/1's normalized map is the authority — these pin OUR
        # inputs and the source-context merge; the rest is the SDK's own
        # defaults (supervisor_name, enabled, api_client, …).
        assert config.api_host == "https://eu.i.posthog.com"
        assert config.in_app_otp_apps == [:flux_vale]
        assert config.capture_level == :error
        assert config.metadata == [:request_id]
        assert config.enable_source_code_context
        assert config.root_source_code_paths == [File.cwd!()]
        assert config.context_lines == 5
        # in_app_modules is what validate!/1 computes from in_app_otp_apps.
        assert MapSet.member?(config.in_app_modules, FluxVale.Observability)
        # The convenience key never reaches the supervisor options.
        refute Map.has_key?(config, :enable_error_tracking)
      end)
    end

    test "unset source-context keys are not merged — the schema defaults fill in" do
      keys = [:enable_source_code_context, :root_source_code_paths, :context_lines]

      originals =
        Map.new(keys, fn key -> {key, Application.get_env(:posthog, key)} end)

      on_exit(fn ->
        Enum.each(originals, fn
          {key, nil} -> Application.delete_env(:posthog, key)
          {key, value} -> Application.put_env(:posthog, key, value)
        end)
      end)

      Enum.each(keys, &Application.delete_env(:posthog, &1))

      with_env("POSTHOG_API_KEY", "phc_test_posthog_key", fn ->
        {:ok, cfg} = Observability.posthog_config()
        Application.put_env(:flux_vale, :posthog, cfg)

        assert [{PostHog.Supervisor, config}] = Observability.posthog_children()

        # The nil-drop arm ran (nothing to merge); validate!/1 backfills
        # the SDK schema defaults: source context off, no paths, 5 lines.
        refute config.enable_source_code_context
        assert config.root_source_code_paths == []
        assert config.context_lines == 5
      end)
    end
  end

  describe "setup_posthog/0" do
    setup do
      original = Application.get_env(:flux_vale, :posthog)

      on_exit(fn ->
        # The armed arm attaches a VM-global Logger handler — remove it
        # even if the test raised before its own cleanup. Harmless if
        # never attached ({:error, :not_found}).
        :logger.remove_handler(:posthog)

        case original do
          nil -> Application.delete_env(:flux_vale, :posthog)
          value -> Application.put_env(:flux_vale, :posthog, value)
        end
      end)

      :ok
    end

    test "no Logger handler when unarmed (the honest default arm — the suite runs unarmed)" do
      Application.delete_env(:flux_vale, :posthog)

      assert :ok = Observability.setup_posthog()
      assert match?({:error, _}, :logger.get_handler_config(:posthog))
    end

    test "the PostHog handler over the validated config when armed" do
      # Arming here stays network-free WITHOUT starting the supervision
      # tree: with no Registry, the SDK's Sender finds no senders and
      # drops any event the handler would see (PostHog.Registry.config/1
      # falls back to a disabled config).
      with_env("POSTHOG_API_KEY", "phc_test_posthog_key", fn ->
        {:ok, cfg} = Observability.posthog_config()
        Application.put_env(:flux_vale, :posthog, cfg)

        assert :ok = Observability.setup_posthog()

        {:ok, handler} = :logger.get_handler_config(:posthog)
        assert handler.module == PostHog.Handler

        # The handler's private config (:config in add_handler) IS the
        # validated map — defaults filled, in_app_modules resolved — the
        # same map PostHog.Handler.log/2 destructures.
        assert handler.config.supervisor_name == PostHog
        assert handler.config.enabled
      end)
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
