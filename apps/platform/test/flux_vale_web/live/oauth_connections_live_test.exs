defmodule FluxValeWeb.OAuthConnectionsLiveTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    user = SessionHelpers.user!()
    {:ok, conn: SessionHelpers.sign_in(conn, user), user: user}
  end

  test "lists a live OAuth connection with its client, scopes, and resource", %{
    conn: conn,
    user: user
  } do
    client = client!(%{"client_name" => "Claude Code"})
    _tokens = tokens!(client, user, %{"scope" => "instances:read wallet:read"})

    {:ok, view, _html} = live(conn, ~p"/settings/developer")

    assert has_element?(view, "#connected-apps")
    assert has_element?(view, "[data-testid='oauth-connection-client']", "Claude Code")
    meta = render(element(view, "[data-testid='oauth-connection-meta']"))
    assert meta =~ "instances:read, wallet:read"
    assert meta =~ "mcp.fluxvale.com"
    assert meta =~ "Never used"
  end

  test "hides a disconnected family", %{conn: conn, user: user} do
    client = client!()
    _tokens = tokens!(client, user)

    {:ok, view, _html} = live(conn, ~p"/settings/developer")

    assert has_element?(view, "[data-testid='oauth-connection-row']")
    refute has_element?(view, "[data-testid='oauth-connections-empty']")
  end

  test "disconnect is armed and revokes the whole family", %{conn: conn, user: user} do
    client = client!()
    _tokens = tokens!(client, user)

    {:ok, view, _html} = live(conn, ~p"/settings/developer")
    family_id = family_id(user)

    view
    |> element("[data-testid='oauth-disconnect']")
    |> render_click()

    assert has_element?(view, "[data-testid='oauth-disconnect-confirm']")

    view
    |> element("[data-testid='oauth-disconnect-confirm-button']")
    |> render_click()

    assert has_element?(view, "[data-testid='oauth-connections-empty']")

    rows = PersonalAccessToken.list_oauth_tokens!(user.id, authorize?: false)
    assert length(rows) == 2
    assert Enum.all?(rows, & &1.revoked_at)
    assert Enum.all?(rows, &(&1.token_family_id == family_id))
  end

  test "an identity-only grant and a used connection render their copy", %{
    conn: conn,
    user: user
  } do
    client = client!(%{"client_name" => "Identity only"})
    _tokens = tokens!(client, user, %{"scope" => "offline_access"})

    {:ok, view, _html} = live(conn, ~p"/settings/developer")

    meta = render(element(view, "[data-testid='oauth-connection-meta']"))
    assert meta =~ "no scopes (identity only)"
  end

  test "a used connection shows its last-used date", %{conn: conn, user: user} do
    client = client!()
    _tokens = tokens!(client, user)

    access =
      user.id
      |> PersonalAccessToken.list_oauth_tokens!(authorize?: false)
      |> Enum.find(&(&1.kind == :oauth_access))

    {:ok, _stamped} = PersonalAccessToken.touch_last_used(access, authorize?: false)

    {:ok, view, _html} = live(conn, ~p"/settings/developer")

    meta = render(element(view, "[data-testid='oauth-connection-meta']"))
    assert meta =~ "Last used"
  end

  test "cancel disarms without revoking", %{conn: conn, user: user} do
    client = client!()
    _tokens = tokens!(client, user)

    {:ok, view, _html} = live(conn, ~p"/settings/developer")

    view
    |> element("[data-testid='oauth-disconnect']")
    |> render_click()

    assert has_element?(view, "[data-testid='oauth-disconnect-confirm']")

    view
    |> element("[data-testid='oauth-disconnect-cancel']")
    |> render_click()

    refute has_element?(view, "[data-testid='oauth-disconnect-confirm']")

    rows = PersonalAccessToken.list_oauth_tokens!(user.id, authorize?: false)
    assert Enum.all?(rows, &is_nil(&1.revoked_at))
  end

  test "a disconnect event without the arm is a no-op", %{conn: conn, user: user} do
    client = client!()
    _tokens = tokens!(client, user)
    family_id = family_id(user)

    {:ok, view, _html} = live(conn, ~p"/settings/developer")

    render_hook(view, "disconnect-oauth", %{"id" => family_id})

    assert has_element?(view, "[data-testid='oauth-connection-row']")

    rows = PersonalAccessToken.list_oauth_tokens!(user.id, authorize?: false)
    assert Enum.all?(rows, &is_nil(&1.revoked_at))
  end

  test "another user's family stays invisible", %{conn: conn, user: user} do
    other = user!()
    client = client!(%{"client_name" => "Elsewhere"})
    _tokens = tokens!(client, other)

    {:ok, view, _html} = live(conn, ~p"/settings/developer")

    refute has_element?(view, "[data-testid='oauth-connection-client']")
    assert has_element?(view, "[data-testid='oauth-connections-empty']")
    assert is_nil(family_id(user))
  end

  defp family_id(user) do
    tokens = PersonalAccessToken.list_oauth_tokens!(user.id, authorize?: false)

    case List.first(tokens) do
      nil -> nil
      token -> token.token_family_id
    end
  end
end
