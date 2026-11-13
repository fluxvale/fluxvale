defmodule FluxValeWeb.Api.TokenRouteTest do
  @moduledoc false

  # #772: POST /api/v1/tokens — the CLI's scoped, short-lived token
  # mint. The caller's own PAT is the authority: the child may carry
  # only a subset of the caller's scopes and may not outlive it. The
  # success body is the one-time secret; every refusal is a JSON:API
  # error document.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  setup :verify_on_exit!

  alias AshAuthentication.Jwt
  alias FluxVale.Identity
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat
  alias FluxValeWeb.Api.TokenController

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  defp mint(conn, pat, params) do
    conn
    |> auth(pat)
    |> post("/api/v1/tokens", params)
  end

  defp rows(user), do: PersonalAccessToken.list_for_user!(user.id, actor: user)

  defp expires_at(body) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(body["expires_at"])
    expires_at
  end

  test "mints a token, and the child works in scope while an out-of-scope call is refused",
       %{conn: conn} do
    {user, caller} = ApiPat.member!()

    conn =
      mint(conn, caller, %{
        "name" => "ci-terraform",
        "scopes" => ["instances:read"],
        "ttl_seconds" => 3600
      })

    assert body = json_response(conn, 201)
    assert String.starts_with?(body["access_token"], "fvpat_")
    assert body["token_type"] == "Bearer"
    assert body["name"] == "ci-terraform"
    assert body["scope"] == "instances:read"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]

    # One hour, within a small clock skew.
    expires = expires_at(body)
    remaining = DateTime.diff(expires, DateTime.utc_now())
    assert remaining in 3590..3601

    # Provenance is system-written, never caller input: the minted-via
    # marker and the parent id the lineage check walks.
    row =
      user
      |> rows()
      |> Enum.find(&(&1.id == body["id"]))

    assert row.metadata["minted_via"] == "cli_token"
    assert is_binary(row.metadata["minted_parent_id"])

    # In scope: the instances list (any live token's own orgs read).
    in_scope =
      build_conn()
      |> auth(body["access_token"])
      |> get("/api/v1/instances")

    assert json_response(in_scope, 200)["data"] == []

    # Out of scope: a write route the token was not granted.
    denied =
      build_conn()
      |> auth(body["access_token"])
      |> patch("/api/v1/instances/whatever/stop")

    assert %{"errors" => [%{"status" => "403", "detail" => detail}]} =
             json_response(denied, 403)

    assert detail =~ "instances:write"
  end

  test "a caller cannot mint a scope it does not hold", %{conn: conn} do
    {user, caller} = ApiPat.member!(["instances:read"])
    before = length(rows(user))

    conn =
      mint(conn, caller, %{
        "scopes" => ["instances:write"],
        "ttl_seconds" => 3600
      })

    assert %{"errors" => [%{"status" => "403", "detail" => detail}]} =
             json_response(conn, 403)

    assert detail =~ "instances:write"
    assert length(rows(user)) == before, "a refused mint must not write a row"
  end

  test "a write grant covers its read scope for a narrower mint", %{conn: conn} do
    {_user, caller} = ApiPat.member!(["instances:write"])

    conn =
      mint(conn, caller, %{
        "scopes" => ["instances:read"],
        "ttl_seconds" => 60
      })

    assert json_response(conn, 201)["scope"] == "instances:read"
  end

  test "a child token may not outlive its caller", %{conn: conn} do
    user = AccountsFixtures.user!()
    caller_expiry = DateTime.add(DateTime.utc_now(), 120, :second)

    {:ok, %{token: caller}} =
      Identity.mint_pat(user, %{
        user_id: user.id,
        name: "short parent",
        scopes: ["instances:read"],
        expires_at: caller_expiry
      })

    conn =
      mint(conn, caller, %{
        "scopes" => ["instances:read"],
        "ttl_seconds" => 3600
      })

    assert body = json_response(conn, 201)
    # The parent's two minutes win over the requested hour.
    expires = expires_at(body)
    difference = DateTime.diff(expires, caller_expiry)
    assert difference in -1..1
  end

  test "an absurd ttl is capped at the one-year bound", %{conn: conn} do
    {_user, caller} = ApiPat.member!()

    conn =
      mint(conn, caller, %{
        "scopes" => ["instances:read"],
        "ttl_seconds" => 100 * 365 * 24 * 60 * 60
      })

    assert body = json_response(conn, 201)
    expires = expires_at(body)
    remaining = DateTime.diff(expires, DateTime.utc_now())
    assert remaining <= 365 * 24 * 60 * 60 + 5
  end

  test "the name is optional and trimmed", %{conn: conn} do
    {_user, caller} = ApiPat.member!()

    default = mint(conn, caller, %{"scopes" => [], "ttl_seconds" => 60})
    assert json_response(default, 201)["name"] == "fluxvale auth token"

    trimmed =
      mint(build_conn(), caller, %{
        "name" => "  nightly  ",
        "scopes" => [],
        "ttl_seconds" => 60
      })

    assert json_response(trimmed, 201)["name"] == "nightly"
  end

  test "malformed input is a 400, not a crash", %{conn: conn} do
    for {params, detail} <- [
          {%{"scopes" => "instances:read", "ttl_seconds" => 60}, "scopes must be"},
          {%{"scopes" => [7], "ttl_seconds" => 60}, "scopes must be"},
          {%{"scopes" => ["nope:read"], "ttl_seconds" => 60}, "unknown scope"},
          {%{"scopes" => ["instances:read", "instances:read"], "ttl_seconds" => 60},
           "duplicate scope"},
          {%{"scopes" => ["instances:read"], "ttl_seconds" => 0}, "ttl_seconds"},
          {%{"scopes" => ["instances:read"]}, "ttl_seconds"},
          {%{"scopes" => ["instances:read"], "ttl_seconds" => "60"}, "ttl_seconds"},
          {%{"name" => "   ", "scopes" => [], "ttl_seconds" => 60}, "name must not be blank"},
          {%{"name" => String.duplicate("a", 101), "scopes" => [], "ttl_seconds" => 60},
           "at most 100"},
          {%{"name" => 7, "scopes" => [], "ttl_seconds" => 60}, "name must be a string"}
        ] do
      # A fresh caller per row: the rate limiter keys on the token,
      # and this suite deliberately camps on the refusal paths.
      {_user, caller} = ApiPat.member!()
      conn = mint(conn, caller, params)

      assert %{"errors" => [%{"status" => "400", "detail" => message}]} =
               json_response(conn, 400)

      assert message =~ detail
    end
  end

  test "revoking the parent severs a minted child", %{conn: conn} do
    {user, caller} = ApiPat.member!(["instances:read"])

    response = mint(conn, caller, %{"scopes" => ["instances:read"], "ttl_seconds" => 3600})

    child =
      response
      |> json_response(201)
      |> Map.fetch!("access_token")

    hash = PersonalAccessToken.token_hash(caller)
    parent = PersonalAccessToken.get_by_token_hash!(hash, actor: user)

    assert {:ok, _revoked} = Identity.revoke_pat(user, parent)

    denied =
      build_conn()
      |> auth(child)
      |> get("/api/v1/instances")

    assert %{"errors" => [%{"status" => "401"}]} = json_response(denied, 401)
  end

  test "an expired ancestor refuses the child" do
    user = AccountsFixtures.user!()
    expired_at = DateTime.add(DateTime.utc_now(), -60, :second)

    {:ok, %{pat: parent}} =
      Identity.mint_pat(user, %{
        user_id: user.id,
        name: "expired parent",
        scopes: [],
        expires_at: expired_at
      })

    {:ok, %{token: child}} =
      Identity.mint_pat(user, %{
        user_id: user.id,
        name: "child",
        scopes: [],
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        metadata: %{"minted_parent_id" => parent.id}
      })

    denied =
      build_conn()
      |> auth(child)
      |> get("/api/v1/instances")

    assert %{"errors" => [%{"status" => "401"}]} = json_response(denied, 401)
  end

  test "a systemic mint failure is a 500 without echoing the changeset", %{conn: conn} do
    {_user, caller} = ApiPat.member!()

    stub(Identity, :mint_pat, fn _actor, _params -> {:error, :boom} end)

    conn = mint(conn, caller, %{"scopes" => [], "ttl_seconds" => 60})

    assert %{"errors" => [%{"status" => "500", "detail" => "the token could not be minted"}]} =
             json_response(conn, 500)
  end

  test "a session write is refused — machine writes need a token", %{conn: conn} do
    user = AccountsFixtures.user!()
    {:ok, session_token, _claims} = Jwt.token_for_user(user)

    conn =
      conn
      |> Plug.Test.init_test_session(%{"user_token" => session_token})
      |> post("/api/v1/tokens", %{"scopes" => [], "ttl_seconds" => 60})

    assert %{"errors" => [%{"status" => "401", "detail" => detail}]} =
             json_response(conn, 401)

    assert detail =~ "personal access token"
  end

  test "no credentials is a 401", %{conn: conn} do
    conn = post(conn, "/api/v1/tokens", %{"scopes" => [], "ttl_seconds" => 60})
    assert %{"errors" => [%{"status" => "401"}]} = json_response(conn, 401)
  end

  test "the controller refuses a conn without a PAT even outside the pipeline" do
    conn = TokenController.create(build_conn(), %{})
    assert %{"errors" => [%{"status" => "401"}]} = json_response(conn, 401)
  end
end
