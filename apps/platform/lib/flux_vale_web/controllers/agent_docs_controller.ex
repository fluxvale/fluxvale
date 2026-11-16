defmodule FluxValeWeb.AgentDocsController do
  @moduledoc """
  `GET /docs/agents` (#765): the public, machine-readable version of the
  post-registration handoff. It renders the same prompt as `/agent` and
  `/llms.txt` from `FluxValeWeb.AgentPrompt`, with the org left as a
  placeholder — any agent (or human) can be pointed at one stable URL.

  Signed-in readers also get a link to the personalized surface, the
  `/agent` panel (#817); on first run the same handoff opens as a
  modal from the signed-in dashboard's empty state.

  A literal route before `/docs/:section`: "agents" is a page, not a
  docs section. The regular docs sidebar rides along for the way back.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Docs
  alias FluxValeWeb.AgentPrompt

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    Docs.maybe_hot_reload()

    ctx = AgentPrompt.public_context()

    clients = AgentPrompt.clients_with_code(ctx)

    conn
    |> assign(:page_title, "Set up with your agent · FluxVale Docs")
    |> assign(:page_description, "One prompt that finishes a FluxVale setup over MCP.")
    |> assign(:canonical_path, "/docs/agents")
    |> assign(:sections, Docs.sections_with_pages())
    |> assign(:prompt, AgentPrompt.prompt(ctx))
    |> assign(:clients, clients)
    |> assign(:what_it_will_do, AgentPrompt.what_it_will_do())
    |> assign(:commit_rule, AgentPrompt.commit_rule())
    |> assign(:snippet_note, AgentPrompt.snippet_note())
    |> assign(:links, AgentPrompt.links(ctx))
    |> render(:show)
  end
end
