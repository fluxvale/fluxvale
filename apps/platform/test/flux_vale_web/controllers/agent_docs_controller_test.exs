defmodule FluxValeWeb.AgentDocsControllerTest do
  @moduledoc false

  # /docs/agents (#765): the impersonal public guide (#817) — prose and
  # pointers, no prompt and no snippets. The full handoff renders only
  # on the signed-in surfaces. A literal route, not a docs section.

  use FluxValeWeb.ConnCase, async: false

  alias FluxVale.TestSupport.SessionHelpers

  # A stable literal from AgentPrompt.prompt/1 — if the prompt ever
  # leaks onto the public page, this fails.
  @prompt_line "You are my FluxVale setup agent. Connect to the MCP server above"

  test "serves the impersonal guide — no prompt, no snippets", %{conn: conn} do
    conn = get(conn, ~p"/docs/agents")
    html = html_response(conn, 200)

    assert html =~ "Set up with your agent"
    assert html =~ "What the agent does"
    assert html =~ "Get the prompt"

    # The anonymous door: sign-in, carrying /agent as the return path.
    document = LazyHTML.from_document(html)
    link = LazyHTML.query(document, ~s(a[data-testid="agent-docs-sign-in-link"]))
    assert LazyHTML.attribute(link, "href") == ["/sign-in?return_to=%2Fagent"]

    # #817: no prompt content of any kind — no prompt block, no recipe,
    # no client configs.
    refute html =~ "agent-docs-prompt"
    refute html =~ @prompt_line
    refute html =~ "claude mcp add"
    refute html =~ "agent-docs-client"
    refute html =~ "<pre"
    refute html =~ "fvpat_"

    # The reading surface's pointers stand.
    assert html =~ ~s(href="/docs/automation/mcp")
    assert html =~ ~s(href="/docs/automation/terraform")
    assert html =~ ~s(href="/llms.txt")
  end

  # The auth mode drives the snippets, and the guide carries none — no
  # mode may leak content onto the public page.
  test "no auth-mode snippet content leaks onto the guide", %{conn: conn} do
    previous = Application.get_env(:flux_vale, :mcp_auth_mode)
    on_exit(fn -> Application.put_env(:flux_vale, :mcp_auth_mode, previous) end)
    Application.put_env(:flux_vale, :mcp_auth_mode, :oauth)

    conn = get(conn, ~p"/docs/agents")
    html = html_response(conn, 200)

    assert html =~ "Set up with your agent"
    refute html =~ "FLUXVALE_PAT"
    refute html =~ "browser sign-in"
    refute html =~ "--header"
    refute html =~ "agent-docs-client"
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
  test "signed-in readers get the personalized panel link and still no prompt", %{conn: conn} do
    {_user, session_conn} = SessionHelpers.user_with_session(conn)

    conn = get(session_conn, ~p"/docs/agents")
    html = html_response(conn, 200)

    document = LazyHTML.from_document(html)
    link = LazyHTML.query(document, ~s(a[data-testid="agent-docs-personalized-link"]))

    assert LazyHTML.text(link) == "Open your personalized panel"
    # attribute/2 lists values across matches — exactly one anchor here.
    assert LazyHTML.attribute(link, "href") == ["/agent"]

    # The guide stays impersonal signed-in too — the prompt is on /agent.
    refute html =~ "agent-docs-prompt"
    refute html =~ @prompt_line
  end

  test "the anonymous render carries no personalized panel link", %{conn: conn} do
    conn = get(conn, ~p"/docs/agents")
    html = html_response(conn, 200)

    refute html =~ ~s(href="/agent")
    refute html =~ "agent-docs-personalized-link"
  end

  test "the guide mentions the CLI bridge and links to the CLI page", %{conn: conn} do
    conn = get(conn, ~p"/docs/agents")
    html = html_response(conn, 200)

    assert html =~ "FluxVale CLI bridges it to the server"
    # The guide's own link, with its text. The page's sidebar also links to the CLI page.
    assert html =~ ~s(<a href="/docs/automation/cli">CLI guide</a>)

    # The copy says the CLI page has the two commands, so that page must carry the section.
    cli_conn = get(conn, ~p"/docs/automation/cli")
    assert html_response(cli_conn, 200) =~ "Connect an MCP client"
  end

  test "the guide walks through the SSO branch and links the Pocket ID guide", %{conn: conn} do
    conn = get(conn, ~p"/docs/agents")
    html = html_response(conn, 200)

    assert html =~ "Ask once whether you want single sign-on (OIDC) for your apps"
    assert html =~ "deploys and wires Pocket ID"

    # The guide's own link, with its text.
    assert html =~ ~s(<a href="/docs/guides/sso">Pocket ID SSO guide</a>)

    # The new list item's words, with its line breaks collapsed so the
    # template's wrapping does not decide these. The older list items
    # carry semicolons on purpose.
    item_html =
      html
      |> String.split("Ask once whether")
      |> List.last()
      |> String.split("</li>")
      |> List.first()

    item_text = String.replace(item_html, ~r/\s+/, " ")

    assert item_text =~ "connecting Pocket ID is free and needs no top-up"
    assert item_text =~ "any welcome credit goes toward that"
    assert item_text =~ "deploys and wires Pocket ID"
    refute item_text =~ "paid"
    refute item_text =~ "recommends a top-up"
    refute item_text =~ "check out"
    refute item_html =~ "—"
    refute item_html =~ ";"

    # The guide stays impersonal — no prompt content of any kind.
    refute html =~ "agent-docs-prompt"
    refute html =~ @prompt_line
    refute html =~ "claude mcp add"
    refute html =~ "agent-docs-client"
    refute html =~ "<pre"
    refute html =~ "fvpat_"

    # The linked guide page must exist and be about Pocket ID.
    sso_conn = get(conn, ~p"/docs/guides/sso")
    assert html_response(sso_conn, 200) =~ "Pocket ID"
  end
end
