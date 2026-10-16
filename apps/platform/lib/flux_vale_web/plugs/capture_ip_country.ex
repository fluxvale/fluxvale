defmodule FluxValeWeb.Plugs.CaptureIpCountry do
  @moduledoc """
  Records the buyer's IP country as checkout location evidence (#138,
  ADR-0029 Am. 3 gate 2): reads the edge geo header (prefer
  `cf-ipcountry`, fall back to `x-ip-country`) and stores it in the
  session, where the top-up wizard picks it up in mount.

  Tolerant by design — the IP is the weak second proof (VPNs, roaming):
  a missing header records nothing, a mismatch is recorded and never
  blocks the buyer (`FluxVale.Billing.Tax.location_verified?/2`). The
  value is trimmed and uppercased; no shape validation — an odd header
  ("T1" for Tor on Cloudflare) just never matches a billing country.

  Dependency-free and pipeline-order-agnostic beyond needing the
  session (it only writes it); testable by setting the request header
  on a ConnCase conn.
  """

  @geo_headers ["cf-ipcountry", "x-ip-country"]
  @session_key "ip_country"

  @doc false
  @spec init(keyword) :: keyword
  def init(opts), do: opts

  @doc "Stores the geo header's country (if any) in the session."
  @spec call(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  def call(conn, _opts) do
    case geo_country(conn) do
      nil -> conn
      country -> Plug.Conn.put_session(conn, @session_key, country)
    end
  end

  # First configured header that carries a non-empty value wins.
  defp geo_country(conn) do
    Enum.find_value(@geo_headers, fn header ->
      case Plug.Conn.get_req_header(conn, header) do
        [value | _rest] -> normalize(value)
        [] -> nil
      end
    end)
  end

  defp normalize(value) do
    trimmed =
      value
      |> String.trim()
      |> String.upcase()

    if trimmed == "", do: nil, else: trimmed
  end
end
