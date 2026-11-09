defmodule FluxVale.TestSupport.OIDC.Provider do
  @moduledoc """
  A real OIDC provider on localhost for the Google sign-in tests
  (#642 plan §7): Bandit on `127.0.0.1:<random>` (port 0, the bound
  port read back), so nothing in `lib/` knows the provider is fake —
  assent runs its full discovery/state/PKCE/signature/issuer/audience/
  expiry/nonce chain against it over real HTTP.

  Endpoints:

  - `GET /.well-known/openid-configuration` — issuer = the provider's
    own base URL, authorization/token/jwks endpoints, and NO
    `userinfo_endpoint`: claims must come from the ID token alone
    (assent 0.2.13's OIDC.fetch_user never consults userinfo — the
    omission is honored by construction).
  - `GET /authorize` — validates `client_id` + `redirect_uri`, mints
    a single-use code, REMEMBERS the received `code_challenge`,
    `code_challenge_method`, and `nonce` keyed by that code, and 302s
    back to `redirect_uri` with `code` + the echoed `state`.
  - `POST /token` — validates `grant_type`, the client credentials
    (Basic auth, assent's `client_secret_basic` default, or post
    body), `redirect_uri`, and PKCE: recomputes
    BASE64URL(SHA256(code_verifier)) and compares to the remembered
    challenge. The code is burned by ANY redemption attempt (strict
    single-use). Responds with an RS256-signed `id_token` (JOSE, the
    server's own RSA key; iss = base URL, aud = client_id, sub
    configurable, exp/iat now, nonce = the one remembered at
    /authorize) plus an `access_token`.
  - `GET /jwks.json` — the RSA public key as JWKS.

  Test-facing API (pass the pid/struct `start_supervised!` returned):

      provider = start_supervised!({FluxVale.TestSupport.OIDC.Provider, client_id: "id", client_secret: "secret"})
      Provider.base_url(provider)      # point :google_oidc's issuer here
      Provider.set_claims(provider, email: "ada@example.com", email_verified: true, sub: "sub-1")
      Provider.set_fault(provider, :wrong_audience)   # or :expired | :tampered_signature | nil

  Faults poison the NEXT `id_token` mint (wrong audience / expired
  window / broken signature) so assent's validator is what fails. A
  state-mismatch callback needs no knob — pass the wrong
  `session_params` from the test.
  """

  use GenServer

  @default_client_id "mock-client-id"
  @default_client_secret "mock-client-secret"

  defstruct [
    :base_url,
    :client_id,
    :client_secret,
    :key,
    :public_jwk,
    claims: [],
    fault: nil,
    grants: %{}
  ]

  @type fault :: :wrong_audience | :expired | :tampered_signature | nil

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  ## Test-facing API

  def base_url(provider), do: GenServer.call(provider, :base_url)

  @doc "The JWKS document assent fetches (one RSA key, kid-tagged)."
  def jwks(provider), do: GenServer.call(provider, :jwks)

  @doc "Configures the claims the next /token issuance carries in its id_token."
  def set_claims(provider, claims), do: GenServer.call(provider, {:set_claims, claims})

  @doc "Poisons the next id_token mint (see the moduledoc); `nil` clears."
  @spec set_fault(pid() | atom(), fault()) :: :ok
  def set_fault(provider, fault), do: GenServer.call(provider, {:set_fault, fault})

  ## Plug-facing API (ProviderPlug forwards HTTP shapes here)

  def discovery(provider), do: GenServer.call(provider, :discovery)

  def authorize(provider, params), do: GenServer.call(provider, {:authorize, params})

  def token(provider, params, basic), do: GenServer.call(provider, {:token, params, basic})

  @impl true
  def init(opts) do
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public_jwk} = JOSE.JWK.to_public_map(key)

    # The server links to this GenServer: it dies with the test's
    # supervised provider. Port 0 = an ephemeral port; read the bound
    # one back for the issuer URL the discovery document must carry.
    # The provider pid rides plug opts as [provider: pid()] — a bare
    # pid is outside Plug.opts()'s JSON-ish type and would fail
    # dialyzer through Bandit's options() spec.
    {:ok, server} =
      Bandit.start_link(
        plug: {FluxVale.TestSupport.OIDC.ProviderPlug, provider: self()},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    state = %__MODULE__{
      base_url: bound_base_url(server),
      client_id: Keyword.get(opts, :client_id, @default_client_id),
      client_secret: Keyword.get(opts, :client_secret, @default_client_secret),
      key: key,
      public_jwk: public_jwk
    }

    {:ok, state}
  end

  # listener_info answers :error only for a dead listener (dialyzer
  # totality) — the server was just started above; fail loudly.
  defp bound_base_url(server) do
    case ThousandIsland.listener_info(server) do
      {:ok, {addr, port}} -> "http://#{:inet.ntoa(addr)}:#{port}"
      :error -> raise "mock OIDC provider could not read its bound port"
    end
  end

  @impl true
  def handle_call(:base_url, _from, state), do: {:reply, state.base_url, state}

  def handle_call(:jwks, _from, state), do: {:reply, %{"keys" => [state.public_jwk]}, state}

  def handle_call(:discovery, _from, state) do
    {:reply, discovery_doc(state.base_url), state}
  end

  def handle_call({:set_claims, claims}, _from, state) do
    {:reply, :ok, %{state | claims: claims}}
  end

  def handle_call({:set_fault, fault}, _from, state) do
    {:reply, :ok, %{state | fault: fault}}
  end

  def handle_call({:authorize, params}, _from, state) do
    cond do
      params["client_id"] != state.client_id ->
        {:reply, {:error, "unknown client_id"}, state}

      not is_binary(params["redirect_uri"]) or params["redirect_uri"] == "" ->
        {:reply, {:error, "redirect_uri required"}, state}

      true ->
        code = url_random()

        grant = %{
          redirect_uri: params["redirect_uri"],
          state: params["state"],
          nonce: params["nonce"],
          code_challenge: params["code_challenge"],
          code_challenge_method: params["code_challenge_method"]
        }

        grants = Map.put(state.grants, code, grant)

        reply = %{code: code, redirect_uri: grant.redirect_uri, state: grant.state}
        {:reply, {:ok, reply}, %{state | grants: grants}}
    end
  end

  # The code is burned the moment it is presented — strict single-use:
  # a failed redemption (bad PKCE, wrong client) consumes it too, so a
  # replay probe can never hit a half-spent grant.
  def handle_call({:token, params, basic}, _from, state) do
    case Map.pop(state.grants, params["code"]) do
      {nil, _grants} ->
        {:reply, invalid_grant("unknown or reused code"), state}

      {grant, remaining} ->
        burned = %{state | grants: remaining}

        case validate_and_issue(params, basic, grant, burned) do
          {:ok, token} ->
            {:reply, {:ok, token}, burned}

          {:error, status, error, description} ->
            {:reply, {:error, status, error, description}, burned}
        end
    end
  end

  defp validate_and_issue(params, basic, grant, state) do
    with :ok <- check_grant_type(params["grant_type"]),
         :ok <- check_client(params, basic, state),
         :ok <- check_redirect_uri(params["redirect_uri"], grant),
         :ok <- check_pkce(params["code_verifier"], grant) do
      {:ok, issue_token(state, grant)}
    end
  end

  defp check_grant_type("authorization_code"), do: :ok

  defp check_grant_type(_other),
    do: {:error, 400, "unsupported_grant_type", "grant_type must be authorization_code"}

  defp check_client(params, basic, state) do
    {id, secret} = client_credentials(params, basic)

    if id == state.client_id and secret == state.client_secret do
      :ok
    else
      {:error, 401, "invalid_client", "client authentication failed"}
    end
  end

  # assent authenticates with client_secret_basic by default (the
  # Basic header); the post-body shape is accepted too so the knob
  # stays available without re-pointing assent.
  defp client_credentials(_params, {id, secret}), do: {id, secret}

  defp client_credentials(params, _no_basic_header),
    do: {params["client_id"], params["client_secret"]}

  defp check_redirect_uri(redirect_uri, grant) when is_binary(redirect_uri) do
    if redirect_uri == grant.redirect_uri do
      :ok
    else
      invalid_grant("redirect_uri mismatch")
    end
  end

  defp check_redirect_uri(_missing, _grant), do: invalid_grant("redirect_uri required")

  # PKCE S256, recomputed exactly the way assent generated the
  # challenge (oauth2.ex): BASE64URL(SHA256(code_verifier)), compared
  # to the challenge remembered at /authorize.
  defp check_pkce(verifier, grant) when is_binary(verifier) do
    computed =
      :sha256
      |> :crypto.hash(verifier)
      |> Base.url_encode64(padding: false)

    if computed == grant.code_challenge and grant.code_challenge_method == "S256" do
      :ok
    else
      invalid_grant("PKCE verification failed")
    end
  end

  defp check_pkce(_missing, _grant), do: invalid_grant("code_verifier required")

  defp invalid_grant(description), do: {:error, 400, "invalid_grant", description}

  defp issue_token(state, grant) do
    now = System.system_time(:second)

    claims = %{
      "iss" => state.base_url,
      "sub" => Keyword.get(state.claims, :sub, "mock-sub"),
      "aud" => audience(state),
      "exp" => expiry(state, now),
      "iat" => now,
      "nonce" => grant.nonce,
      "email" => Keyword.get(state.claims, :email),
      "email_verified" => Keyword.get(state.claims, :email_verified)
    }

    payload = Jason.encode!(claims)

    {_jws, compact} =
      state.key
      |> JOSE.JWS.sign(payload, %{"alg" => "RS256"})
      |> JOSE.JWS.compact()

    %{
      access_token: url_random(),
      token_type: "bearer",
      expires_in: 3600,
      id_token: maybe_tamper(compact, state.fault)
    }
  end

  defp audience(%{fault: :wrong_audience}), do: "some-other-client"
  defp audience(%{client_id: client_id}), do: client_id

  defp expiry(%{fault: :expired}, now), do: now - 600
  defp expiry(_no_fault, now), do: now + 3600

  # Flip the signature's last base64url char: still decodable (assent
  # decodes the signature before comparing), never valid.
  defp maybe_tamper(compact, :tampered_signature) do
    [header, payload, signature] = String.split(compact, ".")
    replacement = if String.last(signature) == "A", do: "B", else: "A"
    tampered = String.replace_trailing(signature, String.last(signature), replacement)

    Enum.join([header, payload, tampered], ".")
  end

  defp maybe_tamper(compact, _no_fault), do: compact

  defp discovery_doc(base_url) do
    %{
      "issuer" => base_url,
      "authorization_endpoint" => base_url <> "/authorize",
      "token_endpoint" => base_url <> "/token",
      "jwks_uri" => base_url <> "/jwks.json"
    }
  end

  defp url_random do
    raw = :crypto.strong_rand_bytes(16)
    Base.url_encode64(raw, padding: false)
  end
end
