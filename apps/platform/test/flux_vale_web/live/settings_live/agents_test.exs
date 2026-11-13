defmodule FluxValeWeb.SettingsLive.AgentsTest do
  @moduledoc false

  # The agent quickstart (#484 W5): a static-recipe surface — the
  # server URL, the two-step recipe, per-client snippets, the scopes
  # story, the destructive gate. The placeholder rule is the one
  # invariant worth its own assertion: every fvpat_ the page renders
  # is the ellipsis placeholder, never a minted value.

  use FluxValeWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  setup %{conn: conn} do
    user = AccountsFixtures.user!()
    {:ok, conn: SessionHelpers.sign_in(conn, user), user: user}
  end

  test "the page serves the recipe: server URL, copy, steps, both panel links", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/agents")

    assert view.module == FluxValeWeb.SettingsLive.Agents

    assert has_element?(view, "[data-testid='agents-title']", "Use with AI agents")

    # #765: the one-prompt handoff is one click from the quickstart.
    assert has_element?(view, "[data-testid='agents-first-run-link'][href='/agent']")

    # The server URL and its copy button carry the same value — the
    # protocol path, not the bare origin (main.rs nests at /mcp).
    assert has_element?(view, "[data-testid='agents-server-url']", "https://mcp.fluxvale.com/mcp")

    assert render(element(view, "[data-testid='agents-server-url-copy']")) =~
             "https://mcp.fluxvale.com/mcp"

    # Step 1 sends the visitor to the tokens panel's section anchor
    # (#638: the panel lives on the developer settings page now); the
    # scopes callout links the same place.
    assert render(element(view, "[data-testid='agents-tokens-link']")) =~
             ~s(href="/settings/developer#api-tokens")

    assert render(element(view, "[data-testid='agents-scopes'] a")) =~
             ~s(href="/settings/developer#api-tokens")

    # The two-step recipe renders both steps.
    assert has_element?(view, "[data-testid='agents-recipe']", "Mint a token")

    assert has_element?(
             view,
             "[data-testid='agents-recipe']",
             "Point your client at the server"
           )

    # The DNS records ride the beta rollout — the note under the URL
    # stays evergreen (no dates, no promises).
    assert render(element(view, "[data-testid='agents-server-dns']")) =~
             "rolling out"

    # Step 1 names the four MCP scope domains (the panel's scope
    # catalog spans more than the server serves).
    recipe = render(element(view, "[data-testid='agents-recipe']"))
    assert recipe =~ "catalog, instances, backups, wallet"
    assert recipe =~ "unlock MCP tools today"
  end

  test "each client config is the exact snippet, copyable, placeholder-only", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings/agents")

    for client <- ["claude", "cursor", "opencode"] do
      assert has_element?(view, "[data-testid='agents-config-#{client}']")
    end

    # Claude Desktop is the connector FORM (no config file — that
    # file is the local-stdio mechanism); Cursor and opencode are
    # verbatim snippets in <pre> bodies riding copy buttons. Quotes
    # escape as &quot; in the rendered HTML (Phoenix escapes them
    # even in text nodes); the URL carries nothing escapable.
    claude = render(element(view, "[data-testid='agents-config-claude']"))
    assert claude =~ "Add custom connector"
    assert claude =~ "https://mcp.fluxvale.com/mcp"
    # The auth choice is explicit: No sign-in, not OAuth — the header
    # below is the auth (CodeRabbit GNsF).
    assert claude =~ "No sign-in"
    assert claude =~ "Bearer fvpat_…"

    assert render(element(view, "[data-testid='agents-config-claude-copy']")) =~
             "Authorization: Bearer fvpat_…"

    # The file snippets never carry the token — each reads it from
    # FLUXVALE_PAT through its client's env syntax (CodeRabbit GNsI):
    # Cursor ${env:…}, opencode {env:…}.
    assert render(element(view, "[data-testid='agents-clients-secret']")) =~
             "Never commit a token"

    cursor = render(element(view, "[data-testid='agents-config-cursor'] pre"))
    assert cursor =~ "&quot;mcpServers&quot;"
    assert cursor =~ "https://mcp.fluxvale.com/mcp"
    assert cursor =~ "Bearer ${env:FLUXVALE_PAT}"
    assert has_element?(view, "[data-testid='agents-config-cursor-copy']")

    # opencode rides the V2 shape (the card says so — v1 uses a
    # different layout, upgrade rather than hand-edit): nested under
    # mcp.servers with protocol auto (legacy caps at 2025-11-25; the
    # destructive confirmations need the 2026-07-28 stateless
    # revision).
    opencode_card = render(element(view, "[data-testid='agents-config-opencode']"))
    assert opencode_card =~ "Requires opencode v2"

    opencode = render(element(view, "[data-testid='agents-config-opencode'] pre"))
    assert opencode =~ "&quot;servers&quot;"
    assert opencode =~ "&quot;protocol&quot;: &quot;auto&quot;"
    assert opencode =~ "&quot;type&quot;: &quot;remote&quot;"
    assert opencode =~ "&quot;oauth&quot;: false"
    assert opencode =~ "Bearer {env:FLUXVALE_PAT}"

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
    # Multi-domain tools: the callout says the union is the mint and
    # points at the docs table for the exact sets (CodeRabbit GNsM).
    assert scopes =~ "two domains"
    assert scopes =~ "docs/mcp.md"
  end

  test "the sidebar marks AI agents current on this page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/agents")

    current = render(element(view, "[data-testid='account-settings-nav-agents']"))
    assert current =~ ~s(aria-current="page")
    assert current =~ ~s(href="/settings/agents")

    for key <- ["profile", "access", "developer", "wallet"] do
      quiet = render(element(view, "[data-testid='account-settings-nav-#{key}']"))
      refute quiet =~ "aria-current", "#{key} should stay quiet"
    end
  end

  test "with no personal org, the mint link still serves — the tokens page is actor-scoped", %{
    conn: conn,
    user: user
  } do
    # The seeded/legacy no-org shape (PersonalAccountTest's teardown).
    # #638 moved the tokens panel to the actor-scoped developer page,
    # so the quickstart's mint link is no dead end for this actor.
    membership =
      Membership
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.Query.filter(user_id == ^user.id and role == :owner)
      |> Ash.read_one!(authorize?: false)

    Ash.destroy!(membership, authorize?: false)

    {:ok, view, _html} = live(conn, ~p"/settings/agents")

    assert render(element(view, "[data-testid='agents-tokens-link']")) =~
             ~s(href="/settings/developer#api-tokens")

    # The recipe itself still serves — static content, nothing gated.
    assert has_element?(view, "[data-testid='agents-server-url']")
    assert has_element?(view, "[data-testid='agents-config-claude-steps']")
  end
end
