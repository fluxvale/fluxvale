defmodule FluxValeWeb.AdminLive.OrgDetail do
  @moduledoc """
  One org's operator view (#501): the wallet state and the org's
  instances, each rendered exactly as far as its read policy admits.

  Read-only by design (the v1 plan reserved this section's writes).
  The org identity rides the flagged `:admin_lookup` seam (three
  public fields — the wallets lane's read), the wallet rides the read
  policy's platform-admin arm, and the instances ride
  `:list_for_organization` behind a membership probe: the read
  policies are members-only filters, so the probe (a Membership read
  with the actor attached) is what lets the page tell "nothing
  deployed" apart from "not yours to see". A non-member admin gets the
  honest scope note where the instance table would be — the page
  states what it can see, never silently less.

  The instances list caps at the latest 100 (the lane's cap rationale,
  the orgs surface's trigger). No writes anywhere on the surface.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.Wallet
  alias FluxVale.Infrastructure.Instance
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.AdminShell
  alias FluxValeWeb.BillingComponents

  require Ash.Query
  require Ash.Expr

  # The instances list cap (the moduledoc names it; move the two
  # together): the same rationale as the orgs surface's cap. Revisit
  # trigger: pagination once a single org approaches the cap.
  @list_cap 100

  @impl Phoenix.LiveView
  def mount(%{"id" => raw_id}, _session, socket) do
    admin = socket.assigns.current_user

    with {:ok, org_id} <- cast_uuid(raw_id),
         {:ok, [org]} <- org_lookup(admin, org_id) do
      wallet = wallet_read(admin, org_id)
      {instances_state, instances, capped?} = instances_page(admin, org_id)

      # Live truth (the dashboard's posture, #74): every status-writing
      # action broadcasts on instances:<id>, and the strip and rows
      # follow the broadcasts instead of aging into a lie. A stream is
      # not enumerable, so the counts ride an id → status index of the
      # SHOWN page (the capped copy beside the strip names the cap, so
      # the numbers never read as org totals).
      instances_index = Map.new(instances, fn instance -> {instance.id, instance.status} end)
      subscribe_to_instances(instances_state, instances)

      {:ok,
       socket
       |> assign(
         org: org,
         wallet: wallet,
         instances_state: instances_state,
         instances_capped?: capped?,
         instances_empty?: instances == [],
         instances_index: instances_index,
         strip: strip_counts(instances_index)
       )
       |> stream(:instances, instances)}
    else
      # A malformed param (the cast) or a lookup that answers nothing:
      # one arm, one answer — back to the list with the flash.
      _missing ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That org does not exist."))
         |> push_navigate(to: ~p"/admin/orgs")}
    end
  end

  # Teardown's hard delete: the row leaves the stream, and the index
  # (and the strip with it) follows.
  @impl Phoenix.LiveView
  def handle_info(
        %Ash.Notifier.Notification{action: %{name: :destroy}, data: %{id: id}},
        socket
      ) do
    socket
    |> stream_delete(:instances, %Instance{id: id})
    |> reindex(Map.delete(socket.assigns.instances_index, id))
    |> then(&{:noreply, &1})
  end

  # A status write (the funnel, deploy, a resize): re-read the row on
  # broadcast (the DB is the one ordering that can't lie — a trailing
  # notification can predate fresher writes) and re-stream it loaded,
  # the dashboard's exact posture. The strip re-counts from the index.
  def handle_info(%Ash.Notifier.Notification{data: %{id: id}}, socket) do
    case Instance.get_by_id(id, actor: socket.assigns.current_user) do
      {:ok, instance} ->
        instance = Ash.load!(instance, [app_version: :app], actor: socket.assigns.current_user)

        socket
        |> stream_insert(:instances, instance)
        |> reindex(Map.put(socket.assigns.instances_index, id, instance.status))
        |> then(&{:noreply, &1})

      _error ->
        # Destroy races land here too: the row left via the destroy
        # clause, nothing to re-read.
        {:noreply, socket}
    end
  end

  # Per-instance subscribe over the loaded page (instance_live/show's
  # pattern): only where a table exists to keep live. The hidden state
  # has nothing to follow.
  defp subscribe_to_instances(:ok, instances) do
    Enum.each(instances, fn instance ->
      Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")
    end)
  end

  defp subscribe_to_instances(_hidden, _instances), do: :ok

  # One index, one recount — and the empty state follows the index:
  # a destroy that empties the page must land on the empty inset, not
  # a zeroed strip beside a header with nothing under it.
  defp reindex(socket, index) do
    assign(socket,
      instances_index: index,
      instances_empty?: index == %{},
      strip: strip_counts(index)
    )
  end

  # A route param is an untyped string: cast before it becomes an
  # argument, so garbage ids take the missing-org arm instead of
  # raising at the action boundary.
  defp cast_uuid(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  # The flagged seam (#501): one id in, the switcher's public fields
  # out. An unknown org answers an empty list — the with's match arm.
  defp org_lookup(admin, org_id) do
    Organization
    |> Ash.ActionInput.for_action(:admin_lookup, %{ids: [org_id]}, actor: admin)
    |> Ash.run_action()
  end

  # The wallet read policy's platform-admin arm carries this read (the
  # read! posture: a read failure is the DB-down class). An org can
  # legitimately have no wallet yet — team orgs provision at the first
  # billing touch — and that is an honest :none, not an error.
  defp wallet_read(admin, org_id) do
    case Wallet
         |> Ash.Query.for_read(:get_by_organization, %{organization_id: org_id}, actor: admin)
         |> Ash.Query.load(:balance)
         |> Ash.read!() do
      [wallet] -> {:ok, wallet}
      [] -> :none
    end
  end

  # The instances ride the org-scoped read — but WHO may read them is
  # not answerable from the read alone: the read policy's
  # relates_to_actor_via is a filter check, so a non-member admin's
  # read succeeds with an empty list, indistinguishable from "nothing
  # deployed". The honest scope decision rides the membership probe
  # (the same members-only filter, one row in or none), and only a
  # member admin's read runs. Capped one past the cap so the overflow
  # question answers without a count.
  defp instances_page(admin, org_id) do
    if org_member?(admin, org_id) do
      fetched =
        Instance
        |> Ash.Query.for_read(:list_for_organization, %{organization_id: org_id}, actor: admin)
        |> Ash.Query.sort(created_at: :desc, id: :desc)
        |> Ash.Query.limit(@list_cap + 1)
        |> Ash.Query.load(app_version: :app)
        |> Ash.read!()

      capped? = length(fetched) > @list_cap
      {:ok, Enum.take(fetched, @list_cap), capped?}
    else
      {:hidden, [], false}
    end
  end

  # The membership probe: the Membership read policy is members-only
  # with the same relates_to_actor_via filter, so a non-member admin's
  # read answers [] — the policy's own "you are not inside" answer.
  # No new action, no widened policy: the probe rides the member read
  # exactly as the instance table does.
  defp org_member?(admin, org_id) do
    Membership
    |> Ash.Query.for_read(:read, %{}, actor: admin)
    |> Ash.Query.filter(organization_id == ^org_id and user_id == ^admin.id)
    |> Ash.read!()
    |> Enum.any?()
  end

  # The strip's counts read the index of the SHOWN page. "other" is
  # the mixed bucket (error, lost, pending, deploying, starting,
  # restoring, deleting) — its own cue, so ten errored instances can
  # never read as "all quiet".
  defp strip_counts(index) do
    statuses = Map.values(index)
    freq = Enum.frequencies(statuses)
    total = map_size(index)

    running = Map.get(freq, :running, 0)
    stopped = Map.get(freq, :stopped, 0)
    sleeping = Map.get(freq, :sleeping, 0)

    %{
      running: running,
      stopped: stopped,
      sleeping: sleeping,
      other: total - running - stopped - sleeping
    }
  end

  # Reached only under the wallet_since guard in the template.
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
      <div class="appgram console contents" data-testid="admin-orgs-detail">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">{@org.name}</h1>
              <p class="mt-1 font-mono text-sm text-ink-muted">{@org.slug}</p>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext(
                  "The org's wallet state and its instances. Instances render only as far as the read policy admits."
                )}
              </p>
              <div class="mt-4">
                <.link
                  navigate={~p"/admin/orgs"}
                  data-testid="admin-orgs-back-link"
                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                >
                  {gettext("Back to orgs")}
                </.link>
              </div>
            </div>
          </div>
        </section>

        <section class="wrap pt-2 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <%!-- The section entry is an ANCESTOR mark (exact: false):
            this page is the orgs section's sub-route, so the sidebar's
            orgs entry carries aria-current="location". --%>
            <AdminShell.sidebar current="orgs" exact={false} />

            <div class="min-w-0 flex-1 space-y-8">
              <%!-- The wallet summary: the state badge and the balance.
              The ledger and its writes live in the wallets section. --%>
              <.card class="space-y-4" data-testid="admin-orgs-detail-wallet-card">
                <div class="flex items-start justify-between gap-4">
                  <div class="min-w-0">
                    <h2 class="text-base font-medium text-ink">{gettext("Wallet")}</h2>
                    <p class="mt-1 text-sm text-ink-muted">
                      {gettext("The balance and its state. The ledger lives in Wallets and billing.")}
                    </p>
                  </div>
                  <.link
                    :if={match?({:ok, _wallet}, @wallet)}
                    navigate={~p"/admin/billing/wallets/#{elem(@wallet, 1).id}"}
                    data-testid="admin-orgs-open-wallet"
                    class="shrink-0 text-sm font-medium text-link underline-offset-2 hover:underline"
                  >
                    {gettext("Open wallet")}
                  </.link>
                </div>

                <div
                  :if={match?({:ok, _wallet}, @wallet)}
                  data-testid="admin-orgs-detail-wallet-facts"
                >
                  <div class="flex flex-wrap items-center gap-3">
                    <span
                      class="whitespace-nowrap text-3xl font-bold tracking-tight text-ink"
                      data-testid="admin-orgs-detail-balance"
                    >
                      {BillingComponents.format_balance(elem(@wallet, 1).balance)}
                    </span>
                    <span data-testid="admin-orgs-detail-state">
                      <AdminComponents.wallet_state_badge balance_cents={elem(@wallet, 1).balance} />
                    </span>
                  </div>
                  <p
                    :if={elem(@wallet, 1).created_at}
                    class="mt-1 text-sm text-ink-muted"
                    data-testid="admin-orgs-detail-wallet-since"
                  >
                    {gettext("Wallet since %{date}",
                      date: stamp_text(elem(@wallet, 1).created_at)
                    )}
                  </p>
                </div>

                <div :if={@wallet == :none} data-testid="admin-orgs-detail-no-wallet">
                  <%!-- The moderation grammar (a solid panel wrapping a
                  borderless empty state): the card IS the panel here. --%>
                  <.empty_state
                    title={gettext("No wallet yet.")}
                    class="border-none bg-transparent"
                  >
                    {gettext("It provisions at the org's first billing touch.")}
                  </.empty_state>
                </div>
              </.card>

              <%!-- The instances, exactly as far as the members-only read
              policy admits: a member admin sees the strip and the
              table, a non-member admin sees the scope note. --%>
              <div class="space-y-4" data-testid="admin-orgs-detail-instances">
                <h2 class="text-base font-medium text-ink">{gettext("Instances")}</h2>

                <%!-- "Newest first" describes a list: it says nothing in
                the states with no list. --%>
                <p
                  :if={@instances_state == :ok}
                  class="text-sm text-ink-muted"
                >
                  {gettext("Newest first. The instances' own pages live in the product surfaces.")}
                </p>

                <div
                  :if={@instances_state == :hidden}
                  class="rounded-panel border border-line bg-panel px-6 py-8"
                  data-testid="admin-orgs-instances-hidden"
                >
                  <p class="text-sm font-medium text-ink">
                    {gettext("You are not a member of this org.")}
                  </p>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext("Instances are readable by org members only, so none are listed here.")}
                  </p>
                </div>

                <%= if @instances_state == :ok do %>
                  <div :if={@instances_empty?} data-testid="admin-orgs-instances-empty">
                    <%!-- The moderation inset (the one grammar). --%>
                    <div class="rounded-panel border border-line bg-panel px-6 py-8">
                      <.empty_state
                        title={gettext("No instances yet.")}
                        class="border-none bg-transparent"
                      >
                        {gettext("Nothing has been deployed from this org.")}
                      </.empty_state>
                    </div>
                  </div>

                  <div :if={not @instances_empty?} class="space-y-3">
                    <%!-- The lifecycle strip: the counts read the SHOWN
                    page (the capped copy beside them names the cap).
                    The chips carry the design system's dot cues, the
                    SAME per-state treatment the row badges use
                    (core_components status_badge) — chip and row can
                    never disagree, and no solid hero-icon outlier
                    outshouts the quiet states. "other" is the mixed
                    bucket (error, lost, pending, in-motion) on the
                    warning rung with a static dot: attention, no
                    motion claim. Sleep is a resting state, not a
                    failure — the note says what waking costs and when
                    it happens (ADR-0036). --%>
                    <div
                      class="flex flex-wrap items-center gap-2"
                      data-testid="admin-orgs-status-strip"
                    >
                      <span class="inline-flex items-center gap-1.5 rounded-full border border-line-success bg-success-muted px-2.5 py-0.5 text-xs font-medium text-success">
                        <span class="size-1.5 rounded-full bg-current" />
                        <span data-testid="admin-orgs-strip-running">
                          {gettext("%{count} running", count: @strip.running)}
                        </span>
                      </span>
                      <span class="inline-flex items-center gap-1.5 rounded-full border border-line bg-panel-raised px-2.5 py-0.5 text-xs font-medium text-ink-muted">
                        <span data-testid="admin-orgs-strip-stopped">
                          {gettext("%{count} stopped", count: @strip.stopped)}
                        </span>
                      </span>
                      <span class="inline-flex items-center gap-1.5 rounded-full border border-line bg-primary-muted px-2.5 py-0.5 text-xs font-medium text-link">
                        <span data-testid="admin-orgs-strip-sleeping">
                          {gettext("%{count} sleeping", count: @strip.sleeping)}
                        </span>
                      </span>
                      <span class="inline-flex items-center gap-1.5 rounded-full border border-line-warning bg-warning-muted px-2.5 py-0.5 text-xs font-medium text-warning">
                        <span class="size-1.5 rounded-full bg-current" />
                        <span data-testid="admin-orgs-strip-other">
                          {gettext("%{count} other", count: @strip.other)}
                        </span>
                      </span>
                    </div>

                    <p
                      :if={@strip.sleeping > 0}
                      class="text-sm text-ink-muted"
                      data-testid="admin-orgs-sleep-note"
                    >
                      {gettext(
                        "Sleeping instances wake on the next visit and bill storage only while asleep."
                      )}
                    </p>

                    <%!-- The count is the @list_cap above (kept literal here —
                    a module attribute reads as assigns inside HEEx); move the
                    two together. --%>
                    <p
                      :if={@instances_capped?}
                      class="text-sm text-ink-muted"
                      data-testid="admin-orgs-instances-capped"
                    >
                      {gettext("Showing the latest 100 instances.")}
                    </p>

                    <%!-- The md-band posture (the people surface's idiom):
                    header and rows share one overflow-x-auto box, so a
                    narrow band scrolls INTERNALLY, never the page. The
                    floor on the inner box is the tracks' own sum: it
                    keeps the fr tracks from collapsing to zero slivers
                    before the scroll engages. The chrome around the
                    tracks is the shared helper (#602); the tracks stay
                    literal so Tailwind keeps emitting them. --%>
                    <div class="overflow-x-auto" data-noscroll>
                      <div class="min-w-[38rem]">
                        <%!-- One grid template shared by the header and
                        every row (kept literal in both spots), so the
                        columns can never drift. --%>
                        <div class={[
                          "grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)_7.5rem_9.5rem_6.5rem]",
                          AdminComponents.admin_table_header_class()
                        ]}>
                          <div class="truncate">{gettext("Instance")}</div>
                          <div class="truncate">{gettext("App")}</div>
                          <div class="truncate">{gettext("Status")}</div>
                          <div class="truncate">{gettext("Allocation")}</div>
                          <div class="truncate">{gettext("Created")}</div>
                        </div>

                        <div id="admin-orgs-instances-table" phx-update="stream">
                          <div
                            :for={{dom_id, instance} <- @streams.instances}
                            id={dom_id}
                            class={[
                              "grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)_7.5rem_9.5rem_6.5rem]",
                              AdminComponents.admin_table_row_class(),
                              "border-b border-line last:border-0"
                            ]}
                          >
                            <div class="min-w-0" data-testid={"admin-orgs-instance-#{instance.id}"}>
                              <p class="truncate font-medium text-ink">{instance.name}</p>
                              <p class="truncate font-mono text-xs text-ink-muted">
                                {instance.slug}
                              </p>
                            </div>
                            <div class="min-w-0" data-testid={"admin-orgs-app-#{instance.id}"}>
                              <p class="truncate text-sm text-ink">
                                {instance.app_version.app.name}
                              </p>
                              <p class="truncate font-mono text-xs text-ink-muted">
                                v{instance.app_version.version}
                              </p>
                            </div>
                            <div>
                              <span data-testid={"admin-orgs-status-#{instance.id}"}>
                                <.status_badge status={instance.status} />
                              </span>
                            </div>
                            <div class="min-w-0">
                              <%!-- Truncate, but never hide: the title
                            carries the full allocation the ellipsis
                            clips (a shorn "8 CPU · 65536 MB · 102…"
                            reads as a different instance). --%>
                              <span
                                class="block truncate text-xs text-ink-muted"
                                title={AdminComponents.instance_allocation_text(instance)}
                                data-testid={"admin-orgs-allocation-#{instance.id}"}
                              >
                                {AdminComponents.instance_allocation_text(instance)}
                              </span>
                            </div>
                            <div>
                              <span
                                class="text-sm text-ink-muted"
                                data-testid={"admin-orgs-created-#{instance.id}"}
                              >
                                {stamp_text(instance.created_at)}
                              </span>
                            </div>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
