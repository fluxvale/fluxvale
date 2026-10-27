defmodule FluxValeWeb.Storybook.Components.OrgSwitcher do
  @moduledoc """
  Org-switcher stories (#276): the app chrome's context dropdown.
  Open one to see the panel — a native <details>, so the storybook's
  own chrome exercises the toggle exactly like the app's.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.org_switcher/1
  def render_source, do: :function

  def variations do
    orgs = [
      %{organization: %{name: "Acme Collective", slug: "acme"}},
      %{organization: %{name: "OSS Friends", slug: "oss-friends"}}
    ]

    [
      %Variation{
        id: :personal_active,
        description: "Personal context active — the closed summary reads Personal",
        attributes: %{orgs: Enum.take(orgs, 1)}
      },
      %Variation{
        id: :org_active,
        description: "Org context active — the closed summary names the org",
        attributes: %{orgs: Enum.take(orgs, 1), current_org: hd(orgs).organization}
      },
      %Variation{
        id: :two_orgs,
        description: "Two memberships — Personal stays pinned first, orgs after",
        attributes: %{orgs: orgs}
      }
    ]
  end
end
