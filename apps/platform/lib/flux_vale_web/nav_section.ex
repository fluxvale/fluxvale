defmodule FluxValeWeb.NavSection do
  @moduledoc """
  The chrome's active-nav hook (app-wide grammar lane): derives the nav
  section from the mounted LiveView module and assigns `nav_section` —
  `:catalog`, `:instances`, `:billing`, or nil. Callers pass it through
  to `Layouts.app` like every other chrome assign, and the header marks
  the matching link active with the round-3 amber underline.

  Same on_mount shape as `FluxValeWeb.OrgNav`; wire it in the
  authenticated live_session's on_mount list AND on `DashboardLive`
  (it renders through `live_render`, not the live_session). The hook is
  what lets the templates reference `@nav_section` at all: the assign is
  guaranteed present on every socket the chain mounts.

  Round-3 rule: mark only where a section genuinely applies — dashboard,
  org home/settings/members/access, `SettingsLive`, sign-in resolve nil
  and no header link marks active.
  """

  @doc """
  Assigns `nav_section` from the LiveView module. Never halts.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(_lifecycle, _params, _session, socket) do
    {:cont, Phoenix.Component.assign(socket, :nav_section, section(socket.view))}
  end

  # Namespace matching, not pattern matching: the mounted view is only
  # known at runtime here, and a section owns its whole namespace
  # (CatalogLive.Index/Show/Deploy, …). `OrganizationLive.Billing` is
  # the one org surface that IS a section — the org-scoped /billing
  # shape (#276) — so it matches exactly and the sibling org surfaces
  # (Home/Settings/Members/Access) stay unmarked.
  defp section(view) do
    case Module.split(view) do
      ["FluxValeWeb", "CatalogLive" | _rest] -> :catalog
      ["FluxValeWeb", "InstanceLive" | _rest] -> :instances
      ["FluxValeWeb", "BillingLive" | _rest] -> :billing
      ["FluxValeWeb", "OrganizationLive", "Billing"] -> :billing
      _else -> nil
    end
  end
end
