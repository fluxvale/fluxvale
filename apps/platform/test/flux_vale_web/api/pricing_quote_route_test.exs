defmodule FluxValeWeb.Api.PricingQuoteRouteTest do
  @moduledoc false

  # #770: GET /api/v1/pricing/quote — the same `price_allocation/1`
  # the /pricing calculator and the ledger price through, exposed so
  # an agent quotes the cent it would be charged. Public data:
  # `:any` scope, and the route is read-only.

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.Pricing
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  test "the default-size quote is the seeded ladder's own cents", %{conn: conn} do
    {user, _pat} = ApiPat.member!()
    pat = ApiPat.mint!(user, [])

    conn =
      conn
      |> auth(pat)
      |> get("/api/v1/pricing/quote?cpu_cores=0.5&memory_mb=512&storage_gb=10")

    assert body = json_response(conn, 200)
    # The `small` compute class (295¢) plus 10 GB of storage (40¢) —
    # the /pricing page's own first-paint figures ($3.35/mo, $0.40
    # stopped), pinned as literals so the route cannot drift.
    assert body["monthly_cents"] == 335
    assert body["stopped_monthly_cents"] == 40
    assert body["monthly"] == "$3.35/mo · billed hourly"
    assert body["stopped"] == "$0.40 while stopped"
    assert body["cpu_cores"] == "0.5"
    assert body["memory_mb"] == 512
    assert body["storage_gb"] == 10
  end

  test "a custom allocation prices through the one curve", %{conn: conn} do
    {user, _pat} = ApiPat.member!()
    pat = ApiPat.mint!(user, [])

    conn =
      conn
      |> auth(pat)
      |> get("/api/v1/pricing/quote?cpu_cores=2&memory_mb=4096&storage_gb=25")

    body = json_response(conn, 200)

    assert body["monthly_cents"] ==
             Pricing.price_allocation(%{
               cpu_cores: Decimal.new("2"),
               memory_mb: 4096,
               storage_gb: 25
             }).monthly_cents

    assert body["stopped_monthly_cents"] == Pricing.storage_monthly_cents(25)
    refute body["monthly"] == "$3.35/mo · billed hourly"
  end

  test "the quote is public data — a zero-scope token asks", %{conn: conn} do
    {user, _pat} = ApiPat.member!()
    pat = ApiPat.mint!(user, [])

    conn =
      conn
      |> auth(pat)
      |> get("/api/v1/pricing/quote?cpu_cores=1&memory_mb=1024&storage_gb=0")

    assert %{"monthly_cents" => monthly, "stopped_monthly_cents" => 0} =
             json_response(conn, 200)

    assert monthly ==
             Pricing.price_allocation(%{
               cpu_cores: Decimal.new("1"),
               memory_mb: 1024,
               storage_gb: 0
             }).monthly_cents
  end

  test "an out-of-range allocation is refused, never priced", %{conn: conn} do
    {user, _pat} = ApiPat.member!()

    for query <- [
          "cpu_cores=0&memory_mb=512&storage_gb=10",
          "cpu_cores=65&memory_mb=512&storage_gb=10",
          "cpu_cores=0.5&memory_mb=0&storage_gb=10",
          "cpu_cores=0.5&memory_mb=512&storage_gb=-1",
          "cpu_cores=0.5&memory_mb=512",
          "cpu_cores=nope&memory_mb=512&storage_gb=10"
        ] do
      # One token per probe: the ets window is per-token, and a
      # refused request still counts.
      pat = ApiPat.mint!(user, [])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/pricing/quote?#{query}")

      assert %{"errors" => [_error | _errors]} = json_response(conn, 400), "query: #{query}"
    end
  end

  test "a session cookie may read — the /api/v1 read posture", %{conn: conn} do
    user = AccountsFixtures.user!()
    {:ok, session_token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn =
      conn
      |> Plug.Test.init_test_session(%{"user_token" => session_token})
      |> get("/api/v1/pricing/quote?cpu_cores=0.5&memory_mb=512&storage_gb=10")

    assert %{"monthly_cents" => 335} = json_response(conn, 200)
  end
end
