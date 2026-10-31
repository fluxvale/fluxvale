defmodule FluxVale.Infrastructure.Operations.ClaimAccessDomainTest do
  @moduledoc """
  The member-scoped claim (ADR-0040 §3): serving-state + same-org +
  verified gates, resolver from config, the claims funnel — and the 401
  drift: a rejected token lands the row :needs_attention with the
  re-paste copy AND fails the operation honestly.
  """

  # async: false — the tests stub the global :access_dns app env.
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

    previous = Application.get_env(:flux_vale, :access_dns)
    Application.put_env(:flux_vale, :access_dns, resolver_ip: @resolver_ip)

    on_exit(fn -> Application.put_env(:flux_vale, :access_dns, previous) end)

    {org, owner} = BillingFixtures.grant_free_org!()

    {:ok, org: org, owner: owner}
  end

  test "claims a verified domain and records the entry on the row", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(owner)

    stub(Tailscale, :claim_domain, fn gw, domain_name, resolver_ip ->
      assert gw.id == gateway.id
      assert domain_name == @domain_name
      assert resolver_ip == @resolver_ip
      {:ok, %{device_id: "dev-777"}}
    end)

    assert {:ok, row} = Infrastructure.claim_access_domain(gateway, domain, actor: owner)

    # The entry records WHAT was claimed and the RECORDED tailnet (P2-14).
    assert row.dns_claims == %{
             @domain_name => %{"ip" => @resolver_ip, "tailnet" => "example.ts.net"}
           }
  end

  test "a re-claim converges — the entry is updated, not duplicated", %{org: org, owner: owner} do
    existing = AccessFixtures.gateway!(org)

    gateway =
      Ash.update!(existing, %{dns_claims: %{@domain_name => "9.9.9.9"}},
        action: :update_claims,
        authorize?: false
      )

    domain = verified_domain!(owner)

    stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:ok, %{device_id: "dev-777"}} end)

    assert {:ok, row} = Infrastructure.claim_access_domain(gateway, domain, actor: owner)

    assert row.dns_claims == %{
             @domain_name => %{"ip" => @resolver_ip, "tailnet" => "example.ts.net"}
           }
  end

  test "a gateway torn down between the stale write and the retry stands failed", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(owner)

    stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:ok, %{device_id: "dev-777"}} end)
    stale = %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}

    stub(AccessGateway, :update_claims, fn _gw, _attrs, _opts -> {:error, stale} end)
    # Only the RETRY's re-read (authorize?: false) finds the row gone;
    # the op's authorized first read passes through to the real row.
    stub(AccessGateway, :get_by_id, fn _id, opts ->
      if opts[:authorize?] == false do
        {:error, :torn_down}
      else
        {:ok, gateway}
      end
    end)

    assert {:error, %Ash.Error.Invalid{}} =
             Infrastructure.claim_access_domain(gateway, domain, actor: owner)
  end

  test "a parked gateway claims nothing", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org, state: :suspended)
    domain = verified_domain!(owner)

    stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> flunk("a parked gateway claims nothing") end)

    assert {:error, :gateway_not_serving} =
             Infrastructure.claim_access_domain(gateway, domain, actor: owner)
  end

  test "an unverified domain claims nothing (verify-by-issuance)", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    domain = pending_domain!(owner)

    stub(Tailscale, :claim_domain, fn _gw, _d, _ip ->
      flunk("unverified domains claim nothing")
    end)

    assert {:error, :domain_not_verified} =
             Infrastructure.claim_access_domain(gateway, domain, actor: owner)
  end

  test "no resolver configured refuses honestly", %{org: org, owner: owner} do
    previous = Application.get_env(:flux_vale, :access_dns)
    Application.put_env(:flux_vale, :access_dns, nil)
    on_exit(fn -> Application.put_env(:flux_vale, :access_dns, previous) end)

    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(owner)

    stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> flunk("nothing to claim against") end)

    assert {:error, :resolver_unconfigured} =
             Infrastructure.claim_access_domain(gateway, domain, actor: owner)
  end

  test "a rejected token drifts the row AND fails the operation", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(owner)

    stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:error, :unauthorized} end)

    assert {:error, :unauthorized} =
             Infrastructure.claim_access_domain(gateway, domain, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)

    assert row.state == :needs_attention

    # P3-13's equality pin: the op drifts with the PROVIDER's copy —
    # one source, two surfaces.
    assert row.status_message == Tailscale.token_drift_message(:unauthorized)
    assert row.needs_attention_since
    # Nothing was claimed — the claims registry is untouched.
    assert row.dns_claims == nil
  end

  test "a scope-less token (403) drifts with the scope copy", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(owner)

    stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:error, :forbidden} end)

    assert {:error, :forbidden} =
             Infrastructure.claim_access_domain(gateway, domain, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.state == :needs_attention
    assert row.status_message == Tailscale.token_drift_message(:forbidden)
    assert row.status_message =~ "devices:routes"
  end

  test "a stale claims write retries once against the committed map (P2-3)", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(owner)

    # Two tabs, two domains: this tab's write races a concurrent claim
    # of "other.example.com". The lock refuses the slower write
    # (StaleRecord); the retry re-reads the committed map and MERGES —
    # the other tab's entry survives alongside this one.
    stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:ok, %{device_id: "dev-777"}} end)

    stale = %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    stub(AccessGateway, :update_claims, fn gw, %{dns_claims: claims}, _opts ->
      n = Agent.get_and_update(attempts, fn c -> {c, c + 1} end)

      if n == 0 do
        # First attempt: refused as stale (the other tab wrote first).
        {:error, stale}
      else
        # The retry recomputed from the committed map: merge the other
        # tab's entry in, keep BOTH.
        merged =
          Map.put(claims, "other.example.com", %{
            "ip" => @resolver_ip,
            "tailnet" => "example.ts.net"
          })

        send(self(), {:claims_write, gw.id, merged})
        {:ok, %{gw | dns_claims: merged, version: 2}}
      end
    end)

    assert {:ok, _row} = Infrastructure.claim_access_domain(gateway, domain, actor: owner)

    assert_received {:claims_write, _id, claims}
    assert Map.has_key?(claims, @domain_name)
    assert claims["other.example.com"] == %{"ip" => @resolver_ip, "tailnet" => "example.ts.net"}
  end

  test "a claims-write failure after a successful claim surfaces honestly", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(owner)

    stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:ok, %{device_id: "dev-777"}} end)
    stub(AccessGateway, :update_claims, fn _gw, _attrs, _opts -> {:error, :forced_db} end)

    assert {:error, :forced_db} =
             Infrastructure.claim_access_domain(gateway, domain, actor: owner)

    # The claim LANDED on the tailnet but the row says nothing yet —
    # the failure surfaces (the idempotent re-claim is the convergence).
    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.dns_claims == nil
  end

  test "any other provider failure passes through with no drift", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(owner)

    stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:error, :node_not_found} end)

    assert {:error, :node_not_found} =
             Infrastructure.claim_access_domain(gateway, domain, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.state == :active
    assert row.dns_claims == nil
  end

  test "a drift-write failure is logged, the operation still fails honestly", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(owner)

    stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:error, :unauthorized} end)
    stub(AccessGateway, :update_state, fn _gw, _attrs, _opts -> {:error, :forced_db} end)

    assert {:error, :unauthorized} =
             Infrastructure.claim_access_domain(gateway, domain, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.state == :active
  end

  test "a non-member is Forbidden before any provider call", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)

    # The domain belongs to ANOTHER org whose member registered it; the
    # gateway org's owner is not a member there, so the authorized
    # domain read forbids before any provider call.
    {_other_org, other_owner} = BillingFixtures.grant_free_org!()

    stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> flunk("no claim for a stranger") end)

    domain = verified_domain!(other_owner)

    assert {:error, _forbidden} =
             Infrastructure.claim_access_domain(gateway, domain, actor: owner)
  end

  test "one org's gateway never claims another org's row", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)

    # The owner is a member of BOTH orgs, so both authorized reads pass;
    # the explicit same-org check is what refuses here (the platform
    # domain exists per-org — the reads alone cannot tell).
    {other_org, _other_owner} = BillingFixtures.grant_free_org!()
    domain = cross_org_verified_domain!(other_org)

    Membership.create!(%{organization_id: other_org.id, user_id: owner.id, role: :member},
      authorize?: false
    )

    stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> flunk("cross-org claim refused") end)

    assert {:error, :org_mismatch} =
             Infrastructure.claim_access_domain(gateway, domain, actor: owner)
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp verified_domain!(owner) do
    pending = pending_domain!(owner)

    Ash.update!(pending, %{cert_secret_ref: "cert-secret"},
      action: :mark_verified,
      authorize?: false
    )
  end

  defp pending_domain!(owner) do
    expect(Kubereq, :apply, fn _req, manifest, _fm ->
      {:ok, %{status: 201, body: manifest}}
    end)

    assert {:ok, domain} =
             Infrastructure.register_access_domain(%{domain: @domain_name}, actor: owner)

    domain
  end

  # The :custom uniqueness is PLATFORM-wide, so a second org cannot hold
  # a row for the same name — the cross-org case rides the PLATFORM row
  # (born :verified, one per org).
  defp cross_org_verified_domain!(org) do
    platform_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)

    AccessDomain.mint_platform!(
      %{domain: platform_domain, organization_id: org.id},
      authorize?: false
    )
  end
end
