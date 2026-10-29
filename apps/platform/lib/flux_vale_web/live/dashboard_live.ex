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

  on_mount({FluxValeWeb.UserAuth, :ensure_authenticated})

  # #276: the chrome's org data — OrgNav rides after the auth gate so
  # `current_user` is already resolved. The authenticated live_session
  # carries the same pair for its own routes; this view renders through
  # `live_render`, so it declares them itself.
  on_mount({FluxValeWeb.OrgNav, :assign_orgs})

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
    <Layouts.app flash={@flash} current_user={@current_user} actor_orgs={@actor_orgs}>
      <div class="space-y-8">
        <.header>
          Dashboard
          <:subtitle>Your apps, balance, and runway at a glance.</:subtitle>
          <:actions>
            <div class="flex items-center gap-2">
              <.button navigate={~p"/billing/topup"} variant="secondary" size="sm">
                Add credits
              </.button>
              <.button navigate={~p"/apps"} size="sm">
                Deploy an app
              </.button>
            </div>
          </:actions>
        </.header>

        <div class="space-y-4">
          <%!-- Defensive-only (#124): action-created users always have a
          JIT-provisioned org. A seeded/legacy row without one keeps the
          rest of the dashboard — push_navigate isn't available to a
          live_render'd view, so this is a link, not a redirect. --%>
          <.callout :if={@wallet == :none} tone="warning" title="Billing unavailable">
            We couldn't load billing for this account. Try the <.link
              navigate={~p"/billing"}
              class="font-medium text-ink underline"
            >Billing page</.link>.
          </.callout>

          <div :if={@wallet != :none} class="grid gap-4 sm:grid-cols-2">
            <.metric_card
              label="Balance"
              value={format_usd(@wallet.balance_cents)}
              hint="Credits never expire."
              data-testid="dashboard-balance"
            />
            <.metric_card
              label="Runway"
              value={format_runway(@wallet)}
              hint={burn_hint(@wallet, @instance_count)}
              data-testid="dashboard-runway"
            />
          </div>
        </div>

        <section aria-labelledby="dashboard-instances-title" class="space-y-3">
          <div class="flex items-center justify-between gap-4">
            <h2 id="dashboard-instances-title" class="text-lg font-semibold tracking-tight text-ink">
              Instances
            </h2>
            <.link
              navigate={~p"/instances"}
              class="text-sm font-medium text-ink-muted transition-colors hover:text-ink"
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

          <%!-- Same card language as the index rows (#277 T5a/T7) — see
          instance_live/index.ex for the lift note (shadow on the link,
          motion-safe translate on the wrapper + chevron). --%>
          <div id="dashboard-instances" phx-update="stream" class="space-y-3">
            <.link
              :for={{dom_id, instance} <- @streams.instances}
              navigate={~p"/instances/#{instance.id}"}
              id={dom_id}
              data-testid="instance-row"
              class="group relative block rounded-panel border border-line-strong bg-panel p-5 shadow-sm outline-offset-2 outline-focus focus-visible:outline-2 transition-[box-shadow] duration-(--motion-base) ease-(--motion-ease-out) hover:shadow-md"
            >
              <div class="space-y-2 transition-[translate] duration-(--motion-base) ease-(--motion-ease-out) motion-safe:group-hover:-translate-y-1">
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <div class="flex min-w-0 items-center gap-3">
                    <h3 class="min-w-0 text-base font-medium text-ink transition-colors duration-(--motion-fast) [overflow-wrap:anywhere] group-hover:text-link">
                      {instance.name}
                    </h3>
                    <span class="font-mono text-xs text-ink-subtle shrink-0">{instance.slug}</span>
                  </div>
                  <div class="flex items-center gap-3">
                    <span class="text-sm text-ink-muted">
                      {instance.app_version.app.name}
                      <span class="ml-1 font-mono text-xs text-ink-subtle">
                        v{instance.app_version.version}
                      </span>
                    </span>
                    <.status_badge status={instance.status} />
                  </div>
                </div>
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
              <.icon
                name="hero-chevron-right"
                class="absolute right-1 top-5 size-4 text-ink-subtle opacity-0 transition-[opacity,translate] duration-(--motion-base) ease-(--motion-ease-out) group-hover:opacity-100 group-focus-visible:opacity-100 motion-safe:group-hover:-translate-y-1"
              />
            </.link>
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
