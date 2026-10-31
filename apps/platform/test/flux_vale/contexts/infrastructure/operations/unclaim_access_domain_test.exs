defmodule FluxVale.Infrastructure.Operations.UnclaimAccessDomainTest do
  @moduledoc """
  The member-scoped unclaim (ADR-0040 §3's mirror): provider unclaim,
  then the row's claims lose the entry. Provider failure leaves the
  claims untouched — the retry converges.
  """

  # async: false — sibling module of the claim tests (the shared
  # provider stubs and the Mimic stance).
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Accounts.Membership
  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures

  @domain_name "apps.customer.com"
  @resolver_ip "10.43.0.20"

  setup do
    # Domain registration issues the verification Certificate — the
    # cluster call rides the create's transaction (stubbed like the
    # remove tests').
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)

    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    {org, owner} = BillingFixtures.grant_free_org!()

    {:ok, org: org, owner: owner}
  end

  test "unclaims and removes the entry from the row", %{org: org, owner: owner} do
    gateway = claimed_gateway!(org)
    domain = custom_domain!(owner)

    stub(Tailscale, :unclaim_domain, fn gw, domain_name ->
      assert gw.id == gateway.id
      assert domain_name == @domain_name
      :ok
    end)

    assert {:ok, row} = Infrastructure.unclaim_access_domain(gateway, domain, actor: owner)

    assert row.dns_claims == %{}
  end

  test "a provider failure leaves the claims untouched", %{org: org, owner: owner} do
    gateway = claimed_gateway!(org)
    domain = custom_domain!(owner)

    stub(Tailscale, :unclaim_domain, fn _gw, _d -> {:error, :network_error} end)

    assert {:error, :network_error} =
             Infrastructure.unclaim_access_domain(gateway, domain, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)

    assert row.dns_claims == %{
             @domain_name => %{"ip" => @resolver_ip, "tailnet" => "example.ts.net"}
           }
  end

  test "a claims-write failure after a successful unclaim surfaces honestly", %{
    org: org,
    owner: owner
  } do
    gateway = claimed_gateway!(org)
    domain = custom_domain!(owner)

    stub(Tailscale, :unclaim_domain, fn _gw, _d -> :ok end)
    stub(AccessGateway, :update_claims, fn _gw, _attrs, _opts -> {:error, :forced_db} end)

    assert {:error, :forced_db} =
             Infrastructure.unclaim_access_domain(gateway, domain, actor: owner)

    # The route went on the tailnet but the row still holds the entry —
    # the failure surfaces and the retry converges (a second unclaim
    # makes the same no-op writes).
    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)

    assert row.dns_claims == %{
             @domain_name => %{"ip" => @resolver_ip, "tailnet" => "example.ts.net"}
           }
  end

  test "a stale claims write retries once against the committed map (P2-3)", %{
    org: org,
    owner: owner
  } do
    gateway = claimed_gateway!(org)
    domain = custom_domain!(owner)

    stub(Tailscale, :unclaim_domain, fn _gw, _d -> :ok end)

    stale = %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    stub(AccessGateway, :update_claims, fn gw, %{dns_claims: claims}, _opts ->
      n = Agent.get_and_update(attempts, fn c -> {c, c + 1} end)

      if n == 0 do
        # First attempt: stale — the other tab wrote a second domain
        # first.
        {:error, stale}
      else
        # The retry recomputes from the committed map: the other tab's
        # entry survives this unclaim.
        merged =
          Map.put(claims, "other.example.com", %{
            "ip" => @resolver_ip,
            "tailnet" => "example.ts.net"
          })

        send(self(), {:claims_write, gw.id, merged})
        {:ok, %{gw | dns_claims: merged, version: 2}}
      end
    end)

    assert {:ok, _row} = Infrastructure.unclaim_access_domain(gateway, domain, actor: owner)

    assert_received {:claims_write, _id, claims}
    refute Map.has_key?(claims, @domain_name)
    assert Map.has_key?(claims, "other.example.com")
  end

  test "unclaiming a domain this gateway never claimed is a converging no-op", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    domain = custom_domain!(owner)

    stub(Tailscale, :unclaim_domain, fn _gw, _d -> :ok end)

    assert {:ok, row} = Infrastructure.unclaim_access_domain(gateway, domain, actor: owner)

    assert row.dns_claims == %{}
  end

  test "a non-member is Forbidden before any provider call", %{org: org, owner: owner} do
    gateway = claimed_gateway!(org)

    # The domain belongs to ANOTHER org whose member registered it; the
    # gateway org's owner is not a member there, so the authorized
    # domain read forbids before any provider call.
    {_other_org, other_owner} = BillingFixtures.grant_free_org!()

    stub(Tailscale, :unclaim_domain, fn _gw, _d -> flunk("no unclaim for a stranger") end)

    domain = custom_domain!(other_owner)

    assert {:error, _forbidden} =
             Infrastructure.unclaim_access_domain(gateway, domain, actor: owner)
  end

  test "one org's gateway never unclaims another org's row", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)

    # The owner is a member of BOTH orgs, so both authorized reads pass;
    # the explicit same-org check is what refuses here.
    {other_org, _other_owner} = BillingFixtures.grant_free_org!()
    domain = platform_domain!(other_org)

    Membership.create!(%{organization_id: other_org.id, user_id: owner.id, role: :member},
      authorize?: false
    )

    stub(Tailscale, :unclaim_domain, fn _gw, _d -> flunk("cross-org unclaim refused") end)

    assert {:error, :org_mismatch} =
             Infrastructure.unclaim_access_domain(gateway, domain, actor: owner)
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp claimed_gateway!(org) do
    gateway = AccessFixtures.gateway!(org)

    Ash.update!(
      gateway,
      %{dns_claims: %{@domain_name => %{"ip" => @resolver_ip, "tailnet" => "example.ts.net"}}},
      action: :update_claims,
      authorize?: false
    )
  end

  defp custom_domain!(owner) do
    expect(Kubereq, :apply, fn _req, manifest, _fm ->
      {:ok, %{status: 201, body: manifest}}
    end)

    assert {:ok, domain} =
             Infrastructure.register_access_domain(%{domain: @domain_name}, actor: owner)

    domain
  end

  defp platform_domain!(org) do
    AccessDomain.mint_platform!(
      %{
        domain: Application.fetch_env!(:flux_vale, :instances_base_domain),
        organization_id: org.id
      },
      authorize?: false
    )
  end
end
