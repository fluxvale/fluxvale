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

  `tailnet/-` (the dash) addresses the key's own tailnet — one
  credential, one tailnet, no tailnet id handling.
  """

  require Logger

  @base_url "https://api.tailscale.com"

  # The drift signal (ADR-0040 §5): the key was rejected — expired and
  # revoked present identically (API keys expire ≤90 days by design).
  @unauthorized_statuses [401, 403]

  @typedoc "A non-2xx other than 401/403: the status plus a body snippet."
  @type api_error :: %{status: pos_integer(), body: String.t()}

  @type error :: :unauthorized | :not_found | :network_error | api_error()

  @doc """
  Finds the tailnet device whose name's FIRST label is `hostname` (the
  gateway's opaque `fv-…` name; the API returns full MagicDNS FQDNs).
  Routes are not part of this payload — `routes_get/2` is the next call.
  """
  @spec devices_lookup(String.t(), String.t()) ::
          {:ok, %{id: String.t()}} | {:error, error()}
  def devices_lookup(token, hostname) when is_binary(token) and is_binary(hostname) do
    req = new_req(token)

    req
    |> Req.get(url: "/api/v2/tailnet/-/devices")
    |> devices_result(hostname)
  end

  @doc """
  The device's subnet routes: `{:ok, %{advertised: [...], enabled: [...]}}`.
  """
  @spec routes_get(String.t(), String.t()) ::
          {:ok, %{advertised: [String.t()], enabled: [String.t()]}} | {:error, error()}
  def routes_get(token, device_id) when is_binary(token) and is_binary(device_id) do
    req = new_req(token)

    req
    |> Req.get(url: "/api/v2/device/#{device_id}/routes")
    |> routes_result()
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
  The tailnet's split-DNS map: `%{domain => [nameservers]}`.
  """
  @spec split_dns_get(String.t()) :: {:ok, %{String.t() => [String.t()]}} | {:error, error()}
  def split_dns_get(token) when is_binary(token) do
    req = new_req(token)

    req
    |> Req.get(url: "/api/v2/tailnet/-/dns/split-dns")
    |> split_dns_result()
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

  defp devices_result({:ok, %Req.Response{status: status, body: body}}, hostname)
       when status in 200..299 do
    find_device(devices_from(body), hostname)
  end

  defp devices_result(other, _hostname), do: error_result(other)

  # Liberal on the envelope (the SDK exposes both the bare array and the
  # `{"devices": [...]}` wrapper across v2 generations), strict on the
  # match: the first label of a device's name must equal the hostname.
  defp devices_from(devices) when is_list(devices), do: devices
  defp devices_from(%{"devices" => devices}) when is_list(devices), do: devices
  defp devices_from(_unrecognized), do: []

  defp find_device(devices, hostname) do
    device = Enum.find(devices, &name_matches?(&1, hostname))

    case device do
      %{"id" => id} when is_binary(id) -> {:ok, %{id: id}}
      _none_or_malformed -> {:error, :not_found}
    end
  end

  defp name_matches?(%{"name" => name}, hostname) when is_binary(name) do
    [first_label | _rest] = String.split(name, ".", parts: 2)
    first_label == hostname
  end

  defp name_matches?(_malformed, _hostname), do: false

  defp routes_result({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    {:ok,
     %{
       advertised: routes_list(body["advertisedRoutes"]),
       enabled: routes_list(body["enabledRoutes"])
     }}
  end

  defp routes_result(other), do: error_result(other)

  defp routes_list(routes) when is_list(routes), do: routes
  defp routes_list(_missing), do: []

  defp split_dns_result({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    {:ok, body}
  end

  defp split_dns_result(other), do: error_result(other)

  defp write_result({:ok, %Req.Response{status: status}}) when status in 200..299 do
    :ok
  end

  defp write_result(other), do: error_result(other)

  defp error_result({:ok, %Req.Response{status: status, body: _body}})
       when status in @unauthorized_statuses do
    {:error, :unauthorized}
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
