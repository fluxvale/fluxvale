defmodule FluxValeWeb.AgentDocsControllerTest do
  @moduledoc false

  # /docs/agents (#765): the public page renders the same prompt and
  # snippets as the panel, with the org left as a placeholder. A
  # literal route, not a docs section.

  use FluxValeWeb.ConnCase, async: false

  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.AgentPrompt

  test "serves the generic prompt, the client snippets, and the docs links", %{conn: conn} do
    conn = get(conn, ~p"/docs/agents")
    html = html_response(conn, 200)

    assert html =~ "Set up with your agent"
    assert html =~ "your organization (&lt;your-org-slug&gt;)"
    assert html =~ AgentPrompt.mcp_url()
    assert html =~ "claude mcp add --transport http fluxvale"

    for client <- ["claude-code", "cursor", "vscode", "generic"] do
      assert html =~ "agent-docs-client-#{client}"
    end

    assert html =~ "Confirm the spend"
    assert html =~ ~s(href="/docs/automation/mcp")
    assert html =~ ~s(href="/docs/automation/terraform")

    refute html =~ "fvpat_"
  end

  test "the OAuth mode keeps the PAT fallback in the note", %{conn: conn} do
    previous = Application.get_env(:flux_vale, :mcp_auth_mode)
    on_exit(fn -> Application.put_env(:flux_vale, :mcp_auth_mode, previous) end)
    Application.put_env(:flux_vale, :mcp_auth_mode, :oauth)

    conn = get(conn, ~p"/docs/agents")
    html = html_response(conn, 200)

    assert html =~ "FLUXVALE_PAT"
    assert html =~ "browser sign-in"
    refute html =~ "--header"
  end

  test "the docs sidebar renders with the normal sections", %{conn: conn} do
    conn = get(conn, ~p"/docs/agents")
    html = html_response(conn, 200)

    assert html =~ ~s(class="docs-nav")
    assert html =~ ~s(href="/docs/automation/mcp")

    # #799: the guide lists itself at the sidebar's top, active.
    document = LazyHTML.from_document(html)
    agent_entry = LazyHTML.query(document, ~s(nav.docs-nav a[href="/docs/agents"]))
    entry_html = LazyHTML.to_html(agent_entry)
    agent_text = LazyHTML.text(agent_entry)

    assert String.trim(agent_text) == "Set up with your agent"
    assert entry_html =~ ~s(aria-current="page")
    assert entry_html =~ "docs-nav-link-active"
  end

  # #817: the guide connects to the personalized surface. MaybeResolveUser
  # assigns current_user display-only (#164) — the link is chrome, not a gate.
  test "signed-in readers get the personalized panel link", %{conn: conn} do
    {_user, session_conn} = SessionHelpers.user_with_session(conn)

    conn = get(session_conn, ~p"/docs/agents")
    html = html_response(conn, 200)

    document = LazyHTML.from_document(html)
    link = LazyHTML.query(document, ~s(a[data-testid="agent-docs-personalized-link"]))

    assert LazyHTML.text(link) == "Open your personalized panel"
    # attribute/2 lists values across matches — exactly one anchor here.
    assert LazyHTML.attribute(link, "href") == ["/agent"]
  end

  test "the anonymous render carries no personalized panel link", %{conn: conn} do
    conn = get(conn, ~p"/docs/agents")
    html = html_response(conn, 200)

    refute html =~ ~s(href="/agent")
    refute html =~ "agent-docs-personalized-link"
  end
end
