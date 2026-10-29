defmodule FluxValeWeb.Storybook.Components.OrgSwitcher do
  @moduledoc """
  Org-switcher stories (#276): the app chrome's context dropdown. The
  previews show the open/closed states — the outside-click and Esc
  dismissal is app-runtime behavior (the DetailsDismiss hook rides
  app.js, which the storybook page doesn't load), so check it in the
  app chrome. Rows follow the #284 rule: hidden while only-personal,
  all of them from the second org on.
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
      # No id: here — PhoenixStorybook overwrites the :id assign with its
      # own variation_dom_id, so a story-level id is dead markup (gate-2
      # F6); uniqueness comes from the framework plus the component's
      # attr(:id) default.
      %Variation{
        id: :personal_only,
        description: "Single (personal) org — the panel is the Personal row alone (#284)",
        attributes: %{orgs: Enum.take(orgs, 1)}
      },
      %Variation{
        id: :org_active,
        description:
          "Org context active — the closed summary names the org; below lg its initial leads the pill; still only-personal, so no org rows",
        attributes: %{orgs: Enum.take(orgs, 1), current_org: hd(orgs).organization}
      },
      %Variation{
        id: :org_active_long,
        description:
          "Long org name active — the label truncates above lg, the initial leads below",
        attributes: %{
          orgs: orgs,
          current_org: %{name: "A Very Long Organization Display Name", slug: "very-long"}
        }
      },
      %Variation{
        id: :two_orgs,
        description: "Two memberships — rows render: Personal pinned first, both orgs after",
        attributes: %{orgs: orgs}
      }
    ]
  end
end
