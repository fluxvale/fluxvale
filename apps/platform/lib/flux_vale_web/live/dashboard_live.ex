defmodule FluxValeWeb.DashboardLive do
  @moduledoc """
  The signed-in root (#205): `PageController` swaps `/` from the
  marketing landing to this view for resolved sessions — GitHub-style,
  same URL. v1 surface: instances overview with live status, wallet
  balance + runway, quick actions (deploy, top up), and fresh-account
  empty states. Structured to grow: later widgets land as new sections
  (out of scope today, per #205).

  Auth is the standard on_mount gate — this LiveView renders through
  `live_render/3` from the controller, not the authenticated
  live_session, so the hook is declared here; a revoked session turns
  the mount into the usual /sign-in redirect (live_render's stop arm
  converts it to a conn redirect).

  Live status mirrors `InstanceLive.Index`: per-instance PubSub
  subscriptions, re-read + re-stream on broadcast — broadcasts carry
  every state change. Deliberately no #179 slow-provision tick here:
  `InstanceStatus.message/1` still swaps in the taking-longer copy for
  a lingering provision (computed at mount or the last broadcast), but
  only the instances page's tick keeps that copy moving between
  writes — the dashboard's job is the at-a-glance state.

  #203 coupling is display-level only: statuses flow straight through
  `status_badge`/`InstanceStatus`, so new states land here without
  vocabulary changes. The one status list below (quiet vs. noisy) is a
  display choice, not vocabulary — settled states (running/sleeping/
  stopped, the list rows' quiet rule) say enough in a badge, everything
  else earns its friendly message line.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts
  alias FluxVale.Billing
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing
  alias FluxValeWeb.InstanceStatus

  # #121's calendar-neutral month, the one settle prorates by — pinned
  # by agreement tests. Display-only here: micro-cents/hour → the
  # monthly burn the runway hint shows.
  @seconds_per_month 2_629_746
  @micro_per_cent 10_000

  # Locale first — it must apply in this process before any rendering.
  # Same story as the pair below: the authenticated live_session
  # carries it for its own routes; this view renders through
  # `live_render`, so it declares it itself.
  on_mount({FluxValeWeb.Locale, :set_locale})

  on_mount({FluxValeWeb.UserAuth, :ensure_authenticated})

  # #276: the chrome's org data — OrgNav rides after the auth gate so
  # `current_user` is already resolved. The authenticated live_session
  # carries the same pair for its own routes; this view renders through
  # `live_render`, so it declares them itself.
  on_mount({FluxValeWeb.OrgNav, :assign_orgs})

  # The chrome's active-nav section — same story: the live_session's
  # routes get it from the router's on_mount list; this view declares it
  # itself.
  on_mount({FluxValeWeb.NavSection, :derive})

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    instances =
      Instance
      |> Ash.Query.for_read(:list_for_actor, %{}, actor: user)
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.load(app_version: :app)
      |> Ash.read!()

    socket =
      socket
      |> stream(:instances, instances)
      |> assign(:instance_count, length(instances))
      |> assign(:wallet, wallet_summary(user))
      |> subscribe(instances)

    {:ok, socket}
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
      <%!-- App-wide grammar page (S4): `bare` main + .appgram — the page
      owns ALL of main's rhythm (no max-w, no padding), same posture as
      the instance show. The metrics band is concept-1's sanctioned
      composition, RENDER-EXACT (architect call on this PR: the
      verdict'd renders beat the teardown prose — the lane's
      artifact-pixels-beat-prose precedent): the page header sits on the
      page background ABOVE the band, the Balance card tops the band's
      inside-left, and the runway floats mid-band end-anchored right —
      the diagonal is the page's bold move. NO straddle: concept-2 gives
      the ONE straddle to the instance show's status card. --%>
      <div class="appgram contents">
        <%!-- 1. The page header on the page background (above the band,
        as the render shows): title + subtitle left, quick actions
        right, bottoms flush. --%>
        <section class="wrap pt-8 pb-11">
          <div class="rise flex flex-wrap items-end justify-between gap-x-6 gap-y-4">
            <div class="min-w-0">
              <h1 class="page-title">Dashboard</h1>
              <p class="mt-2 text-base text-ink-muted">
                Your apps, balance, and runway at a glance.
              </p>
            </div>

            <div class="flex shrink-0 flex-wrap gap-2">
              <.button navigate={~p"/billing/topup"} variant="secondary">
                Add credits
              </.button>
              <.button navigate={~p"/apps"}>
                Deploy an app
              </.button>
            </div>
          </div>
        </section>

        <%!-- 2. The metrics band. Mid-page here (the header is above it
        on the page background), so it carries its own top hairline via
        utility — the grammar's .band supplies the sunken fill + the
        bottom hairline. Render insets, real numbers (page first, render
        second): the card tops the band 7px / 7px in, with 123px / 97px
        of band below it; the runway is the band's vertical center at
        the content's right edge, top inset 83px / 82px — the
        min-[760px] margin below IS that offset. Below 760px the cards
        stack inside the band (render's mobile insets 21px / 45px on the
        page). The metric values are whitespace-nowrap and step down
        below 900px (text-4xl, card capped max-w-sm there): "No active
        burn" and "under an hour" must never break mid-phrase — a wrap
        would grow the band 48px off a string (hostile F1). The values
        carry border-line-strong: the render's card edge is --line-strong
        in BOTH themes, and app.css's dark rule says raised panels carry
        depth with border emphasis (hostile F6). The runway carries no
        .rise of its own — the band's rise already carries it; a nested
        rise double-fades and double-travels (hostile F2, and now a
        grammar kill rule). Billing-down (#124, defensive-only:
        action-created users always have a JIT-provisioned org) swaps
        the metric for the callout, same card-width column, no special
        placement. --%>
        <section class="band border-t border-line">
          <div class="wrap pt-5 pb-11 min-[760px]:pt-1.5 min-[760px]:pb-24">
            <div class="rise flex flex-col gap-6 min-[760px]:flex-row min-[760px]:items-start min-[760px]:justify-between">
              <div
                :if={@wallet != :none}
                data-testid="dashboard-balance"
                class="card w-full max-w-sm min-[900px]:max-w-md border-line-strong p-5 shadow-md sm:p-6"
              >
                <p class="eyebrow">Balance</p>
                <p class="mt-1.5 whitespace-nowrap text-4xl font-bold tracking-tight text-ink min-[900px]:text-5xl">
                  {format_usd(@wallet.balance_cents)}
                </p>
                <p class="mt-1 text-xs text-ink-subtle">Credits never expire.</p>
              </div>

              <div :if={@wallet != :none} data-testid="dashboard-runway" class="min-[760px]:mt-[76px]">
                <p class="eyebrow">Runway</p>
                <p class="mt-1.5 whitespace-nowrap text-4xl font-bold tracking-tight text-ink min-[900px]:text-5xl">
                  {format_runway(@wallet)}
                </p>
                <p class="mt-1 text-xs text-ink-subtle">{burn_hint(@wallet, @instance_count)}</p>
              </div>

              <div :if={@wallet == :none} class="w-full max-w-sm min-[900px]:max-w-md">
                <.callout tone="warning" title="Billing unavailable">
                  We couldn't load billing for this account. Try the <.link
                    navigate={~p"/billing"}
                    class="font-medium text-ink underline"
                  >Billing page</.link>.
                </.callout>
              </div>
            </div>
          </div>
        </section>

        <%!-- 3. The instances overview — the render's ~80px drop from
        the band to the section heading. The .rise wraps the SECTION
        container, never the rows: stream patches rewrite rows in place,
        and a rise on patched nodes would replay the reveal on every
        broadcast (the S2/S3 lesson) — node identity is what the rise
        rides. --%>
        <section aria-labelledby="dashboard-instances-title" class="wrap pt-20 pb-12">
          <div class="rise space-y-4 [animation-delay:170ms]">
            <div class="flex items-center justify-between gap-4">
              <h2 id="dashboard-instances-title" class="text-lg font-semibold tracking-tight text-ink">
                Instances
              </h2>
              <.link
                navigate={~p"/instances"}
                class="text-sm font-medium text-link transition-colors hover:text-ink"
              >
                View all <span aria-hidden="true">&rarr;</span>
              </.link>
            </div>

            <.empty_state :if={@instance_count == 0} title="No instances yet">
              Deploy your first app from the catalog.
            </.empty_state>
            <%!-- The fresh-account onboarding nudge (#205): a welcome
            grant on the balance is exactly the "your first deploy is
            free" moment — only meaningful while nothing's deployed. --%>
            <.callout
              :if={@instance_count == 0 and @wallet != :none and @wallet.balance_cents > 0}
              tone="info"
              title="Welcome credits ready"
            >
              You have {format_usd(@wallet.balance_cents)} in credits — your first deploy is on us.
            </.callout>

            <%!-- The concept's row language: monogram chip, name + mono
            hostname, app/version, status badge. Same card language as
            the index rows (#277 T5a/T7) — and the same hit-box split
            (hostile F5): the link's own box stays put and an inner
            wrapper lifts motion-safe, so a pointer parked at the row's
            bottom 1px still lands inside the link and navigates (the
            grammar's a.card lift moves the box itself and opens a 3px
            dead band). border-line-strong + shadow-sm is the index
            rows' rest step — app.css's dark rule gives raised panels
            border emphasis, and the sibling row surface must not read
            flatter than this one (hostile F6). Grid: mobile drops
            app/version under the name at the name's left edge (the
            reference's indent); sm+ reads one line. --%>
            <div id="dashboard-instances" phx-update="stream" class="space-y-3">
              <.link
                :for={{dom_id, instance} <- @streams.instances}
                navigate={~p"/instances/#{instance.id}"}
                id={dom_id}
                data-testid="instance-row"
                class="group relative block rounded-panel border border-line-strong bg-panel p-4 shadow-sm outline-offset-2 outline-focus focus-visible:outline-2 transition-[box-shadow] duration-(--motion-base) ease-(--motion-ease-out) hover:shadow-md sm:p-5"
              >
                <div class="grid grid-cols-[auto_minmax(0,1fr)] items-center gap-x-4 gap-y-2 transition-[translate] duration-(--motion-base) ease-(--motion-ease-out) motion-safe:group-hover:-translate-y-1 sm:grid-cols-[auto_minmax(0,1fr)_auto_auto]">
                  <span
                    aria-hidden="true"
                    class="grid size-9 place-items-center rounded-panel border border-primary/25 bg-primary-muted font-mono text-xs font-semibold text-link"
                  >
                    {monogram(instance.name)}
                  </span>

                  <div class="min-w-0 space-y-0.5">
                    <h3 class="min-w-0 text-base font-medium text-ink transition-colors duration-(--motion-fast) [overflow-wrap:anywhere] group-hover:text-link">
                      {instance.name}
                    </h3>
                    <p class="truncate font-mono text-xs text-ink-subtle">{instance.slug}</p>
                    <%!-- #179 friendly copy only; quiet on settled states —
                    see the moduledoc's #203 note. --%>
                    <p
                      :if={noisy?(instance.status)}
                      class="truncate text-xs text-ink-subtle"
                      data-testid="instance-status-message"
                    >
                      {InstanceStatus.message(instance)}
                    </p>
                  </div>

                  <div class="col-start-2 row-start-2 flex items-center gap-3 sm:col-start-3 sm:row-start-1">
                    <span class="text-sm text-ink-muted">
                      {instance.app_version.app.name}
                      <span class="ml-1 font-mono text-xs text-ink-subtle">
                        v{instance.app_version.version}
                      </span>
                    </span>
                    <.status_badge status={instance.status} />
                  </div>

                  <.icon
                    name="hero-chevron-right"
                    class="hidden size-4 text-ink-subtle opacity-0 transition-[opacity] duration-(--motion-base) ease-(--motion-ease-out) group-hover:opacity-100 group-focus-visible:opacity-100 sm:col-start-4 sm:row-start-1 sm:block"
                  />
                </div>
              </.link>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  # Teardown's hard delete — the row leaves the stream, and the wallet
  # follows: a stopped burn changes the runway (CodeRabbit #207).
  def handle_info(
        %Ash.Notifier.Notification{action: %{name: :destroy}} = notification,
        socket
      ) do
    socket =
      socket
      |> stream_delete(:instances, notification.data)
      |> assign(:instance_count, socket.assigns.instance_count - 1)
      |> refresh_wallet()

    {:noreply, socket}
  end

  # Re-read the row on broadcast (the DB is the one ordering that can't
  # lie — a trailing notification can predate fresher writes) and
  # re-stream it loaded: the row template renders the app name. The
  # wallet rides along: a transition that changes burn (starting →
  # running) must move the runway card with it, or the dashboard
  # contradicts its own live status.
  def handle_info(%Ash.Notifier.Notification{data: %{id: id}}, socket) do
    case Instance.get_by_id(id, actor: socket.assigns.current_user) do
      {:ok, instance} ->
        instance = Ash.load!(instance, [app_version: :app], actor: socket.assigns.current_user)

        {:noreply,
         socket
         |> stream_insert(:instances, instance)
         |> refresh_wallet()}

      _error ->
        # Destroy races land here too — the destroy clause handles the
        # page exit; the row leaves via stream_delete there.
        {:noreply, socket}
    end
  end

  # Display choice, not vocabulary (#179/#203): settled states
  # (running/sleeping/stopped — the list rows' quiet rule) are the
  # badge's business; everything else earns the friendly message line.
  defp noisy?(status), do: status not in [:running, :sleeping, :stopped]

  # The row chip's mark (S4's reference rows): the name's first two
  # GRAPHEMES, uppercased — String.graphemes, not String.slice, so a
  # multi-codepoint glyph (emoji, combining accent) is never split.
  defp monogram(name) do
    name
    |> String.graphemes()
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  defp subscribe(socket, instances) do
    Enum.reduce(instances, socket, fn instance, socket ->
      Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")
      socket
    end)
  end

  # The wallet block for the metric cards: balance + the #124 runway
  # projection. `ensure_wallet` is the system seam (idempotent), like
  # the billing surface; `:none` is the no-org defensive arm.
  defp wallet_summary(user) do
    case Accounts.personal_org_for_user(user.id, actor: user) do
      {:ok, org} ->
        {:ok, wallet} = Billing.ensure_wallet(org)
        {:ok, runway} = Billing.compute_runway(wallet)

        %{
          balance_cents: runway.balance_cents,
          runway_hours: runway.runway_hours,
          burn_micro_cents_per_hour: runway.burn_micro_cents_per_hour
        }

      :none ->
        :none
    end
  end

  defp refresh_wallet(socket) do
    assign(socket, :wallet, wallet_summary(socket.assigns.current_user))
  end

  # The shared formatter is `Pricing.format_usd/1` (non-negative by
  # constraint); the sign is this surface's business, like billing's.
  defp format_usd(cents) when cents < 0, do: "-" <> Pricing.format_usd(-cents)
  defp format_usd(cents), do: Pricing.format_usd(cents)

  # A spent wallet is out of runway — "under an hour" would read as
  # nearly-there. :infinity (no burn) reads as itself.
  defp format_runway(%{balance_cents: cents}) when cents < 0, do: "Depleted"
  defp format_runway(%{runway_hours: :infinity}), do: "No active burn"

  defp format_runway(%{runway_hours: hours}) when hours < 1, do: "under an hour"

  defp format_runway(%{runway_hours: hours}) when hours < 48,
    do: "≈ #{round(hours)} #{plural(round(hours), "hour")}"

  defp format_runway(%{runway_hours: hours}) do
    days = hours / 24

    if days < 60 do
      "≈ #{round(days)} #{plural(round(days), "day")}"
    else
      months = days * 24 * 3600 / @seconds_per_month
      "≈ #{round(months)} #{plural(round(months), "month")}"
    end
  end

  # Zero burn reads differently by account shape: nothing deployed yet
  # (the onboarding nudge) vs. nothing accruing right now.
  defp burn_hint(%{burn_micro_cents_per_hour: 0}, 0),
    do: "Your first deploy starts the meter."

  defp burn_hint(%{burn_micro_cents_per_hour: 0}, _instance_count),
    do: "Nothing burning right now."

  defp burn_hint(%{burn_micro_cents_per_hour: burn_micro}, _instance_count) do
    monthly_cents = div(burn_micro * @seconds_per_month, @micro_per_cent * 3600)
    "at #{format_usd(monthly_cents)}/mo current burn"
  end

  defp plural(1, unit), do: unit
  defp plural(_n, unit), do: "#{unit}s"
end
