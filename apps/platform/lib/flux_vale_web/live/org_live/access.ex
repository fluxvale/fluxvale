defmodule FluxValeWeb.OrganizationLive.Access do
  @moduledoc """
  Org settings, Access tab (#273, ADR-0039): the private-access
  gateway's owner surface — enable, watch, re-paste the key, resume
  after suspension, remove, and pair instances (attach/detach, §4.1 —
  the owner's reachability switch).

  Slug-keyed mount like the sibling tabs; unknown slugs (and policy
  denials) read as "not here" — never a bare 404. Owners-only in the
  panel is a UX gate, not the authority: the actions' own policies
  (membership, funded wallet) are what actually forbid a call. The
  wallet hints report the wallet each affordance acts on — enable bills
  the page org (#408: the create names it), resume the row's org.

  S5: the personal org's access panel moved INTO user settings —
  `/settings/access` mounts this same LiveView under the named
  `:personal` action and serves the actor's personal org, so the
  slug-keyed route for a personal slug redirects there. The two heads
  are kept apart by the route's action: a `?slug=` query param on the
  personal route is refused as not-found (LiveView merges query params
  into mount params — without the named head it would mount the org
  frame on the personal page). The org chrome (header, tabs) renders
  for real orgs only; the personal page carries the user-settings
  frame.

  Live updates ride the gateway's per-org PubSub topic — every state
  write publishes there (the observer's minute tick, the ladder's
  suspension, a resume from another tab), and the teardown's hard
  delete refetches the panel to the empty state. The auth key is
  write-only: a password input, and no read-back path ever returns the
  stored key (ADR-0039 §4).

  #836: the enable takes one credential — the OAuth client pair
  (preferred, lane B: the platform exchanges it and mints every join
  key), the API token, or the fallback auth key; a stored credential
  makes reconnect a zero-paste click, with the key input behind an
  explicit fallback toggle.

  #635: the Device sign-ins (#362) and API tokens (#483) sections
  moved OUT of this page to /settings/developer
  (DeveloperSettingsLive) — developer tooling, not the access surface.
  The /settings/access/device landing redirects there at the section
  anchor.
  """

  use FluxValeWeb, :live_view

  alias Ash.Error.Forbidden
  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Checks.ActorOrgHasPaid
  alias FluxVale.Checks.ActorOrgWalletFunded
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing
  alias FluxValeWeb.AccountSettings
  alias FluxValeWeb.OrgSettings
  alias FluxValeWeb.PersonalOrg

  # #250 S6: the paid-feature hint names the wallet floor the wizard
  # enforces (FluxVale.Billing's config), never a hardcoded amount.
  @min_topup_dollars FluxVale.Billing.min_topup_dollars()

  @impl Phoenix.LiveView
  # The :personal route's contract is NO slug — but LiveView merges query
  # params into mount params, so `/settings/access?slug=…` lands in mount
  # with one and would take the slug-keyed head below, mounting the org
  # frame (header, tabs, the URL org's gateway and its PubSub topic) on
  # the personal route — a page whose enable form would name the URL org
  # while the frame shows the personal one, and that the created row's
  # own topic can never update. So on this route the param is refused
  # outright: not-found, the codebase's posture for a hand-typed path.
  # (First clause: it must win over the slug-keyed head for this action.)
  def mount(%{"slug" => _refused}, _session, %{assigns: %{live_action: :personal}} = socket) do
    {:ok,
     socket
     |> put_flash(:error, "Organization not found.")
     |> push_navigate(to: ~p"/")}
  end

  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Organization.get_by_slug(slug, actor: user) do
      {:ok, org} ->
        cond do
          # S5: the personal org never renders an org page — its access
          # panel lives at /settings/access, served below by this same
          # module without a slug. Flash-free (nothing failed).
          PersonalOrg.personal?(socket, org) ->
            {:ok, push_navigate(socket, to: ~p"/settings/access")}

          # UX gate, not the authority: the actions' own policies (member
          # read, funded-wallet create/resume) are what actually forbid a
          # non-owner call. This only spares a member a settings surface
          # that is owners-only by design — same posture as Settings.
          ActorIsOrganizationOwner.owner?(user, org) ->
            {:ok, mount_panel(socket, org, user)}

          true ->
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

  # /settings/access (:personal, S5): the personal account's access
  # panel. The org is the actor's personal org through the canonical
  # resolver — its :owner-membership filter IS the owner gate here, so
  # no separate check. No slug in the contract, nothing to enumerate.
  def mount(_params, _session, %{assigns: %{live_action: :personal}} = socket) do
    user = socket.assigns.current_user

    case PersonalOrg.org_for(user) do
      {:ok, org} ->
        {:ok, mount_panel(socket, org, user)}

      # Seeded/legacy no-personal-org shape (OrgNav's stance) — the
      # surface isn't here; the sibling not-found arm's answer.
      :none ->
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
         |> push_navigate(to: ~p"/")}

      # defensive: DB read failure, not simulatable under the
      # sandbox. Same degrade as the slug arm's miss.
      # coveralls-ignore-start
      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
         |> push_navigate(to: ~p"/")}

        # coveralls-ignore-stop
    end
  end

  # The panel setup both routes share — one gateway per org, whatever
  # resolved it (URL slug or the actor's personal org). The route's own
  # action picks the chrome: the org frame (header, tabs, org billing
  # links) for the slug route, the user-settings frame for :personal.
  defp mount_panel(%{assigns: %{live_action: :personal}} = socket, org, user) do
    mount_panel_for(socket, org, user, true)
  end

  defp mount_panel(socket, org, user) do
    mount_panel_for(socket, org, user, false)
  end

  defp mount_panel_for(socket, org, user, personal?) do
    # The per-org topic, never a global one: every gateway write
    # broadcasts here, so only this org's open panels refetch.
    Phoenix.PubSub.subscribe(FluxVale.PubSub, "access_gateways:#{org.id}")

    gateway = fetch_gateway(org, user)

    socket
    |> assign(
      org: org,
      personal?: personal?,
      current_org: if(personal?, do: nil, else: org),
      billing_path: billing_path(org, personal?),
      gateway: gateway,
      price_cents: monthly_cents()
    )
    |> assign(
      repaste_open?: repaste_open_for(gateway),
      repaste_key_fallback?: false,
      token_api_fallback?: false,
      remove_armed?: false
    )
    |> assign(attach_error: nil)
    |> stream_configure(:attached, dom_id: &"access-attached-#{&1.route.id}")
    |> stream_configure(:attachable, dom_id: &"access-attach-#{&1.id}")
    |> refresh_wallet_gates()
    |> assign_forms()
    |> assign_domains()
    |> refresh_pairing()
  end

  # The top-up links inside the panel: a real org bills at its org URL,
  # the personal org at /billing (S5 — one wallet, one surface).
  defp billing_path(_org, true), do: ~p"/billing"
  defp billing_path(org, false), do: ~p"/organizations/#{org.slug}/billing"

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
         |> put_flash(:info, "Private access is connecting. This page updates on its own.")
         |> assign(gateway: loaded_gateway(socket, gateway))
         |> assign(
           repaste_open?: repaste_open_for(gateway),
           repaste_key_fallback?: false,
           remove_armed?: false
         )
         |> assign_forms()}

      {:error, form} ->
        if forbidden?(form) do
          # A policy gate (funded or paid-once) — the fix is the wallet,
          # so the copy says so instead of rendering a field error. The
          # form is rebuilt from the row (no key echo — see
          # clear_key_display) and carries only the errors.
          {:noreply,
           socket
           |> put_flash(:error, "Top up before enabling private access.")
           |> rebuild_form_with_errors(form)}
        else
          {:noreply,
           socket
           |> put_flash(:error, "Couldn't enable private access. Try again.")
           |> rebuild_form_with_errors(form)}
        end
    end
  end

  # Re-paste — the NeedsLogin / deleted-node recovery, and #836's mint
  # reconnect: the token-state form submits with NO key (the platform
  # mints the join key); the copy stays "reconnect", never the
  # machinery underneath.
  def handle_event("repaste", %{"gateway" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, gateway} ->
        {:noreply,
         socket
         |> put_flash(:info, "Reconnecting with the new key. This page updates on its own.")
         |> assign(gateway: loaded_gateway(socket, gateway))
         |> assign(repaste_open?: repaste_open_for(gateway), repaste_key_fallback?: false)
         |> assign_forms()}

      {:error, form} ->
        # The engine's own answer (the change writes the mint copy — the
        # 403's "paste an auth key instead" among them) lands on the
        # :auth_key field, which the token state keeps hidden behind the
        # fallback toggle: reveal it so the sentence is actually
        # readable. The form rebuilds from the row carrying only the
        # errors: the submitted key is not echoed back (ADR-0039 §4).
        {:noreply,
         socket
         |> put_flash(:error, "Couldn't update the access key. Try again.")
         |> assign(repaste_key_fallback?: true)
         |> rebuild_form_with_errors(form)}
    end
  end

  # A submit with no gateway payload at all (the mint form has no
  # visible inputs, and a crafted empty event should never crash) is
  # the same empty-params submit — the action decides mint vs paste.
  def handle_event("repaste", _no_gateway_payload, socket) do
    handle_event("repaste", %{"gateway" => %{}}, socket)
  end

  def handle_event("toggle-repaste", _params, socket) do
    {:noreply,
     assign(socket,
       repaste_open?: not socket.assigns.repaste_open?,
       repaste_key_fallback?: false
     )}
  end

  # #836's fallback toggle — "Paste an auth key instead" reveals the
  # key input the mint 403 copy names as the exit. Client state only;
  # the submit's own payload picks the path.
  def handle_event("toggle-repaste-key", _params, socket) do
    {:noreply, assign(socket, repaste_key_fallback?: not socket.assigns.repaste_key_fallback?)}
  end

  # #836 lane B's alternate toggle — "Use an API token instead" reveals
  # the console-token input the preferred client pair displaces. Client
  # state only; the submit's own payload picks the credential shape.
  def handle_event("toggle-token-api", _params, socket) do
    {:noreply, assign(socket, token_api_fallback?: not socket.assigns.token_api_fallback?)}
  end

  # #760: the API token is a paste-only secret — the auth-key posture,
  # one field, no reveal, no read-back. The submit runs the gateway's
  # :set_api_token action, which also claims the org's verified domains.
  # The empty state (no gateway) has no token form; a stale or crafted
  # event must be a no-op, never a crash whose report could carry the
  # payload (the remove family's posture).
  def handle_event("validate-token", _params, %{assigns: %{token_form: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("save-token", _params, %{assigns: %{token_form: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("validate-token", %{"gateway" => params}, socket) do
    # A validate round-trip is a read-back (ADR-0039 §4): the strip
    # pulls both secret halves out of the assigned form (argument,
    # params, raw_params — the same three places the enable form's
    # clear_key_display scrubs), so the socket state never carries them
    # and a crash dump cannot either. The client id is NOT a secret —
    # it stays, so the patch keeps it rendered while the user types the
    # secret half (the enable form's domain-field posture).
    form =
      socket.assigns.token_form
      |> AshPhoenix.Form.validate(params)
      |> strip_token_secrets()

    {:noreply, assign(socket, token_form: form)}
  end

  def handle_event("save-token", %{"gateway" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.token_form, params: params) do
      {:ok, gateway} ->
        # The claim sweep ran inside the action's after_transaction; a
        # fresh read is what carries the landed claims into the panel.
        fresh = fetch_gateway(socket.assigns.org, socket.assigns.current_user)

        {:noreply,
         socket
         |> put_flash(:info, "Token saved.")
         |> assign(gateway: fresh || loaded_gateway(socket, gateway))
         |> assign_forms()
         |> assign_domains()}

      {:error, form} ->
        # Field-less failures (and the write's own message) surface as a
        # flash; the form rebuilds from the row with only its errors, so
        # the submitted token never echoes back (ADR-0039 §4).
        {:noreply,
         socket
         |> put_flash(:error, "Couldn't save the access token. Try again.")
         |> rebuild_token_form_with_errors(form)}
    end
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
             |> put_flash(:info, "Removing private access. Billing stops now.")
             |> assign(gateway: loaded_gateway(socket, gateway))
             |> assign(remove_armed?: false)
             |> assign_forms()}

          {:error, _reason} ->
            # The stale-view arm: the row vanished (teardown won the
            # race) — the next broadcast lands the empty state.
            {:noreply, put_flash(socket, :error, "Could not remove private access. Try again.")}
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
         |> put_flash(:info, "Retrying removal. This page updates on its own.")
         |> assign(gateway: loaded_gateway(socket, gateway))
         |> assign(remove_armed?: false)
         |> assign_forms()}

      {:error, _reason} ->
        # The stale-view arm: the row vanished (the in-flight teardown
        # won) — the next broadcast lands the empty state.
        {:noreply, put_flash(socket, :error, "Could not remove private access. Try again.")}
    end
  end

  # The zero-balance ladder's undo — the engine's funded-wallet policy
  # is the authority; the flash just says what the wallet needs.
  def handle_event("resume", _params, socket) do
    case AccessGateway.resume(socket.assigns.gateway, actor: socket.assigns.current_user) do
      {:ok, gateway} ->
        {:noreply,
         socket
         |> put_flash(:info, "Private access is reconnecting. This page updates on its own.")
         |> assign(gateway: loaded_gateway(socket, gateway))
         |> refresh_wallet_gates()
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
           put_flash(socket, :error, "This gateway changed underneath you. Reload to continue.")}
        else
          # A transient failure mid-resume (the scale call) — the row
          # kept :suspended, so the retry is the same button.
          {:noreply, put_flash(socket, :error, "Could not resume private access. Try again.")}
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
            {:noreply, put_flash(socket, :error, "Couldn't detach. Try again.")}
        end

      _gone ->
        # Stale row (CodeRabbit round): refresh alongside the retry copy
        # so a vanished instance leaves the attached list, not a ghost
        # that re-fails every click.
        {:noreply,
         socket
         |> put_flash(:error, "Couldn't detach. Try again.")
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
      |> refresh_wallet_gates()
      |> assign_domains()
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
      |> assign(
        repaste_open?: repaste_open_for(gateway),
        repaste_key_fallback?: false,
        remove_armed?: false
      )
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
      current_org={@current_org}
      bare
    >
      <%!-- App-wide grammar page (S10): `bare` main + .appgram — the
      page owns ALL of main's rhythm. This is the mono-panel grammar's
      dense home: the gateway's technical reality (hostname, rate, the
      pairing rows) in the sunken mono register, the ACTIONS on raised
      cards — the instance-show pattern, asymmetric. --%>
      <div class="appgram contents">
        <%= if @personal? do %>
          <%!-- S5: the personal account's frame — the account band and
          the way back. No org chrome here: the personal org is the
          account, never presented as an org. --%>
          <section class="band">
            <div class="wrap pt-8 pb-10">
              <div class="rise">
                <.link
                  navigate={~p"/settings"}
                  data-testid="settings-access-back"
                  class="inline-flex items-center gap-1.5 text-sm text-ink-muted transition-colors hover:text-ink"
                >
                  <span aria-hidden="true">&larr;</span> Settings
                </.link>
                <div class="mt-3 min-w-0">
                  <h1 class="page-title mt-1.5" data-testid="settings-title">
                    Account settings
                  </h1>
                </div>
              </div>
            </div>
          </section>
        <% else %>
          <OrgSettings.org_header org={@org} surface="Access" />
        <% end %>

        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <%!-- #551: the account cluster's section sidebar rides the
            personal head only — the org head keeps the org rail below. --%>
            <AccountSettings.sidebar
              :if={@personal?}
              current="access"
              personal_org_id={@personal_org_id}
            />

            <div class="min-w-0 flex-1 space-y-6">
              <OrgSettings.settings_tabs :if={!@personal?} current="access" slug={@org.slug} />

              <div>
                <h2 class="text-base font-medium text-ink">Access</h2>
                <p class="mt-1 text-sm text-ink-muted">
                  Reach your private apps from your own Tailscale network.
                </p>
              </div>

              <%= if @gateway do %>
                <.gateway_card
                  gateway={@gateway}
                  form={@form}
                  token_form={@token_form}
                  row_funded?={@row_funded?}
                  row_paid?={@row_paid?}
                  billing_path={@billing_path}
                  repaste_open?={@repaste_open?}
                  repaste_key_fallback?={@repaste_key_fallback?}
                  token_api_fallback?={@token_api_fallback?}
                  remove_armed?={@remove_armed?}
                />

                <.domains_card :if={@domains != []} domains={@domains} />

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
                <.access_empty_state
                  personal?={@personal?}
                  form={@form}
                  create_funded?={@create_funded?}
                  create_paid?={@create_paid?}
                  billing_path={@billing_path}
                  price_cents={@price_cents}
                />
              <% end %>

              <%!-- #635: the Device sign-ins and API tokens sections
                moved to /settings/developer — nothing renders here
                after the pairing cards. --%>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The no-gateway surface: what private access is, the three tailnet
  # prerequisites the panel cannot do for the owner (ADR-0039 §8 — it
  # only names them), the price, and the key intake. `personal?` picks
  # the explainer's noun — the account on the personal frame, the
  # organization on the org frame (S5: the personal org never presents
  # as one, copy included).
  attr(:personal?, :boolean, required: true)
  attr(:billing_path, :string, required: true)
  attr(:form, :any, required: true)
  attr(:create_funded?, :boolean, required: true)
  attr(:create_paid?, :boolean, required: true)
  attr(:price_cents, :integer, required: true)

  defp access_empty_state(assigns) do
    assigns = assign(assigns, :min_topup_dollars, @min_topup_dollars)

    ~H"""
    <div class="max-w-2xl space-y-6" data-testid="access-empty">
      <.card id="access-intro-card" class="card space-y-4">
        <div>
          <h3 class="text-sm font-medium text-ink-muted">Private access</h3>
          <p class="mt-2 text-sm text-ink" data-testid="access-explainer">
            Put your private apps on your own Tailscale network, reachable from your own
            devices, never the public internet.
            <%= if @personal? do %>
              One gateway serves every app in your organization and each app gets its own
              address on it.
            <% else %>
              One gateway serves the whole organization and each app gets its own address on
              it.
            <% end %>
          </p>
        </div>

        <div data-testid="access-prereqs">
          <p class="text-sm font-medium text-ink">
            Before you start, set up once in your Tailscale admin console:
          </p>
          <ul class="mt-2 list-disc space-y-1 pl-5 text-sm text-ink-muted">
            <li>
              Create the tag <span class="font-mono">tag:fluxvale-gateway</span> in your ACL
              and make yourself its owner.
            </li>
            <li>Turn on MagicDNS.</li>
            <li>Turn on HTTPS on the DNS page.</li>
          </ul>
        </div>

        <p class="text-sm text-ink" data-testid="access-price">
          <span class="font-mono">{Pricing.format_usd(@price_cents)}</span>/month, billed hourly
          while connected.
        </p>

        <%!-- The blocking gate's own hint, shown up front: a wallet that
            has never PAID sees the paid-once callout (the welcome credit
            does not unlock enablement), a paid-but-empty one the balance
            copy. Two testids — the states assert separately. --%>
        <.callout
          :if={!@create_paid?}
          id="access-paid-hint"
          tone="warning"
          data-testid="access-paid-hint"
        >
          <p>
            Private access needs a one-time top-up of at least ${@min_topup_dollars}. Add funds in <.link
              navigate={@billing_path}
              class="underline underline-offset-2 hover:text-ink"
              data-testid="access-paid-link"
            >
              Billing
            </.link>.
          </p>
        </.callout>

        <.callout
          :if={@create_paid? and !@create_funded?}
          id="access-prefund-hint"
          tone="warning"
          data-testid="access-prefund-hint"
        >
          <p>
            Your balance is empty. Top up before enabling private access. Start from <.link
              navigate={@billing_path}
              class="underline underline-offset-2 hover:text-ink"
              data-testid="access-prefund-link"
            >
              Billing
            </.link>.
          </p>
        </.callout>
      </.card>

      <.card id="access-enable-card" class="card space-y-4">
        <div>
          <h3 class="text-sm font-medium text-ink-muted">Enable private access</h3>
          <p class="mt-1 text-sm text-ink-muted">
            Paste one credential: your Tailscale OAuth client (preferred), an API token, or an
            auth key. Whichever you paste is stored in our own secret store and never shown
            again.
          </p>
          <p class="mt-1 text-xs text-ink-muted" data-testid="access-tagowners-note">
            Your tailnet's ACL must own <span class="font-mono">tag:fluxvale-gateway</span>
            (Tailscale admin console → Access Controls), or the join will not complete.
          </p>
          <p class="mt-1 text-xs text-ink-muted" data-testid="access-client-tag-note">
            The OAuth client must carry <span class="font-mono">tag:fluxvale-gateway</span>
            too — join keys minted from it can only carry the client's own tags.
          </p>
        </div>

        <.form for={@form} id="access-enable-form" phx-change="validate" phx-submit="enable">
          <div class="space-y-4">
            <.input
              field={@form[:ts_client_id]}
              type="text"
              label="Client ID"
              placeholder="k1234567890abcdef…"
              data-testid="access-enable-client-id-input"
            />
            <.input
              field={@form[:ts_client_secret]}
              type="password"
              label="Client secret"
              placeholder="Your OAuth client's secret"
              data-testid="access-enable-client-secret-input"
            />
            <p class="text-xs text-ink-muted">
              The preferred path: an OAuth client from your Tailscale admin console
              (Settings → OAuth clients) with the <span class="font-mono">auth_keys</span>, <span class="font-mono">dns</span>,
              and <span class="font-mono">devices:routes</span>
              scopes (write) plus <span class="font-mono">devices:core:read</span>,
              carrying the <span class="font-mono">tag:fluxvale-gateway</span>
              tag. We mint every join key from it — no
              Tailscale-side key handling at all.
            </p>

            <div class="border-t border-line pt-4">
              <.input
                field={@form[:api_token]}
                type="password"
                label="API token"
                placeholder="tskey-api-…"
                data-testid="access-api-token-input"
              />
              <p class="text-xs text-ink-muted">
                The alternate: we create the join key for you from this console token. Mint it
                from a tailnet owner or admin account (admin console → Settings → Keys →
                Generate API token) — the token carries that account's permissions.
              </p>
              <.input
                field={@form[:auth_key]}
                type="password"
                label="Auth key"
                placeholder="tskey-auth-…"
                data-testid="access-key-input"
              />
              <p class="text-xs text-ink-muted">
                The fallback: a reusable auth key from your Tailscale admin console.
              </p>
            </div>

            <.input
              field={@form[:tailnet_domain]}
              type="text"
              label="Tailnet domain"
              placeholder="your-tailnet.ts.net"
              required
              data-testid="access-domain-input"
            />
            <p class="text-xs text-ink-muted">
              Your tailnet's DNS name, the part after the first dot in any of your
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

  attr(:gateway, AccessGateway, required: true)
  attr(:form, :any, required: true)
  attr(:token_form, :any, required: true)
  attr(:row_funded?, :boolean, required: true)
  attr(:row_paid?, :boolean, required: true)
  attr(:billing_path, :string, required: true)
  attr(:repaste_open?, :boolean, required: true)
  attr(:repaste_key_fallback?, :boolean, required: true)
  attr(:token_api_fallback?, :boolean, required: true)
  attr(:remove_armed?, :boolean, required: true)

  defp gateway_card(assigns) do
    ~H"""
    <%!-- The instance-show pattern: the technical reality in the sunken
    mono panel beside the raised actions card, asymmetric (1.4fr/1fr —
    no fake symmetry). The panel carries what the gateway IS (state,
    hostname, rate); the card carries what you DO (re-paste, remove,
    resume) — actions stay form surfaces, never sunken. --%>
    <div class="min-w-0 items-start gap-6 space-y-6 lg:grid lg:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)] lg:space-y-0">
      <div class="mono-panel min-w-0 space-y-3" data-testid="access-gateway-card">
        <div class="flex items-center gap-2">
          <h3 class="mono-panel-label mb-0">Private access</h3>
          <.status_badge status={@gateway.state} />
        </div>

        <div class="grid gap-1.5">
          <p class="flex gap-4">
            <span class="w-24 shrink-0">hostname:</span>
            <span
              class="min-w-0 text-ink [overflow-wrap:anywhere]"
              data-testid="access-hostname"
            >
              {@gateway.hostname}
            </span>
          </p>
          <p class="flex gap-4">
            <span class="w-24 shrink-0">rate:</span>
            <span class="min-w-0" data-testid="access-billing-line">
              {Pricing.format_usd(@gateway.monthly_cents)}/month, billed hourly while
              connected. Suspended or removed, nothing accrues.
            </span>
          </p>
        </div>
      </div>

      <.card class="card min-w-0 space-y-4">
        <%!-- the engine's own words for the state — written friendly by
        design (the #179 split: technical detail never leaves the row). --%>
        <p
          :if={@gateway.status_message}
          class="text-sm text-ink"
          data-testid="access-status-message"
        >
          {@gateway.status_message}
        </p>

        <.gateway_actions
          gateway={@gateway}
          form={@form}
          token_form={@token_form}
          row_funded?={@row_funded?}
          row_paid?={@row_paid?}
          billing_path={@billing_path}
          repaste_open?={@repaste_open?}
          repaste_key_fallback?={@repaste_key_fallback?}
          token_api_fallback?={@token_api_fallback?}
          remove_armed?={@remove_armed?}
        />
      </.card>
    </div>
    """
  end

  attr(:gateway, AccessGateway, required: true)
  attr(:form, :any, required: true)
  attr(:token_form, :any, required: true)
  attr(:row_funded?, :boolean, required: true)
  attr(:row_paid?, :boolean, required: true)
  attr(:billing_path, :string, required: true)
  attr(:repaste_open?, :boolean, required: true)
  attr(:repaste_key_fallback?, :boolean, required: true)
  attr(:token_api_fallback?, :boolean, required: true)
  attr(:remove_armed?, :boolean, required: true)

  defp gateway_actions(assigns) do
    ~H"""
    <div class="space-y-4">
      <%= cond do %>
        <% @gateway.state == :provisioning -> %>
          <p class="text-sm text-ink-muted" data-testid="access-connecting-note">
            Setting up access, usually under a minute. If it sticks, reconnect with
            your key.
          </p>
          <.repaste_panel
            form={@form}
            open?={@repaste_open?}
            token_set?={api_token_set?(@gateway)}
            key_fallback?={@repaste_key_fallback?}
            toggle_label="Re-paste key"
            submit_label="Save key"
          />
        <% @gateway.state == :active -> %>
          <.token_panel
            form={@token_form}
            token_set_at={@gateway.token_set_at}
            token_api_fallback?={@token_api_fallback?}
          />
          <.repaste_panel
            form={@form}
            open?={@repaste_open?}
            token_set?={api_token_set?(@gateway)}
            key_fallback?={@repaste_key_fallback?}
            toggle_label="Re-paste key"
            submit_label="Save key"
          />
          <.remove_panel armed?={@remove_armed?} />
        <% @gateway.state == :needs_attention -> %>
          <.callout id="access-attention-note" tone="warning" data-testid="access-attention-note">
            <p>
              We can't reach your gateway. The key may have expired, or the node was
              removed from your Tailscale admin console. Paste a fresh key to reconnect.
            </p>
          </.callout>
          <.token_panel
            form={@token_form}
            token_set_at={@gateway.token_set_at}
            token_api_fallback?={@token_api_fallback?}
          />
          <.repaste_panel
            form={@form}
            open?={@repaste_open?}
            token_set?={api_token_set?(@gateway)}
            key_fallback?={@repaste_key_fallback?}
            toggle_label="Reconnect"
            submit_label="Reconnect"
            prominent?
          />
          <.remove_panel armed?={@remove_armed?} />
        <% @gateway.state == :suspended -> %>
          <.suspended_panel
            row_funded?={@row_funded?}
            row_paid?={@row_paid?}
            billing_path={@billing_path}
          />
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

  # #756: the claim state's member-visible half. Claims are a separate
  # truth from issuance (the admin page's own stance), so each row
  # carries both — and a verified-but-unclaimed domain names the fix.
  defp assign_domains(socket) do
    %{org: org, gateway: gateway, current_user: user} = socket.assigns

    claimed = claimed_names(gateway)

    rows =
      org.id
      |> AccessDomain.list_for_org!(actor: user)
      |> Enum.filter(&(&1.kind == :custom))
      |> Enum.sort_by(& &1.domain)
      |> Enum.map(fn domain ->
        %{
          domain: domain.domain,
          state: domain.state,
          claimed?: domain.domain in claimed
        }
      end)

    assign(socket, domains: rows)
  end

  defp claimed_names(nil), do: []

  defp claimed_names(%{dns_claims: claims}) when is_map(claims) and not is_struct(claims),
    do: Map.keys(claims)

  defp claimed_names(_gateway), do: []

  # Two truths per row (the admin page's stance): the registered state
  # and the claim are separate, so a claimed domain whose certificate
  # needs attention still says so.
  defp domain_state_label(%{state: :verified}), do: "Verified"
  defp domain_state_label(%{state: :pending}), do: "Verifying…"
  defp domain_state_label(%{state: :failed}), do: "Verification failed"
  defp domain_state_label(%{state: :needs_attention}), do: "Certificate needs attention"
  defp domain_state_label(%{state: :suspended}), do: "Suspended"

  # coveralls-ignore-start - a state the panel has no label for yet (a
  # future enum value): the honest generic beats crashing the card.
  defp domain_state_label(_domain), do: "Not verified"

  # coveralls-ignore-stop

  defp domain_claim_label(%{claimed?: true}), do: "Claimed on your tailnet"
  defp domain_claim_label(_domain), do: "Not claimed yet"

  attr(:domains, :list, required: true)

  defp domains_card(assigns) do
    ~H"""
    <.card id="access-domains-card" class="card space-y-3" data-testid="access-domains">
      <div>
        <h3 class="text-sm font-medium text-ink">Domains</h3>
        <p class="mt-1 text-xs text-ink-muted">
          Custom domains your organization registered. A verified domain resolves on your
          tailnet once the gateway claims it — the gateway's API token is what claims, and its
          card appears while the gateway is active.
        </p>
      </div>

      <ul class="divide-y divide-line text-sm">
        <li
          :for={domain <- @domains}
          class="flex items-center justify-between gap-3 py-2"
          data-testid="access-domain-row"
        >
          <span class="min-w-0 truncate font-mono text-xs" data-testid="access-domain-name">
            {domain.domain}
          </span>
          <span class="flex shrink-0 items-center gap-2">
            <span class="text-xs text-ink-subtle" data-testid="access-domain-state">
              {domain_state_label(domain)}
            </span>
            <span
              :if={domain.claimed?}
              class="text-xs text-ink-muted"
              data-testid="access-domain-claim"
            >
              {domain_claim_label(domain)}
            </span>
            <span
              :if={not domain.claimed?}
              class="text-xs text-ink-subtle"
              data-testid="access-domain-unclaimed"
            >
              {domain_claim_label(domain)}
            </span>
          </span>
        </li>
      </ul>
    </.card>
    """
  end

  attr(:form, :any, required: true)
  attr(:token_set_at, :any, required: true)
  attr(:token_api_fallback?, :boolean, required: true)

  # The token card (#760), now carrying either credential shape (#836
  # lane B): the OAuth client pair preferred — the platform exchanges it
  # and mints every join key from the derived token — with the console
  # API access token behind the explicit "Use an API token instead"
  # toggle (the repaste panel's alternate voice). The pair's copy names
  # the console path and the scope set; the tag-pairing line is the
  # addendum's coupling ruling (a client mints only its own tags).
  defp token_panel(assigns) do
    ~H"""
    <div class="border-t border-line pt-4" data-testid="access-api-token">
      <div>
        <h3 class="text-sm font-medium text-ink">Tailscale credential</h3>
        <p class="mt-1 text-xs text-ink-muted">
          Needed to claim your domains on your tailnet — and the platform creates every
          join key from it.
        </p>
        <p
          :if={@token_set_at}
          class="mt-1 text-xs text-ink-subtle"
          data-testid="access-api-token-age"
        >
          Credential set {Calendar.strftime(@token_set_at, "%b %d, %Y")}. Tailscale API keys
          expire within 90 days — paste a fresh one before then.
        </p>
      </div>

      <.form
        for={@form}
        id="access-api-token-form"
        phx-change="validate-token"
        phx-submit="save-token"
        class="space-y-3"
      >
        <.input
          field={@form[:ts_client_id]}
          type="text"
          label="Client ID"
          placeholder="k1234567890abcdef…"
          data-testid="access-client-id-input"
        />
        <.input
          field={@form[:ts_client_secret]}
          type="password"
          label="Client secret"
          placeholder="Your OAuth client's secret"
          data-testid="access-client-secret-input"
        />
        <p class="text-xs text-ink-muted" data-testid="access-client-copy">
          The preferred credential: an OAuth client from your Tailscale admin console
          (Settings → OAuth clients) with the <span class="font-mono">auth_keys</span>, <span class="font-mono">dns</span>,
          and <span class="font-mono">devices:routes</span>
          scopes (write) plus <span class="font-mono">devices:core:read</span>
          —
          carrying the <span class="font-mono">tag:fluxvale-gateway</span>
          tag, since a client can only mint join keys
          that carry its own tags.
        </p>
        <p class="text-xs text-ink-muted">
          Whichever shape you save is stored write-only and never shown again. Saving claims
          the domains you have already verified.
        </p>
        <div class="flex justify-end">
          <.button type="submit" size="sm" data-testid="access-api-token-save">
            Save credential
          </.button>
        </div>

        <%= if @token_api_fallback? do %>
          <div class="border-t border-line pt-3">
            <.input
              field={@form[:api_token]}
              type="password"
              label="API token"
              placeholder="tskey-api-…"
              data-testid="access-api-token-input"
            />
            <p class="text-xs text-ink-muted">
              The alternate: a console API access token (admin console → Settings → Keys →
              API access tokens). It carries the permissions of the account that minted it.
            </p>
            <.button
              type="button"
              phx-click="toggle-token-api"
              variant="ghost"
              size="sm"
              data-testid="access-token-fallback-hide"
            >
              Use the client pair instead
            </.button>
          </div>
        <% else %>
          <.button
            type="button"
            phx-click="toggle-token-api"
            variant="ghost"
            size="sm"
            data-testid="access-token-fallback"
          >
            Use an API token instead
          </.button>
        <% end %>
      </.form>
    </div>
    """
  end

  attr(:form, :any, required: true)
  attr(:open?, :boolean, required: true)
  attr(:toggle_label, :string, required: true)
  attr(:submit_label, :string, required: true)
  attr(:prominent?, :boolean, default: false)
  attr(:token_set?, :boolean, required: true)
  attr(:key_fallback?, :boolean, required: true)

  defp repaste_panel(assigns) do
    ~H"""
    <div data-testid="access-repaste">
      <%= if @token_set? do %>
        <%!-- #836: a stored token makes reconnect a zero-paste click —
        the platform creates the join key from it, no input to fill. The
        key input stays hidden until the fallback toggle reveals it (the
        mint 403 copy's named exit, the #837 review amendment); the
        revealed form is today's paste path. --%>
        <.form
          for={@form}
          id="access-repaste-form"
          phx-change="validate"
          phx-submit="repaste"
          class="space-y-3"
        >
          <%= if @key_fallback? do %>
            <.input
              field={@form[:auth_key]}
              type="password"
              label="Auth key"
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
                Reconnect
              </.button>
              <.button
                type="button"
                phx-click="toggle-repaste-key"
                variant="ghost"
                size="sm"
                data-testid="access-repaste-fallback-hide"
              >
                Cancel
              </.button>
            </div>
          <% else %>
            <div class="flex gap-3">
              <.button
                type="submit"
                size="sm"
                variant={if(@prominent?, do: "primary", else: "ghost")}
                data-testid="access-reconnect"
              >
                Reconnect
              </.button>
              <.button
                type="button"
                phx-click="toggle-repaste-key"
                variant="ghost"
                size="sm"
                data-testid="access-repaste-fallback"
              >
                Paste an auth key instead
              </.button>
            </div>
          <% end %>
        </.form>
      <% else %>
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
            Remove private access? Your private apps fall back to panel-only private,
            reachable only inside FluxVale, and billing stops.
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

  # The resume button only where resume can succeed — the ROW's org
  # funded AND paid. A never-paid org (funded on welcome credit alone)
  # would hit the paid-once Forbidden, so it sees the top-up line
  # instead.
  attr(:row_funded?, :boolean, required: true)
  attr(:row_paid?, :boolean, required: true)
  attr(:billing_path, :string, required: true)

  defp suspended_panel(assigns) do
    ~H"""
    <div class="space-y-3" data-testid="access-suspended-banner">
      <.callout id="access-suspended-callout" tone="warning">
        <p>
          Private access is suspended. The balance ran out. Your private apps stay
          reachable only through the panel, and nothing accrues while suspended.
        </p>
      </.callout>
      <%= if @row_funded? and @row_paid? do %>
        <.button type="button" phx-click="resume" size="sm" data-testid="access-resume">
          Resume private access
        </.button>
      <% else %>
        <p class="text-sm text-ink" data-testid="access-resume-topup">
          Top up before resuming private access. Start from <.link
            navigate={@billing_path}
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
    <div class="min-w-0 space-y-3" data-testid="access-attached">
      <div>
        <h3 class="text-sm font-medium text-ink-muted">Attached apps</h3>
        <p class="mt-1 text-sm text-ink-muted">
          Each app gets its own address on your tailnet. Detaching is reversible. A
          detached app is reachable from the panel only again.
        </p>
      </div>

      <%!-- The pairing rows are the gateway's technical reality — the
      sunken mono register (the dav-snippet posture). The row-scoped
      Detach rides its row (the snippet's copy-button precedent);
      panel-level actions stay on cards. Friendly copy (the empty
      line, the public note) overrides the panel's mono so it keeps
      the sans register. --%>
      <div class="mono-panel min-w-0">
        <p
          :if={@attached_empty?}
          class="font-sans text-sm text-ink-muted"
          data-testid="access-attached-empty"
        >
          Nothing attached yet. Pick an app below.
        </p>

        <ul id="access-attached-rows" phx-update="stream" class="divide-y divide-line">
          <li
            :for={{dom_id, row} <- @attached}
            id={dom_id}
            class="space-y-1.5 py-3 first:pt-0 last:pb-0"
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

            <p class="text-xs break-all text-ink" data-testid="access-attached-address">
              {address(row.route, @gateway)}
            </p>

            <%!-- §4.1: the exposure toggle can put a public instance here
                after the fact — the two switches are independent, and the
                row says so honestly instead of hiding it. --%>
            <p
              :if={row.instance.exposure == :public}
              class="font-sans text-xs text-ink-muted"
              data-testid="access-attached-public-note"
            >
              Also public. Anyone can reach it at its own address too.
            </p>
          </li>
        </ul>
      </div>
    </div>
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
    <.card id="access-attach-card" class="card space-y-4" data-testid="access-attach">
      <div>
        <h3 class="text-sm font-medium text-ink-muted">Attach an app</h3>
        <p class="mt-1 text-sm text-ink-muted">
          Give a private app an address on your tailnet. Attaching never changes an
          app's exposure. The two switches stay independent.
        </p>
      </div>

      <.callout :if={@attach_error} id="access-attach-error" tone="warning">
        <p data-testid="access-attach-error">
          {attach_error_copy(@attach_error)}
        </p>
      </.callout>

      <p :if={@attachable_empty?} class="text-sm text-ink-muted" data-testid="access-attach-empty">
        No private apps waiting. Apps show up here while they are private and not
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
  # the UX gate, so a miss here is genuinely "no gateway". The stored-
  # token calc rides every read — the reconnect panel branches on it
  # (#836).
  defp fetch_gateway(org, user) do
    case AccessGateway.get_for_organization(org.id, actor: user) do
      {:ok, gateway} -> Ash.load!(gateway, :api_token_set, actor: user)
      {:error, _not_found} -> nil
    end
  end

  # A form submit returns the row without the stored-token calc the
  # reconnect panel branches on (#836) — the same load fetch_gateway
  # gives every re-read, so the panel renders the right shape wherever
  # the row came from.
  defp loaded_gateway(socket, gateway) do
    Ash.load!(gateway, :api_token_set, actor: socket.assigns.current_user)
  end

  # The stored-token boolean (the resource's public calculation) as the
  # reconnect panel reads it. Nothing renders this card without a
  # gateway, and every path feeding it loads the calc.
  defp api_token_set?(%AccessGateway{api_token_set: true}), do: true
  defp api_token_set?(%AccessGateway{}), do: false

  # The form tracks the panel's state: create when there is no gateway,
  # re-paste when there is.
  defp assign_forms(socket) do
    user = socket.assigns.current_user

    case socket.assigns.gateway do
      nil ->
        form =
          AccessGateway
          |> AshPhoenix.Form.for_create(:create, actor: user, as: "gateway")
          |> to_form()

        assign(socket, form: form, token_form: nil)

      gateway ->
        form =
          gateway
          |> AshPhoenix.Form.for_update(:update_credential, actor: user, as: "gateway")
          |> to_form()

        token_form =
          gateway
          |> AshPhoenix.Form.for_update(:set_api_token, actor: user, as: "gateway")
          |> to_form()

        assign(socket, form: form, token_form: token_form)
    end
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
  # (the page org — the create names it, #408) and the price snapshot
  # the row keeps.
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
  #
  # #836 lane B: the client secret gets the identical discipline. The
  # client id does NOT — it is the OAuth client's public identity (the
  # resource keeps it in the clear), so it may re-render, and the patch
  # must keep it while the user types the secret half.
  defp clear_key_display(%Phoenix.HTML.Form{source: %AshPhoenix.Form{} = ash_form} = form) do
    key_stripped = strip_secret(ash_form, :auth_key)
    token_stripped = strip_create_argument(key_stripped, :api_token)
    secret_stripped = strip_create_argument(token_stripped, :ts_client_secret)

    without_keys = Map.delete(form.params, "auth_key")
    without_token = Map.delete(without_keys, "api_token")
    params = Map.delete(without_token, "ts_client_secret")

    %{form | source: secret_stripped, params: params}
  end

  # The create-only sensitive arguments (:api_token, :ts_client_secret):
  # strip when the action carries the argument; the update form's action
  # has neither, and force-setting an unknown argument adds a
  # NoSuchInput error to every re-paste validate round-trip — but its
  # PARAMS map still absorbs a crafted value from a hostile event, and
  # the socket state must not carry it (#857 hostile review). Drop the
  # key; there is nothing to force.
  defp strip_create_argument(ash_form, argument) do
    if Enum.any?(ash_form.source.action.arguments, &(&1.name == argument)) do
      strip_secret(ash_form, argument)
    else
      %{ash_form | params: Map.delete(ash_form.params, Atom.to_string(argument))}
    end
  end

  # The token form's validate strip: the set_api_token action carries
  # both secret arguments unconditionally, so both strip outright. The
  # client id is not a secret and stays (see clear_key_display).
  defp strip_token_secrets(%Phoenix.HTML.Form{source: %AshPhoenix.Form{} = ash_form} = form) do
    token_stripped = strip_secret(ash_form, :api_token)
    stripped = strip_secret(token_stripped, :ts_client_secret)

    without_token = Map.delete(form.params, "api_token")
    params = Map.delete(without_token, "ts_client_secret")

    %{form | source: stripped, params: params}
  end

  # Both maps hold the submitted value after a validate round-trip (the
  # Ash form's params and the Phoenix form's): the socket state — and so
  # any crash report's status — must not carry a secret. `force_` because
  # the changeset is already validated by then (Ash's own warning).
  defp strip_secret(ash_form, argument) do
    %{
      ash_form
      | source: Ash.Changeset.force_set_argument(ash_form.source, argument, ""),
        params: Map.delete(ash_form.params, Atom.to_string(argument)),
        # AshPhoenix's validate stores the SUBMITTED params verbatim in
        # raw_params — the third place a typed secret survives the strip
        # (#857 review; verified: ash_phoenix form.ex validate/3 assigns
        # raw_params = new_params — here always the inner params map,
        # never the "gateway" envelope, because every handler passes the
        # unwrapped inner map). Nothing reads it for rendering and the
        # next validate replaces it wholesale, so deleting the secret
        # key is safe and closes the retention.
        raw_params: Map.delete(ash_form.raw_params, Atom.to_string(argument))
    }
  end

  # A failed submit rediscovers the form from the row — which has no
  # key — and carries only the errored form's field errors, so the
  # submitted key never echoes back (ADR-0039 §4; the backups panel's
  # secret-field posture). Two details make the errors actually render:
  # the {msg, opts} tuple format .input translates, and an "used" marker
  # per errored field — .input hides a field's errors until its key is
  # in the form's params, and a fresh rebuild has none. The markers are
  # empty strings: the keys flip the used-gate, the values stay empty,
  # and the rendered value reads the fresh changeset anyway (never the
  # submitted secret).
  defp rebuild_form_with_errors(socket, errored_form) do
    socket
    |> assign_forms()
    |> then(fn socket ->
      errors = AshPhoenix.Form.errors(errored_form, format: :raw)

      used =
        Enum.reduce(errors, %{}, fn
          {field, _msg}, acc when is_atom(field) -> Map.put(acc, Atom.to_string(field), "")
          # Defensive: every error the create/update_credential actions
          # can return today is field-scoped (verified against the S3
          # copy table and the gone/suspended refusals); a fieldless
          # shape would degrade to a skip here instead of a crash. No
          # current action can produce it — the one fieldless candidate
          # (the policy Forbidden) dies at the protocol, upstream.
          # coveralls-ignore-next-line
          _fieldless, acc -> acc
        end)

      assign(socket, form: %{socket.assigns.form | errors: errors, params: used})
    end)
  end

  defp rebuild_token_form_with_errors(socket, errored_form) do
    socket
    |> assign_forms()
    |> then(fn socket ->
      # The same two details that make the enable form's errors render:
      # the {msg, opts} tuple format .input translates, and an "used"
      # marker per errored field (.input hides a field's errors until its
      # key is in the form's params — a fresh rebuild has none). The
      # markers are empty strings; the rendered value reads the fresh
      # changeset, so no secret echo rides them (ADR-0039 §4).
      errors = AshPhoenix.Form.errors(errored_form, format: :raw)

      used =
        Enum.reduce(errors, %{}, fn
          {field, _msg}, acc when is_atom(field) -> Map.put(acc, Atom.to_string(field), "")
          # Defensive: the set_api_token refusals are all field-scoped
          # (the B2 sentence and the store/fence copies); no current
          # failure is fieldless. coveralls-ignore-next-line
          _fieldless, acc -> acc
        end)

      assign(socket, token_form: %{socket.assigns.token_form | errors: errors, params: used})
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

  # Two wallets in play, named so they can't be conflated:
  #
  # - `create_*` — the wallet an ENABLE create bills. The create names
  #   the page org (#408), so the empty state's hints read that wallet
  #   on every mount.
  # - `row_*` — the gateway ROW's org wallet: resume spends the row's
  #   org, so the suspended panel's affordance reads that.
  defp refresh_wallet_gates(socket) do
    create_org_id = create_wallet_org_id(socket)
    row_org_id = row_wallet_org_id(socket.assigns.gateway)

    socket
    |> assign(
      create_funded?: wallet_funded?(create_org_id),
      create_paid?: wallet_paid?(create_org_id)
    )
    |> assign(
      row_funded?: wallet_funded?(row_org_id),
      row_paid?: wallet_paid?(row_org_id)
    )
  end

  # The enable create names the page org (#408), so the page org's
  # wallet IS the create's billing wallet — on the :personal mount too,
  # where the page org is the actor's personal org. The old divergence
  # (the create pinning the actor's personal org on org pages, hints
  # following it) closed with the context deploy.
  defp create_wallet_org_id(socket), do: socket.assigns.org.id

  defp row_wallet_org_id(nil), do: nil
  defp row_wallet_org_id(%AccessGateway{organization_id: org_id}), do: org_id

  # nil = no resolvable wallet (no row yet / no personal org): fail
  # closed — the empty state's hints show, nothing else reads these.
  defp wallet_funded?(nil), do: false
  defp wallet_funded?(org_id), do: ActorOrgWalletFunded.org_funded?(org_id)

  defp wallet_paid?(nil), do: false
  defp wallet_paid?(org_id), do: ActorOrgHasPaid.org_paid?(org_id)

  # ---- Pairing data + copy (§4.1) ----

  # The operation is the authority (state, exposure, org); the error map
  # is §4.1's copy contract — each refusal gets its own honest line.
  defp attach(socket, instance) do
    case Infrastructure.attach_instance(socket.assigns.gateway, instance) do
      {:ok, _route} ->
        # The attach ran the claim sweep; the fresh row is what carries
        # the landed claims into the Domains card.
        fresh = fetch_gateway(socket.assigns.org, socket.assigns.current_user)

        {:noreply,
         socket
         |> put_flash(:info, "#{instance.name} attached. Its tailnet address is below.")
         |> assign(attach_error: nil)
         |> assign(:gateway, fresh || socket.assigns.gateway)
         |> refresh_pairing()
         |> assign_domains()}

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
    "#{instance.name} detached. Reachable from the panel only again."
  end

  defp detach_flash(%Instance{} = instance) do
    "#{instance.name} detached. Its public address still works."
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
    "Attaching is paused while private access is suspended. Resume it to bring your apps' addresses back."
  end

  defp pairing_paused_copy(%AccessGateway{state: :needs_attention}) do
    "Attaching is paused while the gateway isn't connected. Reconnect with a fresh key first."
  end

  defp pairing_paused_copy(%AccessGateway{state: :destroying}) do
    "Attaching is unavailable. Private access is being removed."
  end

  # The open states render the sections instead — nil hides the note.
  defp pairing_paused_copy(%AccessGateway{}), do: nil

  # §4.1's error map: each refusal in the operation's own words.
  defp attach_error_copy(:gateway_not_active) do
    "Private access isn't connected yet. Wait for Connected, then attach again."
  end

  defp attach_error_copy(:pool_exhausted) do
    "This gateway's addresses are all in use. Detach an app to free one."
  end

  # The migration-window row only: every gateway created after the
  # column lands carries its domain. The fix is the re-paste form.
  defp attach_error_copy(:tailnet_domain_missing) do
    "This gateway needs its tailnet domain. Reconnect with your key and fill it in first."
  end

  defp attach_error_copy(_cluster_or_stale) do
    "Couldn't attach. Try again."
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
    # The panel's rate display reads the platform's one accessor —
    # never the config directly.
    AccessGateway.monthly_cents()
  end
end
