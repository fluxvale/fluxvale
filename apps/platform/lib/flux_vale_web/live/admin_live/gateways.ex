defmodule FluxValeWeb.AdminLive.Gateways do
  @moduledoc """
  The admin access-gateways surface (#501): every gateway the console
  can legally see in one table, read-only by design (the v1 plan made
  gateways/domains oversight; registration, keys, and config belong to
  the product surfaces — the org Access panel and the provider API).

  The honesty the surface can offer is bounded by its read policy:
  `AccessGateway` reads are members-only (`relates_to_actor_via`
  [:organization, :members]) with NO platform-admin arm — unlike the
  wallet seam the orgs surface rides. `relates_to_actor_via` is a
  FILTER, so a non-member admin's read answers `[]`, not Forbidden:
  this list is exactly the gateways of orgs the admin belongs to. The
  empty state says that in its title (filter-scoped, never a global
  claim), and for an admin with no org memberships at all (only
  producible by bypassing the create's JIT personal org) a scope note
  says why the list is empty instead. Widening the read policy is a
  policy change this lane does not make — the gap is reported, not
  built around (#613).

  Columns the policies admit: the org name (the flagged `:admin_lookup`
  seam, the lane's one org path), the identifier grammar the product
  uses (`fv-<8 hex>` + the tailnet domain, ADR-0039 §1), the state (the
  product's own vocabulary, rendered through the section's shared badge
  in AdminComponents with a shape cue per state), the rate snapshot,
  the created stamp. The credential references stay off the list: they
  render on the detail page, as names, with the copy that keeps them
  honest.

  Attention first: a gateway whose STATE is `:needs_attention` pins to
  the top, then newest created. The pin keys on the state, not the
  `needs_attention_since` stamp — Suspend does not clear that stamp, so
  a stamp-keyed sort would pin a suspended row indefinitely (the review
  finding; the domain-side fix is #613, not ours). The list caps at the
  latest 100 (the lane's cap rationale). Revisit trigger: pagination
  once gateway volume approaches the cap. Search narrows by hostname or
  org name/slug — the relationship filter runs at the data layer, so
  the search never needs an org read.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Pricing
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.AdminShell

  require Ash.Query
  require Ash.Expr

  # The list cap (the moduledoc names it; move the two together): an
  # unbounded read is an unindexed sort away from growing expensive,
  # and the operator finds a gateway by search, not by paging. Revisit
  # trigger: pagination once gateway volume approaches the cap.
  @list_cap 100

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    # The chrome assigns (current_user, username, nav_section) ride the
    # AdminChrome on_mount on the :admin live_session — this mount adds
    # only the page's own data.
    {:ok,
     socket
     |> assign(query: "")
     |> assign(search_form: to_form(%{"query" => ""}, as: :search))
     |> refresh_rows()}
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    trimmed = String.trim(query)

    {:noreply,
     socket
     |> assign(query: trimmed, search_form: to_form(%{"query" => trimmed}, as: :search))
     |> refresh_rows()}
  end

  # -- reads ----------------------------------------------------------------

  # Attention first, then newest provisioned. The pin is a STATE-keyed
  # expression sort (Ash.Expr.calc): needs_attention_since is written
  # by the state funnel but never cleared by Suspend, so a stamp-keyed
  # sort would pin a suspended row above a newer active one forever.
  # Capped one past the cap so the overflow question answers without a
  # count. The org names ride the flagged lookup seam — one read for
  # the page's ids, mapped by id; a gateway whose org vanished (the FK
  # is :restrict, so this cannot happen today) would simply render
  # without a name.
  defp refresh_rows(socket) do
    admin = socket.assigns.current_user

    fetched =
      AccessGateway
      |> Ash.Query.for_read(:read, %{}, actor: admin)
      |> Ash.Query.sort([
        {Ash.Expr.calc(state == :needs_attention), :desc},
        {:created_at, :desc},
        {:id, :desc}
      ])
      |> maybe_search(socket.assigns.query)
      |> Ash.Query.limit(@list_cap + 1)
      |> Ash.read!()

    capped? = length(fetched) > @list_cap
    gateways = Enum.take(fetched, @list_cap)

    socket
    |> assign(
      orgs: org_lookup(admin, gateways),
      any_membership?: any_membership?(admin),
      rows_empty?: gateways == [],
      rows_capped?: capped?
    )
    |> stream(:gateways, gateways, reset: true)
  end

  defp maybe_search(query, ""), do: query

  # The scope filter, drawn in data: hostname (the row's identifier) or
  # org name/slug (whose gateway it is), nothing past it. The
  # relationship filter runs at the data layer — no Organization read
  # rides the search.
  defp maybe_search(query, term) do
    # ILIKE wildcards in the term are literals: escaped before the
    # pattern wraps both ends (the backslash first, or it would
    # double-escape the ones below).
    escaped =
      term
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    pattern = "%#{escaped}%"

    # Non-keyword call form: filter/2 routes it through Ash.Expr.expr,
    # where the exists()/ilike() calls and the relationship path parse
    # as one filter. (The keyword-list form bypasses expr and would
    # compile the calls as plain Elixir.)
    Ash.Query.filter(
      query,
      ilike(hostname, ^pattern) or
        exists(organization, ilike(name, ^pattern)) or
        exists(organization, ilike(slug, ^pattern))
    )
  end

  defp org_lookup(_admin, []), do: %{}

  defp org_lookup(admin, gateways) do
    organization_ids = Enum.map(gateways, & &1.organization_id)
    ids = Enum.uniq(organization_ids)

    {:ok, orgs} =
      Organization
      |> Ash.ActionInput.for_action(:admin_lookup, %{ids: ids}, actor: admin)
      |> Ash.run_action()

    Map.new(orgs, fn org -> {org.id, org} end)
  end

  # The membership probe (the orgs slice's, generalized to "any"): the
  # Membership read policy is members-only with the same
  # relates_to_actor_via filter, so a non-member admin's read answers
  # [] — the policy's own "you are not inside" answer. No new action,
  # no widened policy. It serves ONLY the org-less shape (a seeded
  # service account): a product-created admin always carries the JIT
  # personal org, so the main empty state stays filter-scoped and never
  # leans on this.
  defp any_membership?(admin) do
    Membership
    |> Ash.Query.for_read(:read, %{}, actor: admin)
    |> Ash.Query.filter(user_id == ^admin.id)
    |> Ash.read!()
    |> Enum.any?()
  end

  # -- display helpers ------------------------------------------------------

  # The :error arms are the vanished-org guard (the gateway FK is
  # :restrict, so the org cannot be gone while the gateway stands) —
  # not simulatable without dropping the constraint.
  defp org_name(orgs, gateway) do
    case Map.fetch(orgs, gateway.organization_id) do
      {:ok, org} -> org.name
      # coveralls-ignore-next-line - unreachable while the FK stands
      :error -> nil
    end
  end

  defp org_slug(orgs, gateway) do
    case Map.fetch(orgs, gateway.organization_id) do
      {:ok, org} -> org.slug
      # coveralls-ignore-next-line - unreachable while the FK stands
      :error -> nil
    end
  end

  # Reached only under the created_at guard in the template.
  defp stamp_text(stamp), do: Calendar.strftime(stamp, "%b %d, %Y")

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
      wide
    >
      <%!-- The console lane (#593): `wide` chrome + `appgram console`
      - flush sidebar, the surface fills the space beside it. --%>
      <div class="appgram console contents" data-testid="admin-gateways">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">{gettext("Access gateways and domains")}</h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext(
                  "Private-access gateways and the domains that serve them. This page is read-only: registration and keys live on each org's Access panel."
                )}
              </p>
              <%!-- The one honesty statement the page carries: the read
              scope, stated at fact weight, not as a footnote (the orgs
              surface's treatment). --%>
              <p class="mt-1 max-w-prose text-sm font-medium text-ink">
                {gettext(
                  "Gateway reads are member-scoped, so this list is the gateways of orgs you belong to."
                )}
              </p>
            </div>
          </div>
        </section>

        <%!-- The section sidebar (Am. 4, the #568 idiom) owns
        cross-section wayfinding — no console-level back link. The
        search card and the list are one content column beside it. --%>
        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <AdminShell.sidebar current="gateways" />

            <div class="min-w-0 flex-1 space-y-6">
              <.card class="space-y-4" data-testid="admin-gateways-search-card">
                <div>
                  <h2 class="text-base font-medium text-ink">{gettext("Find a gateway")}</h2>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext(
                      "Search narrows this list by hostname or org name or slug. It never reaches past it."
                    )}
                  </p>
                </div>
                <.form
                  for={@search_form}
                  id="admin-gateways-search"
                  phx-change="search"
                  phx-submit="search"
                >
                  <.input
                    field={@search_form[:query]}
                    type="text"
                    label={gettext("Hostname or org")}
                    placeholder={gettext("Search by hostname or org name or slug")}
                    phx-debounce="200"
                    data-testid="admin-gateways-search-input"
                  />
                </.form>
              </.card>

              <div class="space-y-4" data-testid="admin-gateways-list">
                <%!-- The count is the @list_cap above (kept literal here —
                a module attribute reads as assigns inside HEEx); move the
                two together. --%>
                <p
                  :if={@rows_capped?}
                  class="text-sm text-ink-muted"
                  data-testid="admin-gateways-capped"
                >
                  {gettext("Showing the latest 100 gateways. Attention pins to the top.")}
                </p>

                <%!-- The empty states ride the lane's panel-inset shape
                (the scope note's card, the #571/#603 treatment) — no
                dashed boxes on this surface, dark mode included. The
                MAIN empty is filter-scoped: the member-scoped read
                cannot support a global claim, so the title names the
                orgs this admin belongs to and only the copy carries
                the once-enabled story. --%>
                <div
                  :if={@rows_empty? and @query == "" and @any_membership?}
                  class="rounded-panel border border-line bg-panel px-4 py-3"
                  data-testid="admin-gateways-empty"
                >
                  <p class="text-sm font-medium text-ink">
                    {gettext("No gateways in the orgs you belong to.")}
                  </p>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext(
                      "Private access is opt-in per org. An org's gateway appears here once its owner enables it."
                    )}
                  </p>
                </div>

                <%!-- The honest scope note: a members-only read cannot
                tell "no gateways anywhere" from "not yours to see", so
                the membership probe answers and the page states which
                emptiness this is (the orgs slice's discipline). --%>
                <div
                  :if={@rows_empty? and @query == "" and not @any_membership?}
                  class="rounded-panel border border-line bg-panel px-4 py-3"
                  data-testid="admin-gateways-scope-note"
                >
                  <p class="text-sm font-medium text-ink">
                    {gettext("You are not a member of any org.")}
                  </p>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext("Gateways are readable by org members only, so none are listed here.")}
                  </p>
                </div>

                <div
                  :if={@rows_empty? and @query != ""}
                  class="rounded-panel border border-line bg-panel px-4 py-3"
                  data-testid="admin-gateways-search-empty"
                >
                  <p class="text-sm font-medium text-ink">
                    {gettext("No gateway matches that search.")}
                  </p>
                </div>

                <%!-- The table chrome lives under the rows guard: an
                empty list renders its honest empty state, never a dead
                header (the people surface's structure). One grid
                template shared by the header and every row (kept
                literal in both spots), so the columns can never drift.
                Every track shrinks (minmax(0, …)) inside the fixed
                ones; the whole chrome rides its own scroll below the
                fixed tracks' floor (the people surface's
                floor-and-scroll idiom), so the page never scrolls
                sideways. The gutter is the console's disclosed delta
                (the review round): gap-x-3, so the right-aligned tracks
                stop colliding with their neighbors. --%>
                <div :if={not @rows_empty?} class="overflow-x-auto">
                  <div class="min-w-[32.25rem]">
                    <div class="grid grid-cols-[minmax(0,1.5fr)_minmax(0,1.2fr)_9.5rem_7.5rem_6.5rem_3.5rem] items-center gap-x-3 border-b border-line px-3 py-3 text-left text-xs font-medium tracking-wide text-ink-muted uppercase">
                      <div>{gettext("Organization")}</div>
                      <div>{gettext("Gateway")}</div>
                      <div>{gettext("State")}</div>
                      <div class="text-right">{gettext("Rate")}</div>
                      <div>{gettext("Created")}</div>
                      <div class="sr-only">{gettext("Actions")}</div>
                    </div>

                    <div>
                      <div id="admin-gateways-table" phx-update="stream">
                        <div
                          :for={{dom_id, gateway} <- @streams.gateways}
                          id={dom_id}
                          class="grid grid-cols-[minmax(0,1.5fr)_minmax(0,1.2fr)_9.5rem_7.5rem_6.5rem_3.5rem] items-center gap-x-3 border-b border-line px-3 py-3 transition-colors last:border-0 hover:bg-panel-raised/60"
                        >
                          <div class="min-w-0" data-testid={"admin-gateways-org-#{gateway.id}"}>
                            <p class="truncate font-medium text-ink">{org_name(@orgs, gateway)}</p>
                            <p class="truncate font-mono text-xs text-ink-muted">
                              {org_slug(@orgs, gateway)}
                            </p>
                          </div>
                          <div class="min-w-0" data-testid={"admin-gateways-host-#{gateway.id}"}>
                            <p class="truncate font-mono text-sm text-ink">{gateway.hostname}</p>
                            <p class="truncate font-mono text-xs text-ink-muted">
                              {gateway.tailnet_domain}
                            </p>
                          </div>
                          <div>
                            <span data-testid={"admin-gateways-state-#{gateway.id}"}>
                              <AdminComponents.gateway_state_badge state={gateway.state} />
                            </span>
                          </div>
                          <div class="text-right">
                            <span
                              class="whitespace-nowrap text-sm tabular-nums text-ink"
                              data-testid={"admin-gateways-rate-#{gateway.id}"}
                            >
                              {Pricing.format_usd(gateway.monthly_cents)}
                              <span class="text-xs font-normal text-ink-muted">
                                {gettext("per month")}
                              </span>
                            </span>
                          </div>
                          <div>
                            <span
                              :if={gateway.created_at}
                              class="text-sm text-ink-muted"
                              data-testid={"admin-gateways-created-#{gateway.id}"}
                            >
                              {stamp_text(gateway.created_at)}
                            </span>
                          </div>
                          <div>
                            <div class="flex items-center justify-end">
                              <.link
                                navigate={~p"/admin/gateways/#{gateway.id}"}
                                data-testid={"admin-gateways-open-#{gateway.id}"}
                                class="text-sm font-medium text-link underline-offset-2 hover:underline"
                              >
                                {gettext("Open")}
                              </.link>
                            </div>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
