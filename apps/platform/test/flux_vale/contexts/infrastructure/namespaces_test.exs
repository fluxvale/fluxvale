defmodule FluxVale.Infrastructure.NamespacesTest do
  # NOT async: the fail-loud arms mutate the :access_gateway application
  # env, which is global. It is restored in on_exit.
  use FluxVale.DataCase, async: false

  alias FluxVale.Infrastructure.Operations.InstanceK8s

  setup do
    original = Application.fetch_env(:flux_vale, :access_gateway)
    on_exit(fn -> restore(original) end)
    :ok
  end

  defp restore({:ok, value}), do: Application.put_env(:flux_vale, :access_gateway, value)
  defp restore(:error), do: Application.delete_env(:flux_vale, :access_gateway)

  describe "gateway_access_namespace/0" do
    test "returns the configured namespace" do
      Application.put_env(:flux_vale, :access_gateway, namespace: "fluxvale-access")

      assert InstanceK8s.gateway_access_namespace() == "fluxvale-access"
    end

    test "the config value wins — no hardcoded fallback" do
      Application.put_env(:flux_vale, :access_gateway, namespace: "a-different-ns")

      assert InstanceK8s.gateway_access_namespace() == "a-different-ns"
    end

    test "raises rather than admitting into a default when the key is missing" do
      # Carried finding #1: a silent "fluxvale-access" fallback admitted the
      # peer into one namespace while the Deployment went elsewhere, so
      # every reconfigure severed reachability. Fail loudly instead.
      Application.put_env(:flux_vale, :access_gateway, image: "tailscale/tailscale:v1.90.6")

      assert_raise KeyError, ~r/key :namespace not found/, fn ->
        InstanceK8s.gateway_access_namespace()
      end
    end

    test "raises when the config block is absent entirely" do
      # A missing block is ArgumentError from fetch_env!/2; a missing key
      # inside a block is KeyError. Both fail loudly — neither falls back.
      Application.delete_env(:flux_vale, :access_gateway)

      assert_raise ArgumentError, ~r/:access_gateway/, fn ->
        InstanceK8s.gateway_access_namespace()
      end
    end
  end
end
