defmodule FluxValeWeb.Plugs.CaptureIpCountry do
  @moduledoc """
  Records the buyer's IP country as a checkout location signal (#138,
  ADR-0029 Am. 3 gate 2): reads the edge-owned `cf-ipcountry` header and
  stores it in the session, where the top-up wizard picks it up in
  mount.

  Only the edge's header is trusted — arbitrary `x-*` headers are
  client-settable and would let a buyer fake the signal. And the signal
  is record-only regardless: behind a bare proxy the header itself is
  client-settable too, so it can never VERIFY anything. The billing
  address is the sole rate-deciding proof; this value rides along so
  the return's evidence trail shows whether it matched
  (`FluxVale.Billing.Tax.ip_matches_billing?/2`).

  Tolerant by design — VPNs and roaming make IP weak either way: a
  missing header records nothing, a mismatch is recorded and never
  blocks the buyer. The value is trimmed and uppercased; no shape
  validation — an odd header ("T1" for Tor) just never matches a
  billing country. A request without the header clears any stale
  session value, so a signal can never outlive the request that
  produced it.

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
