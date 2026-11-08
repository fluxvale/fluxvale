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

  The domains list caps at the latest 100 (the lane's cap rationale).
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Pricing
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

    # Ash.read! answers a bare list: [] covers a bad id, a malformed
    # param, and an id the members-only read does not admit — one arm,
    # one answer, the flash saying what the list can see.
    with {:ok, id} <- cast_uuid(raw_id),
         [gateway] <- gateway_read(admin, id),
         {:ok, [org]} <- org_lookup(admin, gateway.organization_id) do
      {domains_state, domains, capped?} = domains_page(admin, gateway.organization_id)

      {:ok,
       socket
       |> assign(
         gateway: gateway,
         org: org,
         domains_state: domains_state,
         domains_capped?: capped?,
         domains_empty?: domains == []
       )
       |> stream(:domains, domains)}
    else
      _missing ->
        {:ok,
         socket
         |> put_flash(
           :error,
           gettext("That gateway is not listed. Gateway reads are member-scoped.")
         )
         |> push_navigate(to: ~p"/admin/gateways")}
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
  # second probe is needed. Capped one past the cap so the overflow
  # question answers without a count.
  defp domains_page(admin, org_id) do
    fetched =
      AccessDomain
      |> Ash.Query.for_read(:list_for_org, %{organization_id: org_id}, actor: admin)
      |> Ash.Query.sort(registered_at: :desc, id: :desc)
      |> Ash.Query.limit(@list_cap + 1)
      |> Ash.read!()

    capped? = length(fetched) > @list_cap
    {:ok, Enum.take(fetched, @list_cap), capped?}
  end

  # -- display helpers ------------------------------------------------------

  # The domain kinds: the platform row is system-minted (the instance
  # create path, ADR-0040), the custom row is the owner's registration.
  defp kind_label(:platform), do: gettext("Platform")
  defp kind_label(:custom), do: gettext("Custom")

  # The domain states' badge grammar (tone + cue + word, no two states
  # ever share both tone and shape — the people surface's discipline).
  # The shared `status_badge` cannot serve here: its label map has no
  # :verified/:failed arms (they are not instance states), so the
  # vocabulary lives on this surface, from birth, in gettext.
  defp domain_state_tone(:pending), do: "primary"
  defp domain_state_tone(:verified), do: "success"
  defp domain_state_tone(:needs_attention), do: "warning"
  defp domain_state_tone(:failed), do: "danger"
  defp domain_state_tone(:suspended), do: "neutral"

  defp domain_state_cue(:pending), do: {:dot, :pulse}
  defp domain_state_cue(:verified), do: {:icon, "hero-check-circle"}
  defp domain_state_cue(:needs_attention), do: {:icon, "hero-exclamation-triangle"}
  defp domain_state_cue(:failed), do: {:icon, "hero-x-mark"}
  defp domain_state_cue(:suspended), do: {:icon, "hero-pause"}

  defp domain_state_label(:pending), do: gettext("Pending")
  defp domain_state_label(:verified), do: gettext("Verified")
  defp domain_state_label(:needs_attention), do: gettext("Needs attention")
  defp domain_state_label(:failed), do: gettext("Failed")
  defp domain_state_label(:suspended), do: gettext("Suspended")

  defp provider_label(:tailscale), do: gettext("Tailscale")

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
                <span class="font-mono text-sm">{@org.slug}</span>
              </p>
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
            <AdminShell.sidebar current="gateways" exact={false} />

            <div class="min-w-0 flex-1 space-y-8">
              <%!-- The gateway's facts: the state (the product's own
              badge vocabulary), the friendly status copy, the
              identifier grammar (hostname + tailnet domain), the rate
              snapshot. --%>
              <.card class="space-y-4" data-testid="admin-gateways-facts-card">
                <div class="flex items-center gap-2">
                  <h2 class="text-base font-medium text-ink">{gettext("Gateway")}</h2>
                  <span data-testid="admin-gateways-detail-state">
                    <.status_badge status={@gateway.state} />
                  </span>
                </div>

                <p
                  :if={@gateway.status_message}
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
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext(
                      "A gateway's keys live in the platform's secret store, outside this app. The names below point at the store entries that hold them."
                    )}
                  </p>
                  <p class="mt-1 text-sm font-medium text-ink">
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
                      {@gateway.credential_secret_ref || gettext("Not recorded")}
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
                      <dd
                        class="min-w-0 text-ink-muted"
                        data-testid="admin-gateways-secret-token-none"
                      >
                        {gettext("None. This gateway has not claimed any tailnet domains.")}
                      </dd>
                    <% end %>
                  </div>
                </dl>
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

                <p
                  :if={@domains_capped?}
                  class="text-sm text-ink-muted"
                  data-testid="admin-gateways-domains-capped"
                >
                  {gettext("Showing the latest 100 domains.")}
                </p>

                <.empty_state
                  :if={@domains_state == :ok and @domains_empty?}
                  title={gettext("No domains registered for this org yet.")}
                />

                <div :if={@domains_state == :ok and not @domains_empty?} class="space-y-3">
                  <%!-- One grid template shared by the header and every
                  row (kept literal in both spots), so the columns can
                  never drift. --%>
                  <div class="grid grid-cols-[minmax(0,1.6fr)_6.5rem_9.5rem_6.5rem] items-center gap-x-1.5 border-b border-line px-3 py-3 text-left text-xs font-medium tracking-wide text-ink-muted uppercase">
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
                        class="grid grid-cols-[minmax(0,1.6fr)_6.5rem_9.5rem_6.5rem] items-center gap-x-1.5 border-b border-line px-3 py-3 transition-colors last:border-0 hover:bg-panel-raised/60"
                      >
                        <div class="min-w-0">
                          <p
                            class="truncate font-mono text-sm text-ink"
                            data-testid={"admin-gateways-domain-name-#{domain.id}"}
                          >
                            {domain.domain}
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
                            <.badge
                              tone={domain_state_tone(domain.state)}
                              class="px-1.5! text-[11px]!"
                            >
                              <%= case domain_state_cue(domain.state) do %>
                                <% {:dot, :pulse} -> %>
                                  <span class="size-1.5 rounded-full bg-current motion-safe:animate-pulse" />
                                <% {:icon, name} -> %>
                                  <.icon name={name} class="size-3.5" />
                              <% end %>
                              {domain_state_label(domain.state)}
                            </.badge>
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
