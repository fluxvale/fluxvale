defmodule FluxValeWeb.TestInboxRouteTest do
  @moduledoc false

  # #22 exit criteria at the route level: an admin PAT reads the JSON
  # endpoint (curl returns the code); the 401/403 vocabulary holds; the
  # stock-preview UI sits behind the same admin gate. Memory storage is
  # global and this file is async: every test uses its own plus-addressed
  # mailbox and asserts through the address-filtered endpoint. The
  # disabled-config 404s live in test_inbox_gate_test (env mutation is not
  # async-safe).

  use FluxValeWeb.ConnCase, async: true

  alias AshAuthentication.Jwt
  alias FluxVale.Identity.User
  alias FluxVale.Mailer

  @admin_email "test-inbox-admin@fluxvale.com"
  @user_email "test-inbox-user@fluxvale.com"

  setup do
    admin =
      case User.get_by_email(@admin_email, authorize?: false) do
        {:ok, existing} ->
          existing

        {:error, _not_found} ->
          User.create!(@admin_email, %{platform_role: :admin}, authorize?: false)
      end

    %{admin: admin, admin_pat: mint_pat!(@admin_email, admin)}
  end

  describe "GET /test-inbox/api/mails with an admin PAT" do
    test "returns the captured list filtered by address", %{conn: conn, admin_pat: pat} do
      {:ok, _delivery} = Mailer.deliver_auth_code("test+route-list@fluxvale.com", "101010")

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> pat)
        |> get("/test-inbox/api/mails", email: "test+route-list@fluxvale.com")

      assert %{"mails" => mails} = json_response(conn, 200)

      assert Enum.any?(mails, fn mail ->
               mail["code"] == "101010" and mail["to"] == ["test+route-list@fluxvale.com"]
             end)

      # Deliberate charset suffix: plain application/json (Phoenix's default
      # utf-8 charset), not the vnd.api+json media type /api/v1 speaks
      assert ["application/json; charset=utf-8"] = get_resp_header(conn, "content-type")
    end
  end

  describe "GET /test-inbox/api/mails/latest with an admin PAT" do
    test "returns the latest mail and code — the E2E polling shape", %{
      conn: conn,
      admin_pat: pat
    } do
      {:ok, _delivery} = Mailer.deliver_auth_code("test+route-latest@fluxvale.com", "202020")

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> pat)
        |> get("/test-inbox/api/mails/latest", email: "test+route-latest@fluxvale.com")

      assert %{"mail" => mail} = json_response(conn, 200)
      assert mail["code"] == "202020"
      assert mail["to"] == ["test+route-latest@fluxvale.com"]
    end

    test "404 JSON while the code-send has not landed (poll until then)", %{
      conn: conn,
      admin_pat: pat
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> pat)
        |> get("/test-inbox/api/mails/latest", email: "test+route-none@fluxvale.com")

      assert %{"error" => _detail} = json_response(conn, 404)
    end
  end

  describe "the auth vocabulary" do
    test "401 plain JSON with no credentials", %{conn: conn} do
      conn = get(conn, "/test-inbox/api/mails")

      assert %{"error" => _detail} = json_response(conn, 401)
    end

    test "403 for an authenticated non-admin", %{conn: conn, admin: admin} do
      User.create!(@user_email, %{}, authorize?: false)
      user_pat = mint_pat!(@user_email, admin)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> user_pat)
        |> get("/test-inbox/api/mails")

      assert %{"error" => _detail} = json_response(conn, 403)
    end

    test "the admin session works too — same gate, session path", %{
      conn: conn,
      admin: admin
    } do
      {:ok, token, _claims} = Jwt.token_for_user(admin)

      conn =
        conn
        |> Plug.Test.init_test_session(%{"user_token" => token})
        |> get("/test-inbox/api/mails")

      assert %{"mails" => _mails} = json_response(conn, 200)
    end
  end

  describe "the mailbox UI (stock Swoosh preview behind the gates)" do
    test "an admin session reaches the preview", %{conn: conn, admin: admin} do
      # The preview's index redirects to the newest captured mail; ensure
      # at least one exists so the redirect is deterministic under async
      {:ok, _delivery} = Mailer.deliver_auth_code("test+route-ui@fluxvale.com", "303030")

      {:ok, token, _claims} = Jwt.token_for_user(admin)

      conn =
        conn
        |> Plug.Test.init_test_session(%{"user_token" => token})
        |> get("/test-inbox")

      assert conn.status == 302
      assert [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, "/test-inbox/")
    end

    test "unsigned-in humans bounce to /sign-in", %{conn: conn} do
      conn = get(conn, "/test-inbox")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/sign-in"]
    end

    test "a signed-in non-admin gets a bare 403", %{conn: conn} do
      user = User.create!(@user_email, %{}, authorize?: false)
      {:ok, token, _claims} = Jwt.token_for_user(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{"user_token" => token})
        |> get("/test-inbox")

      assert conn.status == 403
      # Empty body, not a JSON error document on an HTML route (CodeRabbit, #47)
      assert conn.resp_body == ""
    end
  end

  # mint_pat authorizes under the platform-admin policy (#23) — the admin
  # actor mints, the PAT belongs to `email`'s user (me_route_test's shape)
  defp mint_pat!(email, admin) do
    {:ok, token} = User.mint_pat(email, actor: admin)
    token
  end
end
