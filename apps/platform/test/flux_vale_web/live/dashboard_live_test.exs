defmodule FluxValeWeb.DashboardLiveTest do
  @moduledoc false

  # The signed-in root (#205): balance + runway metric cards, the
  # instances overview with live status, fresh-account empty states,
  # and the broadcast-driven re-stream. Mounted through live_render —
  # the same entry PageController uses for `/`.

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Billing
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  # Micro-cents per cent — Billing's debit/credit unit (the wallet
  # shape tests below trade in it).
  @micro_per_cent 10_000

  setup %{conn: conn} do
    {user, conn} = SessionHelpers.user_with_session(conn)
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()
    %{user: user, conn: conn, version: version}
  end

  # The controller's exact entry: GET / — the session-aware root
  # resolves the actor, live_renders this view, and LiveViewTest's
  # proxy adopts the rendered child.
  defp dashboard(conn), do: live(conn, ~p"/")

  test "a fresh account gets the empty state, welcome hint, and quick actions", %{
    conn: conn
  } do
    {:ok, view, html} = dashboard(conn)

    assert has_element?(view, "h1", "Dashboard")
    assert has_element?(view, "[data-testid='dashboard-balance']")
    # No instances → no burn → the infinite-runway shape.
    assert has_element?(view, "[data-testid='dashboard-runway']", "No active burn")

    assert has_element?(
             view,
             "[data-testid='dashboard-runway']",
             "Your first deploy starts the meter."
           )

    assert html =~ "No instances yet"
    assert html =~ "in credits — your first deploy is on us."
    # Quick actions (#205): deploy from catalog, top up.
    assert has_element?(view, "a[href='/apps']", "Deploy an app")
    assert has_element?(view, "a[href='/billing/topup']", "Add credits")
    assert has_element?(view, "a[href='/instances']", "View all")
  end

  test "lists the actor's instances — quiet on running, friendly copy on noisy", %{
    conn: conn,
    user: user,
    version: version
  } do
    mine = InstanceFixtures.instance!(version, user)
    running = InstanceFixtures.walk_to!(mine, :running)

    deploying = InstanceFixtures.instance!(version, user)
    InstanceFixtures.walk_to!(deploying, :deploying)

    theirs = SessionHelpers.user!()
    their_row = InstanceFixtures.instance!(version, theirs)

    {:ok, view, html} = dashboard(conn)

    assert has_element?(view, "#instances-#{running.id}", running.name)
    # Running is quiet (badge only)…
    refute html =~ "Your app is up and running."
    # …a deploying row earns its copy.
    assert has_element?(view, "#instances-#{deploying.id}", "Provisioning")
    assert has_element?(view, "[data-testid='instance-status-message']", "Setting up your app.")
    # Owner-scoped: the other actor's row never appears.
    refute has_element?(view, "#instances-#{their_row.id}")
  end

  test "a running priced instance burns — finite runway with the burn hint", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = InstanceFixtures.instance!(version, user)
    InstanceFixtures.walk_to!(instance, :running)

    {:ok, view, _html} = dashboard(conn)

    # Welcome balance $3 at the fixture's $1/mo size → ≈ 3 months.
    assert has_element?(view, "[data-testid='dashboard-runway']", "≈ 3 months")

    assert has_element?(
             view,
             "[data-testid='dashboard-runway']",
             ~r/at \$[\d.]+\/mo current burn/
           )
  end

  # Zero burn isn't always a fresh account: a pending row accrues
  # nothing, and the hint must not promise a "first deploy".
  test "zero burn with instances reads neutral, not onboarding", %{
    conn: conn,
    user: user,
    version: version
  } do
    InstanceFixtures.instance!(version, user)

    {:ok, view, _html} = dashboard(conn)

    assert has_element?(view, "[data-testid='dashboard-runway']", "No active burn")
    assert has_element?(view, "[data-testid='dashboard-runway']", "Nothing burning right now.")
    refute render(view) =~ "Your first deploy starts the meter."
  end

  # The formatter's remaining arms, one wallet shape each (the month
  # arm is the test above): singular hour, under-an-hour, days,
  # depleted. Each shape owns its user so the arithmetic stays flat.
  test "runway copy tracks the balance-to-burn shape" do
    check = fn monthly_cents, cents_left, expected_runway, expected_balance ->
      {user, conn} = SessionHelpers.user_with_session(Phoenix.ConnTest.build_conn())

      org = AccountsFixtures.personal_org!(user)
      {:ok, wallet} = Billing.ensure_wallet(org)

      # Deploy first (creates are balance-gated), then shape the wallet.
      version = InstanceFixtures.app_version!(monthly_cents: monthly_cents)
      instance = InstanceFixtures.instance!(version, user)
      InstanceFixtures.walk_to!(instance, :running)

      {:ok, balance} = Billing.balance(wallet, actor: user)
      Billing.debit_wallet(wallet, (balance - cents_left) * @micro_per_cent)

      {:ok, view, _html} = dashboard(conn)

      assert has_element?(view, "[data-testid='dashboard-runway']", expected_runway)

      if expected_balance do
        assert has_element?(view, "[data-testid='dashboard-balance']", expected_balance)
      end
    end

    check.(1000, 2, "≈ 1 hour", nil)
    check.(1000, 1, "under an hour", nil)
    check.(100, 100, "≈ 30 days", nil)

    # The wallet crossed zero — no "under an hour" sugar on a spent
    # balance, and the balance card carries the minus sign.
    check.(100, -4, "Depleted", "-$0.04")
  end

  test "a status broadcast re-streams the row in place", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = InstanceFixtures.instance!(version, user)
    deployed = InstanceFixtures.walk_to!(instance, :deploying)

    {:ok, view, _html} = dashboard(conn)

    assert has_element?(view, "#instances-#{deployed.id}", "Provisioning")

    InstanceK8s.update_status(deployed, :starting, nil)

    assert has_element?(view, "#instances-#{deployed.id}", "Starting")
  end

  # CodeRabbit #207: a transition that changes burn must move the
  # runway card with the row — a live "Running" badge under a stale
  # "No active burn" contradicts the dashboard's own live status.
  test "a burn-starting broadcast refreshes the runway card", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = InstanceFixtures.instance!(version, user)
    deployed = InstanceFixtures.walk_to!(instance, :deploying)

    {:ok, view, _html} = dashboard(conn)

    assert has_element?(view, "[data-testid='dashboard-runway']", "No active burn")

    {:ok, starting} = InstanceK8s.update_status(deployed, :starting, nil)
    InstanceK8s.update_status(starting, :running, nil)

    assert has_element?(view, "#instances-#{instance.id}", "Running")

    assert has_element?(
             view,
             "[data-testid='dashboard-runway']",
             ~r/at \$[\d.]+\/mo current burn/
           )
  end

  test "a destroy broadcast drops the row and the count follows", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = InstanceFixtures.instance!(version, user)
    InstanceFixtures.walk_to!(instance, :running)

    {:ok, view, _html} = dashboard(conn)

    Instance.delete(instance.id, actor: user)

    html = render(view)

    refute has_element?(view, "#instances-#{instance.id}")
    assert html =~ "No instances yet"
  end

  test "a stale notification for a torn-down row must not crash", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = InstanceFixtures.instance!(version, user)
    InstanceFixtures.walk_to!(instance, :running)

    {:ok, view, _html} = dashboard(conn)

    # The exact interleaving the re-read exists for: an update_status
    # notification for a row teardown already deleted.
    Instance.delete(instance.id, actor: user)

    notification = %Ash.Notifier.Notification{
      resource: Instance,
      action: %{name: :update_status},
      data: instance
    }

    Phoenix.PubSub.broadcast(FluxVale.PubSub, "instances:#{instance.id}", notification)

    refute has_element?(view, "#instances-#{instance.id}")
  end

  test "a user without an org keeps the dashboard — billing callout, no metric cards", %{
    conn: conn
  } do
    # Ash.seed! — the only way to produce an org-less user: the create
    # action's JIT change always provisions one (state actions can't
    # produce, the documented seed! exception).
    orgless = Ash.Seed.seed!(User, %{email: "orgless-#{System.unique_integer()}@fluxvale.test"})
    conn = SessionHelpers.sign_in(conn, orgless)

    {:ok, view, html} = dashboard(conn)

    assert has_element?(view, "h1", "Dashboard")
    assert html =~ "Billing unavailable"
    refute has_element?(view, "[data-testid='dashboard-balance']")
    # The fresh-account nudge needs the wallet — nothing to promise here.
    refute html =~ "in credits — your first deploy is on us."
  end

  test "a bad session never mounts the dashboard", %{conn: conn} do
    # Through the controller this arm is unreachable (MaybeResolveUser
    # gates first); live_isolated mounts the view alone to prove the
    # on_mount gate still owns the redirect when the session dies
    # between the resolve and the mount.
    conn = Plug.Test.init_test_session(conn, %{"user_token" => "junk"})

    case Phoenix.LiveViewTest.live_isolated(conn, FluxValeWeb.DashboardLive,
           session: %{"user_token" => "junk"}
         ) do
      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/sign-in"

      {:error, {:redirect, %{to: to}}} ->
        assert to == ~p"/sign-in"
    end
  end
end
