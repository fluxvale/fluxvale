defmodule FluxValeWeb.Storybook.Components.OrgSwitcher do
  @moduledoc """
  Org-switcher stories (#276): the app chrome's context dropdown. The
  previews show the open/closed states — the outside-click and Esc
  dismissal is app-runtime behavior (the DetailsDismiss hook rides
  app.js, which the storybook page doesn't load), so check it in the
  app chrome. One row per membership (#285 T6): the owned org renders
  as Personal — username, others as name + slug.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.org_switcher/1
  def render_source, do: :function

  def variations do
    # Plain maps with ids — the personal row is whichever org matches
    # personal_org_id (the chrome passes OrgNav's assigns).
    acme = %{organization: %{id: "org-acme", name: "Acme Collective", slug: "acme"}}
    oss = %{organization: %{id: "org-oss", name: "OSS Friends", slug: "oss-friends"}}
    personal = %{personal_org_id: "org-acme", username: "terence"}

    [
      # No id: here — PhoenixStorybook overwrites the :id assign with its
      # own variation_dom_id, so a story-level id is dead markup (gate-2
      # F6); uniqueness comes from the framework plus the component's
      # attr(:id) default.
      %Variation{
        id: :personal_only,
        description: "Single (personal) org — one row, labeled Personal — username (#285 T6)",
        attributes: Map.merge(personal, %{orgs: [acme]})
      },
      %Variation{
        id: :org_active,
        description:
          "Org context active — the closed summary names the org; below lg its initial leads the pill; the panel row is unchanged",
        attributes:
          Map.merge(personal, %{orgs: [acme], current_org: Map.get(acme, :organization)})
      },
      %Variation{
        id: :org_active_long,
        description:
          "Long org name active — the label truncates above lg, the initial leads below",
        attributes: %{
          orgs: [acme, oss],
          personal_org_id: "org-acme",
          username: "terence",
          current_org: %{name: "A Very Long Organization Display Name", slug: "very-long"}
        }
      },
      %Variation{
        id: :two_orgs,
        description:
          "Two memberships — one row each: Personal — username first (the owned org), name + slug for the rest",
        attributes: Map.merge(personal, %{orgs: [acme, oss]})
      }
    ]
  end
end
