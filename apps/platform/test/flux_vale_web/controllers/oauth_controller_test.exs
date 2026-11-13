defmodule FluxValeWeb.OAuthControllerTest do
  @moduledoc false

  # #766: the authorization-server wire — metadata, DCR, the consent
  # page and its signed decision, the token endpoint's two grants and
  # their refusal matrix, revocation, CORS, and the per-IP windows.

  use FluxValeWeb.ConnCase, async: false

  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.Api.Scopes
  alias FluxVale.Identity
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth.AuditEvent
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.Endpoint
  alias FluxValeWeb.Plugs.OAuthRateLimit

  require Ash.Query

  @consent_salt "oauth consent"

  describe "GET /.well-known/oauth-authorization-server" do
    test "serves RFC 8414 metadata with S256, public clients, and offline_access", %{conn: conn} do
      conn = get(conn, "/.well-known/oauth-authorization-server")
      body = json_response(conn, 200)

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert body["issuer"] == Endpoint.url()
      assert body["authorization_endpoint"] == Endpoint.url() <> "/oauth/authorize"
      assert body["token_endpoint"] == Endpoint.url() <> "/oauth/token"
      assert body["registration_endpoint"] == Endpoint.url() <> "/oauth/register"
      assert body["revocation_endpoint"] == Endpoint.url() <> "/oauth/revoke"
      assert body["response_types_supported"] == ["code"]
      assert body["grant_types_supported"] == ["authorization_code", "refresh_token"]
      assert body["token_endpoint_auth_methods_supported"] == ["none"]
      assert body["revocation_endpoint_auth_methods_supported"] == ["none"]
      assert body["code_challenge_methods_supported"] == ["S256"]
      assert body["authorization_response_iss_parameter_supported"] == true
      assert "offline_access" in body["scopes_supported"]

      assert Enum.sort(body["scopes_supported"] -- ["offline_access"]) ==
               Enum.sort(Scopes.all_scopes())
    end
  end

  describe "CORS preflight" do
    test "answers the token endpoint's OPTIONS", %{conn: conn} do
      conn = options(conn, "/oauth/token")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, OPTIONS"]

      assert get_resp_header(conn, "access-control-allow-headers") == [
               "content-type, authorization"
             ]
    end
  end

  describe "POST /oauth/register" do
    test "registers a public client and returns the RFC 7591 shape", %{conn: conn} do
      conn = json_post(conn, "/oauth/register", registration_params())

      body = json_response(conn, 201)
      assert body["client_id"] =~ ~r/^fvoc_/
      assert is_integer(body["client_id_issued_at"])
      assert body["client_name"] == "Claude Code"
      assert body["redirect_uris"] == ["http://127.0.0.1:53682/callback"]
      assert body["grant_types"] == ["authorization_code", "refresh_token"]
      assert body["response_types"] == ["code"]
      assert body["token_endpoint_auth_method"] == "none"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end

    test "refuses an unsupported redirect URI with the RFC error", %{conn: conn} do
      conn =
        json_post(
          conn,
          "/oauth/register",
          registration_params(%{"redirect_uris" => ["http://evil.example/cb"]})
        )

      body = json_response(conn, 400)
      assert body["error"] == "invalid_redirect_uri"
    end

    test "refuses malformed metadata", %{conn: conn} do
      conn = json_post(conn, "/oauth/register", %{"redirect_uris" => []})
      assert json_response(conn, 400)["error"] == "invalid_client_metadata"
    end

    test "an unknown scope and the resource backstop are metadata errors", %{conn: conn} do
      unknown_scope = registration_params(%{"scope" => "instances:read admin"})
      response = json_post(conn, "/oauth/register", unknown_scope)
      assert json_response(response, 400)["error"] == "invalid_client_metadata"

      uris = for n <- 1..6, do: "https://client.example/cb#{n}"
      too_many = registration_params(%{"redirect_uris" => uris})
      too_many_response = json_post(conn, "/oauth/register", too_many)
      body = json_response(too_many_response, 400)
      assert body["error"] == "invalid_client_metadata"
    end

    test "the per-IP window answers 429 with Retry-After", %{conn: conn} do
      put_bucket_limit(:register, 1)
      first = with_ip(conn, {10, 10, 0, 1})

      assert json_response(json_post(first, "/oauth/register", registration_params()), 201)

      second = with_ip(conn, {10, 10, 0, 1})

      response =
        json_post(second, "/oauth/register", registration_params(%{"client_name" => "Second"}))

      body = json_response(response, 429)
      assert body["error"] == "temporarily_unavailable"
      retry_headers = get_resp_header(response, "retry-after")
      retry_after = hd(retry_headers)
      assert retry_after =~ ~r/^\d+$/
    end

    test "the global client cap answers 429", %{conn: conn} do
      put_client_cap(1)
      first = with_ip(conn, {10, 10, 0, 2})

      assert json_response(json_post(first, "/oauth/register", registration_params()), 201)

      second = with_ip(conn, {10, 10, 0, 3})

      response =
        json_post(second, "/oauth/register", registration_params(%{"client_name" => "Second"}))

      assert json_response(response, 429)["error"] == "temporarily_unavailable"
    end
  end

  describe "GET /oauth/authorize" do
    test "sends an anonymous visitor to sign-in with the full authorize URL", %{conn: conn} do
      client = client!()

      params = authorize_params(client)
      response = get(conn, "/oauth/authorize?" <> URI.encode_query(params))

      assert redirected_to(response, 302) =~ "/sign-in?return_to="

      location_headers = get_resp_header(response, "location")
      location = hd(location_headers)
      [_path, encoded] = String.split(location, "return_to=", parts: 2)

      assert URI.decode_www_form(encoded) =~ "/oauth/authorize?client_id=#{client.client_id}"
    end

    test "an unknown client or redirect is a local error page, never a redirect", %{conn: conn} do
      client = client!()
      unknown = authorize_params(client, %{"client_id" => "fvoc_unknown"})
      unknown_response = get(conn, "/oauth/authorize?" <> URI.encode_query(unknown))
      assert html_response(unknown_response, 400) =~ "oauth-error"

      bad = authorize_params(client, %{"redirect_uri" => "https://evil.example/cb"})
      bad_response = get(conn, "/oauth/authorize?" <> URI.encode_query(bad))
      assert html_response(bad_response, 400) =~ "oauth-error"
      assert get_resp_header(bad_response, "location") == []
    end

    test "post-validation errors redirect with error, state, and iss", %{conn: conn} do
      client = client!()
      params = authorize_params(client, %{"response_type" => "token", "state" => "st-1"})

      response = get(conn, "/oauth/authorize?" <> URI.encode_query(params))
      location = redirected_to(response, 302)
      parsed = URI.parse(location)
      query = URI.decode_query(parsed.query)

      assert query["error"] == "unsupported_response_type"
      assert query["state"] == "st-1"
      assert query["iss"] == Endpoint.url()
    end

    test "the authorize and consent POST share the per-IP window", %{conn: conn} do
      put_bucket_limit(:authorize, 1)
      client = client!()
      params = authorize_params(client)

      first = with_ip(conn, {10, 30, 0, 1})
      response = get(first, "/oauth/authorize?" <> URI.encode_query(params))
      assert response.status in [200, 302]

      second = with_ip(conn, {10, 30, 0, 1})
      second_response = get(second, "/oauth/authorize?" <> URI.encode_query(params))
      assert html_response(second_response, 429) =~ "Too many authorization attempts"

      third = with_ip(conn, {10, 30, 0, 1})

      consent_response =
        post(third, "/oauth/authorize", %{"consent_token" => "x", "decision" => "approve"})

      assert html_response(consent_response, 429) =~ "Too many authorization attempts"
    end

    test "a missing consent token is a local error page", %{conn: conn} do
      client = client!()
      user = user!()

      response = consent_post(user, %{"decision" => "approve", "consent_token" => nil})

      assert html_response(response, 400) =~ "expired"
      _client = client
      _conn = conn
    end

    test "a signed-in user sees the client, redirect host, and product-language scopes", %{
      conn: conn
    } do
      client = client!()
      user = user!()

      signed = SessionHelpers.sign_in(conn, user)
      params = authorize_params(client)
      response = get(signed, "/oauth/authorize?" <> URI.encode_query(params))

      html = html_response(response, 200)
      assert html =~ "MCP Test Client"
      assert html =~ "127.0.0.1:53682"
      assert html =~ user.username
      assert html =~ Scopes.describe("instances:read")
      assert html =~ "instances:read"
      assert html =~ "all of your FluxVale organizations"
      assert html =~ "revokes access immediately"
      assert html =~ "oauth-approve"
      assert html =~ "oauth-deny"
    end
  end

  describe "POST /oauth/authorize — the consent decision" do
    test "approve redirects with a code, state, and iss", %{conn: conn} do
      client = client!()
      user = user!()
      signed = SessionHelpers.sign_in(conn, user)
      token = consent_token!(signed, client, %{"state" => "state-approve"})

      response = consent_post(user, %{"consent_token" => token, "decision" => "approve"})

      query = redirect_query(response)
      assert query["code"] =~ ~r/^fvac_/
      assert query["state"] == "state-approve"
      assert query["iss"] == Endpoint.url()
      assert [%{kind: :authorize_approved}] = oauth_audit(:authorize_approved)
      assert [%{kind: :code_issued}] = oauth_audit(:code_issued)
    end

    test "deny redirects with access_denied and audits the decision", %{conn: conn} do
      client = client!()
      user = user!()
      signed = SessionHelpers.sign_in(conn, user)
      token = consent_token!(signed, client, %{"state" => "state-deny"})

      response = consent_post(user, %{"consent_token" => token, "decision" => "deny"})

      query = redirect_query(response)
      assert query["error"] == "access_denied"
      assert query["state"] == "state-deny"
      assert query["iss"] == Endpoint.url()
      assert [%{kind: :authorize_denied, actor_id: actor_id}] = oauth_audit(:authorize_denied)
      assert actor_id == user.id
    end

    test "extra form fields cannot alter the signed request", %{conn: conn} do
      client = client!()
      user = user!()
      signed = SessionHelpers.sign_in(conn, user)
      token = consent_token!(signed, client)

      response =
        consent_post(user, %{
          "consent_token" => token,
          "decision" => "approve",
          "redirect_uri" => "https://evil.example/cb",
          "scopes" => "wallet:read"
        })

      location = redirected_to(response, 302)
      assert String.starts_with?(location, redirect_uri())
      assert redirect_query(response)["code"] =~ ~r/^fvac_/
    end

    test "an altered or expired consent token is a local error page", %{conn: _conn} do
      client = client!()
      user = user!()

      response = consent_post(user, %{"consent_token" => "garbage", "decision" => "approve"})

      assert html_response(response, 400) =~ "expired"

      expired =
        Phoenix.Token.sign(Endpoint, @consent_salt, consent_payload(client, user),
          signed_at: System.system_time(:second) - 1_000
        )

      expired_response =
        consent_post(user, %{"consent_token" => expired, "decision" => "approve"})

      assert html_response(expired_response, 400) =~ "expired"
    end

    test "a signed-in user cannot approve another user's request", %{conn: _conn} do
      client = client!()
      user = user!()
      other = user!()

      token = Phoenix.Token.sign(Endpoint, @consent_salt, consent_payload(client, other))

      response = consent_post(user, %{"consent_token" => token, "decision" => "approve"})

      assert html_response(response, 400) =~ "session changed"
    end

    test "a consent token naming a client that no longer resolves is refused", %{conn: _conn} do
      user = user!()

      base = consent_payload(client!(), user)
      payload = Map.put(base, :client_id, nil)

      token = Phoenix.Token.sign(Endpoint, @consent_salt, payload)

      response = consent_post(user, %{"consent_token" => token, "decision" => "approve"})

      assert html_response(response, 400) =~ "no longer registered"
    end

    test "a consent token naming an unknown client id is refused", %{conn: _conn} do
      user = user!()

      base = consent_payload(client!(), user)
      payload = Map.put(base, :client_id, "fvoc_gone")

      token = Phoenix.Token.sign(Endpoint, @consent_salt, payload)

      response = consent_post(user, %{"consent_token" => token, "decision" => "approve"})

      assert html_response(response, 400) =~ "no longer registered"
    end

    test "a custom-scheme redirect without an authority renders its whole value", %{
      conn: conn
    } do
      {:ok, client} =
        FluxVale.OAuth.register_client(%{
          "client_name" => "Custom scheme",
          "redirect_uris" => ["claude:callback"]
        })

      user = user!()
      signed = SessionHelpers.sign_in(conn, user)
      params = authorize_params(client, %{"redirect_uri" => "claude:callback"})

      response = get(signed, "/oauth/authorize?" <> URI.encode_query(params))

      assert html_response(response, 200) =~ "claude:callback"
    end

    test "an unrecognized decision is refused", %{conn: conn} do
      client = client!()
      user = user!()
      signed = SessionHelpers.sign_in(conn, user)
      token = consent_token!(signed, client)

      response = consent_post(user, %{"consent_token" => token, "decision" => "maybe"})

      assert html_response(response, 400) =~ "not recognized"
    end
  end

  describe "POST /oauth/token — authorization_code" do
    test "exchanges a code, then rotates the refresh token", %{conn: conn} do
      client = client!()
      user = user!()
      code = authorize_code!(conn, client, user, %{"scope" => "instances:read wallet:read"})

      response = form_post(conn, "/oauth/token", token_params(client, code))
      body = json_response(response, 200)

      assert body["access_token"] =~ ~r/^fvoat_/
      assert body["refresh_token"] =~ ~r/^fvort_/
      assert body["token_type"] == "Bearer"
      assert body["expires_in"] == 3600
      assert body["scope"] == "instances:read wallet:read"
      assert get_resp_header(response, "cache-control") == ["no-store"]

      refreshed_response =
        form_post(conn, "/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => body["refresh_token"],
          "client_id" => client.client_id,
          "resource" => resource()
        })

      refreshed = json_response(refreshed_response, 200)
      assert refreshed["access_token"] =~ ~r/^fvoat_/
      assert refreshed["refresh_token"] =~ ~r/^fvort_/
      assert refreshed["refresh_token"] != body["refresh_token"]
    end

    test "a wrong verifier, mismatched redirect, and mismatched resource are protocol errors", %{
      conn: conn
    } do
      client = client!()
      user = user!()
      code = authorize_code!(conn, client, user)

      wrong_verifier =
        form_post(conn, "/oauth/token", %{
          token_params(client, code)
          | "code_verifier" => verifier()
        })

      assert json_response(wrong_verifier, 400)["error"] == "invalid_grant"

      wrong_redirect =
        form_post(conn, "/oauth/token", %{
          token_params(client, code)
          | "redirect_uri" => "http://127.0.0.1:53682/other"
        })

      assert json_response(wrong_redirect, 400)["error"] == "invalid_grant"

      wrong_resource =
        form_post(conn, "/oauth/token", %{
          token_params(client, code)
          | "resource" => "https://mcp.evil.example/mcp"
        })

      assert json_response(wrong_resource, 400)["error"] == "invalid_target"
    end

    test "a reused code is invalid_grant and revokes the family", %{conn: conn} do
      client = client!()
      user = user!()
      code = authorize_code!(conn, client, user)

      assert json_response(form_post(conn, "/oauth/token", token_params(client, code)), 200)
      second = form_post(conn, "/oauth/token", token_params(client, code))
      assert json_response(second, 400)["error"] == "invalid_grant"

      rows = PersonalAccessToken.list_oauth_tokens!(user.id, authorize?: false)
      assert Enum.all?(rows, &(not is_nil(&1.revoked_at)))
    end

    test "an unsupported grant type is refused", %{conn: conn} do
      response = form_post(conn, "/oauth/token", %{"grant_type" => "client_credentials"})
      assert json_response(response, 400)["error"] == "unsupported_grant_type"
    end

    test "the token endpoint's per-IP window answers 429", %{conn: conn} do
      put_bucket_limit(:token, 1)
      first = with_ip(conn, {10, 20, 0, 1})
      first_response = form_post(first, "/oauth/token", %{"grant_type" => "client_credentials"})
      assert json_response(first_response, 400)

      second = with_ip(conn, {10, 20, 0, 1})
      second_response = form_post(second, "/oauth/token", %{"grant_type" => "client_credentials"})
      assert json_response(second_response, 429)["error"] == "temporarily_unavailable"
    end
  end

  describe "POST /oauth/revoke" do
    test "revoking the access token severs the family and the next API call is 401", %{
      conn: conn
    } do
      client = client!()
      user = user!()
      code = authorize_code!(conn, client, user)
      tokens = json_response(form_post(conn, "/oauth/token", token_params(client, code)), 200)

      first_authed =
        conn
        |> put_req_header("authorization", "Bearer " <> tokens["access_token"])
        |> get("/api/v1/me")

      assert json_response(first_authed, 200)

      revoked =
        form_post(conn, "/oauth/revoke", %{
          "token" => tokens["access_token"],
          "client_id" => client.client_id
        })

      assert revoked.status == 200
      assert revoked.resp_body == ""

      second_authed =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> tokens["access_token"])
        |> get("/api/v1/me")

      assert json_response(second_authed, 401)
    end

    test "the revoke endpoint's per-IP window answers 429", %{conn: conn} do
      put_bucket_limit(:revoke, 1)
      first = with_ip(conn, {10, 40, 0, 1})

      assert form_post(first, "/oauth/revoke", %{
               "token" => "fvoat_unknown",
               "client_id" => "fvoc_unknown"
             }).status == 200

      second = with_ip(conn, {10, 40, 0, 1})

      response =
        form_post(second, "/oauth/revoke", %{
          "token" => "fvoat_unknown",
          "client_id" => "fvoc_unknown"
        })

      assert json_response(response, 429)["error"] == "temporarily_unavailable"
    end

    test "unknown tokens and missing parameters", %{conn: conn} do
      assert form_post(conn, "/oauth/revoke", %{
               "token" => "fvoat_unknown",
               "client_id" => "fvoc_unknown"
             }).status == 200

      assert json_response(form_post(conn, "/oauth/revoke", %{}), 400)["error"] ==
               "invalid_request"
    end
  end

  describe "PAT compatibility" do
    test "a personal access token still authenticates /api/v1/me", %{conn: conn} do
      user = user!()

      {:ok, %{token: pat}} =
        Identity.mint_pat(nil, %{user_id: user.id, name: "still works", scopes: []},
          authorize?: false
        )

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> pat)
        |> get("/api/v1/me")

      assert json_response(conn, 200)["data"]["type"] == "user"
    end
  end

  # ---- helpers ----

  defp registration_params(overrides \\ %{}) do
    Map.merge(
      %{
        "client_name" => "Claude Code",
        "redirect_uris" => [redirect_uri()],
        "scope" => "instances:read offline_access"
      },
      overrides
    )
  end

  defp authorize_params(client, overrides \\ %{}) do
    Map.merge(
      %{
        "client_id" => client.client_id,
        "redirect_uri" => redirect_uri(),
        "response_type" => "code",
        "scope" => "instances:read",
        "code_challenge" => challenge(verifier()),
        "code_challenge_method" => "S256",
        "resource" => resource(),
        "state" => "state-#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end

  defp consent_payload(client, user) do
    %{
      user_id: user.id,
      client_id: client.client_id,
      redirect_uri: redirect_uri(),
      scopes: ["instances:read"],
      resource: resource(),
      resource_defaulted: false,
      code_challenge: challenge(verifier()),
      state: "state"
    }
  end

  defp consent_token!(conn, client, overrides \\ %{}) do
    params = authorize_params(client, overrides)
    html = html_response(get(conn, "/oauth/authorize?" <> URI.encode_query(params)), 200)
    [_full, token] = Regex.run(~r/name="consent_token" value="([^"]+)"/, html)
    token
  end

  defp authorize_code!(conn, client, user, overrides \\ %{}) do
    verifier = verifier()
    overrides = Map.put(overrides, "code_challenge", challenge(verifier))
    signed = SessionHelpers.sign_in(conn, user)
    token = consent_token!(signed, client, overrides)

    response =
      consent_post(user, %{"consent_token" => token, "decision" => "approve"})

    %{code: redirect_query(response)["code"], verifier: verifier}
  end

  defp token_params(client, %{code: code, verifier: verifier}) do
    %{
      "grant_type" => "authorization_code",
      "code" => code,
      "client_id" => client.client_id,
      "redirect_uri" => redirect_uri(),
      "code_verifier" => verifier,
      "resource" => resource()
    }
  end

  defp redirect_query(conn) do
    conn
    |> redirected_to(302)
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
  end

  defp json_post(conn, path, body) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp form_post(conn, path, params) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, URI.encode_query(params))
  end

  defp consent_post(user, params) do
    build_conn()
    |> SessionHelpers.sign_in(user)
    |> post("/oauth/authorize", params)
  end

  defp with_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp oauth_audit(kind) do
    cutoff = DateTime.add(DateTime.utc_now(), 60, :second)
    base_query = Ash.Query.for_read(AuditEvent, :stale, %{cutoff: cutoff})
    filtered_query = Ash.Query.filter(base_query, kind == ^kind)
    Ash.read!(filtered_query, authorize?: false)
  end

  defp put_bucket_limit(bucket, max_requests) do
    previous = Application.get_env(:flux_vale, OAuthRateLimit)
    buckets = Keyword.get(previous || [], :buckets, %{})

    updated =
      Keyword.put(
        previous || [],
        :buckets,
        Map.put(buckets, bucket, window_seconds: 86_400, max_requests: max_requests)
      )

    Application.put_env(:flux_vale, OAuthRateLimit, updated)
    on_exit(fn -> restore_env(OAuthRateLimit, previous) end)
  end

  defp put_client_cap(cap) do
    previous = Application.get_env(:flux_vale, :mcp_oauth)
    updated = Keyword.put(previous || [], :client_cap, cap)
    Application.put_env(:flux_vale, :mcp_oauth, updated)
    on_exit(fn -> restore_env(:mcp_oauth, previous) end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:flux_vale, key)
  defp restore_env(key, value), do: Application.put_env(:flux_vale, key, value)
end
