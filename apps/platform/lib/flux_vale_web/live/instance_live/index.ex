defmodule FluxValeWeb.InstanceLive.Index do
  @moduledoc """
  The actor's instances (#74): owner-scoped read, streamed, live status
  via the instances:<id> broadcasts (Ash.Notifier.PubSub on Instance) —
  no polling, no full refetch.

  Creates elsewhere (another tab) won't appear until remount — M3's
  surface is the status of what you can see; no create broadcast.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Infrastructure.Instance

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    instances =
      Instance
      |> Ash.Query.for_read(:list_for_actor, %{}, actor: socket.assigns.current_user)
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.load(app_version: :app)
      |> Ash.read!()

    socket =
      socket
      |> stream(:instances, instances)
      |> assign(:instance_count, length(instances))
      |> subscribe(instances)

    {:ok, socket}
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
              <p :if={instance.status_message} class="text-xs opacity-60 truncate">
                {instance.status_message}
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
        {:noreply, stream_insert(socket, :instances, instance)}

      _error ->
        # Destroy races land here too — the destroy clause handles the
        # page exit; the row leaves via stream_delete there.
        {:noreply, socket}
    end
  end

  defp subscribe(socket, instances) do
    Enum.reduce(instances, socket, fn instance, socket ->
      Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")
      socket
    end)
  end
end
