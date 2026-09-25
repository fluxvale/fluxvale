defmodule FluxValeWeb.InstanceLive.Show do
  @moduledoc """
  The instance status surface (#74): state, message, URL, and lifecycle
  controls — the M3 exit demo's stage. Updates land live via the
  instances:<id> broadcasts (no polling); buttons fire the code-interface
  actions and the broadcast refreshes the view — no optimistic state.

  The :destroy broadcast (teardown's hard delete) is the exit: the row
  no longer exists to re-read, so the view confirms and navigates home.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Infrastructure.Instance

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Instance.get_by_id(id, actor: user) do
      {:ok, instance} ->
        instance = Ash.load!(instance, [app_version: :app], actor: user)

        Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")

        {:ok, assign(socket, :instance, instance)}

      _error ->
        # Someone else's instance reads as not-found (owner policy);
        # unknown ids are the same surface.
        {:ok,
         socket
         |> put_flash(:error, "Instance not found.")
         |> push_navigate(to: ~p"/instances")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="space-y-6">
        <div>
          <.link navigate={~p"/instances"} class="btn btn-ghost btn-sm mb-4">
            &larr; Instances
          </.link>

          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="flex items-center gap-3">
              <h1 class="text-3xl font-bold tracking-tight">{@instance.name}</h1>
              <.status_badge status={@instance.status} />
            </div>
            <div class="flex gap-2">
              <.action_buttons instance={@instance} />
            </div>
          </div>

          <p class="font-mono text-sm opacity-60 mt-1">
            {instance_url(@instance)}
          </p>
        </div>

        <div class="card bg-base-200">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">Status</h2>
            <p :if={@instance.status_message} class="text-sm opacity-80" id="status-message">
              {@instance.status_message}
            </p>
            <p :if={is_nil(@instance.status_message)} class="text-sm opacity-60">
              {@instance.status}
            </p>

            <%= if @instance.status in [:deploying, :starting] do %>
              <div class="flex items-center gap-2 text-sm opacity-70">
                <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
                Kubernetes is converging — this page updates on its own.
              </div>
            <% end %>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">Details</h2>
            <div class="grid gap-3 sm:grid-cols-2 text-sm">
              <div class="flex justify-between sm:block">
                <span class="opacity-60">App</span>
                <span>{@instance.app_version.app.name}</span>
              </div>
              <div class="flex justify-between sm:block">
                <span class="opacity-60">Version</span>
                <span class="font-mono">v{@instance.app_version.version}</span>
              </div>
              <div class="flex justify-between sm:block">
                <span class="opacity-60">Image</span>
                <span class="font-mono text-xs truncate">{@instance.image}</span>
              </div>
              <div class="flex justify-between sm:block">
                <span class="opacity-60">Namespace</span>
                <span class="font-mono text-xs">{@instance.namespace || "—"}</span>
              </div>
              <div class="flex justify-between sm:block">
                <span class="opacity-60">Resources</span>
                <span>
                  {@instance.cpu_cores} CPU · {@instance.memory_mb} MB · {@instance.storage_gb} GB
                </span>
              </div>
              <div class="flex justify-between sm:block">
                <span class="opacity-60">Created</span>
                <span>{Calendar.strftime(@instance.created_at, "%b %d, %Y %H:%M UTC")}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Lifecycle controls gated by the state machine's legal transitions —
  # the actions enforce the same, this is presentation.
  defp action_buttons(assigns) do
    ~H"""
    <button
      :if={@instance.status in [:pending, :error]}
      type="button"
      phx-click="deploy"
      class="btn btn-primary btn-sm"
    >
      <%= if @instance.status == :error do %>
        Retry deploy
      <% else %>
        Deploy
      <% end %>
    </button>

    <a
      :if={@instance.status == :running}
      href={instance_url(@instance)}
      target="_blank"
      rel="noopener"
      class="btn btn-primary btn-sm"
    >
      Open <span aria-hidden="true">&rarr;</span>
    </a>

    <button
      :if={@instance.status == :running}
      type="button"
      phx-click="stop"
      class="btn btn-ghost btn-sm"
    >
      Stop
    </button>

    <button
      :if={@instance.status == :stopped}
      type="button"
      phx-click="start"
      class="btn btn-primary btn-sm"
    >
      Start
    </button>

    <button
      :if={@instance.status != :deleting}
      type="button"
      phx-click="delete"
      data-confirm="Delete this instance and all its data? This cannot be undone."
      class="btn btn-error btn-outline btn-sm"
    >
      Delete
    </button>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("deploy", _params, socket) do
    # Non-bang + case: an in-flight second click (or any stale-view
    # event) hits the action's illegal-transition error — flash it,
    # don't crash; the next render's buttons match the true state.
    case Instance.deploy(socket.assigns.instance, actor: socket.assigns.current_user) do
      {:ok, _deploying} ->
        {:noreply, assign(socket, :instance, fetch(socket, socket.assigns.instance.id))}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Deploy isn't possible from this state.")}
    end
  end

  # stop/start return {:ok, instance} on the K8s paths — the row's
  # status carries the outcome (failure lands :error with the reason) —
  # but the action-level guards (stale-view double clicks) return
  # {:error, changeset}; both ride this case.
  def handle_event("stop", _params, socket) do
    handle_lifecycle(socket, &Instance.stop/2)
  end

  def handle_event("start", _params, socket) do
    handle_lifecycle(socket, &Instance.start/2)
  end

  def handle_event("delete", _params, socket) do
    instance = socket.assigns.instance

    case Instance.delete(instance.id, actor: socket.assigns.current_user) do
      {:ok, updated} ->
        {:noreply, assign(socket, :instance, reload(updated, socket))}

      # coveralls-ignore-start - defensive: the action's error arms are
      # DB-level failures (the action handles every status shape)
      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Delete failed — try again.")}
        # coveralls-ignore-stop
    end
  end

  @impl Phoenix.LiveView
  # Teardown finished: the row is gone, nothing to re-read.
  def handle_info(%Ash.Notifier.Notification{action: %{name: :destroy}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Instance #{socket.assigns.instance.name} deleted.")
     |> push_navigate(to: ~p"/instances")}
  end

  # Re-read on every broadcast instead of trusting notification.data:
  # a notification can trail fresher writes (the deploy action's own
  # :deploying publish lands after the trigger's :starting under inline
  # testing; any interleaving is possible in prod) — the DB is the one
  # ordering that can't lie. A read miss means the row is already gone
  # (a trailing broadcast racing teardown) — keep the last state; the
  # :destroy clause handles the exit.
  def handle_info(%Ash.Notifier.Notification{data: %{id: id}}, socket) do
    case fetch(socket, id) do
      nil -> {:noreply, socket}
      instance -> {:noreply, assign(socket, :instance, instance)}
    end
  end

  defp instance_url(instance) do
    "https://#{instance.slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}/"
  end

  # nil on a read miss — see handle_info above.
  defp fetch(socket, id) do
    case Instance.get_by_id(id, actor: socket.assigns.current_user) do
      {:ok, instance} -> reload(instance, socket)
      _error -> nil
    end
  end

  defp handle_lifecycle(socket, action) do
    case action.(socket.assigns.instance, actor: socket.assigns.current_user) do
      {:ok, _instance} ->
        {:noreply, assign(socket, :instance, fetch(socket, socket.assigns.instance.id))}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "That action isn't possible from this state.")}
    end
  end

  # Action results and broadcast records carry no loaded relationships;
  # the page renders app name + version off the version's app.
  defp reload(instance, socket) do
    Ash.load!(instance, [app_version: :app], actor: socket.assigns.current_user)
  end
end
