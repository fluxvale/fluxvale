defmodule FluxValeWeb.OrganizationLive.Home do
  @moduledoc """
  The org home (#276): the surface the switcher's org rows link to —
  header, the org's instances, its wallet balance, its member count.
  First slice, deliberately lean; the page grows (activity, member
  management) later.

  Slug-keyed mount like the catalog. Unknown slug and non-member read
  identically — flash + home — because the slug is an enumeration
  boundary: "no such org" and "not yours" must be indistinguishable.
  The actor's personal org redirects to `/` (S5) — it never renders
  this page.

  Live like the dashboard (S6): per-instance PubSub subscriptions,
  re-read + re-stream on broadcast — a destroy on another tab must not
  leave a phantom row, and a burn change must move the band's balance.
  Deliberately no #179 slow-provision tick: the tick is the primary ops
  surface's optimization; this page renders mount-fresh state, refreshes
  on broadcast, and reloads on navigation.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing
  alias FluxValeWeb.InstanceStatus
  alias FluxValeWeb.PersonalOrg

  require Ash.Query

  @impl Phoenix.LiveView
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Organization.get_by_slug(slug, actor: user) do
      {:ok, org} ->
        if PersonalOrg.personal?(socket, org) do
          # S5: the personal org never presents as one — its org-scoped
          # URLs redirect to the account's own surfaces, flash-free
          # (nothing failed). Its instances and balance already live on
          # the dashboard.
          {:ok, push_navigate(socket, to: ~p"/")}
        else
          instances =
            Instance
            |> Ash.Query.for_read(:list_for_organization, %{organization_id: org.id}, actor: user)
            |> Ash.Query.sort(created_at: :desc)
            |> Ash.Query.load(app_version: :app)
            |> Ash.read!()

          members = members!(org, user)

          # ensure_wallet is the system seam (idempotent), like the billing
          # surface; the balance read rides the wallet policies.
          {:ok, wallet} = Billing.ensure_wallet(org)
          {:ok, balance} = Billing.balance(wallet, actor: user)

          {:ok,
           socket
           |> stream(:instances, instances)
           |> assign(
             org: org,
             owner?: ActorIsOrganizationOwner.owner?(user, org),
             member_count: length(members),
             balance_cents: balance,
             instance_count: length(instances),
             instances_empty?: instances == []
           )
           |> subscribe(instances)}
        end

      # Unknown slug and non-member land here together: the read policy
      # denies a stranger exactly as a miss does — no enumeration signal.
      _error ->
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  # Teardown's hard delete — the row leaves the stream and the facts
  # follow: a destroyed row's burn changes the org's balance, and the
  # empty state replaces the last row.
  def handle_info(
        %Ash.Notifier.Notification{action: %{name: :destroy}} = notification,
        socket
      ) do
    count = socket.assigns.instance_count - 1

    socket =
      socket
      |> stream_delete(:instances, notification.data)
      |> assign(instance_count: count, instances_empty?: count == 0)
      |> refresh_facts()

    {:noreply, socket}
  end

  # Re-read the row on broadcast (the DB is the one ordering that can't
  # lie — a trailing notification can predate fresher writes) and
  # re-stream it loaded: the row template renders the app name. The
  # facts ride along: a transition that changes burn (starting →
  # running) must move the org's balance with it, or the band would
  # contradict the row's live status.
  def handle_info(%Ash.Notifier.Notification{data: %{id: id}}, socket) do
    case Instance.get_by_id(id, actor: socket.assigns.current_user) do
      {:ok, instance} ->
        instance = Ash.load!(instance, [app_version: :app], actor: socket.assigns.current_user)

        {:noreply,
         socket
         |> stream_insert(:instances, instance)
         |> refresh_facts()}

      _error ->
        # Destroy races land here too — the destroy clause handles the
        # page exit; the row leaves via stream_delete there.
        {:noreply, socket}
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
      bare
    >
      <%!-- App-wide grammar page (S6): `bare` main + .appgram — the page
      owns ALL of main's rhythm (no max-w, no padding). List pages stay
      calm: the sunken band carries the header, no straddle. --%>
      <div class="appgram contents">
        <%!-- 1. The sunken band header: the org's identity (mark,
        page-title name, mono slug) with the owner's Settings link, and
        the org's facts as eyebrow-labeled values inside the band — the
        dashboard's in-band Balance posture, NOT floating stat cards. --%>
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <div class="flex flex-wrap items-end justify-between gap-x-6 gap-y-4">
                <div class="flex min-w-0 items-center gap-4">
                  <div
                    aria-hidden="true"
                    class="grid size-12 shrink-0 place-items-center overflow-hidden rounded-panel border border-primary/25 bg-primary-muted text-lg font-semibold text-link"
                  >
                    {String.upcase(String.first(@org.name || "?"))}
                  </div>
                  <div class="min-w-0">
                    <p class="eyebrow">Organization</p>
                    <h1 class="page-title mt-1.5 truncate" data-testid="org-name">
                      {@org.name}
                    </h1>
                    <p
                      class="mt-1.5 truncate font-mono text-sm text-ink-muted"
                      data-testid="org-slug"
                    >
                      {@org.slug}
                    </p>
                  </div>
                </div>

                <div class="flex shrink-0 gap-2">
                  <.button
                    :if={@owner?}
                    navigate={~p"/organizations/#{@org.slug}/settings"}
                    variant="secondary"
                    data-testid="org-settings-link"
                  >
                    Settings
                  </.button>
                </div>
              </div>

              <%!-- The facts: eyebrow-labeled values on the dashboard's
              metric scale, stepping down one type step and one gap step
              below 420px so the pair fits the viewport at every sweep
              width — whitespace-nowrap protects the phrases, but the
              guard is the PAIR: "2 members" + gap + "$111.00" wrapped
              and grew the band 86.5px off the balance value at 375
              (hostile-339 F3 — the S4 F1 lesson: a band never grows off
              a string; flex-wrap stays as the safety valve for values
              beyond the fixture set, never for the fixture set). --%>
              <div class="mt-9 flex flex-wrap items-end gap-x-6 gap-y-6 min-[420px]:gap-x-14">
                <div>
                  <p class="eyebrow">Members</p>
                  <p
                    class="mt-1.5 whitespace-nowrap text-3xl font-bold tracking-tight text-ink min-[420px]:text-4xl min-[900px]:text-5xl"
                    data-testid="member-count"
                  >
                    {member_label(@member_count)}
                  </p>
                </div>

                <div>
                  <p class="eyebrow">Balance</p>
                  <p
                    class="mt-1.5 whitespace-nowrap text-3xl font-bold tracking-tight text-ink min-[420px]:text-4xl min-[900px]:text-5xl"
                    data-testid="wallet-balance"
                  >
                    {format_balance(@balance_cents)}
                  </p>
                </div>
              </div>
            </div>
          </div>
        </section>

        <%!-- 2. The org's instances in the S4 row language
        (dashboard_live.ex is the reference — same chip, name+slug,
        app/version, badge, rest step, and the same hit-box split: the
        link's own box stays put, an inner wrapper lifts motion-safe).
        The .rise wraps the section's content container — the heading,
        the empty state, and the stream container — never the rows
        themselves: stream patches rewrite rows in place, and a rise on
        patched nodes would replay the reveal on every broadcast (node
        identity). --%>
        <section aria-labelledby="org-instances-title" class="wrap pt-14 pb-16">
          <div class="rise space-y-4 [animation-delay:170ms]">
            <h2 id="org-instances-title" class="text-lg font-semibold tracking-tight text-ink">
              Instances
            </h2>

            <%!-- Empty state outside the stream container: streams can't
            count (the billing surface's stance). --%>
            <div :if={@instances_empty?} data-testid="instances-empty">
              <.empty_state title="No instances yet">
                Deploy this organization's first app from the <.link
                  navigate={~p"/apps"}
                  class="underline underline-offset-2 hover:text-ink"
                >
                  catalog
                </.link>.
              </.empty_state>
            </div>

            <%!-- The S4 row language, live via the instances:<id>
            broadcasts above (no #179 tick — the primary ops surface's
            optimization, not this one). --%>
            <div id="org-instances" phx-update="stream" class="space-y-3">
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
                    <%!-- #179: friendly copy only — raw status_message
                    never renders here. copy_status? is the EXPLICIT
                    positive list, NOT the dashboard's noisy? predicate:
                    :restoring is deliberately excluded (ADR-0037 — the
                    state owns the show page, the row's job is the
                    badge), and the predicate's polarity would silently
                    add it (its copy is the app's longest; a flip is a
                    behavior change, hostile-339 F1). --%>
                    <p
                      :if={copy_status?(instance.status)}
                      class="truncate text-xs text-ink-subtle"
                      data-testid="instance-status-message"
                    >
                      {InstanceStatus.message(instance)}
                    </p>
                  </div>

                  <div class="col-start-2 row-start-2 flex items-center gap-3 sm:col-start-3 sm:row-start-1">
                    <%!-- min-w-0 truncate: the cluster's flex item must be
                    allowed to shrink — a long single-token app name
                    otherwise blows the auto column out and paints the
                    badge outside the row (the pre-S6 markup carried this
                    guard for exactly that measured ~199px overflow at
                    375; hostile-339 F2). --%>
                    <span class="min-w-0 truncate text-sm text-ink-muted">
                      {instance.app_version.app.name}
                      <span class="ml-1 font-mono text-xs text-ink-subtle">
                        v{instance.app_version.version}
                      </span>
                    </span>
                    <.status_badge status={instance.status} />
                  </div>

                  <%!-- In-flow grid cell (vs an absolute pin): always
                  occupying the cell keeps the message column's measure
                  stable, and items-center on the cell answers the old
                  top-5 calibration — the reveal centers on the row's
                  full height instead of pinning to a first line that
                  moves on two-line rows, so there is no collision to
                  tune away. It rides no translate: the wrapper's lift
                  moves the content, and a moving chevron under a
                  stationary pointer is the dead-band bug the hit-box
                  split exists to prevent. --%>
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

  # Members may read their org's memberships (the read policy); the
  # home needs only the count today.
  defp members!(org, user) do
    Membership
    |> Ash.Query.for_read(:read, %{}, actor: user)
    |> Ash.Query.filter(organization_id == ^org.id)
    |> Ash.read!()
  end

  # Per-instance PubSub subscriptions — the dashboard's shape: every
  # state change broadcasts on instances:<id>, and the page re-streams
  # from it (a destroy on another tab must not leave a phantom row).
  defp subscribe(socket, instances) do
    Enum.reduce(instances, socket, fn instance, socket ->
      Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")
      socket
    end)
  end

  defp refresh_facts(socket) do
    {:ok, wallet} = Billing.ensure_wallet(socket.assigns.org)
    {:ok, balance} = Billing.balance(wallet, actor: socket.assigns.current_user)

    assign(socket, :balance_cents, balance)
  end

  defp member_label(1), do: "1 member"
  defp member_label(count), do: "#{count} members"

  # The shared formatter is `Pricing.format_usd/1` (non-negative by
  # constraint); the sign is this surface's business, like the
  # dashboard's and billing's.
  defp format_balance(cents) when cents < 0, do: "-" <> Pricing.format_usd(-cents)
  defp format_balance(cents), do: Pricing.format_usd(cents)

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

  # The statuses whose row carries the #179 friendly copy line — the
  # EXPLICIT positive list, not a negation: :restoring is deliberately
  # excluded (ADR-0037 — the state owns the show page, the row's job is
  # the badge) and a negative predicate's polarity would silently add it
  # (its copy is the app's longest; a flip is a behavior change,
  # hostile-339 F1).
  defp copy_status?(status),
    do: status in [:pending, :deploying, :starting, :error, :deleting, :lost]
end
