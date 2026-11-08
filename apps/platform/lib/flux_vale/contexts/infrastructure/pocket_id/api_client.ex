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

  @typedoc "A non-2xx other than 401/403: the status plus a body snippet."
  @type api_error :: %{status: pos_integer(), body: String.t()}

  @type error ::
          :unauthorized
          | :forbidden
          | :unreachable
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

  # ------------------------------------------------------------------
  # Plumbing
  # ------------------------------------------------------------------

  defp new_req(base_url, api_key) do
    Req.new(base_url: base_url, headers: [{"x-api-key", api_key}])
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
