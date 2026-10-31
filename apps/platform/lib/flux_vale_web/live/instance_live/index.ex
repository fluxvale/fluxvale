defmodule FluxValeWeb.InstanceLive.Index do
  @moduledoc """
  The actor's instances (#74): owner-scoped read, streamed, live status
  via the instances:<id> broadcasts (Ash.Notifier.PubSub on Instance) —
  no polling, no full refetch.

  One exception to "no polling" (#179): a lingering provision writes
  nothing (a reconcile no-op doesn't broadcast), so a status tick
  re-streams in-flight rows while any exist — otherwise the
  taking-longer copy could never land on an open list. Creates in
  another tab ride that same refresh; with nothing in-flight, remount
  remains the only way creates appear.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Infrastructure.Instance
  alias FluxValeWeb.InstanceStatus

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    instances =
      Instance
      |> Ash.Query.for_read(:list_for_actor, %{}, actor: socket.assigns.current_user)
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.load(app_version: :app)
      |> Ash.read!()

    in_flight_ids = in_flight_ids(instances)

    socket =
      socket
      |> stream(:instances, instances)
      |> assign(:instance_count, length(instances))
      |> assign(:in_flight_ids, in_flight_ids)
      |> assign(:tick_scheduled?, false)
      |> subscribe(instances)

    {:ok, maybe_schedule_status_tick(socket, in_flight_ids)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      actor_orgs={@actor_orgs}
      personal_org_id={@personal_org_id}
      username={@username}
      nav_section={@nav_section}
      bare
    >
      <%!-- App-wide grammar page (S6): `bare` main + .appgram — the page
      owns ALL of main's rhythm (no max-w, no padding), same posture as
      the dashboard and the instance show. List pages stay calm: the
      sunken band carries the page title, no straddle. --%>
      <div class="appgram contents">
        <%!-- 1. The sunken band header: page title on the working-page
        type scale + the scope eyebrow (the read spans every org the
        actor belongs to). The Deploy CTA keeps its destination; it
        rides the dashboard header's posture. --%>
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise flex flex-wrap items-end justify-between gap-x-6 gap-y-4">
              <div class="min-w-0">
                <p class="eyebrow">All organizations</p>
                <h1 class="page-title mt-1.5">Instances</h1>
              </div>

              <div class="flex shrink-0 gap-2">
                <.button navigate={~p"/apps"}>
                  Deploy an app
                </.button>
              </div>
            </div>
          </div>
        </section>

        <%!-- 2. The rows in the S4 row language (dashboard_live.ex is
        the reference — same chip, name+slug, app/version, badge, rest
        step, and the same hit-box split: the link's own box stays put,
        an inner wrapper lifts motion-safe). The .rise wraps the
        section's content container — the empty state and the stream
        container — never the rows themselves: stream patches rewrite
        rows in place, and a rise on patched nodes would replay the
        reveal on every broadcast (node identity). --%>
        <section class="wrap pt-14 pb-16">
          <div class="rise space-y-4 [animation-delay:170ms]">
            <.empty_state :if={@instance_count == 0} title="No instances yet">
              Deploy your first app from the catalog.
            </.empty_state>

            <div id="instances" phx-update="stream" class="space-y-3">
              <.link
                :for={{dom_id, instance} <- @streams.instances}
                navigate={~p"/instances/#{instance.id}"}
                id={dom_id}
                data-testid="instance-row"
                class="group relative block rounded-panel border border-line-strong bg-panel p-4 shadow-sm outline-offset-2 outline-focus focus-visible:outline-2 transition-[box-shadow] duration-(--motion-base) ease-(--motion-ease-out) hover:shadow-md sm:p-5"
              >
                <div class="grid grid-cols-[auto_minmax(0,1fr)] items-center gap-x-4 gap-y-2 transition-[translate] duration-(--motion-base) ease-(--motion-ease-out) motion-safe:group-hover:-translate-y-1 sm:grid-cols-[auto_minmax(0,1fr)_auto_auto]">
                  <span
                    aria-hidden="true"
                    class="grid size-9 place-items-center rounded-panel border border-primary/25 bg-primary-muted font-mono text-xs font-semibold text-link"
                  >
                    {monogram(instance.name)}
                  </span>

                  <div class="min-w-0 space-y-0.5">
                    <%!-- Rows are H2: the page title IS this section's
                    heading (no separate H2 here), so H3 rows would skip
                    a level under the H1. --%>
                    <h2 class="min-w-0 text-base font-medium text-ink transition-colors duration-(--motion-fast) [overflow-wrap:anywhere] group-hover:text-link">
                      {instance.name}
                    </h2>
                    <p class="truncate font-mono text-xs text-ink-subtle">{instance.slug}</p>
                    <%!-- #179: friendly copy only — raw status_message
                    never renders here. copy_status? is the EXPLICIT
                    positive list, NOT the dashboard's noisy? predicate:
                    :restoring is deliberately excluded (ADR-0037 — the
                    state owns the show page, the row's job is the
                    badge), and the predicate's polarity would silently
                    add it (its copy is the app's longest; a flip is a
                    behavior change, hostile-339 F1). --%>
                    <p
                      :if={copy_status?(instance.status)}
                      class="truncate text-xs text-ink-subtle"
                      data-testid="instance-status-message"
                    >
                      {InstanceStatus.message(instance)}
                    </p>
                  </div>

                  <div class="col-start-2 row-start-2 flex items-center gap-3 sm:col-start-3 sm:row-start-1">
                    <%!-- min-w-0 truncate: the cluster's flex item must be
                    allowed to shrink — a long single-token app name
                    otherwise blows the auto column out and paints the
                    badge outside the row (the org home's measured ~199px
                    overflow at 375; hostile-339 F2). --%>
                    <span class="min-w-0 truncate text-sm text-ink-muted">
                      {instance.app_version.app.name}
                      <span class="ml-1 font-mono text-xs text-ink-subtle">
                        v{instance.app_version.version}
                      </span>
                    </span>
                    <.status_badge status={instance.status} />
                  </div>

                  <%!-- In-flow grid cell (vs the old absolute right-1
                  top-5): always occupying the cell is what keeps the
                  message column's measure stable, and items-center on the
                  cell answers the old top-5 calibration — the reveal
                  centers on the row's full height instead of pinning to a
                  first line that moves on two-line rows, so there is no
                  collision to tune away. It rides no translate: the
                  wrapper's lift moves the content, and a moving chevron
                  under a stationary pointer is the dead-band bug the
                  hit-box split exists to prevent. --%>
                  <.icon
                    name="hero-chevron-right"
                    class="hidden size-4 text-ink-subtle opacity-0 transition-[opacity] duration-(--motion-base) ease-(--motion-ease-out) group-hover:opacity-100 group-focus-visible:opacity-100 sm:col-start-4 sm:row-start-1 sm:block"
                  />
                </div>
              </.link>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  # Teardown's hard delete — the row leaves the stream.
  def handle_info(
        %Ash.Notifier.Notification{action: %{name: :destroy}} = notification,
        socket
      ) do
    socket =
      socket
      |> stream_delete(:instances, notification.data)
      |> assign(:instance_count, socket.assigns.instance_count - 1)

    {:noreply, socket}
  end

  # Re-read the row on broadcast (the DB is the one ordering that can't
  # lie — a trailing notification can predate fresher writes) and
  # re-stream it loaded: the row template renders the app name.
  def handle_info(%Ash.Notifier.Notification{data: %{id: id}}, socket) do
    case Instance.get_by_id(id, actor: socket.assigns.current_user) do
      {:ok, instance} ->
        instance = Ash.load!(instance, [app_version: :app], actor: socket.assigns.current_user)

        ids = track_in_flight(socket.assigns.in_flight_ids, instance)

        socket =
          socket
          |> assign(:in_flight_ids, ids)
          |> stream_insert(:instances, instance)
          # A broadcast landing in-flight may be the first (mounted
          # with nothing in-progress) — the tick needs starting.
          |> maybe_schedule_status_tick(ids)

        {:noreply, socket}

      _error ->
        # Destroy races land here too — the destroy clause handles the
        # page exit; the row leaves via stream_delete there.
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  # #179's status tick: a lingering provision writes nothing, so this is
  # what re-streams in-flight rows (fresh clock → taking-longer copy).
  # Settled rows stop the tick.
  def handle_info(:status_tick, socket) do
    unscheduled = assign(socket, :tick_scheduled?, false)

    {refreshed, still_ids} = refresh_in_flight(unscheduled, unscheduled.assigns.in_flight_ids)

    {:noreply,
     refreshed
     |> assign(:in_flight_ids, still_ids)
     |> maybe_schedule_status_tick(still_ids)}
  end

  # The row chip's mark (S4's reference rows): the name's first two
  # GRAPHEMES, uppercased — String.graphemes, not String.slice, so a
  # multi-codepoint glyph (emoji, combining accent) is never split.
  defp monogram(name) do
    name
    |> String.graphemes()
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  # The statuses whose row carries the #179 friendly copy line — the
  # EXPLICIT positive list, not a negation: :restoring is deliberately
  # excluded (ADR-0037 — the state owns the show page, the row's job is
  # the badge) and a negative predicate's polarity would silently add it
  # (its copy is the app's longest; a flip is a behavior change,
  # hostile-339 F1).
  defp copy_status?(status),
    do: status in [:pending, :deploying, :starting, :error, :deleting, :lost]

  defp subscribe(socket, instances) do
    Enum.reduce(instances, socket, fn instance, socket ->
      Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")
      socket
    end)
  end

  # The tick's tracking set — plain ids, not the stream (streams aren't
  # enumerable; the assign holds only what the tick re-reads).
  defp in_flight_ids(instances) do
    instances
    |> Enum.filter(&InstanceStatus.in_progress?(&1.status))
    |> Enum.map(& &1.id)
  end

  defp refresh_in_flight(socket, ids) do
    Enum.reduce(ids, {socket, []}, fn id, acc ->
      refresh_one(socket, id, acc)
    end)
  end

  # One tracked row: re-streamed either way (a settle whose broadcast
  # hasn't landed still deserves the fresher copy), tracked only while
  # still in-flight. A read miss (row torn down mid-tick) is the
  # destroy broadcast's job.
  defp refresh_one(socket, id, {acc_socket, still}) do
    case Instance.get_by_id(id, actor: socket.assigns.current_user) do
      {:ok, instance} ->
        instance = Ash.load!(instance, [app_version: :app], actor: socket.assigns.current_user)
        next_socket = stream_insert(acc_socket, :instances, instance)

        if InstanceStatus.in_progress?(instance.status) do
          {next_socket, [id | still]}
        else
          {next_socket, still}
        end

      _error ->
        {acc_socket, still}
    end
  end

  defp track_in_flight(ids, instance) do
    if InstanceStatus.in_progress?(instance.status) do
      [instance.id | List.delete(ids, instance.id)]
    else
      List.delete(ids, instance.id)
    end
  end

  # One self-rescheduling tick while any row is in-flight — connected
  # only (the disconnected static render is thrown away).
  defp maybe_schedule_status_tick(socket, in_flight_ids) do
    if connected?(socket) and in_flight_ids != [] and not socket.assigns.tick_scheduled? do
      interval = InstanceStatus.slow_after_seconds() * 1000
      Process.send_after(self(), :status_tick, interval)
      assign(socket, :tick_scheduled?, true)
    else
      socket
    end
  end
end
