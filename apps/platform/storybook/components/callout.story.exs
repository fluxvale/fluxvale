defmodule FluxValeWeb.Storybook.Components.Callout do
  @moduledoc """
  Callout stories — inline notices (#178 wave 2).
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.callout/1
  def render_source, do: :function
  def layout, do: :one_column

  def template do
    """
    <div class="max-w-md space-y-3"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %VariationGroup{
        id: :tones,
        description: "All tones",
        variations: [
          %Variation{
            id: :info,
            attributes: %{tone: "info", title: "First open"},
            slots: ["Registration is open on first boot — the first account becomes admin."]
          },
          %Variation{
            id: :warning,
            attributes: %{tone: "warning", title: "Below the recommendation"},
            slots: ["It may run slowly or fail."]
          },
          %Variation{
            id: :danger,
            attributes: %{tone: "danger", title: "Deploy failed"},
            slots: ["Check your wallet balance and try again."]
          },
          %Variation{
            id: :success,
            attributes: %{tone: "success", title: "Payment received"},
            slots: ["Credit was added to your balance."]
          }
        ]
      },
      %Variation{
        id: :no_title,
        description: "Body-only",
        attributes: %{tone: "warning"},
        slots: ["This is below what the app recommends."]
      }
    ]
  end
end
