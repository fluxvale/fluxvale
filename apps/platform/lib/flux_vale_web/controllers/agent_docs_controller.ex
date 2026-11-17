defmodule FluxValeWeb.AgentDocsController do
  @moduledoc """
  `GET /docs/agents` (#765): the impersonal public guide to the agent
  setup — prose and pointers, no prompt and no client snippets (#817).
  The full handoff renders only on the signed-in surfaces: the
  `/agent` panel and the dashboard's first-run modal, both from
  `FluxValeWeb.AgentPrompt`. Signed-in readers get a link to the
  panel; anonymous readers get the account door,
  `/sign-in?return_to=/agent`. Never a 404.

  A literal route before `/docs/:section`: "agents" is a page, not a
  docs section. The regular docs sidebar rides along for the way back.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Docs
  alias FluxValeWeb.ReturnPath

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    Docs.maybe_hot_reload()

    conn
    |> assign(:page_title, "Set up with your agent · FluxVale Docs")
    |> assign(:page_description, "One prompt that finishes a FluxVale setup over MCP.")
    |> assign(:canonical_path, "/docs/agents")
    |> assign(:sections, Docs.sections_with_pages())
    |> assign(:sign_in_path, ReturnPath.sign_in_path(~p"/agent"))
    |> render(:show)
  end
end
