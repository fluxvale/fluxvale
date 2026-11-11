defmodule FluxValeWeb.AdminLive.Health do
  @moduledoc """
  The Health section (#702, ADR-0050 — the operational console): the
  instance fleet at a glance. The build stamp (env chip when the
  platform names its env, the version always), the status spread with
  the always-on count, and the five newest deploys with their recorded
  actor tombstones.

  The data comes from `FluxValeWeb.AdminHealth.fleet/1` — the section's
  widget seam — read with the mount-resolved admin actor and
  authorization ON (repo default): the policies decide, never the UI.
  """

  use FluxValeWeb, :live_view

  alias FluxValeWeb.AdminHealth
  alias FluxValeWeb.AdminShell
  alias FluxValeWeb.InstanceStatus

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :fleet, AdminHealth.fleet(socket.assigns.current_user))}
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
                  <%!-- One badge per non-zero status; the fleet's vocabulary
                  is the product's (#179) — InstanceStatus owns the words. --%>
                  <.badge
                    :for={{status, count} <- sorted_statuses(@fleet.statuses)}
                    data-testid={"fleet-status-#{status}"}
                    class="px-1.5! text-[11px]!"
                  >
                    {InstanceStatus.label(status)} {count}
                  </.badge>
                </div>
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

  # Map iteration order is unspecified — the badge row sorts by status
  # so the spread renders the same order on every mount.
  defp sorted_statuses(statuses), do: Enum.sort(statuses)

  # The tombstone renders as recorded; a nil actor_label is the honest
  # system attribution (the audit section's same grammar).
  defp deploy_actor(nil), do: gettext("System")
  defp deploy_actor(actor), do: actor
end
