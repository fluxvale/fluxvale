defmodule FluxValeWeb.NavSectionTest do
  @moduledoc """
  The chrome's active-nav hook: derives `nav_section` from the mounted
  LiveView module — each section's whole namespace, the one org surface
  that IS a section (`OrganizationLive.Billing`), and nil for everything
  else (dashboard, org home/settings, settings, sign-in): the round-3
  rule is to mark only where a section genuinely applies.
  """

  use ExUnit.Case, async: true

  alias FluxValeWeb.NavSection

  test "CatalogLive.* resolves :catalog" do
    for view <- [
          FluxValeWeb.CatalogLive.Index,
          FluxValeWeb.CatalogLive.Show,
          FluxValeWeb.CatalogLive.Deploy
        ] do
      assert {:cont, socket} = NavSection.on_mount(:derive, %{}, %{}, socket_with(view))
      assert socket.assigns.nav_section == :catalog
    end
  end

  test "InstanceLive.* resolves :instances" do
    for view <- [FluxValeWeb.InstanceLive.Index, FluxValeWeb.InstanceLive.Show] do
      assert {:cont, socket} = NavSection.on_mount(:derive, %{}, %{}, socket_with(view))
      assert socket.assigns.nav_section == :instances
    end
  end

  test "BillingLive.* resolves :billing — the top-up wizard included" do
    for view <- [FluxValeWeb.BillingLive.Index, FluxValeWeb.BillingLive.Topup] do
      assert {:cont, socket} = NavSection.on_mount(:derive, %{}, %{}, socket_with(view))
      assert socket.assigns.nav_section == :billing
    end
  end

  test "OrganizationLive.Billing is the one org surface that resolves :billing" do
    assert {:cont, socket} =
             NavSection.on_mount(
               :derive,
               %{},
               %{},
               socket_with(FluxValeWeb.OrganizationLive.Billing)
             )

    assert socket.assigns.nav_section == :billing
  end

  test "everything else resolves nil — no header link marks active" do
    for view <- [
          FluxValeWeb.DashboardLive,
          FluxValeWeb.OrganizationLive.Home,
          FluxValeWeb.OrganizationLive.Settings,
          FluxValeWeb.OrganizationLive.Members,
          FluxValeWeb.OrganizationLive.Access,
          FluxValeWeb.SettingsLive,
          FluxValeWeb.AuthLive.SignIn
        ] do
      assert {:cont, socket} = NavSection.on_mount(:derive, %{}, %{}, socket_with(view))
      assert socket.assigns.nav_section == nil
    end
  end

  defp socket_with(view) do
    %Phoenix.LiveView.Socket{view: view}
  end
end
