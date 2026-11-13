defmodule FluxValeWeb.OAuth.RegistrationController do
  @moduledoc """
  Dynamic client registration (#766, RFC 7591). Unauthenticated by
  design; the per-IP window and the global per-window client cap keep a
  flood from filling the registry.

  Errors use RFC 7591 §3.2.2's codes (`invalid_redirect_uri`,
  `invalid_client_metadata`) with the RFC 6749 §5.2 JSON envelope.
  """

  use FluxValeWeb, :controller

  alias FluxVale.OAuth
  alias FluxValeWeb.Plugs.OAuthRateLimit

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    with :ok <- rate_limit(conn),
         :ok <- client_cap() do
      register(conn)
    else
      {:error, retry_after} -> rate_limited(conn, retry_after)
    end
  end

  defp register(conn) do
    case OAuth.register_client(conn.body_params) do
      {:ok, client} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_status(201)
        |> json(%{
          client_id: client.client_id,
          client_id_issued_at: DateTime.to_unix(client.created_at),
          client_name: client.client_name,
          redirect_uris: client.redirect_uris,
          grant_types: client.grant_types,
          response_types: client.response_types,
          token_endpoint_auth_method: client.token_endpoint_auth_method
        })

      {:error, {:invalid_redirect_uri, uri}} ->
        error(conn, 400, "invalid_redirect_uri", "unsupported redirect URI #{inspect(uri)}")

      {:error, {:invalid_client_metadata, detail}} ->
        error(conn, 400, "invalid_client_metadata", detail)

      {:error, {kind, scope}} when kind in [:invalid_scope, :duplicate_scope] ->
        error(conn, 400, "invalid_client_metadata", "scope #{inspect(scope)} is not supported")

      {:error, _changeset} ->
        error(conn, 400, "invalid_client_metadata", "the client metadata was refused")
    end
  end

  defp rate_limit(conn) do
    case OAuthRateLimit.allow?(conn, :register) do
      :ok -> :ok
      {:error, retry_after} -> {:error, retry_after}
    end
  end

  defp client_cap do
    if OAuth.client_cap_reached?(), do: {:error, OAuth.client_cap_window_seconds()}, else: :ok
  end

  # The with-else arm for both gates: 429 with the retry window.
  defp rate_limited(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_header("cache-control", "no-store")
    |> put_status(429)
    |> json(%{
      error: "temporarily_unavailable",
      error_description: "registration is temporarily rate limited"
    })
  end

  defp error(conn, status, code, description) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(%{error: code, error_description: description})
  end
end
