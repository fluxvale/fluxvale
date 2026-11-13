defmodule FluxValeWeb.AgentDocsControllerTest do
  @moduledoc false

  # /docs/agents (#765): the public page renders the same prompt and
  # snippets as the panel, with the org left as a placeholder. A
  # literal route, not a docs section.

  use FluxValeWeb.ConnCase, async: false

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

  test "the OAuth mode swaps the token sentence too", %{conn: conn} do
    previous = Application.get_env(:flux_vale, :mcp_auth_mode)
    on_exit(fn -> Application.put_env(:flux_vale, :mcp_auth_mode, previous) end)
    Application.put_env(:flux_vale, :mcp_auth_mode, :oauth)

    conn = get(conn, ~p"/docs/agents")
    html = html_response(conn, 200)

    refute html =~ "FLUXVALE_PAT"
    assert html =~ "browser sign-in"
    refute html =~ "--header"
  end

  test "the docs sidebar renders with the normal sections", %{conn: conn} do
    conn = get(conn, ~p"/docs/agents")
    html = html_response(conn, 200)

    assert html =~ ~s(class="docs-nav")
    assert html =~ ~s(href="/docs/automation/mcp")
  end
end
