defmodule FluxValeWeb.AdminLive.Catalog do
  @moduledoc """
  The admin catalog surgery list (ADR-0027 Am. 3, #501): every app with
  its versions, each version showing its allocation, the price it rides
  (its recommended size's monthly rate), and whether a first-run
  contract is present. Reads run through the public catalog reads with
  the platform-admin actor; the edit links hand off to the surgery
  forms. The size ladder lives one hop away.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog.App
  alias FluxVale.Pricing
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.UserAuth

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    # Chrome-only resolution, display seam (UserAuth): the route gate
    # (:admin_auth) plus the AdminGate on_mount have already decided
    # this session is a platform admin — the same posture as the home.
    current_user = UserAuth.resolve_user(session)

    apps =
      App
      |> Ash.Query.for_read(:list, %{}, actor: current_user)
      |> Ash.Query.load(category: [], app_versions: [:recommended_size])
      |> Ash.read!()

    {:ok,
     assign(socket,
       current_user: current_user,
       actor_orgs: [],
       personal_org_id: nil,
       username: current_user && current_user.username,
       nav_section: nil,
       apps: apps
     )}
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
      <div class="appgram contents" data-testid="admin-catalog">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">{gettext("Catalog and pricing")}</h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext(
                  "Every app and version with its allocation, its price, and its first-run posture. Edits run through the resource actions."
                )}
              </p>
              <div class="mt-4">
                <.link
                  navigate={~p"/admin/catalog/sizes"}
                  data-testid="admin-sizes-link"
                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                >
                  {gettext("Size ladder")}
                </.link>
              </div>
            </div>
          </div>
        </section>

        <section class="wrap pt-8 pb-16">
          <div class="rise space-y-4" data-testid="admin-catalog-list">
            <.empty_state
              :if={@apps == []}
              title={gettext("No apps in the catalog yet.")}
            />

            <.card :for={app <- @apps} class="space-y-4" data-testid={"admin-app-#{app.slug}"}>
              <div class="flex items-baseline justify-between gap-2">
                <div>
                  <p class="eyebrow">{app.category.name}</p>
                  <h2 class="mt-0.5 text-base font-medium text-ink">{app.name}</h2>
                </div>
              </div>

              <.table id={"admin-versions-#{app.slug}"} rows={sorted_versions(app)}>
                <:col :let={version} label={gettext("Version")}>
                  <span class="font-mono text-xs">{version.version}</span>
                </:col>
                <:col :let={version} label={gettext("Allocation")}>
                  <span data-testid={"admin-version-allocation-#{version.id}"}>
                    {AdminComponents.allocation_text(version)}
                  </span>
                </:col>
                <:col :let={version} label={gettext("Price")}>
                  <%= if version.recommended_size do %>
                    <span data-testid={"admin-version-price-#{version.id}"}>
                      <span class="font-mono text-xs">{version.recommended_size.slug}</span>
                      <span class="ml-1.5">
                        {Pricing.format_usd(version.recommended_size.monthly_cents)}
                        {gettext("/mo")}
                      </span>
                    </span>
                  <% else %>
                    <span data-testid={"admin-version-price-#{version.id}"}>
                      {gettext("No size")}
                    </span>
                  <% end %>
                </:col>
                <:col :let={version} label={gettext("First run")}>
                  <span data-testid={"admin-version-firstrun-#{version.id}"}>
                    <%= if version.first_run do %>
                      <.badge tone="primary">{gettext("Contract")}</.badge>
                    <% else %>
                      <.badge>{gettext("None")}</.badge>
                    <% end %>
                  </span>
                </:col>
                <:action :let={version}>
                  <.link
                    navigate={~p"/admin/catalog/versions/#{version.id}"}
                    data-testid={"admin-version-edit-#{version.id}"}
                    class="text-sm font-medium text-link underline-offset-2 hover:underline"
                  >
                    {gettext("Edit")}
                  </.link>
                </:action>
              </.table>
            </.card>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The version rows read newest-first, matching the app page's own
  # order (the :list_for_app sort).
  defp sorted_versions(app) do
    Enum.sort_by(app.app_versions, & &1.version, :desc)
  end
end
