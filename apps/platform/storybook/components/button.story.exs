defmodule FluxValeWeb.Storybook.Components.Button do
  @moduledoc """
  Button stories — the system's action component.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.button/1
  def render_source, do: :function

  def variations do
    [
      %VariationGroup{
        id: :variants,
        description:
          "The four variants — hover lifts the primary's elevation; active presses down 1px with an elevation step-down",
        variations: [
          %Variation{id: :primary, attributes: %{}, slots: ["Deploy"]},
          %Variation{id: :secondary, attributes: %{variant: "secondary"}, slots: ["Cancel"]},
          %Variation{id: :ghost, attributes: %{variant: "ghost"}, slots: ["Back"]},
          %Variation{
            id: :destructive,
            attributes: %{variant: "destructive"},
            slots: ["Delete"]
          }
        ]
      },
      %VariationGroup{
        id: :sizes,
        description: "Sizes (sm for table rows/toolbars, md default, lg for heroes)",
        variations: [
          %Variation{id: :sm, attributes: %{size: "sm"}, slots: ["Small"]},
          %Variation{id: :md, attributes: %{size: "md"}, slots: ["Medium"]},
          %Variation{id: :lg, attributes: %{size: "lg"}, slots: ["Large"]}
        ]
      },
      %Variation{
        id: :disabled,
        description:
          "Disabled state — ink-subtle on panel-raised (5.51:1 light / 4.77:1 dark), flat, pointer-inert. Also the loading visual: phx-disable-with swaps the button to this state mid-request.",
        attributes: %{disabled: true},
        slots: ["Deploying…"]
      },
      %Variation{
        id: :as_link,
        description: "Renders <a> when given href/navigate/patch",
        attributes: %{href: "#", variant: "secondary"},
        slots: ["Open docs ↗"]
      }
    ]
  end
end
