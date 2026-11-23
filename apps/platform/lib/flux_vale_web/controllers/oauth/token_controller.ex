defmodule FluxValeWeb.OAuth.TokenController do
  @moduledoc """
  The token and revocation endpoints (#766): form-encoded
  `authorization_code` / `refresh_token` grants, the `device_code`
  grant (#886, RFC 8628 §3.5), and RFC 7009 revocation.

  Token responses carry `no-store` (RFC 6749 §5.1). Errors use the
  §5.2 JSON envelope; the protocol's `invalid_grant` / `invalid_target`
  distinctions stay intact. The device grant's §3.5 states
  (`authorization_pending`, `slow_down`, `access_denied`,
  `expired_token`) ride the same envelope as 400s.
  """

  use FluxValeWeb, :controller

  alias FluxVale.OAuth
  alias FluxValeWeb.Plugs.OAuthRateLimit

  # The device grant routes by its wire URN, read from the domain seam
  # (one tie shared with metadata and PollDeviceGrant).
  @device_grant_type OAuth.device_grant_type()

  @spec token(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def token(conn, _params) do
    bucket = rate_limit_bucket(conn.body_params)

    case OAuthRateLimit.allow?(conn, bucket) do
      :ok -> grant(conn, conn.body_params)
      {:error, retry_after} -> rate_limited(conn, retry_after)
    end
  end

  defp rate_limit_bucket(%{"grant_type" => @device_grant_type}), do: :device_poll
  defp rate_limit_bucket(_params), do: :token

  defp grant(conn, %{"grant_type" => grant_type} = params)
       when grant_type == "authorization_code" or
              grant_type == "refresh_token" or
              grant_type == @device_grant_type do
    params
    |> route_grant(grant_type)
    |> token_result(conn)
  end

  defp grant(conn, _params) do
    oauth_error(
      conn,
      :unsupported_grant_type,
      "grant_type must be authorization_code, refresh_token, or #{@device_grant_type}",
      400
    )
  end

  defp route_grant(params, "authorization_code"), do: OAuth.exchange_code(params)
  defp route_grant(params, "refresh_token"), do: OAuth.refresh_token(params)
  defp route_grant(params, @device_grant_type), do: OAuth.poll_device_grant(params)

  @spec revoke(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def revoke(conn, _params) do
    case OAuthRateLimit.allow?(conn, :revoke) do
      :ok -> revoke_token(conn, conn.body_params)
      {:error, retry_after} -> rate_limited(conn, retry_after)
    end
  end

  defp revoke_token(conn, params) do
    case OAuth.revoke_token(params) do
      :ok ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, "")

      {:error, :invalid_request} ->
        oauth_error(conn, :invalid_request, "token and client_id are required", 400)
    end
  end

  defp token_result({:ok, response}, conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> json(response)
  end

  # coveralls-ignore-start - mint failure = DB outage; the domain's
  # server_error arm, not sequentially stageable.
  defp token_result({:error, {:server_error, description}}, conn) do
    oauth_error(conn, :server_error, description, 500)
  end

  # coveralls-ignore-stop

  defp token_result({:error, {kind, description}}, conn) do
    oauth_error(conn, kind, description, 400)
  end

  defp rate_limited(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> oauth_error(:temporarily_unavailable, "the endpoint is rate limited", 429)
  end

  defp oauth_error(conn, kind, description, status) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_status(status)
    |> json(%{error: to_string(kind), error_description: description})
  end
end
