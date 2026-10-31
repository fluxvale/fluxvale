defmodule FluxValeWeb.PersonalAccountTest do
  @moduledoc """
  The personal org's account posture (S5 — owner smoke-test, Oct 30):
  the personal org IS an org under the hood, but presenting it as one
  is weird. Pinned here:

    * every org-scoped route for the personal slug redirects to the
      personal account's canonical surface — a personal slug must never
      render an org page, direct URLs included;
    * another user's personal slug still reads as not-found (no
      enumeration) — existing behavior, unchanged;
    * real orgs render every org surface exactly as before;
    * `/settings/access` serves the personal org's gateway panel inside
      the user-settings frame, and `/settings` carries the way there;
    * the switcher's Personal row targets `/` (pinned in
      OrgSwitcherTest) and instance show links this panel for
      personal-org instances (pinned in InstanceLive.ShowTest).
  """

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  setup %{conn: conn} do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.personal_org!(owner)

    %{owner: owner, org: org, conn: SessionHelpers.sign_in(conn, owner)}
  end

  # -- The five org-scoped routes redirect for the personal slug --------

  test "the personal org home redirects to the dashboard", %{conn: conn, org: org} do
    assert_navigated(conn, ~p"/organizations/#{org.slug}", ~p"/")
  end

  test "the personal org settings redirect to the user settings", %{conn: conn, org: org} do
    assert_navigated(conn, ~p"/organizations/#{org.slug}/settings", ~p"/settings")
  end

  test "the personal org members page redirects to the user settings", %{conn: conn, org: org} do
    assert_navigated(
      conn,
      ~p"/organizations/#{org.slug}/settings/members",
      ~p"/settings"
    )
  end

  test "the personal org billing redirects to the personal billing page", %{conn: conn, org: org} do
    assert_navigated(conn, ~p"/organizations/#{org.slug}/billing", ~p"/billing")
  end

  test "the personal org access tab redirects to /settings/access", %{conn: conn, org: org} do
    assert_navigated(
      conn,
      ~p"/organizations/#{org.slug}/settings/access",
      ~p"/settings/access"
    )
  end

  # The redirects are flash-free: nothing failed, and every landing
  # surface self-identifies. Pinned so the silence is a decision, not an
  # oversight.
  test "the redirects carry no flash", %{conn: conn, org: org} do
    assert {:error, {:live_redirect, redirect}} =
             live(conn, ~p"/organizations/#{org.slug}/settings")

    assert redirect[:to] == ~p"/settings"
    refute redirect[:flash][:error]
  end

  # -- The personal slug is not yours: not-found, unchanged -------------

  test "another user's personal slug reads as not-found — no enumeration", %{
    conn: conn
  } do
    stranger_org = AccountsFixtures.personal_org!(AccountsFixtures.user!())

    assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
             live(conn, ~p"/organizations/#{stranger_org.slug}/settings")

    assert flash["error"] == "Organization not found."
  end

  # -- Real orgs render every surface, unchanged ------------------------

  test "a real org's five surfaces render exactly as before", %{conn: conn, owner: owner} do
    # The redirect branch keys off OrgNav's personal_org_id — the
    # canonical op's pick for a two-owner user is unordered (T7). Pin the
    # premise: the pick names the personal org, so the real org's URLs
    # below are real-org URLs.
    personal = AccountsFixtures.personal_org!(owner)
    {:ok, pick} = FluxVale.Accounts.personal_org_for_user(owner.id, actor: owner)
    assert pick.id == personal.id

    org = AccountsFixtures.owned_org!(owner)

    {:ok, home_view, _html} = live(conn, ~p"/organizations/#{org.slug}")
    assert has_element?(home_view, "[data-testid='org-name']", org.name)

    {:ok, settings_view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")
    assert has_element?(settings_view, "#org-general-form")

    {:ok, members_view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/members")
    assert has_element?(members_view, "#org-members-table")

    {:ok, billing_view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")
    assert has_element?(billing_view, "[data-testid='wallet-balance']")

    {:ok, access_view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")
    assert has_element?(access_view, "[data-testid='org-settings-tabs']")
    assert has_element?(access_view, "[data-testid='access-empty']")
  end

  # -- /settings/access: the personal org's panel in the user frame -----

  test "/settings/access serves the personal org's panel, org chrome absent", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/settings/access")

    # The panel itself — the same surface the org tab serves (the empty
    # state: the personal org has no gateway yet).
    assert has_element?(view, "[data-testid='access-empty']")
    assert has_element?(view, "[data-testid='access-explainer']")
    assert has_element?(view, "#access-enable-form")

    # The user-settings frame, not the org one: back to settings, the
    # settings title, and NO org identity or org tabs.
    assert has_element?(view, "[data-testid='settings-title']", "Account settings")
    assert has_element?(view, "[data-testid='settings-access-back'][href='/settings']")
    refute has_element?(view, "[data-testid='org-settings-tabs']")
    refute has_element?(view, "[data-testid='org-name']")

    # The chrome's pill claims the personal context (no current_org).
    assert has_element?(view, "[data-testid='org-switcher-button'] span", "Personal")

    # The panel bills the personal org: the prefund hint (drained below)
    # points at /billing, never an org billing URL.
    BillingFixtures.drain_wallet!(org)

    {:ok, prefunded_view, _html} = live(conn, ~p"/settings/access")

    assert has_element?(prefunded_view, "[data-testid='access-prefund-link'][href='/billing']")
  end

  test "an anonymous visit to /settings/access redirects to sign-in" do
    assert {:error, {:redirect, %{to: to}}} =
             live(build_conn(), ~p"/settings/access")

    assert to == ~p"/sign-in"
  end

  test "a user with no personal org reads /settings/access as not-found", %{
    conn: conn,
    owner: owner
  } do
    # The seeded/legacy zero-org shape (OrgNav's stance): destroying the
    # owner membership is the sanctioned posture — nothing in the system
    # can produce it through actions.
    membership =
      Membership
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.Query.filter(user_id == ^owner.id)
      |> Ash.read_one!(authorize?: false)

    Ash.destroy!(membership, authorize?: false)

    assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
             live(conn, ~p"/settings/access")

    assert flash["error"] == "Organization not found."
  end

  # -- The settings surface carries the way in --------------------------

  test "/settings links the access panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "[data-testid='settings-access-link'][href='/settings/access']")
  end

  # Mount-time push_navigate surfaces either as a completed redirect off
  # the mounted view or as the error tuple from live/2 — both mean the
  # same navigation (the org surfaces' tests pin the same duality).
  defp assert_navigated(conn, path, to) do
    case live(conn, path) do
      {:ok, view, _html} ->
        assert_redirect(view, to)

      {:error, {:live_redirect, %{to: actual}}} ->
        assert actual == to
    end
  end
end
