defmodule FluxValeWeb.AdminLive.Home do
  @moduledoc """
  The admin landing (ADR-0027 Am. 3, #501): the operator console's
  home — a static map of the admin surfaces, zero data queries. The
  per-surface workflows land in later slices of the same lane, and
  until one does, its card says so honestly and links nowhere. The two
  generated tools keep their debug subpaths and link from the deep
  debugging section.
  """

  use FluxValeWeb, :live_view

  alias FluxValeWeb.UserAuth

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    # Chrome-only resolution, display seam (UserAuth): the route gate
    # (:admin_auth) plus the AdminGate on_mount have already decided
    # this session is a platform admin — this read feeds the app
    # chrome's user menu. The rest of the chrome assigns are
    # console-neutral: the admin live_session mounts no org/nav hooks,
    # and this surface runs no data queries.
    current_user = UserAuth.resolve_user(session)

    {:ok,
     assign(socket,
       current_user: current_user,
       actor_orgs: [],
       personal_org_id: nil,
       username: current_user && current_user.username,
       nav_section: nil,
       surfaces: surfaces()
     )}
  end

  # The unbuilt surfaces, in the order the lane ships them. Copy stays
  # here so the template renders one shape; every card is badged and
  # none is a link (nothing to navigate to yet).
  defp surfaces do
    [
      %{
        testid: "admin-surface-people",
        title: gettext("People and invites"),
        blurb: gettext("Invitations, accounts, and the people behind them.")
      },
      %{
        testid: "admin-surface-catalog",
        title: gettext("Catalog and pricing surgery"),
        blurb: gettext("Edit catalog entries and price ladders.")
      },
      %{
        testid: "admin-surface-wallets",
        title: gettext("Wallets and billing"),
        blurb: gettext("Balances, top-ups, and billing oversight.")
      },
      %{
        testid: "admin-surface-feedback",
        title: gettext("Feedback moderation"),
        blurb: gettext("Moderate the public feedback board.")
      },
      %{
        testid: "admin-surface-orgs",
        title: gettext("Orgs and instances"),
        blurb: gettext("Read-only sweeps across orgs and instances.")
      },
      %{
        testid: "admin-surface-gateways",
        title: gettext("Access gateways and domains"),
        blurb: gettext("Read-only gateway and domain inspection.")
      }
    ]
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
    >
      <div class="appgram contents" data-testid="admin-home">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">{gettext("Admin")}</h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext("The operator console. Surfaces build out across this lane.")}
              </p>
            </div>
          </div>
        </section>

        <%!-- The surface map: one mosaic, all unbuilt surfaces. Same
        card language as the catalog mosaic, minus the link — none of
        these has a destination yet, so the card stays put. --%>
        <section class="wrap pt-14 pb-16">
          <div class="rise space-y-4">
            <h2 class="eyebrow">{gettext("Surfaces")}</h2>
            <div class="grid grid-cols-[repeat(auto-fit,minmax(min(17rem,100%),1fr))] gap-4">
              <.card :for={surface <- @surfaces} class="space-y-2" data-testid={surface.testid}>
                <div class="flex items-center justify-between gap-2">
                  <h3 class="text-base font-medium text-ink">{surface.title}</h3>
                  <.badge>{gettext("Coming in this lane")}</.badge>
                </div>
                <p class="text-sm text-ink-muted">{surface.blurb}</p>
              </.card>
            </div>
          </div>
        </section>

        <%!-- Deep debugging: the generated tools keep their demoted
        debug subpaths. Copy stays honest — superuser posture, no
        resource policies, emergencies only. --%>
        <section class="wrap pt-8 pb-16">
          <div class="rise space-y-4">
            <h2 class="eyebrow">{gettext("Deep debugging")}</h2>
            <p class="max-w-prose text-sm text-ink-muted">
              {gettext(
                "The generated tools. They run as trusted superuser without the resource policies. For emergencies and data surgery."
              )}
            </p>
            <div class="grid gap-4 sm:grid-cols-2">
              <.link
                navigate={~p"/admin/ash"}
                data-testid="admin-fallback-ash"
                class="group block outline-offset-2 outline-focus focus-visible:outline-2"
              >
                <.card class={[
                  "space-y-2",
                  "transition-[box-shadow] duration-(--motion-base) ease-(--motion-ease-out) group-hover:shadow-md"
                ]}>
                  <h3 class="text-base font-medium text-ink">{gettext("AshAdmin")}</h3>
                  <p class="text-sm text-ink-muted">
                    {gettext("Generated views over the shown domains.")}
                  </p>
                </.card>
              </.link>
              <.link
                navigate={~p"/admin/debug/dashboard"}
                data-testid="admin-fallback-dashboard"
                class="group block outline-offset-2 outline-focus focus-visible:outline-2"
              >
                <.card class={[
                  "space-y-2",
                  "transition-[box-shadow] duration-(--motion-base) ease-(--motion-ease-out) group-hover:shadow-md"
                ]}>
                  <h3 class="text-base font-medium text-ink">{gettext("LiveDashboard")}</h3>
                  <p class="text-sm text-ink-muted">
                    {gettext("This node's BEAM and database telemetry.")}
                  </p>
                </.card>
              </.link>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
