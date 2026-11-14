defmodule FluxValeWeb.Plugs.OAuthCors do
  @moduledoc """
  CORS for the OAuth browser-facing endpoints (#766): the metadata,
  registration, token, and revocation surfaces are public and
  credential-free, so `Access-Control-Allow-Origin: *` is safe.
  `authorization` stays allowed in the preflight because a public
  client may still send the header shape; no cookies are allowed.
  """

  import Plug.Conn

  @doc false
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc """
  Sets the CORS headers; the OPTIONS routes answer 204 through the
  preflight controller.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
    |> put_resp_header("access-control-max-age", "86400")
  end
end
