defmodule FluxValeWeb.Api.DomainDelegationRouteTest do
  @moduledoc false

  # #783: GET /api/v1/domain-delegations/:domain — the
  # pre-registration delegation preview the provider's
  # fluxvale_domain_delegation data source reads. Row-free on purpose:
  # the Terraform graph creates the DNS record before the domain's
  # create waits for issuance.

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  test "returns the one challenge CNAME, canonicalized", %{conn: conn} do
    {user, _pat} = ApiPat.member!()
    pat = ApiPat.mint!(user, ["gateways:read"])

    conn =
      conn
      |> auth(pat)
      |> get("/api/v1/domain-delegations/Apps.Customer.COM")

    assert body = json_response(conn, 200)
    assert body["domain"] == "apps.customer.com"

    assert [
             %{
               "name" => "_acme-challenge.apps.customer.com",
               "type" => "CNAME",
               "value" => target
             }
           ] =
             body["dns_records"]

    assert target =~ ~r/^[0-9a-f]{32}\.acme\.fluxvale\.app$/
  end

  test "same domain, same records — the value is stable across calls", %{conn: conn} do
    {user, _pat} = ApiPat.member!()

    read = fn ->
      conn
      |> auth(ApiPat.mint!(user, ["gateways:read"]))
      |> get("/api/v1/domain-delegations/apps.customer.com")
      |> json_response(200)
    end

    assert read.()["dns_records"] == read.()["dns_records"]
  end

  test "an invalid name is refused before any row exists", %{conn: conn} do
    {user, _pat} = ApiPat.member!()
    pat = ApiPat.mint!(user, ["gateways:read"])

    conn =
      conn
      |> auth(pat)
      |> get("/api/v1/domain-delegations/not%20a%20domain")

    assert %{"errors" => [error | _rest]} = json_response(conn, 400)
    assert error["detail"] =~ "valid domain"
  end

  test "a syntactically valid name over the registration length is refused", %{conn: conn} do
    {user, _pat} = ApiPat.member!()
    pat = ApiPat.mint!(user, ["gateways:read"])
    # Four valid labels, 252 characters — the register attribute's
    # max_length is 251 (the wildcard's "*." fills the DNS name).
    long = Enum.map_join([63, 63, 63, 60], ".", &String.duplicate("a", &1))
    assert String.length(long) == 252

    conn =
      conn
      |> auth(pat)
      |> get("/api/v1/domain-delegations/#{long}")

    assert %{"errors" => [error | _rest]} = json_response(conn, 400)
    assert error["detail"] =~ "valid domain"
  end

  test "FluxVale's own serving domain is refused — it is platform-served", %{conn: conn} do
    {user, _pat} = ApiPat.member!()
    pat = ApiPat.mint!(user, ["gateways:read"])
    base = Application.fetch_env!(:flux_vale, :instances_base_domain)

    conn =
      conn
      |> auth(pat)
      |> get("/api/v1/domain-delegations/#{base}")

    assert %{"errors" => [error | _rest]} = json_response(conn, 400)
    assert error["detail"] =~ "platform-served"
  end

  test "a read-only gateway scope is required", %{conn: conn} do
    {user, _pat} = ApiPat.member!()

    conn =
      conn
      |> auth(ApiPat.mint!(user, ["instances:read"]))
      |> get("/api/v1/domain-delegations/apps.customer.com")

    assert %{"errors" => [%{"status" => "403"} | _rest]} = json_response(conn, 403)
  end

  test "no token is 401", %{conn: conn} do
    conn = get(conn, "/api/v1/domain-delegations/apps.customer.com")
    assert %{"errors" => [%{"status" => "401"} | _rest]} = json_response(conn, 401)
  end

  test "a session cookie may read — any live actor", %{conn: conn} do
    user = AccountsFixtures.user!()
    {:ok, session_token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn =
      conn
      |> Plug.Test.init_test_session(%{"user_token" => session_token})
      |> get("/api/v1/domain-delegations/apps.customer.com")

    assert %{"domain" => "apps.customer.com"} = json_response(conn, 200)
  end
end
