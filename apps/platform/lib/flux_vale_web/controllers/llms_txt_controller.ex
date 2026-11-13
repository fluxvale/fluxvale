defmodule FluxValeWeb.LlmsTxtController do
  @moduledoc """
  `GET /llms.txt` (#765): the machine-readable agent entry point. One
  stable URL an agent can be pointed at, carrying the same prompt the
  `/agent` panel and `/docs/agents` render (one fixture:
  `FluxValeWeb.AgentPrompt`) plus the doc links.

  Plain text, no layout, no session. The noindex plug still rides so a
  staging copy advertises itself as non-canonical.
  """

  use FluxValeWeb, :controller

  alias FluxValeWeb.AgentPrompt

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    body = AgentPrompt.llms_txt(AgentPrompt.public_context())

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end
end
