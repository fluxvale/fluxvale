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
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ApiClient
  alias FluxVale.Infrastructure.AccessProviders.Tailscale.TokenCache
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @token "tskey-api-secret-value"
  @client_id "ts-client-id-1"
  @client_secret "ts-client-secret-1"
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

  test "a Secret write failure leaves the row untouched and answers a stable tag", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :write_api_credential, fn _gw, _t -> {:error, :cluster_oops} end)

    assert {:error, :api_token_write_failed} =
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

  test "one save claims every verified domain, not just the first", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      {:ok, %{api_token_secret_ref: "api-credential-abc"}}
    end)

    names = ["one.customer.com", "two.customer.com", "three.customer.com"]
    Enum.each(names, &verified_domain!(owner, &1))

    stub(Tailscale, :claim_domain, fn _gw, name, _ip ->
      assert name in names
      {:ok, %{device_id: "device-1", route: "10.43.0.20/32"}}
    end)

    assert :ok = Infrastructure.set_access_api_token(gateway, @token, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)

    claim_names =
      row.dns_claims
      |> Map.keys()
      |> Enum.sort()

    assert claim_names == Enum.sort(names)
  end

  test "an already-claimed domain is skipped", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      {:ok, %{api_token_secret_ref: "api-credential-abc"}}
    end)

    held = verified_domain!(owner, "held.customer.com")

    {:ok, held_gateway} =
      AccessGateway.update_claims(
        gateway,
        %{dns_claims: %{held.domain => %{"ip" => @resolver_ip}}},
        authorize?: false
      )

    stub(Tailscale, :claim_domain, fn _gw, name, _ip ->
      assert name == "fresh.customer.com"
      {:ok, %{device_id: "device-1", route: "10.43.0.20/32"}}
    end)

    _fresh = verified_domain!(owner, "fresh.customer.com")

    assert :ok = Infrastructure.set_access_api_token(held_gateway, @token, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)

    claim_names =
      row.dns_claims
      |> Map.keys()
      |> Enum.sort()

    assert claim_names == ["fresh.customer.com", "held.customer.com"]
  end

  test "another org's verified domain is never claimed", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      {:ok, %{api_token_secret_ref: "api-credential-abc"}}
    end)

    {other_org, _other_owner} = BillingFixtures.grant_free_org!()

    Ash.Seed.seed!(FluxVale.Infrastructure.AccessDomain, %{
      domain: "other.customer.com",
      kind: :custom,
      state: :verified,
      organization_id: other_org.id,
      cert_secret_ref: "cert-secret"
    })

    stub(Tailscale, :claim_domain, fn _gw, _name, _ip -> flunk("foreign domain") end)

    assert :ok = Infrastructure.set_access_api_token(gateway, @token, actor: owner)
  end

  test "a deleted gateway is refused before any cluster call", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)
    gone = %{gateway | id: Ash.UUIDv7.generate()}

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      flunk("no Secret write for a row that no longer exists")
    end)

    assert {:error, _reason} =
             Infrastructure.set_access_api_token(gone, @token, actor: owner)
  end

  test "a destroying gateway is refused before any cluster call", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org, state: :destroying)

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      flunk("no Secret write while tearing down")
    end)

    assert {:error, _reason} =
             Infrastructure.set_access_api_token(gateway, @token, actor: owner)
  end

  test "a padded paste is stored trimmed", %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :write_api_credential, fn _gw, token ->
      assert token == @token
      {:ok, %{api_token_secret_ref: "api-credential-abc"}}
    end)

    assert :ok =
             Infrastructure.set_access_api_token(gateway, "  " <> @token <> "\n", actor: owner)

    assert AccessGateway.get_by_id!(gateway.id, authorize?: false).api_token_secret_ref ==
             "api-credential-abc"
  end

  test "a struct provider failure stays off the wire and names a safe tag", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      {:error, %FluxVale.Clients.K8s.Error{status_code: 500, reason: :api_error, message: "boom"}}
    end)

    assert {:error, :api_token_write_failed} =
             Infrastructure.set_access_api_token(gateway, @token, actor: owner)

    assert AccessGateway.get_by_id!(gateway.id, authorize?: false).api_token_secret_ref == nil
  end

  test "the action returns the post-sweep row (the wire's claim state)", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(owner)

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      {:ok, %{api_token_secret_ref: "api-credential-abc"}}
    end)

    stub(Tailscale, :claim_domain, fn _gw, _name, _ip ->
      {:ok, %{device_id: "device-1", route: "10.43.0.20/32"}}
    end)

    assert {:ok, row} =
             AccessGateway.set_api_token(gateway, %{api_token: @token},
               actor: owner,
               authorize?: true
             )

    assert row.dns_claims[domain.domain]["ip"] == @resolver_ip
  end

  defp verified_domain!(owner, name \\ @domain_name) do
    BillingFixtures.mark_user_paid!(owner)

    expect(Kubereq, :apply, fn _req, manifest, _fm ->
      {:ok, %{status: 201, body: manifest}}
    end)

    assert {:ok, pending} =
             Infrastructure.register_access_domain(%{domain: name}, actor: owner)

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

  test "a non-struct, non-atom provider failure is logged as unexpected", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :write_api_credential, fn _gw, _t -> {:error, "not a struct"} end)

    assert {:error, :api_token_write_failed} =
             Infrastructure.set_access_api_token(gateway, @token, actor: owner)

    assert AccessGateway.get_by_id!(gateway.id, authorize?: false).api_token_secret_ref == nil
  end

  # The lane-B verification the change-level pins cannot reach (the
  # settings suite here is the async: false home of the real sweep):
  # a pair-stored row's claims read through `with_access_token/2` — the
  # wrapper resolves the pair, the exchange mints the bearer, and the
  # sweep claims with it. Zero shape-specific claim code.
  test "a pair save's claim sweep exchanges and claims with the OAuth token", %{
    org: org,
    owner: owner
  } do
    # A client id UNIQUE to this test, so the app-global cache is cold
    # for it without clearing anyone else's entries — the capture-
    # restore discipline (#864 review): the on_exit invalidates only
    # what this test put in.
    client_id = "ts-client-id-sweep-#{System.unique_integer([:positive])}"

    on_exit(fn -> TokenCache.invalidate(client_id) end)

    gateway = AccessFixtures.gateway!(org)
    domain = verified_domain!(owner)

    stub(Tailscale, :write_client_credential, fn _gw, _id, _secret ->
      {:ok, %{api_token_secret_ref: "api-credential-pair"}}
    end)

    # claim_domain is deliberately NOT stubbed: the Secret read answers
    # with the pair the save stored, and the exchange runs for real
    # (against stubs at the ApiClient seam, like the provider suite).
    InstanceFixtures.local_cluster!()
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Secret, :get_data, fn _kc, _ns, _name ->
      {:ok, %{"TS_CLIENT_ID" => client_id, "TS_CLIENT_SECRET" => @client_secret}}
    end)

    stub(ApiClient, :oauth_exchange, fn _id, _secret ->
      {:ok, %{access_token: "tskey-token-pair", expires_in: 3600}}
    end)

    stub(ApiClient, :devices_lookup, fn token, _hostname ->
      send(self(), {:lookup, token})
      {:ok, %{id: "dev-777"}}
    end)

    stub(ApiClient, :routes_get, fn _token, _id -> {:ok, %{advertised: [], enabled: []}} end)
    stub(ApiClient, :routes_set, fn _token, _id, _routes -> :ok end)
    stub(ApiClient, :split_dns_get, fn _token -> {:ok, %{}} end)
    stub(ApiClient, :split_dns_patch, fn _token, _routes -> :ok end)

    assert {:ok, row} =
             AccessGateway.set_api_token(
               gateway,
               %{ts_client_id: client_id, ts_client_secret: @client_secret},
               actor: owner,
               authorize?: true
             )

    assert row.dns_claims[domain.domain]["ip"] == @resolver_ip
    assert_received {:lookup, "tskey-token-pair"}
  end
end
