defmodule FluxVale.Infrastructure.Operations.InstanceK8sTest do
  # NOT async: the fail-loud arms mutate the :access_gateway application
  # env, which is global. It is restored in on_exit.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  # The provider seam must raise BEFORE its first write, not after the
  # route row lands: the cleanup clauses only handle error tuples, and
  # an idempotent retry would then report {:ok, existing} with no
  # cluster limb ever written (hostile review, fix round).
  test "attach raises on a missing namespace BEFORE the route row lands" do
    InstanceFixtures.local_cluster!()

    # Fixture scaffolding only: the provider raises before any cluster
    # limb, so nothing below the resolver is ever reached.
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)

    Application.put_env(:flux_vale, :access_gateway, image: "tailscale/tailscale:v1.90.6")

    assert_raise KeyError, ~r/key :namespace not found/, fn ->
      Tailscale.attach_instance(gateway, instance)
    end

    assert {:error, _no_route} =
             AccessRoute.get_by_instance(instance.id, authorize?: false)
  end

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

    test "a nil or empty namespace VALUE fails as loudly as a missing key" do
      # An env-var interpolation that yields nil is one deploy away;
      # fetch!/2 alone would happily return it.
      for value <- [nil, ""] do
        Application.put_env(:flux_vale, :access_gateway, namespace: value)

        assert_raise CaseClauseError, fn ->
          InstanceK8s.gateway_access_namespace()
        end
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
