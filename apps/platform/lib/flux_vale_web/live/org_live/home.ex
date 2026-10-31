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
             instances_empty?: instances == []
           )}
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
              metric scale. whitespace-nowrap: a wrap would grow the band
              off a string ("1 member" must never break mid-phrase). --%>
              <div class="mt-9 flex flex-wrap items-end gap-x-14 gap-y-6">
                <div>
                  <p class="eyebrow">Members</p>
                  <p
                    class="mt-1.5 whitespace-nowrap text-4xl font-bold tracking-tight text-ink min-[900px]:text-5xl"
                    data-testid="member-count"
                  >
                    {member_label(@member_count)}
                  </p>
                </div>

                <div>
                  <p class="eyebrow">Balance</p>
                  <p
                    class="mt-1.5 whitespace-nowrap text-4xl font-bold tracking-tight text-ink min-[900px]:text-5xl"
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
        The .rise wraps the SECTION container, never the rows: stream
        patches rewrite rows in place, and a rise on patched nodes would
        replay the reveal on every broadcast (node identity). --%>
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

            <%!-- The S4 row language; like the index, this page renders
            mount-fresh state and refreshes on navigation (the #179 tick
            is the primary ops surface's optimization, not this one). --%>
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
                    <%!-- #179: friendly copy only; quiet on settled states. --%>
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

  # Members may read their org's memberships (the read policy); the
  # home needs only the count today.
  defp members!(org, user) do
    Membership
    |> Ash.Query.for_read(:read, %{}, actor: user)
    |> Ash.Query.filter(organization_id == ^org.id)
    |> Ash.read!()
  end

  defp member_label(1), do: "1 member"
  defp member_label(count), do: "#{count} members"

  # The shared formatter is `Pricing.format_usd/1` (non-negative by
  # constraint); the sign is this surface's business, like the
  # dashboard's and billing's.
  defp format_balance(cents) when cents < 0, do: "-" <> Pricing.format_usd(-cents)
  defp format_balance(cents), do: Pricing.format_usd(cents)

  # Display choice, not vocabulary (#179/#203) — the dashboard's rule,
  # verbatim: settled states (running/sleeping/stopped — the list rows'
  # quiet rule) are the badge's business; everything else earns the
  # friendly message line.
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
end
