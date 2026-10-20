defmodule FluxValeWeb.InstanceLive.ShowTest do
  @moduledoc false

  # The status surface (#74): state, URL, lifecycle controls, and the
  # broadcast-driven updates. deploy/stop/start run against stubbed K8s
  # (Oban inline executes the deploy trigger synchronously); teardown's
  # exit is driven by a direct broadcast (its K8s choreography is #73's
  # contract, asserted there).

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import FluxVale.TestSupport.NoK8sLeaks
  import Phoenix.LiveViewTest

  alias FluxVale.Clients.K8s

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    {user, conn} = SessionHelpers.user_with_session(conn)
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()
    {:ok, user: user, conn: conn, version: version}
  end

  defp create_instance!(version, user) do
    Instance.create!(%{name: "Inst #{System.unique_integer()}", app_version_id: version.id},
      actor: user
    )
  end

  defp stub_deploy_k8s do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _replicas -> {:ok, %{}} end)
    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
  end

  test "renders the status surface with URL and details", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    {:ok, view, html} = live(conn, ~p"/instances/#{instance.id}")

    # #179: the arc vocabulary, not the internal atom — and no k8s term
    # anywhere on the surface.
    assert has_element?(view, ".badge", "Submitted")
    assert has_element?(view, "[data-testid='status-message']", "We've got your request")
    refute_k8s_terms(html)
    assert html =~ "#{instance.slug}.fluxvale.lvh.me"
    assert has_element?(view, "button[phx-click='deploy']", "Deploy")
    assert has_element?(view, "button[phx-click='delete']")
    # ADR-0028's flat rate on the status surface (#125): the fixture
    # size prices at 100¢ running.
    assert has_element?(view, "[data-testid='instance-price']", "$1.00/mo")
  end

  test "a stopped instance shows the storage-only fee", %{
    conn: conn,
    user: user,
    version: version
  } do
    pending = create_instance!(version, user)
    instance = InstanceFixtures.walk_to!(pending, :stopped)
    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    assert has_element?(view, "[data-testid='instance-price']", "$0.10/mo while stopped")
  end

  test "a non-stopped lifecycle state shows the configured running price", %{
    conn: conn,
    user: user,
    version: version
  } do
    # :error is the interesting arm — the row states the instance's
    # configured price, not an accrual (settlement is #121's).
    pending = create_instance!(version, user)
    instance = InstanceFixtures.walk_to!(pending, :running)
    {:ok, _started} = InstanceK8s.update_status(instance, :error, "boom")

    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    assert has_element?(view, "[data-testid='instance-price']", "$1.00/mo")
    refute has_element?(view, "[data-testid='instance-price']", "while stopped")
  end

  test "an instance of a pre-#125 version shows no price row", %{conn: conn, user: user} do
    version = InstanceFixtures.app_version!()
    app = Ash.load!(version, :app, authorize?: false).app

    # States actions can't produce: the pre-#125 shape — nil size.
    unsized =
      Ash.Seed.seed!(AppVersion, %{
        version: "0.9.0",
        image: "test/image:0.9",
        port: 3000,
        app_id: app.id
      })

    instance = create_instance!(unsized, user)
    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    refute has_element?(view, "[data-testid='instance-price']")
  end

  test "another actor's instance is not found", %{conn: conn, version: version} do
    other = SessionHelpers.user!()
    theirs = create_instance!(version, other)

    case live(conn, ~p"/instances/#{theirs.id}") do
      {:ok, view, _html} ->
        assert_redirect(view, ~p"/instances")

      # push_navigate in mount surfaces as live_redirect from live/2
      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/instances"
    end
  end

  test "the deploy button fires the deploy trigger through stubbed K8s", %{
    conn: conn,
    user: user,
    version: version
  } do
    stub_deploy_k8s()

    instance = create_instance!(version, user)
    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")

    view
    |> element("button[phx-click='deploy']")
    |> render_click()

    # The action's own :deploying publish can trail the inline trigger's
    # :starting (notification order isn't write order) — the view re-reads
    # the row per broadcast, so a follow-up render is the settled truth.
    render(view)

    assert has_element?(view, ".badge", "Starting")
  end

  test "stop and start buttons drive the state machine", %{
    conn: conn,
    user: user,
    version: version
  } do
    stub_deploy_k8s()

    instance = create_instance!(version, user)
    running = InstanceFixtures.walk_to!(instance, :running)

    {:ok, view, _html} = live(conn, ~p"/instances/#{running.id}")

    view
    |> element("button[phx-click='stop']")
    |> render_click()

    assert has_element?(view, ".badge", "Stopped")

    view
    |> element("button[phx-click='start']")
    |> render_click()

    assert has_element?(view, ".badge", "Starting")
  end

  # The illegal-transition arms: a stale event (state moved server-side
  # between render and event — an in-flight click, say) must flash, not
  # crash — the action-level guards are the real gate, buttons are
  # presentation. Pushed channel-level (render_click/3): the view's own
  # subscription keeps its DOM too fresh for a stale button to exist.
  test "a stale deploy event flashes instead of crashing", %{
    conn: conn,
    user: user,
    version: version
  } do
    stub_deploy_k8s()

    instance = create_instance!(version, user)
    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    # The state moves behind the view's back — the next deploy event is
    # now an illegal transition
    InstanceFixtures.walk_to!(instance, :running)
    render(view)

    html = render_click(view, "deploy", %{})

    assert html =~ "Deploy isn&#39;t possible"
    assert has_element?(view, ".badge", "Running")
  end

  test "a stale stop event flashes instead of crashing", %{
    conn: conn,
    user: user,
    version: version
  } do
    stub_deploy_k8s()

    instance = create_instance!(version, user)
    running = InstanceFixtures.walk_to!(instance, :running)

    {:ok, view, _html} = live(conn, ~p"/instances/#{running.id}")

    # Stopped behind the view's back — stop is now illegal
    InstanceK8s.update_status(running, :stopped, nil)
    render(view)

    html = render_click(view, "stop", %{})

    assert html =~ "action isn&#39;t possible"
    assert has_element?(view, ".badge", "Stopped")
  end

  test "a deleting instance shows the teardown state and no controls", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    # The delete action's first write — no teardown enqueued here (that
    # path is #73's), just the broadcast's presentation.
    InstanceK8s.update_status(instance, :deleting, "Tearing down K8s resources...")

    html = render(view)

    assert has_element?(view, ".badge", "Deleting")
    assert has_element?(view, "[data-testid='status-message']", "Cleaning up")
    refute_k8s_terms(html)
    refute has_element?(view, "button[phx-click='delete']")
  end

  test "delete exits through the destroy broadcast", %{conn: conn, user: user, version: version} do
    instance = create_instance!(version, user)
    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    # Never deployed: delete hard-deletes synchronously; the destroy
    # broadcast navigates the page away.
    view
    |> element("button[phx-click='delete']")
    |> render_click()

    assert_redirect(view, ~p"/instances")
  end

  test "a status broadcast from the reconciler updates the page live", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    running = InstanceFixtures.walk_to!(instance, :running)

    InstanceK8s.update_status(running, :running, "All replicas ready")

    html = render(view)

    assert has_element?(view, ".badge", "Running")
    assert has_element?(view, "[data-testid='status-message']", "up and running")
    refute_k8s_terms(html)
    assert has_element?(view, "a[href^='https://#{instance.slug}.']")
  end

  test "a trailing update broadcast for a deleted row keeps the last state", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    {:ok, view, html} = live(conn, ~p"/instances/#{instance.id}")

    # The interleaving the re-read defends against: an update_status
    # broadcast whose row no longer reads back. A foreign id exercises
    # the arm without racing teardown's own destroy notification.
    notification = %Ash.Notifier.Notification{
      resource: Instance,
      action: %{name: :update_status},
      data: %{id: Ash.UUID.generate()}
    }

    Phoenix.PubSub.broadcast(FluxVale.PubSub, "instances:#{instance.id}", notification)

    # Unchanged: the view holds its state (the :destroy clause is the exit)
    assert render(view) =~ instance.name
    assert has_element?(view, ".badge", "Submitted")
    refute html =~ "isn&#39;t possible"
  end

  # #179: the friendly arc — every in-flight/landed state renders its
  # plain-language copy, live off the broadcasts, and no k8s term
  # renders at any step of the way.
  test "the provisioning arc renders friendly copy per state", %{
    conn: conn,
    user: user,
    version: version
  } do
    stub_deploy_k8s()

    instance = create_instance!(version, user)
    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    assert has_element?(view, ".badge", "Submitted")
    assert has_element?(view, "[data-testid='status-message']", "setup will begin shortly")

    deploying = InstanceFixtures.walk_to!(instance, :deploying)
    render(view)
    assert has_element?(view, ".badge", "Provisioning")
    assert has_element?(view, "[data-testid='status-message']", "Setting up your app")

    {:ok, _starting} = InstanceK8s.update_status(deploying, :starting, "awaiting readiness")
    render(view)
    assert has_element?(view, ".badge", "Starting")
    assert has_element?(view, "[data-testid='status-message']", "Starting it up")

    InstanceFixtures.walk_to!(instance, :running)
    html = render(view)
    assert has_element?(view, ".badge", "Running")
    assert has_element?(view, "[data-testid='status-message']", "up and running")
    refute_k8s_terms(html)
  end

  test "a lingering provision swaps in the taking-longer copy", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    deploying = InstanceFixtures.walk_to!(instance, :deploying)

    {:ok, view, _html} = live(conn, ~p"/instances/#{deploying.id}")

    assert has_element?(view, "[data-testid='status-message']", "Setting up your app")

    # The provision lingers past the slow threshold — still in-flight
    # per the state machine, but the copy acknowledges the wait.
    InstanceFixtures.pin!(deploying, deployed_at: DateTime.add(DateTime.utc_now(), -600, :second))

    html = render(view)

    assert has_element?(
             view,
             "[data-testid='status-message']",
             "This is taking longer than usual"
           )

    refute_k8s_terms(html)
  end

  # The observed incident (#179's why), replayed verbatim: the deploy
  # apply hits a 403 carrying RBAC wording, service-account names, and
  # the namespace — none of it may reach the surface.
  test "a failed deploy renders friendly copy, keeping the detail on the row", %{
    conn: conn,
    user: user,
    version: version
  } do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    stub(ResourceQuota, :create, fn _kc, ns, _n, _spec ->
      {:error,
       %Error{
         status_code: 403,
         reason: :forbidden,
         message:
           "resourcequotas is forbidden: User \"system:serviceaccount:fluxvale:platform\" " <>
             "cannot create resource \"resourcequotas\" in API group \"\" in the namespace \"#{ns}\""
       }}
    end)

    instance = create_instance!(version, user)
    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    view
    |> element("button[phx-click='deploy']")
    |> render_click()

    html = render(view)

    # The user sees the failure vocabulary + a next step — and nothing else.
    assert has_element?(view, ".badge", "Failed")
    assert has_element?(view, "[data-testid='status-message']", "We hit a snag")
    assert has_element?(view, "button[phx-click='deploy']", "Retry deploy")
    refute_k8s_terms(html)

    # The technical detail lives on, exactly where ops needs it: the
    # row (admin reveal below asserts it renders for staff only).
    stored = Instance.get_by_id!(instance.id, authorize?: false)
    assert stored.status_message =~ "resourcequotas is forbidden"
    assert stored.status_message =~ "system:serviceaccount"
    assert stored.failure_reason == :deploy_failed
    assert stored.namespace == "fluxvale-app-#{instance.id}"
  end

  test "an admin sees the technical reveal; a non-admin never does", %{
    conn: conn,
    version: version
  } do
    admin =
      User.create!(
        "admin-#{System.unique_integer()}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    instance = create_instance!(version, admin)
    InstanceFixtures.pin!(instance, namespace: "fluxvale-app-#{instance.id}")

    InstanceK8s.update_status(
      instance,
      :error,
      "Deploy failed: resourcequotas is forbidden: User system:serviceaccount cannot create",
      :deploy_failed
    )

    # The admin's own page: friendly copy AND the raw trail — the one
    # sanctioned surface for k8s terms (#179's admin-only reveal); no
    # denylist here by design.
    admin_conn = SessionHelpers.sign_in(conn, admin)
    {:ok, view, _html} = live(admin_conn, ~p"/instances/#{instance.id}")

    assert has_element?(view, "[data-testid='status-message']", "We hit a snag")
    assert has_element?(view, "[data-testid='admin-technical']")

    technical =
      view
      |> element("[data-testid='admin-technical']")
      |> render()
      |> String.downcase()

    assert technical =~ "resourcequotas is forbidden"
    assert technical =~ "system:serviceaccount"
    assert technical =~ "fluxvale-app-#{instance.id}"
    assert technical =~ "deploy_failed"

    # A non-admin owner: the same failure, friendly copy only — the
    # reveal doesn't exist on their page, denylist enforced.
    {owner, owner_conn} = SessionHelpers.user_with_session(conn)
    owned = create_instance!(version, owner)

    InstanceK8s.update_status(owned, :error, "Deploy failed: quota exceeded", :deploy_failed)

    {:ok, owner_view, owner_html} = live(owner_conn, ~p"/instances/#{owned.id}")

    assert has_element?(owner_view, ".badge", "Failed")
    assert has_element?(owner_view, "[data-testid='status-message']", "We hit a snag")
    refute has_element?(owner_view, "[data-testid='admin-technical']")
    refute_k8s_terms(owner_html)
  end

  # #179's status tick: the taking-longer copy is render-time derived
  # and a lingering provision writes nothing (a reconcile no-op doesn't
  # broadcast) — the tick is what re-renders an open page. Pushed
  # channel-level like the real timer would.
  test "the status tick re-renders an in-flight page without a status write", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    deploying = InstanceFixtures.walk_to!(instance, :deploying)

    {:ok, view, _html} = live(conn, ~p"/instances/#{deploying.id}")

    assert has_element?(view, "[data-testid='status-message']", "Setting up your app")

    send(view.pid, :status_tick)

    html = render(view)

    # Fresh clock → still the progress copy; the tick re-rendered
    # without crashing and without any row write.
    assert has_element?(view, ".badge", "Provisioning")
    assert has_element?(view, "[data-testid='status-message']", "Setting up your app")
    refute_k8s_terms(html)
  end

  test "the status tick is a no-op on a settled page", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    running = InstanceFixtures.walk_to!(instance, :running)

    {:ok, view, _html} = live(conn, ~p"/instances/#{running.id}")

    send(view.pid, :status_tick)

    assert has_element?(view, ".badge", "Running")
    assert has_element?(view, "[data-testid='status-message']", "up and running")
  end
end
