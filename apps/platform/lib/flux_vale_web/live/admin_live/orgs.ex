defmodule FluxValeWeb.AdminLive.Orgs do
  @moduledoc """
  The admin orgs surface (#501): every org with a wallet in one table,
  read-only by design (the v1 plan reserved this section's writes).

  The list's spine is the wallet read — a curation choice now, not a
  policy constraint: the org read itself admits platform admins
  cross-org (ADR-0047's blanket bypass), but this surface's meaning is
  wallet state, and every row IS the org's wallet (the unique_org
  identity makes org and wallet one-to-one). The names ride the shared
  `Organization :admin_lookup` seam — kept deliberately over the now-
  admitted primary read: it is the one batched, switcher-shaped idiom
  every admin surface shares (id, name, slug — exactly the fields the
  tables render), so the surfaces stay one grammar. What the table
  does NOT carry is honest curation, not policy:

  - member count — Membership rows render on no admin surface today;
    the count is not this table's question.
  - instance count — an org's instances render on the detail page,
    cross-org since the bypass.
  - the org's own created stamp — :admin_lookup returns id, name, and
    slug only; the stamp shown is the wallet's provisioning date,
    labeled as such.

  The list caps at the latest 100 (the wallets surface's rationale: an
  unbounded scan grows expensive and the operator scans for what just
  happened anyway). Revisit trigger: pagination once org volume
  approaches the cap. Search narrows the list by org name or slug,
  scoped to the list — the relationship filter runs at the data layer,
  so the search never needs an org read.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.Wallet
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.AdminShell
  alias FluxValeWeb.BillingComponents

  require Ash.Query
  require Ash.Expr

  # The list cap (the moduledoc names it; move the two together): an
  # unbounded read is an unindexed sort away from growing expensive,
  # and the operator finds an org by search, not by paging. Revisit
  # trigger: pagination once org volume approaches the cap.
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

  # Attention first: the destroy-clock rows pin to the top (the wallets
  # surface's order), then newest provisioned. Capped one past the cap
  # so the overflow question answers without a count. The org names
  # ride the shared lookup seam (see the moduledoc for why it stays
  # over the now-admitted primary read) — one read for the page's ids,
  # mapped by id; a wallet whose org vanished (the FK has no ON DELETE,
  # so this cannot happen today) would simply render without a name.
  defp refresh_rows(socket) do
    admin = socket.assigns.current_user

    fetched =
      Wallet
      |> Ash.Query.for_read(:read, %{}, actor: admin)
      |> Ash.Query.sort(negative_since: :desc_nils_last, created_at: :desc, id: :desc)
      |> maybe_search(socket.assigns.query)
      |> Ash.Query.limit(@list_cap + 1)
      |> Ash.Query.load(:balance)
      |> Ash.read!()

    capped? = length(fetched) > @list_cap
    wallets = Enum.take(fetched, @list_cap)

    socket
    |> assign(
      orgs: org_lookup(admin, wallets),
      rows_empty?: wallets == [],
      rows_capped?: capped?
    )
    |> stream(:wallets, wallets, reset: true)
  end

  defp maybe_search(query, ""), do: query

  # The scope filter, drawn in data: org name or org slug (the org's
  # address), nothing past it. The relationship filter runs at the data
  # layer — no Organization read rides the search.
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
      exists(organization, ilike(name, ^pattern)) or
        exists(organization, ilike(slug, ^pattern))
    )
  end

  defp org_lookup(_admin, []), do: %{}

  defp org_lookup(admin, wallets) do
    organization_ids = Enum.map(wallets, & &1.organization_id)
    ids = Enum.uniq(organization_ids)

    {:ok, orgs} =
      Organization
      |> Ash.ActionInput.for_action(:admin_lookup, %{ids: ids}, actor: admin)
      |> Ash.run_action()

    Map.new(orgs, fn org -> {org.id, org} end)
  end

  # -- display helpers ------------------------------------------------------

  # The :error arms are the vanished-org guard (the wallet FK has no
  # ON DELETE, so the org cannot be gone while the wallet stands) —
  # not simulatable without dropping the constraint.
  defp org_name(orgs, wallet) do
    case Map.fetch(orgs, wallet.organization_id) do
      {:ok, org} -> org.name
      # coveralls-ignore-next-line - unreachable while the FK stands
      :error -> nil
    end
  end

  defp org_slug(orgs, wallet) do
    case Map.fetch(orgs, wallet.organization_id) do
      {:ok, org} -> org.slug
      # coveralls-ignore-next-line - unreachable while the FK stands
      :error -> nil
    end
  end

  # The countdown presentation gates on the balance alone: the sweep
  # clears a recovered wallet's anchor hourly, and an armed-but-positive
  # row must not read as a countdown.
  defp negative?(wallet), do: wallet.balance < 0

  # Reached only under the negative_since guard in the template.
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
      <div class="appgram console contents" data-testid="admin-orgs">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">{gettext("Orgs and instances")}</h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext(
                  "Every org with a wallet, and its wallet state. Open an org for its instances."
                )}
              </p>
              <%!-- The page's ONE honesty statement: the wallet seam's
              scope, given weight (ink, medium) so it reads as a fact,
              not a footnote. --%>
              <p
                class="mt-2 max-w-prose text-sm font-medium text-ink"
                data-testid="admin-orgs-scope-copy"
              >
                {gettext(
                  "An org appears here once its wallet exists. Personal orgs get theirs at signup. Team orgs get theirs at the first billing touch."
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
            <AdminShell.sidebar current="orgs" pending_requests={@pending_storage_requests} />

            <div class="min-w-0 flex-1 space-y-6">
              <.card class="space-y-4" data-testid="admin-orgs-search-card">
                <div>
                  <h2 class="text-base font-medium text-ink">{gettext("Find an org")}</h2>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext(
                      "Search narrows this list by org name or slug. It never reaches past it."
                    )}
                  </p>
                </div>
                <.form
                  for={@search_form}
                  id="admin-orgs-search"
                  phx-change="search"
                  phx-submit="search"
                >
                  <.input
                    field={@search_form[:query]}
                    type="text"
                    label={gettext("Org name or slug")}
                    placeholder={gettext("Search by org name or slug")}
                    phx-debounce="200"
                    data-testid="admin-orgs-search-input"
                  />
                </.form>
              </.card>

              <div class="space-y-4" data-testid="admin-orgs-list">
                <%!-- The count is the @list_cap above (kept literal here —
                a module attribute reads as assigns inside HEEx); move the
                two together. --%>
                <p
                  :if={@rows_capped?}
                  class="text-sm text-ink-muted"
                  data-testid="admin-orgs-capped"
                >
                  {gettext("Showing the latest 100 orgs. Negative balances pin to the top.")}
                </p>

                <%!-- The empty states ride the moderation inset (the one
                grammar): a solid panel wrapping a borderless empty
                state, never a bare dashed box. --%>
                <div
                  :if={@rows_empty?}
                  class="rounded-panel border border-line bg-panel px-6 py-8"
                  data-testid="admin-orgs-empty"
                >
                  <.empty_state
                    :if={@query == ""}
                    title={gettext("No orgs yet.")}
                    class="border-none bg-transparent"
                  >
                    {gettext(
                      "An org appears here once its wallet exists. Personal orgs get theirs at signup."
                    )}
                  </.empty_state>

                  <.empty_state
                    :if={@query != ""}
                    title={gettext("No org with a wallet matches that search.")}
                    class="border-none bg-transparent"
                  />
                </div>

                <%!-- The md-band posture (the people surface's idiom):
                header and rows share one overflow-x-auto box, so a
                narrow band scrolls INTERNALLY, never the page. The
                floor on the inner box (the billing surface's shape) is
                the tracks' own sum: without it the fr tracks collapse
                to zero slivers before the scroll engages. At md+ the
                band is wider than the floor, so nothing scrolls and
                nothing collapses. --%>
                <div :if={not @rows_empty?} class="overflow-x-auto" data-noscroll>
                  <div class="min-w-[40rem]">
                    <%!-- One grid template shared by the header and every
                    row (kept literal in both spots), so the columns can
                    never drift. Gated behind rows-present: a dangling
                    header over an empty state promises columns nothing
                    is there to fill. --%>
                    <div
                      class={[
                        "grid-cols-[minmax(0,1.8fr)_6rem_8rem_6.5rem_minmax(0,6rem)]",
                        AdminComponents.admin_table_header_class()
                      ]}
                      data-testid="admin-orgs-table-header"
                    >
                      <div class="truncate">{gettext("Organization")}</div>
                      <div class="truncate text-right">{gettext("Balance")}</div>
                      <div class="truncate">{gettext("Balance state")}</div>
                      <div class="truncate">{gettext("Wallet since")}</div>
                      <div class="sr-only">{gettext("Actions")}</div>
                    </div>

                    <div id="admin-orgs-table" phx-update="stream">
                      <div
                        :for={{dom_id, wallet} <- @streams.wallets}
                        id={dom_id}
                        class={[
                          "grid-cols-[minmax(0,1.8fr)_6rem_8rem_6.5rem_minmax(0,6rem)]",
                          AdminComponents.admin_table_row_class(),
                          "border-b border-line last:border-0",
                          negative?(wallet) && "bg-danger-muted"
                        ]}
                      >
                        <div class="min-w-0" data-testid={"admin-orgs-org-#{wallet.id}"}>
                          <%!-- The org detail is the row's PRIMARY action
                        (the hero promises it): the amber link. The
                        wallet's is the secondary. --%>
                          <.link
                            :if={org_name(@orgs, wallet)}
                            navigate={~p"/admin/orgs/#{wallet.organization_id}"}
                            class="block truncate font-medium text-link underline-offset-2 hover:underline"
                            data-testid={"admin-orgs-org-link-#{wallet.id}"}
                          >
                            {org_name(@orgs, wallet)}
                          </.link>
                          <p class="truncate font-mono text-xs text-ink-muted">
                            {org_slug(@orgs, wallet)}
                          </p>
                        </div>
                        <div class="text-right">
                          <span
                            class={[
                              "whitespace-nowrap text-sm tabular-nums",
                              wallet.balance < 0 && "font-semibold text-danger"
                            ]}
                            data-testid={"admin-orgs-balance-#{wallet.id}"}
                          >
                            {BillingComponents.format_balance(wallet.balance)}
                          </span>
                        </div>
                        <%!-- The balance state at a glance: negative is the
                      destroy clock's countdown (the tint above carries
                      the weight, the badge names it and dates it),
                      zero blocks the funded gates. Positive is the
                      resting rung and takes no badge at all — the
                      plain state. The wallets section owns the
                      detail. --%>
                        <div>
                          <span
                            class="inline-flex flex-col gap-0.5"
                            data-testid={"admin-orgs-state-#{wallet.id}"}
                          >
                            <%!-- tone plus icon plus word — the state never
                          rides color alone --%>
                            <AdminComponents.wallet_state_badge
                              balance_cents={wallet.balance}
                              class="self-start"
                            />
                            <%!-- The whole clock object, the wallets
                          section's grammar: the anchor AND the
                          deadline, so the countdown reads as one. --%>
                            <span
                              :if={negative?(wallet) and wallet.negative_since}
                              class="flex flex-col text-xs text-ink-muted"
                            >
                              <span>
                                {gettext("since %{date}",
                                  date: stamp_text(wallet.negative_since)
                                )}
                              </span>
                              <span>
                                {gettext("deletes %{date}",
                                  date: AdminComponents.destroy_deadline_text(wallet.negative_since)
                                )}
                              </span>
                            </span>
                          </span>
                        </div>
                        <div>
                          <span
                            :if={wallet.created_at}
                            class="text-sm text-ink-muted"
                            data-testid={"admin-orgs-since-#{wallet.id}"}
                          >
                            {stamp_text(wallet.created_at)}
                          </span>
                        </div>
                        <div class="min-w-0">
                          <div class="flex items-center justify-end">
                            <.link
                              navigate={~p"/admin/billing/wallets/#{wallet.id}"}
                              data-testid={"admin-orgs-open-wallet-#{wallet.id}"}
                              class="truncate text-sm text-ink-muted underline-offset-2 hover:text-ink hover:underline"
                            >
                              {gettext("Open wallet")}
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
        </section>
      </div>
    </Layouts.app>
    """
  end
end
