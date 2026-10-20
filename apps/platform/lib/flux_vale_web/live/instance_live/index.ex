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
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-3xl font-bold tracking-tight">Instances</h1>
          <.link navigate={~p"/apps"} class="btn btn-primary btn-sm">
            Deploy an app
          </.link>
        </div>

        <div :if={@instance_count == 0} class="card bg-base-200">
          <div class="card-body items-center text-center py-10">
            <p class="opacity-70">No instances yet — deploy your first app from the catalog.</p>
          </div>
        </div>

        <div id="instances" phx-update="stream" class="space-y-3">
          <.link
            :for={{dom_id, instance} <- @streams.instances}
            navigate={~p"/instances/#{instance.id}"}
            id={dom_id}
            data-testid="instance-row"
            class="card bg-base-200 hover:bg-base-300 transition-colors block"
          >
            <div class="card-body gap-2 py-4">
              <div class="flex flex-wrap items-center justify-between gap-3">
                <div class="flex items-center gap-3">
                  <h2 class="card-title text-base">{instance.name}</h2>
                  <span class="font-mono text-xs opacity-50">{instance.slug}</span>
                </div>
                <div class="flex items-center gap-3">
                  <span class="text-sm opacity-70">
                    {instance.app_version.app.name}
                    <span class="font-mono text-xs opacity-60">
                      v{instance.app_version.version}
                    </span>
                  </span>
                  <.status_badge status={instance.status} />
                </div>
              </div>
              <%!-- #179: friendly copy only — raw status_message never
              renders here. Quiet on settled states (running/stopped):
              the badge says enough. --%>
              <p
                :if={instance.status in [:pending, :deploying, :starting, :error, :deleting]}
                class="text-xs opacity-60 truncate"
                data-testid="instance-status-message"
              >
                {InstanceStatus.message(instance)}
              </p>
            </div>
          </.link>
        </div>
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
