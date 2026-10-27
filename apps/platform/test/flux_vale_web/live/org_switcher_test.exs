defmodule FluxValeWeb.OrgSwitcherTest do
  @moduledoc """
  The app chrome's org switcher (#276): rendered for a signed-in actor
  beside the logo, absent from the public and anonymous chrome. Rows are
  asserted by href — the /organizations/:slug surfaces are a sibling
  ticket in this lane.
  """

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  setup %{conn: conn} do
    {user, conn} = SessionHelpers.user_with_session(conn)
    %{user: user, conn: conn, org: AccountsFixtures.personal_org!(user)}
  end

  defp dashboard_html(conn) do
    conn
    |> get(~p"/")
    |> html_response(200)
  end

  test "the app chrome renders the switcher, personal context active", %{conn: conn, org: org} do
    html = dashboard_html(conn)

    assert html =~ ~s(data-testid="org-switcher")
    assert html =~ ~s(data-testid="org-switcher-panel")
    # The closed summary names the active context — personal by default.
    assert html =~ ~s(>Personal</span>)
    # hrefs, not navigation targets: the org route lands in a sibling ticket.
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/organizations/#{org.slug}")
    assert html =~ org.name

    # Personal is pinned first in the panel, ahead of every org row —
    # the same slice technique the #255 user-menu tests use.
    panel =
      html
      |> String.split(~s(data-testid="org-switcher-panel"))
      |> List.last()

    assert panel =~ "Personal"

    {personal_at, _match_len} = :binary.match(panel, "Personal")
    {org_at, _match_len} = :binary.match(panel, ~s(href="/organizations/))
    assert personal_at < org_at
  end

  test "every membership gets a row — a second org rides along", %{conn: conn, user: user} do
    team = member_org!(user)

    html = dashboard_html(conn)

    assert html =~ ~s(href="/organizations/#{team.slug}")
    assert html =~ team.name
  end

  test "zero orgs keeps the switcher with its Personal entry alone", %{
    conn: conn,
    user: user,
    org: org
  } do
    membership = membership!(user, org)

    # System posture — the destroy policy is system-only (#119); the
    # empty shape is unreachable through actions.
    Ash.destroy!(membership, authorize?: false)

    html = dashboard_html(conn)

    assert html =~ ~s(data-testid="org-switcher")
    assert html =~ ~s(>Personal</span>)
    refute html =~ ~s(href="/organizations/)
  end

  # Layouts.public's real consumers — the #164 SEO surfaces render the
  # session-aware chrome, so a signed-in visitor proves the `apps`
  # guard, not a standalone landing template that never calls chrome.
  test "the public chrome carries no switcher, even signed in", %{conn: conn} do
    conn = get(conn, ~p"/catalog")
    html = html_response(conn, 200)

    refute html =~ ~s(data-testid="org-switcher")
    # Sanity: this really is the session-aware public chrome.
    assert html =~ ~s(data-testid="user-menu")
  end

  test "the refund policy's public chrome carries no switcher", %{conn: conn} do
    conn = get(conn, ~p"/policies/refund")
    html = html_response(conn, 200)

    refute html =~ ~s(data-testid="org-switcher")
  end

  # The live_session wiring is half of the hook's contract — every
  # assertion above rides `/`, whose view declares the pair itself.
  test "the authenticated live_session wires the hook — the switcher rides /apps", %{
    conn: conn,
    org: org
  } do
    conn = get(conn, ~p"/apps")
    html = html_response(conn, 200)

    assert html =~ ~s(data-testid="org-switcher")
    assert html =~ ~s(href="/organizations/#{org.slug}")
  end

  test "the anonymous app chrome (sign-in) carries no switcher", %{conn: conn} do
    conn = get(conn, ~p"/sign-in")
    html = html_response(conn, 200)

    refute html =~ ~s(data-testid="org-switcher")
  end

  test "current_org names the active context in the closed summary" do
    html =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [%{organization: %{name: "Acme Collective", slug: "acme"}}],
        current_org: %{name: "Acme Collective", slug: "acme"}
      )

    assert html =~ ~s(>Acme Collective</span>)
    assert html =~ ~s(href="/organizations/acme")
  end

  # Both creates are system-only (#119) — the bootstrap posture,
  # mirroring seeds.
  defp member_org!(user) do
    org =
      Organization.create!(
        %{name: "Team Org", slug: "team-#{System.unique_integer([:positive])}"},
        authorize?: false
      )

    Membership.create!(%{organization_id: org.id, user_id: user.id}, authorize?: false)

    org
  end

  defp membership!(user, org) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(user_id == ^user.id and organization_id == ^org.id)
    |> Ash.read_one!(authorize?: false)
  end
end
