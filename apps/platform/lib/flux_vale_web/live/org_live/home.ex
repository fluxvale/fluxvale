defmodule FluxValeWeb.OrganizationLive.Home do
  @moduledoc """
  The org home (#276): the surface the switcher's org rows link to —
  header, the org's instances, its wallet balance, its member count.
  First slice, deliberately lean; the page grows (activity, member
  management) later.

  Slug-keyed mount like the catalog. Unknown slug and non-member read
  identically — flash + home — because the slug is an enumeration
  boundary: "no such org" and "not yours" must be indistinguishable.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Infrastructure.Instance
  alias FluxValeWeb.BillingComponents

  require Ash.Query

  @impl Phoenix.LiveView
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Organization.get_by_slug(slug, actor: user) do
      {:ok, org} ->
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
    >
      <div class="space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div class="flex min-w-0 items-center gap-4">
            <div
              aria-hidden="true"
              class="flex size-12 shrink-0 items-center justify-center overflow-hidden rounded-xl bg-primary-muted text-lg font-semibold text-link"
            >
              {String.upcase(String.first(@org.name || "?"))}
            </div>
            <div class="min-w-0">
              <h1
                class="truncate text-2xl font-semibold tracking-tight text-ink"
                data-testid="org-name"
              >
                {@org.name}
              </h1>
              <p class="truncate font-mono text-sm text-ink-muted" data-testid="org-slug">
                {@org.slug}
              </p>
            </div>
          </div>
          <.button
            :if={@owner?}
            navigate={~p"/organizations/#{@org.slug}/settings"}
            variant="ghost"
            size="sm"
            data-testid="org-settings-link"
          >
            Settings
          </.button>
        </div>

        <p class="text-sm text-ink-muted" data-testid="member-count">
          {member_label(@member_count)}
        </p>

        <.card>
          <BillingComponents.balance_header balance={@balance_cents} />
        </.card>

        <section aria-labelledby="org-instances-title" class="space-y-3">
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

          <%!-- The InstanceLive.Index card shape, minus that page's
          provisioning status-tick — the tick is an optimization for the
          primary ops surface; this card renders mount-fresh state and
          refreshes on navigation. --%>
          <div id="org-instances" phx-update="stream" class="space-y-3">
            <.link
              :for={{dom_id, instance} <- @streams.instances}
              navigate={~p"/instances/#{instance.id}"}
              id={dom_id}
              data-testid="instance-row"
              class="group block rounded-xl border border-line bg-panel p-5 shadow-sm transition-all hover:border-primary/40 hover:shadow-md"
            >
              <div class="flex flex-wrap items-center justify-between gap-3">
                <div class="min-w-0">
                  <h3 class="truncate text-base font-medium text-ink transition-colors group-hover:text-primary">
                    {instance.name}
                  </h3>
                </div>
                <%!-- min-w-0 twice: the cluster is a flex child that must
                be allowed to shrink, and the app name is a flex item
                whose truncate is dead without it (a long app name
                overflowed the card by ~199px at 375). --%>
                <div class="flex min-w-0 items-center gap-3">
                  <span class="min-w-0 truncate text-sm text-ink-muted">
                    {instance.app_version.app.name}
                  </span>
                  <.status_badge status={instance.status} />
                </div>
              </div>
            </.link>
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
end
