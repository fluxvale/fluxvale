defmodule FluxValeWeb.Plugs.ApiAuditTest do
  @moduledoc false

  # #360 slice 5: one audit row per PAT-authenticated call through
  # the real :api_auth pipeline — 200s, policy 403s, scope 403s, 429s
  # all captured by the one register_before_send path; session and
  # unauthenticated calls write nothing. The mint/revoke rows join
  # the story in the narrative test — the operator's ordered query.

  use FluxValeWeb.ConnCase, async: true

  import Ecto.Query

  alias AshAuthentication.Jwt
  alias FluxVale.Api.AuditEvent
  alias FluxVale.Identity
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Identity.User
  alias FluxVale.Ops.AccessRule
  alias FluxVale.Repo
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat

  setup do
    user = User.create!("audit-plug@fluxvale.com", %{}, authorize?: false)

    {:ok, %{token: token, pat: pat}} =
      Identity.mint_pat(nil, %{user_id: user.id, name: "audit test", scopes: []},
        authorize?: false
      )

    %{user: user, token: token, pat: pat}
  end

  defp me_request(token) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> get("/api/v1/me")
  end

  describe "mounted in :api_auth — one row per PAT call" do
    test "a 200 leaves exactly one complete request row", %{token: token, pat: pat} do
      assert json_response(me_request(token), 200)["data"]

      assert [%{kind: :mint}, %{kind: :request} = row] = audit_rows(pat.id)

      assert row.personal_access_token_id == pat.id
      assert row.method == "GET"
      assert row.path == "/api/v1/me"
      assert row.status_code == 200
      assert row.actor_id == nil
    end

    test "a scope-refused call (403) is audited", %{token: token, pat: pat} do
      # The setup token holds no scopes — catalog:read is missing.
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> get("/api/v1/apps")

      assert %{"errors" => [%{"status" => "403", "detail" => detail}]} = json_response(conn, 403)
      assert detail =~ "missing the required scope"

      assert [%{kind: :mint}, %{kind: :request} = row] = audit_rows(pat.id)
      assert row.method == "GET"
      assert row.path == "/api/v1/apps"
      assert row.status_code == 403
    end

    test "an AccessRule-denied call (401) is audited — api_pat survives the denial" do
      # The access gate nils current_user AFTER the bearer resolved
      # (api_pat stays assigned), so RequireActor answers 401 — the
      # row must land anyway, the moduledoc's own claim. The denied
      # user needs its own token: the setup user's fluxvale.com
      # address is allowlisted under this rule.
      AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)

      denied = User.create!("audit-denied@example.com", %{}, authorize?: false)

      {:ok, %{token: denied_token, pat: denied_pat}} =
        Identity.mint_pat(nil, %{user_id: denied.id, name: "denied", scopes: []},
          authorize?: false
        )

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> denied_token)
        |> get("/api/v1/me")

      assert %{"errors" => [%{"status" => "401"}]} = json_response(conn, 401)

      assert [%{kind: :mint}, %{kind: :request} = row] = audit_rows(denied_pat.id)
      assert row.personal_access_token_id == denied_pat.id
      assert row.method == "GET"
      assert row.path == "/api/v1/me"
      assert row.status_code == 401
    end

    test "a policy-refused call (403 paywall) is audited" do
      # ApiPat.member!'s org is JIT-provisioned: welcome-funded, never
      # paid — the gateway mint's paid-once gate refuses (the paywall
      # suite's own posture proof, just asserted on the audit row).
      {user, _full_scoped_pat} = ApiPat.member!()
      address = AccountsFixtures.primary_address!(user)
      raw = ApiPat.mint!(address, ["gateways:write"])

      hash = PersonalAccessToken.token_hash(raw)
      {:ok, pat} = PersonalAccessToken.get_by_token_hash(hash, authorize?: false)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways", %{
          "data" => %{
            "type" => "access_gateway",
            "attributes" => %{"tailnet_domain" => "example.ts.net", "auth_key" => "tskey-test"}
          }
        })

      assert %{"errors" => [%{"status" => "403"} | _rest]} = json_response(conn, 403)

      assert [%{kind: :mint}, %{kind: :request} = row] = audit_rows(pat.id)
      assert row.method == "POST"
      assert row.path == "/api/v1/access-gateways"
      assert row.status_code == 403
    end

    test "a rate-refused call (429) is audited — the trail and the meter are separate stores", %{
      token: token,
      pat: pat
    } do
      # test.exs pins max 5 / window 86_400: the sixth call is refused.
      for _n <- 1..5, do: assert(json_response(me_request(token), 200)["data"])
      assert %{"errors" => [%{"status" => "429"}]} = json_response(me_request(token), 429)

      statuses =
        pat.id
        |> audit_rows()
        |> request_statuses()

      assert statuses == [200, 200, 200, 200, 200, 429]
    end

    test "the query answers what did this token do: mint → 200 → 403 → revoke", %{
      user: user,
      token: token,
      pat: pat
    } do
      assert json_response(me_request(token), 200)["data"]

      scope_refused =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> get("/api/v1/apps")

      assert json_response(scope_refused, 403)

      assert {:ok, _revoked} = Identity.revoke_pat(user, pat)

      assert [
               %{kind: :mint, actor_id: nil, method: nil},
               %{kind: :request, status_code: 200},
               %{kind: :request, status_code: 403},
               %{kind: :revoke, actor_id: revoke_actor, method: nil}
             ] = audit_rows(pat.id)

      assert revoke_actor == user.id
    end
  end

  describe "who gets no row" do
    test "the query string never lands in the row (structural: request_path carries no query)", %{
      token: token,
      pat: pat
    } do
      # A token-shaped query param on purpose: even a caller who puts
      # the VALUE in the URL cannot leak it into the trail.
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> get("/api/v1/me?token=" <> token)

      assert json_response(conn, 200)["data"]

      assert [%{kind: :mint}, %{kind: :request} = row] = audit_rows(pat.id)
      assert row.path == "/api/v1/me"
    end

    test "a route-miss 404 is audited", %{user: user} do
      # The route needs its scope granted so the refusal is the MISS,
      # not the scope gate.
      {:ok, %{token: scoped, pat: scoped_pat}} =
        Identity.mint_pat(user, %{user_id: user.id, name: "scoped", scopes: ["catalog:read"]})

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> scoped)
        |> get("/api/v1/apps/no-such-slug")

      assert %{"errors" => [%{"status" => "404"} | _rest]} = json_response(conn, 404)

      assert [%{kind: :mint}, %{kind: :request} = row] = audit_rows(scoped_pat.id)
      assert row.personal_access_token_id == scoped_pat.id
      assert row.status_code == 404
      assert row.path == "/api/v1/apps/no-such-slug"
    end

    test "a session-authenticated call writes nothing — metering is a PAT concept", %{
      user: user,
      pat: pat
    } do
      {:ok, session_jwt, _claims} = Jwt.token_for_user(user)

      session_conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{"user_token" => session_jwt})
        |> get("/api/v1/me")

      assert json_response(session_conn, 200)["data"]

      # The setup's mint row is still the whole trail.
      assert [%{kind: :mint}] = audit_rows(pat.id)
    end

    test "an unauthenticated call writes nothing — nothing to attribute" do
      conn = get(Phoenix.ConnTest.build_conn(), "/api/v1/me")

      assert %{"errors" => [%{"status" => "401"}]} = json_response(conn, 401)

      # Sandbox-isolated: NO request row exists at all.
      query = from(e in "api_audit_events", select: e.id, where: e.kind == "request")
      assert [] = Repo.all(query)
    end
  end

  describe "direct invocation (the unmounted arm)" do
    alias FluxValeWeb.Plugs.ApiAudit

    test "a conn with no PAT registers nothing", %{pat: pat} do
      conn =
        "GET"
        |> Plug.Test.conn("/api/v1/me")
        |> ApiAudit.call([])
        |> Plug.Conn.send_resp(200, "")

      assert conn.state == :sent
      assert [%{kind: :mint}] = audit_rows(pat.id)
    end

    test "a giant path is capped at the storage bound", %{pat: pat} do
      conn =
        "GET"
        |> Plug.Test.conn("/api/v1/" <> String.duplicate("a", 3000))
        |> Plug.Conn.assign(:api_pat, pat)
        |> ApiAudit.call([])
        |> Plug.Conn.send_resp(418, "")

      assert conn.state == :sent

      assert [%{kind: :mint}, %{kind: :request} = row] = audit_rows(pat.id)
      assert String.length(row.path) == 2048
      assert row.status_code == 418
    end

    # The cap validates codepoints, so the cut must be codepoint-true
    # too (the instance_k8s truncate posture): a grapheme slice would
    # hand the write more than the cap and the row would drop silently
    # (RecordAuditEvent swallows validation).
    test "a giant multi-codepoint path is capped in codepoints, and the row survives", %{pat: pat} do
      # "a" plus combining diaeresis: two codepoints, one grapheme.
      graphemes = String.duplicate("a\u0308", 3000)

      conn =
        "GET"
        |> Plug.Test.conn("/api/v1/" <> graphemes)
        |> Plug.Conn.assign(:api_pat, pat)
        |> ApiAudit.call([])
        |> Plug.Conn.send_resp(418, "")

      assert conn.state == :sent

      assert [%{kind: :mint}, %{kind: :request} = row] = audit_rows(pat.id)
      # String.length counts graphemes (1028 here: 8 ASCII + 1020
      # two-codepoint pairs) - the cap and the cut are codepoint-true,
      # so the assertion counts that unit.
      assert length(String.codepoints(row.path)) == 2048
      assert row.status_code == 418
    end
  end

  defp audit_rows(token_id) do
    AuditEvent
    |> Ash.Query.for_read(:by_token, %{token_id: token_id})
    |> Ash.Query.sort([:created_at, :id])
    |> Ash.read!(authorize?: false)
  end

  defp request_statuses(rows) do
    rows
    |> Enum.filter(&(&1.kind == :request))
    |> Enum.map(& &1.status_code)
  end
end
