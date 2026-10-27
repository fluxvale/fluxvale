defmodule FluxValeWeb.OrgSwitcherTest do
  @moduledoc """
  The app chrome's org switcher (#276): rendered for a signed-in actor
  beside the logo, absent from the public and anonymous chrome. Rows are
  asserted by href — the /organizations/:slug surfaces they target are
  this lane's org pages. One org = only-personal, so the org rows hide
  and Personal is the whole panel (#284, interim until the usernames
  root fix).
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

  # The panel slice: everything from the panel marker on — the same
  # slice technique the #255 user-menu tests use.
  defp panel(html) do
    html
    |> String.split(~s(data-testid="org-switcher-panel"))
    |> List.last()
  end

  test "the app chrome renders the switcher, personal context active", %{conn: conn} do
    html = dashboard_html(conn)

    assert html =~ ~s(data-testid="org-switcher")
    assert html =~ ~s(data-testid="org-switcher-panel")
    # GitHub-style dismissal rides the shared hook on the <details>.
    assert html =~ ~s(id="org-switcher")
    assert html =~ ~s(phx-hook="DetailsDismiss")
    # The closed summary names the active context — personal by default.
    assert html =~ ~s(>Personal</span>)
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/organizations/#{org.slug}")
    assert html =~ org.name

    # One org = only-personal: the Personal row is the whole panel — an
    # org row would be the same context twice (#284).
    assert panel(html) =~ ~s(href="/")
    refute panel(html) =~ ~s(href="/organizations/)
  end

  test "two orgs: every membership gets a row, Personal pinned first", %{
    conn: conn,
    user: user,
    org: org
  } do
    team = member_org!(user)

    html = dashboard_html(conn)

    assert html =~ ~s(href="/organizations/#{team.slug}")
    assert html =~ ~s(href="/organizations/#{org.slug}")
    assert html =~ team.name

    # Personal is pinned first in the panel, ahead of every org row —
    # the same slice technique the #255 user-menu tests use.
    panel_html = panel(html)
    assert panel_html =~ "Personal"

    {personal_at, _match_len} = :binary.match(panel_html, "Personal")
    {org_at, _match_len} = :binary.match(panel_html, ~s(href="/organizations/))
    assert personal_at < org_at
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
    user: user,
    org: org
  } do
    # Row assertions need a second org — one org hides the rows (#284).
    member_org!(user)

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

    # Below lg the label is hidden, so the active org leads the pill
    # with its initial (the user_menu glyph) while the building icon
    # demotes to lg+ — the icon alone can't say which org is active.
    assert html =~ ~s(lg:hidden)
    assert html =~ ~r/>\s*A\s*<\/span>/
    assert html =~ "hidden lg:block"

    personal_html =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [%{organization: %{name: "Acme Collective", slug: "acme"}}]
      )

    # Personal keeps the building icon at every width — no initial.
    refute personal_html =~ "lg:hidden"
    refute personal_html =~ "hidden lg:block"
  end

  # The #284 row rule at the component level, off the chrome: one org
  # hides its row, two render every row — personal included.
  test "the org rows render only once a second org exists" do
    acme = %{organization: %{name: "Acme Collective", slug: "acme"}}
    oss = %{organization: %{name: "OSS Friends", slug: "oss-friends"}}

    single = render_component(&FluxValeWeb.CoreComponents.org_switcher/1, orgs: [acme])
    refute single =~ ~s(href="/organizations/acme)

    both = render_component(&FluxValeWeb.CoreComponents.org_switcher/1, orgs: [acme, oss])
    assert both =~ ~s(href="/organizations/acme")
    assert both =~ ~s(href="/organizations/oss-friends")
  end

  # The hook's unique-DOM-id contract stays caller-owned: the default
  # is "org-switcher" (the app chrome's one switcher), a caller's id
  # renders exactly once.
  test "a caller-supplied id wins over the default" do
    html =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [],
        id: "my-own-switcher"
      )

    assert html =~ ~s(id="my-own-switcher")
    # data-testid="org-switcher" also contains `id="org-switcher"` as a
    # substring, so anchor on the attribute's leading space.
    refute html =~ ~s( id="org-switcher")
  end

  test "an empty org name renders the neutral glyph, not a crash" do
    html =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [%{organization: %{name: "", slug: "empty"}}],
        current_org: %{name: "", slug: "empty"}
      )

    # The DB admits '' names; initial/1 is defensive chrome — the pill
    # shows the neutral glyph instead of raising.
    assert html =~ ~r/>\s*\?\s*<\/span>/
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
