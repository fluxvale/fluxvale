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
  alias FluxVale.Infrastructure.BackupRun
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
            dav_password: nil,
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
          <.button variant="ghost" size="sm" navigate={~p"/instances"} class="-ml-2 mb-4">
            &larr; Instances
          </.button>

          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="flex items-center gap-3">
              <h1 class="text-2xl font-semibold tracking-tight text-ink">{@instance.name}</h1>
              <.status_badge status={@instance.status} />
            </div>
            <div class="flex gap-2">
              <.action_buttons instance={@instance} />
            </div>
          </div>

          <p class="mt-1 font-mono text-sm text-ink-subtle" data-testid="instance-url">
            {instance_url(@instance)}
          </p>
        </div>

        <.card class="space-y-4">
          <h2 class="text-sm font-medium text-ink-muted">Status</h2>
          <%!-- #179: user-facing copy derived from the state machine —
          the raw status_message never renders to non-admins. --%>
          <p class="text-sm text-ink" id="status-message" data-testid="status-message">
            {InstanceStatus.message(@instance)}
          </p>

          <%= if InstanceStatus.in_progress?(@instance.status) do %>
            <div class="flex items-center gap-2 text-sm text-ink-subtle">
              <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
              This page updates on its own.
            </div>
          <% end %>
        </.card>

        <%!-- #203 (ADR-0036): the idle posture — auto-sleep is the
        default economics, always-on the premium opt-out. Billing tier
        rides the open sub-decision on #203; the flag is behavior. --%>
        <.card class="space-y-3" data-testid="availability-card">
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-sm font-medium text-ink-muted">Availability</h2>
            <span
              class={[
                "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium",
                if(@instance.always_on,
                  do: "border-line-success bg-success-muted text-success",
                  else: "border-line bg-primary-muted text-primary"
                )
              ]}
              data-testid="availability-mode"
            >
              {if(@instance.always_on, do: "Always on", else: "Sleeps when idle")}
            </span>
          </div>

          <p class="text-sm text-ink-subtle">
            <%= if @instance.always_on do %>
              Always-on instances never sleep, so they bill the full rate around the clock.
            <% else %>
              Apps sleep after an hour without visitors and wake on the next visit — you pay
              only storage while one sleeps.
            <% end %>
          </p>

          <.button
            size="sm"
            variant="ghost"
            phx-click="toggle-always-on"
            phx-value-always_on={to_string(not @instance.always_on)}
            data-testid="always-on-toggle"
          >
            {if(@instance.always_on, do: "Let it sleep when idle", else: "Keep always on (premium)")}
          </.button>
        </.card>

        <.callout
          :if={@instance.app_version.first_run}
          tone="info"
          title="First open"
          data-testid="first-run-guidance"
        >
          <p class="text-sm text-ink-muted">
            {@instance.app_version.first_run.guidance}
          </p>
        </.callout>

        <%!-- #222 (ADR-0037): the backups panel is a LiveComponent — it
        owns form/confirm/reveal state the page has no use for, and this
        page is shared hot ground. --%>
        <.live_component
          module={FluxValeWeb.InstanceLive.BackupsComponent}
          id="backups"
          instance={@instance}
          current_user={@current_user}
        />

        <%= if @instance.file_access do %>
          <%!-- #190 (ADR-0035): the WebDAV sidecar's address book — URL
          and username are config-shaped (no cluster read to render);
          the password reveal is a live Secret read, the credential's
          only home. Gated on storage too: the sidecar and its route
          land only when there's a volume to serve (deploy-side gate). --%>
          <.card
            :if={file_access_on?(@instance)}
            class="space-y-4"
            data-testid="file-access-panel"
          >
            <h2 class="text-sm font-medium text-ink-muted">File access (WebDAV)</h2>

            <%!-- #227: browsers GET, collections answer PROPFIND — a
            plain visit 405s. Name the client move before every new
            user repeats the owner's live dogfood mistake. --%>
            <p class="text-xs text-ink-subtle" data-testid="dav-client-hint">
              Open with a WebDAV client — browsers can't browse this
              endpoint (the "method not allowed" page is expected).
              Recommended: Cyberduck (macOS/Windows) · rclone to mount
              or script.
            </p>

            <%!-- #194: every credential value is a no-wrap code block with a
            copy button that carries the exact rendered string in a
            data-attribute. Selecting a wrapped 43-char password by hand
            (triple-click) catches the neighbouring label and the trailing
            newline, which is how a correct credential produced a 401. --%>
            <div class="grid gap-4 text-sm">
              <.dav_field
                label="Address"
                value={dav_url(@instance)}
                testid="dav-url"
                copy_label="Copy address"
              />

              <div class="grid gap-4 sm:grid-cols-2">
                <.dav_field
                  label="Username"
                  value={dav_username()}
                  testid="dav-username"
                  copy_label="Copy username"
                />

                <div class="grid gap-1.5">
                  <span class="text-ink-subtle">Password</span>
                  <%= if @dav_password do %>
                    <div class="flex items-start gap-2">
                      <code
                        class="min-w-0 flex-1 overflow-x-auto rounded-md border border-line bg-panel-raised px-2 py-1 font-mono text-xs whitespace-nowrap text-ink"
                        data-testid="dav-password"
                      >
                        {@dav_password}
                      </code>
                      <.copy_button
                        id="copy-dav-password"
                        value={@dav_password}
                        label="Copy password"
                      />
                    </div>
                  <% else %>
                    <.button
                      size="sm"
                      phx-click="reveal-credentials"
                      data-testid="reveal-credentials"
                    >
                      Show password
                    </.button>
                  <% end %>
                </div>
              </div>
            </div>

            <p class="text-xs text-ink-subtle">
              Mount it with rclone — parallel transfers, verified copies.
              Each file uploads whole, so keep files under 100 MB through
              this endpoint (larger library files are a coming phase):
            </p>

            <div class="space-y-2">
              <div class="flex items-center justify-between gap-2">
                <span class="text-xs font-medium text-ink-muted">rclone setup</span>
                <.copy_button
                  id="copy-dav-snippet"
                  value={rclone_snippet(@instance, @dav_password)}
                  testid="copy-dav-snippet"
                  label="Copy snippet"
                />
              </div>
              <%!-- #194: `--obscure` is load-bearing. rclone guesses whether a
              `pass` value is already obscured; the platform's 43-char
              base64url password is misread as obscured ~99% of the time, so
              the literal form uploaded garbage and 401'd. --obscure forces
              the plaintext reading. --%>
              <pre
                class="overflow-x-auto rounded-lg bg-panel-raised p-3 text-xs leading-relaxed text-ink-muted"
                phx-no-curly-interpolation
              ><code data-testid="dav-rclone-snippet"><%= rclone_snippet(@instance, @dav_password) %></code></pre>
            </div>

            <p :if={@instance.status == :stopped} class="text-xs text-ink-subtle">
              The endpoint is down while the instance is stopped — start it to
              upload.
            </p>

            <p :if={@instance.status == :sleeping} class="text-xs text-ink-subtle">
              The endpoint sleeps with the app — it wakes on the next upload
              attempt (retrying clients pick it up in a few seconds).
            </p>
          </.card>
        <% end %>

        <%= if @admin? do %>
          <%!-- #179's admin-only reveal: the full technical trail, in the
          clear, for staff. Everything a non-admin must not see on this
          page lives here. --%>
          <.card class="space-y-3 border-dashed border-line-strong">
            <h2 class="flex items-center gap-2 text-sm font-medium text-ink-muted">
              Technical details
              <.badge>admin</.badge>
            </h2>
            <div class="grid gap-1.5 font-mono text-xs text-ink-muted" data-testid="admin-technical">
              <p>
                status: <span class="text-ink" data-testid="admin-status">{@instance.status}</span>
              </p>
              <p>failure_reason: {@instance.failure_reason || "—"}</p>
              <p :if={@instance.status_message} class="break-words">
                message: {@instance.status_message}
              </p>
              <p :if={@instance.lost_detected_at} data-testid="admin-lost-detected-at">
                lost_detected_at: {DateTime.to_iso8601(@instance.lost_detected_at)}
              </p>
              <p>namespace: {@instance.namespace || "—"}</p>
              <p>image: {@instance.image}</p>
            </div>
          </.card>
        <% end %>

        <.card class="space-y-4">
          <h2 class="text-sm font-medium text-ink-muted">Details</h2>
          <div class="grid gap-4 text-sm sm:grid-cols-2">
            <div class="flex justify-between gap-4 sm:block">
              <span class="text-ink-subtle">App</span>
              <span class="text-ink">{@instance.app_version.app.name}</span>
            </div>
            <div class="flex justify-between gap-4 sm:block">
              <span class="text-ink-subtle">Version</span>
              <span class="font-mono text-ink">v{@instance.app_version.version}</span>
            </div>
            <%!-- #179: image + namespace rows moved to the admin-only
            technical card — non-admins never see cluster-identifying
            detail. --%>
            <div class="flex justify-between gap-4 sm:block">
              <span class="text-ink-subtle">Resources</span>
              <span class="text-ink">
                {@instance.cpu_cores} CPU · {@instance.memory_mb} MB · {@instance.storage_gb} GB
              </span>
            </div>
            <%= if size = @instance.app_version.recommended_size do %>
              <%!-- The version's recommended-size rate, not an
              accrual statement — settlement owns elapsed-time math
              (#121); :stopped swaps in the storage-only fee
              (ADR-0028 §2). KNOWN GAP (pre-existing shape, outside
              #206's scope; flagged as a follow-up in the closing
              PR's body): a custom-allocation instance bills its own
              formula snapshot (#186) while this row keeps showing
              the recommended size's cents. The label states
              monthly-equivalent · billed hourly on every surface
              (#206 — no monthly-billing ambiguity). --%>
              <div class="flex justify-between gap-4 sm:block">
                <span class="text-ink-subtle">Price</span>
                <span class="text-ink" data-testid="instance-price">
                  <%= if @instance.status in [:stopped, :sleeping] do %>
                    {FluxVale.Pricing.format_usd(size.stopped_monthly_cents)}/mo while {if(
                      @instance.status == :sleeping,
                      do: "asleep",
                      else: "stopped"
                    )} · billed hourly
                  <% else %>
                    {FluxVale.Pricing.format_monthly_rate(size.monthly_cents)}
                  <% end %>
                </span>
              </div>
            <% end %>
            <div class="flex justify-between gap-4 sm:block">
              <span class="text-ink-subtle">Created</span>
              <span class="text-ink">
                {Calendar.strftime(@instance.created_at, "%b %d, %Y %H:%M UTC")}
              </span>
            </div>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  # Lifecycle controls gated by the state machine's legal transitions —
  # the actions enforce the same, this is presentation.
  defp action_buttons(assigns) do
    ~H"""
    <.button
      :if={@instance.status in [:pending, :error, :lost]}
      size="sm"
      phx-click="deploy"
      data-testid="deploy-button"
    >
      <%= cond do %>
        <% @instance.status == :error -> %>
          Retry deploy
        <% @instance.status == :lost -> %>
          Re-deploy
        <% true -> %>
          Deploy
      <% end %>
    </.button>

    <.button
      :if={@instance.status in [:running, :sleeping]}
      size="sm"
      href={instance_url(@instance)}
      target="_blank"
      rel="noopener"
      data-testid="open-instance"
    >
      Open <span aria-hidden="true">&rarr;</span>
    </.button>

    <.button
      :if={@instance.status == :running}
      variant="ghost"
      size="sm"
      phx-click="stop"
      data-testid="stop-button"
    >
      Stop
    </.button>

    <%!-- #203: wake = start from :sleeping — the same action, the
    traffic-reversible verb; the edge wakes it for a visitor too. --%>
    <.button
      :if={@instance.status == :sleeping}
      size="sm"
      phx-click="wake"
      data-testid="wake-button"
    >
      Wake up
    </.button>

    <.button
      :if={@instance.status == :stopped}
      size="sm"
      phx-click="start"
      data-testid="start-button"
    >
      Start
    </.button>

    <.button
      :if={@instance.status != :deleting}
      variant="destructive"
      size="sm"
      phx-click="delete"
      data-confirm="Delete this instance and all its data? This cannot be undone."
      data-testid="delete-button"
    >
      Delete
    </.button>
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

  # #203: the Wake button — `start` with the sleeping-arc's verb. A
  # separate event so the copy and the flash stay honest ("wake" vs
  # "start"), the action identical.
  def handle_event("wake", _params, socket) do
    handle_lifecycle(socket, &Instance.start/2)
  end

  # #203 (ADR-0036): the always-on opt-out — a paid premium; the
  # billing tier is the open sub-decision on #203, the toggle is
  # behavior today (the idle sweep skips always-on rows).
  def handle_event("toggle-always-on", %{"always_on" => always_on} = _params, socket) do
    instance = socket.assigns.instance
    # phx-value strings in, booleans out — the attribute is boolean.
    always_on = always_on == "true"

    case Instance.set_always_on(instance, %{always_on: always_on},
           actor: socket.assigns.current_user
         ) do
      {:ok, updated} ->
        # "Never sleeps" said while the instance sleeps is a lie:
        # enabling always-on wakes a sleeping instance (the visitor's
        # next open would too — this just doesn't wait for one).
        socket =
          if always_on and updated.status == :sleeping do
            wake_on_enable(socket, updated)
          else
            assign(socket, :instance, reload(updated, socket))
          end

        {:noreply, socket}

      # coveralls-ignore-start - defensive: the action's error arm is a
      # DB-level failure; no deterministic test can stage one without a
      # backdoor (the delete handler's stance, same shape).
      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Couldn't change the availability setting.")}
        # coveralls-ignore-stop
    end
  end

  # #190: the password reveal — a live read of the namespace's
  # file-access Secret (the credential's only home, ADR-0035). The
  # mount's actor-authorized instance read is the ownership check; the
  # outcomes here are copy, not crash states.
  def handle_event("reveal-credentials", _params, socket) do
    case FluxVale.Infrastructure.read_file_access_credential(socket.assigns.instance) do
      {:ok, %{password: password}} ->
        {:noreply, assign(socket, :dav_password, password)}

      {:error, :not_deployed} ->
        {:noreply, put_flash(socket, :error, "Deploy the instance first — no credential yet.")}

      _unavailable ->
        {:noreply, put_flash(socket, :error, "Credential unavailable — try again shortly.")}
    end
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

  # A start error here still leaves the flag set and the row honest
  # (sleeping): the sweep skips it from now on, and any visitor's
  # request wakes it. Flash the outcome, don't crash.
  defp wake_on_enable(socket, sleeping) do
    case Instance.start(sleeping, actor: socket.assigns.current_user) do
      {:ok, waking} ->
        assign(socket, :instance, reload(waking, socket))

      # coveralls-ignore-start - the action-level error arm is the
      # stale-view race (the row moved between render and event); the
      # K8s path reports through status, not error tuples.
      {:error, _error} ->
        put_flash(socket, :error, "Always-on is set — open the app once to wake it now.")
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

  # #222: a backup run's writes ride this same topic (ADR-0037's
  # consequences — a run never touches Instance.status), so the panel is
  # told to re-read rather than the page re-reading the instance. The
  # notification's data is a run, not an instance: never feed it to
  # fetch/2.
  def handle_info(%Ash.Notifier.Notification{resource: BackupRun}, socket) do
    {:noreply, refresh_backups_panel(socket)}
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

  # The panel's own refresh: pass the assigns it already reads. The run
  # notification carries no instance, so the page keeps its row and pokes
  # the component instead.
  defp refresh_backups_panel(socket) do
    send_update(FluxValeWeb.InstanceLive.BackupsComponent,
      id: "backups",
      instance: socket.assigns.instance
    )

    socket
  end

  # The WebDAV endpoint (#190): same hostname, config-owned path prefix
  # — the same two config values the deploy op builds the route from,
  # so the shown address can't drift from the wired one.

  # One labeled credential value: a read-only, no-wrap code block plus
  # its copy button (#194). The value is never wrapped — a wrapped
  # 43-char password is what made hand-selection lossy.
  defp dav_field(assigns) do
    assigns = assign(assigns, :copy_id, "copy-#{assigns.testid}")

    ~H"""
    <div class="grid gap-1.5">
      <span class="text-ink-subtle">{@label}</span>
      <div class="flex items-start gap-2">
        <code
          class="min-w-0 flex-1 overflow-x-auto rounded-md border border-line bg-panel-raised px-2 py-1 font-mono text-xs whitespace-nowrap text-ink"
          data-testid={@testid}
        >
          {@value}
        </code>
        <.copy_button id={@copy_id} value={@value} label={@copy_label} />
      </div>
    </div>
    """
  end

  # The full rclone remote + copy command, password inlined when the
  # owner has revealed it (#194). `--obscure` is mandatory: see the
  # panel comment — without it rclone misreads the generated password.
  defp rclone_snippet(instance, password) do
    secret = password || "YOUR_PASSWORD"
    remote = "fluxvale-#{instance.slug}"

    snippet = """
    rclone config create #{remote} webdav \\
        url #{dav_url(instance)} vendor rclone user #{dav_username()} pass '#{secret}' --obscure
    rclone copy ~/library #{remote}:library --progress
    """

    String.trim_trailing(snippet)
  end

  # The panel's gate mirrors the deploy op's: the sidecar lands only for
  # a file-access instance WITH a volume to serve — at 0 GB there is no
  # endpoint, no secret, no route, so the page must not advertise one.
  defp file_access_on?(%{status: :lost}), do: false

  # #190 (ADR-0035): the sidecar, route, and credential Secret all live
  # in the instance namespace — when it vanished externally (#196's
  # :lost), the address book and the reveal are dead until re-deploy
  # mints a fresh one. Never render an affordance that cannot work.
  defp file_access_on?(%{file_access: true, storage_gb: gb}) when gb > 0, do: true
  defp file_access_on?(_instance), do: false

  defp dav_url(instance) do
    config = file_access_config()

    "https://#{instance.slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}#{config[:path_prefix]}"
  end

  defp dav_username, do: file_access_config()[:username]

  defp file_access_config do
    Application.fetch_env!(:flux_vale, :file_access)
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
