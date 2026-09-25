defmodule FluxValeWeb.InstanceLive.IndexTest do
  @moduledoc false

  # The list surface (#74): owner-scoped rows, streamed, live via the
  # instances:<id> broadcasts. No K8s here — the reconciler's funnel is
  # a DB write, and its notification is what the view rides.

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

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

  test "lists only the actor's instances", %{conn: conn, user: user, version: version} do
    mine = create_instance!(version, user)

    other = SessionHelpers.user!()
    theirs = create_instance!(version, other)

    {:ok, view, _html} = live(conn, ~p"/instances")

    assert has_element?(view, "#instances-#{mine.id}", mine.name)
    refute has_element?(view, "#instances-#{theirs.id}")
  end

  test "the empty state renders when there are none", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/instances")

    assert html =~ "No instances yet"
  end

  test "a status broadcast updates the row in place — app name intact", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    app = Ash.load!(version, :app, authorize?: false).app

    {:ok, view, html} = live(conn, ~p"/instances")

    assert html =~ "pending"
    assert html =~ app.name

    # A real system write (the reconciler's funnel) — the notification's
    # record carries no loaded relationships, so the view reloads the
    # row's app before re-streaming.
    running = InstanceFixtures.walk_to!(instance, :running)
    InstanceK8s.update_status(running, :running, "Ready")

    updated_html = render(view)

    assert updated_html =~ "running"
    assert has_element?(view, "#instances-#{running.id}", running.slug)
    assert updated_html =~ app.name
    assert updated_html =~ "Ready"
  end

  test "a trailing update broadcast for a deleted row is a no-op", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    {:ok, view, _html} = live(conn, ~p"/instances")

    Instance.delete(instance.id, actor: user)

    # The exact interleaving the re-read exists for: an update_status
    # notification for a row teardown already deleted. The destroy
    # clause handles the page exit; this arm must not raise.
    notification = %Ash.Notifier.Notification{
      resource: Instance,
      action: %{name: :update_status},
      data: instance
    }

    Phoenix.PubSub.broadcast(FluxVale.PubSub, "instances:#{instance.id}", notification)

    refute has_element?(view, "#instances-#{instance.id}")
  end

  test "a destroy broadcast removes the row", %{conn: conn, user: user, version: version} do
    instance = create_instance!(version, user)
    {:ok, view, _html} = live(conn, ~p"/instances")

    # Never deployed — delete hard-deletes synchronously; the destroy
    # notification is the delete path's own broadcast.
    Instance.delete(instance.id, actor: user)

    html = render(view)

    refute has_element?(view, "#instances-#{instance.id}")
    assert html =~ "No instances yet"
  end
end
