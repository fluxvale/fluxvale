defmodule FluxVale.Identity.GoogleOIDC do
  @moduledoc """
  The assent seam for Google sign-in (#642,
  [ADR-0003](../../../../../../docs/adr/00003-ashauthentication-drop-authentik.md)
  Am. 4): config in, OIDC round trips out. Assent 0.2.13 called
  directly (`Assent.Strategy.OIDC`) — the ID-token validation chain is
  the library's, none of it ours.

  Config is Application env under `:google_oidc`, read AT CALL TIME
  (the ApiRateLimit posture — runtime-readable, so tests and staging
  point the issuer at a mock or a staging arm without release
  surgery): `client_id`, `client_secret`, `issuer` (default
  `https://accounts.google.com`). The `GOOGLE_CLIENT_ID`/`SECRET`/
  `GOOGLE_OIDC_ISSUER` env wiring lands in S3's runtime config
  (plan §6) — this seam reads whatever the env carries today.

  `redirect_uri` always arrives as an argument — FluxValeWeb is not
  reachable from this context (the secrets.ex boundary), and the
  redirect URI derives from the endpoint's own URL config in the
  controller (S3).

  `callback/3` returns the strategy's normalized user map. Assent
  0.2.13's OIDC `fetch_user` reads the ID token ALONE regardless of
  discovery (it never consults a userinfo endpoint), dropping the
  reserved ID-token claim names (iss/aud/exp/iat/nonce/…) and handing
  back the rest with string keys: `"email"`, `"email_verified"`,
  `"sub"`, … The mock provider deliberately serves NO userinfo
  endpoint so a future switch to userinfo-backed claims fails loudly
  at the mock instead of silently diverging between test and prod.
  """

  alias Assent.Strategy.OIDC
  alias FluxVale.Ops.FeatureFlags

  # Plan §3.1 (D-scopes): openid email, nothing else — no profile
  # claims are requested or kept. The Google-specific params are the
  # consent UX: online access (no refresh token), account chooser.
  @authorization_params [
    scope: "openid email",
    access_type: "online",
    prompt: "select_account"
  ]

  @default_issuer "https://accounts.google.com"

  @doc """
  True only when both credentials are present non-empty binaries — the
  creds-present predicate (nil or `""` is the unconfigured shape,
  plan §6).
  """
  @spec configured?() :: boolean()
  def configured? do
    env = Application.get_env(:flux_vale, :google_oidc, [])

    present?(env[:client_id]) and present?(env[:client_secret])
  end

  @doc """
  True when the Google arm is live: the `:google_sign_in` flag row on
  AND credentials present (#642, D-flag). THE one gate the button and
  both controller hops render under — a predicate inlined at its call
  sites drifts (two lifetimes, the flag read and the creds read); this
  is the notion that cannot fork, so it lives once here and both
  surfaces ask it.
  """
  @spec arm_available?() :: boolean()
  def arm_available? do
    FeatureFlags.enabled?(:google_sign_in) and configured?()
  end

  @doc """
  Builds the PKCE + nonce authorization request and returns assent's
  `%{url:, session_params:}` — the caller parks `session_params`
  (state, code_verifier, code_challenge, code_challenge_method,
  nonce) in the session and redirects to `url`.
  """
  @spec authorize_url(String.t()) ::
          {:ok, %{url: String.t(), session_params: map()}} | {:error, term()}
  def authorize_url(redirect_uri) do
    cfg =
      assent_config(
        redirect_uri,
        code_verifier: true,
        nonce: nonce(),
        authorization_params: @authorization_params,
        # assent prepends its default "openid" scope to whatever we
        # pass (oidc.ex add_default_scope_param); ours already carries
        # it — an empty default keeps the URL's scope exactly
        # "openid email" instead of "openid openid email".
        openid_default_scope: ""
      )

    OIDC.authorize_url(cfg)
  end

  @doc """
  Exchanges the callback `params` (code + state from the redirect)
  against the `session_params` parked at authorize time — pass them
  EXACTLY as `authorize_url/1` returned: atom keys (`:state`,
  `:code_verifier`, `:nonce`, …). Assent `Map.fetch!`es the verifier
  and pattern-matches `%{nonce: stored}` from that map, so a
  JSON-normalized (string-keyed) copy — e.g. one that survived a
  cookie-session round trip un-decoded — fails loudly instead of
  being accepted. Returns the verified claims map (`{:ok, claims}`)
  or assent's error — signature, issuer, audience, expiry, nonce, and
  state failures all land here (the controller's error set, §3.3).
  """
  @spec callback(map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def callback(params, session_params, redirect_uri) do
    # code_verifier: true on this side too: assent gates SENDING the
    # verifier on the config key (oauth2.ex fetch_code_verifer_params),
    # not on session_params carrying it — without it the token request
    # would omit PKCE against a challenge we sent at authorize time.
    cfg = assent_config(redirect_uri, code_verifier: true, session_params: session_params)

    case OIDC.callback(cfg, params) do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  # The shared config skeleton: credentials and issuer from env, the
  # redirect URI from the caller. Extra keys are per-call (PKCE/nonce
  # for authorize, session_params for callback).
  defp assent_config(redirect_uri, extra) do
    env = Application.get_env(:flux_vale, :google_oidc, [])

    [
      client_id: env[:client_id],
      client_secret: env[:client_secret],
      base_url: Keyword.get(env, :issuer, @default_issuer),
      redirect_uri: redirect_uri
    ] ++ extra
  end

  # The unguessable session nonce (OIDC Core §3.1.2.1) — the shape
  # from assent's own docs: 16 random bytes, base64url.
  defp nonce do
    raw = :crypto.strong_rand_bytes(16)
    Base.url_encode64(raw, padding: false)
  end

  defp present?(value), do: is_binary(value) and value != ""
end
