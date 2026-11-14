defmodule FluxValeWeb.OAuth.MetadataController do
  @moduledoc """
  RFC 8414 authorization-server metadata (#766). Public and
  cacheable-by-nobody: the document is small and must always agree
  with the deployed endpoints, so it carries `no-store`.

  The MCP spec's discovery order lands here from the protected
  resource metadata's `authorization_servers` entry.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Api.Scopes
  alias FluxValeWeb.OAuth.Issuer

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      issuer: Issuer.issuer(),
      authorization_endpoint: Issuer.endpoint("/oauth/authorize"),
      token_endpoint: Issuer.endpoint("/oauth/token"),
      registration_endpoint: Issuer.endpoint("/oauth/register"),
      revocation_endpoint: Issuer.endpoint("/oauth/revoke"),
      scopes_supported: Scopes.oauth_scopes(),
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      token_endpoint_auth_methods_supported: ["none"],
      revocation_endpoint_auth_methods_supported: ["none"],
      code_challenge_methods_supported: ["S256"],
      authorization_response_iss_parameter_supported: true
    })
  end
end
