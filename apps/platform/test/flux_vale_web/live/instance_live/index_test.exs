defmodule FluxValeWeb.InstanceLive.IndexTest do
  @moduledoc false

  # The list surface (#74): owner-scoped rows, streamed, live via the
  # instances:<id> broadcasts. No K8s here — the reconciler's funnel is
  # a DB write, and its notification is what the view rides.

  use FluxValeWeb.ConnCase, async: true

  import FluxVale.TestSupport.NoK8sLeaks
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

  # The chrome's active-nav mechanism, end to end: NavSection's on_mount
  # (router-pinned on the authenticated live_session) resolves the
  # section, the view passes it through, and exactly the section's link
  # carries the round-3 amber underline.
  test "the chrome marks Instances active and its siblings quiet", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/instances")

    class_by_label =
      html
      |> LazyHTML.from_fragment()
      # The header's own links: the user menu's folded rows hang deeper
      # inside this nav (li > details), so the selector stays shallow.
      |> LazyHTML.query("nav[aria-label='Primary'] > ul > li > a")
      |> Enum.map(fn link ->
        text =
          link
          |> LazyHTML.text()
          |> String.trim()

        class =
          link
          |> LazyHTML.attribute("class")
          |> List.first()

        {text, class}
      end)
      |> Map.new()

    assert class_by_label["Instances"] =~ "after:bg-focus"
    # Exact token, not a substring (text-ink ⊂ text-ink-muted).
    assert "text-ink" in String.split(class_by_label["Instances"], " ")
    refute class_by_label["Catalog"] =~ "after:bg-focus"
    refute class_by_label["Billing"] =~ "after:bg-focus"
  end

  test "a status broadcast updates the row in place — app name intact", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    app = Ash.load!(version, :app, authorize?: false).app

    {:ok, view, html} = live(conn, ~p"/instances")

    assert has_element?(view, "[data-testid=status-badge]", "Submitted")

    assert has_element?(
             view,
             "[data-testid='instance-status-message']",
             "setup will begin shortly"
           )

    assert html =~ app.name

    # A real system write (the reconciler's funnel) — the notification's
    # record carries no loaded relationships, so the view reloads the
    # row's app before re-streaming.
    running = InstanceFixtures.walk_to!(instance, :running)
    InstanceK8s.update_status(running, :running, "All replicas ready")

    updated_html = render(view)

    assert has_element?(view, "[data-testid=status-badge]", "Running")
    assert has_element?(view, "#instances-#{running.id}", running.slug)
    assert updated_html =~ app.name
    # #179: settled rows are quiet — the raw status_message ("All
    # replicas ready") never renders, and running rows carry no
    # message line at all.
    refute updated_html =~ "All replicas ready"
    refute has_element?(view, "#instances-#{running.id} [data-testid='instance-status-message']")
    refute_k8s_terms(updated_html)
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

  # #179: a failed deploy's row shows the friendly failure copy — the
  # verbatim operator message stays on the row, never in the list.
  test "an errored instance lists friendly failure copy, no operator detail", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    deployed = InstanceFixtures.walk_to!(instance, :running)

    InstanceK8s.update_status(
      deployed,
      :error,
      "Deploy failed: resourcequotas is forbidden: User system:serviceaccount cannot create",
      :deploy_failed
    )

    {:ok, view, html} = live(conn, ~p"/instances")

    assert has_element?(view, "#instances-#{instance.id}", "Failed")
    assert has_element?(view, "[data-testid='instance-status-message']", "We hit a snag")
    refute html =~ "resourcequotas"
    refute_k8s_terms(html)
  end

  # #196: the list row says the loss out loud — a lost instance is not a
  # settled quiet state like running/stopped.
  test "a lost instance lists the billing-stopped copy", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    deployed = InstanceFixtures.walk_to!(instance, :running)

    InstanceK8s.update_status(deployed, :lost, "Namespace gone from cluster")

    {:ok, view, html} = live(conn, ~p"/instances")

    assert has_element?(view, "#instances-#{instance.id}", "Lost")

    assert has_element?(
             view,
             "[data-testid='instance-status-message']",
             "billing has been stopped"
           )

    refute_k8s_terms(html)
  end

  # A :restoring row's row-language contract: the badge speaks, the
  # message line does NOT — :restoring is deliberately outside the
  # explicit copy list (ADR-0037: the state owns the show page; the
  # row's job is the badge). Pins the exclusion so a predicate polarity
  # flip can't silently add the app's longest copy back (hostile-339 F1).
  test "a restoring row shows the badge only — no status message", %{
    conn: conn,
    user: user,
    version: version
  } do
    instance = create_instance!(version, user)
    deployed = InstanceFixtures.walk_to!(instance, :running)

    InstanceK8s.update_status(deployed, :restoring, nil)

    {:ok, view, html} = live(conn, ~p"/instances")

    assert has_element?(view, "#instances-#{instance.id}", "Restoring")
    refute has_element?(view, "#instances-#{instance.id} [data-testid='instance-status-message']")
    refute html =~ "putting one of your backups back in place"
  end

  # #179's status tick on the list: re-streams in-flight rows without
  # any broadcast, and drops tracking for rows that left the stream.
  test "the status tick re-streams in-flight rows and ignores settled ones", %{
    conn: conn,
    user: user,
    version: version
  } do
    in_flight = create_instance!(version, user)
    settled = create_instance!(version, user)
    deploying = InstanceFixtures.walk_to!(in_flight, :deploying)
    InstanceFixtures.walk_to!(settled, :running)

    # Mount after the writes — the tick is the only thing that can move
    # the in-flight row's derived copy now.
    {:ok, view, _html} = live(conn, ~p"/instances")

    assert has_element?(view, "#instances-#{deploying.id}", "Provisioning")

    # A broadcast landing in-flight exercises the tracking put arm.
    InstanceK8s.update_status(deploying, :starting, nil)

    send(view.pid, :status_tick)

    html = render(view)

    assert has_element?(view, "#instances-#{deploying.id}", "Starting")
    assert has_element?(view, "[data-testid='instance-status-message']", "Starting it up")
    assert has_element?(view, "#instances-#{settled.id}", "Running")
    refute_k8s_terms(html)

    # A destroyed row leaves the stream; its id survives in the tick's
    # tracking until the next tick's read miss drops it — no crash.
    Instance.delete(deploying.id, actor: user)

    send(view.pid, :status_tick)

    refute has_element?(view, "#instances-#{deploying.id}")
    assert has_element?(view, "#instances-#{settled.id}", "Running")
  end
end
