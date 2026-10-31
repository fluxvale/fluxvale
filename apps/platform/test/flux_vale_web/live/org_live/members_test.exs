defmodule FluxValeWeb.OrganizationLive.MembersTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Identity
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.AuthCodeHelpers
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  setup %{conn: conn} do
    owner = AccountsFixtures.user!()
    # S5: the personal org has no members page (one member — the user;
    # its URL redirects) — the roster tests ride a real org.
    org = AccountsFixtures.owned_org!(owner)

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

    # Tenant pin: the owner ALSO belongs to a second org — as a plain
    # member — whose other member must never surface here. The actor spans
    # two orgs on purpose: the read policy scopes to the actor's orgs, the
    # organization_id filter to this one, and only an actor on both can
    # see the difference.
    other_org = AccountsFixtures.personal_org!(AccountsFixtures.user!())
    seed_member!(other_org, owner)
    other_member = AccountsFixtures.user!()
    other_membership = seed_member!(other_org, other_member)

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

    # The other org's member is not on this roster — no row, and the email
    # appears nowhere on the page.
    refute has_element?(view, "#member-row-#{other_membership.id}")
    refute render(view) =~ to_string(other_member.email)

    # Row order is the sort: owners first, then joined-asc — the exact
    # rendered sequence.
    assert_row_order(view, [owner_email, member_a_email, member_b_email])

    # The Joined column is labelled Joined and fed by created_at.
    assert has_element?(view, "th", "Joined")

    # The domain's stance on invitations — one copy line, no promises.
    assert has_element?(
             view,
             "[data-testid='members-invite-note']",
             "Invitations arrive with team features."
           )
  end

  test "roster order is chronological across a month boundary — not day-of-month", %{
    conn: conn,
    owner: owner,
    org: org
  } do
    feb = AccountsFixtures.user!()
    jan = AccountsFixtures.user!()

    # Backdated joins are a state the create action cannot produce
    # (created_at is a write-time timestamp) — seed! territory. February
    # is INSERTED FIRST so plain query order contradicts the asserted
    # order: a sort that never reaches the date key cannot pass.
    feb_membership = seed_member_at!(org, feb, ~U[2024-02-01 09:00:00Z])
    jan_membership = seed_member_at!(org, jan, ~U[2024-01-31 09:00:00Z])
    owner_membership!(org, owner)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/members")

    # Owners first even though the owner joined last (2026 vs 2024); then
    # joined-asc. Jan 31 must precede Feb 1 — raw DateTime term comparison
    # sorts day-of-month first and puts February on top.
    assert_row_order(view, [
      to_string(owner.email),
      to_string(jan.email),
      to_string(feb.email)
    ])

    # The Joined cell reads created_at — on a backdated row that is two
    # years before updated_at, so the column's source is observable.
    assert has_element?(
             view,
             "#member-row-#{jan_membership.id}",
             Calendar.strftime(jan_membership.created_at, "%b %d, %Y")
           )
  end

  test "same-instant joins break the tie by id, not by read order", %{
    conn: conn,
    owner: owner,
    org: org
  } do
    same_instant = ~U[2024-03-01 09:00:00Z]

    # Users created in a deliberate order: the first-created user (smaller
    # user uuid — the order the org-user index returns) carries the LARGER
    # membership id and is inserted first. Same created_at on both rows.
    # All three are states the create action cannot produce (write-time
    # timestamp, generated uuid_v7 ids) — seed! territory. Every candidate
    # read order (user-uuid index, insertion) contradicts the asserted
    # sequence, so only the id tiebreak can produce it.
    first_created = AccountsFixtures.user!()
    second_created = AccountsFixtures.user!()

    seed_member_at!(org, first_created, same_instant, "00000000-0000-7000-8000-000000000002")

    seed_member_at!(org, second_created, same_instant, "00000000-0000-7000-8000-000000000001")

    owner_membership!(org, owner)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/members")

    assert_row_order(view, [
      to_string(owner.email),
      to_string(second_created.email),
      to_string(first_created.email)
    ])
  end

  # #285 T4 teeth: the roster column shows the member's PRIMARY address —
  # after the REAL operations promote a verified secondary, the demoted
  # signup address must vanish from the member's row. Reverting the
  # user_email calculation to `user.email` fails this test.
  test "a member's row shows their promoted primary, not the frozen mirror", %{
    conn: conn,
    org: org
  } do
    member = AccountsFixtures.user!()
    membership = seed_member!(org, member)

    mirror = to_string(member.email)
    promoted = "roster-promoted-#{System.unique_integer([:positive])}@fluxvale.test"

    assert {:ok, row} = Identity.add_email(member, promoted)
    code = AuthCodeHelpers.mailbox_code()
    assert {:ok, _verified} = Identity.verify_email(member, row.id, code)
    assert {:ok, _promoted} = Identity.set_primary_email(member, row.id)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/members")

    member_row = "#member-row-#{membership.id}"
    assert has_element?(view, member_row, promoted)
    refute render(view) =~ mirror
  end

  # The nil-primary arm (old-pod straggler with no user_emails row):
  # showing nothing is wrong — the frozen mirror is the honest fallback
  # (see User.primary_email). Seeded shape: no session rides the row.
  test "a member with no verified primary row shows the mirror address", %{
    conn: conn,
    org: org
  } do
    int = System.unique_integer([:positive])

    straggler = Ash.Seed.seed!(FluxVale.Identity.User, %{email: "straggler-#{int}@fluxvale.test"})
    membership = seed_member!(org, straggler)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/members")

    assert has_element?(view, "#member-row-#{membership.id}", "straggler-#{int}@fluxvale.test")
  end

  test "the tab nav renders General (linking back) and Members (active)", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/members")

    assert has_element?(view, "[data-testid='org-settings-tab-members']", "Members")

    general_tab = render(element(view, "[data-testid='org-settings-tab-general']"))
    assert general_tab =~ ~s(href="/organizations/#{org.slug}/settings")

    # Only the active tab carries aria-current and the active styling.
    refute general_tab =~ "aria-current"
    refute general_tab =~ "border-primary"

    members_tab = render(element(view, "[data-testid='org-settings-tab-members']"))
    assert members_tab =~ ~s(aria-current="page")
    assert members_tab =~ "border-primary"
  end

  test "the page carries the shared org header, and the switcher names THIS org", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/members")

    # The shared identity block — the page keeps its <h1> when switching
    # tabs, same frame as the General tab.
    assert has_element?(view, "[data-testid='org-name']", org.name)
    assert has_element?(view, "[data-testid='org-slug']", org.slug)
    assert has_element?(view, "h1", org.name)

    # The back link leaves settings for the dashboard.
    assert render(element(view, "[data-testid='org-back']")) =~ ~s(href="/")

    # The chrome's switcher names THIS org — current_org passes through.
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

  test "a stranger to a real org reads as not-here — same as a typo slug", %{conn: conn, org: org} do
    stranger_conn = SessionHelpers.sign_in(conn, AccountsFixtures.user!())

    assert {:error, {:live_redirect, %{flash: flash, to: "/"}}} =
             live(stranger_conn, ~p"/organizations/#{org.slug}/settings/members")

    # Identical answer to the unknown-slug arm — membership is not
    # disclosed to non-members.
    assert flash["error"] == "Organization not found."
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

  # Backdated joins and explicit ids are states actions cannot produce —
  # created_at is a write-time timestamp and uuid_v7 ids are generated —
  # so they ride Ash.Seed (the sanctioned escape for such rows). Each
  # caller comments which state it needs.
  defp seed_member_at!(org, user, created_at, id \\ nil) do
    base = %{organization_id: org.id, user_id: user.id, role: :member, created_at: created_at}
    attrs = if id, do: Map.put(base, :id, id), else: base

    Ash.Seed.seed!(Membership, attrs)
  end

  # The rendered row order is exactly this email sequence — each email
  # matched once, offsets strictly increasing. Scoped to the table: the
  # chrome's user menu prints the owner's email above <main>, so a
  # whole-page scan would pass whatever the rows did.
  defp assert_row_order(view, emails) do
    table_html = render(element(view, "#org-members-table"))

    offsets =
      Enum.map(emails, fn email ->
        assert {offset, _length} = :binary.match(table_html, email)
        offset
      end)

    assert offsets == Enum.sort(offsets)
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
