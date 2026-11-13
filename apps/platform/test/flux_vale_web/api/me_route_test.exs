defmodule FluxValeWeb.Api.MeRouteTest do
  @moduledoc false

  # #24 exit criteria: PAT hits /api/v1/me with a JSON:API document; no or
  # invalid token is a boring 401 error document. The 401/403 split lives
  # in the pipeline (RequireActor) vs ash_json_api's policy rendering.
  # #360: PATs are opaque fvpat_ values resolved through
  # personal_access_tokens — mint → use → revoke → 401 lives here, plus
  # the JWT-bearer refusal on /api/v1 (ADR-0019 Am. 1).
  # #484 (W2b): the meta's scope introspection — a PAT caller's exact
  # minted list, a session caller's absent key.

  use FluxValeWeb.ConnCase, async: true

  import FluxVale.TestSupport.AuthCodeHelpers
  import FluxVale.TestSupport.OAuthFixtures

  alias AshAuthentication.Jwt
  alias AshJsonApi.Resource.Info
  alias FluxVale.Identity
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Identity.User

  # The full S1 grant set — /me needs none of them, but the helper
  # future-proofs the suites that share its shape (slice 2's routes
  # ride the same tokens).
  @s1_scopes [
    "instances:read",
    "instances:write",
    "backups:read",
    "backups:write",
    "gateways:read",
    "gateways:write",
    "wallet:read",
    "catalog:read"
  ]

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
      # platform_role, username (#285 T2) and nothing else
      assert data["attributes"] == %{
               "email" => "me-route@fluxvale.com",
               "platform_role" => "user",
               "username" => "me-route"
             }

      refute Map.has_key?(data["attributes"], "hashed_password")
    end

    # #484 (W2b): the wire's scope introspection — MCP tool filtering
    # needs token knowledge on the wire (read domains are probeable
    # via the boundary's 403s; write domains are not). The calling
    # PAT's exact minted list rides top-level meta: a known subset
    # (not @s1_scopes) proves it's the token's list, the second mint
    # proves it's the CALLING token's, not the user's.
    test "meta renders the calling PAT's exact scope list", %{conn: conn, user: user} do
      subset = ["instances:read", "instances:write"]

      {:ok, %{token: first}} =
        Identity.mint_pat(nil, %{user_id: user.id, name: "known set", scopes: subset},
          authorize?: false
        )

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> first)
        |> get("/api/v1/me")

      assert %{"meta" => %{"scopes" => scopes}} = json_response(conn, 200)
      assert scopes == subset

      other = ["catalog:read"]

      {:ok, %{token: second}} =
        Identity.mint_pat(nil, %{user_id: user.id, name: "other set", scopes: other},
          authorize?: false
        )

      second_conn = pat_request(second)

      assert %{"meta" => %{"scopes" => ^other}} = json_response(second_conn, 200)
    end

    # #766: an OAuth access token's /me carries the same scope list
    # plus the RFC 8707 resource the MCP resource server checks.
    test "an OAuth access token renders meta.scopes and meta.resource", %{user: user} do
      client = client!()

      %{tokens: tokens} =
        tokens!(client, user, %{"scope" => "instances:read wallet:read"})

      conn = pat_request(tokens.access_token)

      assert %{"meta" => %{"scopes" => scopes, "resource" => resource}} =
               json_response(conn, 200)

      assert scopes == ["instances:read", "wallet:read"]
      assert resource == "https://mcp.fluxvale.com/mcp"
    end

    # A zero-scope PAT is a MINTED fact ("no grants"), not the absence
    # of one — the wire must render the empty list, never omit the key
    # (the omission belongs to session callers alone).
    test "a zero-scope PAT renders meta.scopes as an empty list, not an omission", %{
      user: user
    } do
      {:ok, %{token: token}} =
        Identity.mint_pat(nil, %{user_id: user.id, name: "zero scopes", scopes: []},
          authorize?: false
        )

      conn = pat_request(token)

      assert %{"meta" => %{"scopes" => scopes}} = json_response(conn, 200)
      assert scopes == []
    end

    test "the pinned field list serializes nothing private (#287 F1.4)" do
      # The legacy users.email column is gone; this reflection assert is
      # the rider's re-check: every field the /me route pins is a PUBLIC
      # attribute or calculation, so no private plumbing (an aggregate
      # like primary_address, an invite stamp) can ever leak into the
      # document — drift here fails loudly, not at the wire.
      routes = AshJsonApi.Resource.Info.routes(User)
      route = Enum.find(routes, &(&1.route == "/me"))

      assert route.default_fields == [:primary_email, :platform_role, :username]

      Enum.each(route.default_fields, fn field ->
        attribute = Ash.Resource.Info.attribute(User, field)
        calculation = Ash.Resource.Info.calculation(User, field)

        public? =
          (attribute && attribute.public?) || (calculation && calculation.public?)

        refute is_nil(public?), "field #{inspect(field)} is neither attribute nor calculation"
        assert public? == true, "field #{inspect(field)} is private — must never serialize"
      end)
    end

    # The T4 arm: after the REAL email operations promote a verified
    # secondary (AddEmail → the mailed code → VerifyEmail →
    # SetPrimaryEmail), "email" shows the new primary — the live row,
    # never a stale address.
    test "email is the promoted secondary after SetPrimaryEmail", %{conn: conn} do
      user = User.create!("promotable@fluxvale.com", %{}, authorize?: false)
      secondary = "promoted@fluxvale.test"

      assert {:ok, row} = FluxVale.Identity.add_email(user, secondary)
      code = mailbox_code()
      assert {:ok, _verified} = FluxVale.Identity.verify_email(user, row.id, code)
      assert {:ok, _promoted} = FluxVale.Identity.set_primary_email(user, row.id)

      pat = mint_pat!("promoted@fluxvale.test")

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> pat)
        |> get("/api/v1/me")

      # The key set is the contract (ADR-0019 §1); the email VALUE is the
      # live primary. get_by_email resolves the new address too — the PAT
      # mint above already rode it.
      assert %{"data" => %{"attributes" => attributes}} = json_response(conn, 200)

      assert attributes == %{
               "email" => secondary,
               "platform_role" => "user",
               "username" => "promotable"
             }
    end

    test "last_used_at is stamped once per granularity window, never blocking", %{pat: pat} do
      stamp = fn ->
        hash = PersonalAccessToken.token_hash(pat)
        {:ok, row} = PersonalAccessToken.get_by_token_hash(hash, authorize?: false)
        row.last_used_at
      end

      refute stamp.()

      # First use stamps; the immediate second use is inside the
      # granularity window and skips the write (same stamp, no churn).
      first_use = use_and_stamp(pat, stamp)
      assert first_use

      second_use = use_and_stamp(pat, stamp)
      assert second_use == first_use
    end
  end

  describe "PAT lifecycle on /api/v1 (mint → use → revoke → 401)" do
    test "a revoked PAT answers 401 on its next presentation", %{user: user} do
      pat = mint_pat!("me-route@fluxvale.com")

      conn = pat_request(pat)

      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == user.id

      assert {:ok, _revoked} = Identity.revoke_pat(nil, by_hash(pat), authorize?: false)

      refused_conn = pat_request(pat)

      assert %{"errors" => [%{"status" => "401"}]} = json_response(refused_conn, 401)
    end

    test "an expired PAT is 401 even though its row exists", %{conn: conn, user: user} do
      {:ok, %{token: pat}} =
        Identity.mint_pat(
          nil,
          %{
            user_id: user.id,
            name: "short",
            scopes: [],
            expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
          },
          authorize?: false
        )

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> pat)
        |> get("/api/v1/me")

      assert %{"errors" => [%{"status" => "401"}]} = json_response(conn, 401)
    end

    test "a stale last_used_at (older than the window) is re-stamped", %{user: user} do
      # Seed-only state: actions can never set an arbitrary last_used_at
      # (touch stamps now) — the house rule's "states actions can't
      # produce" case.
      {:ok, %{token: pat}} =
        Identity.mint_pat(nil, %{user_id: user.id, name: "stale", scopes: []}, authorize?: false)

      row = by_hash(pat)
      stale = DateTime.add(DateTime.utc_now(), -120, :second)
      Ash.Seed.update!(row, %{last_used_at: stale})

      conn = pat_request(pat)
      assert %{"data" => %{"id" => _id}} = json_response(conn, 200)

      assert DateTime.after?(by_hash(pat).last_used_at, stale)
    end
  end

  describe "GET /api/v1/me unauthenticated" do
    test "401 JSON:API error document with a Bearer challenge", %{conn: conn} do
      conn = get(conn, "/api/v1/me")

      assert %{"errors" => [error]} = json_response(conn, 401)
      assert error["status"] == "401"
      assert error["title"] == "Unauthorized"
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]

      # the bare media type, charset-free — byte-identical to ash_json_api's
      # own responses (CodeRabbit, #44)
      assert ["application/vnd.api+json"] = get_resp_header(conn, "content-type")
    end

    test "401 for a lower-case bearer scheme is still parsed (RFC 7235)", %{
      conn: conn,
      pat: pat
    } do
      conn =
        conn
        |> put_req_header("authorization", "bearer " <> pat)
        |> get("/api/v1/me")

      assert %{"data" => %{"id" => _id}} = json_response(conn, 200)
    end

    # The scheme rewrite is case-insensitive for ANY casing — an
    # exact-lowercase-only rewrite would leave "BEARER" (or "BeArEr")
    # uncanonicalized and 401 a valid token despite RFC 7235.
    test "an upper-case bearer scheme is parsed too (RFC 7235: any casing)", %{
      conn: conn,
      pat: pat
    } do
      conn =
        conn
        |> put_req_header("authorization", "BEARER " <> pat)
        |> get("/api/v1/me")

      assert %{"data" => %{"id" => _id}} = json_response(conn, 200)
    end

    test "401 for a garbage token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-even-a-pat")
        |> get("/api/v1/me")

      assert %{"errors" => [%{"status" => "401"}]} = json_response(conn, 401)
    end

    test "401 for a PAT-shaped value no row hashes to (unknown digest)", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer fvpat_never-minted-anywhere")
        |> get("/api/v1/me")

      assert %{"errors" => [%{"status" => "401"}]} = json_response(conn, 401)
    end

    # Multiple Authorization headers: a non-Bearer one is skipped, the
    # PAT header still resolves (RFC 7235 permits multiple auth
    # parameters; the plug reads only Bearer values). put/merge would
    # replace, so the extra header is appended to req_headers directly.
    test "a non-Bearer Authorization header does not disturb the PAT", %{
      conn: conn,
      pat: pat
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> pat)
        |> then(&%{&1 | req_headers: [{"authorization", "Basic dXNlcjpwYXNz"} | &1.req_headers]})
        |> get("/api/v1/me")

      assert %{"data" => %{"id" => _id}} = json_response(conn, 200)
    end

    # ADR-0019 Am. 1: /api/v1 takes opaque PATs only — the JWT bearer is
    # refused outright (the #23 mint is gone; zero JWT PATs were issued).
    test "401 for a JWT presented as a bearer on /api/v1", %{conn: conn, user: user} do
      {:ok, token, _claims} = Jwt.token_for_user(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
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

      assert %{"data" => %{"id" => id}, "meta" => meta} = json_response(conn, 200)
      assert id == user.id

      # No PAT ⇒ no introspection key (#484): the session shape stays
      # exactly what it was — empty meta, never a scopes key (no null,
      # no empty-list meaning).
      assert meta == %{}
    end

    # Bearer beats session, and BOTH halves of the answer come from the
    # bearer: Authenticate resolves the PAT first and short-circuits the
    # session lookup, so data.id and meta.scopes are one user's answer —
    # a session cookie can never blend its user with another token's
    # introspection (#484).
    test "a bearer over a session answers wholly from the bearer", %{conn: conn, user: user} do
      bearer_user = User.create!("bearer-wins@fluxvale.com", %{}, authorize?: false)
      bearer_scopes = ["wallet:read"]

      {:ok, %{token: bearer_pat}} =
        Identity.mint_pat(
          nil,
          %{
            user_id: bearer_user.id,
            name: "bearer over session",
            scopes: bearer_scopes
          },
          authorize?: false
        )

      {:ok, session_token, _claims} = Jwt.token_for_user(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{"user_token" => session_token})
        |> put_req_header("authorization", "Bearer " <> bearer_pat)
        |> get("/api/v1/me")

      assert %{"data" => %{"id" => id}, "meta" => %{"scopes" => scopes}} =
               json_response(conn, 200)

      assert id == bearer_user.id
      assert id != user.id
      assert scopes == bearer_scopes
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

  # The mint runs under the seeded admin (the create policy's other
  # arm); the operator path (authorize?: false, nil actor) is exercised
  # in mint_pat_test.
  defp mint_pat!(email) do
    admin =
      case User.get_by_email("admin@fluxvale.com", authorize?: false) do
        {:ok, existing} ->
          existing

        {:error, _not_found} ->
          User.create!("admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)
      end

    {:ok, user} = User.get_by_email(email, authorize?: false)

    {:ok, %{token: token}} =
      Identity.mint_pat(admin, %{user_id: user.id, name: "me-route test", scopes: @s1_scopes})

    token
  end

  defp by_hash(pat) do
    hash = PersonalAccessToken.token_hash(pat)
    {:ok, row} = PersonalAccessToken.get_by_token_hash(hash, authorize?: false)
    row
  end

  # One authenticated /me round-trip through the real router, then the
  # row's stamp — the granularity assertions read it between uses.
  defp use_and_stamp(pat, stamp) do
    conn = pat_request(pat)

    assert %{"data" => %{"id" => _id}} = Jason.decode!(conn.resp_body)

    stamp.()
  end

  defp pat_request(pat) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> pat)
    |> get("/api/v1/me")
  end
end
