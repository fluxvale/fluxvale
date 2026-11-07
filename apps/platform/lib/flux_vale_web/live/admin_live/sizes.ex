defmodule FluxValeWeb.AdminLive.Sizes do
  @moduledoc """
  The admin size ladder (#501): the seeded sizes with their allocations
  and prices, plus how many versions point at each. That count is the
  freeze state the edit form explains: an allocation with referencing
  versions is frozen until they re-point or retire. Prices ride
  `Pricing.format_usd` — the one cents-to-dollars formatter.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Pricing.Size
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.UserAuth

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    # Chrome-only resolution, display seam (UserAuth): the route gate
    # (:admin_auth) plus the AdminGate on_mount have already decided
    # this session is a platform admin — the same posture as the home.
    current_user = UserAuth.resolve_user(session)

    sizes =
      Size
      |> Ash.Query.for_read(:read, %{}, actor: current_user)
      |> Ash.Query.sort(monthly_cents: :asc)
      |> Ash.read!()

    {:ok,
     assign(socket,
       current_user: current_user,
       actor_orgs: [],
       personal_org_id: nil,
       username: current_user && current_user.username,
       nav_section: nil,
       sizes: sizes,
       version_counts: version_counts(current_user)
     )}
  end

  # One probe feeds every row's freeze state: how many versions point
  # at each size. The count is display data — the edit form re-probes
  # at mount, and the action-level validation stays the enforcement.
  defp version_counts(admin) do
    AppVersion
    |> Ash.Query.for_read(:read, %{}, actor: admin)
    |> Ash.Query.select([:recommended_size_id])
    |> Ash.read!()
    |> Enum.frequencies_by(& &1.recommended_size_id)
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
      <div class="appgram contents" data-testid="admin-sizes">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">{gettext("Size ladder")}</h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext(
                  "The sizes and their prices. A size's allocation freezes while versions point at it. Its price never freezes."
                )}
              </p>
              <div class="mt-4">
                <.link
                  navigate={~p"/admin/catalog"}
                  data-testid="admin-catalog-link"
                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                >
                  {gettext("Back to the catalog")}
                </.link>
              </div>
            </div>
          </div>
        </section>

        <section class="wrap pt-8 pb-16">
          <div class="rise space-y-4">
            <.empty_state :if={@sizes == []} title={gettext("No sizes seeded yet.")} />

            <.table
              :if={@sizes != []}
              id="admin-size-ladder"
              rows={@sizes}
              row_id={&"size-row-#{&1.slug}"}
            >
              <:col :let={size} label={gettext("Size")}>
                <span class="font-mono text-xs">{size.slug}</span>
              </:col>
              <:col :let={size} label={gettext("Allocation")}>
                {AdminComponents.allocation_text(size)}
              </:col>
              <:col :let={size} label={gettext("Running rate")}>
                {FluxVale.Pricing.format_usd(size.monthly_cents)}
                {gettext("/mo")}
              </:col>
              <:col :let={size} label={gettext("Stopped rate")}>
                {FluxVale.Pricing.format_usd(size.stopped_monthly_cents)}
                {gettext("/mo")}
              </:col>
              <:col :let={size} label={gettext("Versions")}>
                {ngettext("1 version", "%{count} versions", @version_counts[size.id] || 0)}
              </:col>
              <:action :let={size}>
                <.link
                  navigate={~p"/admin/catalog/sizes/#{size.id}"}
                  data-testid={"admin-size-edit-#{size.slug}"}
                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                >
                  {gettext("Edit")}
                </.link>
              </:action>
            </.table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
