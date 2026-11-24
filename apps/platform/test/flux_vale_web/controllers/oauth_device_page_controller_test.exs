defmodule FluxValeWeb.OAuthDevicePageControllerTest do
  @moduledoc false

  # #886 S2: the hosted /oauth/device verification, consent, and
  # terminal completion/denial pages.

  use FluxValeWeb.ConnCase, async: false

  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.Api.Scopes
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth
  alias FluxVale.OAuth.AuditEvent
  alias FluxVale.OAuth.DeviceGrant
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.Endpoint
  alias FluxValeWeb.Plugs.OAuthRateLimit

  require Ash.Query

  @consent_salt "oauth device consent"

  describe "GET /oauth/device — session and code entry" do
    test "redirects anonymous visitors to sign-in preserving query string or bare path", %{
      conn: conn
    } do
      bare_response = get(conn, "/oauth/device")
      assert redirected_to(bare_response, 302) == "/sign-in?return_to=%2Foauth%2Fdevice"

      with_code_response = get(conn, "/oauth/device?user_code=ABCD-EFGH")

      assert redirected_to(with_code_response, 302) ==
               "/sign-in?return_to=%2Foauth%2Fdevice%3Fuser_code%3DABCD-EFGH"
    end

    test "sends to a bare /sign-in when the path is not local (two leading slashes)", %{
      conn: conn
    } do
      # The path is //oauth/device. The test adapter reads a bare "//..."
      # as a host, so the same path rides on an absolute URL instead.
      response = get(conn, "http://www.example.com//oauth/device?user_code=ABCD-EFGH")

      assert redirected_to(response, 302) == "/sign-in"
    end

    test "renders the enter-code form when user_code is missing, blank, or malformed", %{
      conn: conn
    } do
      user = user!()
      signed = SessionHelpers.sign_in(conn, user)

      for path <- [
            "/oauth/device",
            "/oauth/device?user_code=",
            "/oauth/device?user_code=%20%20",
            "/oauth/device?user_code[]=bad"
          ] do
        response = get(signed, path)
        html = html_response(response, 200)

        assert get_resp_header(response, "cache-control") == ["no-store"]
        assert html =~ "oauth-device-code-form"
        assert html =~ ~s(action="/oauth/device")
        assert html =~ ~s(method="get")
        assert html =~ ~s(name="user_code")
        assert html =~ ~s(placeholder="XXXX-XXXX")
        assert html =~ "Continue"
        assert html =~ user.username
      end
    end
  end

  describe "GET /oauth/device — code normalization and consent card" do
    test "normalizes lowercase, dashless, and space-separated user codes per RFC 8628 §6.1", %{
      conn: conn
    } do
      client = client!()
      user = user!()
      signed = SessionHelpers.sign_in(conn, user)
      minted = device_grant!(client)
      canonical = minted.grant.user_code
      compact = String.replace(canonical, "-", "")
      lowercase = String.downcase(canonical)
      left_part = String.slice(compact, 0, 4)
      right_part = String.slice(compact, 4, 4)
      spaced = String.downcase("#{left_part} #{right_part}")

      for variant <- [canonical, compact, lowercase, spaced] do
        query = URI.encode_query(%{"user_code" => variant})
        response = get(signed, "/oauth/device?" <> query)
        html = html_response(response, 200)

        assert html =~ "oauth-device-consent"
        assert html =~ canonical
      end
    end

    test "renders client name, user_code, scopes, and terminal copy without em-dashes or semicolons",
         %{conn: conn} do
      client = client!()
      user = user!()
      signed = SessionHelpers.sign_in(conn, user)
      minted = device_grant!(client, %{"scope" => "instances:read wallet:read"})

      response = get(signed, "/oauth/device?user_code=" <> minted.grant.user_code)
      html = html_response(response, 200)
      doc = LazyHTML.from_document(html)
      card_text = query_text(doc, "[data-testid='oauth-device-consent']")
      normalized_text = String.replace(card_text, ~r/\s+/, " ")
      title_text = query_text(doc, "title")

      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert html =~ "MCP Test Client"
      assert html =~ user.username
      assert html =~ minted.grant.user_code
      assert html =~ "oauth-device-user-code"
      assert html =~ Scopes.describe("instances:read")
      assert html =~ "instances:read"
      assert html =~ Scopes.describe("wallet:read")
      assert html =~ "wallet:read"

      assert normalized_text =~
               "This request stays on FluxVale and does not redirect your browser."

      assert normalized_text =~ "Return to your terminal after you allow or deny."
      assert normalized_text =~ "all of your FluxVale organizations"
      assert normalized_text =~ "Disconnecting revokes access immediately."
      assert html =~ "oauth-approve"
      assert html =~ "oauth-deny"
      refute card_text =~ "—"
      refute card_text =~ ";"
      refute title_text =~ "—"
      refute title_text =~ ";"
    end

    test "renders identify-only message when the grant requests no scopes", %{conn: conn} do
      client = client!()
      user = user!()
      signed = SessionHelpers.sign_in(conn, user)
      minted = device_grant!(client, %{"scope" => nil})

      response = get(signed, "/oauth/device?user_code=" <> minted.grant.user_code)
      html = html_response(response, 200)

      assert html =~ "Identify your account only, with no domain access."
    end
  end

  describe "GET /oauth/device — error states (400, never redirect)" do
    test "unknown or short user_code returns 400 with a link back to /oauth/device", %{conn: conn} do
      user = user!()
      signed = SessionHelpers.sign_in(conn, user)

      for bad_code <- ["ZZZZ-ZZZZ", "ABC"] do
        response = get(signed, "/oauth/device?user_code=" <> bad_code)
        html = html_response(response, 400)

        assert get_resp_header(response, "location") == []
        assert html =~ "oauth-error"
        assert html =~ "Code not recognized"
        assert html =~ ~s(href="/oauth/device")
      end
    end

    test "expired grants return 400 without redirecting", %{conn: conn} do
      client = client!()
      user = user!()
      signed = SessionHelpers.sign_in(conn, user)

      # Backdated expiry is action-impossible on mint; seed directly.
      past_time = DateTime.add(DateTime.utc_now(), -60, :second)
      past_grant = seed_grant(client, past_time, :pending)
      past_response = get(signed, "/oauth/device?user_code=" <> past_grant.user_code)
      past_html = html_response(past_response, 400)

      assert get_resp_header(past_response, "location") == []
      assert past_html =~ "This code has expired"

      future_time = DateTime.add(DateTime.utc_now(), 300, :second)
      status_expired_grant = seed_grant(client, future_time, :expired)

      status_response = get(signed, "/oauth/device?user_code=" <> status_expired_grant.user_code)
      assert html_response(status_response, 400) =~ "This code has expired"
    end

    test "closes with the terminal, never the MCP client", %{conn: conn} do
      client = client!()
      user = user!()
      signed = SessionHelpers.sign_in(conn, user)
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      expired_grant = seed_grant(client, past, :pending)

      for path <- [
            "/oauth/device?user_code=ZZZZ-ZZZZ",
            "/oauth/device?user_code=" <> expired_grant.user_code
          ] do
        html = html_response(get(signed, path), 400)
        doc = LazyHTML.from_document(html)
        restart_text = query_text(doc, "[data-testid='oauth-error-restart']")

        sentence =
          restart_text
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        assert sentence == "You can close this tab and start again from your terminal."

        refute html =~ "MCP client"
      end
    end

    test "already-decided or consumed grants return 400 without redirecting", %{conn: conn} do
      client = client!()
      user = user!()
      signed = SessionHelpers.sign_in(conn, user)

      approved_minted = approved_device_grant!(client, user)

      approved_response =
        get(signed, "/oauth/device?user_code=" <> approved_minted.grant.user_code)

      assert get_resp_header(approved_response, "location") == []
      assert html_response(approved_response, 400) =~ "This code has already been used"

      consumed = DeviceGrant.consume!(approved_minted.grant, authorize?: false)
      consumed_response = get(signed, "/oauth/device?user_code=" <> consumed.user_code)
      assert get_resp_header(consumed_response, "location") == []
      assert html_response(consumed_response, 400) =~ "This code has already been used"

      denied_minted = device_grant!(client)
      {:ok, denied} = OAuth.deny_device_grant(denied_minted.grant, actor: user)
      denied_response = get(signed, "/oauth/device?user_code=" <> denied.user_code)
      assert get_resp_header(denied_response, "location") == []
      assert html_response(denied_response, 400) =~ "This code has already been used"
    end
  end

  describe "POST /oauth/device — consent decisions" do
    test "approve renders completion page, binds user, and records audit event", %{conn: conn} do
      client = client!()
      user = user!()
      minted = device_grant!(client)
      token = fetch_consent_token!(conn, user, minted.grant.user_code)

      response = post_decision(user, %{"consent_token" => token, "decision" => "approve"})
      html = html_response(response, 200)
      doc = LazyHTML.from_document(html)
      card_text = query_text(doc, "[data-testid='oauth-device-complete']")

      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert html =~ "oauth-device-complete"
      assert html =~ "Connected"
      assert html =~ client.client_name
      assert html =~ "You can close this tab and return to your terminal."
      assert html =~ ~s(href="/settings/developer#connected-apps")
      assert card_text =~ "You can revoke access any time in"
      assert card_text =~ "Developer settings."
      refute card_text =~ "—"
      refute card_text =~ ";"

      updated = DeviceGrant.get_by_user_code!(minted.grant.user_code, authorize?: false)
      assert updated.status == :approved
      assert updated.user_id == user.id

      assert [%{kind: :device_grant_approved, actor_id: actor_id}] =
               oauth_audit(:device_grant_approved, client)

      assert actor_id == user.id
    end

    test "deny renders denial page, marks grant denied, and records audit event", %{conn: conn} do
      client = client!()
      user = user!()
      minted = device_grant!(client)
      token = fetch_consent_token!(conn, user, minted.grant.user_code)

      response = post_decision(user, %{"consent_token" => token, "decision" => "deny"})
      html = html_response(response, 200)
      doc = LazyHTML.from_document(html)
      card_text = query_text(doc, "[data-testid='oauth-device-denied']")

      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert html =~ "oauth-device-denied"
      assert html =~ "Access denied"
      assert html =~ client.client_name
      assert html =~ "No access was granted. You can close this tab and return to your terminal."
      refute card_text =~ "—"
      refute card_text =~ ";"

      updated = DeviceGrant.get_by_user_code!(minted.grant.user_code, authorize?: false)
      assert updated.status == :denied
      assert updated.user_id == nil

      assert [%{kind: :device_grant_denied, actor_id: actor_id}] =
               oauth_audit(:device_grant_denied, client)

      assert actor_id == user.id
    end

    test "invalid, expired, or missing consent_token returns 400", %{conn: conn} do
      client = client!()
      user = user!()
      minted = device_grant!(client)

      missing = post_decision(user, %{"decision" => "approve"})
      assert html_response(missing, 400) =~ "expired"

      tampered = post_decision(user, %{"consent_token" => "garbage", "decision" => "approve"})
      assert html_response(tampered, 400) =~ "expired"

      payload = consent_payload(client, user, minted.grant)
      signed_at = System.system_time(:second) - 1_000
      expired_token = Phoenix.Token.sign(Endpoint, @consent_salt, payload, signed_at: signed_at)

      expired = post_decision(user, %{"consent_token" => expired_token, "decision" => "approve"})
      assert html_response(expired, 400) =~ "expired"
      _conn = conn
    end

    test "unrecognized decision returns 400", %{conn: conn} do
      client = client!()
      user = user!()
      minted = device_grant!(client)
      token = fetch_consent_token!(conn, user, minted.grant.user_code)

      response = post_decision(user, %{"consent_token" => token, "decision" => "maybe"})
      assert html_response(response, 400) =~ "not recognized"
    end

    test "signed-out or mismatched session user returns 400", %{conn: conn} do
      client = client!()
      user = user!()
      other = user!()
      minted = device_grant!(client)
      token = fetch_consent_token!(conn, user, minted.grant.user_code)

      anonymous =
        post(conn, "/oauth/device", %{"consent_token" => token, "decision" => "approve"})

      assert html_response(anonymous, 400) =~ "session changed"

      wrong_user = post_decision(other, %{"consent_token" => token, "decision" => "approve"})
      assert html_response(wrong_user, 400) =~ "session changed"
    end

    test "stale race on POST returns 400 already used", %{conn: conn} do
      client = client!()
      user = user!()
      other = user!()

      minted_approve = device_grant!(client)
      approve_token = fetch_consent_token!(conn, user, minted_approve.grant.user_code)
      assert {:ok, _denied} = OAuth.deny_device_grant(minted_approve.grant, actor: other)

      stale_approve =
        post_decision(user, %{"consent_token" => approve_token, "decision" => "approve"})

      assert html_response(stale_approve, 400) =~ "This code has already been used"

      minted_deny = device_grant!(client)
      deny_token = fetch_consent_token!(conn, user, minted_deny.grant.user_code)
      assert {:ok, _approved} = OAuth.approve_device_grant(minted_deny.grant, actor: other)

      stale_deny = post_decision(user, %{"consent_token" => deny_token, "decision" => "deny"})
      assert html_response(stale_deny, 400) =~ "This code has already been used"
    end

    test "expired grant on POST returns 400 expired", %{conn: conn} do
      client = client!()
      user = user!()
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      minted_approve = device_grant!(client)
      approve_token = fetch_consent_token!(conn, user, minted_approve.grant.user_code)
      Ash.Seed.update!(minted_approve.grant, %{expires_at: past})

      expired_approve =
        post_decision(user, %{"consent_token" => approve_token, "decision" => "approve"})

      assert html_response(expired_approve, 400) =~ "This code has expired"

      minted_deny = device_grant!(client)
      deny_token = fetch_consent_token!(conn, user, minted_deny.grant.user_code)
      Ash.Seed.update!(minted_deny.grant, %{expires_at: past})

      expired_deny = post_decision(user, %{"consent_token" => deny_token, "decision" => "deny"})
      assert html_response(expired_deny, 400) =~ "This code has expired"
    end

    test "missing grant on POST returns 400 expired", %{conn: _conn} do
      client = client!()
      user = user!()
      minted = device_grant!(client)
      base_payload = consent_payload(client, user, minted.grant)
      payload = Map.put(base_payload, :user_code, "GONE-CODE")
      token = Phoenix.Token.sign(Endpoint, @consent_salt, payload)

      response = post_decision(user, %{"consent_token" => token, "decision" => "approve"})
      assert html_response(response, 400) =~ "This code has expired"
    end

    test "a consent token whose code was swapped for another grant's decides nothing", %{
      conn: _conn
    } do
      client = client!()
      user = user!()
      shown = device_grant!(client)
      swapped = device_grant!(client)

      shown_payload = consent_payload(client, user, shown.grant)
      payload = Map.put(shown_payload, :user_code, swapped.grant.user_code)

      token = Phoenix.Token.sign(Endpoint, @consent_salt, payload)

      approved = post_decision(user, %{"consent_token" => token, "decision" => "approve"})

      assert html_response(approved, 400) =~ "This consent request expired"
      assert_still_pending(shown.grant)
      assert_still_pending(swapped.grant)
      assert oauth_audit(:device_grant_approved, client) == []

      denied = post_decision(user, %{"consent_token" => token, "decision" => "deny"})

      assert html_response(denied, 400) =~ "This consent request expired"
      assert_still_pending(swapped.grant)
      assert oauth_audit(:device_grant_denied, client) == []
    end
  end

  describe "rate limiting (:authorize bucket)" do
    test "GET and POST /oauth/device return 429 with retry-after when :authorize is exhausted", %{
      conn: conn
    } do
      put_bucket_limit(:authorize, 1)
      ip = {10, 31, 0, 1}

      first = get(with_ip(conn, ip), "/oauth/device")
      assert first.status == 302

      second = get(with_ip(conn, ip), "/oauth/device")
      assert html_response(second, 429) =~ "Too many authorization attempts"
      assert [retry_after_get] = get_resp_header(second, "retry-after")
      assert String.to_integer(retry_after_get) > 0

      third =
        post(with_ip(conn, ip), "/oauth/device", %{
          "consent_token" => "x",
          "decision" => "approve"
        })

      assert html_response(third, 429) =~ "Too many authorization attempts"
      assert [retry_after_post] = get_resp_header(third, "retry-after")
      assert String.to_integer(retry_after_post) > 0
    end
  end

  # ---- helpers ----

  defp query_text(doc, selector) do
    doc
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
  end

  defp fetch_consent_token!(conn, user, user_code) do
    signed = SessionHelpers.sign_in(conn, user)
    response = get(signed, "/oauth/device?user_code=" <> user_code)
    html = html_response(response, 200)
    [_full, token] = Regex.run(~r/name="consent_token" value="([^"]+)"/, html)
    token
  end

  defp post_decision(user, params) do
    build_conn()
    |> SessionHelpers.sign_in(user)
    |> post("/oauth/device", params)
  end

  defp assert_still_pending(grant) do
    reloaded = DeviceGrant.get_by_user_code!(grant.user_code, authorize?: false)

    assert reloaded.status == :pending
    assert reloaded.user_id == nil
  end

  defp consent_payload(client, user, grant) do
    %{
      user_id: user.id,
      grant_id: grant.id,
      user_code: grant.user_code,
      client_id: client.client_id,
      scopes: grant.scopes,
      resource: grant.resource
    }
  end

  # Backdated expiry / :expired status are action-impossible states on
  # mint, so error-page tests seed them directly.
  defp seed_grant(client, expires_at, status) do
    random_bytes = :crypto.strong_rand_bytes(32)
    random_suffix = Base.url_encode64(random_bytes, padding: false)
    code_challenge = challenge(verifier())

    Ash.Seed.seed!(DeviceGrant, %{
      device_code_hash: PersonalAccessToken.token_hash(random_suffix),
      user_code: random_user_code(),
      scopes: ["instances:read"],
      resource: resource(),
      code_challenge: code_challenge,
      status: status,
      expires_at: expires_at,
      client_id: client.id
    })
  end

  defp random_user_code do
    symbols = Enum.map(1..8, fn _i -> Enum.random(~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789") end)
    {left, right} = Enum.split(symbols, 4)
    IO.iodata_to_binary([left, ?-, right])
  end

  defp with_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp oauth_audit(kind, client) do
    cutoff = DateTime.add(DateTime.utc_now(), 60, :second)
    base_query = Ash.Query.for_read(AuditEvent, :stale, %{cutoff: cutoff})
    filtered_query = Ash.Query.filter(base_query, kind == ^kind and oauth_client_id == ^client.id)
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

  defp restore_env(key, nil), do: Application.delete_env(:flux_vale, key)
  defp restore_env(key, value), do: Application.put_env(:flux_vale, key, value)
end
