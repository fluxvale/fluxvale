defmodule FluxValeWeb.OAuth.DeviceController do
  @moduledoc """
  The device authorization endpoint (#886, RFC 8628 §3.1/§3.2): mints
  one device grant for the CLI's redirectless flow.

  Plain JSON, not form or JSON:API — the CLI is the caller and RFC
  8628 bodies are bare `application/json` (the Identity device wire's
  rationale). Unauthenticated BY DESIGN: the CLI has no token yet,
  this endpoint is how it earns one; the per-IP window bounds minting.

  The verification URLs point at the hosted page (`/oauth/device`,
  S2): the page is the human's half of the flow — nothing redirects
  anywhere, which is the point of the grant.
  """

  use FluxValeWeb, :controller

  alias FluxVale.OAuth
  alias FluxVale.OAuth.DeviceGrant
  alias FluxValeWeb.OAuth.Issuer
  alias FluxValeWeb.Plugs.OAuthRateLimit

  @spec create_grant(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_grant(conn, _params) do
    case OAuthRateLimit.allow?(conn, :device_code) do
      :ok -> mint(conn, conn.body_params)
      {:error, retry_after} -> rate_limited(conn, retry_after)
    end
  end

  defp mint(conn, params) do
    case OAuth.mint_device_grant(params) do
      {:ok, minted} ->
        verification_uri = Issuer.endpoint("/oauth/device")

        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(%{
          device_code: minted.device_code,
          user_code: minted.grant.user_code,
          verification_uri: verification_uri,
          verification_uri_complete: verification_uri <> "?user_code=" <> minted.grant.user_code,
          expires_in: minted.expires_in,
          interval: DeviceGrant.poll_interval_seconds()
        })

      {:error, {kind, description}} ->
        oauth_error(conn, kind, description)
    end
  end

  defp rate_limited(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> oauth_error(:temporarily_unavailable, "the endpoint is rate limited", 429)
  end

  # The RFC 8628 §3.1 error envelope — OAuth §5.2's shape, status 400.
  defp oauth_error(conn, error, description, status \\ 400) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(%{error: to_string(error), error_description: description})
  end
end
