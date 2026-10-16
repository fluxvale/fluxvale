defmodule FluxValeWeb.Plugs.CaptureIpCountry do
  @moduledoc """
  Records the buyer's IP country as checkout location evidence (#138,
  ADR-0029 Am. 3 gate 2): reads the edge-owned `cf-ipcountry` header and
  stores it in the session, where the top-up wizard picks it up in
  mount.

  Only the edge's header is trusted — Cloudflare overwrites/sanitizes
  `cf-ipcountry` on every request, while arbitrary `x-*` headers are
  client-settable and would let a buyer forge the OSS location evidence.

  Tolerant by design — the IP is the weak second proof (VPNs, roaming):
  a missing header records nothing, a mismatch is recorded and never
  blocks the buyer (`FluxVale.Billing.Tax.location_verified?/2`). The
  value is trimmed and uppercased; no shape validation — an odd header
  ("T1" for Tor) just never matches a billing country. A request
  without the header clears any stale session value, so evidence can
  never outlive the request that produced it.

  Dependency-free and pipeline-order-agnostic beyond needing the
  session (it only writes it); testable by setting the request header
  on a ConnCase conn.
  """

  @edge_header "cf-ipcountry"
  @session_key "ip_country"

  @doc false
  @spec init(keyword) :: keyword
  def init(opts), do: opts

  @doc "Stores the edge geo header's country (if any) in the session."
  @spec call(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  def call(conn, _opts) do
    case geo_country(conn) do
      # No evidence this request — clear any stale value so a
      # previous request's country cannot persist into a later
      # checkout.
      nil -> Plug.Conn.delete_session(conn, @session_key)
      country -> Plug.Conn.put_session(conn, @session_key, country)
    end
  end

  defp geo_country(conn) do
    case Plug.Conn.get_req_header(conn, @edge_header) do
      [value | _rest] -> normalize(value)
      [] -> nil
    end
  end

  defp normalize(value) do
    trimmed =
      value
      |> String.trim()
      |> String.upcase()

    if trimmed == "", do: nil, else: trimmed
  end
end
