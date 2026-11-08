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

  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Ops.FeatureFlags
  alias FluxValeWeb.AllocationSliders
  alias FluxValeWeb.InstanceLive.DavSnippet
  alias FluxValeWeb.InstanceStatus

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Instance.get_by_id(id, actor: user) do
      {:ok, instance} ->
        instance = Ash.load!(instance, [app_version: [:app]], actor: user)

        Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")

        # #179: technical detail (raw status_message, namespace, image)
        # renders only for platform admins — one predicate, shared with
        # policy-land, so the notion can't fork.
        socket =
          socket
          |> assign(
            instance: instance,
            admin?: ActorIsPlatformAdmin.platform_admin?(user),
            always_on_confirm: always_on_confirm(instance),
            dav_password: nil,
            # #253: the quick-start's active platform. Linux is the
            # no-JS fallback; the .DavOsDefault hook refines it to the
            # visitor's OS on mount (detection assists, never traps).
            dav_platform: :linux,
            dav_platform_locked: false,
            tick_scheduled?: false,
            # #493: the Details price row reads the row's own settlement
            # rates (the #206 gap closure — a custom-allocation row shows
            # the cents it actually bills); the resize panel rides these
            # assigns, closed until an entry opens it.
            rates: rates_for(instance),
            resize_open: false,
            resize_step: :choose,
            resize_resources: %{},
            resize_off_ladder: false,
            resize_preview: nil,
            storage_locked: false,
            storage_lock_reason: nil,
            resize_storage_fixed: false,
            resize_storage_fixed_reason: :capability,
            resize_storage_omitted: false,
            open_resize_on_stop: false,
            resize_seed: nil,
            resize_no_op: false,
            resize_form: to_form(%{})
          )
          # #273 §4.2: the exposure card's reachability copy reads the
          # pairing (route), the org's gateway, and the org's slug (the
          # Access-tab link). Mount-time reads: they move via other
          # writers, not instance broadcasts — navigation remounts, it
          # does not self-heal live (no route notifier; see
          # assign_access).
          |> assign_access(instance, user)
          |> assign_pocketid_custody(instance, user)

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
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      actor_orgs={@actor_orgs}
      personal_org_id={@personal_org_id}
      username={@username}
      nav_section={@nav_section}
      bare
    >
      <%!-- App-wide grammar page (S2): `bare` main + .appgram — the
      page owns ALL of main's rhythm (no max-w, no padding). --%>
      <div class="appgram contents">
        <%!-- 1. The sunken full-bleed header band: breadcrumb, identity
        (mono page title, status badge, public URL chip) and the
        lifecycle actions (Deploy/Retry left of Delete — the concept
        verdict; the state-gated set below is untouched). --%>
        <section class="band">
          <div class="wrap pt-8">
            <div class="rise">
              <.link
                navigate={~p"/instances"}
                class="inline-flex items-center gap-1.5 text-sm text-ink-muted transition-colors hover:text-ink"
              >
                <span aria-hidden="true">&larr;</span> Instances
              </.link>

              <div class="mt-3 flex flex-wrap items-end justify-between gap-x-6 gap-y-4">
                <div class="min-w-0 space-y-3">
                  <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
                    <h1 class="page-title min-w-0 font-mono [overflow-wrap:anywhere]">
                      {@instance.name}
                    </h1>
                    <.status_badge status={@instance.status} />
                  </div>

                  <%!-- #265: the header URL is a public affordance too — a
                  private instance has no address that answers, so it renders
                  nothing (the Open-button gate, same reasoning: never show a
                  link that cannot work). --%>
                  <p :if={@instance.exposure == :public} class="min-w-0" data-testid="instance-url">
                    <span class="inline-flex min-w-0 items-center gap-2 rounded-full border border-line bg-panel px-3 py-1 font-mono text-xs text-ink-muted [overflow-wrap:anywhere]">
                      <span class="size-1.5 shrink-0 rounded-full bg-primary" aria-hidden="true"></span>
                      {instance_url(@instance)}
                    </span>
                  </p>
                </div>
                <div class="flex shrink-0 flex-col items-end gap-1 pb-1">
                  <div class="flex flex-wrap gap-2">
                    <.action_buttons instance={@instance} panel_open={@resize_open} />
                  </div>
                  <%!-- #493: the guided stop→resize start — the button
                  stops now; the panel opens when the row lands :stopped
                  (open_resize_on_stop). --%>
                  <p
                    :if={@instance.status == :running}
                    class="text-xs text-ink-subtle"
                    data-testid="stop-to-resize-note"
                  >
                    Your instance stops first; you start it again after resizing.
                  </p>
                </div>
              </div>
            </div>

            <%!-- 2. The status card straddles the band's bottom edge —
            the one primary status earns the one bold move. Straddle
            contract: this card is taller than --straddle-y (the copy
            guarantees it), and the section after the band carries its
            own top padding. The danger surface composes an opaque panel
            base under the danger-muted tint (a background-image layer):
            in dark the tint token is translucent, and an alpha fill over
            the seam would let the band's hairline read through the
            card — the straddle must hide the seam, not tint it. --%>
            <% family = status_family(@instance.status) %>
            <div class={[
              "straddle card rise mt-7 flex items-start gap-4 p-5 shadow-md [animation-delay:100ms]",
              family == :danger &&
                "border-line-danger bg-panel [background-image:linear-gradient(var(--danger-muted),var(--danger-muted))]",
              family != :danger && "border-line-strong"
            ]}>
              <div
                class={[
                  "grid size-10 shrink-0 place-items-center rounded-panel border",
                  status_tile(family)
                ]}
                aria-hidden="true"
              >
                <%= if family == :progress do %>
                  <%!-- The concept's glyph fix: an indeterminate progress
                  pie — a conic wedge, spinning only where motion is
                  wanted (zero-delta under reduced motion). --%>
                  <span class="size-5 rounded-full bg-[conic-gradient(var(--primary)_0_25%,var(--primary-muted)_0)] motion-safe:animate-spin"></span>
                <% else %>
                  <.icon
                    name={status_icon(@instance.status)}
                    class={["size-5", status_icon_tone(family)]}
                  />
                <% end %>
              </div>

              <div class="min-w-0 space-y-1">
                <h2 class={["text-sm font-semibold", family == :danger && "text-danger"]}>
                  Status
                </h2>
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
              </div>
            </div>
          </div>
        </section>

        <%!-- 3. The overview: the admin technical block as the sunken
        mono-panel beside the raised details card riding lower on
        purpose — no fake symmetry. The section after a straddling band
        carries its own top padding (the straddle contract). Non-admin:
        the details card composes honestly alone. --%>
        <section class="wrap pt-[calc(var(--straddle-y)_+_1.5rem)]">
          <div class={[
            "rise items-start gap-6 space-y-6 [animation-delay:170ms] lg:space-y-0",
            @admin? && "lg:grid lg:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]"
          ]}>
            <%= if @admin? do %>
              <%!-- #179's admin-only reveal: the full technical trail, in the
              clear, for staff. Everything a non-admin must not see on this
              page lives here. --%>
              <div class="mono-panel space-y-3">
                <div class="flex items-center gap-2">
                  <h2 class="mono-panel-label mb-0">Technical details</h2>
                  <.badge>admin</.badge>
                </div>
                <div class="grid gap-1.5" data-testid="admin-technical">
                  <p class="flex gap-4">
                    <span class="w-36 shrink-0">status:</span>
                    <span class="text-ink" data-testid="admin-status">{@instance.status}</span>
                  </p>
                  <p class="flex gap-4">
                    <span class="w-36 shrink-0">failure_reason:</span>
                    <span class="min-w-0 [overflow-wrap:anywhere]">{@instance.failure_reason || "—"}</span>
                  </p>
                  <p :if={@instance.status_message} class="flex gap-4">
                    <span class="w-36 shrink-0">message:</span>
                    <span class="min-w-0 [overflow-wrap:anywhere]">{@instance.status_message}</span>
                  </p>
                  <p
                    :if={@instance.lost_detected_at}
                    class="flex gap-4"
                    data-testid="admin-lost-detected-at"
                  >
                    <span class="w-36 shrink-0">lost_detected_at:</span>
                    <span class="min-w-0 [overflow-wrap:anywhere]">
                      {DateTime.to_iso8601(@instance.lost_detected_at)}
                    </span>
                  </p>
                  <p class="flex gap-4">
                    <span class="w-36 shrink-0">namespace:</span>
                    <span class="min-w-0 [overflow-wrap:anywhere]">{@instance.namespace || "—"}</span>
                  </p>
                  <p class="flex gap-4">
                    <span class="w-36 shrink-0">image:</span>
                    <span class="min-w-0 [overflow-wrap:anywhere]">{@instance.image}</span>
                  </p>
                </div>
              </div>
            <% end %>

            <.card class={["space-y-1", @admin? && "lg:mt-4"]}>
              <h2 class="pb-2 text-sm font-semibold text-ink">Details</h2>
              <div class="divide-y divide-line text-sm">
                <div class="flex items-baseline justify-between gap-4 py-2.5">
                  <span class="shrink-0 text-ink-subtle">App</span>
                  <span class="min-w-0 text-right text-ink">{@instance.app_version.app.name}</span>
                </div>
                <div class="flex items-baseline justify-between gap-4 py-2.5">
                  <span class="shrink-0 text-ink-subtle">Version</span>
                  <span class="min-w-0 text-right font-mono text-ink">
                    v{@instance.app_version.version}
                  </span>
                </div>
                <%!-- #179: image + namespace rows moved to the admin-only
                technical card — non-admins never see cluster-identifying
                detail. --%>
                <div class="flex items-baseline justify-between gap-4 py-2.5">
                  <span class="shrink-0 text-ink-subtle">Resources</span>
                  <%!-- #557: sizes ride the mono voice like versions. --%>
                  <span class="min-w-0 text-right font-mono text-ink" data-testid="instance-resources">
                    {@instance.cpu_cores} CPU · {@instance.memory_mb} MB · {@instance.storage_gb} GB
                  </span>
                </div>
                <%= if @rates do %>
                  <%!-- The row's own settlement figures (#493 — the #206
                  gap closed): the same resolver the accrual prices
                  through, so a custom-allocation row shows the cents it
                  actually bills and an unpriced row hides (never a
                  guess). Monthly-equivalent · billed hourly on every
                  surface (#206). --%>
                  <div class="flex items-baseline justify-between gap-4 py-2.5">
                    <span class="shrink-0 text-ink-subtle">Price</span>
                    <%!-- #557: prices ride the mono voice. --%>
                    <span class="min-w-0 text-right font-mono text-ink" data-testid="instance-price">
                      <%= if @instance.status in [:stopped, :sleeping] do %>
                        {FluxVale.Pricing.format_usd(@rates.stopped)}/mo while {if(
                          @instance.status == :sleeping,
                          do: "asleep",
                          else: "stopped"
                        )} · billed hourly
                      <% else %>
                        {FluxVale.Pricing.format_monthly_rate(@rates.running)}
                      <% end %>
                    </span>
                  </div>
                <% end %>
                <div class="flex items-baseline justify-between gap-4 py-2.5">
                  <span class="shrink-0 text-ink-subtle">Created</span>
                  <span class="min-w-0 text-right text-ink">
                    {Calendar.strftime(@instance.created_at, "%b %d, %Y %H:%M UTC")}
                  </span>
                </div>
              </div>
            </.card>
          </div>
        </section>

        <%!-- 4. The working flow below the frame: availability, the
        first-run callout, and the S3-stranded panels (backups, WebDAV)
        as plain cards — their shells are untouched until S3. --%>
        <section class="wrap pb-12 pt-6">
          <div class="rise space-y-6 [animation-delay:230ms]">
            <%!-- #203 (ADR-0036 Am. 2, #261): the idle posture — auto-sleep
        is the default economics; always-on is no premium tier, it just
        bills the running rate around the clock. --%>
            <%!-- Grammar card opt-in (`card`): the shell joins the
        grammar's card scope. The hover lift fires only on link-cards
        (`a.card`) — the #328 hostile review's F3 narrowed it from the
        old hosts-a-control heuristic after a parked-pointer click
        missed a control on a lifting form panel. --%>
            <.card class="card space-y-3" data-testid="availability-card">
              <div class="flex items-center justify-between gap-3">
                <h2 class="text-sm font-semibold text-ink">Availability</h2>
                <span
                  class={[
                    "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium",
                    if(@instance.always_on,
                      do: "border-line-success bg-success-muted text-success",
                      else: "border-line bg-primary-muted text-link"
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
                  Apps sleep after an hour without visitors and wake on the next visit. You pay
                  only storage while one sleeps.
                <% end %>
              </p>

              <%!-- #261: enabling is the charge-raising direction — confirm
          first (the destroy-flow data-confirm precedent), with the
          row's own settlement figures; the figure rides phx-value so
          the accept-time guard (below) can refuse a stale number.
          Disabling only saves money, so it rides bare. --%>
              <.button
                size="sm"
                variant="ghost"
                phx-click="toggle-always-on"
                phx-value-always_on={to_string(not @instance.always_on)}
                data-confirm={if(not @instance.always_on, do: @always_on_confirm.text)}
                phx-value-shown_monthly_cents={
                  @always_on_confirm.monthly_cents &&
                    Integer.to_string(@always_on_confirm.monthly_cents)
                }
                data-testid="always-on-toggle"
              >
                {if(@instance.always_on, do: "Let it sleep when idle", else: "Keep always on")}
              </.button>

              <%!-- #265: the reachability posture — private is the
          network-isolation primitive (no public route, edge ingress
          denied). #273 §4.2: the access layer is no longer "upcoming" —
          the copy is state-aware. Route → reachable on the tailnet
          (shown below, whatever the exposure — the engine permits the
          public+attached corner and displays it honestly). Gateway, no
          route → attach is the way in. No gateway → the Access tab is
          named plainly. Exposure bills nothing. --%>
              <div class="flex items-center justify-between gap-3 border-t border-line pt-3">
                <h3 class="text-sm font-semibold text-ink">Exposure</h3>
                <span
                  class={[
                    "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium",
                    if(@instance.exposure == :private,
                      do: "border-line-warning bg-warning-muted text-warning",
                      else: "border-line bg-primary-muted text-link"
                    )
                  ]}
                  data-testid="exposure-mode"
                >
                  {if(@instance.exposure == :private, do: "Private", else: "Public")}
                </span>
              </div>

              <p class="text-sm text-ink-subtle" data-testid="exposure-copy">
                <%= if @instance.exposure == :private do %>
                  <%= cond do %>
                    <% @route && serving?(@gateway) -> %>
                      Private instances are unreachable from the internet: this app has no
                      public address. It is reachable from your own devices on your tailnet,
                      and a visit wakes it when it's asleep. Exposure never changes what you pay.
                    <% @route -> %>
                      <%!-- Routes outlive serving (suspend keeps the rows; the
                      gateway is scaled to zero) — the address is paused,
                      not live, and no visit can arrive to wake anything. --%>
                      Private instances are unreachable from the internet: this app has no
                      public address. Its tailnet address is paused: {route_paused_reason(@gateway)}.
                      Exposure never changes what you pay.
                    <% @gateway -> %>
                      Private instances are unreachable from the internet: this app has no
                      public address. You keep full control from this panel (deploy, stop,
                      start, back up), and always-on still works. But
                      nothing can wake a sleeping private instance: no traffic reaches it.
                      To reach it from your own devices, attach it in Settings → Access.
                      Exposure never changes what you pay.
                    <% true -> %>
                      Private instances are unreachable from the internet: this app has no
                      public address. You keep full control from this panel (deploy, stop,
                      start, back up), and always-on still works. But
                      nothing can wake a sleeping private instance: no traffic reaches it.
                      Your organization's Settings → Access can put it on your own
                      Tailscale network. Exposure never changes what you pay.
                  <% end %>
                <% else %>
                  Anyone on the internet can reach this app at its address. Making it private removes
                  that address immediately. The panel keeps working either way, and exposure never
                  changes what you pay.
                <% end %>
              </p>

              <%!-- §4.2's reachability line: whenever a route exists AND the
              gateway is serving — also in the public+attached corner,
              honestly. A paused route shows the paused copy instead
              (never a dead address framed as reachable). --%>
              <div
                :if={@route && serving?(@gateway)}
                class="space-y-1"
                data-testid="tailnet-reachability"
              >
                <p class="text-sm text-ink">
                  Reachable on your tailnet at
                  <span class="font-mono" data-testid="tailnet-address">
                    {tailnet_address(@route)}
                  </span>
                  · Manage this pairing in <.link
                    :if={@access_href}
                    navigate={@access_href}
                    class="underline underline-offset-2 hover:text-ink"
                    data-testid="tailnet-access-link"
                  >
                Settings → Access
              </.link>.
                </p>
              </div>

              <%!-- #261's gate logic, one card over: making private is the
          reachability-cutting direction — confirm first, in plain
          words, because the app goes dark at once (the instant
          kill-switch is the feature, so say it). Making public only
          restores service, so it rides bare. --%>
              <.button
                size="sm"
                variant="ghost"
                phx-click="toggle-exposure"
                phx-value-exposure={if(@instance.exposure == :private, do: "public", else: "private")}
                data-confirm={
                  if(@instance.exposure == :public,
                    do:
                      "Make this instance private? Its public address stops working immediately. The app becomes unreachable from the internet until you make it public again. You keep full control from this panel."
                  )
                }
                data-testid="exposure-toggle"
              >
                {if(@instance.exposure == :private, do: "Make public", else: "Make private")}
              </.button>
            </.card>

            <%!-- #597 §4.3 (S2): the PocketID admin-key custody card —
            PocketID instances only, owner-only, fail-closed behind the
            pocketid_sso_wiring flag. The key goes IN and never comes
            back out: no reveal, no echo, the card states only what the
            row records (verified at, expiry best-effort). --%>
            <.card
              :if={@pocketid_custody_card?}
              class="card space-y-3"
              data-testid="pocketid-custody-card"
            >
              <div class="flex items-center justify-between gap-3">
                <h2 class="text-sm font-semibold text-ink">Sign-in with Pocket ID</h2>
                <span
                  :if={@pocketid_custody}
                  class="inline-flex items-center gap-1.5 rounded-full border border-line-success bg-success-muted px-2.5 py-0.5 text-xs font-medium text-success"
                  data-testid="pocketid-custody-state"
                >
                  Verified
                </span>
              </div>

              <%= if @pocketid_custody do %>
                <%!-- The honest state, from the row alone: when the key
                was last verified live, and its expiry when Pocket ID
                told us unambiguously (nil = managed there, link out). --%>
                <p class="text-sm text-ink-subtle" data-testid="pocketid-custody-copy">
                  FluxVale holds an admin key for this Pocket ID, verified {Calendar.strftime(
                    @pocketid_custody.verified_at,
                    "%b %d, %Y %H:%M UTC"
                  )}.
                  <%= if @pocketid_custody.expires_at do %>
                    The key expires {Calendar.strftime(@pocketid_custody.expires_at, "%b %d, %Y")} — Pocket ID emails
                    before it lapses.
                  <% else %>
                    <%!-- Ambiguous correlation (or Pocket ID didn't say):
                    hand the owner to Pocket ID's own key management. --%>
                    The key's expiry is managed in <.link
                      href={pocketid_url(@instance)}
                      class="underline underline-offset-2 hover:text-ink"
                    >
                      Pocket ID
                    </.link>.
                  <% end %>
                </p>

                <div class="flex flex-wrap gap-2">
                  <.button
                    size="sm"
                    variant="ghost"
                    phx-click="toggle-replace-pocketid-key"
                    data-testid="pocketid-replace-toggle"
                  >
                    {if(@pocketid_replace_open?, do: "Cancel replacing key", else: "Replace key")}
                  </.button>
                  <.button
                    size="sm"
                    variant="ghost"
                    phx-click="revoke-pocketid-key"
                    data-confirm="Stop FluxVale managing sign-in clients for this Pocket ID? Apps already wired keep working; new wiring stops until you paste a key again."
                    data-testid="pocketid-revoke"
                  >
                    Revoke
                  </.button>
                </div>
              <% else %>
                <p class="text-sm text-ink-subtle" data-testid="pocketid-custody-copy">
                  One-time setup: let FluxVale create sign-in clients in this
                  Pocket ID for your other apps. Paste an admin API key — in your
                  Pocket ID, open <span class="font-medium">Settings → API keys</span> and create one.
                </p>
              <% end %>

              <%!-- The intake form: fresh (no custody) or revealed by
              Replace. Password-typed, never echoed; a paste is verified
              live before anything is stored. --%>
              <.form
                :if={is_nil(@pocketid_custody) or @pocketid_replace_open?}
                for={@pocketid_key_form}
                id="pocketid-key-form"
                phx-submit="save-pocketid-key"
              >
                <div class="flex items-end gap-2">
                  <div class="min-w-0 flex-1">
                    <.input
                      field={@pocketid_key_form[:api_key]}
                      type="password"
                      label="Admin API key"
                      placeholder="Paste the key from Pocket ID"
                      autocomplete="off"
                    />
                  </div>
                  <.button size="sm" phx-disable-with="Verifying…" data-testid="pocketid-key-submit">
                    Save key
                  </.button>
                </div>
              </.form>
            </.card>

            <%!-- #493: the resize panel — the guided stop→resize→start.
            It rides the page like always_on_confirm (backups stays the
            one sanctioned LiveComponent); every figure is a server
            assign, priced through the domain's preview seam. --%>
            <.resize_panel
              :if={@resize_open}
              instance={@instance}
              form={@resize_form}
              rates={@rates}
              resources={@resize_resources}
              preview={@resize_preview}
              step={@resize_step}
              storage_locked={@storage_locked}
              storage_lock_reason={@storage_lock_reason}
              storage_fixed={@resize_storage_fixed}
              storage_fixed_reason={@resize_storage_fixed_reason}
              storage_omitted={@resize_storage_omitted}
              off_ladder={@resize_off_ladder}
              no_op={@resize_no_op}
            />

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
                class="card space-y-4"
                data-testid="file-access-panel"
              >
                <h2 class="text-sm font-medium text-ink-muted">File access (WebDAV)</h2>

                <%!-- #227: browsers GET, collections answer PROPFIND — a
            plain visit 405s. Name the client move before every new
            user repeats the owner's live dogfood mistake. --%>
                <p class="text-xs text-ink-subtle" data-testid="dav-client-hint">
                  Open with a WebDAV client. Browsers can't browse this
                  endpoint (the "method not allowed" page is expected).
                  Recommended: Cyberduck (macOS/Windows) · rclone to mount
                  or script.
                </p>

                <%!-- #194: every credential value is a no-wrap code block with a
            copy button that carries the exact rendered string in a
            data-attribute. Selecting a wrapped 43-char password by hand
            (triple-click) catches the neighbouring label and the trailing
            newline, which is how a correct credential produced a 401. --%>
                <div class="grid min-w-0 gap-4 text-sm">
                  <.dav_field
                    label="Address"
                    value={dav_url(@instance)}
                    testid="dav-url"
                    copy_label="Copy address"
                  />

                  <div class="grid min-w-0 gap-4 sm:grid-cols-2">
                    <.dav_field
                      label="Username"
                      value={dav_username()}
                      testid="dav-username"
                      copy_label="Copy username"
                    />

                    <div class="grid min-w-0 gap-1.5">
                      <span class="text-ink-subtle">Password</span>
                      <%= if @dav_password do %>
                        <div class="flex min-w-0 items-start gap-2">
                          <code
                            class="min-w-0 flex-1 overflow-x-auto rounded-control border border-line-strong bg-panel-raised px-2 py-1 font-mono text-xs whitespace-nowrap text-ink"
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
                  Mount it with rclone. Parallel transfers, verified copies.
                  Each file uploads whole, so keep files under 100 MB through
                  this endpoint (larger library files are a coming phase):
                </p>

                <%!-- #253 (ADR-0035 Am. 3): the quick-start is per-platform —
            three tabs, five hand-held steps each, the instance's real
            values inline. The active tab is server state, so the
            password reveal's re-render can't snap the visitor back to
            the default platform mid-sequence. --%>
                <DavSnippet.dav_snippet
                  id="dav"
                  platform={@dav_platform}
                  url={dav_url(@instance)}
                  username={dav_username()}
                  password={@dav_password}
                  remote={"fluxvale-#{@instance.slug}"}
                  on_select="set-dav-platform"
                  on_detect="detect-dav-platform"
                />

                <p :if={@instance.status == :stopped} class="text-xs text-ink-subtle">
                  The endpoint is down while the instance is stopped. Start it to
                  upload.
                </p>

                <p :if={@instance.status == :sleeping} class="text-xs text-ink-subtle">
                  The endpoint sleeps with the app. It wakes on the next upload
                  attempt (retrying clients pick it up in a few seconds).
                </p>
              </.card>
            <% end %>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The status card's state families (S2): every state maps to one of
  # four treatments — progress (the spinning conic pie), settled
  # success, quiet rest, or danger (the loudest surface on the page).
  # :deleting rides danger, not progress: the badge vocabulary already
  # says danger (red Deleting pill), and a red pill over a calm amber
  # card reads as two stories. Presentation only: the state machine and
  # the copy are InstanceStatus's; an unknown state reads as danger
  # (attention demanded is the honest default).
  defp status_family(status) do
    case status do
      s when s in [:pending, :deploying, :starting, :restoring] -> :progress
      :running -> :success
      s when s in [:sleeping, :stopped] -> :quiet
      _failure -> :danger
    end
  end

  # The glyph tile's surface per family — sanctioned semantic tints,
  # no new colors.
  defp status_tile(:progress), do: "border-primary/25 bg-primary-muted"
  defp status_tile(:success), do: "border-line-success bg-success-muted"
  defp status_tile(:quiet), do: "border-line bg-panel-raised"
  defp status_tile(:danger), do: "border-line-danger bg-danger-muted"

  # The quiet family splits by state: asleep reads as the moon, the
  # owner's manual pause as a pause. Progress states render the pie,
  # never an icon.
  defp status_icon(:running), do: "hero-check-circle"
  defp status_icon(:sleeping), do: "hero-moon"
  defp status_icon(:stopped), do: "hero-pause-circle"
  defp status_icon(_failure), do: "hero-exclamation-triangle"

  defp status_icon_tone(:success), do: "text-success"
  defp status_icon_tone(:quiet), do: "text-ink-subtle"
  defp status_icon_tone(:danger), do: "text-danger"

  # Lifecycle controls gated by the state machine's legal transitions —
  # the actions enforce the same, this is presentation.
  attr(:instance, :any, required: true)
  attr(:panel_open, :boolean, default: false)

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

    <%!-- #265: an unreachable app must not offer a working-looking
    Open — a private instance's address answers nothing at the edge
    (the file_access_on? precedent: never render an affordance that
    cannot work). --%>
    <.button
      :if={@instance.status in [:running, :sleeping] and @instance.exposure == :public}
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

    <%!-- #493: the resize entry — stopped opens the panel directly;
    running must stop first (the guided stop→resize start). No entry
    from the states that can't reach :stopped cleanly — wake or deploy
    first, plain and honest. --%>
    <.button
      :if={@instance.status == :stopped and not @panel_open}
      variant="ghost"
      size="sm"
      phx-click="open-resize"
      data-testid="resize-button"
    >
      Resize
    </.button>

    <.button
      :if={@instance.status == :running}
      variant="ghost"
      size="sm"
      phx-click="stop-to-resize"
      data-testid="stop-to-resize"
    >
      Stop to resize
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

  attr(:instance, :any, required: true)
  attr(:form, :any, required: true)
  attr(:rates, :map, default: nil)
  attr(:resources, :map, required: true)
  attr(:preview, :any, required: true)
  attr(:step, :atom, required: true)
  attr(:storage_locked, :boolean, required: true)
  attr(:storage_lock_reason, :atom, required: true)
  attr(:storage_fixed, :boolean, required: true)
  attr(:storage_fixed_reason, :atom, required: true)
  attr(:storage_omitted, :boolean, required: true)
  attr(:off_ladder, :boolean, required: true)
  attr(:no_op, :boolean, required: true)

  # The panel's two steps (#493): :choose seeds the ladders and prices
  # the candidate live; :confirm states the consequence in the row's
  # own settlement figures before the submit exists (the backups
  # panel's two-step shape, in-page — the instance is :stopped here by
  # construction, both entries stop first).
  defp resize_panel(assigns) do
    assigns = assign(assigns, figures: panel_figures(assigns.rates, assigns.preview))

    ~H"""
    <.card class="card space-y-4" data-testid="resize-panel">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-sm font-semibold text-ink">Resize instance</h2>
        <.button
          :if={@step == :choose}
          size="sm"
          variant="ghost"
          type="button"
          phx-click="resize-cancel"
          data-testid="resize-cancel"
        >
          Cancel
        </.button>
      </div>

      <.form
        for={@form}
        id="resize-form"
        phx-change="resize-change"
        phx-submit="resize-submit"
        class="space-y-4"
      >
        <AllocationSliders.sliders
          resources={@resources}
          name="resize"
          locked={if(@storage_locked and not @storage_fixed, do: ["storage_gb"], else: [])}
          hidden={if(@storage_fixed, do: ["storage_gb"], else: [])}
          locked_note={
            if(@storage_locked and not @storage_fixed,
              do: storage_lock_note(@storage_lock_reason)
            )
          }
        />

        <%!-- An off-ladder locked row can't be a rung — the nearest
        rung would read as an imminent shrink — so the slider yields to
        this line (the payload omits storage; the row keeps its value). --%>
        <p :if={@storage_fixed} class="text-xs text-ink-subtle" data-testid="resize-storage-fixed">
          {storage_fixed_line(@storage_fixed_reason, @instance.storage_gb)}
        </p>

        <p :if={@off_ladder} class="text-xs text-ink-subtle" data-testid="resize-off-ladder-note">
          Values not offered here move to the nearest offered value. Storage only grows, so it
          rounds up.
        </p>

        <%!-- The price is the resize's own snapshot choice (the domain's
        preview seam), so the shown figure is the charged figure; no
        priceable preview → no line (never bill a guess). #206: the
        running figure states monthly-equivalent · billed hourly like
        every price surface. A repair path (an unpriced row, a priced
        candidate) has no From figure — it reads "To" only. --%>
        <div
          :if={@figures}
          class="space-y-0.5 rounded-xl bg-panel-raised px-4 py-3 text-sm"
          data-testid="resize-price"
        >
          <p class="text-ink">
            {if(@figures.old,
              do: "From #{@figures.old} to #{@figures.new}",
              else: "To #{@figures.new}"
            )} · billed hourly
          </p>
          <p class="text-ink-muted">{@figures.stopped} while stopped</p>
        </div>

        <p
          :if={is_nil(@figures)}
          class="text-xs text-ink-subtle"
          data-testid="resize-price-unavailable"
        >
          Couldn't show a price right now — close and reopen the panel.
        </p>

        <p :if={@step == :choose} class="text-sm text-ink-subtle">
          The new size applies when you start the instance.
        </p>

        <%= if @step == :choose do %>
          <div class="flex justify-end">
            <.button
              size="sm"
              type="button"
              phx-click="resize-continue"
              disabled={is_nil(@figures) or @no_op}
              data-testid="resize-continue"
            >
              Continue
            </.button>
          </div>
        <% else %>
          <div
            class="space-y-3 rounded-panel border-2 border-line-danger bg-danger-muted px-4 py-3"
            data-testid="resize-confirm"
          >
            <p class="text-sm font-semibold text-danger">Resize instance</p>
            <p class="text-sm text-ink">
              {@resources["cpu_cores"]} CPU · {@resources["memory_mb"]} MB · {if(@storage_omitted,
                do: @instance.storage_gb,
                else: @resources["storage_gb"]
              )} GB — {if(@figures.old,
                do: "from #{@figures.old} to #{@figures.new}",
                else: "to #{@figures.new}"
              )} ({@figures.stopped} while stopped)
            </p>
            <p class="text-xs text-ink-muted">
              The instance stays stopped. The new size applies when you start it.
            </p>
            <div class="flex flex-wrap gap-2">
              <.button
                size="sm"
                type="submit"
                phx-disable-with="Resizing…"
                data-testid="resize-submit"
              >
                Confirm resize
              </.button>
              <.button
                size="sm"
                variant="ghost"
                type="button"
                phx-click="resize-cancel"
                data-testid="resize-cancel"
              >
                Cancel
              </.button>
            </div>
          </div>
        <% end %>
      </.form>
    </.card>
    """
  end

  # The two lock meanings, mirroring ResizeGuard's split (F11): the
  # product boundary vs a probe that failed — the slider locks either
  # way, only the note differs.
  defp storage_lock_note(:capability), do: "Storage can't be expanded on this cluster yet."
  defp storage_lock_note(:error), do: "Couldn't check storage expansion — try again."

  # The hidden-slider line for an off-ladder locked row: the row's own
  # GB, stated as staying put, with the lock's reason.
  defp storage_fixed_line(:above_top, gb),
    do: "Storage: #{gb} GB · stays unchanged (beyond the offered sizes)"

  defp storage_fixed_line(:capability, gb),
    do: "Storage: #{gb} GB · stays unchanged (can't expand on this cluster yet)"

  defp storage_fixed_line(:error, gb),
    do: "Storage: #{gb} GB · stays unchanged (couldn't check storage expansion — try again)"

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

  # #203/#261 (ADR-0036 Am. 2): the always-on opt-out — no premium
  # tier; the toggle is behavior (the idle sweep skips always-on rows,
  # and the page confirms the full-rate cost before enabling).
  def handle_event("toggle-always-on", %{"always_on" => always_on} = params, socket) do
    instance = socket.assigns.instance
    # phx-value strings in, booleans out — the attribute is boolean.
    always_on = always_on == "true"

    if always_on and price_moved?(params, instance) do
      # The number the user accepted no longer matches the fresh rate —
      # never enable against it. Refuse, refresh, and re-ask (the next
      # click compares against the refreshed copy).
      {:noreply, reask_always_on(socket)}
    else
      apply_always_on(socket, instance, always_on)
    end
  end

  # #265: the reachability toggle. The action applies the cluster
  # posture synchronously and fails the write on a cluster error —
  # here that surfaces as copy (the row never claimed a posture the
  # cluster didn't reach), same stance as apply_always_on's error arm.
  def handle_event("toggle-exposure", %{"exposure" => exposure}, socket) do
    instance = socket.assigns.instance

    if exposure == Atom.to_string(instance.exposure) do
      # A stale view's double-click re-sends the current value: the
      # cluster already holds it, nothing to re-apply.
      {:noreply, socket}
    else
      apply_exposure(socket, instance, exposure)
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
        {:noreply, put_flash(socket, :error, "Deploy the instance first. No credential yet.")}

      _unavailable ->
        {:noreply, put_flash(socket, :error, "Credential unavailable. Try again shortly.")}
    end
  end

  # #597 §4.3 (S2): the custody card's three verbs. The paste is
  # verified live inside the op (3s budget) — the flash answers with
  # the op's verdict, never the key. The card's gate (flag + app +
  # owner) is the HANDLER's fence too, not just the render's: a
  # crafted or stale client firing these events with the flag off (or
  # on a non-PocketID instance) must not reach the ops — that is what
  # makes :pocketid_sso_wiring an instant shutdown lever for the
  # whole write path (CodeRabbit, #607). The op still re-fences the
  # owner gate regardless.
  def handle_event("save-pocketid-key", %{"pocketid_key" => %{"api_key" => api_key}}, socket)
      when is_binary(api_key) and api_key != "" do
    if socket.assigns.pocketid_custody_card? do
      save_pocketid_key(api_key, socket)
    else
      {:noreply, put_flash(socket, :error, pocketid_card_unavailable())}
    end
  end

  # An empty paste (or a non-string) is nothing to verify — say so
  # without calling anyone.
  def handle_event("save-pocketid-key", _blank, socket) do
    {:noreply, put_flash(socket, :error, "Paste an admin API key first.")}
  end

  def handle_event("toggle-replace-pocketid-key", _params, socket) do
    {:noreply, assign(socket, pocketid_replace_open?: not socket.assigns.pocketid_replace_open?)}
  end

  def handle_event("revoke-pocketid-key", _params, socket) do
    if socket.assigns.pocketid_custody_card? do
      revoke_pocketid_key(socket)
    else
      {:noreply, put_flash(socket, :error, pocketid_card_unavailable())}
    end
  end

  # #253 (ADR-0035 Am. 3): platform-tab switching. The active platform
  # is server state, and the click locks it — the OS-detected default
  # can then never override a choice (detection assists, never traps).
  # An unrecognized value is a stale view's click; keep the current tab.
  def handle_event("set-dav-platform", %{"platform" => platform}, socket) do
    case DavSnippet.platform_key(platform) do
      nil -> {:noreply, socket}
      key -> {:noreply, assign(socket, dav_platform: key, dav_platform_locked: true)}
    end
  end

  # #253: the OS-detected default — the .DavOsDefault hook pushes the
  # browser's platform string once on mount; guess_platform/1 maps it
  # server-side. nil (unknown, mobile) keeps the Linux default; a
  # locked choice means the visitor's tab click beat the round trip.
  def handle_event("detect-dav-platform", %{"platform" => platform}, socket) do
    if socket.assigns.dav_platform_locked do
      {:noreply, socket}
    else
      case DavSnippet.guess_platform(platform) do
        nil -> {:noreply, socket}
        key -> {:noreply, assign(socket, :dav_platform, key)}
      end
    end
  end

  # #493: the resize panel. The entry buttons are presentation — the
  # action's own guards stay the fence for every state question.

  def handle_event("open-resize", _params, socket) do
    {:noreply, open_resize_panel(socket)}
  end

  # The guided stop→resize start: the row stops through the existing
  # stop path with the flag set; the refresh reading :stopped consumes
  # it and opens the panel (the broadcast that trails the event finds
  # the flag already consumed).
  def handle_event("stop-to-resize", _params, socket) do
    instance = socket.assigns.instance

    case Instance.stop(instance, actor: socket.assigns.current_user) do
      {:ok, _stopped} ->
        socket = assign(socket, :open_resize_on_stop, true)
        {:noreply, refresh(socket, instance.id)}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "That action isn't possible from this state.")}
    end
  end

  # Live reprice: every slider move re-prices through the same snapshot
  # choice the submit charges. Only a map payload is honoured — a
  # crafted `"resize" => "not_a_map"` is an unmatched shape, same as a
  # missing payload.
  def handle_event("resize-change", %{"resize" => params}, socket) when is_map(params) do
    rungs =
      Map.merge(socket.assigns.resize_resources, AllocationSliders.resource_strings(params))

    preview = preview_for(socket.assigns.instance, rungs, socket.assigns.resize_storage_omitted)

    # The confirm exists only with its numbers, and only with something
    # to apply: a change that stops the candidate pricing (a candidate
    # landing on a sizeless recommendation) or a preview read that
    # failed drops the panel back to :choose, and so does a candidate
    # that lands back on the row (the action's own "allocation is
    # unchanged" refusal, surfaced early).
    {allocation, no_op} = candidate_state(socket, rungs)

    step =
      if is_map(preview) and not is_nil(allocation) and not no_op,
        do: socket.assigns.resize_step,
        else: :choose

    {:noreply,
     assign(socket,
       resize_resources: rungs,
       resize_preview: preview,
       resize_step: step,
       resize_no_op: no_op
     )}
  end

  def handle_event("resize-change", _unmatched, socket), do: {:noreply, socket}

  # The disabled Continue is the DOM gate; a crafted click without its
  # numbers — or with a candidate that changes nothing — stays on
  # :choose, never a confirm.
  def handle_event("resize-continue", _params, socket) do
    if proceedable?(socket) do
      {:noreply, assign(socket, :resize_step, :confirm)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("resize-cancel", _params, socket) do
    {:noreply, reset_resize_panel(socket)}
  end

  # Only an open panel at :confirm with a map payload applies anything
  # — a crafted or stale submit (from :choose, a closed panel, or a
  # malformed payload) is a no-op noreply, the unmatched-shape posture.
  # phx-disable-with holds the double-submit window on the wire; this
  # closes the rest.
  def handle_event("resize-submit", params, socket) do
    if resize_open_at_confirm?(socket) and is_map(params) and is_map(params["resize"]) do
      resize_submit(socket, params["resize"])
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete", _params, socket) do
    instance = socket.assigns.instance

    case Instance.delete(instance.id, actor: socket.assigns.current_user) do
      {:ok, updated} ->
        {:noreply, assign_instance(socket, reload(updated, socket))}

      # coveralls-ignore-start - defensive: the action's error arms are
      # DB-level failures (the action handles every status shape)
      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Delete failed. Try again.")}
        # coveralls-ignore-stop
    end
  end

  defp resize_submit(socket, params) do
    rungs =
      Map.merge(socket.assigns.resize_resources, AllocationSliders.resource_strings(params))

    instance = socket.assigns.instance
    shown = socket.assigns.resize_preview

    # The submit must land EXACTLY the confirmed candidate: a crafted
    # payload naming different rungs — even ones that price identically
    # — is an altered confirm, refused like a moved price. The crafted
    # rungs are NOT absorbed; :choose keeps the confirmed state.
    if rungs == socket.assigns.resize_resources do
      price_guard(socket, rungs, instance, shown)
    else
      {:noreply,
       socket
       |> put_flash(:error, "The resize changed since you confirmed — review and confirm again.")
       |> assign(resize_step: :choose)}
    end
  end

  defp price_guard(socket, rungs, instance, shown) do
    case preview_for(instance, rungs, socket.assigns.resize_storage_omitted) do
      # The #261 accept-time guard's posture: the confirm showed a
      # price; between that render and the submit an admin repriced the
      # catalog. Consent must match the charged number — re-price fresh
      # and refuse ANY difference (a stopped-only reprice changes what
      # the row earns while it sleeps), back to :choose for a fresh
      # look.
      %{running_cents: fresh_running, stopped_cents: fresh_stopped} = fresh
      when is_map(shown) and
             (fresh_running != shown.running_cents or fresh_stopped != shown.stopped_cents) ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "The price changed since you confirmed (now #{format_rate(fresh_running)}) — review and confirm again."
         )
         |> assign(resize_step: :choose, resize_preview: fresh)}

      # The candidate stopped pricing (or the read failed) since the
      # confirm — the same refusal, with no new figure to name.
      fresh when fresh != shown ->
        {:noreply,
         socket
         |> put_flash(:error, "The price couldn't be refreshed — review and confirm again.")
         |> assign(resize_step: :choose, resize_preview: fresh)}

      _unchanged ->
        apply_resize(socket, rungs, instance)
    end
  end

  defp apply_resize(socket, rungs, instance) do
    case typed_allocation(rungs, socket.assigns.resize_storage_omitted) do
      {:ok, allocation} ->
        case Instance.resize(instance, allocation, actor: socket.assigns.current_user) do
          {:ok, _resized} ->
            # The refresh closes the panel and re-reads the row — its
            # fresh snapshot moves the Details price row. The page's
            # existing Start button is the flow's end.
            {:noreply,
             socket
             |> put_flash(:info, "Resized. Start your instance to run at the new size.")
             |> refresh(instance.id)}

          {:error, error} ->
            # The action's plain refusals ARE the copy (shrinks, no-ops,
            # capability, stale states) — flash them, stay on the panel.
            {:noreply, put_flash(socket, :error, resize_refusal(error))}
        end

      # F1's guards mean the state is fully seeded on every real path
      # (open seeds all rungs; the merge only ever keeps ladder
      # strings) — a nil rung here is a crafted future, not a testable
      # path. It reads as the refusal flash instead of raising.
      # coveralls-ignore-start
      {:error, _unseeded} ->
        {:noreply, put_flash(socket, :error, "Resize isn't possible right now.")}
        # coveralls-ignore-stop
    end
  end

  # A start error here still leaves the flag set and the row honest
  # (sleeping): the sweep skips it from now on, and any visitor's
  # request wakes it. Flash the outcome, don't crash.
  defp wake_on_enable(socket, sleeping) do
    case Instance.start(sleeping, actor: socket.assigns.current_user) do
      {:ok, waking} ->
        assign_instance(socket, reload(waking, socket))

      # coveralls-ignore-start - the action-level error arm is the
      # stale-view race (the row moved between render and event); the
      # K8s path reports through status, not error tuples.
      {:error, _error} ->
        put_flash(socket, :error, "Always-on is set. Open the app once to wake it now.")
        # coveralls-ignore-stop
    end
  end

  # The toggle's action arms: the wake-on-enable lie-check rides the
  # success path; the error arm flashes (the action's own guards are
  # the real gate — stale-view double clicks).
  defp apply_always_on(socket, instance, always_on) do
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
            assign_instance(socket, reload(updated, socket))
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
      nil ->
        {:noreply, socket}

      # A broadcast landing in-progress may be the first (mounted on
      # :pending) — the tick needs starting.
      instance ->
        {:noreply, maybe_schedule_status_tick(assign_instance(socket, instance))}
    end
  end

  # The toggle's action arms: success re-reads the row (the action
  # result carries no loaded relationships); the error arm flashes —
  # the action fails on cluster errors (a refused route delete, a
  # stale row under the optimistic lock) and the flash hands retry
  # ownership to the owner. An unknown value is a stale view's crafted
  # click — refuse like a bad platform tab, keep the current exposure.
  defp apply_exposure(socket, instance, exposure) when exposure in ["public", "private"] do
    case Instance.set_exposure(instance, %{exposure: String.to_existing_atom(exposure)},
           actor: socket.assigns.current_user
         ) do
      {:ok, updated} ->
        {:noreply, assign_instance(socket, reload(updated, socket))}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Couldn't change the exposure setting.")}
    end
  end

  defp apply_exposure(socket, _instance, _unknown), do: {:noreply, socket}

  defp instance_url(instance) do
    "https://#{instance.slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}/"
  end

  # #273 §4.2: the exposure card's three-state inputs. The pairing row
  # (loaded with its gateway for the hostname) decides the reachability
  # line; the org's gateway decides the "attach it" vs "enable it"
  # wording; the org is the Access surface's link (S5: /settings/access
  # for the personal org, the org URL for a real one). Each read rides
  # its member policy with the actor; misses are the honest "not there".
  # All three are mount-time only: they move via OTHER writers (another
  # tab's attach, an exposure toggle, a suspension) — this page does not
  # subscribe to route writes, so a long-lived mount can go stale until
  # navigation remounts it. Honest staleness, not live truth.
  defp assign_access(socket, instance, user) do
    route = route_for(instance, user)

    gateway =
      case AccessGateway.get_for_organization(instance.organization_id, actor: user) do
        {:ok, gateway} -> gateway
        {:error, _none} -> nil
      end

    org = instance_org(instance.organization_id, user)

    assign(socket,
      route: route,
      gateway: gateway,
      access_href: access_href(org, socket.assigns[:personal_org_id])
    )
  end

  defp route_for(instance, user) do
    case AccessRoute.get_by_instance(instance.id, actor: user) do
      {:ok, route} -> Ash.load!(route, :gateway, actor: user)
      {:error, _not_found} -> nil
    end
  end

  # ------------------------------------------------------------------
  # PocketID custody card (#597 §4.3, S2)
  # ------------------------------------------------------------------

  # Mount-time reads, the assign_access posture: custody moves via
  # this card's own events (reloaded on each), the flag via admin
  # action, the app via the catalog — navigation remounts, honest
  # staleness otherwise. The card is PocketID + owner + flag: members
  # see nothing (the crown is the owner's to paste — the op re-fences
  # regardless), non-PocketIDs see nothing, and fail-closed means no
  # flag row renders nothing anywhere. The flag evaluates FOR THE
  # USER: a partial rollout buckets real actors (anonymous evaluation
  # fails closed on percentages by design), so the lever works as
  # full-off, full-on, or a gradual rollout (CodeRabbit, #607).
  defp assign_pocketid_custody(socket, instance, user) do
    card? =
      FeatureFlags.enabled?(:pocketid_sso_wiring, for: user) and
        instance.app_version.app.slug == "pocket-id" and
        ActorIsOrganizationOwner.owner?(user, %Organization{id: instance.organization_id})

    custody =
      with true <- card?,
           {:ok, row} <- PocketIdCustody.get_by_instance(instance.id, actor: user) do
        row
      else
        _none_or_not_shown -> nil
      end

    assign(socket,
      pocketid_custody_card?: card?,
      pocketid_custody: custody,
      pocketid_replace_open?: false,
      pocketid_key_form: fresh_key_form()
    )
  end

  defp reload_pocketid_custody(socket) do
    user = socket.assigns.current_user

    custody =
      case PocketIdCustody.get_by_instance(socket.assigns.instance.id, actor: user) do
        {:ok, row} -> row
        {:error, _revoked_or_none} -> nil
      end

    assign(socket, :pocketid_custody, custody)
  end

  defp fresh_key_form, do: to_form(%{"api_key" => ""}, as: :pocketid_key)

  # The guarded verbs' bodies (the guards above fence the write path
  # on the card gate; the op still re-fences ownership).
  defp save_pocketid_key(api_key, socket) do
    user = socket.assigns.current_user

    case Infrastructure.set_pocket_id_key(socket.assigns.instance, api_key, actor: user) do
      {:ok, _custody} ->
        {:noreply,
         socket
         |> put_flash(:info, "Admin key verified and stored.")
         |> reload_pocketid_custody()
         |> assign(pocketid_replace_open?: false, pocketid_key_form: fresh_key_form())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, pocketid_key_error(reason))}
    end
  end

  defp revoke_pocketid_key(socket) do
    user = socket.assigns.current_user

    case Infrastructure.revoke_pocket_id_key(socket.assigns.instance, actor: user) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Key custody revoked.")
         |> reload_pocketid_custody()
         |> assign(pocketid_replace_open?: false)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, pocketid_key_error(reason))}
    end
  end

  # Honest and lever-shaped: the surface is off — nothing about the
  # why leaks platform internals.
  defp pocketid_card_unavailable, do: "Sign-in management isn't available right now."

  # The expiry line is a nicety (the store op's correlation): show the
  # date when Pocket ID answered unambiguously, else hand the owner to
  # Pocket ID's own key management. The link target is the instance's
  # public URL — where the key lives.
  defp pocketid_url(%{slug: slug}) do
    "https://#{slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}"
  end

  # The op's verdicts, keyed to honest copy (the Tailscale
  # token_drift_message rule: one mapper, so the card and the op can
  # never disagree about what a rejection means).
  defp pocketid_key_error(:unauthorized),
    do: "Your Pocket ID admin API key was rejected. Paste a fresh admin key."

  defp pocketid_key_error(:forbidden),
    do: "That key doesn't have admin permission. Paste an admin user's key."

  defp pocketid_key_error(:unreachable),
    do: "Couldn't reach your Pocket ID to verify the key. Try again once it's running."

  defp pocketid_key_error(:not_public),
    do: "Make this Pocket ID public first — a private one can't serve sign-in."

  defp pocketid_key_error(:not_org_owner),
    do: "Only the organization owner can manage this key."

  defp pocketid_key_error(:no_custody),
    do: "Nothing to revoke — no key is stored."

  defp pocketid_key_error(_cluster_or_db_failure),
    do: "Something went wrong. Try again shortly."

  defp instance_org(organization_id, user) do
    case Organization.get_by_id(organization_id, actor: user) do
      {:ok, org} -> org
      # Unreachable through this page: the org read's membership chain
      # is the same one the instance read passed, and an org with
      # instances is never hard-deleted (no reachable destroy). A bare
      # nil drops the Access-tab link rather than crashing the card.
      # coveralls-ignore-next-line
      {:error, _none} -> nil
    end
  end

  # The Access surface for the instance's org (S5): a personal-org
  # instance is managed from the user settings' panel, a real org's from
  # its org URL.
  defp access_href(%{id: org_id}, personal_org_id) when org_id == personal_org_id do
    ~p"/settings/access"
  end

  defp access_href(%{slug: slug}, _personal_org_id) do
    ~p"/organizations/#{slug}/settings/access"
  end

  # Unreachable for the same reason as instance_org's error arm above —
  # the org read passes wherever the instance read did. The clause exists
  # so a future shape's bare nil drops the link instead of crashing.
  # coveralls-ignore-next-line
  defp access_href(nil, _personal_org_id), do: nil

  # §4.2's shape: hostname + route_key (the provider-opaque port).
  defp tailnet_address(route) do
    "#{route.gateway.hostname}:#{route.route_key}"
  end

  # A route is only live while its gateway serves (suspend.ex: the rows
  # survive, the pod is scaled to zero). @gateway is non-nil whenever
  # @route is — the route's FK cascade deletes it first.
  defp serving?(%AccessGateway{state: :active}), do: true
  defp serving?(_not_serving_or_nil), do: false

  # The paused-route copy names the way back, per state (the Access
  # tab's paused lines are the sibling wording).
  defp route_paused_reason(%AccessGateway{state: :suspended}) do
    "resume private access in Settings → Access to bring it back"
  end

  defp route_paused_reason(%AccessGateway{state: :needs_attention}) do
    "reconnect the gateway with a fresh key to bring it back"
  end

  defp route_paused_reason(%AccessGateway{state: :destroying}) do
    "private access is being removed"
  end

  defp route_paused_reason(_provisioning) do
    "the gateway is still starting up, usually under a minute"
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
  # 43-char password is what made hand-selection lossy. min-w-0 down
  # the grid/flex chain: without it the no-wrap code's intrinsic width
  # is every ancestor's min-content floor, and the row overflows the
  # panel at mobile widths (#253's vision check caught the address row
  # painting 100px past the viewport).
  defp dav_field(assigns) do
    assigns = assign(assigns, :copy_id, "copy-#{assigns.testid}")

    ~H"""
    <div class="grid min-w-0 gap-1.5">
      <span class="text-ink-subtle">{@label}</span>
      <div class="flex min-w-0 items-start gap-2">
        <code
          class="min-w-0 flex-1 overflow-x-auto rounded-control border border-line-strong bg-panel-raised px-2 py-1 font-mono text-xs whitespace-nowrap text-ink"
          data-testid={@testid}
        >
          {@value}
        </code>
        <.copy_button id={@copy_id} value={@value} label={@copy_label} />
      </div>
    </div>
    """
  end

  # The panel's gate mirrors the deploy op's: the sidecar lands only for
  # a file-access instance WITH a volume to serve — at 0 GB there is no
  # endpoint, no secret, no route, so the page must not advertise one.
  defp file_access_on?(%{status: :lost}), do: false

  # #265: the /dav endpoint rides the same public hostname — a private
  # instance has no route, so the address book is dead until it goes
  # public again (same stance as :lost above: the page shows no
  # affordance that cannot work; the credential Secret is untouched).
  defp file_access_on?(%{exposure: :private}), do: false

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
      nil ->
        socket

      instance ->
        # The refresh closes the panel (the action may have moved the
        # row out from under it) BEFORE the re-read, so the guided-stop
        # flag opens it fresh off the new :stopped state — and the
        # broadcast that trails the event finds the flag consumed and
        # leaves the panel alone. The flag gets exactly ONE refresh to
        # act: a :stopped read opens; anything else clears it, so a
        # LATER unsolicited stop (the plain Stop button, say) can't
        # spring the panel open out of nowhere.
        socket =
          socket
          |> reset_resize_panel()
          |> assign(
            open_resize_on_stop:
              socket.assigns.open_resize_on_stop and instance.status == :stopped
          )

        maybe_schedule_status_tick(assign_instance(socket, instance))
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

  # Every instance (re)assign re-derives the enable-confirm copy with
  # it (#261): the figures ride the row's own settlement rates, so a
  # broadcast refresh can't leave the confirm stale behind the row.
  # Broadcasts keep an open panel open (a reconciler heartbeat must not
  # wipe an edit mid-move); only refresh/2 resets (below).
  defp assign_instance(socket, instance) do
    socket =
      assign(socket,
        instance: instance,
        always_on_confirm: always_on_confirm(instance),
        rates: rates_for(instance)
      )

    socket
    |> reset_stale_panel(instance)
    |> maybe_open_resize_on_stop(instance)
  end

  # A writer moved the row's allocation since this panel seeded —
  # another tab's resize, say. The panel's premise (the allocation it
  # read, priced, and confirmed against) is gone, so it resets rather
  # than letting a stale submit overwrite their write (the optimistic
  # lock can't catch it: the broadcast already refreshed the row's
  # version). A heartbeat/status-only change keeps the panel open.
  defp reset_stale_panel(socket, instance) do
    if panel_stale?(socket, instance), do: reset_resize_panel(socket), else: socket
  end

  defp panel_stale?(socket, instance) do
    case socket.assigns.resize_seed do
      nil ->
        false

      seed ->
        # Compare like for like: the row's allocation through
        # allocation_of (Decimals) — seed vs raw row fields would
        # structurally differ (Decimal ≠ integer) on every broadcast.
        # A status move stales too: the confirm says "the instance
        # stays stopped" — another tab's START makes that a lie, and
        # the action would refuse it anyway.
        current = allocation_of(instance)

        socket.assigns.resize_open and
          (instance.status != :stopped or
             not Decimal.eq?(seed.cpu_cores, current.cpu_cores) or
             seed.memory_mb != current.memory_mb or
             seed.storage_gb != current.storage_gb)
    end
  end

  # The guided stop→resize start (#493): the stop-to-resize click sets
  # the flag; a refresh reading :stopped consumes it and opens the
  # panel. Any other landing leaves it set for the next :stopped read.
  defp maybe_open_resize_on_stop(socket, instance) do
    if socket.assigns.open_resize_on_stop and instance.status == :stopped do
      socket
      |> assign(open_resize_on_stop: false)
      |> open_resize_panel()
    else
      socket
    end
  end

  # The Details price row's figures (#493 — the #206 gap closed): the
  # row's own settlement rates, the same resolver the accrual prices
  # through — never the recommended size's cents. nil (unpriced drift,
  # or a rate that couldn't be read) hides the row.
  defp rates_for(instance) do
    case FluxVale.Pricing.settlement_rates(instance, DateTime.utc_now()) do
      {:ok, rates} when not is_nil(rates) -> rates
      _unpriced_or_error -> nil
    end
  end

  # The panel's starting state: seeded rungs from the row's allocation,
  # the storage lock from the cluster's capability probe (with its
  # reason), the seed allocation the panel's premise rests on, and the
  # first preview.
  defp open_resize_panel(socket) do
    instance = socket.assigns.instance
    {storage_locked, storage_lock_reason} = storage_lock(instance)

    # The storage dimension's offerability, decided up front. A locked
    # slider tells the truth only when the row's storage IS a rung: an
    # off-ladder row's nearest rung (7 GB → 5) would read as an
    # imminent shrink. A row ABOVE the top rung (200 GB > 100) is
    # fixed the same way whatever the lock — the ladder can only name
    # a shrink, so the dimension is unofferable, not editable. In
    # every fixed case (and whenever locked) the payload OMITS storage
    # (the action keeps the row's value) and the preview prices the
    # row's own GB. Compare numerically: the rungs are strings.
    storage_rung = AllocationSliders.floor_rung("storage_gb", instance.storage_gb)
    rung_storage = Decimal.new(storage_rung)
    row_storage = Decimal.new(instance.storage_gb)

    off_rung = not Decimal.eq?(rung_storage, row_storage)
    above_top = Decimal.gt?(row_storage, rung_storage)
    storage_fixed = above_top or (storage_locked and off_rung)
    storage_omitted = storage_fixed or storage_locked

    fixed_reason = if(above_top, do: :above_top, else: storage_lock_reason)

    {rungs, off_ladder} = seeded_resources(instance, storage_omitted)
    {:ok, allocation} = typed_allocation(rungs, storage_omitted)

    assign(socket,
      resize_open: true,
      resize_step: :choose,
      resize_resources: rungs,
      resize_off_ladder: off_ladder,
      storage_locked: storage_locked,
      storage_lock_reason: storage_lock_reason,
      resize_storage_fixed: storage_fixed,
      resize_storage_fixed_reason: fixed_reason,
      resize_storage_omitted: storage_omitted,
      resize_preview: preview_for(instance, rungs, storage_omitted),
      resize_seed: allocation_of(instance),
      resize_no_op: no_op?(allocation, instance)
    )
  end

  # The panel's reset (refresh/2, Cancel, and a stale-seed broadcast):
  # the premise moved out from under it — honest staleness, the same
  # posture as the access card. The guided-stop flag is the one
  # survivor until its :stopped read consumes it.
  defp reset_resize_panel(socket) do
    assign(socket,
      resize_open: false,
      resize_step: :choose,
      resize_resources: %{},
      resize_off_ladder: false,
      resize_preview: nil,
      storage_locked: false,
      storage_lock_reason: nil,
      resize_storage_fixed: false,
      resize_storage_fixed_reason: :capability,
      resize_storage_omitted: false,
      resize_seed: nil,
      resize_no_op: false
    )
  end

  # The storage lock (#493): locked unless the probe answers
  # {:ok, true}. The two lock meanings stay distinct, mirroring
  # ResizeGuard's split — {:ok, false} is the product boundary
  # (:capability, "this cluster can't"), a probe error is a retry
  # (:error, "check failed — try again"). Either way the slider is
  # locked; only the note differs.
  defp storage_lock(instance) do
    case FluxVale.Infrastructure.storage_expansion_capable?(%{cluster_id: instance.cluster_id}) do
      {:ok, true} -> {false, nil}
      {:ok, false} -> {true, :capability}
      {:error, _probe} -> {true, :error}
    end
  end

  # The panel's starting rungs. CPU and memory seed at the NEAREST
  # rung (AllocationSliders' helpers — numeric distance, tie → the
  # cheaper rung). Storage is the up-only dimension: UNLOCKED it seeds
  # at the FLOOR — the smallest rung ≥ the row's value, so seeding
  # never invents a shrink or a silent increase (an explicit move to
  # that rung is the consent; up-only stays the action's enforcement).
  # LOCKED or otherwise FIXED the slider is display-only — the payload
  # omits storage entirely (the action keeps the row's value) — so its
  # nearest-rung display makes no move and isn't claimed as one in the
  # note.
  defp seeded_resources(instance, storage_omitted) do
    # String-keyed to the dimensions' keys (allocation_of/1's atom-keyed
    # shape is for the seed-staleness and no-op comparisons).
    current = %{
      "cpu_cores" => instance.cpu_cores,
      "memory_mb" => Decimal.new(instance.memory_mb),
      "storage_gb" => Decimal.new(instance.storage_gb)
    }

    rungs =
      Map.new(AllocationSliders.resource_dimensions(), fn dimension ->
        {dimension.key, AllocationSliders.nearest_rung(dimension.key, current[dimension.key])}
      end)

    seeded =
      if storage_omitted,
        do: rungs,
        else:
          Map.put(
            rungs,
            "storage_gb",
            AllocationSliders.floor_rung("storage_gb", current["storage_gb"])
          )

    off_ladder = off_ladder?(current, seeded, storage_omitted)

    {seeded, off_ladder}
  end

  # A dimension "moved" when its applied rung differs from the row's
  # value — CPU and memory always apply; storage applies only when it
  # rides the payload (an omitted dimension claims nothing).
  defp off_ladder?(current, rungs, storage_omitted) do
    applied = if storage_omitted, do: Map.delete(rungs, "storage_gb"), else: rungs

    Enum.any?(applied, fn {key, rung} ->
      not Decimal.eq?(Decimal.new(rung), current[key])
    end)
  end

  # The row's allocation as Decimals — the seed the panel's staleness
  # check and the no-op check compare against.
  defp allocation_of(instance) do
    %{
      cpu_cores: instance.cpu_cores,
      memory_mb: Decimal.new(instance.memory_mb),
      storage_gb: Decimal.new(instance.storage_gb)
    }
  end

  # The typed candidate. Storage LOCKED is OMITTED from the payload
  # entirely: the action's absent = keep-the-row's-value semantics
  # preserve 0, 7, 15, 200 GB alike — seeding the payload at a rung
  # would either guarantee a refusal (7 → 5, a shrink) or silently
  # raise the bill on a CPU-only resize (0 → 5) that the lock makes
  # unfixable. The disabled slider is display-only; up-only stays the
  # action's enforcement.
  #
  # Returns {:error, :unseeded} when any rung is missing: F1's guards
  # seed every rung on the real paths, so the arm only ever answers a
  # crafted future state — as the refusal flash, never a raise.
  defp typed_allocation(rungs, storage_locked) do
    with %{"cpu_cores" => cpu} when is_binary(cpu) <- rungs,
         %{"memory_mb" => memory} when is_binary(memory) <- rungs,
         %{"storage_gb" => storage} when is_binary(storage) <- rungs do
      allocation = %{
        cpu_cores: Decimal.new(cpu),
        memory_mb: String.to_integer(memory),
        storage_gb: String.to_integer(storage)
      }

      {:ok, if(storage_locked, do: Map.delete(allocation, :storage_gb), else: allocation)}
    else
      _missing_or_garbled -> {:error, :unseeded}
    end
  end

  # The action's own refusal ("allocation is unchanged"), surfaced
  # before the consequence step: a candidate equal to the row has
  # nothing to apply. A locked-storage candidate omits :storage_gb —
  # the row keeps its value, so storage never counts toward the change.
  defp no_op?(allocation, instance) do
    Decimal.eq?(allocation.cpu_cores, instance.cpu_cores) and
      allocation.memory_mb == instance.memory_mb and
      Map.get(allocation, :storage_gb, instance.storage_gb) == instance.storage_gb
  end

  # The candidate as typed state + its no-op flag; {:error, :unseeded}
  # reads as "nothing to apply, keep the panel quiet".
  defp candidate_state(socket, rungs) do
    case typed_allocation(rungs, socket.assigns.resize_storage_omitted) do
      {:ok, allocation} ->
        {allocation, no_op?(allocation, socket.assigns.instance)}

      # F1's guards seed every rung on the real paths (open seeds all
      # three; the change merge only ever keeps ladder strings) — the
      # arm answers a crafted future state, as a quiet no-op.
      # coveralls-ignore-start
      {:error, _unseeded} ->
        {nil, true}
        # coveralls-ignore-stop
    end
  end

  # The consequence step exists only with figures AND a candidate that
  # changes something — the action's own refusal, surfaced early.
  defp proceedable?(socket) do
    figures = panel_figures(socket.assigns.rates, socket.assigns.resize_preview)

    not is_nil(figures) and not socket.assigns.resize_no_op
  end

  defp resize_open_at_confirm?(socket) do
    socket.assigns.resize_open and socket.assigns.resize_step == :confirm
  end

  # The panel's preview through the domain seam: a map, nil (unpriced),
  # or :unavailable (the read failed — the line hides, Continue stays
  # off). The preview prices the EFFECTIVE candidate: with storage
  # locked the payload omits the dimension and the action keeps the
  # row's value, so the rungs price with the row's storage substituted
  # — pricing the displayed rung would promise figures the resize
  # never charges (worst on 0 GB rows: a stopped fee that can't exist).
  defp preview_for(instance, rungs, storage_locked) do
    rungs =
      if storage_locked,
        do: Map.put(rungs, "storage_gb", Integer.to_string(instance.storage_gb)),
        else: rungs

    case typed_allocation(rungs, false) do
      {:ok, allocation} ->
        case FluxVale.Infrastructure.resize_preview(instance, allocation) do
          {:ok, preview} -> preview
          {:error, _unavailable} -> :unavailable
        end

      # F1's guards seed every rung on the real paths — the arm answers
      # a crafted future state, as a hidden line with Continue off.
      # coveralls-ignore-start
      {:error, _unseeded} ->
        :unavailable
        # coveralls-ignore-stop
    end
  end

  # The line's and the confirm's figures in one place. nil hides the
  # price line (no preview, or nothing priceable at all). An unpriced
  # ROW with a priced CANDIDATE is the repair path: no From figure
  # exists, so the line reads "To $Y/mo" and Continue stays on — the
  # no-op check is against the row, not the rate.
  defp panel_figures(nil, preview) when is_map(preview) do
    %{
      old: nil,
      new: format_rate(preview.running_cents),
      stopped: format_rate(preview.stopped_cents)
    }
  end

  defp panel_figures(nil, _preview), do: nil
  defp panel_figures(_rates, nil), do: nil
  defp panel_figures(_rates, :unavailable), do: nil

  defp panel_figures(rates, preview) do
    %{
      old: format_rate(rates.running),
      new: format_rate(preview.running_cents),
      stopped: format_rate(preview.stopped_cents)
    }
  end

  # The monthly figure: "$X/mo".
  defp format_rate(cents), do: FluxVale.Pricing.format_usd(cents) <> "/mo"

  # The action's plain refusals are the copy — joined when Ash refuses
  # with several. The status guard's message leaks the raw state atom
  # (InstanceStatus's moduledoc forbids raw state copy here) — mapped
  # to the page's impossible-action copy. The rest (shrink figures,
  # capability, expansion-check) are already plain.
  defp resize_refusal(error) do
    messages = Enum.map(error.errors, &refusal_message/1)
    Enum.join(messages, " ")
  end

  defp refusal_message(%{message: "cannot resize instance in " <> _state}) do
    "That action isn't possible from this state."
  end

  defp refusal_message(%{message: message}) when is_binary(message), do: message

  defp refusal_message(_no_plain_message), do: "Resize isn't possible right now."

  # #261 (ADR-0036 Am. 2): enabling always-on is the charge-raising
  # direction — the confirm states the consequence in the row's own
  # settlement figures (#153's one resolver, so the shown numbers are
  # the charged ones), monthly-equivalent · billed hourly per #206 like
  # every price surface, plus the wake-on-enable behavior. An unpriced
  # row (pre-#121 drift — no size, no formula snapshot) falls back to
  # figure-free copy: the gate must render even where the figures
  # don't. `monthly_cents` is the shown running figure — the accept-time
  # guard's comparison input (nil = no figure was shown).
  defp always_on_confirm(instance) do
    case FluxVale.Pricing.settlement_rates(instance, DateTime.utc_now()) do
      {:ok, %{running: running, stopped: stopped}} ->
        %{
          monthly_cents: running,
          text:
            "Keep this instance always on? It never sleeps, so it bills the full rate " <>
              "around the clock (#{FluxVale.Pricing.format_usd(running)}/mo) instead of the " <>
              "storage-only rate while it would otherwise sleep (#{FluxVale.Pricing.format_usd(stopped)}/mo), " <>
              "monthly-equivalent, billed hourly. A sleeping instance wakes immediately."
        }

      _unpriced ->
        %{
          monthly_cents: nil,
          text:
            "Keep this instance always on? It never sleeps, so it bills the full rate " <>
              "around the clock instead of the storage-only rate while it would otherwise " <>
              "sleep. A sleeping instance wakes immediately."
        }
    end
  end

  # The accept-time guard (#261 review, PA-adopted): the dialog's
  # figures are as-of the last assign — between that render and the
  # accept, an admin price edit or the grandfathering deadline can move
  # the real rate. Consent must match the charged number, so enabling
  # re-prices through the same resolver and refuses on any difference.
  # The render-time refresh alternative needs a click→event→JS-confirm
  # round trip the repo doesn't have; checking at accept time needs
  # only the figure the dialog showed (phx-value) vs fresh truth.
  defp price_moved?(params, instance) do
    case shown_figure(params) do
      nil -> false
      figure -> fresh_monthly_cents(instance) != figure
    end
  end

  # The dialog's figure rides phx-value as a string; a stale view can
  # carry anything in there. nil = no figure was shown (unpriced copy —
  # nothing to contradict, proceed); :garbled can't be matched against
  # truth, so it counts as moved — the refuse-and-re-ask arm is the
  # safe answer for garbage too.
  defp shown_figure(%{"shown_monthly_cents" => shown}) when byte_size(shown) > 0 do
    case Integer.parse(shown) do
      {cents, ""} -> cents
      _garbled -> :garbled
    end
  end

  defp shown_figure(_no_figure_shown), do: nil

  # Fresh truth at accept time: the same resolver the confirm rendered
  # from, evaluated now. Any non-integer (unpriced now, unreadable
  # rates) differs from a shown figure — refuse.
  defp fresh_monthly_cents(instance) do
    case FluxVale.Pricing.settlement_rates(instance, DateTime.utc_now()) do
      {:ok, %{running: running}} -> running
      _unavailable -> :unpriced_now
    end
  end

  # Refuse + refresh + re-ask: re-read the row (its own attrs may be
  # what moved — e.g. the grandfathering clock), re-derive the confirm
  # from it, and say the new figure out loud. A read miss keeps the
  # last state (the :destroy clause owns exits) and still re-asks.
  defp reask_always_on(socket) do
    socket =
      case fetch(socket, socket.assigns.instance.id) do
        # coveralls-ignore-start - race window: reaching nil needs the
        # row deleted between the guard's refusal and this re-read
        # inside the same event; teardown's own :destroy broadcast
        # would exit the page first, so no deterministic test can stage
        # it (refresh/2's read-miss stance).
        nil -> socket
        # coveralls-ignore-stop
        instance -> assign_instance(socket, instance)
      end

    put_flash(socket, :error, price_moved_flash(socket.assigns.always_on_confirm.monthly_cents))
  end

  defp price_moved_flash(nil),
    do: "Pricing changed since that dialog. Please review and confirm again."

  defp price_moved_flash(cents),
    do:
      "Pricing changed. Always-on would now bill #{FluxVale.Pricing.format_usd(cents)}/mo " <>
        "(billed hourly) around the clock. Please confirm again."

  # Action results and broadcast records carry no loaded relationships;
  # the page renders app name + version off the version's app (the
  # Details price row reads the row's own settlement rates — #493 — so
  # the version's recommended_size is no longer loaded).
  defp reload(instance, socket) do
    Ash.load!(instance, [app_version: [:app]], actor: socket.assigns.current_user)
  end
end
