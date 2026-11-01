defmodule FluxValeWeb.InstanceLive.BackupsComponent do
  @moduledoc """
  The instance page's backups panel (#222, ADR-0037): BYO-bucket setup,
  run history, the manual trigger, and the restore's two-step confirm.

  **The one sanctioned LiveComponent.** The panel owns state the page has
  no use for (an open settings form, a pending confirm, a revealed repo
  password) and `InstanceLive.Show` is a hot shared file — a component
  keeps that diff to one render call while the panel's own surface stays
  reviewable in one module.

  `update/2` re-reads the setting and the run history on every parent
  render instead of trusting a passed snapshot — the same "the DB is the
  one ordering that can't lie" stance `InstanceLive.Show` takes.

  A run's outcome never touches `Instance.status` (ADR-0037's
  consequences: app health and backup health are separate axes), so the
  `BackupRun` resource publishes its writes on the instance page's own
  topic and `show.ex` forwards them here as `send_update/3`. Live updates
  cost no polling and no timer: the page's existing subscription is the
  signal.

  Nothing secret renders by default: the access key id is masked to its
  last four characters — and the edit form never pre-fills it either, so
  opening the form isn't a credential render — and the repo password
  appears only behind an explicit reveal that reads the live Secret
  (ADR-0037 §4).
  """

  use FluxValeWeb, :live_component

  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorOrgHasPaid
  alias FluxVale.Checks.ActorOrgWalletFunded
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxValeWeb.PersonalOrg
  alias Phoenix.Component

  @runs_limit 20

  # The statuses each action can start from — the operations' own guards,
  # mirrored for presentation so no button offers a guaranteed failure.
  @backup_statuses [:running, :sleeping, :stopped]
  @restorable_statuses [:running, :sleeping, :stopped]

  # The form's fields. `enabled` is deliberately absent: pausing is the
  # summary's own switch, so the panel offers two off-verbs, not three.
  @form_fields ~w(endpoint bucket prefix access_key_id secret_access_key retention_keep)

  # Blank keeps the stored value: the secret key by the operation's own
  # rule, the access key id by omission (a present empty string would
  # overwrite the stored identifier).
  @blank_keeps_stored ~w(access_key_id secret_access_key)

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok, refresh(socket)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("open-settings", _params, socket) do
    {:noreply, assign(socket, editing?: true, error: nil, notice: nil, confirm: nil)}
  end

  def handle_event("cancel-settings", _params, socket) do
    {:noreply,
     assign(socket, editing?: false, error: nil, form: clean_form(socket.assigns.setting))}
  end

  def handle_event("save-settings", %{"backup" => params}, socket) do
    case save(socket, params) do
      :ok ->
        {:noreply,
         socket
         |> assign(editing?: false, error: nil, notice: "Backup settings saved.")
         |> refresh()}

      {:error, {:changeset, changeset}} ->
        {:noreply, assign(socket, form: form_for(params, field_errors(changeset)), error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, form: form_for(params), error: copy_for(reason))}
    end
  end

  # The summary's switch: `enabled` is one attribute and no cluster
  # state — a PLAIN row update (the documented contract), never the
  # full ConfigureBackups pass: pausing must not be blockable by a K8s
  # failure, a missing Secret, or a nil namespace (CodeRabbit).
  def handle_event("toggle-enabled", _params, socket) do
    setting = socket.assigns.setting
    enabled = not setting.enabled

    case BackupSetting.update(setting, %{enabled: enabled}, actor: socket.assigns.current_user) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> assign(error: nil, notice: toggle_notice(enabled))
         |> refresh()}

      # The resume flip is the paid gate's surface — and Ash answers a
      # vanished row (or a revoked membership) with the same Forbidden
      # shape, so the wallet copy is only honest when the row STILL
      # exists for this actor AND the ledger says unpaid. The arm
      # re-reads the row instead of trusting the page's stale assign.
      {:error, %Ash.Error.Forbidden{}} ->
        if wallet_refusal?(socket.assigns.instance, socket.assigns.current_user) do
          {:noreply, assign(socket, error: copy_for(:resume_unpaid))}
        else
          {:noreply, assign(socket, error: copy_for(:unavailable))}
        end

      # coveralls-ignore-start - defensive: the only non-policy failure
      # is a DB outage, which ExUnit cannot simulate (DBConnection
      # reconnects)
      {:error, reason} ->
        {:noreply, assign(socket, error: copy_for(reason))}
        # coveralls-ignore-stop
    end
  end

  def handle_event("back-up-now", _params, socket) do
    case Infrastructure.run_instance_backup(socket.assigns.instance, :manual) do
      {:ok, _run} ->
        {:noreply,
         socket
         |> assign(
           error: nil,
           confirm: nil,
           notice: "Backup started — this page updates as it runs."
         )
         |> refresh()}

      # :wallet_unfunded names two gates (paid-once OR funded), so the
      # org's paid answer rides along — copy_for/2 splits the line by
      # population (the waiver made "$1 once" false for waived orgs).
      {:error, reason} ->
        {:noreply, assign(socket, error: copy_for(reason, socket.assigns.org_paid?))}
    end
  end

  def handle_event("confirm-restore", _params, socket) do
    {:noreply, assign(socket, confirm: :restore, error: nil)}
  end

  def handle_event("confirm-remove", _params, socket) do
    {:noreply, assign(socket, confirm: :remove, error: nil)}
  end

  def handle_event("cancel-confirm", _params, socket) do
    {:noreply, assign(socket, confirm: nil)}
  end

  def handle_event("restore", _params, socket) do
    # The actor rides the call (CodeRabbit Major): the operation's
    # ownership check is the fence between a stale page and someone
    # else's instance — the actorless path is the sweep's alone.
    case Infrastructure.restore_instance_backup(socket.assigns.instance,
           actor: socket.assigns.current_user
         ) do
      {:ok, _run} ->
        {:noreply,
         socket
         |> assign(
           confirm: nil,
           error: nil,
           notice: "Restoring now — the app is off until it's done."
         )
         |> refresh()}

      {:error, reason} ->
        {:noreply, assign(socket, confirm: nil, error: copy_for(reason))}
    end
  end

  def handle_event("remove-settings", _params, socket) do
    case Infrastructure.remove_backup_settings(socket.assigns.setting,
           actor: socket.assigns.current_user
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign(
           confirm: nil,
           editing?: false,
           error: nil,
           repo_password: nil,
           notice: "Backups are off. Your snapshots stay in your bucket."
         )
         |> refresh()}

      # coveralls-ignore-start - defensive: the row was read with this
      # actor, so a policy failure can't reach here; the remaining failure
      # is a DB-level one ExUnit can't stage (DBConnection reconnects)
      {:error, _reason} ->
        {:noreply, assign(socket, confirm: nil, error: copy_for(:unavailable))}
        # coveralls-ignore-stop
    end
  end

  def handle_event("reveal-repo-password", _params, socket) do
    case Infrastructure.read_backup_credential(socket.assigns.instance) do
      {:ok, %{repo_password: password}} ->
        {:noreply, assign(socket, repo_password: password, error: nil)}

      {:error, :not_deployed} ->
        {:noreply,
         assign(socket, error: "Set the app up first — there's no backup password yet.")}

      _unavailable ->
        {:noreply,
         assign(socket, error: "Couldn't read the backup password — try again shortly.")}
    end
  end

  def handle_event("hide-repo-password", _params, socket) do
    {:noreply, assign(socket, :repo_password, nil)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-3" data-testid="backups-panel">
      <.card class="space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h2 class="text-sm font-medium text-ink-muted">Backups</h2>
          <.health_badge :if={@setting} health={@health} />
        </div>

        <.callout :if={@notice} tone="success" data-testid="backups-notice">
          <p class="text-sm text-ink-muted">{@notice}</p>
        </.callout>

        <.callout :if={@error} tone="warning" data-testid="backups-error">
          <p class="text-sm text-ink-muted">{@error}</p>
        </.callout>

        <%= cond do %>
          <% @instance.status == :lost -> %>
            <.unavailable_note />
          <% is_nil(@setting) -> %>
            <.unconfigured
              instance={@instance}
              editing?={@editing?}
              myself={@myself}
              org_paid?={@org_paid?}
              billing_path={@billing_path}
            />
          <% true -> %>
            <.configured
              instance={@instance}
              setting={@setting}
              last_success={@last_success}
              failed_run={@failed_run}
              runs={@runs}
              active_run={@active_run}
              now={@now}
              confirm={@confirm}
              repo_password={@repo_password}
              form={@form}
              editing?={@editing?}
              myself={@myself}
              org_paid?={@org_paid?}
              org_funded?={@org_funded?}
              billing_path={@billing_path}
            />
        <% end %>

        <%!-- A first save (unconfigured) has no summary to sit under, so
        the form follows the callout. The configured edit renders it in
        `configured/1`, right under the action row. --%>
        <.settings_form
          :if={@editing? and is_nil(@setting)}
          form={@form}
          stored_access_key={nil}
          myself={@myself}
        />
      </.card>
    </div>
    """
  end

  attr(:form, :any, required: true)
  # The stored key id, used only to name its last four characters in the
  # empty field's placeholder — never as a value.
  attr(:stored_access_key, :any, default: nil)
  attr(:myself, :any, required: true)

  defp settings_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="backup-settings-form"
      phx-submit="save-settings"
      phx-target={@myself}
      class="space-y-3 rounded-panel border border-line-strong bg-panel-raised p-4"
    >
      <p class="text-sm font-medium text-ink">Backup destination</p>

      <.input
        field={@form[:endpoint]}
        label="Endpoint"
        placeholder="https://account.r2.cloudflarestorage.com"
        autocomplete="off"
      />
      <.input field={@form[:bucket]} label="Bucket" placeholder="my-app-backups" autocomplete="off" />
      <.input
        field={@form[:prefix]}
        label="Folder (optional)"
        placeholder="fluxvale/app"
        autocomplete="off"
      />
      <%!-- Never pre-filled: the stored key would render on a mere
      "Edit settings" navigation, which is the same leak the summary
      masks. Blank keeps it (ADR-0037 §4). --%>
      <.input
        field={@form[:access_key_id]}
        label="Access key id (leave blank to keep the current one)"
        placeholder={access_key_placeholder(@stored_access_key)}
        autocomplete="off"
        spellcheck="false"
      />
      <%!-- Blank keeps the stored key: the operation's own rule, said in
      the label so an edit never looks like a silent credential wipe. The
      placeholder mirrors the access-key field's, so both keep-fields read
      the same (vision convergence nit). --%>
      <.input
        field={@form[:secret_access_key]}
        type="password"
        label="Secret access key (leave blank to keep the current one)"
        placeholder={secret_key_placeholder(@stored_access_key)}
        autocomplete="new-password"
      />
      <.input
        field={@form[:retention_keep]}
        type="number"
        label="Snapshots to keep"
        min="2"
        max="30"
        step="1"
      />

      <div class="flex flex-wrap gap-2">
        <.button type="submit" size="sm" data-testid="backups-save">Save settings</.button>
        <.button
          type="button"
          size="sm"
          variant="ghost"
          phx-click="cancel-settings"
          phx-target={@myself}
          data-testid="backups-cancel"
        >
          Cancel
        </.button>
      </div>
    </.form>
    """
  end

  attr(:health, :any, required: true)

  defp health_badge(assigns) do
    {tone, label} =
      case assigns.health do
        :active -> {"primary", "Running"}
        :failing -> {"warning", "Needs attention"}
        :ok -> {"success", "Healthy"}
        :never -> {"neutral", "Not run yet"}
      end

    assigns = assign(assigns, tone: tone, label: label)

    ~H"""
    <.badge tone={@tone} data-testid="backups-health">{@label}</.badge>
    """
  end

  attr(:instance, :any, required: true)
  attr(:editing?, :boolean, required: true)
  attr(:myself, :any, required: true)
  attr(:org_paid?, :boolean, required: true)
  attr(:billing_path, :any, required: true)

  defp unconfigured(assigns) do
    ~H"""
    <%!-- The pre-emptive gate (the access panel's paid-hint shape): the
    save would be refused anyway, so the card says so before the form. --%>
    <.callout :if={!@org_paid?} tone="warning" data-testid="backups-unpaid">
      <p class="text-sm text-ink-muted">
        Backups need a one-time top-up of at least $1 in your wallet — add
        funds in <.link
          navigate={@billing_path}
          class="underline underline-offset-2 hover:text-ink"
          data-testid="backups-billing-link"
        >
          Billing
        </.link>.
      </p>
    </.callout>

    <.callout tone="info" data-testid="backups-unconfigured">
      <p class="text-sm text-ink-muted">
        Backups go to your own S3-compatible bucket — Cloudflare R2, or any
        MinIO or S3 endpoint. You pay your provider for storage; FluxVale
        charges no fee for backups — the one-time top-up is a wallet
        minimum, not a charge.
      </p>
    </.callout>

    <%= if @editing? do %>
      <p class="text-sm text-ink-subtle">
        Fill in the bucket details below. Nothing is uploaded until the first run.
      </p>
    <% else %>
      <.button
        :if={@instance.namespace}
        size="sm"
        phx-click="open-settings"
        phx-target={@myself}
        data-testid="backups-setup"
      >
        Set up backups
      </.button>
      <p :if={is_nil(@instance.namespace)} class="text-sm text-ink-subtle">
        Backups can be set up once the app has finished setting up.
      </p>
    <% end %>
    """
  end

  attr(:instance, :any, required: true)
  attr(:setting, :any, required: true)
  attr(:last_success, :any, required: true)
  attr(:failed_run, :any, required: true)
  attr(:runs, :list, required: true)
  attr(:active_run, :any, required: true)
  attr(:now, :any, required: true)
  attr(:confirm, :any, required: true)
  attr(:repo_password, :string, required: true)
  attr(:form, :any, required: true)
  attr(:editing?, :boolean, required: true)
  attr(:myself, :any, required: true)
  attr(:org_paid?, :boolean, required: true)
  attr(:org_funded?, :boolean, required: true)
  attr(:billing_path, :any, required: true)

  defp configured(assigns) do
    assigns =
      assign(assigns,
        backup_blocked?: blocked_backup?(assigns),
        restore_blocked?: blocked_restore?(assigns),
        # The cadence line reads the same gate the callouts name: a row
        # whose wallet cannot run is BLOCKED, not "backing up daily" —
        # and the Pause switch stays (the row is enabled; pausing is
        # still the owner's off-verb).
        wallet_runnable?: assigns.org_paid? and assigns.org_funded?
      )

    ~H"""
    <%!-- The configured card's wallet warnings (the access panel's
    two-copy pattern): a row whose org cannot run is named, not
    silently skipped — the same shapes the due pass skips benignly. --%>
    <.callout :if={!@org_paid?} tone="warning" data-testid="backups-config-unpaid">
      <p class="text-sm text-ink-muted">
        Backups are blocked — top up once (at least $1) to use them. Add funds
        in <.link
          navigate={@billing_path}
          class="underline underline-offset-2 hover:text-ink"
          data-testid="backups-config-unpaid-link"
        >
          Billing
        </.link>.
      </p>
    </.callout>

    <.callout
      :if={@org_paid? and !@org_funded?}
      tone="warning"
      data-testid="backups-config-prefund"
    >
      <p class="text-sm text-ink-muted">
        Backups are blocked — the balance ran out. Top up to use them again —
        add funds in <.link
          navigate={@billing_path}
          class="underline underline-offset-2 hover:text-ink"
          data-testid="backups-config-prefund-link"
        >
          Billing
        </.link>.
      </p>
    </.callout>

    <.callout
      :if={@instance.status == :restoring}
      tone="info"
      title="Restore in progress"
      data-testid="backups-restoring"
    >
      <p class="text-sm text-ink-muted">
        The app is off while its files are put back. The run below shows the
        outcome once it finishes.
      </p>
    </.callout>

    <.callout
      :if={@failed_run}
      tone="warning"
      title={failure_text(@failed_run)}
      data-testid="backups-failing"
    >
      <p class="text-sm text-ink-muted">
        Your app is unaffected, and earlier snapshots are still in your bucket.
      </p>
      <%!-- The stored summary is the exact record — kept verbatim, just
      demoted below the plain-words line so jargon never leads. --%>
      <details :if={raw_failure?(@failed_run)} class="text-xs text-ink-subtle">
        <summary class="cursor-pointer">Technical details</summary>
        <p class="mt-1 break-words">{@failed_run.error_summary}</p>
      </details>
    </.callout>

    <div class="grid gap-4 text-sm sm:grid-cols-2">
      <.readonly_field label="Endpoint" value={@setting.endpoint} testid="backup-endpoint" />
      <.readonly_field
        label="Bucket"
        value={@setting.bucket}
        hint={prefix_hint(@setting)}
        testid="backup-bucket"
      />
      <.readonly_field
        label="Access key id"
        value={mask_secret(@setting.access_key_id)}
        hint="Last four characters only"
        testid="backup-access-key"
      />

      <div class="grid gap-1.5">
        <span class="text-ink-subtle">Schedule</span>
        <span class="text-ink" data-testid="backup-retention">
          Daily · keep the last {@setting.retention_keep} snapshots
        </span>
        <p class="text-xs text-ink-subtle">
          Snapshots are taken while the app runs. If a backup is interrupted,
          the one before it is still complete.
        </p>
      </div>
    </div>

    <div class="flex flex-wrap items-center justify-between gap-3 rounded-control border border-line-strong bg-panel-raised px-3 py-2">
      <div>
        <p class="text-sm text-ink" data-testid="backup-cadence">
          {cadence_label(@setting.enabled, @wallet_runnable?)}
        </p>
        <%!-- The success it reports is named as one: the last attempt may
        have failed, and this line must never read as that attempt. --%>
        <p class="text-xs text-ink-subtle" data-testid="last-success">
          Last successful backup: {last_success_label(@last_success, @now)}
        </p>
        <p :if={@failed_run} class="text-xs text-ink-subtle" data-testid="last-attempt">
          Last attempt failed {time_ago(@failed_run.finished_at || @failed_run.started_at, @now)}
        </p>
      </div>
      <.button
        size="sm"
        variant="ghost"
        phx-click="toggle-enabled"
        phx-target={@myself}
        data-testid="backups-enabled-toggle"
      >
        {if(@setting.enabled, do: "Pause backups", else: "Resume backups")}
      </.button>
    </div>

    <div class="flex flex-wrap gap-2">
      <.button
        size="sm"
        phx-click="back-up-now"
        phx-target={@myself}
        disabled={@backup_blocked?}
        data-testid="back-up-now"
      >
        Back up now
      </.button>

      <.button
        :if={@confirm != :restore and @instance.status != :restoring}
        size="sm"
        variant="destructive"
        phx-click="confirm-restore"
        phx-target={@myself}
        disabled={@restore_blocked?}
        data-testid="restore-latest"
      >
        Restore latest
      </.button>

      <.button
        size="sm"
        variant="secondary"
        phx-click="open-settings"
        phx-target={@myself}
        data-testid="backups-edit"
      >
        Edit settings
      </.button>

      <.button
        :if={@confirm != :remove}
        size="sm"
        variant="ghost"
        phx-click="confirm-remove"
        phx-target={@myself}
        data-testid="stop-backups"
      >
        Stop backing up
      </.button>
    </div>

    <%!-- The edit form sits under the actions that opened it: an edit
    that rendered below the run history would land off-screen. --%>
    <.settings_form
      :if={@editing?}
      form={@form}
      stored_access_key={@setting.access_key_id}
      myself={@myself}
    />

    <%!-- Two-step, in-panel: the owner reads the consequence before the
    destructive button exists (the page's delete rides data-confirm; a
    confirm dialog can't carry this much plain copy). --%>
    <.confirm_block
      :if={@confirm == :restore}
      title="Restore a backup?"
      body={
        "This replaces the app's current data with the backup from " <>
          "#{restore_target(@last_success, @now)}. This cannot be undone."
      }
      action="Yes, restore this backup"
      event="restore"
      action_testid="restore-confirm"
      cancel_testid="restore-cancel"
      myself={@myself}
    />

    <.confirm_block
      :if={@confirm == :remove}
      title="Stop backing this app up?"
      body="This app stops backing up and the schedule is removed. Snapshots already in your bucket stay there."
      note="Keep your backup password — you'll still need it to restore these snapshots into a new app."
      action="Yes, stop backing up"
      event="remove-settings"
      action_testid="stop-backups-confirm"
      cancel_testid="stop-backups-cancel"
      myself={@myself}
    />

    <div class="space-y-2 rounded-panel border border-line bg-panel p-4">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <p class="text-sm font-medium text-ink">Backup password</p>
        <%= if @repo_password do %>
          <div class="flex items-start gap-2">
            <.copy_button
              id="copy-repo-password"
              value={@repo_password}
              label="Copy password"
              testid="copy-repo-password"
            />
            <.button
              size="sm"
              variant="secondary"
              phx-click="hide-repo-password"
              phx-target={@myself}
              data-testid="hide-repo-password"
            >
              Hide
            </.button>
          </div>
        <% else %>
          <.button
            size="sm"
            variant="secondary"
            phx-click="reveal-repo-password"
            phx-target={@myself}
            data-testid="reveal-repo-password"
          >
            Show password
          </.button>
        <% end %>
      </div>

      <code
        :if={@repo_password}
        class="block min-w-0 overflow-x-auto rounded-control border border-line-strong bg-panel-raised px-2 py-1 font-mono text-xs whitespace-nowrap text-ink"
        data-testid="repo-password"
      >
        {@repo_password}
      </code>

      <p class="text-xs text-ink-muted">
        <span class="font-medium text-ink">Keep this somewhere safe.</span>
        You need it to restore these backups into a new app if this one is
        deleted — it isn't shown anywhere else.
      </p>
    </div>

    <%!-- S3: the run history is technical content — outcomes, sizes,
    times — so it reads in the mono-panel register (the admin panel's
    sunken treatment). The setup/restore interactions above stay form
    surfaces; the shell stays a regular card. Label rides mb-0 +
    space-y-3, the dav panel's explicit rhythm — space-y on the wrapper
    would otherwise halve the grammar's 12px label gap (#328 hostile
    F7). --%>
    <div class="mono-panel space-y-3">
      <p class="mono-panel-label mb-0">Recent runs</p>
      <div id="backup-runs" class="space-y-2" data-testid="backup-runs">
        <.backup_run_row :for={run <- @runs} run={run} now={@now} />
      </div>
      <p :if={@runs == []} class="text-xs text-ink-subtle" data-testid="backups-no-runs">
        No runs yet — the first one lands at tonight's scheduled time, or press
        "Back up now".
      </p>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:body, :string, required: true)
  attr(:note, :string, default: nil)
  attr(:action, :string, required: true)
  attr(:event, :string, required: true)
  attr(:action_testid, :string, required: true)
  attr(:cancel_testid, :string, required: true)
  attr(:myself, :any, required: true)

  # One destructive treatment for every confirm: the danger border and
  # heading say "consequence", where the status `.callout`s stay muted —
  # a stop must never read like a notice.
  defp confirm_block(assigns) do
    ~H"""
    <div
      class="space-y-3 rounded-panel border-2 border-line-danger bg-danger-muted px-4 py-3"
      data-testid="destructive-confirm"
    >
      <p class="text-sm font-semibold text-danger">{@title}</p>
      <p class="text-sm text-ink">{@body}</p>
      <p :if={@note} class="text-xs text-ink-muted">{@note}</p>
      <div class="flex flex-wrap gap-2">
        <.button
          size="sm"
          variant="destructive"
          phx-click={@event}
          phx-target={@myself}
          data-testid={@action_testid}
        >
          {@action}
        </.button>
        <.button
          size="sm"
          variant="ghost"
          phx-click="cancel-confirm"
          phx-target={@myself}
          data-testid={@cancel_testid}
        >
          Cancel
        </.button>
      </div>
    </div>
    """
  end

  defp unavailable_note(assigns) do
    ~H"""
    <.callout tone="warning" data-testid="backups-unavailable">
      <p class="text-sm text-ink-muted">
        Backup settings live with the app, and this app went missing on our
        side. Re-deploy it to reconnect its backups — the snapshots in your
        bucket are untouched.
      </p>
    </.callout>
    """
  end

  # --- state -----------------------------------------------------------------

  defp refresh(socket) do
    instance = socket.assigns.instance
    user = socket.assigns.current_user
    setting = load_setting(instance, user)
    runs = load_runs(instance, user)

    # The wallet reads are HONEST — never short-circuited by the row's
    # existence: a settings row only proves the org paid when it was
    # written, and the shapes that cannot run anyway (a legacy row, a
    # lapsed customer) deserve the same visible warning the setup card
    # gives. The funded read only runs for paid orgs — an unpaid org's
    # answer is already "cannot run".
    org_paid? = ActorOrgHasPaid.org_paid?(instance.organization_id)

    org_funded? =
      org_paid? and ActorOrgWalletFunded.org_funded?(instance.organization_id)

    socket
    |> assign_new(:editing?, fn -> false end)
    |> assign_new(:confirm, fn -> nil end)
    |> assign_new(:error, fn -> nil end)
    |> assign_new(:notice, fn -> nil end)
    |> assign_new(:repo_password, fn -> nil end)
    |> assign(
      setting: setting,
      runs: runs,
      active_run: Enum.find(runs, &active?/1),
      last_success: Enum.find(runs, &backup_success?/1),
      failed_run: newest_failure(runs),
      health: health(setting, runs),
      org_paid?: org_paid?,
      org_funded?: org_funded?,
      billing_path: billing_path(instance, user, org_paid? and org_funded?),
      now: DateTime.utc_now()
    )
    |> seed_form(setting)
  end

  # Only resolved when a callout can render (the org cannot run —
  # unpaid or empty); a runnable org never reads the org tables for
  # this.
  defp billing_path(_instance, _user, true), do: nil

  defp billing_path(instance, user, false) do
    case Organization.get_by_id(instance.organization_id, actor: user) do
      {:ok, org} -> org_billing_path(org, user)
      _unreadable -> ~p"/billing"
    end
  end

  # The access panel's resolution: the personal org's wallet lives at
  # /billing, a real org's at its own billing page.
  defp org_billing_path(org, user) do
    case PersonalOrg.org_for(user) do
      {:ok, %{id: id}} when id == org.id -> ~p"/billing"
      _not_personal -> ~p"/organizations/#{org.slug}/billing"
    end
  end

  # Re-seed the form only when the stored setting moved (a save, a fresh
  # row) — a status broadcast must never wipe what the owner is typing.
  defp seed_form(socket, setting) do
    signature = signature(setting)

    if socket.assigns[:form] && socket.assigns[:form_signature] == signature do
      socket
    else
      assign(socket,
        form_signature: signature,
        form: clean_form(setting)
      )
    end
  end

  defp signature(nil), do: nil
  defp signature(%BackupSetting{id: id, updated_at: updated_at}), do: {id, updated_at}

  defp clean_form(setting), do: form_for(form_params(setting))

  defp form_for(params, errors \\ []), do: Component.to_form(params, as: :backup, errors: errors)

  defp form_params(nil) do
    %{
      "endpoint" => "",
      "bucket" => "",
      "prefix" => "",
      "access_key_id" => "",
      "secret_access_key" => "",
      "retention_keep" => "7"
    }
  end

  defp form_params(%BackupSetting{} = setting) do
    %{
      "endpoint" => setting.endpoint,
      "bucket" => setting.bucket,
      "prefix" => setting.prefix || "",
      # Never pre-filled: an empty field means "keep the stored key", and
      # a prefilled one would render the credential on a plain navigation.
      "access_key_id" => "",
      # Never pre-filled: an empty field means "keep the stored key".
      "secret_access_key" => "",
      "retention_keep" => Integer.to_string(setting.retention_keep)
    }
  end

  # The form's payload is the operation's params, minus the keys the form
  # doesn't render. Keys are ATOMS: `ConfigureBackups` merges with
  # `Map.take(@row_fields)` (atoms), so a string-keyed map would be
  # dropped and every field would read "is required". Values stay strings:
  # the resource owns the casting and therefore the messages the field
  # errors show.
  defp operation_params(params) do
    taken = Map.take(params, @form_fields)

    # A blank "keep" field is omitted, not sent: the merge keeps a stored
    # value for any key it doesn't receive, while a present `""` would
    # overwrite the stored identifier.
    kept = Map.reject(taken, fn {name, value} -> name in @blank_keeps_stored and value == "" end)

    Map.new(kept, fn {name, value} -> {String.to_existing_atom(name), to_param(name, value)} end)
  end

  # A blank prefix is "no prefix" (the merge's deliberate nil), and a
  # blank secret is "keep the stored one" (the operation's own rule).
  defp to_param("prefix", ""), do: nil
  defp to_param(_field, value), do: value

  defp save(socket, params) do
    case Infrastructure.configure_backups(
           socket.assigns.instance,
           operation_params(params),
           actor: socket.assigns.current_user
         ) do
      {:ok, _setting} -> :ok
      {:error, %Ash.Changeset{} = changeset} -> {:error, {:changeset, changeset}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_setting(instance, user) do
    case BackupSetting.get_by_instance(instance.id, actor: user) do
      {:ok, setting} ->
        setting

      # coveralls-ignore-start - a missing row (the unconfigured state)
      # and a DB outage are one shape here; only the outage is unreachable
      # in ExUnit (DBConnection reconnects by design)
      {:error, _missing} ->
        nil
        # coveralls-ignore-stop
    end
  end

  defp load_runs(instance, user) do
    case BackupRun.recent_for_instance(instance.id, @runs_limit, actor: user) do
      {:ok, runs} ->
        runs

      # coveralls-ignore-start - DB outage only (same stance as above)
      {:error, _missing} ->
        []
        # coveralls-ignore-stop
    end
  end

  # --- derived state ---------------------------------------------------------

  defp active?(%BackupRun{status: status}), do: status in [:pending, :running]

  defp backup_success?(%BackupRun{kind: kind, status: status}),
    do: kind != :restore and status == :succeeded

  # Setting-independent: an unconfigured instance has no runs to show, so
  # the summary row's badge is the only place the state is read.
  defp health(_setting, runs) do
    cond do
      Enum.any?(runs, &active?/1) -> :active
      newest_failure(runs) -> :failing
      Enum.any?(runs, &backup_success?/1) -> :ok
      true -> :never
    end
  end

  # The newest terminal run decides the tone: a failure that arrived after
  # the last success is the state worth a warning.
  defp newest_failure(runs) do
    case Enum.find(runs, &terminal?/1) do
      %BackupRun{status: :failed} = run -> run
      _other -> nil
    end
  end

  defp terminal?(%BackupRun{status: status}), do: status in [:succeeded, :failed]

  defp blocked_backup?(%{active_run: %BackupRun{}}), do: true

  defp blocked_backup?(%{instance: %{status: status}}),
    do: status not in @backup_statuses

  # `:error` + `:restore_failed` is restorable again (RestoreInstanceBackup's
  # retry arm): the app is already scaled down, and a retry is the owner's
  # way out. No other `:error` is.
  defp blocked_restore?(assigns) do
    is_nil(assigns.last_success) or not is_nil(assigns.active_run) or
      not restorable?(assigns.instance)
  end

  defp restorable?(%{status: status}) when status in @restorable_statuses, do: true
  defp restorable?(%{status: :error, failure_reason: :restore_failed}), do: true
  defp restorable?(_instance), do: false

  defp last_success_label(nil, _now), do: "never"

  defp last_success_label(%BackupRun{} = run, now) do
    "#{time_ago(run.finished_at || run.started_at, now)} · #{format_bytes(run.bytes_added || 0)}"
  end

  # The restore's target, named: the confirm must say which snapshot the
  # app is about to become, not "the last backup" on trust.
  defp restore_target(%BackupRun{} = run, now) do
    "#{time_ago(run.finished_at || run.started_at, now)} (#{format_bytes(run.bytes_added || 0)})"
  end

  # coveralls-ignore-start - unreachable: the restore button is disabled
  # without a succeeded run (`blocked_restore?/1`), so no confirm opens
  defp restore_target(nil, _now), do: "the most recent backup"
  # coveralls-ignore-stop

  defp access_key_placeholder(nil), do: "AKIAIOSF…"

  defp access_key_placeholder(key),
    do: "Unchanged — ends in #{String.slice(mask_secret(key), -4, 4)}"

  # The stored secret never renders, so the placeholder can only say
  # THAT one exists — no fragment of it, ever.
  defp secret_key_placeholder(nil), do: "••••••••"
  defp secret_key_placeholder(_stored), do: "Unchanged"

  # --- failure copy ----------------------------------------------------------

  # restic's messages are for us, not the owner. Known shapes get plain
  # words and nothing else; anything else gets the honest generic line
  # and keeps the raw summary as an expandable record.
  defp failure_text(%BackupRun{status: :failed} = run), do: translated(run)
  defp failure_text(%BackupRun{}), do: nil

  defp translated(%BackupRun{kind: :restore}), do: "The restore didn't finish."

  defp translated(%BackupRun{error_summary: summary}) when is_binary(summary) do
    if locked_failure?(summary) do
      "A backup was skipped because the previous one was still running."
    else
      "The last backup didn't finish."
    end
  end

  defp translated(%BackupRun{}), do: "The last backup didn't finish."

  # The stored summary is shown verbatim when it says more than the
  # headline already does — a known shape is fully translated, so its
  # jargon stays out of sight.
  defp raw_failure?(%BackupRun{error_summary: summary}) when is_binary(summary),
    do: not locked_failure?(summary)

  defp raw_failure?(%BackupRun{}), do: false

  defp locked_failure?(summary), do: String.contains?(summary, "repository is already locked")

  defp prefix_hint(%BackupSetting{prefix: nil}), do: nil
  defp prefix_hint(%BackupSetting{prefix: prefix}), do: "Folder: #{prefix}"

  # The one credential the row holds: an identifier, shown only as its
  # last four characters (ADR-0037 §4 — masked confirmation, never the key).
  defp mask_secret(value) when is_binary(value) and byte_size(value) > 4 do
    "••••" <> String.slice(value, -4, 4)
  end

  defp mask_secret(_value), do: "••••"

  defp cadence_label(_enabled, false), do: "Backups are blocked — the wallet cannot run them"
  defp cadence_label(true, true), do: "Backing up daily"
  defp cadence_label(false, true), do: "Backups paused"

  defp toggle_notice(true), do: "Backups resumed."
  defp toggle_notice(false), do: "Backups paused — nothing is uploaded until you resume."

  # The wallet copy's precondition: a row this actor can still read AND
  # an unpaid ledger. Anything else — row gone, membership revoked, a
  # paid org — is not a wallet problem.
  defp wallet_refusal?(instance, user) do
    case BackupSetting.get_by_instance(instance.id, actor: user) do
      {:ok, _row} -> not ActorOrgHasPaid.org_paid?(instance.organization_id)
      _row_gone_or_unreadable -> false
    end
  end

  defp copy_for(:run_in_flight), do: "A backup or restore is already running. Give it a minute."
  defp copy_for(:backups_disabled), do: "Backups are paused — resume them first."

  defp copy_for(:nothing_to_restore), do: "There's no finished backup to restore yet."
  defp copy_for(:not_restorable), do: "The app is busy right now — try again in a moment."

  defp copy_for(:not_deployed),
    do: "Backups can be configured once the app has finished setting up."

  defp copy_for(:secret_access_key_required), do: "Add your secret access key."
  defp copy_for(:secret_corrupt), do: "The stored credentials look damaged — re-enter your keys."

  # The resume toggle's paid refusal — the resource policy has no
  # message of its own, so the panel names the fix (the save path's
  # refusal renders the operation's own line).
  defp copy_for(:resume_unpaid), do: "Top up at least $1 to resume backups."

  # A Forbidden whose policy error carries a plain-words message is the
  # operation speaking to the owner (the paid gate) — render its words.
  # Bare policy denials (a stale row under the toggle, a cross-org save)
  # are structural, not wallet problems: the honest generic line.
  defp copy_for(%Ash.Error.Forbidden{
         errors: [%Ash.Error.Forbidden.Policy{custom_message: message} | _rest]
       })
       when is_binary(message) and message != "",
       do: message

  defp copy_for(_reason), do: "Something went wrong on our side. Try again in a minute."

  # :wallet_unfunded fires when EITHER the paid-once gate or the funded
  # gate refuses, so the copy splits by population (the paywall waiver
  # made the $1-once clause false for a waived org at zero balance —
  # the waiver exists precisely so they never must pay): a never-paid
  # org keeps the $1-once education, a paid-or-waived org at zero gets
  # the balance-only line. The up-front callouts stay population-gated.
  defp copy_for(:wallet_unfunded, false),
    do: "Top up to run a backup — add at least $1 once, and keep a positive balance."

  defp copy_for(:wallet_unfunded, _paid_or_waived),
    do: "Top up to run a backup — keep a positive balance in your wallet."

  defp copy_for(reason, _org_paid?), do: copy_for(reason)

  # `to_form/2`'s :errors option wants `{field, {message, opts}}` tuples —
  # the opts carry the gettext bindings, empty here because the resource's
  # messages have none.
  defp field_errors(%Ash.Changeset{errors: errors}) do
    Enum.flat_map(errors, fn
      %Ash.Error.Changes.Required{field: field} ->
        [{field, {"is required", []}}]

      %{field: field, message: message} = error when is_binary(message) ->
        [{field, {interpolate(message, Map.get(error, :vars) || []), []}}]

      # coveralls-ignore-start - defensive: this operation's changeset
      # errors are Required and InvalidAttribute only; a shape without a
      # field has no input to point at
      _unmapped ->
        []
        # coveralls-ignore-stop
    end)
  end

  # `e.message` is the resource's template (`must be less than or equal to
  # %{max}`); the bindings ride `vars`. Interpolating the scalars here
  # keeps the resource as the message's owner while the input shows plain
  # words. Non-scalar bindings (a validation's regex, say) stay in the
  # template untouched — they're not part of the sentence a person reads.
  defp interpolate(message, vars) do
    Enum.reduce(vars, message, fn
      {name, value}, acc when is_binary(value) or is_number(value) or is_atom(value) ->
        String.replace(acc, "%{#{name}}", to_string(value))

      {_name, _other}, acc ->
        acc
    end)
  end

  # --- presentational function components (storybook) ------------------------

  @doc """
  One labeled, read-only value in the credential-panel shape: no-wrap, so
  a long bucket or key is never broken mid-string (ADR-0035 Am. 1).
  """
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:hint, :string, default: nil)
  attr(:testid, :string, default: nil)

  def readonly_field(assigns) do
    ~H"""
    <div class="grid gap-1.5">
      <span class="text-ink-subtle">{@label}</span>
      <code
        class="min-w-0 overflow-x-auto rounded-control border border-line-strong bg-panel-raised px-2 py-1 font-mono text-xs whitespace-nowrap text-ink"
        data-testid={@testid}
      >
        {@value}
      </code>
      <p :if={@hint} class="text-xs text-ink-subtle" data-testid={@testid && "#{@testid}-hint"}>
        {@hint}
      </p>
    </div>
    """
  end

  @doc """
  One run in the panel's history: kind, status, size, time, and — for a
  failure — the plain-words reason in body color. The snapshot hash stays
  on the run but never renders: it's restic's identifier, not the
  owner's.

  S3: the row reads in the mono register — a quiet row inside the
  mono-panel, no pill chrome; the status word alone carries the tone
  color (red marks the state, never the reason text).
  """
  attr(:run, :any, required: true)
  attr(:now, :any, default: nil)

  def backup_run_row(assigns) do
    run = assigns.run
    now = assigns.now || DateTime.utc_now()

    assigns =
      assign(assigns,
        now: now,
        tone: status_class(run.status),
        status_label: status_label(run.status),
        kind_label: kind_label(run.kind),
        size: run_size(run),
        occurred: time_ago(run.finished_at || run.started_at, now),
        failure: failure_text(run)
      )

    ~H"""
    <div
      class="flex flex-wrap items-baseline gap-x-4 gap-y-0.5 font-mono text-xs"
      data-testid="backup-run"
      data-run-kind={@run.kind}
      data-run-status={@run.status}
    >
      <span class={["w-24 shrink-0 font-medium", @tone]}>{@status_label}</span>
      <span class="text-ink-muted">{@kind_label}</span>
      <span :if={@size} class="text-ink-subtle">{@size}</span>
      <span class="ml-auto text-ink-subtle">{@occurred}</span>
      <p :if={@failure} class="w-full break-words text-ink-muted">
        {@failure}
      </p>
    </div>
    """
  end

  defp status_label(:pending), do: "Queued"
  defp status_label(:running), do: "Running"
  defp status_label(:succeeded), do: "Finished"
  defp status_label(:failed), do: "Failed"

  # The status words' tones in the mono register: text color, not a
  # pill. The deep steps are the sunken-surface tokens (PR #328's
  # hostile F1: the base success/danger fall under 4.5:1 on
  # --panel-sunken in light; the deep steps clear it with margin and
  # alias the same values in dark). `text-link` for "running" is the
  # badge's primary tone's readable member, unchanged.
  defp status_class(:pending), do: "text-ink-subtle"
  defp status_class(:running), do: "text-link"
  defp status_class(:succeeded), do: "text-success-deep"
  defp status_class(:failed), do: "text-danger-deep"

  defp kind_label(:scheduled), do: "Scheduled backup"
  defp kind_label(:manual), do: "Manual backup"
  defp kind_label(:restore), do: "Restore"

  defp run_size(%BackupRun{kind: :restore, bytes_restored: bytes}),
    do: size_label(bytes, "restored")

  defp run_size(%BackupRun{bytes_added: bytes}), do: size_label(bytes, "added")

  defp size_label(nil, _verb), do: nil
  defp size_label(bytes, verb), do: "#{format_bytes(bytes)} #{verb}"

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{scaled(bytes, 1024)} KB"
  defp format_bytes(bytes) when bytes < 1_073_741_824, do: "#{scaled(bytes, 1_048_576)} MB"
  defp format_bytes(bytes), do: "#{scaled(bytes, 1_073_741_824)} GB"

  defp scaled(bytes, unit), do: Float.round(bytes / unit, 1)

  defp time_ago(%DateTime{} = at, %DateTime{} = now) do
    seconds = DateTime.diff(now, at, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3600)} h ago"
      true -> "#{div(seconds, 86_400)} d ago"
    end
  end
end
