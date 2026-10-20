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

  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxVale.Infrastructure.Instance
  alias FluxValeWeb.InstanceStatus

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Instance.get_by_id(id, actor: user) do
      {:ok, instance} ->
        instance = Ash.load!(instance, [app_version: [:app, :recommended_size]], actor: user)

        Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")

        # #179: technical detail (raw status_message, namespace, image)
        # renders only for platform admins — one predicate, shared with
        # policy-land, so the notion can't fork.
        socket =
          assign(socket,
            instance: instance,
            admin?: ActorIsPlatformAdmin.platform_admin?(user),
            tick_scheduled?: false
          )

        {:ok, maybe_schedule_status_tick(socket)}

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

          <p class="font-mono text-sm opacity-60 mt-1" data-testid="instance-url">
            {instance_url(@instance)}
          </p>
        </div>

        <div class="card bg-base-200">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">Status</h2>
            <%!-- #179: user-facing copy derived from the state machine —
            the raw status_message never renders to non-admins. --%>
            <p class="text-sm opacity-80" id="status-message" data-testid="status-message">
              {InstanceStatus.message(@instance)}
            </p>

            <%= if InstanceStatus.in_progress?(@instance.status) do %>
              <div class="flex items-center gap-2 text-sm opacity-70">
                <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
                This page updates on its own.
              </div>
            <% end %>
          </div>
        </div>

        <%= if @admin? do %>
          <%!-- #179's admin-only reveal: the full technical trail, in the
          clear, for staff. Everything a non-admin must not see on this
          page lives here. --%>
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body gap-3">
              <h2 class="card-title text-base">
                Technical details <span class="badge badge-ghost badge-sm">admin</span>
              </h2>
              <div class="grid gap-2 text-xs font-mono" data-testid="admin-technical">
                <p>
                  status: <span data-testid="admin-status">{@instance.status}</span>
                </p>
                <p>failure_reason: {@instance.failure_reason || "—"}</p>
                <p :if={@instance.status_message} class="break-words">
                  message: {@instance.status_message}
                </p>
                <p>namespace: {@instance.namespace || "—"}</p>
                <p>image: {@instance.image}</p>
              </div>
            </div>
          </div>
        <% end %>

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
              <%!-- #179: image + namespace rows moved to the admin-only
              technical card — non-admins never see cluster-identifying
              detail. --%>
              <div class="flex justify-between sm:block">
                <span class="opacity-60">Resources</span>
                <span>
                  {@instance.cpu_cores} CPU · {@instance.memory_mb} MB · {@instance.storage_gb} GB
                </span>
              </div>
              <%= if size = @instance.app_version.recommended_size do %>
                <%!-- The instance's configured price, not an accrual
                statement — settlement owns elapsed-time math (#121).
                :stopped swaps in the storage-only fee (ADR-0028 §2). --%>
                <div class="flex justify-between sm:block">
                  <span class="opacity-60">Price</span>
                  <span data-testid="instance-price">
                    <%= if @instance.status == :stopped do %>
                      {FluxVale.Pricing.format_usd(size.stopped_monthly_cents)}/mo while stopped
                    <% else %>
                      {FluxVale.Pricing.format_usd(size.monthly_cents)}/mo
                    <% end %>
                  </span>
                </div>
              <% end %>
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
      data-testid="deploy-button"
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
      data-testid="open-instance"
    >
      Open <span aria-hidden="true">&rarr;</span>
    </a>

    <button
      :if={@instance.status == :running}
      type="button"
      phx-click="stop"
      class="btn btn-ghost btn-sm"
      data-testid="stop-button"
    >
      Stop
    </button>

    <button
      :if={@instance.status == :stopped}
      type="button"
      phx-click="start"
      class="btn btn-primary btn-sm"
      data-testid="start-button"
    >
      Start
    </button>

    <button
      :if={@instance.status != :deleting}
      type="button"
      phx-click="delete"
      data-confirm="Delete this instance and all its data? This cannot be undone."
      class="btn btn-error btn-outline btn-sm"
      data-testid="delete-button"
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
        {:noreply, refresh(socket, socket.assigns.instance.id)}

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
  # The taking-longer copy (#179) is render-time derived, and a
  # lingering provision writes nothing (a reconcile no-op doesn't
  # broadcast) — this tick is what re-renders an open page past the
  # slow threshold. Self-reschedules while in-progress; one timer max
  # (the flag guards double-scheduling from mount + broadcasts).
  def handle_info(:status_tick, socket) do
    socket = assign(socket, :tick_scheduled?, false)

    if InstanceStatus.in_progress?(socket.assigns.instance.status) do
      # maybe_schedule assigns → the socket changes → re-render with a
      # fresh clock evaluation.
      {:noreply, maybe_schedule_status_tick(socket)}
    else
      {:noreply, socket}
    end
  end

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
      # A broadcast landing in-progress may be the first (mounted on
      # :pending) — the tick needs starting.
      instance -> {:noreply, maybe_schedule_status_tick(assign(socket, :instance, instance))}
    end
  end

  defp instance_url(instance) do
    "https://#{instance.slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}/"
  end

  # One self-rescheduling tick while the instance is mid-provision —
  # connected only (the disconnected static render is thrown away).
  defp maybe_schedule_status_tick(socket) do
    instance = socket.assigns.instance

    if connected?(socket) and not socket.assigns.tick_scheduled? and
         InstanceStatus.in_progress?(instance.status) do
      interval = InstanceStatus.slow_after_seconds() * 1000
      Process.send_after(self(), :status_tick, interval)
      assign(socket, :tick_scheduled?, true)
    else
      socket
    end
  end

  # nil on a read miss — see handle_info above.
  defp fetch(socket, id) do
    case Instance.get_by_id(id, actor: socket.assigns.current_user) do
      {:ok, instance} -> reload(instance, socket)
      _error -> nil
    end
  end

  # The post-action refresh every success arm rides: assign the re-read,
  # or keep the last state on a read miss (the row was torn down between
  # the action and the fetch — assigning nil would crash the render; the
  # :destroy broadcast owns the exit).
  defp refresh(socket, id) do
    # coveralls-ignore-start - race window: the action succeeded but
    # teardown deleted the row before the re-read — the read-miss itself
    # is covered via handle_info's foreign-id broadcast test; landing
    # here needs a concurrent delete mid-event, which no deterministic
    # test can stage without a backdoor
    case fetch(socket, id) do
      nil -> socket
      instance -> maybe_schedule_status_tick(assign(socket, :instance, instance))
    end

    # coveralls-ignore-stop
  end

  defp handle_lifecycle(socket, action) do
    case action.(socket.assigns.instance, actor: socket.assigns.current_user) do
      {:ok, _instance} ->
        {:noreply, refresh(socket, socket.assigns.instance.id)}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "That action isn't possible from this state.")}
    end
  end

  # Action results and broadcast records carry no loaded relationships;
  # the page renders app name + version off the version's app, and the
  # ADR-0028 price off the version's recommended size.
  defp reload(instance, socket) do
    Ash.load!(instance, [app_version: [:app, :recommended_size]],
      actor: socket.assigns.current_user
    )
  end
end
