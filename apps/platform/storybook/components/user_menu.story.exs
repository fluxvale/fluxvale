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
        attributes: %{username: "terence", email: "terence@fluxvale.com"}
      },
      %Variation{
        id: :no_username,
        description:
          "Rollout-window row (NULL username, #285 T4) — name line and glyph degrade to the address's local part",
        attributes: %{username: nil, email: "rollout.window@fluxvale.com"}
      },
      %Variation{
        id: :long_email,
        description: "A long address — the panel truncates, title carries the full value",
        attributes: %{
          username: "very-long-username-that-truncates-in-the-panel",
          email: "very-long-address-that-truncates@fluxvale.com"
        }
      },
      %Variation{
        id: :app_links,
        description:
          "App chrome below sm (#255): the header's Catalog/Instances links fold into the panel",
        attributes: %{username: "terence", email: "terence@fluxvale.com", app_links: true}
      }
    ]
  end
end
