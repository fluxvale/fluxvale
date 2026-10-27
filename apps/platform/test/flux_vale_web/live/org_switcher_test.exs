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

  test "the public chrome carries no switcher", %{conn: conn} do
    conn = get(conn, ~p"/about")
    html = html_response(conn, 200)

    refute html =~ ~s(data-testid="org-switcher")
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
