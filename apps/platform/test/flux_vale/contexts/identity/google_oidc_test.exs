defmodule FluxVale.Identity.GoogleOIDCTest do
  @moduledoc false

  # The assent seam against a real mock provider (plan §7): full
  # discovery/state/PKCE/signature/issuer/audience/expiry/nonce chain
  # over real HTTP on 127.0.0.1. async: false — Application env is
  # VM-global (the ApiRateLimit config-test posture): an async
  # neighbor's :google_oidc would re-point this suite's issuer.

  use ExUnit.Case, async: false

  alias FluxVale.Identity.GoogleOIDC
  alias FluxVale.TestSupport.OIDC.Provider

  @client_id "mock-client-id"
  @client_secret "mock-client-secret"
  @redirect_uri "http://127.0.0.1:9/auth/google/callback"

  setup do
    provider = start_supervised!({Provider, client_id: @client_id, client_secret: @client_secret})

    original = Application.get_env(:flux_vale, :google_oidc)

    Application.put_env(:flux_vale, :google_oidc,
      client_id: @client_id,
      client_secret: @client_secret,
      issuer: Provider.base_url(provider)
    )

    # Default id_token claims for every test that reaches /token (the
    # provider fetch!es email/email_verified — a mint without claims
    # fails loudly there); tests override via set_claims.
    Provider.set_claims(provider,
      email: "ada@example.com",
      email_verified: true,
      sub: "mock-sub-1"
    )

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:flux_vale, :google_oidc)
        value -> Application.put_env(:flux_vale, :google_oidc, value)
      end
    end)

    %{provider: provider}
  end

  # The env is global state — capture and restore (house rule); the
  # configured?/0 matrix needs shapes the setup's env does not carry.
  defp with_env(env, test) do
    original = Application.get_env(:flux_vale, :google_oidc)
    Application.put_env(:flux_vale, :google_oidc, env)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:flux_vale, :google_oidc)
        value -> Application.put_env(:flux_vale, :google_oidc, value)
      end
    end)

    test.()
  end

  # One authorize hop: follow the redirect manually (Req, no redirect
  # following) and parse the code+state out of the callback location —
  # deterministic, and it asserts the mock's echo of state/redirect.
  defp authorize_grant do
    {:ok, %{url: url, session_params: session_params}} = GoogleOIDC.authorize_url(@redirect_uri)

    authorize_query =
      url
      |> URI.parse()
      |> Map.get(:query)
      |> URI.decode_query()

    response = Req.get!(url: url, redirect: false)
    assert response.status == 302

    [location] = Req.Response.get_header(response, "location")
    callback = URI.parse(location)
    callback_query = URI.decode_query(callback.query)
    callback_base = %{callback | query: nil}

    %{
      authorize_url: url,
      authorize_query: authorize_query,
      session_params: session_params,
      code: callback_query["code"],
      state: callback_query["state"],
      callback_uri: URI.to_string(callback_base)
    }
  end

  defp exchange(grant) do
    GoogleOIDC.callback(
      %{"code" => grant.code, "state" => grant.state},
      grant.session_params,
      @redirect_uri
    )
  end

  describe "configured?/0" do
    test "true only with both credentials present as non-empty binaries" do
      with_env(nil, fn ->
        refute GoogleOIDC.configured?()
        Application.put_env(:flux_vale, :google_oidc, client_id: @client_id)
        refute GoogleOIDC.configured?()

        Application.put_env(:flux_vale, :google_oidc,
          client_id: "",
          client_secret: @client_secret
        )

        refute GoogleOIDC.configured?()

        Application.put_env(:flux_vale, :google_oidc,
          client_id: @client_id,
          client_secret: @client_secret
        )

        assert GoogleOIDC.configured?()
      end)
    end
  end

  describe "authorize_url/1" do
    test "builds the PKCE + nonce request on the issuer, session_params in tow", %{
      provider: provider
    } do
      base = Provider.base_url(provider)

      {:ok, %{url: url, session_params: session_params}} = GoogleOIDC.authorize_url(@redirect_uri)

      uri = URI.parse(url)
      assert URI.to_string(%{uri | query: nil}) == base <> "/authorize"

      query = URI.decode_query(uri.query)
      assert query["client_id"] == @client_id
      assert query["redirect_uri"] == @redirect_uri
      assert query["response_type"] == "code"
      assert query["scope"] == "openid email"
      assert query["prompt"] == "select_account"
      assert query["access_type"] == "online"

      # session_params carries the CSRF state and the full PKCE +
      # nonce set the callback must replay against
      assert query["state"] == session_params[:state]
      assert query["code_challenge"] == session_params[:code_challenge]
      assert query["code_challenge_method"] == "S256"
      assert query["nonce"] == session_params[:nonce]
      assert is_binary(session_params[:code_verifier]) and session_params[:code_verifier] != ""
    end
  end

  describe "callback/3 — the full round trip against the mock" do
    test "exchanges the code for the ID-token claims", %{provider: provider} do
      # the mock serves no userinfo endpoint: claims can only come
      # from the ID token
      discovery = Provider.discovery(provider)
      refute Map.has_key?(discovery, "userinfo_endpoint")

      grant = authorize_grant()

      # the mock echoed our redirect_uri and the authorize-time state
      assert grant.callback_uri == @redirect_uri
      assert grant.state == grant.authorize_query["state"]

      assert {:ok, claims} = exchange(grant)
      assert claims["email"] == "ada@example.com"
      assert claims["email_verified"] == true
      assert claims["sub"] == "mock-sub-1"

      # ID-token claims alone: assent drops the reserved ID-token
      # claim names (iss/aud/exp/iat/nonce/…) — the operation's input
      # contract, pinned here where their absence is observable
      refute Map.has_key?(claims, "nonce")
      refute Map.has_key?(claims, "iss")
    end

    # The failure tests assert assent's own message discriminators, not
    # just {:error, _} — any layer's failure would pass a shape assert;
    # the discriminator pins WHICH validation refused the token.
    test "a tampered id_token signature fails", %{provider: provider} do
      Provider.set_fault(provider, :tampered_signature)
      grant = authorize_grant()

      assert {:error, reason} = exchange(grant)
      assert reason =~ "Invalid JWT signature"
    end

    test "a wrong-issuer id_token fails", %{provider: provider} do
      Provider.set_fault(provider, :wrong_issuer)
      grant = authorize_grant()

      assert {:error, reason} = exchange(grant)
      assert reason =~ "Invalid issuer"
    end

    test "a wrong-audience id_token fails", %{provider: provider} do
      Provider.set_fault(provider, :wrong_audience)
      grant = authorize_grant()

      assert {:error, reason} = exchange(grant)
      assert reason =~ "not in audience"
    end

    test "an expired id_token fails", %{provider: provider} do
      Provider.set_fault(provider, :expired)
      grant = authorize_grant()

      assert {:error, reason} = exchange(grant)
      assert reason =~ "has expired"
    end

    test "a nonce mismatch fails — session_params are the arbiter", %{provider: provider} do
      grant = authorize_grant()
      forged = %{grant.session_params | nonce: "forged-nonce"}

      assert {:error, reason} =
               GoogleOIDC.callback(
                 %{"code" => grant.code, "state" => grant.state},
                 forged,
                 @redirect_uri
               )

      assert reason =~ "nonce"
    end

    test "a state mismatch fails — the session_params are the arbiter" do
      grant = authorize_grant()
      forged = %{grant.session_params | state: "forged-state"}

      assert {:error, _csrf} =
               GoogleOIDC.callback(
                 %{"code" => grant.code, "state" => grant.state},
                 forged,
                 @redirect_uri
               )
    end

    test "a replayed code fails — single-use, enforced at the provider" do
      grant = authorize_grant()

      assert {:ok, _claims} = exchange(grant)
      assert {:error, _burned} = exchange(grant)
    end
  end
end
