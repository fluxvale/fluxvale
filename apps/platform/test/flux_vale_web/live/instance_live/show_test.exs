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
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Clients.K8s.SelfAccessReview

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Pricing.Size
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
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
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
    assert has_element?(view, "[data-testid=status-badge]", "Submitted")
    assert has_element?(view, "[data-testid='status-message']", "We've got your request")
    refute_k8s_terms(html)
    assert html =~ "#{instance.slug}.fluxvale.lvh.me"
    assert has_element?(view, "button[phx-click='deploy']", "Deploy")
    assert has_element?(view, "button[phx-click='delete']")
    # ADR-0028's flat rate on the status surface (#125): the fixture
    # size prices at 100¢ running.
    assert has_element?(view, "[data-testid='instance-price']", "$1.00/mo · billed hourly")
  end

  test "a stopped instance shows the storage-only fee", %{
    conn: conn,
    user: user,
    version: version
  } do
    pending = create_instance!(version, user)
    instance = InstanceFixtures.walk_to!(pending, :stopped)
    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    assert has_element?(
             view,
             "[data-testid='instance-price']",
             "$0.10/mo while stopped · billed hourly"
           )
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

    assert has_element?(view, "[data-testid='instance-price']", "$1.00/mo · billed hourly")
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

  test "renders the first-run contract's guidance when the version carries one (#181)", %{
    conn: conn,
    user: user
  } do
    version =
      InstanceFixtures.app_version!(
        first_run: %{
          "pattern" => "first_registered_user_admin",
          "env" => %{"APP__security__INSTALL_LOCK" => "true"},
          "forbidden_env" => [],
          "guidance" => "Register first — the first account becomes admin."
        }
      )

    instance = create_instance!(version, user)
    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    assert has_element?(
             view,
             "[data-testid='first-run-guidance']",
             "Register first — the first account becomes admin."
           )
  end

  test "no first-run card for a version without a contract (#181)", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    refute has_element?(view, "[data-testid='first-run-guidance']")
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

    assert has_element?(view, "[data-testid=status-badge]", "Starting")
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

    assert has_element?(view, "[data-testid=status-badge]", "Stopped")

    view
    |> element("button[phx-click='start']")
    |> render_click()

    assert has_element?(view, "[data-testid=status-badge]", "Starting")
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
    assert has_element?(view, "[data-testid=status-badge]", "Running")
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
    assert has_element?(view, "[data-testid=status-badge]", "Stopped")
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

    assert has_element?(view, "[data-testid=status-badge]", "Deleting")
    assert has_element?(view, "[data-testid='status-message']", "Cleaning up")
    refute_k8s_terms(html)
    refute has_element?(view, "button[phx-click='delete']")
  end

  # #196: the lost surface — the anomaly is visible, billing-stopped is
  # said out loud, and both exits (re-deploy, teardown) are offered.
  test "a lost instance surfaces the anomaly with re-deploy and teardown affordances", %{
    conn: conn,
    user: user,
    version: version
  } do
    pending = create_instance!(version, user)
    running = InstanceFixtures.walk_to!(pending, :running)

    {:ok, _lost} = InstanceK8s.update_status(running, :lost, "Namespace gone from cluster")

    {:ok, view, html} = live(conn, ~p"/instances/#{running.id}")

    assert has_element?(view, "[data-testid=status-badge]", "Lost")
    assert has_element?(view, "[data-testid='status-message']", "billing has been stopped")
    assert has_element?(view, "button[phx-click='deploy']", "Re-deploy")
    assert has_element?(view, "button[phx-click='delete']")

    # stop/start are not offered — nothing is running to stop or start.
    refute has_element?(view, "button[phx-click='stop']")
    refute has_element?(view, "button[phx-click='start']")
    refute_k8s_terms(html)
  end

  test "re-deploy from the lost surface re-enters the deploy lane", %{
    conn: conn,
    user: user,
    version: version
  } do
    stub_deploy_k8s()

    pending = create_instance!(version, user)
    running = InstanceFixtures.walk_to!(pending, :running)

    {:ok, lost} = InstanceK8s.update_status(running, :lost, "Namespace gone from cluster")

    {:ok, view, _html} = live(conn, ~p"/instances/#{lost.id}")

    view
    |> element("button[phx-click='deploy']")
    |> render_click()

    # Same shape as the pending-deploy test: the inline trigger runs the
    # deploy through to :starting; a follow-up render is the settled truth.
    render(view)

    assert has_element?(view, "[data-testid=status-badge]", "Starting")
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

    assert has_element?(view, "[data-testid=status-badge]", "Running")
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
    assert has_element?(view, "[data-testid=status-badge]", "Submitted")
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

    assert has_element?(view, "[data-testid=status-badge]", "Submitted")
    assert has_element?(view, "[data-testid='status-message']", "setup will begin shortly")

    deploying = InstanceFixtures.walk_to!(instance, :deploying)
    render(view)
    assert has_element?(view, "[data-testid=status-badge]", "Provisioning")
    assert has_element?(view, "[data-testid='status-message']", "Setting up your app")

    {:ok, _starting} = InstanceK8s.update_status(deploying, :starting, "awaiting readiness")
    render(view)
    assert has_element?(view, "[data-testid=status-badge]", "Starting")
    assert has_element?(view, "[data-testid='status-message']", "Starting it up")

    InstanceFixtures.walk_to!(instance, :running)
    html = render(view)
    assert has_element?(view, "[data-testid=status-badge]", "Running")
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

    # #238: the forbidden path now waits out RBAC propagation first —
    # stubbed to skip the poll loop; the quota stub below stays
    # forbidden, so the retry lands the verbatim message.
    stub(SelfAccessReview, :wait_until_allowed, fn _kc, _ns, _res, _verb -> :ok end)

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
    assert has_element?(view, "[data-testid=status-badge]", "Failed")
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

    # #196: a lost row's reveal also carries the detection moment — the
    # billing-stop audit trail, admin-side only.
    {:ok, errored} = Instance.get_by_id(instance.id, authorize?: false)
    running = InstanceFixtures.walk_to!(errored, :running)
    {:ok, _lost} = InstanceK8s.update_status(running, :lost, "Namespace gone")

    {:ok, lost_view, _html} = live(admin_conn, ~p"/instances/#{instance.id}")

    lost_technical =
      lost_view
      |> element("[data-testid='admin-technical']")
      |> render()
      |> String.downcase()

    assert lost_technical =~ "lost_detected_at"
    assert lost_technical =~ "namespace gone"

    # A non-admin owner: the same failure, friendly copy only — the
    # reveal doesn't exist on their page, denylist enforced.
    {owner, owner_conn} = SessionHelpers.user_with_session(conn)
    owned = create_instance!(version, owner)

    InstanceK8s.update_status(owned, :error, "Deploy failed: quota exceeded", :deploy_failed)

    {:ok, owner_view, owner_html} = live(owner_conn, ~p"/instances/#{owned.id}")

    assert has_element?(owner_view, "[data-testid=status-badge]", "Failed")
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
    assert has_element?(view, "[data-testid=status-badge]", "Provisioning")
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

    assert has_element?(view, "[data-testid=status-badge]", "Running")
    assert has_element?(view, "[data-testid='status-message']", "up and running")
  end

  describe "the sleeping surface (#203, ADR-0036)" do
    defp sleeping_instance!(version, user) do
      instance = create_instance!(version, user)

      instance
      |> InstanceFixtures.pin!(
        namespace: "fluxvale-app-#{instance.id}",
        deployed_at: DateTime.utc_now()
      )
      |> InstanceFixtures.walk_to!(:sleeping)
    end

    test "sleeping renders its own badge, copy, wake button, storage-only price", %{
      conn: conn,
      user: user,
      version: version
    } do
      sleeping = sleeping_instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{sleeping.id}")

      assert has_element?(view, "[data-testid=status-badge]", "Sleeping")
      assert has_element?(view, "[data-testid=status-message]", ~r/wakes automatically/)
      assert has_element?(view, "[data-testid=wake-button]", "Wake up")
      refute has_element?(view, "[data-testid=start-button]")
      refute has_element?(view, "[data-testid=stop-button]")

      # Storage-only while asleep — the sleeping bill is the stopped
      # bill (ADR-0028 §2), shown in the instance's own vocabulary.
      loaded = Ash.load!(sleeping, app_version: :recommended_size)
      size = loaded.app_version.recommended_size
      assert has_element?(view, "[data-testid=instance-price]", ~r/asleep/)

      assert has_element?(
               view,
               "[data-testid=instance-price]",
               FluxVale.Pricing.format_usd(size.stopped_monthly_cents)
             )

      refute_k8s_terms(render(view))
    end

    test "the Wake button rides start and lands :starting", %{
      conn: conn,
      user: user,
      version: version
    } do
      stub_deploy_k8s()
      sleeping = sleeping_instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{sleeping.id}")

      view
      |> element("[data-testid=wake-button]")
      |> render_click()

      assert has_element?(view, "[data-testid=status-badge]", "Starting")
    end

    test "enabling always-on on a sleeping instance wakes it", %{
      conn: conn,
      user: user,
      version: version
    } do
      stub_deploy_k8s()
      sleeping = sleeping_instance!(version, user)

      {:ok, view, _html} = live(conn, ~p"/instances/#{sleeping.id}")

      view
      |> element("[data-testid=always-on-toggle]")
      |> render_click()

      assert has_element?(view, "[data-testid=availability-mode]", "Always on")
      assert has_element?(view, "[data-testid=status-badge]", "Starting")
    end

    test "the availability card toggles always-on", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = create_instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid=availability-card]")
      assert has_element?(view, "[data-testid=availability-mode]", "Sleeps when idle")
      assert has_element?(view, "[data-testid=always-on-toggle]", "Keep always on")
      # #261: no premium framing anywhere on the surface.
      refute render(view) =~ "premium"

      view
      |> element("[data-testid=always-on-toggle]")
      |> render_click()

      assert has_element?(view, "[data-testid=availability-mode]", "Always on")
      assert has_element?(view, "[data-testid=always-on-toggle]", "Let it sleep when idle")
    end

    # #261 (ADR-0036 Am. 2): enabling is the charge-raising direction —
    # the data-confirm gate states the full-rate consequence in the
    # row's own settlement figures and the wake-on-enable behavior;
    # disabling only saves money, so it carries no gate. (LiveView
    # tests click past data-confirm — the client owns the dialog; the
    # e2e backups spec exercises the real accept.)
    test "enabling always-on carries the cost confirmation; disabling carries none", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = create_instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      # The fixture settles at 100¢ running / 10¢ storage-only — both
      # figures ride the confirm, monthly-equivalent · billed hourly
      # (#206), with the immediate wake stated.
      enable = element(view, "[data-testid=always-on-toggle]")
      confirm = render(enable)

      assert confirm =~ "data-confirm="
      assert confirm =~ "$1.00/mo"
      assert confirm =~ "$0.10/mo"
      assert confirm =~ "billed hourly"
      assert confirm =~ "wakes immediately"

      render_click(enable)

      assert has_element?(view, "[data-testid=availability-mode]", "Always on")

      disable = render(element(view, "[data-testid=always-on-toggle]"))

      refute disable =~ "data-confirm="
    end

    # The one shape actions can't produce (pre-#121 drift): no size, no
    # formula snapshot — settlement forgives the row, so the confirm
    # must render figure-free rather than crash or stay silent.
    test "an unpriced instance's confirm falls back to figure-free copy", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = create_instance!(version, user)

      unpriced =
        InstanceFixtures.pin!(
          instance,
          size_id: nil,
          grandfathered_until: nil,
          grandfathered_monthly_cents: nil,
          grandfathered_stopped_monthly_cents: nil
        )

      {:ok, view, _html} = live(conn, ~p"/instances/#{unpriced.id}")

      button = render(element(view, "[data-testid=always-on-toggle]"))

      assert button =~ "data-confirm="
      assert button =~ "bills the full rate around the clock"
      refute button =~ "$"
    end

    # The accept-time guard (#261 review, PA-adopted): the dialog's
    # figure is as-of render; enabling re-prices and refuses on any
    # difference — the user confirms the number they'll actually pay.
    # Staged as the review's exact scenario: the page lapsed its
    # grandfathering grace (the confirm prices off the live Size row),
    # then the size's price is edited behind the open page.
    test "a stale shown figure refuses the enable and re-asks with fresh copy", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = create_instance!(version, user)
      lapsed = DateTime.add(DateTime.utc_now(), -1, :second)
      InstanceFixtures.pin!(instance, grandfathered_until: lapsed)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      # Past grace, the confirm prices off the live size: $1.00/mo.
      assert render(element(view, "[data-testid=always-on-toggle]")) =~ "$1.00/mo"

      size = Ash.load!(version, :recommended_size, authorize?: false).recommended_size
      Size.update!(size, %{monthly_cents: 200}, authorize?: false)

      # The click carries the figure the dialog showed — 100¢, stale.
      html =
        render_click(view, "toggle-always-on", %{
          "always_on" => "true",
          "shown_monthly_cents" => "100"
        })

      assert html =~ "Pricing changed"
      assert html =~ "$2.00/mo"

      # Refused: the flag never landed, and the page re-asks with the
      # fresh figure in both the flash and the refreshed confirm.
      refute Instance.get_by_id!(instance.id, authorize?: false).always_on

      assert render(element(view, "[data-testid=always-on-toggle]")) =~ "$2.00/mo"

      # The re-asked click — the button now carries the fresh figure —
      # goes through.
      render_click(element(view, "[data-testid=always-on-toggle]"))

      assert has_element?(view, "[data-testid=availability-mode]", "Always on")
      assert Instance.get_by_id!(instance.id, authorize?: false).always_on
    end

    test "a matching shown figure lets the enable proceed", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = create_instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(view, "toggle-always-on", %{
        "always_on" => "true",
        "shown_monthly_cents" => "100"
      })

      assert has_element?(view, "[data-testid=availability-mode]", "Always on")
      assert Instance.get_by_id!(instance.id, authorize?: false).always_on
    end

    # No figure was shown (unpriced copy), so there is nothing to
    # contradict — both the absent key and a stale view's explicit
    # empty string proceed.
    test "an unpriced row enables without a figure", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = create_instance!(version, user)

      unpriced =
        InstanceFixtures.pin!(
          instance,
          size_id: nil,
          grandfathered_until: nil,
          grandfathered_monthly_cents: nil,
          grandfathered_stopped_monthly_cents: nil
        )

      {:ok, view, _html} = live(conn, ~p"/instances/#{unpriced.id}")

      render_click(view, "toggle-always-on", %{"always_on" => "true"})

      assert has_element?(view, "[data-testid=availability-mode]", "Always on")

      render_click(view, "toggle-always-on", %{"always_on" => "true", "shown_monthly_cents" => ""})

      assert Instance.get_by_id!(unpriced.id, authorize?: false).always_on
    end

    # A stale view can carry any string in phx-value; a figure that
    # can't parse can't be matched against truth — the safe answer is
    # the refuse-and-re-ask arm, not an enable.
    test "a garbled figure payload refuses rather than enabling", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = create_instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      html =
        render_click(view, "toggle-always-on", %{
          "always_on" => "true",
          "shown_monthly_cents" => "hundred"
        })

      assert html =~ "Pricing changed"
      refute Instance.get_by_id!(instance.id, authorize?: false).always_on
    end

    # Priced at render, unpriced by the click (drift surgery on the
    # row mid-event): the guard can't confirm the shown figure, so it
    # re-asks — figure-free now, like the row.
    test "a row that becomes unpriced re-asks figure-free", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = create_instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      InstanceFixtures.pin!(
        instance,
        size_id: nil,
        grandfathered_until: nil,
        grandfathered_monthly_cents: nil,
        grandfathered_stopped_monthly_cents: nil
      )

      html =
        render_click(view, "toggle-always-on", %{
          "always_on" => "true",
          "shown_monthly_cents" => "100"
        })

      assert html =~ "Pricing changed since that dialog"
      refute Instance.get_by_id!(instance.id, authorize?: false).always_on

      button = render(element(view, "[data-testid=always-on-toggle]"))

      refute button =~ "$"
    end
  end

  describe "exposure toggle (#265)" do
    test "the availability card carries the exposure posture with honest copy", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = create_instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid=exposure-mode]", "Public")
      assert has_element?(view, "[data-testid=exposure-toggle]", "Make private")

      # Honest public copy: reachability, and that exposure bills
      # nothing (#265's no-billing-change) — fragments that don't
      # cross the template's line breaks.
      copy = render(element(view, "[data-testid=exposure-copy]"))
      assert copy =~ "Anyone on the internet"
      assert copy =~ "changes what you pay"
    end

    test "the toggle flips public → private; the copy states the cut-off plainly", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = create_instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      view
      |> element("[data-testid=exposure-toggle]")
      |> render_click()

      assert has_element?(view, "[data-testid=exposure-mode]", "Private")
      assert has_element?(view, "[data-testid=exposure-toggle]", "Make public")

      # #265's copy contract: manageable via the panel, NOT reachable,
      # nothing wakes a sleeping one, the access layer is upcoming
      # (never dated, never named), exposure is free.
      copy = render(element(view, "[data-testid=exposure-copy]"))

      assert copy =~ "unreachable from the internet"
      assert copy =~ "full control from this panel"
      assert copy =~ "nothing can wake a sleeping private instance"
      assert copy =~ "upcoming"
      assert copy =~ "never changes what you pay"

      assert Instance.get_by_id!(instance.id, authorize?: false).exposure == :private
    end

    # #265: making private is the reachability-cutting direction —
    # confirm in plain words (the always-on enable gate's stance);
    # making public only restores service, so it rides bare.
    test "making private carries the cut-off confirmation; making public carries none", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = create_instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      make_private = render(element(view, "[data-testid=exposure-toggle]"))

      assert make_private =~ "data-confirm="
      assert make_private =~ "stops working immediately"

      view
      |> element("[data-testid=exposure-toggle]")
      |> render_click()

      make_public = render(element(view, "[data-testid=exposure-toggle]"))
      refute make_public =~ "data-confirm="
    end

    test "the Open affordance never renders for a private instance", %{
      conn: conn,
      user: user,
      version: version
    } do
      pending = create_instance!(version, user)

      private =
        pending
        |> InstanceFixtures.pin!(namespace: "fluxvale-app-#{pending.id}")
        |> InstanceFixtures.walk_to!(:running)
        |> InstanceFixtures.pin!(exposure: :private)

      {:ok, view, _html} = live(conn, ~p"/instances/#{private.id}")
      refute has_element?(view, "[data-testid=open-instance]")
      # PR #267 review finding 1: the header URL is a public
      # affordance too — a private instance renders no address that
      # cannot answer.
      refute has_element?(view, "[data-testid=instance-url]")

      public = InstanceFixtures.pin!(private, exposure: :public)
      {:ok, public_view, _html} = live(conn, ~p"/instances/#{public.id}")
      assert has_element?(public_view, "[data-testid=open-instance]")
      assert has_element?(public_view, "[data-testid=instance-url]")
    end

    test "the file-access panel hides while private — its endpoint rides the public hostname", %{
      conn: conn,
      user: user
    } do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      pending = create_instance!(version, user)

      private =
        pending
        |> InstanceFixtures.pin!(namespace: "fluxvale-app-#{pending.id}")
        |> InstanceFixtures.walk_to!(:running)
        |> InstanceFixtures.pin!(exposure: :private)

      {:ok, view, _html} = live(conn, ~p"/instances/#{private.id}")
      refute has_element?(view, "[data-testid=file-access-panel]")
    end

    # A stale view can carry any string in phx-value; an unknown value
    # or the already-held one changes nothing (the platform-tab
    # stance: keep the current posture).
    test "crafted or no-op payloads leave the exposure untouched", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = create_instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(view, "toggle-exposure", %{"exposure" => "banana"})
      assert Instance.get_by_id!(instance.id, authorize?: false).exposure == :public

      render_click(view, "toggle-exposure", %{"exposure" => "public"})
      assert Instance.get_by_id!(instance.id, authorize?: false).exposure == :public

      assert has_element?(view, "[data-testid=exposure-mode]", "Public")
    end

    # PR #267 review finding 2: the action's error arm is stageable —
    # a cluster failure through the LiveView flashes and keeps the row
    # public (the action rolls back; the flash owns the retry).
    test "a cluster failure flashes and keeps the instance public", %{
      conn: conn,
      user: user,
      version: version
    } do
      pending = create_instance!(version, user)

      instance =
        pending
        |> InstanceFixtures.pin!(namespace: "fluxvale-app-#{pending.id}")
        |> InstanceFixtures.walk_to!(:running)

      stub(K8s, :kubeconfig, fn nil -> {:error, Error.connection_error("cluster down")} end)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      html = render_click(view, "toggle-exposure", %{"exposure" => "private"})

      # The apostrophe rides HTML-escaped (the stale-stop flash
      # test's stance).
      assert html =~ "Couldn&#39;t change the exposure setting"
      assert has_element?(view, "[data-testid=exposure-mode]", "Public")
      assert Instance.get_by_id!(instance.id, authorize?: false).exposure == :public
    end
  end

  describe "file access panel (#190, ADR-0035)" do
    test "renders the WebDAV address, username, and rclone snippet — no password until asked", %{
      conn: conn,
      user: user
    } do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid='file-access-panel']")

      assert has_element?(
               view,
               "[data-testid='dav-url']",
               "https://#{instance.slug}.fluxvale.lvh.me/dav"
             )

      assert has_element?(view, "[data-testid='dav-username']", "fluxvale")
      assert has_element?(view, "[data-testid='dav-rclone-snippet']")
      assert has_element?(view, "[data-testid='reveal-credentials']")
      refute has_element?(view, "[data-testid='dav-password']")
    end

    # #227: a browser GET on the collection 405s — the hint teaches the
    # client move (and names the recommended pair) instead of leaving
    # every new user to repeat the live dogfood mistake.
    test "recommends WebDAV clients — browsers can't browse the endpoint", %{
      conn: conn,
      user: user
    } do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(
               view,
               "[data-testid='dav-client-hint']",
               "browsers can't browse this endpoint"
             )

      assert has_element?(
               view,
               "[data-testid='dav-client-hint']",
               "Cyberduck (macOS/Windows) · rclone to mount or script"
             )
    end

    # #194: the human copy path. Before the fix the password rendered as
    # wrapped body text with no copy affordance — a triple-click selected
    # the neighbouring "Password" label and a trailing newline, so a
    # correct credential pasted as garbage and 401'd. Every credential
    # value now carries a copy button holding the exact string.
    test "every credential value carries a copy button with its exact text", %{
      conn: conn,
      user: user
    } do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)
      url = "https://#{instance.slug}.fluxvale.lvh.me/dav"

      running =
        instance
        |> InstanceFixtures.walk_to!(:running)
        |> InstanceFixtures.pin!(namespace: "fluxvale-app-#{instance.id}")

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      expect(Secret, :get_data, fn _kc, _ns, "file-access" ->
        {:ok,
         %{
           "RCLONE_USER" => "fluxvale",
           "RCLONE_PASS" => "a43charpassword43charsa43charpassword43char"
         }}
      end)

      {:ok, view, _html} = live(conn, ~p"/instances/#{running.id}")

      render_click(element(view, "[data-testid='reveal-credentials']"))

      # The value rides a data attribute — the copy can't pick up a label
      # or a newline the way a text selection can.
      assert has_element?(
               view,
               "[data-testid='copy-dav-username'][data-copy-value='fluxvale']"
             )

      assert has_element?(view, "[data-testid='copy-dav-url'][data-copy-value='#{url}']")

      assert has_element?(
               view,
               "[data-testid='copy-dav-password'][data-copy-value='a43charpassword43charsa43charpassword43char']"
             )

      # The password renders unwrapped: overflowing rather than breaking
      # across lines, so a hand-selection stays whole. Scoped to the
      # password element — the shared button/1 base classes carry
      # `whitespace-nowrap` too, so a whole-page assertion would pass
      # even if this element lost the class (review finding).
      password_html =
        view
        |> element("[data-testid='dav-password']")
        |> render()

      assert password_html =~ "whitespace-nowrap"
      refute password_html =~ "break-all"
    end

    # #194's second cause: rclone guesses whether a `pass` value is
    # already obscured, and misreads the platform's 43-char base64url
    # password ~99% of the time — the literal snippet uploaded garbage
    # and 401'd. `--obscure` forces the plaintext reading.
    test "the rclone snippet keeps passwords out of argv and forces --obscure", %{
      conn: conn,
      user: user
    } do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      snippet =
        view
        |> element("[data-testid='dav-rclone-snippet']")
        |> render()

      # The reveal hasn't happened: no credential in the doc, and the
      # placeholder stands in.
      assert snippet =~ "YOUR_PASSWORD"
      assert snippet =~ "--obscure"

      # The copy button carries the identical text, placeholder included.
      copy =
        view
        |> element("[data-testid='copy-dav-snippet']")
        |> render()

      assert copy =~ "YOUR_PASSWORD"
    end

    test "the snippet inlines the revealed password for a one-shot copy", %{
      conn: conn,
      user: user
    } do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)

      running =
        instance
        |> InstanceFixtures.walk_to!(:running)
        |> InstanceFixtures.pin!(namespace: "fluxvale-app-#{instance.id}")

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      expect(Secret, :get_data, fn _kc, _ns, "file-access" ->
        {:ok, %{"RCLONE_USER" => "fluxvale", "RCLONE_PASS" => "s3cret"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/instances/#{running.id}")

      render_click(element(view, "[data-testid='reveal-credentials']"))

      assert has_element?(
               view,
               "[data-testid='copy-dav-snippet'][data-copy-value*=\"pass 's3cret' --obscure\"]"
             )
    end

    # #253 (ADR-0035 Am. 3): three platform tabs, each a complete
    # five-step sequence with the instance's real values inline — the
    # visitor follows the visible one verbatim, whatever their OS.
    test "every platform tab renders its full sequence with the instance's real URL and username",
         %{conn: conn, user: user} do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)
      url = "https://#{instance.slug}.fluxvale.lvh.me/dav"
      remote = "fluxvale-#{instance.slug}"

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      windows =
        view
        |> element("[data-testid='dav-panel-windows']")
        |> render()

      assert windows =~ "winget install Rclone.Rclone"
      assert windows =~ "mkdir $env:USERPROFILE\\Books"
      assert windows =~ "rclone copy $env:USERPROFILE\\Books #{remote}:library/books --progress"

      macos =
        view
        |> element("[data-testid='dav-panel-macos']")
        |> render()

      assert macos =~ "brew install rclone"
      assert macos =~ "mkdir -p ~/Books"
      assert macos =~ "rclone copy ~/Books #{remote}:library/books --progress"

      linux =
        view
        |> element("[data-testid='dav-panel-linux']")
        |> render()

      assert linux =~ "curl https://rclone.org/install.sh | sudo bash"
      assert linux =~ "mkdir -p ~/Books"
      assert linux =~ "rclone copy ~/Books #{remote}:library/books --progress"

      # The real URL and username ride every platform's connect
      # command, --obscure with them (Am. 1: it is load-bearing).
      for panel <- [windows, macos, linux] do
        assert panel =~ "url #{url} vendor rclone user fluxvale pass"
        assert panel =~ "YOUR_PASSWORD"
        assert panel =~ "--obscure"
        assert panel =~ "rclone lsd #{remote}:"
      end
    end

    # The active platform is server state: a click switches the visible
    # panel and the copy button's payload together — one platform's
    # sequence, so a Windows visitor can't paste a bash line by accident.
    test "tab clicks switch the visible sequence and the copy value", %{
      conn: conn,
      user: user
    } do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      # Linux is the no-JS default: visible, the others wait hidden.
      refute has_element?(view, "[data-testid='dav-panel-linux'][hidden]")
      assert has_element?(view, "[data-testid='dav-panel-windows'][hidden]")
      assert has_element?(view, "[data-testid='dav-panel-macos'][hidden]")

      render_click(element(view, "[data-testid='dav-tab-windows']"))

      refute has_element?(view, "[data-testid='dav-panel-windows'][hidden]")
      assert has_element?(view, "[data-testid='dav-panel-linux'][hidden]")
      assert has_element?(view, "[data-testid='dav-tab-windows'][aria-selected='true']")

      copy =
        view
        |> element("[data-testid='copy-dav-snippet']")
        |> render()

      assert copy =~ "winget install Rclone.Rclone"
      refute copy =~ "brew install rclone"
      refute copy =~ "curl https://rclone.org/install.sh"
    end

    # #253: the OS-detected default. The .DavOsDefault hook pushes the
    # browser's platform string once on mount and the server maps it
    # (guess_platform/1 — unit-tested against representative agents);
    # render_hook stands in for the client's push.
    test "the visitor's OS becomes the default tab", %{conn: conn, user: user} do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      # The hook must ride the panel as the colocated registry's
      # QUALIFIED name — the compiler rewrites a literal `.Name` only,
      # so a dynamic phx-hook expression would ship unrewritten and the
      # detection would never fire in a real browser (hostile-pass
      # finding; this pins the rewrite happened).
      assert has_element?(
               view,
               ~s(#dav-snippet[phx-hook='FluxValeWeb.InstanceLive.DavSnippet.DavOsDefault'])
             )

      render_hook(view, "detect-dav-platform", %{"platform" => "Win32"})

      refute has_element?(view, "[data-testid='dav-panel-windows'][hidden]")
      assert has_element?(view, "[data-testid='dav-panel-linux'][hidden]")
    end

    test "an unrecognized platform string keeps the Linux default", %{conn: conn, user: user} do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_hook(view, "detect-dav-platform", %{"platform" => "Android"})

      refute has_element?(view, "[data-testid='dav-panel-linux'][hidden]")
    end

    # Detection assists, never traps: an explicit tab click locks the
    # choice, so a late-arriving detection push can't yank it away.
    test "detection never overrides an explicit tab choice", %{conn: conn, user: user} do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid='dav-tab-macos']"))
      render_hook(view, "detect-dav-platform", %{"platform" => "Win32"})

      refute has_element?(view, "[data-testid='dav-panel-macos'][hidden]")
      assert has_element?(view, "[data-testid='dav-panel-windows'][hidden]")
    end

    # A stale view's click can carry anything in phx-value — an
    # unrecognized platform keeps the current tab instead of crashing.
    test "a stale tab value keeps the current tab", %{conn: conn, user: user} do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid='dav-tab-windows']"), %{"platform" => "dos"})

      refute has_element?(view, "[data-testid='dav-panel-linux'][hidden]")
    end

    test "no panel for an instance without file access", %{conn: conn, user: user} do
      version = InstanceFixtures.app_version!()
      instance = create_instance!(version, user)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      refute has_element?(view, "[data-testid='file-access-panel']")
    end

    # #196: the sidecar, route, and credential Secret die with the
    # namespace — a :lost row must not advertise an address book whose
    # reveal can only fail. Re-deploy mints a fresh credential.
    test "no panel for a :lost instance — the namespace and its Secret are gone", %{
      conn: conn,
      user: user
    } do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      pending = create_instance!(version, user)

      running = InstanceFixtures.walk_to!(pending, :running)

      {:ok, lost} = InstanceK8s.update_status(running, :lost, "Namespace gone from cluster")

      {:ok, view, _html} = live(conn, ~p"/instances/#{lost.id}")

      refute has_element?(view, "[data-testid='file-access-panel']")
    end

    # 0 GB is an ordinary wizard outcome — the deploy side lands no
    # sidecar, so the page must not advertise an endpoint (review finding).
    test "no panel for a file-access instance with no storage", %{conn: conn, user: user} do
      version = InstanceFixtures.app_version!(file_access: true)

      instance =
        Instance.create!(
          %{
            name: "Zero Storage",
            app_version_id: version.id,
            env_vars: %{},
            storage_gb: 0
          },
          actor: user
        )

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      refute has_element?(view, "[data-testid='file-access-panel']")
    end

    test "reveal reads the credential live from the namespace Secret", %{conn: conn, user: user} do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)

      running =
        instance
        |> InstanceFixtures.walk_to!(:running)
        |> InstanceFixtures.pin!(namespace: "fluxvale-app-#{instance.id}")

      ns = "fluxvale-app-#{instance.id}"

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      expect(Secret, :get_data, fn _kc, ^ns, "file-access" ->
        {:ok, %{"RCLONE_USER" => "fluxvale", "RCLONE_PASS" => "s3cret"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/instances/#{running.id}")

      assert has_element?(view, "[data-testid='reveal-credentials']")
      reveal = element(view, "[data-testid='reveal-credentials']")
      render_click(reveal)

      assert has_element?(view, "[data-testid='dav-password']", "s3cret")
    end

    test "reveal before the first deploy flashes instead of crashing", %{conn: conn, user: user} do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      reveal = element(view, "[data-testid='reveal-credentials']")
      render_click(reveal)

      assert render(view) =~ "Deploy the instance first"
      refute has_element?(view, "[data-testid='dav-password']")
    end

    test "reveal on a cluster hiccup flashes the retry copy", %{conn: conn, user: user} do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)

      running =
        instance
        |> InstanceFixtures.walk_to!(:running)
        |> InstanceFixtures.pin!(namespace: "fluxvale-app-#{instance.id}")

      stub(K8s, :kubeconfig, fn nil -> {:error, K8s.Error.connection_error("down")} end)

      {:ok, view, _html} = live(conn, ~p"/instances/#{running.id}")

      reveal = element(view, "[data-testid='reveal-credentials']")
      render_click(reveal)

      assert render(view) =~ "Credential unavailable"
    end

    test "a stopped instance hints the endpoint is down", %{conn: conn, user: user} do
      version = InstanceFixtures.app_version!(file_access: true, default_storage_gb: 10)
      instance = create_instance!(version, user)
      stopped = InstanceFixtures.walk_to!(instance, :stopped)

      {:ok, view, _html} = live(conn, ~p"/instances/#{stopped.id}")

      assert has_element?(view, "[data-testid='file-access-panel']")
      assert render(view) =~ "endpoint is down while the instance is stopped"
    end
  end
end
