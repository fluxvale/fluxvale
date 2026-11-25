defmodule FluxVale.Infrastructure.Operations.ClaimUnclaimedDomainsTest do
  @moduledoc """
  The claim sweep (#760): claims a gateway's verified-but-unclaimed
  custom domains, skips the ones already held, summarises refusals
  instead of raising, and renders once when something landed.
  """

  # async: false — the claim reads the global :access_dns app env.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.Operations.ClaimUnclaimedDomains
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.Infrastructure.Operations.SyncInstanceUrlEnv
  alias FluxVale.Infrastructure.Operations.VerifyAccessDomains
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @resolver_ip "10.43.0.20"

  setup do
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(RenderAccessDNS, :call, fn -> :ok end)
    stub(RenderAccessDNS, :call, fn _opts -> :ok end)

    previous = Application.get_env(:flux_vale, :access_dns)
    Application.put_env(:flux_vale, :access_dns, resolver_ip: @resolver_ip)
    on_exit(fn -> Application.put_env(:flux_vale, :access_dns, previous) end)

    {org, owner} = BillingFixtures.grant_free_org!()

    {:ok, org: org, owner: owner}
  end

  test "claims the org's verified, unclaimed domains and renders once", %{org: org} do
    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(org, "apps.customer.com")

    expect(RenderAccessDNS, :call, fn -> :ok end)

    stub(Tailscale, :claim_domain, fn gw, name, resolver_ip ->
      assert gw.id == gateway.id
      assert name == "apps.customer.com"
      assert resolver_ip == @resolver_ip
      {:ok, %{device_id: "device-1", route: "10.43.0.20/32"}}
    end)

    assert %{claimed: ["apps.customer.com"], failed: []} =
             ClaimUnclaimedDomains.call(gateway)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.dns_claims[domain.domain]["ip"] == @resolver_ip
  end

  test "skips a domain the gateway already holds", %{org: org} do
    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(org, "apps.customer.com")

    {:ok, claimed} =
      AccessGateway.update_claims(
        gateway,
        %{dns_claims: %{domain.domain => %{"ip" => @resolver_ip, "tailnet" => "example.ts.net"}}},
        authorize?: false
      )

    stub(Tailscale, :claim_domain, fn _gw, _name, _ip -> flunk("already claimed") end)

    assert %{claimed: [], failed: []} = ClaimUnclaimedDomains.call(claimed)
  end

  test "a domains filter narrows the sweep to the rows it was given", %{org: org} do
    gateway = AccessFixtures.gateway!(org)
    wanted = verified_domain!(org, "apps.customer.com")
    _other = verified_domain!(org, "files.customer.com")

    stub(Tailscale, :claim_domain, fn _gw, name, _ip ->
      assert name == "apps.customer.com"
      {:ok, %{device_id: "device-1", route: "10.43.0.20/32"}}
    end)

    assert %{claimed: ["apps.customer.com"], failed: []} =
             ClaimUnclaimedDomains.call(gateway, domains: [wanted])
  end

  test "a refusal is summarised, not raised, and neither render nor claim lands", %{org: org} do
    gateway = AccessFixtures.gateway!(org)
    verified_domain!(org, "apps.customer.com")

    stub(Tailscale, :claim_domain, fn _gw, _name, _ip -> {:error, :tailnet_down} end)
    reject(&RenderAccessDNS.call/0)

    assert %{claimed: [], failed: [{"apps.customer.com", :tailnet_down}]} =
             ClaimUnclaimedDomains.call(gateway)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.dns_claims in [nil, %{}]
  end

  test "no verified domain is a quiet no-op", %{org: org} do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :claim_domain, fn _gw, _name, _ip -> flunk("nothing to claim") end)

    assert %{claimed: [], failed: []} = ClaimUnclaimedDomains.call(gateway)
  end

  test "a crashing provider is caught and reported as a sweep failure", %{org: org} do
    gateway = AccessFixtures.gateway!(org)
    verified_domain!(org, "apps.customer.com")

    stub(Tailscale, :claim_domain, fn _gw, _name, _ip -> raise "tailnet exploded" end)

    assert %{claimed: [], failed: [{:sweep, _error}]} = ClaimUnclaimedDomains.call(gateway)
  end

  describe "the URL-env sync hook (the address re-tell)" do
    test "each landed claim syncs the domain's serving instances", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      domain = verified_domain!(org, "apps.customer.com")
      instance = serving_instance!(org, owner)

      # The population shrunk to one (the selector is the shared seam;
      # its own selection is the verify suite's subject).
      stub(VerifyAccessDomains, :serving_instances, fn claimed ->
        assert claimed.id == domain.id
        [instance]
      end)

      stub(Tailscale, :claim_domain, fn _gw, _name, _ip ->
        {:ok, %{device_id: "device-1", route: "10.43.0.20/32"}}
      end)

      # Two passes re-tell the instance, both by design: the claim's own
      # success arm (the nested caller runs the hooks) and the sweep's
      # post-reduce pass — the second is the sync's no-op by contract.
      expect(SyncInstanceUrlEnv, :call, 2, fn synced ->
        assert synced.id == instance.id
        :ok
      end)

      assert %{claimed: ["apps.customer.com"], failed: []} = ClaimUnclaimedDomains.call(gateway)
    end

    test "a sync failure is warn-only — the claim still lands", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      domain = verified_domain!(org, "apps.customer.com")
      instance = serving_instance!(org, owner)

      stub(VerifyAccessDomains, :serving_instances, fn _claimed -> [instance] end)
      stub(SyncInstanceUrlEnv, :call, fn _instance -> {:error, :boom} end)

      stub(Tailscale, :claim_domain, fn _gw, _name, _ip ->
        {:ok, %{device_id: "device-1", route: "10.43.0.20/32"}}
      end)

      assert %{claimed: ["apps.customer.com"], failed: []} = ClaimUnclaimedDomains.call(gateway)

      row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert row.dns_claims[domain.domain]["ip"] == @resolver_ip
    end
  end

  # A private, attached, running instance — the sync's subject shape.
  # (The create resolves the single cluster row, so the row exists.)
  defp serving_instance!(org, owner) do
    InstanceFixtures.local_cluster!()
    {_org, _wallet} = BillingFixtures.funded_wallet!(org: org)
    AccessFixtures.private_instance!(org, owner)
  end

  # Seed, not register: the sweep's subject is the registry read and the
  # claim limbs; registration's issuance is covered by its own suites.
  defp verified_domain!(org, name) do
    Ash.Seed.seed!(AccessDomain, %{
      domain: name,
      kind: :custom,
      state: :verified,
      organization_id: org.id,
      cert_secret_ref: "cert-secret"
    })
  end
end
