defmodule FluxValeWeb.OrganizationLive.HomeTest do
  @moduledoc false

  # The org home (#276): the switcher rows' target — header, the org's
  # instances, wallet balance, member count, and the owner-only Settings
  # link. Slug-keyed mount; unknown and non-member read identically.

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    {user, conn} = SessionHelpers.user_with_session(conn)
    InstanceFixtures.local_cluster!()

    %{user: user, conn: conn, org: AccountsFixtures.personal_org!(user)}
  end

  test "a member sees the org header, member count, and the switcher naming the org", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}")

    assert has_element?(view, "[data-testid='org-name']", org.name)
    assert has_element?(view, "[data-testid='org-slug']", org.slug)
    assert has_element?(view, "[data-testid='member-count']", "1 member")

    # current_org rides the layout: the closed switcher names the org,
    # and the panel keeps its pinned Personal entry.
    assert has_element?(view, "[data-testid='org-switcher-button'] span", org.name)
    assert has_element?(view, "[data-testid='org-switcher-panel'] a", "Personal")
  end

  test "a member sees the org's instances as cards", %{conn: conn, user: user, org: org} do
    version = InstanceFixtures.app_version!()
    instance = InstanceFixtures.instance!(version, user)
    app = Ash.load!(version, :app, authorize?: false).app

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}")

    assert has_element?(
             view,
             "[data-testid='instance-row'][href='/instances/#{instance.id}']",
             instance.name
           )

    assert has_element?(view, "[data-testid='instance-row']", app.name)
    # Fresh instance: the #179 vocabulary's creation label.
    assert has_element?(view, "[data-testid='status-badge']", "Submitted")
    refute has_element?(view, "[data-testid='instances-empty']")
  end

  test "instances and the wallet are org-scoped — the URL org's, never another org's", %{
    conn: conn,
    user: user,
    org: org
  } do
    version = InstanceFixtures.app_version!()
    personal_instance = InstanceFixtures.instance!(version, user)

    # The discriminating case (the org billing view's two-org pattern):
    # the SAME actor owns a second org with its own instance, so "the
    # URL's org" and "the actor's other org" are different rows. An
    # action create can't land there (SetOrganizationFromActor pins
    # every create to the actor's personal org), so the team instance
    # rides Ash.seed! — the sanctioned escape for states actions can't
    # produce.
    team = team_org!(user)

    team_instance =
      Ash.Seed.seed!(Instance, %{
        name: "Team Inst #{System.unique_integer([:positive])}",
        slug: "team-inst-#{System.unique_integer([:positive])}",
        image: "registry.example.com/team:1",
        port: 3000,
        healthcheck_path: "/",
        status: :running,
        namespace: "fluxvale-app-team-#{System.unique_integer([:positive])}",
        deployed_at: DateTime.utc_now(),
        env_vars: %{},
        app_version_id: version.id,
        organization_id: team.id
      })

    # Distinct wallet amounts per org (the billing view's shape): drain
    # the personal JIT grant first so the arithmetic below owns itself,
    # then grant each wallet its marker.
    {:ok, personal_wallet} = Billing.ensure_wallet(org)

    {:ok, personal_balance} = Billing.balance(personal_wallet, authorize?: false)
    {:ok, _drain} = Billing.debit_wallet(personal_wallet, personal_balance * 10_000)
    {:ok, _grant} = Billing.grant_credits(personal_wallet, 11_100)

    {:ok, team_wallet} = Billing.ensure_wallet(team)
    {:ok, _grant} = Billing.grant_credits(team_wallet, 22_200)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}")

    assert has_element?(
             view,
             "[data-testid='instance-row'][href='/instances/#{personal_instance.id}']"
           )

    refute has_element?(view, "[data-testid='instance-row']", team_instance.name)

    # The personal page bills the personal wallet.
    assert has_element?(view, "[data-testid='wallet-balance']", "$111.00")
    refute has_element?(view, "[data-testid='wallet-balance']", "$222.00")

    # And the team org's page is the mirror image — its instance and its
    # wallet, never the personal org's.
    {:ok, team_view, _html} = live(conn, ~p"/organizations/#{team.slug}")

    assert has_element?(
             team_view,
             "[data-testid='instance-row'][href='/instances/#{team_instance.id}']"
           )

    refute has_element?(team_view, "[data-testid='instance-row']", personal_instance.name)

    assert has_element?(team_view, "[data-testid='wallet-balance']", "$222.00")
    refute has_element?(team_view, "[data-testid='wallet-balance']", "$111.00")
  end

  test "zero instances shows the empty state pointing at the catalog", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}")

    assert has_element?(view, "[data-testid='instances-empty']")
    assert has_element?(view, "[data-testid='instances-empty'] a[href='/apps']")
  end

  test "the wallet summary shows the org balance", %{conn: conn, org: org} do
    {:ok, wallet} = Billing.ensure_wallet(org)

    # Drain the JIT welcome grant first — the arithmetic below owns itself
    # (the billing surface's setup posture).
    {:ok, balance} = Billing.balance(wallet, authorize?: false)
    {:ok, _drain} = Billing.debit_wallet(wallet, balance * 10_000)

    {:ok, _grant} = Billing.grant_credits(wallet, 10_000)
    {:ok, _debit} = Billing.debit_wallet(wallet, 250_000)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}")

    # 10_000¢ − 25¢ = 9_975¢
    assert has_element?(view, "[data-testid='wallet-balance']", "$99.75")
  end

  test "a negative balance renders with a minus sign", %{conn: conn, org: org} do
    {:ok, wallet} = Billing.ensure_wallet(org)

    {:ok, balance} = Billing.balance(wallet, authorize?: false)
    {:ok, _drain} = Billing.debit_wallet(wallet, balance * 10_000)

    {:ok, _grant} = Billing.grant_credits(wallet, 10_000)
    # 200_000_000 µ¢ = 20_000¢ against a 10_000¢ grant — posting never
    # checks the balance, so the ledger lands at −10_000¢.
    {:ok, _debit} = Billing.debit_wallet(wallet, 200_000_000)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}")

    assert has_element?(view, "[data-testid='wallet-balance']", "-$100.00")
  end

  test "the owner sees the Settings link", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}")

    assert has_element?(view, "[data-testid='org-settings-link']", "Settings")

    assert has_element?(
             view,
             "[data-testid='org-settings-link'][href='/organizations/#{org.slug}/settings']"
           )
  end

  test "a :member does not see the Settings link", %{conn: conn, user: user} do
    team = team_org!(user)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{team.slug}")

    assert has_element?(view, "[data-testid='org-name']", team.name)
    assert has_element?(view, "[data-testid='member-count']", "2 members")
    refute has_element?(view, "[data-testid='org-settings-link']")
  end

  test "an unknown slug redirects home with a flash", %{conn: conn} do
    case live(conn, ~p"/organizations/nope") do
      {:ok, view, _html} ->
        assert_redirect(view, ~p"/")

      # push_navigate in mount surfaces as live_redirect from live/2
      {:error, {:live_redirect, %{to: to} = redirect}} ->
        assert to == ~p"/"
        assert redirect[:flash]["error"] == "Organization not found."
    end
  end

  test "a non-member reads the same not-found treatment — no enumeration signal", %{
    conn: conn
  } do
    stranger_org = AccountsFixtures.personal_org!(AccountsFixtures.user!())

    case live(conn, ~p"/organizations/#{stranger_org.slug}") do
      {:ok, view, _html} ->
        assert_redirect(view, ~p"/")

      {:error, {:live_redirect, %{to: to} = redirect}} ->
        assert to == ~p"/"
        assert redirect[:flash]["error"] == "Organization not found."
    end
  end

  # A second org with a non-owner member: both creates are system-only
  # (#119 — the create policies forbid actor-driven rows), so the
  # preconditions ride the actions with authorize?: false, mirroring
  # seeds. The :member row is the sanctioned precondition for the
  # role-distinction assertions (nothing in the system makes one yet).
  defp team_org!(member) do
    owner = AccountsFixtures.user!()

    org =
      Organization.create!(
        %{
          name: "Team Org #{System.unique_integer([:positive])}",
          slug: "team-#{System.unique_integer([:positive])}"
        },
        authorize?: false
      )

    Membership.create!(%{organization_id: org.id, user_id: owner.id, role: :owner},
      authorize?: false
    )

    Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
      authorize?: false
    )

    org
  end
end
