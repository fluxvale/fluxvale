defmodule FluxValeWeb.Api.MembershipRouteTest do
  @moduledoc false

  # #360: membership bites over the wire — a member of org A asking
  # for org B's records gets ash_json_api's filtered-get shape (404),
  # never a cross-org document.

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  setup do
    outsider = elem(ApiPat.member!(), 0)
    BillingFixtures.mark_user_paid!(outsider)

    {org, owner} = BillingFixtures.grant_free_org!()

    # The instance create's funded gate reads the ledger (the fixtures'
    # own precondition posture).
    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _funding} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance = InstanceFixtures.instance!(version, owner)

    %{
      outsider: outsider,
      org: org,
      instance: instance,
      wallet: wallet
    }
  end

  test "org A's member cannot read org B's instance or wallet", %{
    conn: conn,
    outsider: outsider,
    instance: instance,
    wallet: wallet
  } do
    pat = ApiPat.mint!(outsider.email, ["instances:read", "wallet:read", "backups:write"])

    instance_read =
      conn
      |> auth(pat)
      |> get("/api/v1/instances/#{instance.id}")

    assert %{"errors" => [%{"status" => "404"}]} = json_response(instance_read, 404)

    wallet_read =
      build_conn()
      |> auth(pat)
      |> get("/api/v1/organizations/#{wallet.organization_id}/wallet")

    assert %{"errors" => [%{"status" => "404"}]} = json_response(wallet_read, 404)

    # The runway projection rides the same authorized read — the
    # membership fence, not a separate one.
    runway_read =
      build_conn()
      |> auth(pat)
      |> get("/api/v1/organizations/#{wallet.organization_id}/wallet/runway")

    assert %{"errors" => [%{"status" => "404"}]} = json_response(runway_read, 404)

    ledger_read =
      build_conn()
      |> auth(pat)
      |> get("/api/v1/wallets/#{wallet.id}/ledger-entries")

    assert %{"data" => []} = json_response(ledger_read, 200)
  end

  test "the backup verbs are ownership-fenced — the authorized reads inside refuse", %{
    conn: conn,
    outsider: outsider,
    instance: instance
  } do
    pat = ApiPat.mint!(outsider.email, ["instances:read", "wallet:read", "backups:write"])

    run =
      conn
      |> auth(pat)
      |> post("/api/v1/instances/#{instance.id}/backup-runs")

    assert %{"errors" => [%{"status" => "404"}]} = json_response(run, 404)

    restore =
      build_conn()
      |> auth(pat)
      |> post("/api/v1/instances/#{instance.id}/backup-runs/#{instance.id}/restore")

    assert %{"errors" => [%{"status" => "404"}]} = json_response(restore, 404)
  end
end
