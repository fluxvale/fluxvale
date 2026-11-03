defmodule FluxValeWeb.Plugs.AuthorizeApiScopesTest do
  @moduledoc false

  # #360: the /api/v1 boundary gate in isolation — PAT scope checks
  # (deny-by-default included) and the session read-only rule. The
  # paths are fabricated on purpose: the S1 routes beyond /me do not
  # exist yet, and the plug's contract is method+path, not dispatch.
  # The mounted-pipeline behavior is proven in me_route_test.

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.Api.Scopes
  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxValeWeb.Plugs.AuthorizeApiScopes

  setup do
    user = User.create!("scope-gate@fluxvale.com", %{}, authorize?: false)
    %{user: user}
  end

  defp mint_pat!(user_id, scopes) do
    {:ok, %{pat: pat}} =
      Identity.mint_pat(nil, %{user_id: user_id, name: "gate test", scopes: scopes},
        authorize?: false
      )

    pat
  end

  # A fabricated /api/v1 request through the plug: method, path, and
  # the auth assigns — nothing else reaches the gate.
  defp gate(method, path, auth) do
    conn =
      method
      |> Plug.Test.conn(path)
      |> Plug.Conn.assign(:current_user, auth.user)
      |> Plug.Conn.assign(:api_pat, Map.get(auth, :pat))

    AuthorizeApiScopes.call(conn, [])
  end

  describe "PAT callers" do
    test "a token without the required scope is 403 with the missing scope named", %{
      user: user
    } do
      auth = %{user: user, pat: mint_pat!(user.id, [])}

      conn = gate("GET", "/api/v1/instances", auth)

      assert %{"errors" => [error]} = Jason.decode!(conn.resp_body)
      assert error["status"] == "403"
      assert error["title"] == "Forbidden"
      assert error["detail"] == "token is missing the required scope instances:read"

      # RequireActor's rendering posture exactly: bare media type,
      # charset-free, JSON:API error document.
      assert ["application/vnd.api+json"] = get_resp_header(conn, "content-type")
      assert conn.halted
    end

    test "a granted scope passes, and write implies read", %{user: user} do
      reader = %{user: user, pat: mint_pat!(user.id, ["instances:read"])}
      writer = %{user: user, pat: mint_pat!(user.id, ["instances:write"])}

      refute gate("GET", "/api/v1/instances", reader).halted
      refute gate("GET", "/api/v1/instances", writer).halted
    end

    test "read does not imply write: a read token is 403 on a write route", %{user: user} do
      auth = %{user: user, pat: mint_pat!(user.id, ["instances:read"])}

      conn = gate("DELETE", "/api/v1/instances/abc", auth)

      assert %{"errors" => [%{"detail" => detail}]} = Jason.decode!(conn.resp_body)
      assert detail == "token is missing the required scope instances:write"
    end

    test "an unmapped path is 403 — deny by default", %{user: user} do
      auth = %{user: user, pat: mint_pat!(user.id, Scopes.all_scopes())}

      conn = gate("GET", "/api/v1/unimagined", auth)

      assert %{"errors" => [%{"status" => "403", "detail" => detail}]} =
               Jason.decode!(conn.resp_body)

      assert detail == "no scope grants access to this path"
    end

    test "scopeless routes pass any live token (:any)", %{user: user} do
      auth = %{user: user, pat: mint_pat!(user.id, [])}

      refute gate("GET", "/api/v1/me", auth).halted
    end
  end

  describe "session callers" do
    test "GET passes — policies bite downstream", %{user: user} do
      refute gate("GET", "/api/v1/instances", %{user: user}).halted
      refute gate("HEAD", "/api/v1/instances", %{user: user}).halted
    end

    test "a write method is 401 with the PAT-only detail", %{user: user} do
      conn = gate("POST", "/api/v1/instances", %{user: user})

      assert %{"errors" => [error]} = Jason.decode!(conn.resp_body)
      assert error["status"] == "401"
      assert error["title"] == "Unauthorized"
      assert error["detail"] == "writes on /api/v1 require a personal access token"

      # RequireActor's 401 shape: the Bearer challenge rides too
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      assert ["application/vnd.api+json"] = get_resp_header(conn, "content-type")
      assert conn.halted
    end

    test "a session write is 401 even on a scopeless route", %{user: user} do
      conn = gate("POST", "/api/v1/me", %{user: user})

      assert %{"errors" => [%{"status" => "401"}]} = Jason.decode!(conn.resp_body)
    end
  end

  describe "scopeless plumbing" do
    test "swaggerui passes for every caller", %{user: user} do
      refute gate("GET", "/api/v1/swaggerui", %{user: user}).halted
      refute gate("GET", "/api/v1/swaggerui/index.css", %{user: user}).halted
    end

    # The unprefixed arm exists for direct invocations (tests); mounted,
    # the plug only ever sees /api/v1 paths.
    test "an unprefixed path still resolves (direct-invocation arm)", %{user: user} do
      refute gate("GET", "/instances", %{user: user}).halted
    end

    # Unreachable mounted (RequireActor halts first) — the direct-
    # invocation arm: an unauthenticated conn passes untouched; the
    # caller's own gate owns that case.
    test "a conn with neither PAT nor user passes untouched" do
      conn =
        "GET"
        |> Plug.Test.conn("/api/v1/instances")
        |> AuthorizeApiScopes.call([])

      refute conn.halted
    end
  end
end
