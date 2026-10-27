defmodule FluxValeWeb.OrganizationLive.MembersTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  setup %{conn: conn} do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.personal_org!(owner)

    {:ok, conn: SessionHelpers.sign_in(conn, owner), owner: owner, org: org}
  end

  test "the owner sees the roster — owner row first, then members joined-asc", %{
    conn: conn,
    owner: owner,
    org: org
  } do
    member_a = AccountsFixtures.user!()
    member_b = AccountsFixtures.user!()
    membership_a = seed_member!(org, member_a)
    membership_b = seed_member!(org, member_b)
    owner_membership = owner_membership!(org, owner)

    # Ash.CiString — text filters and splits want plain binaries.
    owner_email = to_string(owner.email)
    member_a_email = to_string(member_a.email)
    member_b_email = to_string(member_b.email)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/members")

    # The owner row: email, Owner label, joined date.
    owner_row = "#member-row-#{owner_membership.id}"

    assert has_element?(view, owner_row, owner_email)
    assert has_element?(view, owner_row, "Owner")

    assert has_element?(
             view,
             owner_row,
             Calendar.strftime(owner_membership.created_at, "%b %d, %Y")
           )

    # Seeded members read as "Member".
    assert has_element?(view, "#member-row-#{membership_a.id}", member_a_email)
    assert has_element?(view, "#member-row-#{membership_a.id}", "Member")
    assert has_element?(view, "#member-row-#{membership_b.id}", "Member")

    # Row order is the sort: owners first, then joined-asc. Scoped to the
    # table — the chrome's user menu prints the owner's email above <main>,
    # so a whole-page scan would pass whatever the rows did.
    table_html = render(element(view, "#org-members-table"))

    [before_b | _after_b] = String.split(table_html, member_b_email)
    assert before_b =~ member_a_email

    [before_a | _after_a] = String.split(before_b, member_a_email)
    assert before_a =~ owner_email

    # The domain's stance on invitations — one copy line, no promises.
    assert has_element?(
             view,
             "[data-testid='members-invite-note']",
             "Invitations arrive with team features."
           )
  end

  test "the tab nav renders General (linking back) and Members (active)", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/members")

    assert has_element?(view, "[data-testid='org-settings-tab-members']", "Members")

    general_tab = render(element(view, "[data-testid='org-settings-tab-general']"))
    assert general_tab =~ ~s(href="/organizations/#{org.slug}/settings")

    # Only the active tab carries aria-current — an inactive tab must not.
    refute general_tab =~ "aria-current"

    members_tab = render(element(view, "[data-testid='org-settings-tab-members']"))
    assert members_tab =~ ~s(aria-current="page")
  end

  test "the chrome's switcher names THIS org — current_org passes through", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/members")

    assert has_element?(view, "[data-testid='org-switcher-button'] span", org.name)
  end

  test "a non-owner member is gated away from the members tab", %{conn: conn, org: org} do
    member = AccountsFixtures.user!()

    seed_member!(org, member)

    member_conn = SessionHelpers.sign_in(conn, member)

    assert {:error, {:live_redirect, %{flash: flash, to: "/"}}} =
             live(member_conn, ~p"/organizations/#{org.slug}/settings/members")

    assert flash["error"] == "Only organization owners can access settings."
  end

  test "an unknown slug reads as not-here — flash + redirect home", %{conn: conn} do
    assert {:error, {:live_redirect, %{flash: flash, to: "/"}}} =
             live(conn, ~p"/organizations/no-such-org/settings/members")

    assert flash["error"] == "Organization not found."
  end

  # Sanctioned precondition: nothing in the system creates :member rows
  # yet, so the row rides the action with authorize?: false.
  defp seed_member!(org, user) do
    Membership.create!(%{organization_id: org.id, user_id: user.id, role: :member},
      authorize?: false
    )
  end

  # Precondition read with authorize?: false — the gate under test is the
  # mount's, not the read policy's; mirrors the fixtures' bootstrap
  # posture.
  defp owner_membership!(org, owner) do
    matches =
      Membership
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.Query.filter(user_id == ^owner.id and organization_id == ^org.id)
      |> Ash.read!()

    assert [%Membership{} = owner_membership] = matches
    owner_membership
  end
end
