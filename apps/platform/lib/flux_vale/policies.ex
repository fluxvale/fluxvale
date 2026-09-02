defmodule FluxVale.Policies do
  @moduledoc """
  Shared policy helpers — one place answers "is this actor a platform
  admin?" for Ash policies (`Policies.PlatformAdmin`), plugs, and
  LiveViews (#20). Org-scoped questions never belong here (M5 Membership).
  """

  @spec platform_admin?(map() | nil) :: boolean()
  def platform_admin?(%{platform_role: :admin}), do: true
  def platform_admin?(_other), do: false
end
