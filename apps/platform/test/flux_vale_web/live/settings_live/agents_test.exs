defmodule FluxValeWeb.SettingsLive.AgentsTest do
  @moduledoc false

  # The agent quickstart (#484 W5): a static-recipe surface — the
  # server URL, the two-step recipe, per-client snippets, the scopes
  # story, the destructive gate. The placeholder rule is the one
  # invariant worth its own assertion: every fvpat_ the page renders
  # is the ellipsis placeholder, never a minted value.

  use FluxValeWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    user = AccountsFixtures.user!()
    {:ok, conn: SessionHelpers.sign_in(conn, user)}
  end

  test "the page serves the recipe: server URL, copy, steps, both panel links", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/agents")

    assert view.module == FluxValeWeb.SettingsLive.Agents

    assert has_element?(view, "[data-testid='agents-title']", "Use with AI agents")

    # The server URL and its copy button carry the same value.
    assert has_element?(view, "[data-testid='agents-server-url']", "https://mcp.fluxvale.com")

    assert render(element(view, "[data-testid='agents-server-url-copy']")) =~
             "https://mcp.fluxvale.com"

    # Step 1 sends the visitor to the tokens panel's section anchor;
    # the scopes callout links the same place.
    assert render(element(view, "[data-testid='agents-tokens-link']")) =~
             ~s(href="/settings/access#api-tokens")

    assert render(element(view, "[data-testid='agents-scopes'] a")) =~
             ~s(href="/settings/access#api-tokens")

    # The two-step recipe renders both steps.
    assert has_element?(view, "[data-testid='agents-recipe']", "Mint a token")
    assert has_element?(view, "[data-testid='agents-recipe']", "Point your client at the server")
  end

  test "each client config is the exact snippet, copyable, placeholder-only", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings/agents")

    for client <- ["claude", "cursor", "opencode"] do
      assert has_element?(view, "[data-testid='agents-config-#{client}']")
    end

    # The snippets render verbatim in the cards' <pre> bodies and ride
    # the copy buttons — a paste-ready config, one token swap away.
    # Quotes escape as &quot; in the rendered HTML (Phoenix escapes
    # them even in text nodes); the URL carries nothing escapable.
    claude = render(element(view, "[data-testid='agents-config-claude'] pre"))
    assert claude =~ "&quot;mcpServers&quot;"
    assert claude =~ "https://mcp.fluxvale.com"
    assert has_element?(view, "[data-testid='agents-config-claude-copy']")

    opencode = render(element(view, "[data-testid='agents-config-opencode'] pre"))
    assert opencode =~ "&quot;type&quot;: &quot;remote&quot;"
    assert opencode =~ "&quot;oauth&quot;: false"

    # The invariant: every fvpat_ on the page (snippets, copy values,
    # prose) is the ellipsis placeholder — the page holds no minted
    # value to echo.
    tokens = Regex.scan(~r/fvpat_/, html)
    placeholders = Regex.scan(~r/fvpat_…/, html)
    assert tokens != []
    assert length(tokens) == length(placeholders)
  end

  test "the destructive gate and the scopes story say what the server does", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/agents")

    destructive = render(element(view, "[data-testid='agents-destructive']"))
    assert destructive =~ "Destructive actions ask first."
    assert destructive =~ "nothing changes"

    scopes = render(element(view, "[data-testid='agents-scopes']"))
    assert scopes =~ "write"
    assert scopes =~ "includes read"
    assert scopes =~ "zero-scope token"
  end

  test "the sidebar marks AI agents current on this page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/agents")

    current = render(element(view, "[data-testid='account-settings-nav-agents']"))
    assert current =~ ~s(aria-current="page")
    assert current =~ ~s(href="/settings/agents")

    for key <- ["profile", "access", "wallet"] do
      quiet = render(element(view, "[data-testid='account-settings-nav-#{key}']"))
      refute quiet =~ "aria-current", "#{key} should stay quiet"
    end
  end
end
