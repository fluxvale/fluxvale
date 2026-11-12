defmodule FluxValeWeb.AdminLive.Health do
  @moduledoc """
  The Health section (#702, ADR-0050 — the operational console): the
  instance fleet at a glance. The build stamp (env chip when the
  platform names its env, the version always), the status spread with
  the always-on count, the five newest deploys with their recorded
  actor tombstones, the wake widget — per-app p95 promotion-wait and
  median total seconds off WakeStats' in-memory scrape (numbers reset
  on every deploy) — the storage posture (allocated GB and the
  storage-request queue's three counters), the org runway (the
  wallets below the configured gate, the unknown projections counted),
  and the audit activity (the last 24 hours of trail rows across the
  audited business set).

  The data comes from `FluxValeWeb.AdminHealth` — the section's
  widget seam — each read with the mount-resolved admin actor and
  authorization ON (repo default): the policies decide, never the UI.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Observability.WakeStats
  alias FluxValeWeb.AdminHealth
  alias FluxValeWeb.AdminShell
  alias FluxValeWeb.BillingComponents

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:fleet, AdminHealth.fleet(socket.assigns.current_user))
     |> assign(:wake, AdminHealth.wake())
     |> assign(:storage, AdminHealth.storage(socket.assigns.current_user))
     |> assign(:runway, AdminHealth.runway(socket.assigns.current_user))
     |> assign(:audit_activity, AdminHealth.audit_activity(socket.assigns.current_user))
     |> assign(:smoke, AdminHealth.smoke())
     |> assign(:errors, AdminHealth.errors())}
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
      <div class="appgram console contents" data-testid="admin-health">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5" data-testid="admin-health-title">
                {gettext("Health")}
              </h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext(
                  "The instance fleet at a glance — the build this platform runs, the status spread, and the newest deploys."
                )}
              </p>
            </div>
          </div>
        </section>

        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <AdminShell.sidebar current="health" pending_requests={@pending_storage_requests} />

            <div class="min-w-0 flex-1 space-y-6">
              <%!-- The build stamp: the env chip renders only when the
              platform names its env (config.exs's "local" default, the
              fleet overlays' staging/production) — the version chip
              always does (the /health contract's same value). --%>
              <div class="flex flex-wrap items-center gap-2" data-testid="fleet-chips">
                <span
                  :if={@fleet.env}
                  data-testid="fleet-env"
                  class="inline-flex items-center gap-1 rounded-control border border-line bg-panel-raised px-2 py-0.5 text-xs text-ink"
                >
                  {gettext("Env")}: {@fleet.env}
                </span>
                <span
                  data-testid="fleet-version"
                  class="inline-flex items-center gap-1 rounded-control border border-line bg-panel-raised px-2 py-0.5 font-mono text-xs text-ink"
                >
                  {gettext("Version")}: {@fleet.version}
                </span>
              </div>

              <div
                class="rounded-panel border border-line bg-panel px-4 py-4"
                data-testid="fleet-summary"
              >
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <p class="text-sm text-ink-muted" data-testid="fleet-total">
                    {ngettext("1 instance", "%{count} instances", @fleet.total)}
                  </p>
                  <p class="text-sm text-ink-muted" data-testid="fleet-always-on">
                    {ngettext("1 always-on", "%{count} always-on", @fleet.always_on)}
                  </p>
                </div>
                <div class="mt-3 flex flex-wrap items-center gap-2" data-testid="fleet-statuses">
                  <%!-- One badge per non-zero status, in the lifecycle arc
                  InstanceStatus documents (unknowns alphabetical at the
                  tail). The badge is the shared status_badge — the one
                  state-to-(label, color, pulse) mapping — and the count
                  rides beside it as sibling markup; the fleet's
                  vocabulary is the product's (#179), never forked here. --%>
                  <span
                    :for={{status, count} <- sorted_statuses(@fleet.statuses)}
                    data-testid={"fleet-status-#{status}"}
                    class="inline-flex items-center gap-1"
                  >
                    <.status_badge status={status} />
                    <span class="text-xs font-medium text-ink">{count}</span>
                  </span>
                </div>
              </div>

              <%!-- The wake widget (#702): per-app p95 promotion-wait
              and median total seconds off WakeStats' in-memory
              scrape. A row renders for every app either family knows;
              a family an app lacks renders the honest dash, and no
              numbers at all render the honest empty line (the deploys
              trail's same grammar) — PromEx off is the default local
              state, and a hollow box would lie about it. Values render
              through WakeStats.format_estimate/1 — the catalog badge's
              one formatter. No external link — the Grafana wake
              dashboard is fleet-repo owned; links arrive with the
              Tier-2 proxy config. --%>
              <div
                class="rounded-panel border border-line bg-panel px-4 py-4 text-ink"
                data-testid="wake-panel"
              >
                <h2 class="text-sm font-medium" data-testid="wake-title">
                  {gettext("Wakes")}
                </h2>
                <ul
                  :if={wake_apps(@wake) != []}
                  class="mt-2"
                  id="wake-apps"
                  data-testid="wake-apps"
                >
                  <li
                    :for={slug <- wake_apps(@wake)}
                    data-testid={"wake-#{slug}"}
                    class="flex flex-wrap items-center gap-2 border-b border-line py-2 text-sm text-ink last:border-0"
                  >
                    <span class="font-mono text-xs">{slug}</span>
                    <span aria-hidden="true">-</span>
                    <span>
                      {gettext("p95 promotion %{seconds}",
                        seconds: wake_seconds(@wake.p95_promotion, slug)
                      )}
                    </span>
                    <span aria-hidden="true">-</span>
                    <span>
                      {gettext("median total %{seconds}",
                        seconds: wake_seconds(@wake.median_total, slug)
                      )}
                    </span>
                  </li>
                </ul>
                <p
                  :if={wake_apps(@wake) == []}
                  class="mt-2 text-sm text-ink-muted"
                  data-testid="wake-empty"
                >
                  {gettext("No wake data yet — the metrics tree is off or no app has enough samples.")}
                </p>
                <p class="mt-2 text-xs text-ink-muted" data-testid="wake-caveat">
                  {gettext(
                    "In-memory numbers covering the time since this deployment started — they reset on every deploy."
                  )}
                </p>
              </div>

              <%!-- The storage posture widget (#702): the fleet's
              allocated gigabytes and the operator queue's three
              state counters — the same numbers the sidebar badge
              counts. The queue deep-links to its own section; pool
              headroom is a runbook fact, named as text because the
              runbook is not served from here. --%>
              <div
                class="rounded-panel border border-line bg-panel px-4 py-4 text-ink"
                data-testid="storage-panel"
              >
                <h2 class="text-sm font-medium" data-testid="storage-title">
                  {gettext("Storage")}
                </h2>
                <div class="mt-2 flex flex-wrap items-center gap-2" data-testid="storage-chips">
                  <span
                    data-testid="storage-allocated"
                    class="inline-flex items-center gap-1 rounded-control border border-line bg-panel-raised px-2 py-0.5 text-xs text-ink"
                  >
                    {ngettext("1 GB allocated", "%{count} GB allocated", @storage.allocated_gb)}
                  </span>
                  <span
                    data-testid="storage-requested"
                    class="inline-flex items-center gap-1 rounded-control border border-line bg-panel-raised px-2 py-0.5 text-xs text-ink"
                  >
                    {ngettext("1 requested", "%{count} requested", @storage.requested)}
                  </span>
                  <span
                    data-testid="storage-approved"
                    class="inline-flex items-center gap-1 rounded-control border border-line bg-panel-raised px-2 py-0.5 text-xs text-ink"
                  >
                    {ngettext("1 approved", "%{count} approved", @storage.approved)}
                  </span>
                  <span
                    data-testid="storage-applied"
                    class="inline-flex items-center gap-1 rounded-control border border-line bg-panel-raised px-2 py-0.5 text-xs text-ink"
                  >
                    {ngettext("1 applied", "%{count} applied", @storage.applied)}
                  </span>
                </div>
                <p class="mt-2 text-xs text-ink-muted" data-testid="storage-runbook">
                  {gettext("Pool headroom lives in the block-storage runbook — not served from here.")}
                </p>
                <p class="mt-2">
                  <.link
                    navigate={~p"/admin/storage-requests"}
                    class="text-sm font-medium text-link underline-offset-2 hover:underline"
                    data-testid="storage-link"
                  >
                    {gettext("Open the storage queue")}
                  </.link>
                </p>
              </div>

              <%!-- The org runway widget (#702): the wallets below the
              configured gate (the seam's threshold, restated so the
              list has its context), sorted most-urgent first, one row
              per low wallet — the phrase rides the billing display
              seam's projection formatter, never a raw float, and the
              row names the org twice (name, then the slug in mono —
              the deploy-row idiom, since names are not unique). The
              list caps at ten with an honest overflow count.
              Depleted-with-no-burn wallets, unknown projections and a
              failed widget read each render their own honest line:
              "above the gate" speaks only when it is true. --%>
              <div
                class="rounded-panel border border-line bg-panel px-4 py-4 text-ink"
                data-testid="runway-panel"
              >
                <h2 class="text-sm font-medium" data-testid="runway-title">
                  {gettext("Org runway")}
                </h2>
                <p class="mt-2 text-sm text-ink-muted" data-testid="runway-gate">
                  {gettext("Wallets under %{hours}h of runway", hours: @runway.threshold_hours)}
                </p>
                <p
                  :if={@runway.unavailable}
                  class="mt-2 text-sm text-ink-muted"
                  data-testid="runway-unavailable"
                >
                  {gettext("Runway data unavailable.")}
                </p>
                <ul :if={@runway.low != []} class="mt-2" id="runway-low" data-testid="runway-low">
                  <li
                    :for={row <- Enum.take(@runway.low, runway_cap())}
                    class="flex flex-wrap items-center gap-2 border-b border-line py-2 text-sm text-ink last:border-0"
                  >
                    <span class="font-medium">{row.org}</span>
                    <span class="font-mono text-xs text-ink-muted">{row.slug}</span>
                    <span aria-hidden="true">-</span>
                    <span>{BillingComponents.format_runway(row.projection)}</span>
                  </li>
                </ul>
                <p
                  :if={length(@runway.low) > runway_cap()}
                  class="mt-2 text-xs text-ink-muted"
                  data-testid="runway-more"
                >
                  {ngettext(
                    "and 1 more",
                    "and %{count} more",
                    length(@runway.low) - runway_cap()
                  )}
                </p>
                <p
                  :if={@runway.depleted > 0}
                  class="mt-2 text-xs text-ink-muted"
                  data-testid="runway-depleted"
                >
                  {ngettext("1 depleted wallet", "%{count} depleted wallets", @runway.depleted)}
                </p>
                <p
                  :if={@runway.unknown > 0}
                  class="mt-2 text-xs text-ink-muted"
                  data-testid="runway-unknown"
                >
                  {ngettext(
                    "1 projection unknown",
                    "%{count} projections unknown",
                    @runway.unknown
                  )}
                </p>
                <p
                  :if={
                    @runway.low == [] and @runway.unknown == 0 and @runway.depleted == 0 and
                      not @runway.unavailable
                  }
                  class="mt-2 text-sm text-ink-muted"
                  data-testid="runway-empty"
                >
                  {gettext("Every wallet is above the gate.")}
                </p>
                <p class="mt-2">
                  <.link
                    navigate={~p"/admin/billing"}
                    class="text-sm font-medium text-link underline-offset-2 hover:underline"
                    data-testid="runway-link"
                  >
                    {gettext("Open wallets and billing")}
                  </.link>
                </p>
              </div>

              <%!-- The audit activity widget (#702, W5): the last 24
              hours of paper-trail rows across the audited business set
              — one indexed count per AdminAudit Version module, the
              whole-set total, the five busiest resources, and the deep
              link into the full trail. The 24h window is stated in the
              copy, never implied. --%>
              <div
                class="rounded-panel border border-line bg-panel px-4 py-4 text-ink"
                data-testid="audit-activity"
              >
                <h2 class="text-sm font-medium" data-testid="audit-title">
                  {gettext("Audit activity")}
                </h2>
                <p class="mt-2 text-sm text-ink-muted" data-testid="audit-activity-total">
                  {ngettext(
                    "1 change in the last 24 hours",
                    "%{count} changes in the last 24 hours",
                    @audit_activity.total
                  )}
                </p>
                <ul
                  :if={@audit_activity.top != []}
                  class="mt-2"
                  id="audit-activity-top"
                  data-testid="audit-activity-top"
                >
                  <li
                    :for={row <- @audit_activity.top}
                    data-testid={"audit-activity-#{row.key}"}
                    class="flex flex-wrap items-center gap-2 border-b border-line py-2 text-sm text-ink last:border-0"
                  >
                    <span class="font-medium">{row.label}</span>
                    <span aria-hidden="true">-</span>
                    <span>{ngettext("1 change", "%{count} changes", row.count)}</span>
                  </li>
                </ul>
                <p
                  :if={@audit_activity.active > length(@audit_activity.top)}
                  class="mt-2 text-xs text-ink-muted"
                  data-testid="audit-activity-more"
                >
                  {ngettext(
                    "and 1 more resource",
                    "and %{count} more resources",
                    @audit_activity.active - length(@audit_activity.top)
                  )}
                </p>
                <p
                  :if={@audit_activity.top == []}
                  class="mt-2 text-sm text-ink-muted"
                  data-testid="audit-activity-empty"
                >
                  {gettext("No audit activity in the last 24 hours.")}
                </p>
                <p class="mt-2">
                  <.link
                    navigate={~p"/admin/audit"}
                    class="text-sm font-medium text-link underline-offset-2 hover:underline"
                    data-testid="audit-link"
                  >
                    {gettext("Open the audit trail")}
                  </.link>
                </p>
              </div>

              <%!-- The smoke widget (#702, W2): the scheduled workflow's
              latest verdict through the cached public runs API, the
              last run's time, and the public workflow link. The chip
              speaks the verdict; an unreachable API says so rather
              than guess. Grafana's heartbeat series and synthetics
              stay Grafana-side — the Tier-1 boundary. --%>
              <div
                class="rounded-panel border border-line bg-panel px-4 py-4 text-ink"
                data-testid="smoke-panel"
              >
                <h2 class="text-sm font-medium" data-testid="smoke-title">
                  {gettext("Smoke status")}
                </h2>
                <div class="mt-2 flex flex-wrap items-center gap-2">
                  <.badge tone={smoke_tone(@smoke)} data-testid="smoke-verdict">
                    {smoke_label(@smoke)}
                  </.badge>
                </div>
                <%= case @smoke do %>
                  <% {:ok, %{runs: [latest | _]}} -> %>
                    <p class="mt-2 text-sm text-ink-muted" data-testid="smoke-last-run">
                      {gettext("Last run: %{time}", time: smoke_time(latest.created_at))}
                    </p>
                  <% {:ok, %{runs: []}} -> %>
                    <p class="mt-2 text-sm text-ink-muted" data-testid="smoke-empty">
                      {gettext("No scheduled smoke runs returned.")}
                    </p>
                  <% {:error, :unreachable} -> %>
                    <p class="mt-2 text-sm text-ink-muted" data-testid="smoke-unreachable">
                      {gettext("The GitHub runs API did not answer — check the public runs page.")}
                    </p>
                <% end %>
                <p class="mt-2">
                  <.link
                    href="https://github.com/fluxvale/fluxvale/actions/workflows/smoke.yml"
                    target="_blank"
                    rel="noopener"
                    class="text-sm font-medium text-link underline-offset-2 hover:underline"
                    data-testid="smoke-link"
                  >
                    {gettext("Open the smoke workflow")}
                  </.link>
                </p>
              </div>

              <%!-- The error-count seam (#702, W6; ADR-0050 D6): reserved,
              not blocked on. Until the PostHog split's S1/S4 flip lands
              the Tier-2 proxy, the panel says so in place — Grafana
              Explore's error_signature is today's surface. No number is
              fabricated here. --%>
              <div
                class="rounded-panel border border-line bg-panel px-4 py-4 text-ink"
                data-testid="errors-panel"
              >
                <h2 class="text-sm font-medium" data-testid="errors-title">
                  {gettext("Errors")}
                </h2>
                <p
                  :if={@errors == {:error, :not_configured}}
                  class="mt-2 text-sm text-ink-muted"
                  data-testid="errors-placeholder"
                >
                  {gettext(
                    "Error counts are not configured yet — they land with the PostHog split; until then Grafana Explore's error_signature is the surface."
                  )}
                </p>
              </div>

              <div class="rounded-panel border border-line bg-panel px-4 py-4 text-ink">
                <h2 class="text-sm font-medium" data-testid="fleet-deploys-title">
                  {gettext("Recent deploys")}
                </h2>
                <%!-- The trail caps at five by the seam — a plain assign,
                not a stream: the cap makes ballooning impossible. The
                empty line is the audit section's honest-empty grammar. --%>
                <ul class="mt-2" id="fleet-deploys" data-testid="fleet-deploys">
                  <li
                    :if={@fleet.recent_deploys == []}
                    data-testid="fleet-deploys-empty"
                    class="py-2 text-sm text-ink-muted"
                  >
                    {gettext("No deploys recorded yet.")}
                  </li>
                  <li
                    :for={deploy <- @fleet.recent_deploys}
                    class="flex flex-wrap items-center gap-2 border-b border-line py-2 text-sm text-ink last:border-0"
                  >
                    <span class="font-mono text-xs">{deploy.source}</span>
                    <span aria-hidden="true">-</span>
                    <span>{deploy_actor(deploy.actor)}</span>
                    <span aria-hidden="true">-</span>
                    <span class="text-xs whitespace-nowrap text-ink-muted">
                      {Calendar.strftime(deploy.at, "%b %d %H:%M UTC")}
                    </span>
                  </li>
                </ul>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The low list renders its ten most-urgent rows; the seam's honest
  # overflow count covers the rest.
  defp runway_cap, do: 10

  # The lifecycle arc, in InstanceStatus's documented order.
  @status_arc [
    :pending,
    :deploying,
    :starting,
    :running,
    :restoring,
    :sleeping,
    :stopped,
    :error,
    :deleting,
    :lost
  ]

  # Map iteration order is unspecified — the badge row renders in the
  # lifecycle arc InstanceStatus documents (the state machine's own
  # reading: submitted → provisioning → starting → running, the idle
  # and backup rests, then the failure and teardown terminals), with
  # unknown statuses alphabetical at the tail so a new atom can never
  # reorder the row.
  defp sorted_statuses(statuses) do
    {arc, unknown} = Map.split(statuses, @status_arc)

    Enum.sort_by(arc, &arc_index(elem(&1, 0))) ++ Enum.sort(unknown)
  end

  defp arc_index(status), do: Enum.find_index(@status_arc, &(&1 == status))

  # The tombstone renders as recorded; a nil actor_label is the honest
  # system attribution (the audit section's same grammar).
  defp deploy_actor(nil), do: gettext("System")
  defp deploy_actor(actor), do: actor

  # Status is checked before conclusion deliberately: a queued or
  # in-progress run has no conclusion yet.
  defp smoke_label({:error, :unreachable}), do: gettext("Unreachable")
  defp smoke_label({:ok, %{runs: []}}), do: gettext("No runs")
  defp smoke_label({:ok, %{runs: [latest | _rest]}}), do: verdict_label(latest)

  defp verdict_label(%{status: status})
       when status in ["queued", "in_progress", "waiting", "pending"],
       do: gettext("In progress")

  defp verdict_label(%{conclusion: "success"}), do: gettext("Success")

  defp verdict_label(%{conclusion: conclusion})
       when conclusion in ["failure", "timed_out"],
       do: gettext("Failure")

  defp verdict_label(%{conclusion: conclusion}) when is_binary(conclusion),
    do: String.capitalize(conclusion)

  defp verdict_label(_run), do: gettext("No verdict")

  defp smoke_tone({:error, :unreachable}), do: "neutral"
  defp smoke_tone({:ok, %{runs: []}}), do: "neutral"
  defp smoke_tone({:ok, %{runs: [latest | _rest]}}), do: verdict_tone(latest)

  defp verdict_tone(%{status: status})
       when status in ["queued", "in_progress", "waiting", "pending"],
       do: "warning"

  defp verdict_tone(%{conclusion: "success"}), do: "success"

  defp verdict_tone(%{conclusion: conclusion})
       when conclusion in ["failure", "timed_out"],
       do: "danger"

  defp verdict_tone(_run), do: "neutral"

  # The runs API's timestamps are ISO-8601; the raw-string arm is
  # defensive for a malformed upstream value and keeps it visible,
  # never a crash.
  defp smoke_time(nil), do: "-"

  defp smoke_time(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%b %d %H:%M UTC")
      {:error, _reason} -> iso
    end
  end

  # The union of the two families' app slugs, sorted for a stable row
  # order (map iteration order is unspecified).
  defp wake_apps(%{p95_promotion: p95, median_total: medians}) do
    p95
    |> Map.keys()
    |> Enum.concat(Map.keys(medians))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A family an app lacks (its other series below its sample floor)
  # renders the honest dash; a number renders through the catalog
  # badge's one formatter — same series, one convention.
  defp wake_seconds(family, slug) do
    case Map.get(family, slug) do
      nil -> "-"
      seconds -> WakeStats.format_estimate(seconds)
    end
  end
end
