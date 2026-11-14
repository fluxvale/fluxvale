defmodule FluxValeWeb.OAuth.PreflightController do
  @moduledoc """
  The OPTIONS answer for the CORS-enabled OAuth endpoints (#766): the
  CORS plug has already written the allow headers; this sends the
  empty 204 the browser's preflight expects.
  """

  use FluxValeWeb, :controller

  @spec options(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def options(conn, _params) do
    send_resp(conn, 204, "")
  end
end
