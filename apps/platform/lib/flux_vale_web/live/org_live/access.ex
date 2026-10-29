defmodule FluxValeWeb.OrganizationLive.Access do
  @moduledoc """
  Org settings, Access tab (#273, ADR-0039): the private-access
  gateway's owner surface — enable, watch, re-paste the key, resume
  after suspension, remove. Instance pairing (attach/detach) is the
  next slice; this tab is the gateway's lifecycle only.

  Slug-keyed mount like the sibling tabs; unknown slugs (and policy
  denials) read as "not here" — never a bare 404. Owners-only in the
  panel is a UX gate, not the authority: the actions' own policies
  (membership, funded wallet) are what actually forbid a call.

  Live updates ride the gateway's per-org PubSub topic — every state
  write (the observer's minute tick included) lands here, and the
  teardown's hard delete refetches the panel to the empty state. The
  auth key is write-only: a password input, never rendered back.
  """

  use FluxValeWeb, :live_view

  alias Ash.Error.Forbidden
  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Checks.ActorOrgWalletFunded
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
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
           |> refresh_funded()
           |> assign_forms()}
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
    form = AshPhoenix.Form.validate(socket.assigns.form, form_params(params, socket))

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
          # says so instead of rendering a field error.
          {:noreply,
           socket
           |> put_flash(:error, "Top up before enabling private access.")
           |> assign(form: form)}
        else
          {:noreply, assign(socket, form: form)}
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
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("toggle-repaste", _params, socket) do
    {:noreply, assign(socket, repaste_open?: not socket.assigns.repaste_open?)}
  end

  def handle_event("arm-remove", _params, socket) do
    {:noreply, assign(socket, remove_armed?: true)}
  end

  def handle_event("cancel-remove", _params, socket) do
    {:noreply, assign(socket, remove_armed?: false)}
  end

  # Guarded: only an armed panel removes — every path here passes
  # through the explicit confirm callout first (Settings' armed-rename
  # posture), so a crafted click cannot delete on its own.
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

      {:error, _reason} ->
        # A transient failure mid-resume (the scale call) — the row kept
        # :suspended, so the retry is the same button.
        {:noreply, put_flash(socket, :error, "Could not resume private access — try again.")}
    end
  end

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
  # wipe a half-typed key out of the re-paste form.
  defp maybe_rebuild_panel(socket, gateway, previous) do
    if state_of(gateway) == previous do
      socket
    else
      socket
      |> assign(repaste_open?: repaste_open_for(gateway), remove_armed?: false)
      |> assign_forms()
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      actor_orgs={@actor_orgs}
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
            Connecting — usually under a minute. This page updates on its own.
          </p>
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

  # A policy denial arrives as a Forbidden error inside the form — not
  # a field error an input can render. The flash is the friendly copy;
  # the empty state's own hint names the fix before the click. (The
  # form path carries the INNER Policy error; the code-interface resume
  # path carries the Forbidden class.)
  defp forbidden?(form) do
    Enum.any?(form.source.source.errors, &match?(%Ash.Error.Forbidden.Policy{}, &1))
  end

  defp refresh_funded(socket) do
    assign(socket, funded?: ActorOrgWalletFunded.org_funded?(socket.assigns.org.id))
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
