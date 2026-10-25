defmodule FluxValeWeb.Storybook.Components.UserMenu do
  @moduledoc """
  User-menu stories (#205): the signed-in chrome's avatar dropdown.
  Open one to see the panel — a native <details>, so the storybook's
  own chrome exercises the toggle exactly like the app's.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.user_menu/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :default,
        description: "Resting state — avatar bubble + chevron",
        attributes: %{email: "terence@fluxvale.com"}
      },
      %Variation{
        id: :long_email,
        description: "A long address — the panel truncates, title carries the full value",
        attributes: %{email: "very-long-address-that-truncates@fluxvale.com"}
      },
      %Variation{
        id: :app_links,
        description:
          "App chrome below sm (#255): the header's Catalog/Instances links fold into the panel",
        attributes: %{email: "terence@fluxvale.com", app_links: true}
      }
    ]
  end
end
