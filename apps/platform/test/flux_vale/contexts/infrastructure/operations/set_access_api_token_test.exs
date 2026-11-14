defmodule FluxVale.Infrastructure.Operations.SetAccessApiTokenTest do
  @moduledoc """
  The API-token intake seam (#760, ADR-0040 §5, Am. 3): owner-only,
  Secret first then the row ref, the token never coming back — and the
  save claims the org's already-verified domains (the S6 follow-up),
  with a claim failure leaving the token written and the row unclaimed
  rather than failing the save.
  """

  # async: false — the claim sweep reads the global :access_dns app env.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Accounts.Membership
  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  @token "tskey-api-secret-value"
  @domain_name "apps.customer.com"
  @resolver_ip "10.43.0.20"

  setup do
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)
    stub(RenderAccessDNS, :call, fn -> :ok end)
    stub(RenderAccessDNS, :call, fn _opts -> :ok end)

    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    previous = Application.get_env(:flux_vale, :access_dns)
    Application.put_env(:flux_vale, :access_dns, resolver_ip: @resolver_ip)
    on_exit(fn -> Application.put_env(:flux_vale, :access_dns, previous) end)

    {org, owner} = BillingFixtures.grant_free_org!()

    {:ok, org: org, owner: owner}
  end

  test "writes the Secret and records only its NAME on the row", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :write_api_credential, fn gw, token ->
      assert gw.id == gateway.id
      assert token == @token
      {:ok, %{api_token_secret_ref: "api-credential-abc"}}
    end)

    # The return is `:ok` — the token appears NOWHERE in the result.
    assert :ok = Infrastructure.set_access_api_token(gateway, @token, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.api_token_secret_ref == "api-credential-abc"
    assert %DateTime{} = row.token_set_at
    refute "#{inspect(row)}" =~ @token
    refute inspect(gateway) =~ @token
  end

  test "a non-member is Forbidden before any cluster call", %{org: org} do
    gateway = AccessFixtures.gateway!(org)
    {_other_org, other_owner} = BillingFixtures.grant_free_org!()

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      flunk("no cluster call for a stranger")
    end)

    assert {:error, _forbidden} =
             Infrastructure.set_access_api_token(gateway, @token, actor: other_owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.api_token_secret_ref == nil
  end

  # P2-8: the crown is owner-only (ADR-0040 §12 — with the key
  # FluxVale can rewrite the customer's whole tailnet DNS).
  test "a member of the org (not an owner) is refused before any cluster call", %{org: org} do
    gateway = AccessFixtures.gateway!(org)

    member = AccountsFixtures.user!()

    Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
      authorize?: false
    )

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      flunk("the crown is the owner's to paste")
    end)

    assert {:error, :not_org_owner} =
             Infrastructure.set_access_api_token(gateway, @token, actor: member)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.api_token_secret_ref == nil
  end

  test "a nil actor is refused as not-an-owner even authorize?-free", %{org: org} do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :write_api_credential, fn _gw, _t -> flunk("nil actor, no cluster call") end)

    assert {:error, :not_org_owner} =
             Infrastructure.set_access_api_token(gateway, @token, authorize?: false)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.api_token_secret_ref == nil
  end

  test "a Secret write failure leaves the row untouched and names the reason", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :write_api_credential, fn _gw, _t -> {:error, :cluster_oops} end)

    assert {:error, :cluster_oops} =
             Infrastructure.set_access_api_token(gateway, @token, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.api_token_secret_ref == nil
    assert row.token_set_at == nil
  end

  test "saving the token claims the org's already-verified domains", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(owner)

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      {:ok, %{api_token_secret_ref: "api-credential-abc"}}
    end)

    stub(Tailscale, :claim_domain, fn gw, domain_name, resolver_ip ->
      assert gw.id == gateway.id
      assert domain_name == @domain_name
      assert resolver_ip == @resolver_ip
      {:ok, %{device_id: "device-1", route: "10.43.0.20/32"}}
    end)

    assert :ok = Infrastructure.set_access_api_token(gateway, @token, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.dns_claims[domain.domain]["ip"] == @resolver_ip
  end

  test "a refused claim keeps the token written and reports it unclaimed", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    verified_domain!(owner)

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      {:ok, %{api_token_secret_ref: "api-credential-abc"}}
    end)

    stub(Tailscale, :claim_domain, fn _gw, _domain, _ip -> {:error, :tailnet_down} end)

    assert :ok = Infrastructure.set_access_api_token(gateway, @token, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.api_token_secret_ref == "api-credential-abc"
    assert row.dns_claims in [nil, %{}]
  end

  test "no verified domain means no claim call at all", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      {:ok, %{api_token_secret_ref: "api-credential-abc"}}
    end)

    stub(Tailscale, :claim_domain, fn _gw, _domain, _ip ->
      flunk("nothing to claim")
    end)

    assert :ok = Infrastructure.set_access_api_token(gateway, @token, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.api_token_secret_ref == "api-credential-abc"
    assert row.dns_claims in [nil, %{}]
  end

  defp verified_domain!(owner) do
    BillingFixtures.mark_user_paid!(owner)

    expect(Kubereq, :apply, fn _req, manifest, _fm ->
      {:ok, %{status: 201, body: manifest}}
    end)

    assert {:ok, pending} =
             Infrastructure.register_access_domain(%{domain: @domain_name}, actor: owner)

    Ash.update!(pending, %{cert_secret_ref: "cert-secret"},
      action: :mark_verified,
      authorize?: false
    )
  end

  test "the action's own fence refuses a member even authorize?-free", %{org: org} do
    gateway = AccessFixtures.gateway!(org)
    member = AccountsFixtures.user!()

    Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
      authorize?: false
    )

    stub(Tailscale, :write_api_credential, fn _gw, _t -> flunk("no cluster call") end)

    # The policy fences the member on every actor path; this is the
    # authorize?-free seam's own fence, so its shape is the programming-
    # error class (a system caller that skipped the op's check).
    assert {:error, %Ash.Error.Unknown{}} =
             AccessGateway.set_api_token(gateway, %{api_token: @token},
               actor: member,
               authorize?: false
             )

    assert AccessGateway.get_by_id!(gateway.id, authorize?: false).api_token_secret_ref == nil
  end

  test "a crashing claim sweep never fails the save", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    verified_domain!(owner)

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      {:ok, %{api_token_secret_ref: "api-credential-abc"}}
    end)

    stub(Tailscale, :claim_domain, fn _gw, _domain, _ip -> raise "tailnet exploded" end)

    assert :ok = Infrastructure.set_access_api_token(gateway, @token, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.api_token_secret_ref == "api-credential-abc"
  end
end
