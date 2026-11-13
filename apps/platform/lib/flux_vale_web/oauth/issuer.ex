defmodule FluxValeWeb.OAuth.Issuer do
  @moduledoc """
  The authorization server's stable origin (#766): RFC 8414's `issuer`
  and the prefix every metadata endpoint is built from.

  It is the endpoint's configured URL, never the request's `Host`
  header — the issuer must not change with an attacker-supplied host,
  and the metadata/PRM documents must agree exactly.
  """

  @doc "The issuer origin, e.g. `https://fluxvale.com`."
  @spec issuer() :: String.t()
  def issuer, do: FluxValeWeb.Endpoint.url()

  @doc "An absolute endpoint URL on the issuer origin."
  @spec endpoint(String.t()) :: String.t()
  def endpoint(path), do: issuer() <> path
end
