defmodule FluxValeWeb.InstanceLive.ShowTest do
  @moduledoc false

  # The status surface (#74): state, URL, lifecycle controls, and the
  # broadcast-driven updates. deploy/stop/start run against stubbed K8s
  # (Oban inline executes the deploy trigger synchronously); teardown's
  # exit is driven by a direct broadcast (its K8s choreography is #73's
  # contract, asserted there).

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Clients.K8s

  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service

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

    assert has_element?(view, ".badge", "pending")
    assert html =~ "#{instance.slug}.fluxvale.lvh.me"
    assert has_element?(view, "button[phx-click='deploy']", "Deploy")
    assert has_element?(view, "button[phx-click='delete']")
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

    assert has_element?(view, ".badge", "starting")
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

    assert has_element?(view, ".badge", "stopped")

    view
    |> element("button[phx-click='start']")
    |> render_click()

    assert has_element?(view, ".badge", "starting")
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
    assert has_element?(view, ".badge", "running")
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
    assert has_element?(view, ".badge", "stopped")
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

    assert has_element?(view, ".badge", "deleting")
    assert html =~ "Tearing down"
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

    assert has_element?(view, ".badge", "running")
    assert html =~ "All replicas ready"
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
    assert has_element?(view, ".badge", "pending")
    refute html =~ "isn&#39;t possible"
  end
end
