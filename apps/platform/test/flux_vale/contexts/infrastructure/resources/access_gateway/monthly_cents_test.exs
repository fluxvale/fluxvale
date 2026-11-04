defmodule FluxVale.Infrastructure.AccessGateway.MonthlyCentsTest do
  @moduledoc """
  #395's rate accessor: the one RUNTIME reader of the gateway's
  configured monthly price, mirroring `AccessDomain.monthly_cents/0`
  (same shape, same fail-closed missing-config, missing-key and
  mispriced-config behavior).
  """

  use FluxVale.DataCase, async: false

  # async: false — the override/mispriced tests below mutate the global
  # :access_gateway app env, which every concurrent gateway create reads
  # through the accessor (money paths fail closed), so a raced window
  # fails unrelated creates. They must not run against sibling modules
  # (the HealthControllerTest :build_sha stance).

  alias FluxVale.Infrastructure.AccessGateway

  describe "monthly_cents/0" do
    test "returns the configured rate" do
      configured = Application.fetch_env!(:flux_vale, :access_gateway)[:monthly_cents]

      assert AccessGateway.monthly_cents() == configured
    end

    test "follows a config override" do
      previous = Application.get_env(:flux_vale, :access_gateway)

      on_exit(fn -> Application.put_env(:flux_vale, :access_gateway, previous) end)

      Application.put_env(
        :flux_vale,
        :access_gateway,
        Keyword.put(previous, :monthly_cents, 777)
      )

      assert AccessGateway.monthly_cents() == 777
    end

    test "a mispriced config is a configuration error — money paths fail closed" do
      previous = Application.get_env(:flux_vale, :access_gateway)

      on_exit(fn -> Application.put_env(:flux_vale, :access_gateway, previous) end)

      for bad <- [0, -1, "free"] do
        Application.put_env(
          :flux_vale,
          :access_gateway,
          Keyword.put(previous, :monthly_cents, bad)
        )

        assert_raise ArgumentError, ~r/must be a positive integer/, fn ->
          AccessGateway.monthly_cents()
        end
      end
    end

    test "a missing config fails closed (fetch_env!/2's ArgumentError)" do
      previous = Application.get_env(:flux_vale, :access_gateway)

      on_exit(fn -> Application.put_env(:flux_vale, :access_gateway, previous) end)

      Application.delete_env(:flux_vale, :access_gateway)

      assert_raise ArgumentError, fn ->
        AccessGateway.monthly_cents()
      end
    end

    test "a config without the key fails closed (Keyword.fetch!/2's KeyError)" do
      previous = Application.get_env(:flux_vale, :access_gateway)

      on_exit(fn -> Application.put_env(:flux_vale, :access_gateway, previous) end)

      Application.put_env(:flux_vale, :access_gateway, Keyword.delete(previous, :monthly_cents))

      assert_raise KeyError, fn ->
        AccessGateway.monthly_cents()
      end
    end
  end
end
