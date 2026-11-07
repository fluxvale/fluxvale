defmodule FluxValeWeb.Api.WalletRouteTest do
  @moduledoc false

  # #360: the wallet family's wire contract — the org's wallet (balance
  # aggregate included), the runway projection, and the keyset-paginated
  # ledger. Read-only by design: the scope table has no wallet writes.

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.Billing
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  defp member_org! do
    user = elem(ApiPat.member!(), 0)
    org = BillingFixtures.mark_user_paid!(user)
    {user, org}
  end

  describe "GET /api/v1/organizations/:organization_id/wallet" do
    test "returns the wallet with the live balance aggregate", %{conn: conn} do
      {user, org} = member_org!()

      {:ok, wallet} = Billing.ensure_wallet(org)
      {:ok, _grant} = Billing.grant_credits(wallet, 1_500, reason: :purchase)

      pat = ApiPat.mint!(user.email, ["wallet:read"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/organizations/#{org.id}/wallet")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["type"] == "wallet"
      assert row["id"] == wallet.id

      # The key set is the contract: the balance aggregate rides along;
      # the carryover/ladder system state stays private. The balance is
      # the live ledger sum: 300 welcome + 100 paid-mark + 1_500 grant.
      assert row["attributes"] == %{
               "organization_id" => org.id,
               "balance" => 1_900,
               "paywall_waived" => false
             }
    end
  end

  describe "GET /api/v1/organizations/:organization_id/wallet/runway" do
    test "projects the runway — the operation's own three-key shape", %{conn: conn} do
      {user, org} = member_org!()
      pat = ApiPat.mint!(user.email, ["wallet:read"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/organizations/#{org.id}/wallet/runway")

      # No instances, no gateways: nothing burns, runway is infinite —
      # the atom serializes as its name. The balance is the live ledger:
      # 300 welcome + 100 paid-mark.
      assert body = json_response(conn, 200)
      assert body["balance_cents"] == 400
      assert body["burn_micro_cents_per_hour"] == 0
      assert body["runway_hours"] == "infinity"
    end

    test "a burning org gets finite hours", %{conn: conn} do
      {user, org} = member_org!()
      InstanceFixtures.local_cluster!()

      version = InstanceFixtures.app_version!(monthly_cents: 100, default_storage_gb: 10)

      instance = InstanceFixtures.instance!(version, user)
      InstanceFixtures.walk_to!(instance, :running)

      pat = ApiPat.mint!(user.email, ["wallet:read"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/organizations/#{org.id}/wallet/runway")

      assert body = json_response(conn, 200)
      assert body["burn_micro_cents_per_hour"] > 0
      assert is_float(body["runway_hours"])
    end
  end

  describe "GET /api/v1/wallets/:wallet_id/ledger-entries" do
    test "lists keyset-paginated, newest first", %{conn: conn} do
      {user, org} = member_org!()

      {:ok, wallet} = Billing.ensure_wallet(org)
      {:ok, _welcome} = Billing.grant_credits(wallet, 300, reason: :welcome)
      {:ok, _topup} = Billing.credit_wallet(wallet, 100)

      pat = ApiPat.mint!(user.email, ["wallet:read"])

      page_one =
        conn
        |> auth(pat)
        |> get("/api/v1/wallets/#{wallet.id}/ledger-entries?page[limit]=1&sort=-id")

      assert %{"data" => [row]} = json_response(page_one, 200)
      assert row["type"] == "ledger_entry"
      # Newest first: the purchase credit (100¢) landed after the grant.
      assert row["attributes"]["amount"] == 100
      assert row["attributes"]["reason"] == "purchase"

      # The keyset cursor is opaque — follow the response's own next
      # link (the library's cursor, never the row id).
      assert %{"next" => next} = json_response(page_one, 200)["links"]
      assert next =~ "page[after]"

      %URI{path: path, query: query} = URI.parse(next)

      page_two =
        build_conn()
        |> auth(pat)
        |> get(path <> "?" <> query)

      assert %{"data" => [older]} = json_response(page_two, 200)
      assert older["attributes"]["amount"] == 300
      assert older["attributes"]["reason"] == "welcome"
    end

    test "a wallet with no entries lists empty", %{conn: conn} do
      # The paid member's wallet already carries welcome + purchase
      # rows; a grant-free org's fresh wallet is the empty shape.
      {org, owner} = BillingFixtures.grant_free_org!()
      {:ok, wallet} = Billing.ensure_wallet(org)
      pat = ApiPat.mint!(owner.email, ["wallet:read"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/wallets/#{wallet.id}/ledger-entries")

      assert %{"data" => []} = json_response(conn, 200)
    end
  end
end
