defmodule FluxVale.Infrastructure.AccessProviders.Tailscale.ApiClient do
  @moduledoc """
  The Tailscale API v2 client for tailnet claiming (ADR-0040 §3/§5) —
  pure data over `Req`. No Ash, no cluster, no storage: the provider
  reads the API token from its Secret and passes it to every call, so
  this module can never leak a credential into a log line (the token
  rides only the request header, and error bodies — which never carry
  it — are snippet-truncated before logging).

  Field-level shapes are spike-pinned against the official SDK v2.12.0
  (ADR-0040 §3):

  - Node lookup lists the tailnet's devices; `advertisedRoutes` /
    `enabledRoutes` are NOT in that payload — they live on the
    per-device routes endpoint.
  - `POST /api/v2/device/{id}/routes` REPLACES the enabled list, so
    approving is read→union→set. The API may pre-enable a route the
    node is not yet advertising — used deliberately: ours goes on even
    before the gateway advertises it.
  - Split DNS PATCH is a NATIVE per-domain upsert: domains absent from
    the body keep their routes, a `nil` value unsets. Never a
    full-replace PUT — that would rewrite the customer's other
    split-DNS routes (§12's blast-radius rule).
  - Key mint/revoke (the gateway-enrollment lane, #836): the create
    response carries the secret `key` value exactly once — returned to
    the caller, never logged.
  - OAuth client-credential exchange (lane B, #836): the response
    carries the access token and the request's Basic header carries the
    client secret — the same never-logged discipline, and the same
    manual decode (`decode_mint`'s stance) so a decode-error struct can
    never hold the body.

  `tailnet/-` (the dash) addresses the key's own tailnet — one
  credential, one tailnet, no tailnet id handling.
  """

  require Logger

  @base_url "https://api.tailscale.com"

  # 401 — the drift signal (ADR-0040 §5): the key was rejected —
  # expired and revoked present identically (API keys expire ≤90 days
  # by design).
  @unauthorized_status 401
  # 403 — authenticated but NOT permitted: the key lacks the scopes
  # this write needs (§5: dns + devices:routes + devices:core:read).
  # A different copy and a different fix than a 401 — never fold them.
  @forbidden_status 403

  @typedoc "A non-2xx other than 401/403: the status plus a body snippet."
  @type api_error :: %{status: pos_integer(), body: String.t()}

  # A 2xx whose body is not the shape the endpoint documents — a
  # contract break, not a missing record. Surfaced (never silently
  # mapped to not_found/empty) so a tick cannot converge on garbage.
  @type bad_payload :: {:bad_payload, pos_integer()}

  @type error ::
          :unauthorized
          | :forbidden
          | :not_found
          | :node_ambiguous
          | :network_error
          | api_error()
          | bad_payload()

  @doc """
  Finds the tailnet device whose name's FIRST label is `hostname` (the
  gateway's opaque `fv-…` name; the API returns full MagicDNS FQDNs).
  Routes are not part of this payload — `routes_get/2` is the next call.

  The device's Tailscale IPs ride along (`tailscale_ips` — the payload's
  `addresses`; the node's 100.x/fd7a:: addresses): the resolver views
  (ADR-0040 §4) answer a claimed hostname with the CLAIMING gateway's
  tailnet IP, and the tailnet API is the only place the platform can
  read one.

  Duplicate matches (two nodes reusing one name — a rejoin that went
  stale, a hostname collision) resolve deterministically: prefer an
  ONLINE device, then the most recent `lastSeen`. More than one match
  with NO online candidate is `{:error, :node_ambiguous}` — claiming
  against a picked-from-a-hat dead node would route the tailnet's DNS
  at a ghost.
  """
  @spec devices_lookup(String.t(), String.t()) ::
          {:ok, %{id: String.t(), tailscale_ips: [String.t()]}} | {:error, error()}
  def devices_lookup(token, hostname) when is_binary(token) and is_binary(hostname) do
    req = new_req(token)

    case Req.get(req, url: "/api/v2/tailnet/-/devices") do
      # Both documented envelopes (the object wrapper and the bare
      # array); a scalar body is a contract break, not an empty list.
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_list(body) ->
        find_device(body, hostname)

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        find_device(devices_from(body), hostname)

      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:error, {:bad_payload, status}}

      other ->
        error_result(other)
    end
  end

  @doc """
  The device's subnet routes: `{:ok, %{advertised: [...], enabled: [...]}}`.
  """
  @spec routes_get(String.t(), String.t()) ::
          {:ok, %{advertised: [String.t()], enabled: [String.t()]}} | {:error, error()}
  def routes_get(token, device_id) when is_binary(token) and is_binary(device_id) do
    req = new_req(token)

    case Req.get(req, url: "/api/v2/device/#{device_id}/routes") do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok,
         %{
           advertised: routes_list(body["advertisedRoutes"]),
           enabled: routes_list(body["enabledRoutes"])
         }}

      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:error, {:bad_payload, status}}

      {:ok, response} ->
        error_result({:ok, response})

      {:error, _reason} = error ->
        error_result(error)
    end
  end

  @doc """
  REPLACES the device's enabled route list — callers union (or
  difference) with what `routes_get/2` reported before calling.
  """
  @spec routes_set(String.t(), String.t(), [String.t()]) :: :ok | {:error, error()}
  def routes_set(token, device_id, routes) when is_binary(token) and is_list(routes) do
    req = new_req(token)

    req
    |> Req.post(url: "/api/v2/device/#{device_id}/routes", json: %{"routes" => routes})
    |> write_result()
  end

  @doc """
  Mints an enrollment auth key (ADR-0040 Am. 3): tagged, single-use,
  non-ephemeral, pre-authorized. The capabilities block is FIXED — a
  one-off key is revoked by its own consumption at join — while `opts`
  carry the caller's config policy: `:tag`, `:ttl_seconds`,
  `:description` (≤50 chars).

  The response's `key` value is the secret, delivered exactly once: it
  is returned to the caller and never logged. The call opts OUT of
  Req's body decoding and decodes manually: a decode failure would
  surface as `{:error, %Jason.DecodeError{}}` whose `data` field holds
  the RAW body — secret included — which `error_result/1` would
  inspect into a log line. `Jason.decode/1`'s error tuple is discarded
  instead; no exception, no leak. A 2xx whose body lacks a binary
  `id` or `key` (either one) is a contract break —
  `{:error, {:bad_payload, status}}` — never a converged mint.
  """
  @spec keys_create(String.t(), keyword()) ::
          {:ok, %{id: String.t(), key: String.t()}} | {:error, error()}
  def keys_create(token, opts) when is_binary(token) and is_list(opts) do
    req = new_req(token)

    case Req.post(req,
           url: "/api/v2/tailnet/-/keys",
           json: keys_create_body(opts),
           decode_body: false
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        decode_mint(status, body)

      other ->
        error_result(other)
    end
  end

  # The one place the platform decodes a response itself — because this
  # is the one response whose body carries a secret. Jason.decode/1
  # answers {:error, %Jason.DecodeError{}} on malformed input; the
  # struct's `data` is the raw body, so it is dropped unread: the
  # status is the honest answer, and nothing body-shaped can reach a
  # log through this path.
  defp decode_mint(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"id" => id, "key" => key}} when is_binary(id) and is_binary(key) ->
        {:ok, %{id: id, key: key}}

      _malformed_or_incomplete ->
        {:error, {:bad_payload, status}}
    end
  end

  defp decode_mint(status, _not_a_binary), do: {:error, {:bad_payload, status}}

  @doc """
  Revokes an auth key by id (the id is embedded in the minted
  `tskey-auth-<keyid>-…` value's own prefix — parsed upstream, so no
  second store can drift). Errors pass through untranslated:
  404-tolerance is the CALLER's policy, not the client's.
  """
  @spec keys_delete(String.t(), String.t()) :: :ok | {:error, error()}
  def keys_delete(token, key_id) when is_binary(token) and is_binary(key_id) do
    req = new_req(token)

    req
    |> Req.delete(url: "/api/v2/tailnet/-/keys/#{key_id}")
    |> write_result()
  end

  @doc """
  Exchanges an OAuth client-credential pair for a short-lived access
  token (the #836 lane-B addendum — mechanics verified live,
  2026-11-18): `POST /api/v2/oauth/token`, HTTP Basic
  (`client_id`:`client_secret`), NO body — the endpoint needs none and
  ignores scope bodies.

  The client secret rides the Authorization header — built explicitly
  rather than via Req's `auth:` option, because the stubbed-`Req.post`
  tests must be able to assert the header (the auth step never runs
  under a stub) — and is never in the URL or a logged option. 2xx
  returns `{:ok, %{access_token: String.t(), expires_in:
  pos_integer()}}`; a 2xx missing either field is
  `{:error, {:bad_payload, status}}` — the contract-break rule, never a
  converged garbage token. 401 is a real rejection of the client
  credentials (no retry); 403, others — the module's taxonomy.
  """
  @spec oauth_exchange(String.t(), String.t()) ::
          {:ok, %{access_token: String.t(), expires_in: pos_integer()}} | {:error, error()}
  def oauth_exchange(client_id, client_secret)
      when is_binary(client_id) and is_binary(client_secret) do
    # The Basic header IS the client secret: it must never ride plain
    # HTTP. A configured base_url override is validated BEFORE the
    # credential is attached (#863 review — Req validates redirects,
    # not the initial URL). Test overrides stay usable: they are https.
    with {:ok, url} <- https_base_url() do
      req =
        Req.new(
          base_url: url,
          headers: [
            {"authorization", "Basic " <> Base.encode64(client_id <> ":" <> client_secret)}
          ]
        )

      Req.post(req, url: "/api/v2/oauth/token", decode_body: false)
    end
    |> exchange_result()
  end

  defp exchange_result({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299,
       do: decode_token(status, body)

  defp exchange_result({:error, :insecure_base_url} = refusal), do: refusal

  # The exchange's error paths NEVER carry bodies or exception
  # details (#863 review): a misbehaving intermediary's 502 can echo
  # the request's Basic header in its diagnostic body, and the module
  # 's generic snippet logger assumes Tailscale's own bodies. Status
  # codes and atoms only — the same taxonomy, none of the payload.
  defp exchange_result({:ok, %Req.Response{status: @unauthorized_status}}),
    do: {:error, :unauthorized}

  defp exchange_result({:ok, %Req.Response{status: @forbidden_status}}),
    do: {:error, :forbidden}

  defp exchange_result({:ok, %Req.Response{status: status}}) do
    Logger.warning("Tailscale OAuth exchange failed with HTTP #{status}")
    {:error, %{status: status}}
  end

  defp exchange_result({:error, %Req.TransportError{reason: reason}}) do
    Logger.warning("Tailscale OAuth exchange transport error: #{inspect(reason)}")
    {:error, :network_error}
  end

  # Any other error shape: classified, never inspected — the exchange
  # is the one endpoint whose request carries the client secret.
  defp exchange_result({:error, _other_class}) do
    Logger.warning("Tailscale OAuth exchange failed (transport-class error)")
    {:error, :network_error}
  end

  # The credential-bearing endpoint's transport floor: https, or the
  # refusal happens before any secret is placed on a request.
  defp https_base_url do
    url = base_url()

    case URI.parse(url) do
      %URI{scheme: "https"} -> {:ok, url}
      _insecure_or_unparseable -> {:error, :insecure_base_url}
    end
  end

  # The exchange response carries the access token: decoded by hand,
  # the Jason error struct dropped unread (the decode_mint stance —
  # its `data` field would hold the RAW body). `expires_in` is the
  # documented integer seconds; a non-positive one can't key a cache.
  defp decode_token(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"access_token" => token, "expires_in" => seconds}}
      when is_binary(token) and is_integer(seconds) and seconds > 0 ->
        {:ok, %{access_token: token, expires_in: seconds}}

      _malformed_or_incomplete ->
        {:error, {:bad_payload, status}}
    end
  end

  defp decode_token(status, _not_a_binary), do: {:error, {:bad_payload, status}}

  @doc """
  The tailnet's split-DNS map: `%{domain => [nameservers]}`.
  """
  @spec split_dns_get(String.t()) :: {:ok, %{String.t() => [String.t()]}} | {:error, error()}
  def split_dns_get(token) when is_binary(token) do
    req = new_req(token)

    case Req.get(req, url: "/api/v2/tailnet/-/dns/split-dns") do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:error, {:bad_payload, status}}

      {:ok, response} ->
        error_result({:ok, response})

      {:error, _reason} = error ->
        error_result(error)
    end
  end

  @doc """
  The per-domain upsert (§3): `%{"domain" => ["ip"]}` sets that domain;
  `%{"domain" => nil}` unsets it. Everything not in the map is
  untouched — this is why claims cannot race the customer's other
  split-DNS edits.
  """
  @spec split_dns_patch(String.t(), %{String.t() => [String.t()] | nil}) ::
          :ok | {:error, error()}
  def split_dns_patch(token, routes) when is_binary(token) and is_map(routes) do
    req = new_req(token)

    req
    |> Req.patch(url: "/api/v2/tailnet/-/dns/split-dns", json: routes)
    |> write_result()
  end

  # ------------------------------------------------------------------
  # Plumbing
  # ------------------------------------------------------------------

  defp new_req(token) do
    Req.new(base_url: base_url(), headers: [{"authorization", "Bearer " <> token}])
  end

  # App config with the production default — testable without network
  # (the HitPay base_url stance).
  defp base_url do
    :flux_vale
    |> Application.get_env(:tailscale_api, [])
    |> Keyword.get(:base_url, @base_url)
  end

  # The minted key's shape (the 836 plan's R1 ruling): reusable/
  # ephemeral/preauthorized are FIXED — not policy the caller can
  # move. Tag, TTL and description are the caller's config policy.
  # The API embeds the id in the key value itself and answers with
  # both exactly once (verified: Tailscale api.md `4e822c0`).
  defp keys_create_body(opts) do
    tag = Keyword.fetch!(opts, :tag)
    ttl_seconds = Keyword.fetch!(opts, :ttl_seconds)
    description = Keyword.fetch!(opts, :description)

    create = %{
      "reusable" => false,
      "ephemeral" => false,
      "preauthorized" => true,
      "tags" => [tag]
    }

    %{
      "capabilities" => %{"devices" => %{"create" => create}},
      "expirySeconds" => ttl_seconds,
      "description" => description
    }
  end

  # The object wrapper's devices list; a map without one means the node
  # is simply not in the payload (the bare-array envelope is handled at
  # the call site).
  defp devices_from(%{"devices" => devices}) when is_list(devices), do: devices
  defp devices_from(_no_devices_key), do: []

  defp find_device(devices, hostname) do
    matches = Enum.filter(devices, &name_matches?(&1, hostname))

    case matches do
      [] ->
        {:error, :not_found}

      [only] ->
        device_result(only)

      _many ->
        # Same name on two nodes: prefer a live one, then the freshest
        # lastSeen. A split vote among DEAD nodes is refused — the
        # route would point at a ghost (P2-5).
        online = Enum.filter(matches, &(&1["online"] == true))

        case online do
          [] ->
            {:error, :node_ambiguous}

          [only] ->
            device_result(only)

          _several_online ->
            device_result(Enum.max_by(online, &seen_at/1))
        end
    end
  end

  defp device_result(%{"id" => id} = device) when is_binary(id),
    do: {:ok, %{id: id, tailscale_ips: addresses(device)}}

  # A row that matched by name but carries no usable id cannot be
  # claimed against — refused, and the caller surfaces :node_not_found.
  defp device_result(_malformed), do: {:error, :not_found}

  # The node's Tailscale IPs (spike: the local API's TailscaleIPs; the
  # tailnet API names them `addresses`). Missing or malformed → [] —
  # the id remains claimable, only the view-building skips such a node.
  defp addresses(%{"addresses" => ips}) when is_list(ips),
    do: Enum.filter(ips, &is_binary/1)

  defp addresses(_missing), do: []

  defp name_matches?(%{"name" => name}, hostname) when is_binary(name) do
    [first_label | _rest] = String.split(name, ".", parts: 2)
    first_label == hostname
  end

  defp name_matches?(_malformed, _hostname), do: false

  # RFC3339 strings from the API; unparseable timestamps sort oldest so
  # a live-looking node with a broken clock never wins on garbage.
  defp seen_at(%{"lastSeen" => seen}) when is_binary(seen) do
    case DateTime.from_iso8601(seen) do
      {:ok, dt, _offset} -> dt
      _unparseable -> ~U[1970-01-01 00:00:00Z]
    end
  end

  defp seen_at(_missing), do: ~U[1970-01-01 00:00:00Z]

  defp routes_list(routes) when is_list(routes), do: routes
  defp routes_list(_missing), do: []

  defp write_result({:ok, %Req.Response{status: status}}) when status in 200..299 do
    :ok
  end

  defp write_result(other), do: error_result(other)

  defp error_result({:ok, %Req.Response{status: @unauthorized_status, body: _body}}) do
    {:error, :unauthorized}
  end

  defp error_result({:ok, %Req.Response{status: @forbidden_status, body: _body}}) do
    {:error, :forbidden}
  end

  defp error_result({:ok, %Req.Response{status: status, body: body}}) do
    snippet = body_snippet(body)
    Logger.warning("Tailscale API returned #{status}: #{snippet}")
    {:error, %{status: status, body: snippet}}
  end

  defp error_result({:error, exception}) do
    Logger.warning("Tailscale API network error: #{inspect(exception)}")
    {:error, :network_error}
  end

  # Logs stay bounded, and the token is never in a body — it rides the
  # request header only, which is never logged.
  defp body_snippet(body) do
    body
    |> inspect()
    |> String.slice(0, 200)
  end
end
