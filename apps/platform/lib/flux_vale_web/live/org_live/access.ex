defmodule FluxValeWeb.OrganizationLive.Access do
  @moduledoc """
  Org settings, Access tab (#273, ADR-0039): the private-access
  gateway's owner surface — enable, watch, re-paste the key, resume
  after suspension, remove, and pair instances (attach/detach, §4.1 —
  the owner's reachability switch).

  Slug-keyed mount like the sibling tabs; unknown slugs (and policy
  denials) read as "not here" — never a bare 404. Owners-only in the
  panel is a UX gate, not the authority: the actions' own policies
  (membership, funded wallet) are what actually forbid a call.

  Live updates ride the gateway's per-org PubSub topic — every state
  write publishes there (the observer's minute tick, the ladder's
  suspension, a resume from another tab), and the teardown's hard
  delete refetches the panel to the empty state. The auth key is
  write-only: a password input, and no read-back path ever returns the
  stored key (ADR-0039 §4).
  """

  use FluxValeWeb, :live_view

  alias Ash.Error.Forbidden
  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Checks.ActorOrgWalletFunded
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing
  alias FluxValeWeb.OrgSettings

  @impl Phoenix.LiveView
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Organization.get_by_slug(slug, actor: user) do
      {:ok, org} ->
        # UX gate, not the authority: the actions' own policies (member
        # read, funded-wallet create/resume) are what actually forbid a
        # non-owner call. This only spares a member a settings surface
        # that is owners-only by design — same posture as Settings.
        if ActorIsOrganizationOwner.owner?(user, org) do
          # The per-org topic, never a global one: every gateway write
          # broadcasts here, so only this org's open panels refetch.
          Phoenix.PubSub.subscribe(FluxVale.PubSub, "access_gateways:#{org.id}")

          gateway = fetch_gateway(org, user)

          {:ok,
           socket
           |> assign(org: org, gateway: gateway, price_cents: monthly_cents())
           |> assign(repaste_open?: repaste_open_for(gateway), remove_armed?: false)
           |> assign(attach_error: nil)
           |> stream_configure(:attached, dom_id: &"access-attached-#{&1.route.id}")
           |> stream_configure(:attachable, dom_id: &"access-attach-#{&1.id}")
           |> refresh_funded()
           |> assign_forms()
           |> refresh_pairing()}
        else
          {:ok,
           socket
           |> put_flash(:error, "Only organization owners can access settings.")
           |> push_navigate(to: ~p"/")}
        end

      _error ->
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"gateway" => params}, socket) do
    form =
      socket.assigns.form
      |> AshPhoenix.Form.validate(form_params(params, socket))
      |> clear_key_display()

    {:noreply, assign(socket, form: form)}
  end

  # Enable — the empty state's create. The panel owns the two create
  # inputs the form doesn't render: the org, and the price snapshot the
  # row keeps (the price the owner opted in at is the price they keep).
  def handle_event("enable", %{"gateway" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: form_params(params, socket)) do
      {:ok, gateway} ->
        {:noreply,
         socket
         |> put_flash(:info, "Private access is connecting — this page updates on its own.")
         |> assign(gateway: gateway)
         |> assign(repaste_open?: repaste_open_for(gateway), remove_armed?: false)
         |> assign_forms()}

      {:error, form} ->
        if forbidden?(form) do
          # The funded-wallet gate — the fix is the wallet, so the copy
          # says so instead of rendering a field error. The form is
          # rebuilt from the row (no key echo — see clear_key_display)
          # and carries only the errors.
          {:noreply,
           socket
           |> put_flash(:error, "Top up before enabling private access.")
           |> rebuild_form_with_errors(form)}
        else
          {:noreply,
           socket
           |> put_flash(:error, "Couldn't enable private access — try again.")
           |> rebuild_form_with_errors(form)}
        end
    end
  end

  # Re-paste — the NeedsLogin / deleted-node recovery. The engine writes
  # the Secret and restarts; the copy stays "reconnect", never the
  # machinery underneath.
  def handle_event("repaste", %{"gateway" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, gateway} ->
        {:noreply,
         socket
         |> put_flash(:info, "Reconnecting with the new key — this page updates on its own.")
         |> assign(gateway: gateway)
         |> assign(repaste_open?: repaste_open_for(gateway))
         |> assign_forms()}

      {:error, form} ->
        # The engine's own answer (the change writes "Couldn't update
        # the access key — try again") is field-less, so the flash is
        # its surface — never a silent dead click. The form rebuilds
        # from the row carrying only the errors: the submitted key is
        # not echoed back (ADR-0039 §4).
        {:noreply,
         socket
         |> put_flash(:error, "Couldn't update the access key — try again.")
         |> rebuild_form_with_errors(form)}
    end
  end

  def handle_event("toggle-repaste", _params, socket) do
    {:noreply, assign(socket, repaste_open?: not socket.assigns.repaste_open?)}
  end

  # The empty state is a normal state of this panel (the teardown can
  # delete the row out from under any card), so every event in the
  # remove family is a no-op there — a nil gateway has nothing to arm,
  # remove, or retry, and a real double-click on Retry removal lands
  # exactly here after the first click's teardown wins.
  def handle_event("arm-remove", _params, %{assigns: %{gateway: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("arm-remove", _params, socket) do
    {:noreply, assign(socket, remove_armed?: true)}
  end

  def handle_event("retry-remove", _params, %{assigns: %{gateway: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("cancel-remove", _params, socket) do
    {:noreply, assign(socket, remove_armed?: false)}
  end

  # Guarded: only an armed panel removes — every path here passes
  # through the explicit confirm callout first (Settings' armed-rename
  # posture), so a crafted click cannot delete on its own. The nil
  # gateway arm is the empty state (see the arm-remove guard).
  def handle_event("remove", _params, %{assigns: %{gateway: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("remove", _params, socket) do
    case socket.assigns do
      %{remove_armed?: true} ->
        case Infrastructure.delete_access_gateway(socket.assigns.gateway.id,
               actor: socket.assigns.current_user
             ) do
          {:ok, gateway} ->
            {:noreply,
             socket
             |> put_flash(:info, "Removing private access — billing stops now.")
             |> assign(gateway: gateway)
             |> assign(remove_armed?: false)
             |> assign_forms()}

          {:error, _reason} ->
            # The stale-view arm: the row vanished (teardown won the
            # race) — the next broadcast lands the empty state.
            {:noreply, put_flash(socket, :error, "Could not remove private access — try again.")}
        end

      _unarmed ->
        {:noreply, socket}
    end
  end

  # A failed removal parks the row in :destroying — this is its owner
  # path forward. The engine's delete re-enqueues idempotently from
  # :destroying (its own comment: a duplicate against a live job costs
  # one wasted pass), so one explicit click needs no confirm arm; the
  # destructive confirm stays on the :active/:needs_attention/:suspended
  # cards, where the click is what STARTS the removal.
  def handle_event("retry-remove", _params, socket) do
    case Infrastructure.delete_access_gateway(socket.assigns.gateway.id,
           actor: socket.assigns.current_user
         ) do
      {:ok, gateway} ->
        {:noreply,
         socket
         |> put_flash(:info, "Retrying removal — this page updates on its own.")
         |> assign(gateway: gateway)
         |> assign(remove_armed?: false)
         |> assign_forms()}

      {:error, _reason} ->
        # The stale-view arm: the row vanished (the in-flight teardown
        # won) — the next broadcast lands the empty state.
        {:noreply, put_flash(socket, :error, "Could not remove private access — try again.")}
    end
  end

  # The zero-balance ladder's undo — the engine's funded-wallet policy
  # is the authority; the flash just says what the wallet needs.
  def handle_event("resume", _params, socket) do
    case AccessGateway.resume(socket.assigns.gateway, actor: socket.assigns.current_user) do
      {:ok, gateway} ->
        {:noreply,
         socket
         |> put_flash(:info, "Private access is reconnecting — this page updates on its own.")
         |> assign(gateway: gateway)
         |> refresh_funded()
         |> assign_forms()}

      {:error, %Forbidden{}} ->
        {:noreply, put_flash(socket, :error, "Top up before resuming private access.")}

      {:error, error} ->
        if stale_gateway?(error) do
          # The stale-view arm: another tab won the resume (or the
          # teardown won the race) between this panel's last refetch and
          # the click. The row filter refused the write — retrying here
          # would guess at a state this panel cannot see. Settings'
          # stale posture: reload, not retry.
          {:noreply,
           put_flash(socket, :error, "This gateway changed underneath you — reload to continue.")}
        else
          # A transient failure mid-resume (the scale call) — the row
          # kept :suspended, so the retry is the same button.
          {:noreply, put_flash(socket, :error, "Could not resume private access — try again.")}
        end
    end
  end

  # ---- Pairing (ADR-0039 §3): the owner's reachability switch ----

  # The sections aren't rendered without a gateway (or on a gateway the
  # operation would refuse), so these guards are the crafted/stale-click
  # arms — no-ops, never crashes (the remove family's stance). The
  # trailing catch-alls make that total over crafted payloads too: a
  # phx event without an instance_id is a no-op, not a crash.
  def handle_event("attach", _params, %{assigns: %{gateway: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("attach", %{"instance_id" => instance_id}, socket) do
    user = socket.assigns.current_user

    case Instance.get_by_id(instance_id, actor: user) do
      {:ok, instance} ->
        attach(socket, instance)

      # The stale view: the instance left between this panel's render
      # and the click — the generic copy is the honest answer to a
      # click that can no longer mean anything.
      _gone ->
        # The instance left between render and click — a stale row. The
        # generic copy answers the click AND the lists re-read so the
        # ghost row disappears instead of failing forever.
        {:noreply,
         socket
         |> assign(attach_error: :cluster)
         |> refresh_pairing()}
    end
  end

  def handle_event("attach", _params, socket), do: {:noreply, socket}

  def handle_event("detach", _params, %{assigns: %{gateway: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("detach", %{"instance_id" => instance_id}, socket) do
    user = socket.assigns.current_user

    case Instance.get_by_id(instance_id, actor: user) do
      {:ok, instance} ->
        case Infrastructure.detach_instance(socket.assigns.gateway, instance) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, detach_flash(instance))
             |> refresh_pairing()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Couldn't detach — try again.")}
        end

      _gone ->
        # Stale row (CodeRabbit round): refresh alongside the retry copy
        # so a vanished instance leaves the attached list, not a ghost
        # that re-fails every click.
        {:noreply,
         socket
         |> put_flash(:error, "Couldn't detach — try again.")
         |> refresh_pairing()}
    end
  end

  def handle_event("detach", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  # The per-org topic's catch-all: every gateway write lands here (the
  # observer's tick, a state change from another tab, the create) and so
  # does the teardown's hard delete — a read miss IS the delete, and
  # refetching to the nil state is the honest answer (empty state, form
  # rebuilt). The DB is the one ordering that can't lie: notification
  # data can trail fresher writes, so never trust it — refetch (the
  # Instance panel's stance).
  def handle_info(%Ash.Notifier.Notification{}, socket) do
    previous = state_of(socket.assigns.gateway)
    gateway = fetch_gateway(socket.assigns.org, socket.assigns.current_user)

    socket =
      socket
      |> assign(:gateway, gateway)
      |> refresh_funded()
      |> maybe_rebuild_panel(gateway, previous)

    {:noreply, socket}
  end

  # Rebuild the panel's chrome only when the state actually moved — a
  # no-op broadcast (the observer re-publishing the same state) must not
  # wipe a half-typed key out of the re-paste form. A state move can
  # also flip the pairing sections' visibility (the suspension hides
  # them), so their data refetches with the chrome.
  defp maybe_rebuild_panel(socket, gateway, previous) do
    if state_of(gateway) == previous do
      socket
    else
      socket
      |> assign(repaste_open?: repaste_open_for(gateway), remove_armed?: false)
      |> assign_forms()
      |> refresh_pairing()
    end
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
      current_org={@org}
    >
      <div class="mx-auto max-w-3xl space-y-8">
        <OrgSettings.org_header org={@org} />

        <OrgSettings.settings_tabs current="access" slug={@org.slug} />

        <div>
          <h2 class="text-base font-medium text-ink">Access</h2>
          <p class="mt-1 text-sm text-ink-muted">
            Reach your private apps from your own Tailscale network.
          </p>
        </div>

        <%= if @gateway do %>
          <.gateway_card
            org={@org}
            gateway={@gateway}
            form={@form}
            funded?={@funded?}
            repaste_open?={@repaste_open?}
            remove_armed?={@remove_armed?}
          />

          <%!-- §4.1's pairing sections — only while the operation would
              accept an attach; every other state gets one honest line
              instead (the banner explains why). --%>
          <p
            :if={pairing_paused_copy(@gateway)}
            class="text-sm text-ink-muted"
            data-testid="access-pairing-paused"
          >
            {pairing_paused_copy(@gateway)}
          </p>

          <.attached_card
            :if={pairing_open?(@gateway)}
            gateway={@gateway}
            attached={@streams.attached}
            attached_empty?={@attached_empty?}
          />

          <.attach_card
            :if={pairing_open?(@gateway)}
            attachable={@streams.attachable}
            attachable_empty?={@attachable_empty?}
            attach_error={@attach_error}
          />
        <% else %>
          <.access_empty_state org={@org} form={@form} funded?={@funded?} price_cents={@price_cents} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # The no-gateway surface: what private access is, the three tailnet
  # prerequisites the panel cannot do for the owner (ADR-0039 §8 — it
  # only names them), the price, and the key intake.
  attr(:org, :map, required: true)
  attr(:form, :any, required: true)
  attr(:funded?, :boolean, required: true)
  attr(:price_cents, :integer, required: true)

  defp access_empty_state(assigns) do
    ~H"""
    <div class="space-y-6" data-testid="access-empty">
      <.card id="access-intro-card" class="space-y-4">
        <div>
          <h3 class="text-sm font-medium text-ink-muted">Private access</h3>
          <p class="mt-2 text-sm text-ink" data-testid="access-explainer">
            Put your private apps on your own Tailscale network — reachable from your own
            devices, never the public internet. One gateway serves the whole organization
            and each app gets its own address on it.
          </p>
        </div>

        <div data-testid="access-prereqs">
          <p class="text-sm font-medium text-ink">
            Before you start, set up once in your Tailscale admin console:
          </p>
          <ul class="mt-2 list-disc space-y-1 pl-5 text-sm text-ink-muted">
            <li>
              Create a tag for FluxVale (for example <span class="font-mono">tag:fluxvale</span>)
              and make yourself its owner.
            </li>
            <li>Turn on MagicDNS.</li>
            <li>Turn on HTTPS on the DNS page.</li>
          </ul>
        </div>

        <p class="text-sm text-ink" data-testid="access-price">
          {Pricing.format_usd(@price_cents)}/month, billed hourly while connected.
        </p>

        <.callout
          :if={!@funded?}
          id="access-prefund-hint"
          tone="warning"
          data-testid="access-prefund-hint"
        >
          <p>
            Your balance is empty — top up before enabling private access. Start from <.link
              navigate={~p"/organizations/#{@org.slug}/billing"}
              class="underline underline-offset-2 hover:text-ink"
              data-testid="access-prefund-link"
            >
              Billing
            </.link>.
          </p>
        </.callout>
      </.card>

      <.card id="access-enable-card" class="space-y-4">
        <div>
          <h3 class="text-sm font-medium text-ink-muted">Enable private access</h3>
          <p class="mt-1 text-sm text-ink-muted">
            Paste a reusable auth key from your Tailscale admin console. It is stored in
            our own secret store and never shown again.
          </p>
        </div>

        <.form for={@form} id="access-enable-form" phx-change="validate" phx-submit="enable">
          <div class="space-y-4">
            <.input
              field={@form[:auth_key]}
              type="password"
              label="Auth key"
              placeholder="tskey-auth-…"
              required
              data-testid="access-key-input"
            />
            <.input
              field={@form[:tailnet_domain]}
              type="text"
              label="Tailnet domain"
              placeholder="your-tailnet.ts.net"
              required
              data-testid="access-domain-input"
            />
            <p class="text-xs text-ink-muted">
              Your tailnet's DNS name — the part after the first dot in any of your
              device names, visible in your Tailscale admin console. It becomes part of
              every private app's address.
            </p>
            <div class="flex justify-end">
              <.button type="submit" data-testid="access-enable">
                Enable private access
              </.button>
            </div>
          </div>
        </.form>
      </.card>
    </div>
    """
  end

  attr(:org, :map, required: true)
  attr(:gateway, AccessGateway, required: true)
  attr(:form, :any, required: true)
  attr(:funded?, :boolean, required: true)
  attr(:repaste_open?, :boolean, required: true)
  attr(:remove_armed?, :boolean, required: true)

  defp gateway_card(assigns) do
    ~H"""
    <.card id="access-gateway-card" class="space-y-4" data-testid="access-gateway-card">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex items-center gap-3">
          <h3 class="text-base font-medium text-ink">Private access</h3>
          <.status_badge status={@gateway.state} />
        </div>
        <p class="font-mono text-sm text-ink-muted" data-testid="access-hostname">
          {@gateway.hostname}
        </p>
      </div>

      <%!-- the engine's own words for the state — written friendly by
          design (the #179 split: technical detail never leaves the
          row). --%>
      <p
        :if={@gateway.status_message}
        class="text-sm text-ink"
        data-testid="access-status-message"
      >
        {@gateway.status_message}
      </p>

      <p class="text-sm text-ink-muted" data-testid="access-billing-line">
        {Pricing.format_usd(@gateway.monthly_cents)}/month, billed hourly while connected —
        suspended or removed, nothing accrues.
      </p>

      <.gateway_actions
        org={@org}
        gateway={@gateway}
        form={@form}
        funded?={@funded?}
        repaste_open?={@repaste_open?}
        remove_armed?={@remove_armed?}
      />
    </.card>
    """
  end

  attr(:org, :map, required: true)
  attr(:gateway, AccessGateway, required: true)
  attr(:form, :any, required: true)
  attr(:funded?, :boolean, required: true)
  attr(:repaste_open?, :boolean, required: true)
  attr(:remove_armed?, :boolean, required: true)

  defp gateway_actions(assigns) do
    ~H"""
    <div class="space-y-4">
      <%= cond do %>
        <% @gateway.state == :provisioning -> %>
          <p class="text-sm text-ink-muted" data-testid="access-connecting-note">
            Setting up access — usually under a minute; if it sticks, reconnect with
            your key.
          </p>
          <.repaste_panel
            form={@form}
            open?={@repaste_open?}
            toggle_label="Re-paste key"
            submit_label="Save key"
          />
        <% @gateway.state == :active -> %>
          <.repaste_panel
            form={@form}
            open?={@repaste_open?}
            toggle_label="Re-paste key"
            submit_label="Save key"
          />
          <.remove_panel armed?={@remove_armed?} />
        <% @gateway.state == :needs_attention -> %>
          <.callout id="access-attention-note" tone="warning" data-testid="access-attention-note">
            <p>
              We can't reach your gateway — the key may have expired, or the node was
              removed from your Tailscale admin console. Paste a fresh key to reconnect.
            </p>
          </.callout>
          <.repaste_panel
            form={@form}
            open?={@repaste_open?}
            toggle_label="Reconnect"
            submit_label="Reconnect"
            prominent?
          />
          <.remove_panel armed?={@remove_armed?} />
        <% @gateway.state == :suspended -> %>
          <.suspended_panel org={@org} funded?={@funded?} />
          <.remove_panel armed?={@remove_armed?} />
        <% @gateway.state == :destroying -> %>
          <p class="text-sm text-ink-muted" data-testid="access-removing-note">
            Removing private access… This page updates on its own.
          </p>
          <.button
            type="button"
            phx-click="retry-remove"
            variant="ghost"
            size="sm"
            data-testid="access-retry-remove"
          >
            Retry removal
          </.button>
      <% end %>
    </div>
    """
  end

  attr(:form, :any, required: true)
  attr(:open?, :boolean, required: true)
  attr(:toggle_label, :string, required: true)
  attr(:submit_label, :string, required: true)
  attr(:prominent?, :boolean, default: false)

  defp repaste_panel(assigns) do
    ~H"""
    <div data-testid="access-repaste">
      <%= if @open? do %>
        <.form
          for={@form}
          id="access-repaste-form"
          phx-change="validate"
          phx-submit="repaste"
          class="space-y-3"
        >
          <.input
            field={@form[:auth_key]}
            type="password"
            label="New auth key"
            placeholder="tskey-auth-…"
            required
            data-testid="access-repaste-key"
          />
          <.input
            field={@form[:tailnet_domain]}
            type="text"
            label="Tailnet domain"
            placeholder="your-tailnet.ts.net"
            required
            data-testid="access-repaste-domain"
          />
          <div class="flex gap-3">
            <.button type="submit" size="sm" data-testid="access-repaste-submit">
              {@submit_label}
            </.button>
            <.button
              type="button"
              phx-click="toggle-repaste"
              variant="ghost"
              size="sm"
              data-testid="access-repaste-hide"
            >
              Cancel
            </.button>
          </div>
        </.form>
      <% else %>
        <.button
          type="button"
          phx-click="toggle-repaste"
          variant={if(@prominent?, do: "primary", else: "ghost")}
          size="sm"
          data-testid="access-repaste-toggle"
        >
          {@toggle_label}
        </.button>
      <% end %>
    </div>
    """
  end

  attr(:armed?, :boolean, required: true)

  defp remove_panel(assigns) do
    ~H"""
    <div class="border-t border-line pt-4">
      <%= if @armed? do %>
        <.callout id="access-remove-confirm" tone="danger" data-testid="access-remove-confirm">
          <p>
            Remove private access? Your private apps fall back to panel-only private —
            reachable only inside FluxVale — and billing stops.
          </p>
          <div class="flex gap-3 pt-1">
            <.button type="button" phx-click="remove" size="sm" data-testid="access-confirm-remove">
              Remove private access
            </.button>
            <.button
              type="button"
              phx-click="cancel-remove"
              variant="ghost"
              size="sm"
              data-testid="access-cancel-remove"
            >
              Cancel
            </.button>
          </div>
        </.callout>
      <% else %>
        <.button
          type="button"
          phx-click="arm-remove"
          variant="ghost"
          size="sm"
          data-testid="access-remove"
        >
          Remove
        </.button>
      <% end %>
    </div>
    """
  end

  attr(:org, :map, required: true)
  attr(:funded?, :boolean, required: true)

  defp suspended_panel(assigns) do
    ~H"""
    <div class="space-y-3" data-testid="access-suspended-banner">
      <.callout id="access-suspended-callout" tone="warning">
        <p>
          Private access is suspended — the balance ran out. Your private apps stay
          reachable only through the panel, and nothing accrues while suspended.
        </p>
      </.callout>
      <%= if @funded? do %>
        <.button type="button" phx-click="resume" size="sm" data-testid="access-resume">
          Resume private access
        </.button>
      <% else %>
        <p class="text-sm text-ink" data-testid="access-resume-topup">
          Top up before resuming private access — start from <.link
            navigate={~p"/organizations/#{@org.slug}/billing"}
            class="underline underline-offset-2 hover:text-ink"
            data-testid="access-resume-topup-link"
          >
            Billing
          </.link>.
        </p>
      <% end %>
    </div>
    """
  end

  # §4.1's attached half: one row per paired app — name, status, the
  # tailnet address (hostname + domain + route_key, rendered from the
  # row's owner-provided suffix), and Detach with no confirm
  # (reversible). The list is a stream reset on every pairing change —
  # the refetch is the update.
  attr(:gateway, AccessGateway, required: true)
  attr(:attached, :any, required: true)
  attr(:attached_empty?, :boolean, required: true)

  defp attached_card(assigns) do
    ~H"""
    <.card id="access-attached-card" class="space-y-4" data-testid="access-attached">
      <div>
        <h3 class="text-sm font-medium text-ink-muted">Attached apps</h3>
        <p class="mt-1 text-sm text-ink-muted">
          Each app gets its own address on your tailnet. Detaching is reversible — a
          detached app is reachable from the panel only again.
        </p>
      </div>

      <p :if={@attached_empty?} class="text-sm text-ink-muted" data-testid="access-attached-empty">
        Nothing attached yet — pick an app below.
      </p>

      <ul id="access-attached-rows" phx-update="stream" class="divide-y divide-line">
        <li
          :for={{dom_id, row} <- @attached}
          id={dom_id}
          class="space-y-1.5 py-3"
          data-testid="access-attached-row"
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="flex min-w-0 flex-wrap items-center gap-2">
              <span class="text-sm font-medium text-ink">{row.instance.name}</span>
              <.status_badge status={row.instance.status} />
            </div>
            <.button
              type="button"
              phx-click="detach"
              phx-value-instance_id={row.instance.id}
              variant="ghost"
              size="sm"
              data-testid="access-detach"
            >
              Detach
            </.button>
          </div>

          <p class="font-mono text-xs text-ink-muted break-all" data-testid="access-attached-address">
            {address(row.route, @gateway)}
          </p>

          <%!-- §4.1: the exposure toggle can put a public instance here
              after the fact — the two switches are independent, and the
              row says so honestly instead of hiding it. --%>
          <p
            :if={row.instance.exposure == :public}
            class="text-xs text-ink-muted"
            data-testid="access-attached-public-note"
          >
            Also public — anyone can reach it at its own address too.
          </p>
        </li>
      </ul>
    </.card>
    """
  end

  # §4.1's attach half: the org's private instances that have no route
  # yet. Refusals are the operation's; each error lands its own line
  # here, and the section hides entirely where attaching can't work.
  attr(:attachable, :any, required: true)
  attr(:attachable_empty?, :boolean, required: true)
  attr(:attach_error, :atom, required: true)

  defp attach_card(assigns) do
    ~H"""
    <.card id="access-attach-card" class="space-y-4" data-testid="access-attach">
      <div>
        <h3 class="text-sm font-medium text-ink-muted">Attach an app</h3>
        <p class="mt-1 text-sm text-ink-muted">
          Give a private app an address on your tailnet. Attaching never changes an
          app's exposure — the two switches stay independent.
        </p>
      </div>

      <.callout :if={@attach_error} id="access-attach-error" tone="warning">
        <p data-testid="access-attach-error">
          {attach_error_copy(@attach_error)}
        </p>
      </.callout>

      <p :if={@attachable_empty?} class="text-sm text-ink-muted" data-testid="access-attach-empty">
        No private apps waiting — apps show up here while they are private and not
        attached yet.
      </p>

      <ul id="access-attach-rows" phx-update="stream" class="divide-y divide-line">
        <li
          :for={{dom_id, instance} <- @attachable}
          id={dom_id}
          class="flex flex-wrap items-center justify-between gap-3 py-3"
          data-testid="access-attach-row"
        >
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <span class="text-sm font-medium text-ink">{instance.name}</span>
            <.status_badge status={instance.status} />
          </div>
          <.button
            type="button"
            phx-click="attach"
            phx-value-instance_id={instance.id}
            size="sm"
            data-testid="access-attach-button"
          >
            Attach
          </.button>
        </li>
      </ul>
    </.card>
    """
  end

  # The member read policy scopes to the actor's orgs; the owner passed
  # the UX gate, so a miss here is genuinely "no gateway".
  defp fetch_gateway(org, user) do
    case AccessGateway.get_for_organization(org.id, actor: user) do
      {:ok, gateway} -> gateway
      {:error, _not_found} -> nil
    end
  end

  # The form tracks the panel's state: create when there is no gateway,
  # re-paste when there is.
  defp assign_forms(socket) do
    user = socket.assigns.current_user

    form =
      case socket.assigns.gateway do
        nil ->
          AccessGateway
          |> AshPhoenix.Form.for_create(:create, actor: user, as: "gateway")
          |> to_form()

        gateway ->
          gateway
          |> AshPhoenix.Form.for_update(:update_credential, actor: user, as: "gateway")
          |> to_form()
      end

    assign(socket, form: form)
  end

  # The create form gets the panel-owned inputs merged in; the re-paste
  # form takes its payload as-is (its action has no other inputs).
  defp form_params(params, socket) do
    if socket.assigns.form.source.type == :create do
      panel_params(params, socket)
    else
      params
    end
  end

  # The panel supplies the two create inputs it doesn't render: the org
  # (the action's own change pins it from the actor — this only keeps
  # validation quiet) and the price snapshot the row keeps.
  defp panel_params(params, socket) do
    Map.merge(params, %{
      "organization_id" => socket.assigns.org.id,
      "monthly_cents" => to_string(socket.assigns.price_cents)
    })
  end

  # The auth key never re-renders: ADR-0039 §4 forbids any read-back,
  # and a validate round-trip is one — the typed value would land in the
  # patch payload and the input's value= attribute. The submitted params
  # were validated before this strip, and LiveView leaves a focused
  # input's text alone, so typing survives; an unfocused field simply
  # comes back empty (the backups panel's secret-field posture). The
  # DOM-driven submit still sends whatever the browser holds. The strip
  # targets the changeset's ARGUMENT — that is what AshPhoenix's
  # input_value reads first, not the params maps.
  defp clear_key_display(%Phoenix.HTML.Form{source: %AshPhoenix.Form{} = ash_form} = form) do
    %{form | source: strip_key_argument(ash_form)}
  end

  defp strip_key_argument(ash_form) do
    %{ash_form | source: Ash.Changeset.set_argument(ash_form.source, :auth_key, "")}
  end

  # A failed submit rediscovers the form from the row — which has no
  # key — and carries only the errored form's field errors, so the
  # submitted key never echoes back (ADR-0039 §4; the backups panel's
  # secret-field posture).
  defp rebuild_form_with_errors(socket, errored_form) do
    socket
    |> assign_forms()
    |> then(fn socket ->
      errors = AshPhoenix.Form.errors(errored_form)

      assign(socket, form: %{socket.assigns.form | errors: errors})
    end)
  end

  # A policy denial arrives as a Forbidden error inside the form — not
  # a field error an input can render. The flash is the friendly copy;
  # the empty state's own hint names the fix before the click. (The
  # form path carries the INNER Policy error; the code-interface resume
  # path carries the Forbidden class.)
  defp forbidden?(form) do
    Enum.any?(form.source.source.errors, &match?(%Ash.Error.Forbidden.Policy{}, &1))
  end

  # The code interface wraps a refused filtered write (the resume's row
  # filter) as Invalid carrying StaleRecord — the settings form's stale
  # marker, error-class shape.
  defp stale_gateway?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  # Defensive: code-interface failures are always error classes (the
  # Forbidden arm is caught before this), so no test can land a bare
  # term here; the clause keeps a future shape from crashing the flash.
  # coveralls-ignore-next-line
  defp stale_gateway?(_error), do: false

  defp refresh_funded(socket) do
    assign(socket, funded?: ActorOrgWalletFunded.org_funded?(socket.assigns.org.id))
  end

  # ---- Pairing data + copy (§4.1) ----

  # The operation is the authority (state, exposure, org); the error map
  # is §4.1's copy contract — each refusal gets its own honest line.
  defp attach(socket, instance) do
    case Infrastructure.attach_instance(socket.assigns.gateway, instance) do
      {:ok, _route} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{instance.name} attached — its tailnet address is below.")
         |> assign(attach_error: nil)
         |> refresh_pairing()}

      {:error, :gateway_not_active} ->
        {:noreply, assign(socket, attach_error: :gateway_not_active)}

      {:error, :pool_exhausted} ->
        {:noreply, assign(socket, attach_error: :pool_exhausted)}

      {:error, :tailnet_domain_missing} ->
        {:noreply, assign(socket, attach_error: :tailnet_domain_missing)}

      {:error, _cluster_or_stale} ->
        {:noreply, assign(socket, attach_error: :cluster)}
    end
  end

  # Detach never changes exposure (the two switches are independent),
  # so the flash says what the instance is actually left as — the
  # public-but-attached corner detaches back to public, not panel-only.
  defp detach_flash(%Instance{exposure: :private} = instance) do
    "#{instance.name} detached — reachable from the panel only again."
  end

  defp detach_flash(%Instance{} = instance) do
    "#{instance.name} detached — its public address still works."
  end

  # Both lists refetch wholesale: the pairing table is small, and every
  # refetch reads the rows fresh. What triggers a refetch is bounded —
  # this panel's own actions and gateway state moves; AccessRoute has no
  # notifier, so ANOTHER tab's attach or an exposure toggle elsewhere
  # does not land here until then (a stale row's click converges through
  # the operation's own guards). The emptiness flags ride alongside —
  # streams can't be counted in the template.
  defp refresh_pairing(socket) do
    {attached, attachable} =
      pairing_lists(socket.assigns.gateway, socket.assigns.org, socket.assigns.current_user)

    socket
    |> stream(:attached, attached, reset: true)
    |> stream(:attachable, attachable, reset: true)
    |> assign(attached_empty?: attached == [], attachable_empty?: attachable == [])
  end

  defp pairing_lists(nil, _org, _user), do: {[], []}

  defp pairing_lists(gateway, org, user) do
    attached = attached_rows(gateway, user)
    taken = MapSet.new(attached, & &1.route.instance_id)

    attachable =
      org.id
      |> Instance.list_for_organization!(actor: user)
      |> Enum.filter(&private_and_free?(&1, taken))
      |> Enum.sort_by(&{&1.name, &1.id})

    {Enum.sort_by(attached, &{&1.instance.name, &1.route.id}), attachable}
  end

  # §4.1's filter: exposure == :private with no existing route. A
  # public-but-attached row keeps its route (the switches are
  # independent), and its instance is rightly absent from this list.
  defp private_and_free?(%Instance{exposure: :private} = instance, taken),
    do: not MapSet.member?(taken, instance.id)

  defp private_and_free?(%Instance{}, _taken), do: false

  # The routes ride the route read policy (member-scoped through the
  # gateway); each row's instance loads under the instance read policy
  # the same way — the FK cascades the route with its instance, so a
  # row always has one.
  defp attached_rows(gateway, user) do
    gateway.id
    |> AccessRoute.list_for_gateway!(actor: user)
    |> Ash.load!(:instance, actor: user)
    |> Enum.map(&%{route: &1, instance: &1.instance})
  end

  # The states the attach operation accepts (AttachInstance's guard) —
  # the UI mirrors the authority, the operation keeps the last word.
  defp pairing_open?(%AccessGateway{state: state}), do: state in [:active, :provisioning]

  # Where the sections hide, one honest line says why (§4.1's banner:
  # attach while suspended is refused, so the section isn't offered).
  defp pairing_paused_copy(%AccessGateway{state: :suspended}) do
    "Attaching is paused while private access is suspended — resume it to bring your apps' addresses back."
  end

  defp pairing_paused_copy(%AccessGateway{state: :needs_attention}) do
    "Attaching is paused while the gateway isn't connected — reconnect with a fresh key first."
  end

  defp pairing_paused_copy(%AccessGateway{state: :destroying}) do
    "Attaching is unavailable — private access is being removed."
  end

  # The open states render the sections instead — nil hides the note.
  defp pairing_paused_copy(%AccessGateway{}), do: nil

  # §4.1's error map: each refusal in the operation's own words.
  defp attach_error_copy(:gateway_not_active) do
    "Private access isn't connected yet — wait for Connected, then attach again."
  end

  defp attach_error_copy(:pool_exhausted) do
    "This gateway's addresses are all in use — detach an app to free one."
  end

  # The migration-window row only: every gateway created after the
  # column lands carries its domain. The fix is the re-paste form.
  defp attach_error_copy(:tailnet_domain_missing) do
    "This gateway needs its tailnet domain — reconnect with your key and fill it in first."
  end

  defp attach_error_copy(_cluster_or_stale) do
    "Couldn't attach — try again."
  end

  # §4.1's address shape: hostname + tailnet domain + route_key. The
  # domain comes from the row (the owner's, provided at enable/re-paste
  # — with PVC state the node's FQDN never leaves the pod), so the
  # address is the concrete thing the gateway serves. The placeholder
  # arm is the backfill window only: a row created before the column
  # existed, until its owner re-pastes.
  defp address(route, %AccessGateway{tailnet_domain: nil} = gateway) do
    "#{gateway.hostname}.<your-tailnet>.ts.net:#{route.route_key}"
  end

  defp address(route, %AccessGateway{} = gateway) do
    "#{gateway.hostname}.#{gateway.tailnet_domain}:#{route.route_key}"
  end

  # The recovery state shows the re-paste form outright (the ADR's
  # reconnect); everywhere else it stays collapsed behind the toggle.
  defp repaste_open_for(%AccessGateway{state: :needs_attention}), do: true
  defp repaste_open_for(_gateway), do: false

  defp state_of(nil), do: nil
  defp state_of(%AccessGateway{state: state}), do: state

  defp monthly_cents do
    Application.fetch_env!(:flux_vale, :access_gateway)[:monthly_cents]
  end
end
