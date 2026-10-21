defmodule FluxValeWeb.Storybook.Components.Header do
  @moduledoc """
  Page header stories — title, subtitle, actions.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.header/1
  def render_source, do: :function
  def layout, do: :one_column

  # The actions slot composes <.button> — import it.
  def imports, do: [{FluxValeWeb.CoreComponents, button: 1}]

  def variations do
    [
      %Variation{
        id: :with_subtitle,
        description: "Title + subtitle",
        slots: [
          "Catalog",
          "<:subtitle>One click from browse to a running instance.</:subtitle>"
        ]
      },
      %Variation{
        id: :with_actions,
        description: "Title + actions",
        slots: [
          "Instances",
          """
          <:actions>
            <.button navigate="#" size="sm">Deploy an app</.button>
          </:actions>
          """
        ]
      }
    ]
  end
end
