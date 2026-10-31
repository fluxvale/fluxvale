defmodule FluxVale.Infrastructure.Operations.SetAccessApiTokenTest do
  @moduledoc """
  The API-token intake seam (ADR-0040 §5): member-scoped, Secret first
  then the row ref, and the token never comes back — the op's return is
  `:ok`, the row holds only the Secret's NAME.
  """

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures

  @token "tskey-api-secret-value"

  setup do
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

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
    refute "#{inspect(row)}" =~ @token
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

  test "a Secret write failure leaves the row untouched (the retry converges)", %{
    org: org,
    owner: owner
  } do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :write_api_credential, fn _gw, _t -> {:error, :cluster_oops} end)

    assert {:error, :cluster_oops} =
             Infrastructure.set_access_api_token(gateway, @token, actor: owner)

    row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
    assert row.api_token_secret_ref == nil
  end

  test "a ref-write failure surfaces (the Secret write is an SSA upsert, so the retry is safe)",
       %{org: org, owner: owner} do
    gateway = AccessFixtures.gateway!(org)

    stub(Tailscale, :write_api_credential, fn _gw, _t ->
      {:ok, %{api_token_secret_ref: "api-credential-abc"}}
    end)

    stub(AccessGateway, :set_api_token_ref, fn _gw, _attrs, _opts -> {:error, :forced_db} end)

    assert {:error, :forced_db} =
             Infrastructure.set_access_api_token(gateway, @token, actor: owner)
  end
end
