defmodule FluxValeWeb.Storybook.Components.OrgSwitcher do
  @moduledoc """
  Org-switcher stories (#276): the app chrome's context dropdown.
  Open one to see the panel — a native <details>, so the storybook's
  own chrome exercises the toggle exactly like the app's. Rows follow
  the #284 rule: hidden while only-personal, all of them from the
  second org on.
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
        id: :personal_only,
        description: "Single (personal) org — the panel is the Personal row alone (#284)",
        attributes: %{orgs: Enum.take(orgs, 1), id: "story-org-switcher-personal"}
      },
      %Variation{
        id: :org_active,
        description:
          "Org context active — the closed summary names the org; still only-personal, so no org rows",
        attributes: %{
          orgs: Enum.take(orgs, 1),
          current_org: hd(orgs).organization,
          id: "story-org-switcher-org"
        }
      },
      %Variation{
        id: :two_orgs,
        description: "Two memberships — rows render: Personal pinned first, both orgs after",
        attributes: %{orgs: orgs, id: "story-org-switcher-two"}
      }
    ]
  end
end
