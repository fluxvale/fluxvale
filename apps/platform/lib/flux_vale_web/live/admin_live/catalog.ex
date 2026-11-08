defmodule FluxValeWeb.AdminLive.Catalog do
  @moduledoc """
  The admin catalog surgery list (ADR-0027 Am. 3, #501): every app's
  versions in one grouped table, each version showing its allocation,
  the price it rides (its recommended size's monthly rate), and whether
  a first-run contract is present. Reads run through the public catalog
  reads with the platform-admin actor; the edit links hand off to the
  surgery forms. The size ladder lives one hop away.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog.App
  alias FluxVale.Pricing
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.AdminShell

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    # The chrome assigns (current_user, username, nav_section) ride the
    # AdminChrome on_mount on the :admin live_session — this mount adds
    # only the page's own data.
    apps =
      App
      |> Ash.Query.for_read(:list, %{}, actor: socket.assigns.current_user)
      |> Ash.Query.load(category: [], app_versions: [:recommended_size])
      |> Ash.read!()

    {:ok, assign(socket, rows: rows(apps))}
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
      <%!-- The console lane (#593): `wide` chrome + `appgram console`
      — flush sidebar, the versions table stretches the space beside
      it. --%>
      <div class="appgram console contents" data-testid="admin-catalog">
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

        <%!-- One grouped table: the app rides an eyebrow-and-name column,
        versions are rows — no box-in-box borders, no repeated header
        rows. Price scannability stays per-version. --%>
        <%!-- The section sidebar (Am. 4, the #568 idiom) owns
        cross-section wayfinding; the sizes link stays — it is
        intra-section. --%>
        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <AdminShell.sidebar current="catalog" pending_requests={@pending_storage_requests} />

            <div class="min-w-0 flex-1 space-y-6">
              <div class="space-y-4" data-testid="admin-catalog-list">
                <.empty_state :if={@rows == []} title={gettext("No apps in the catalog yet.")} />

                <.table
                  :if={@rows != []}
                  id="admin-catalog-versions"
                  rows={@rows}
                  row_id={&"catalog-version-#{&1.version.id}"}
                >
                  <:col :let={row} label={gettext("App")}>
                    <div data-testid={"admin-app-cell-#{row.app.slug}"}>
                      <p class="eyebrow">{row.app.category.name}</p>
                      <p class="mt-0.5 text-sm font-medium text-ink">{row.app.name}</p>
                    </div>
                  </:col>
                  <:col :let={row} label={gettext("Version")}>
                    <span
                      class="font-mono text-xs"
                      data-testid={"admin-version-name-#{row.version.id}"}
                    >
                      {row.version.version}
                    </span>
                  </:col>
                  <:col :let={row} label={gettext("Allocation")}>
                    <span data-testid={"admin-version-allocation-#{row.version.id}"}>
                      {AdminComponents.allocation_text(row.version)}
                    </span>
                  </:col>
                  <:col :let={row} label={gettext("Price")}>
                    <span data-testid={"admin-version-price-#{row.version.id}"}>
                      <%= if row.version.recommended_size do %>
                        <span class="font-mono text-xs">{row.version.recommended_size.slug}</span>
                        <span class="ml-1.5">
                          {gettext("%{rate}/mo",
                            rate: Pricing.format_usd(row.version.recommended_size.monthly_cents)
                          )}
                        </span>
                      <% else %>
                        {gettext("No size")}
                      <% end %>
                    </span>
                  </:col>
                  <:col :let={row} label={gettext("First run")}>
                    <span data-testid={"admin-version-firstrun-#{row.version.id}"}>
                      <%= if row.version.first_run do %>
                        <.badge tone="primary">{gettext("Contract")}</.badge>
                      <% else %>
                        <.badge>{gettext("None")}</.badge>
                      <% end %>
                    </span>
                  </:col>
                  <:action :let={row}>
                    <.link
                      navigate={~p"/admin/catalog/versions/#{row.version.id}"}
                      data-testid={"admin-version-edit-#{row.version.id}"}
                      class="text-sm font-medium text-link underline-offset-2 hover:underline"
                    >
                      {gettext("Edit")}
                    </.link>
                  </:action>
                </.table>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The table's flat rows: {app, version} pairs in the app page's own
  # order — apps by name, each app's versions newest-first (the
  # :list_for_app sort).
  defp rows(apps) do
    for app <- apps, version <- sorted_versions(app), do: %{app: app, version: version}
  end

  defp sorted_versions(app) do
    Enum.sort_by(app.app_versions, & &1.version, :desc)
  end
end
