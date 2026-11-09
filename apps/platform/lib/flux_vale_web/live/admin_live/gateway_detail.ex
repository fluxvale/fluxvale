defmodule FluxValeWeb.AdminLive.GatewayDetail do
  @moduledoc """
  One gateway's oversight view (#501): the gateway's facts, its
  credential references rendered as NAMES, and the org's access domains
  with their verification states. Read-only by design — re-pasting a
  key, resuming, removing: all of it belongs to the org's own Access
  panel (ADR-0039), and this surface builds none of it.

  The read that lands here rides the blanket platform-admin authority
  (#644, ADR-0047): a member still sees only their org's gateway, while
  a session platform admin — the only actor this route admits — reads
  ANY org's row, with the operator-truth fields the member-scoped
  posture dropped: the attention clock in the facts, the key age
  beside the API token entry, and each domain's tailnet claim in the
  domains table (claim state is tailnet resolution — a distinct fact
  from the verified badge's cert issuance). The org name rides the
  flagged `:admin_lookup` seam (one idiom for every admin surface), and
  the domains ride `:list_for_org` — the same read, cross-org for the
  admin under the blanket. An id the read does not admit is one the
  row does not have: `[]` means no such gateway, and the page says
  exactly that.

  The credential references are the surface's most important sentence:
  `credential_secret_ref` and `api_token_secret_ref` name entries in
  the platform's secret store (ADR-0039 §4, ADR-0040 §5). They render
  as the identifiers they are, under copy that says the keys never
  enter this app's database and never pass through this console. The
  auth key an owner pasted appears NOWHERE on this page.

  Known limitation, resolved where it lives: this view reaches the
  org's domains THROUGH the gateway, so it shows them only while the
  gateway row stands. `MintDefaultHostname` mints a domain row for
  every instance create, so orgs that never enabled private access —
  and orgs past teardown — hold domains this page cannot show (no
  gateway row to mount). The org detail's domains card (this slice,
  #613's second half) answers for those orgs: the same `:list_for_org`
  read, mounted from the org instead of the gateway.

  The domains list caps at the latest 100 (the lane's cap rationale).
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Pricing
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.AdminShell

  # The domains list cap (the moduledoc names it; move the two
  # together): one org's domains are few by design (one platform row,
  # a handful of custom ones), and the cap keeps a pathological row
  # count from rendering an unbounded page. Revisit trigger: pagination
  # once a single org approaches the cap.
  @list_cap 100

  @impl Phoenix.LiveView
  def mount(%{"id" => raw_id}, _session, socket) do
    admin = socket.assigns.current_user

    with {:ok, id} <- cast_uuid(raw_id),
         [gateway] <- gateway_read(admin, id),
         {:ok, [org]} <- org_lookup(admin, gateway.organization_id) do
      {domains, capped?} = domains_page(admin, gateway.organization_id)

      {:ok,
       socket
       |> assign(
         gateway: gateway,
         org: org,
         domains_capped?: capped?,
         domains_empty?: domains == []
       )
       |> stream(:domains, domains)}
    else
      # Each arm carries its own honest answer, folded nowhere.
      #
      # With the platform-admin read (#613) the filter-less arm means
      # an empty answer can only be "no such row" — a malformed param
      # (a TYPO) and an unknown id get the SAME plain answer, the orgs
      # sibling's copy: there is no member-scope verdict left to guess.
      miss when miss in [:error, []] ->
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

  # A route param is an untyped string: cast before it becomes an
  # argument, so garbage ids take the missing arm instead of raising at
  # the action boundary.
  defp cast_uuid(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  # The get_by_id read carries the platform-admin arm (#613): for this
  # surface's only admitted actor it is filter-less, so `[]` means no
  # such row — the missing arm above.
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

  # The org's domains — `:list_for_org`, the same read action the
  # gateway rode, its policy now admitting the admin cross-org (#613):
  # the gateway read that mounted this page already proved access.
  # Capped one past the cap so the overflow question answers without a
  # count. No error arm: Ash.read! raises the DB-down class, and a
  # caught-and-reflashed variant of that would be scope creep on a
  # read that cannot fail for policy reasons.
  defp domains_page(admin, org_id) do
    fetched =
      AccessDomain
      |> Ash.Query.for_read(:list_for_org, %{organization_id: org_id}, actor: admin)
      |> Ash.Query.sort(registered_at: :desc, id: :desc)
      |> Ash.Query.limit(@list_cap + 1)
      |> Ash.read!()

    capped? = length(fetched) > @list_cap
    {Enum.take(fetched, @list_cap), capped?}
  end

  # -- display helpers ------------------------------------------------------

  # The domain kinds: the platform row is system-minted (the instance
  # create path, ADR-0040), the custom row is the owner's registration.
  defp kind_label(:platform), do: gettext("Platform")
  defp kind_label(:custom), do: gettext("Custom")

  defp provider_label(:tailscale), do: gettext("Tailscale")

  # The row's tailnet claim state (#613's operator-truth column): the
  # gateway's `dns_claims` map keys are the claimed domains, written
  # only through the claim/unclaim funnels. Distinct from the state
  # badge — cert issuance is not tailnet resolution, and either can
  # move without the other.
  defp claimed?(gateway, domain),
    do: Map.has_key?(gateway.dns_claims || %{}, domain.domain)

  # Reached only under the stamp guards in the template.
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
                  <%!-- The attention clock (#613's operator-truth
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

                <%!-- The key-age signal (#613's operator-truth column,
                ADR-0040 §5): Tailscale API keys expire within 90 days
                by design, so when the token was last set is the
                rotation clock. Rides the token entry it belongs to;
                absent when no ref write ever stamped it. --%>
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
              org — so the domains live on this page. The claim line
              under each name is the tailnet-resolution fact (#613's
              operator-truth column): the gateway's claims map, not the
              state badge — cert issuance and tailnet resolution are
              separate truths. --%>
              <div class="space-y-4" data-testid="admin-gateways-detail-domains">
                <div>
                  <h2 class="text-base font-medium text-ink">{gettext("Domains")}</h2>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext(
                      "The names this org serves its private instances under. Registration lives on the org's own surfaces."
                    )}
                  </p>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext(
                      "The state badge is certificate issuance. The claim line is tailnet resolution. Either can move without the other."
                    )}
                  </p>
                </div>

                <p
                  :if={@domains_capped?}
                  class="text-sm text-ink-muted"
                  data-testid="admin-gateways-domains-capped"
                >
                  {gettext("Showing the latest 100 domains.")}
                </p>

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

                <div :if={not @domains_empty?} class="space-y-3">
                  <%!-- One grid template shared by the header and every
                  row (kept literal in both spots), so the columns can
                  never drift. --%>
                  <div class="grid grid-cols-[minmax(0,1.6fr)_6.5rem_10rem_6.5rem] items-center gap-x-3 border-b border-line px-3 py-3 text-left text-xs font-medium tracking-wide text-ink-muted uppercase">
                    <div>{gettext("Domain")}</div>
                    <div>{gettext("Kind")}</div>
                    <div>{gettext("State")}</div>
                    <div>{gettext("Registered")}</div>
                  </div>

                  <div>
                    <div id="admin-gateways-domains-table" phx-update="stream">
                      <div
                        :for={{dom_id, domain} <- @streams.domains}
                        id={dom_id}
                        class="grid grid-cols-[minmax(0,1.6fr)_6.5rem_10rem_6.5rem] items-center gap-x-3 border-b border-line px-3 py-3 transition-colors last:border-0 hover:bg-panel-raised/60"
                      >
                        <div class="min-w-0">
                          <p
                            class="truncate font-mono text-sm text-ink"
                            data-testid={"admin-gateways-domain-name-#{domain.id}"}
                          >
                            {domain.domain}
                          </p>
                          <%!-- The claim state: claimed on the tailnet or
                          not — the operator-truth column the state
                          badge cannot carry (issuance ≠ resolution).
                          The map keys are the claimed domains. --%>
                          <p
                            :if={claimed?(@gateway, domain)}
                            class="truncate text-xs text-ink-muted"
                            data-testid={"admin-gateways-domain-claim-#{domain.id}"}
                          >
                            {gettext("Claimed on the tailnet")}
                          </p>
                          <p
                            :if={not claimed?(@gateway, domain)}
                            class="truncate text-xs text-ink-muted"
                            data-testid={"admin-gateways-domain-unclaimed-#{domain.id}"}
                          >
                            {gettext("Not on the tailnet")}
                          </p>
                        </div>
                        <div>
                          <span
                            class="text-sm text-ink-muted"
                            data-testid={"admin-gateways-domain-kind-#{domain.id}"}
                          >
                            {kind_label(domain.kind)}
                          </span>
                        </div>
                        <div>
                          <span data-testid={"admin-gateways-domain-state-#{domain.id}"}>
                            <%!-- The house badge size, no overrides — these
                            pills carry Failed and must not read
                            dinkier than their neighbors (the review's
                            scale note). --%>
                            <AdminComponents.domain_state_badge state={domain.state} />
                          </span>
                        </div>
                        <div>
                          <span
                            :if={domain.registered_at}
                            class="text-sm text-ink-muted"
                            data-testid={"admin-gateways-domain-registered-#{domain.id}"}
                          >
                            {stamp_text(domain.registered_at)}
                          </span>
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
