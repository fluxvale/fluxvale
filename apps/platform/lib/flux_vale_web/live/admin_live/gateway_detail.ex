defmodule FluxValeWeb.AdminLive.GatewayDetail do
  @moduledoc """
  One gateway's oversight view (#501): the gateway's facts, its
  credential references rendered as NAMES, and the org's access domains
  with their verification states. Read-only by design — re-pasting a
  key, resuming, removing: all of it belongs to the org's own Access
  panel (ADR-0039), and this surface builds none of it.

  The read that lands here is members-only (`AccessGateway.get_by_id`
  under the relates_to_actor_via filter), so a rendered page PROVES the
  admin is inside the gateway's org: the org name rides the flagged
  `:admin_lookup` seam anyway (one idiom for every admin surface), and
  the domains ride the same member read the gateway did
  (`:list_for_org`). An id the policy does not admit answers `[]` —
  indistinguishable from no such row — so one honest arm covers both:
  a flash and the list. The page never guesses which one it was.

  The credential references are the surface's most important sentence:
  `credential_secret_ref` and `api_token_secret_ref` name entries in
  the platform's secret store (ADR-0039 §4, ADR-0040 §5). They render
  as the identifiers they are, under copy that says the keys never
  enter this app's database and never pass through this console. The
  auth key an owner pasted appears NOWHERE on this page.

  Known limitation, stated: this view is org-scoped THROUGH the
  gateway, so it shows domains only while the gateway row stands.
  `MintDefaultHostname` mints a domain row for every instance create,
  so orgs that never enabled private access — and orgs past teardown —
  hold domains this page cannot show (no gateway row to mount). The
  read arm that would lift this is the policy escalation (#613), not
  this surface's to build.

  The domains list is paginated by the shared data table (the
  latest-100 cap retired; offset mode) — the pledged #608 finding's
  missing floor and scroll wrapper retire with it, since the
  component owns both for every adopting table.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Pricing
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.AdminShell
  alias FluxValeWeb.Components.AdminDataTable

  # The domains table's contract (#501): the sortable fields are the
  # columns the row prints that the domain read carries. Offset mode
  # (no keyset action on this read).
  @sortable [:domain, :kind, :state, :registered_at]
  @sizes AdminDataTable.default_sizes()

  @impl Phoenix.LiveView
  def mount(%{"id" => raw_id}, _session, socket) do
    admin = socket.assigns.current_user

    with {:ok, id} <- cast_uuid(raw_id),
         [gateway] <- gateway_read(admin, id),
         {:ok, [org]} <- org_lookup(admin, gateway.organization_id) do
      {:ok, assign(socket, gateway: gateway, org: org)}
    else
      # Each arm carries its own honest answer, folded nowhere.
      #
      # A malformed param is a TYPO, not an authorization outcome: the
      # plain answer, the orgs sibling's copy.
      :error ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That gateway does not exist."))
         |> push_navigate(to: ~p"/admin/gateways")}

      # The blanket authority (#644/#648) makes the admin read
      # filter-less cross-org: an empty answer IS "no such row" — the
      # same plain sentence as the typo arm, no scope verdict left to
      # guess (#613's resolution).
      [] ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That gateway does not exist."))
         |> push_navigate(to: ~p"/admin/gateways")}

      # The lookup's error class is DB-down, not a policy answer — its
      # own arm. (An org_lookup [] cannot happen while the FK stands,
      # so that shape rides here too.)
      # coveralls-ignore-start - not simulatable under the sandbox
      _lookup_failed ->
        {:ok,
         socket
         |> put_flash(:error, gettext("The gateway's org did not load. Try again."))
         |> push_navigate(to: ~p"/admin/gateways")}

        # coveralls-ignore-stop
    end
  end

  # The domains table's view state: sort, page, and size ride query
  # params (no search on this read), parsed with garbage-proof
  # fallbacks.
  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    state = AdminDataTable.parse_params(params, sortable: @sortable)

    {:noreply,
     socket
     |> assign(table: state, columns: columns())
     |> refresh_domains()}
  end

  # -- events ---------------------------------------------------------------

  # The header sort: whitelisted fields only, click-to-toggle.
  @impl Phoenix.LiveView
  def handle_event("sort", %{"field" => raw_field}, socket) do
    sort = AdminDataTable.toggle_sort(socket.assigns.table.sort, raw_field, @sortable)
    # A crafted field leaves the sort as it was: a true no-op, no
    # page reset, no patch.
    if sort == socket.assigns.table.sort do
      {:noreply, socket}
    else
      push_view(socket, %{socket.assigns.table | sort: sort, page: 1})
    end
  end

  # A crafted field is not a crash: the sort stays as it was.
  def handle_event("sort", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("page", %{"nav" => "prev"}, socket) do
    state = %{socket.assigns.table | page: socket.assigns.table.page - 1}

    push_view(socket, state)
  end

  def handle_event("page", %{"nav" => "next"}, socket) do
    state = %{socket.assigns.table | page: socket.assigns.table.page + 1}

    push_view(socket, state)
  end

  # A crafted page event is a no-op.
  def handle_event("page", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("size", %{"size" => raw}, socket) do
    size = AdminDataTable.parse_size(raw)
    state = %{socket.assigns.table | size: size, page: 1}

    push_view(socket, state)
  end

  def handle_event("size", _params, socket), do: {:noreply, socket}

  # Every table event is a patch: the URL states the view, and
  # handle_params owns the re-query. replace keeps the browser
  # history clean — a table view is a state, not a navigation.
  defp push_view(socket, state) do
    {:noreply,
     push_patch(socket,
       to: AdminDataTable.url_for(~p"/admin/gateways/#{socket.assigns.gateway.id}", state),
       replace: true
     )}
  end

  # A route param is an untyped string: cast before it becomes an
  # argument, so garbage ids take the missing arm instead of raising at
  # the action boundary.
  defp cast_uuid(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  # The get_by_id read is members-only: `[]` covers a bad id and an id
  # this admin may not see, and the page answers them identically (the
  # filter-vs-forbid posture — no Forbidden to distinguish, so no
  # guessing).
  defp gateway_read(admin, id) do
    AccessGateway
    |> Ash.Query.for_read(:get_by_id, %{id: id}, actor: admin)
    |> Ash.read!()
  end

  # The flagged seam (#501): one id in, the switcher's public fields
  # out. An unknown org answers an empty list — the with's match arm.
  defp org_lookup(admin, org_id) do
    Organization
    |> Ash.ActionInput.for_action(:admin_lookup, %{ids: [org_id]}, actor: admin)
    |> Ash.run_action()
  end

  # The org's domains — the same member read the gateway ride proved.
  # A rendered gateway page means the admin is inside this org, so no
  # second probe is needed. The page rides the shared data table: an
  # honest count, then one server-driven page (offset mode). No error
  # arm: Ash.read! raises the DB-down class, and a caught-and-reflashed
  # variant of that would be scope creep on a read that cannot fail
  # for policy reasons.
  defp refresh_domains(socket) do
    admin = socket.assigns.current_user
    state = socket.assigns.table

    filtered =
      Ash.Query.for_read(
        AccessDomain,
        :list_for_org,
        %{organization_id: socket.assigns.org.id},
        actor: admin
      )

    total = Ash.count!(filtered)
    page_count = AdminDataTable.page_count(total, state.size)

    # A crafted deep link clamps BEFORE the query is built: the page
    # read runs at the honest offset, never a crafted deep scan.
    page = min(state.page, page_count)

    domains =
      filtered
      |> apply_sort(state.sort)
      |> Ash.Query.limit(state.size)
      |> Ash.Query.offset((page - 1) * state.size)
      |> Ash.read!()

    updated = %{state | page: page, total: total}

    socket
    |> assign(table: updated, domains_empty?: domains == [])
    |> stream(:domains, domains, reset: true)
  end

  # Newest registered first by default; the id tiebreak rides every
  # sort so a same-second page boundary cannot shuffle rows between
  # reads.
  defp apply_sort(query, nil), do: Ash.Query.sort(query, registered_at: :desc, id: :desc)

  # Whitelisted atoms only — the param path never builds a sort term.
  defp apply_sort(query, {field, dir}) do
    Ash.Query.sort(query, [{field, dir}, {:id, :desc}])
  end

  # -- display helpers ------------------------------------------------------

  # The domain kinds: the platform row is system-minted (the instance
  # create path, ADR-0040), the custom row is the owner's registration.
  defp kind_label(:platform), do: gettext("Platform")
  defp kind_label(:custom), do: gettext("Custom")

  # The row's tailnet claim state (#648's operator-truth column): the
  # gateway's `dns_claims` map keys are the claimed domains, written
  # only through the claim/unclaim funnels. Distinct from the state
  # badge's cert issuance — either can move without the other.
  defp claimed?(gateway, domain),
    do: Map.has_key?(gateway.dns_claims || %{}, domain.domain)

  defp provider_label(:tailscale), do: gettext("Tailscale")

  # Reached only under the stamp guards in the template.
  defp stamp_text(stamp), do: Calendar.strftime(stamp, "%b %d, %Y")

  # The column declarations, built per render so the labels ride the
  # live locale. Tracks and floors are the shared component's data:
  # the pledged #608 finding was this table missing a floor and a
  # scroll wrapper entirely — the component now owns both.
  defp columns do
    [
      %{
        key: :domain,
        label: gettext("Domain"),
        track: "minmax(0,1.6fr)",
        sort: :domain,
        floor_rem: 8
      },
      %{key: :kind, label: gettext("Kind"), track: "6.5rem", sort: :kind},
      %{key: :state, label: gettext("State"), track: "10rem", sort: :state},
      %{
        key: :registered,
        label: gettext("Registered"),
        track: "6.5rem",
        sort: :registered_at
      }
    ]
  end

  # The view state the component renders: the parsed params plus the
  # honest count and the surface's event names.
  defp table_meta(state) do
    %{
      query: state.query,
      page: state.page,
      size: state.size,
      sort: state.sort,
      total: state.total,
      sizes: @sizes,
      sort_event: "sort",
      page_event: "page",
      size_event: "size"
    }
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
      wide
    >
      <div class="appgram console contents" data-testid="admin-gateways-detail">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5 font-mono">{@gateway.hostname}</h1>
              <p class="mt-1 text-base text-ink-muted">
                {gettext("Gateway of %{org}", org: @org.name)}
              </p>
              <p class="mt-0.5 font-mono text-sm text-ink-subtle">{@org.slug}</p>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext(
                  "The gateway's facts, its credential references, and this org's domains. Everything here is read-only: the org's Access panel owns the writes."
                )}
              </p>
              <div class="mt-4">
                <.link
                  navigate={~p"/admin/gateways"}
                  data-testid="admin-gateways-back-link"
                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                >
                  {gettext("Back to gateways")}
                </.link>
              </div>
            </div>
          </div>
        </section>

        <section class="wrap pt-2 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <%!-- The section entry is an ANCESTOR mark (exact: false):
            this page is the gateways section's sub-route. --%>
            <AdminShell.sidebar
              current="gateways"
              exact={false}
              pending_requests={@pending_storage_requests}
            />

            <div class="min-w-0 flex-1 space-y-8">
              <%!-- The gateway's facts: the state (the product's own
              badge vocabulary, the section's shape-cued badge), the
              row's message ONLY for the informative states (a bare
              "Connected" under a Connected pill is a stray echo —
              needs_attention and suspended are where the row's words
              carry), the identifier grammar, the rate snapshot. --%>
              <.card class="space-y-4" data-testid="admin-gateways-facts-card">
                <div class="flex items-center gap-2">
                  <h2 class="text-base font-medium text-ink">{gettext("Gateway")}</h2>
                  <span data-testid="admin-gateways-detail-state">
                    <AdminComponents.gateway_state_badge state={@gateway.state} />
                  </span>
                </div>

                <p
                  :if={
                    @gateway.status_message != nil and
                      @gateway.state in [:needs_attention, :suspended]
                  }
                  class="text-sm text-ink-muted"
                  data-testid="admin-gateways-detail-status-message"
                >
                  {@gateway.status_message}
                </p>

                <div class="grid gap-1.5" data-testid="admin-gateways-detail-facts">
                  <p class="flex gap-4 text-sm">
                    <span class="w-32 shrink-0 text-ink-muted">{gettext("Hostname")}</span>
                    <span
                      class="min-w-0 font-mono text-ink [overflow-wrap:anywhere]"
                      data-testid="admin-gateways-detail-hostname"
                    >
                      {@gateway.hostname}
                    </span>
                  </p>
                  <p class="flex gap-4 text-sm">
                    <span class="w-32 shrink-0 text-ink-muted">{gettext("Tailnet domain")}</span>
                    <span
                      class="min-w-0 font-mono text-ink [overflow-wrap:anywhere]"
                      data-testid="admin-gateways-detail-tailnet"
                    >
                      {@gateway.tailnet_domain}
                    </span>
                  </p>
                  <p class="flex gap-4 text-sm">
                    <span class="w-32 shrink-0 text-ink-muted">{gettext("Provider")}</span>
                    <span data-testid="admin-gateways-detail-provider">
                      {provider_label(@gateway.provider)}
                    </span>
                  </p>
                  <p class="flex gap-4 text-sm">
                    <span class="w-32 shrink-0 text-ink-muted">{gettext("Rate")}</span>
                    <span
                      class="min-w-0 text-ink"
                      data-testid="admin-gateways-detail-rate"
                    >
                      {Pricing.format_usd(@gateway.monthly_cents)}
                      {gettext(
                        "per month, billed while connected. Suspended or removed, nothing accrues."
                      )}
                    </span>
                  </p>
                  <p
                    :if={@gateway.provisioned_at}
                    class="flex gap-4 text-sm"
                    data-testid="admin-gateways-detail-provisioned"
                  >
                    <span class="w-32 shrink-0 text-ink-muted">{gettext("Provisioned")}</span>
                    <span class="text-ink-muted">{stamp_text(@gateway.provisioned_at)}</span>
                  </p>
                  <%!-- The attention clock (#648's operator-truth
                  column, the wallets surface's since-date signal).
                  Guarded on the STATE like the list's pin — Suspend
                  never clears the stamp, so an unguarded render would
                  show a clock under a suspended row. --%>
                  <p
                    :if={@gateway.state == :needs_attention and @gateway.needs_attention_since}
                    class="flex gap-4 text-sm"
                    data-testid="admin-gateways-detail-attention-since"
                  >
                    <span class="w-32 shrink-0 text-ink-muted">
                      {gettext("Attention since")}
                    </span>
                    <span class="text-ink-muted">
                      {stamp_text(@gateway.needs_attention_since)}
                    </span>
                  </p>
                  <p
                    :if={@gateway.created_at}
                    class="flex gap-4 text-sm"
                    data-testid="admin-gateways-detail-created"
                  >
                    <span class="w-32 shrink-0 text-ink-muted">{gettext("Created")}</span>
                    <span class="text-ink-muted">{stamp_text(@gateway.created_at)}</span>
                  </p>
                </div>
              </.card>

              <%!-- THE secret-reference card: the names are honest
              identifiers, the copy is the surface's most important
              sentence. The auth key an owner pasted appears nowhere on
              this page — the card shows the store entry's NAME and
              says what it is. --%>
              <.card class="space-y-4" data-testid="admin-gateways-secret-card">
                <div>
                  <h2 class="text-base font-medium text-ink">{gettext("Credential references")}</h2>
                  <p class="mt-1 max-w-prose text-sm text-ink-muted">
                    {gettext(
                      "A gateway's keys live in the platform's secret store, outside this app. The names below point at the store entries that hold them."
                    )}
                  </p>
                  <%!-- THE trust line: real separation, fact weight — the
                  page's one honesty statement (the list band's
                  member-scope line is its sibling). --%>
                  <p class="mt-3 max-w-prose text-sm font-medium text-ink">
                    {gettext(
                      "The keys themselves are never stored in the app database and never pass through this console. This page can show a name, never a key."
                    )}
                  </p>
                </div>

                <dl class="grid gap-2" data-testid="admin-gateways-secret-refs">
                  <div class="flex flex-wrap gap-x-4 gap-y-1 text-sm">
                    <dt class="w-32 shrink-0 text-ink-muted">{gettext("Auth key entry")}</dt>
                    <dd
                      class="min-w-0 font-mono text-ink [overflow-wrap:anywhere]"
                      data-testid="admin-gateways-secret-credential-ref"
                    >
                      {@gateway.credential_secret_ref || gettext("Not recorded.")}
                    </dd>
                  </div>
                  <div class="flex flex-wrap gap-x-4 gap-y-1 text-sm">
                    <dt class="w-32 shrink-0 text-ink-muted">{gettext("API token entry")}</dt>
                    <%= if @gateway.api_token_secret_ref do %>
                      <dd
                        class="min-w-0 font-mono text-ink [overflow-wrap:anywhere]"
                        data-testid="admin-gateways-secret-token-ref"
                      >
                        {@gateway.api_token_secret_ref}
                      </dd>
                    <% else %>
                      <%!-- What the card CAN say about a nil ref is only
                      that nothing is recorded: the claim path reads the
                      Secret by its derived name, so a usable Secret can
                      exist without a ref on the row — an inference
                      about claims would cross facts. --%>
                      <dd
                        class="min-w-0 text-ink-muted"
                        data-testid="admin-gateways-secret-token-none"
                      >
                        {gettext("Not recorded.")}
                      </dd>
                    <% end %>
                  </div>
                </dl>
                <%!-- The key-age signal (#648's operator-truth column):
                the ref write stamps token_set_at (its change,
                ADR-0040 §5) — the only writer, so the page reads the
                funnel's own fact. Absent when no ref write ever
                stamped it. --%>
                <p
                  :if={@gateway.token_set_at}
                  class="text-sm text-ink-muted"
                  data-testid="admin-gateways-secret-token-set"
                >
                  {gettext(
                    "Token set %{stamp}. Tailscale API keys expire within 90 days by design. Age this one toward rotation.",
                    stamp: stamp_text(@gateway.token_set_at)
                  )}
                </p>
              </.card>

              <%!-- The org's domains: the data model ties a domain to
              the ORG, not to the gateway, and the gateway is one per
              org — so the domains live on this page rather than in a
              separate cross-org list the member-only read could not
              fill. --%>
              <div class="space-y-4" data-testid="admin-gateways-detail-domains">
                <div>
                  <h2 class="text-base font-medium text-ink">{gettext("Domains")}</h2>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext(
                      "The names this org serves its private instances under. Registration lives on the org's own surfaces."
                    )}
                  </p>
                </div>

                <%!-- The empty and the table ride the lane's panel-inset
                shape and the disclosed gutter, same as the list. --%>
                <div
                  :if={@domains_empty?}
                  class="rounded-panel border border-line bg-panel px-4 py-3"
                  data-testid="admin-gateways-domains-empty"
                >
                  <p class="text-sm font-medium text-ink">
                    {gettext("No domains registered for this org yet.")}
                  </p>
                </div>

                <%!-- The domains data table (#501): the shared component
                owns the chrome, the computed floor, the sort headers,
                and the pagination — the pledged #608 finding (this
                table had neither floor nor scroll wrapper) dies here. --%>
                <div :if={not @domains_empty?}>
                  <AdminDataTable.data_table
                    id="admin-gateways-domains-table"
                    items={@streams.domains}
                    columns={@columns}
                    meta={table_meta(@table)}
                  >
                    <:cell :let={domain} col={:domain}>
                      <p
                        class="truncate font-mono text-sm text-ink"
                        data-testid={"admin-gateways-domain-name-#{domain.id}"}
                      >
                        {domain.domain}
                      </p>
                      <%!-- The claim state (#648's operator-truth
                      column): claimed on the tailnet or not — the
                      state badge cannot carry it (issuance and
                      resolution are separate truths). The map keys are
                      the claimed domains. Both states render: the
                      unclaimed line is the operator's "check the
                      funnel" cue, not an absence. --%>
                      <p
                        :if={claimed?(@gateway, domain)}
                        class="truncate text-xs text-ink-muted"
                        data-testid={"admin-gateways-domain-claim-#{domain.id}"}
                      >
                        {gettext("Claimed on the tailnet")}
                      </p>
                      <p
                        :if={not claimed?(@gateway, domain)}
                        class="truncate text-xs text-ink-subtle"
                        data-testid={"admin-gateways-domain-unclaimed-#{domain.id}"}
                      >
                        {gettext("Not on the tailnet")}
                      </p>
                    </:cell>

                    <:cell :let={domain} col={:kind}>
                      <span
                        class="text-sm text-ink-muted"
                        data-testid={"admin-gateways-domain-kind-#{domain.id}"}
                      >
                        {kind_label(domain.kind)}
                      </span>
                    </:cell>

                    <:cell :let={domain} col={:state}>
                      <span data-testid={"admin-gateways-domain-state-#{domain.id}"}>
                        <%!-- The house badge size, no overrides — these
                        pills carry Failed and must not read
                        dinkier than their neighbors (the review's
                        scale note). --%>
                        <AdminComponents.domain_state_badge state={domain.state} />
                      </span>
                    </:cell>

                    <:cell :let={domain} col={:registered}>
                      <span
                        :if={domain.registered_at}
                        class="text-sm text-ink-muted"
                        data-testid={"admin-gateways-domain-registered-#{domain.id}"}
                      >
                        {stamp_text(domain.registered_at)}
                      </span>
                    </:cell>
                  </AdminDataTable.data_table>
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
