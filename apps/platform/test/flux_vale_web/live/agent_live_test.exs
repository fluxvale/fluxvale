defmodule FluxValeWeb.AgentLiveTest do
  @moduledoc false

  # The post-registration handoff (#765): the prompt, the four client
  # snippets, the spend rule, and the dismissal — all rendered from
  # FluxValeWeb.AgentPrompt. The page never holds a minted token.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.AgentPrompt

  setup %{conn: conn} do
    user = AccountsFixtures.user!()
    org = AccountsFixtures.personal_org!(user)

    {:ok, conn: SessionHelpers.sign_in(conn, user), user: user, org: org}
  end

  test "a signed-in user gets the generated prompt for their org", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/agent")

    assert view.module == FluxValeWeb.AgentLive

    assert has_element?(view, "h1", "Finish setup with your agent")
    assert has_element?(view, "[data-testid='agent-prompt']", org.name)
    assert has_element?(view, "[data-testid='agent-prompt']", org.slug)
    assert has_element?(view, "[data-testid='agent-prompt']", AgentPrompt.mcp_url())
    assert has_element?(view, "[data-testid='agent-prompt']", FluxValeWeb.Endpoint.url())

    # The copy button carries the exact prompt the page renders.
    prompt =
      view
      |> element("[data-testid='agent-prompt']")
      |> render()

    assert prompt =~ "Mint a scoped token"
    assert prompt =~ "instances_deploy"
    assert prompt =~ "instances_configure"
  end

  test "the four client snippets render with copy buttons", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")

    for client <- ["claude-code", "cursor", "vscode", "generic"] do
      assert has_element?(view, "[data-testid='agent-client-#{client}']")
      assert has_element?(view, "[data-testid='agent-client-#{client}-copy']")
      assert has_element?(view, "[data-testid='agent-client-#{client}-code']")
    end

    claude = render(element(view, "[data-testid='agent-client-claude-code-code']"))
    assert claude =~ "claude mcp add --transport http fluxvale"
    assert claude =~ "FLUXVALE_PAT"

    cursor = render(element(view, "[data-testid='agent-client-cursor-code']"))
    assert cursor =~ "cursor://anysphere.cursor-deeplink/mcp/install"

    vscode = render(element(view, "[data-testid='agent-client-vscode-code']"))
    assert vscode =~ "servers"

    generic = render(element(view, "[data-testid='agent-client-generic-code']"))
    assert generic =~ "mcpServers"
  end

  test "the panel carries the what-it-will-do list, the spend rule, and the dismissal", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/agent")

    assert has_element?(view, "[data-testid='agent-what-it-will-do']", "Check your wallet")
    assert has_element?(view, "[data-testid='agent-what-it-will-do']", "Confirm the spend")
    assert has_element?(view, "[data-testid='agent-spend-rule']", "It asks before it spends")

    assert has_element?(view, "[data-testid='agent-dismiss'][href='/']", "I'll explore myself")
  end

  test "the OAuth mode drops the token sentence and the snippet headers", %{conn: conn} do
    previous = Application.get_env(:flux_vale, :mcp_auth_mode)
    on_exit(fn -> Application.put_env(:flux_vale, :mcp_auth_mode, previous) end)
    Application.put_env(:flux_vale, :mcp_auth_mode, :oauth)

    {:ok, view, html} = live(conn, ~p"/agent")

    refute html =~ "FLUXVALE_PAT"
    assert has_element?(view, "[data-testid='agent-snippet-note']", "browser sign-in")
    assert html =~ "claude mcp add --transport http fluxvale"
    refute html =~ "--header"
  end

  test "no token value ever renders — only the env-var name", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/agent")

    refute html =~ "fvpat_"
    assert html =~ "FLUXVALE_PAT"
  end

  test "a legacy account with no org renders the placeholder prompt", %{conn: _conn} do
    user =
      Ash.Seed.seed!(FluxVale.Identity.User, %{
        username: "no-org-agent-#{System.unique_integer([:positive])}",
        platform_role: :user
      })

    AccountsFixtures.attach_primary_email!(
      user,
      "no-org-agent-#{System.unique_integer([:positive])}@example.com"
    )

    conn = SessionHelpers.sign_in(build_conn(), user)
    {:ok, view, _html} = live(conn, ~p"/agent")

    assert has_element?(view, "[data-testid='agent-prompt']", "your organization")
    assert has_element?(view, "[data-testid='agent-prompt']", "<your-org-slug>")
  end

  test "an anonymous visitor is sent to sign-in" do
    assert {:error, {:redirect, %{to: to}}} = live(build_conn(), ~p"/agent")
    assert to =~ "/sign-in"
  end
end
