defmodule FluxVale.Infrastructure.PocketId.ApiClient do
  @moduledoc """
  The PocketID REST client for key custody (#597 §4.3) — pure data
  over `Req`, the Tailscale ApiClient stance: no Ash, no cluster, no
  storage. The caller reads the key from the custody Secret and
  passes it to every call, so this module can never leak a
  credential into a log line (the key rides only the `X-API-KEY`
  request header, and error bodies — which never carry it — are
  snippet-truncated before logging).

  Unlike the Tailscale client (one fixed API host), every PocketID
  instance is its own host: `base_url` is a per-call argument — the
  instance's public URL, `https://<slug>.<instances_base_domain>`.

  Field shapes against the shipped image v2.19.2 (#597 §2's live
  transcript):

  - `GET /api/oidc/clients` — an admin-scoped read that doubles as
    the key verification probe (the cheapest read whose 2xx proves
    the key can manage OIDC clients — the wiring's whole need).
    Status semantics pinned by the transcript and the v2.19.2 source.
  - `GET /api/api-keys` — the key can list its own key family; the
    just-used key's `lastUsedAt` is ≈now, which is how the store op
    correlates the pasted key to its `expiresAt` (best-effort). The
    LIST response's exact envelope is not in the transcript: the bare
    array is primary, an object wrapper tolerated, every other shape
    degrades to "no expiry known" — a wrong guess costs a date on a
    card, nothing else.
  - `GET /.well-known/openid-configuration` — the wiring's issuer
    source (#597 S4, §4.4): the issuer string VERBATIM from the
    document, fetched fresh per wiring (never cached — S3's probe
    cache answers a different question, reachability of setup, and a
    wizard-lifetime cache could pin an issuer the owner has since
    changed). Keyless on purpose: the document is public, and sending
    the admin key to an unauthenticated endpoint is exposure with no
    benefit.
  - `POST /api/oidc/clients` — the wiring's client mint (#597 S4,
    §4.5). The create response is the ONLY one that reveals a secret
    (the v2.19.2 DTOs: `credentials.secrets` is read-only on create —
    "any value sent by a client is ignored" — and a caller-supplied
    secret is accepted solely by the dedicated `POST .../secrets`
    endpoint). So the mint takes the `createdSecret` the response
    carries and hands its value straight to the caller; this module
    never logs it (only error bodies log, and they never contain it).
  - 401 vs 403 are never folded (the Tailscale rule): 401 = the key
    was rejected (expired/revoked present identically); 403 =
    authenticated but not permitted (a non-admin user's key) —
    different copy, different fix.
  """

  require Logger

  # 401 — rejected outright: expired or revoked.
  @unauthorized_status 401
  # 403 — valid key, insufficient permission: not an admin's key.
  @forbidden_status 403

  # The paste-time probe budget (#597 S2): short, honest, fail-fast —
  # the card waits on this call synchronously.
  @timeout_milliseconds 3_000

  @discovery_path "/.well-known/openid-configuration"
  @clients_path "/api/oidc/clients"

  @typedoc "A non-2xx other than 401/403: the status plus a body snippet."
  @type api_error :: %{status: pos_integer(), body: String.t()}

  @typedoc """
  The minted client as the wiring needs it (#597 S4): PocketID's own
  ids (`client_id` for admin/delete, `secret_id` for S5's rotation)
  and the one-time `secret` — carried straight into env, never logged,
  never persisted on a row.
  """
  @type created_client :: %{
          client_id: String.t(),
          client_name: String.t(),
          secret_id: String.t(),
          secret: String.t()
        }

  @typedoc "The mint's request shape: the name, the callback, PKCE on/off."
  @type client_attrs :: %{
          required(:name) => String.t(),
          required(:callback_url) => String.t(),
          required(:pkce) => boolean()
        }

  @type error ::
          :unauthorized
          | :forbidden
          | :unreachable
          | :no_issuer
          | :no_created_secret
          | api_error()

  @doc """
  Verifies the key is a working PocketID admin key: one
  `GET /api/oidc/clients` with the `X-API-KEY` header. `:ok` = the
  key can manage OIDC clients (a valid admin key); `{:error,
  :unauthorized}` = rejected (expired/revoked); `{:error,
  :forbidden}` = a valid key without admin permission;
  `{:error, :unreachable}` = the instance did not answer (down,
  waking, wrong host).
  """
  @spec verify_admin_key(String.t(), String.t()) :: :ok | {:error, error()}
  def verify_admin_key(base_url, api_key)
      when is_binary(base_url) and is_binary(api_key) do
    req = new_req(base_url, api_key)

    case Req.get(req, url: "/api/oidc/clients", receive_timeout: @timeout_milliseconds) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      other -> error_result(other)
    end
  end

  @doc """
  The key's own key family (`GET /api/api-keys`) — the raw list; the
  store op correlates `lastUsedAt` ≈ now to find the pasted key's
  `expiresAt`. A nicety feed: every failure or unrecognized shape maps
  to "no expiry known" at the caller, never an error surface of its
  own.
  """
  @spec list_api_keys(String.t(), String.t()) ::
          {:ok, [map()]} | {:error, error()}
  def list_api_keys(base_url, api_key)
      when is_binary(base_url) and is_binary(api_key) do
    req = new_req(base_url, api_key)

    case Req.get(req, url: "/api/api-keys", receive_timeout: @timeout_milliseconds) do
      # The bare array (the documented v2.19.2 shape) plus a tolerated
      # object wrapper; anything else is unusable for correlation, not
      # a crash.
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, keys_list(body)}

      other ->
        error_result(other)
    end
  end

  @doc """
  The discovery document's `issuer`, VERBATIM (#597 §4.4) — the value
  the recipe's `issuer_env` must carry (PocketID returns its own
  `APP_URL` exactly, and consumers like Vaultwarden require issuer
  equality). `{:error, :no_issuer}` when a 2xx document carries no
  issuer string — answered, but broken (an unset `APP_URL`); not
  `:unreachable`, which reserves for hosts that never answered.
  """
  @spec get_discovery(String.t()) :: {:ok, String.t()} | {:error, error()}
  def get_discovery(base_url) when is_binary(base_url) do
    req = discovery_req(base_url)

    case Req.get(req, url: @discovery_path) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        issuer(body)

      other ->
        error_result(other)
    end
  end

  @doc """
  Mints a confidential OIDC client (`POST /api/oidc/clients`): name
  `FluxVale · <instance name>`-shaped (the caller composes it),
  callback, PKCE per the recipe, `isPublic` false — the env-wired
  consumer exchanges its secret server-side. The 201's
  `createdSecret` is the only shape that ever reveals the value (see
  the moduledoc); a 2xx without one (`isPublic` somehow true, or the
  instance's `AutoCreateOIDCClientSecret` disabled) is
  `{:error, :no_created_secret}` — an honest refusal, not a client
  the wiring cannot authenticate.
  """
  @spec create_client(String.t(), String.t(), client_attrs()) ::
          {:ok, created_client()} | {:error, error()}
  def create_client(base_url, api_key, attrs)
      when is_binary(base_url) and is_binary(api_key) and is_map(attrs) do
    req = new_req(base_url, api_key)

    # The v2.19.2 wire shape (§2's transcript): camelCase fields, one
    # callback, confidential (the env-wired consumer exchanges its
    # secret server-side), pkce per the recipe.
    wire = %{
      "name" => attrs.name,
      "callbackUrls" => [attrs.callback_url],
      "isPublic" => false,
      "pkceEnabled" => attrs.pkce
    }

    case Req.post(req, url: @clients_path, json: wire) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        created(attrs.name, body)

      other ->
        error_result(other)
    end
  end

  # ------------------------------------------------------------------
  # Plumbing
  # ------------------------------------------------------------------

  # The keyless discovery request: same fail-fast posture as the keyed
  # calls (no retries, bounded connect), but no X-API-KEY — the
  # document is public and the key would only widen its exposure.
  defp discovery_req(base_url) do
    Req.new(
      base_url: base_url,
      retry: false,
      connect_options: [timeout: @timeout_milliseconds]
    )
  end

  defp issuer(%{"issuer" => issuer}) when is_binary(issuer) and issuer != "",
    do: {:ok, issuer}

  defp issuer(_answered_without_issuer), do: {:error, :no_issuer}

  # The 201 body: PocketID's client id, the created secret's id (S5's
  # rotation targets it), and the one-time secret value. The value
  # rides the return map to the wiring's env merge — this function and
  # its callers never log it (the module logs error bodies only).
  defp created(name, %{
         "id" => client_id,
         "createdSecret" => %{"id" => secret_id, "secret" => secret}
       })
       when is_binary(client_id) and client_id != "" and is_binary(secret_id) and
              secret_id != "" and is_binary(secret) and secret != "" do
    {:ok, %{client_id: client_id, client_name: name, secret_id: secret_id, secret: secret}}
  end

  defp created(_name, _no_created_secret), do: {:error, :no_created_secret}

  defp new_req(base_url, api_key) do
    # retry: false — Req's default (:safe_transient) would retry a
    # waking PocketID's 503s/transient errors with backoff, so one
    # "3s" probe could block the paste submit for ~20s.
    # connect_options timeout — receive_timeout bounds the response
    # wait, NOT connection setup; without this a blackholed host
    # hangs the connect for the OS's TCP default (CodeRabbit, #607).
    Req.new(
      base_url: base_url,
      headers: [{"x-api-key", api_key}],
      retry: false,
      connect_options: [timeout: @timeout_milliseconds]
    )
  end

  defp keys_list(body) when is_list(body), do: Enum.filter(body, &is_map/1)

  defp keys_list(%{"apiKey" => %{"data" => keys}}) when is_list(keys),
    do: Enum.filter(keys, &is_map/1)

  defp keys_list(_other), do: []

  defp error_result({:ok, %Req.Response{status: @unauthorized_status, body: _body}}) do
    {:error, :unauthorized}
  end

  defp error_result({:ok, %Req.Response{status: @forbidden_status, body: _body}}) do
    {:error, :forbidden}
  end

  defp error_result({:ok, %Req.Response{status: status, body: body}}) do
    snippet = body_snippet(body)
    Logger.warning("PocketID API returned #{status}: #{snippet}")
    {:error, %{status: status, body: snippet}}
  end

  defp error_result({:error, exception}) do
    Logger.warning("PocketID API network error: #{inspect(exception)}")
    {:error, :unreachable}
  end

  # Logs stay bounded, and the key is never in a body — it rides the
  # request header only, which is never logged.
  defp body_snippet(body) do
    body
    |> inspect()
    |> String.slice(0, 200)
  end
end
