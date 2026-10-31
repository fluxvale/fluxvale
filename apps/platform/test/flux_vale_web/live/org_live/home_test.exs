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

    # S5: the personal org no longer renders org pages (its URLs
    # redirect to the account surfaces) — the org-home tests ride a real
    # org the actor owns.
    %{user: user, conn: conn, org: AccountsFixtures.owned_org!(user)}
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
    # and the panel's one row is the personal org, labeled Personal —
    # username (#285 T6).
    assert has_element?(view, "[data-testid='org-switcher-button'] span", org.name)
    assert has_element?(view, "[data-testid='org-switcher-panel'] a", "Personal")
  end

  test "a member sees the org's instances as cards", %{conn: conn, org: org} do
    version = InstanceFixtures.app_version!()
    instance = org_instance!(org, version, "Org Inst")
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
    org_instance = org_instance!(org, version, "Org A Inst")

    # The discriminating case (the org billing view's two-org pattern):
    # the SAME actor owns a second org with its own instance, so "the
    # URL's org" and "the actor's other org" are different rows. An
    # action create can't land there (SetOrganizationFromActor pins
    # every create to the actor's personal org), so both org instances
    # ride Ash.seed! — the sanctioned escape for states actions can't
    # produce.
    other = team_org!(user)
    other_instance = org_instance!(other, version, "Org B Inst")

    # Distinct wallet amounts per org (the billing view's shape) — the
    # fixture orgs have no JIT grant, so each wallet starts at zero.
    {:ok, org_wallet} = Billing.ensure_wallet(org)
    {:ok, _grant} = Billing.grant_credits(org_wallet, 11_100)

    {:ok, other_wallet} = Billing.ensure_wallet(other)
    {:ok, _grant} = Billing.grant_credits(other_wallet, 22_200)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}")

    assert has_element?(
             view,
             "[data-testid='instance-row'][href='/instances/#{org_instance.id}']"
           )

    refute has_element?(view, "[data-testid='instance-row']", other_instance.name)

    # The org page bills the URL org's wallet.
    assert has_element?(view, "[data-testid='wallet-balance']", "$111.00")
    refute has_element?(view, "[data-testid='wallet-balance']", "$222.00")

    # And the other org's page is the mirror image — its instance and
    # its wallet, never this org's.
    {:ok, other_view, _html} = live(conn, ~p"/organizations/#{other.slug}")

    assert has_element?(
             other_view,
             "[data-testid='instance-row'][href='/instances/#{other_instance.id}']"
           )

    refute has_element?(other_view, "[data-testid='instance-row']", org_instance.name)

    assert has_element?(other_view, "[data-testid='wallet-balance']", "$222.00")
    refute has_element?(other_view, "[data-testid='wallet-balance']", "$111.00")
  end

  test "zero instances shows the empty state pointing at the catalog", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}")

    assert has_element?(view, "[data-testid='instances-empty']")
    assert has_element?(view, "[data-testid='instances-empty'] a[href='/apps']")
  end

  test "the wallet summary shows the org balance", %{conn: conn, org: org} do
    {:ok, wallet} = Billing.ensure_wallet(org)

    # The fixture org has no JIT grant, so the balance starts at exactly
    # zero and the arithmetic below owns itself.
    {:ok, _grant} = Billing.grant_credits(wallet, 10_000)
    {:ok, _debit} = Billing.debit_wallet(wallet, 250_000)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}")

    # 10_000¢ − 25¢ = 9_975¢
    assert has_element?(view, "[data-testid='wallet-balance']", "$99.75")
  end

  test "a negative balance renders with a minus sign", %{conn: conn, org: org} do
    {:ok, wallet} = Billing.ensure_wallet(org)

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

  # An instance ON a given org. The create action pins every instance to
  # the actor's personal org (SetOrganizationFromActor), so an org-paged
  # instance is a state actions cannot produce — Ash.seed! is the
  # sanctioned escape, the same posture this file's team-instance shape
  # has always used.
  defp org_instance!(org, version, name, status \\ :pending) do
    Ash.Seed.seed!(Instance, %{
      name: "#{name} #{System.unique_integer([:positive])}",
      slug: "inst-#{System.unique_integer([:positive])}",
      image: "registry.example.com/org:1",
      port: 3000,
      healthcheck_path: "/",
      status: status,
      namespace: "fluxvale-app-org-#{System.unique_integer([:positive])}",
      deployed_at: DateTime.utc_now(),
      env_vars: %{},
      app_version_id: version.id,
      organization_id: org.id
    })
  end
end
