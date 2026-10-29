defmodule FluxVale.Infrastructure.NamespacesTest do
  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Infrastructure.InstanceK8s
  alias FluxVale.Infrastructure.Tailscale

  describe "access_namespace resolver split-brain fix" do
    test "both resolvers return the same value when the key exists" do
      namespace = "fluxvale-access"

      # Mock Application.fetch_env! to return the configured namespace
      expect(Application, :fetch_env!, fn
        :flux_vale, :access_gateway -> {:ok, [namespace: namespace]}
      end)

      stub(Application, :get_env, fn :flux_vale, :access_gateway, [] ->
        [namespace: namespace]
      end)

      # Clear any cached state
      Process.unregister(:access_namespace, dead: true)
      Process.unregister(:access_namespace_cached, dead: true)

      assert InstanceK8s.gateway_access_namespace() == namespace
      assert Tailscale.access_namespace() == namespace
    end

    test "both resolvers raise on missing config key (fail-loud)" do
      # Remove the key from runtime config
      Application.delete_env(:flux_vale, :access_gateway)

      # Clear any cached state
      Process.unregister(:access_namespace, dead: true)
      Process.unregister(:access_namespace_cached, dead: true)

      assert_raise KeyError, ~r/key :namespace not found in :access_gateway config/, fn ->
        InstanceK8s.gateway_access_namespace()
      end

      assert_raise KeyError, ~r/key :namespace not found in :access_gateway config/, fn ->
        Tailscale.access_namespace()
      end
    end

    test "provider re-uses InstanceK8s resolver via delegation" do
      # Verify the provider calls the instance-side resolver for the shared namespace
      namespace = "fluxvale-access"

      stub(Application, :get_env, fn :flux_vale, :access_gateway, [] ->
        [namespace: namespace]
      end)

      Process.unregister(:access_namespace, dead: true)
      Process.unregister(:access_namespace_cached, dead: true)

      assert Tailscale.access_namespace() == namespace
    end
  end
end
