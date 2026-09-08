defmodule FluxValeWeb.Api.MeRouteTest do
  @moduledoc false

  # #24 exit criteria: PAT hits /api/v1/me with a JSON:API document; no or
  # invalid token is a boring 401 error document. The 401/403 split lives
  # in the pipeline (RequireActor) vs ash_json_api's policy rendering.

  use FluxValeWeb.ConnCase, async: true

  alias AshAuthentication.Jwt
  alias AshAuthentication.TokenResource.Actions
  alias FluxVale.Identity.User

  setup do
    user = User.create!("me-route@fluxvale.com", %{}, authorize?: false)
    %{user: user, pat: mint_pat!("me-route@fluxvale.com")}
  end

  describe "GET /api/v1/me with a PAT" do
    test "returns the actor's JSON:API document", %{conn: conn, user: user, pat: pat} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> pat)
        |> get("/api/v1/me")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["type"] == "user"
      assert data["id"] == user.id

      # Public attributes are the API contract (ADR-0019 §1) — id, email,
      # platform_role and nothing else
      assert data["attributes"] == %{
               "email" => "me-route@fluxvale.com",
               "platform_role" => "user"
             }

      refute Map.has_key?(data["attributes"], "hashed_password")
    end
  end

  describe "GET /api/v1/me unauthenticated" do
    test "401 JSON:API error document with a Bearer challenge", %{conn: conn} do
      conn = get(conn, "/api/v1/me")

      assert %{"errors" => [error]} = json_response(conn, 401)
      assert error["status"] == "401"
      assert error["title"] == "Unauthorized"
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    test "401 for a garbage token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-jwt")
        |> get("/api/v1/me")

      assert %{"errors" => [%{"status" => "401"}]} = json_response(conn, 401)
    end

    test "401 for a revoked PAT (the 1-yr token never outlives its owner's access)", %{
      conn: conn,
      pat: pat
    } do
      :ok = Actions.revoke(FluxVale.Identity.Token, pat)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> pat)
        |> get("/api/v1/me")

      assert %{"errors" => [%{"status" => "401"}]} = json_response(conn, 401)
    end
  end

  describe "GET /api/v1/me session fallback" do
    test "authenticates from the token-backed session", %{conn: conn, user: user} do
      {:ok, token, _claims} = Jwt.token_for_user(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{"user_token" => token})
        |> get("/api/v1/me")

      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == user.id
    end
  end

  describe "versioning (OQ #9: URL prefix)" do
    test "the scaffold's unversioned mount is dead — /api/json/* is 404", %{conn: conn} do
      conn = get(conn, "/api/json/me")

      assert conn.status == 404
    end

    test "no unversioned alias — /api/me is 404, not a redirect", %{conn: conn} do
      conn = get(conn, "/api/me")

      assert conn.status == 404
    end
  end

  # mint_pat authorizes under the platform-admin policy (#23); the operator
  # path (authorize?: false) is exercised in pat_action_test
  defp mint_pat!(email) do
    admin =
      case User.get_by_email("admin@fluxvale.com", authorize?: false) do
        {:ok, existing} ->
          existing

        {:error, _not_found} ->
          User.create!("admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)
      end

    {:ok, token} = User.mint_pat(email, actor: admin)
    token
  end
end
