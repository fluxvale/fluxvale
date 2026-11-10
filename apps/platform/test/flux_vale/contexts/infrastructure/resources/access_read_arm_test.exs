defmodule FluxVale.Infrastructure.AccessReadArmTest do
  @moduledoc false

  # #613's cross-org admin reads for AccessGateway and AccessDomain,
  # now served by the blanket authority (#644, ADR-0047): the actor
  # discrimination matrix (member / platform admin / anonymous), one
  # ruling pinned on both resources. Direct Ash calls carry no
  # machine-API mark, so the admin rows here exercise the bypass arm
  # exactly as the admin console's session does; the PAT-shaped
  # exclusions (machine-API callers stay member-filtered) are pinned in
  # #657's boundary suites. Includes the non-public columns'
  # visibility — the operator-truth fields the console renders
  # (`needs_attention_since`, `token_set_at`, `dns_claims`) ride the
  # record for authorized actors and stay OFF THE WIRE for everyone
  # (`public?: false`; pinned at the seam in the gateway route suite).
  # The provider is Mimic-stubbed (the fixture's contract).

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  setup do
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)

    # Two orgs the admin belongs to NEITHER of: the cross-org rows the
    # member filter hides and the admin arm admits.
    {org_a, owner_a} = BillingFixtures.grant_free_org!()
    {org_b, _owner_b} = BillingFixtures.grant_free_org!()

    %{org_a: org_a, org_b: org_b, owner_a: owner_a}
  end

  # The #613 signal row: the needs_attention clock set through the
  # state funnel (Suspend never clears the stamp — the funnel is the
  # only writer), the token ref through its system funnel (which
  # stamps `token_set_at`), the claims map through the claims funnel
  # the claim/unclaim operations ride.
  defp flagged_gateway!(org) do
    base = AccessFixtures.gateway!(org)

    flagged =
      base
      |> Ash.Changeset.for_update(
        :update_state,
        %{state: :needs_attention, needs_attention_since: DateTime.utc_now()},
        authorize?: false
      )
      |> Ash.update!()

    with_token =
      AccessGateway.set_api_token_ref!(flagged, %{api_token_secret_ref: "tok-stub"},
        authorize?: false
      )

    with_token
    |> Ash.Changeset.for_update(
      :update_claims,
      %{
        dns_claims: %{"apps.customer.com" => %{"ip" => "100.100.100.1", "tailnet" => "b.ts.net"}}
      },
      authorize?: false
    )
    |> Ash.update!()
  end

  # Each org's system-minted platform domain (MintDefaultHostname's
  # shape): one row per org, born :verified.
  defp platform_domain!(org) do
    AccessDomain.mint_platform!(
      %{domain: "fluxvale-#{System.unique_integer([:positive])}.lvh.me", organization_id: org.id},
      authorize?: false
    )
  end

  describe "AccessGateway reads" do
    test "a member reads exactly their org's gateways", %{
      org_a: org_a,
      org_b: org_b,
      owner_a: owner_a
    } do
      mine = AccessFixtures.gateway!(org_a)
      theirs = AccessFixtures.gateway!(org_b)

      {:ok, rows} =
        AccessGateway
        |> Ash.Query.for_read(:read, %{}, actor: owner_a)
        |> Ash.read()

      ids = Enum.map(rows, & &1.id)
      assert mine.id in ids
      refute theirs.id in ids

      assert {:error, error} = AccessGateway.get_by_id(theirs.id, actor: owner_a)
      assert Exception.message(error) =~ "not found"
    end

    test "a platform admin reads every org's gateway, carrying the operator-truth fields",
         %{org_a: org_a, org_b: org_b} do
      admin = AccountsFixtures.platform_admin!()
      mine = AccessFixtures.gateway!(org_a)
      flagged = flagged_gateway!(org_b)

      {:ok, rows} =
        AccessGateway
        |> Ash.Query.for_read(:read, %{}, actor: admin)
        |> Ash.read()

      ids = Enum.map(rows, & &1.id)
      assert mine.id in ids
      assert flagged.id in ids

      assert {:ok, foreign} = AccessGateway.get_by_id(flagged.id, actor: admin)

      # The non-public operator-truth columns ride the record for the
      # admin's read — the visibility the admin console's section
      # renders from (they stay off the wire; public?: false).
      assert foreign.needs_attention_since != nil
      assert foreign.token_set_at != nil
      assert Map.has_key?(foreign.dns_claims, "apps.customer.com")
    end

    test "an anonymous read is Forbidden" do
      assert {:error, %Ash.Error.Forbidden{}} =
               AccessGateway
               |> Ash.Query.for_read(:read, %{})
               |> Ash.read()
    end
  end

  describe "AccessDomain reads" do
    test "a member's reads stay org-filtered", %{
      org_a: org_a,
      org_b: org_b,
      owner_a: owner_a
    } do
      mine = platform_domain!(org_a)
      theirs = platform_domain!(org_b)

      assert {:ok, [row]} = AccessDomain.list_for_org(org_a.id, actor: owner_a)
      assert row.id == mine.id

      assert {:ok, []} = AccessDomain.list_for_org(org_b.id, actor: owner_a)

      assert {:error, error} = AccessDomain.get_by_id(theirs.id, actor: owner_a)
      assert Exception.message(error) =~ "not found"
    end

    test "a platform admin reads any org's domains", %{org_a: org_a, org_b: org_b} do
      admin = AccountsFixtures.platform_admin!()
      mine = platform_domain!(org_a)
      theirs = platform_domain!(org_b)

      assert {:ok, [row]} = AccessDomain.list_for_org(org_b.id, actor: admin)
      assert row.id == theirs.id

      assert {:ok, foreign} = AccessDomain.get_by_id(theirs.id, actor: admin)
      assert foreign.id == theirs.id

      # The admin is a member of neither org — the arm, not a leak.
      assert mine.organization_id != foreign.organization_id
    end

    test "an anonymous read is Forbidden", %{org_a: org_a} do
      assert {:error, %Ash.Error.Forbidden{}} =
               AccessDomain.list_for_org(org_a.id)
    end
  end
end
