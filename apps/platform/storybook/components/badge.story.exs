defmodule FluxValeWeb.Storybook.Components.Badge do
  @moduledoc """
  Badge stories — metadata pills (category, size, price).
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.badge/1
  def render_source, do: :function

  def variations do
    [
      %VariationGroup{
        id: :tones,
        description: "All tones",
        variations:
          for tone <- ~w(neutral primary success warning danger) do
            %Variation{
              id: String.to_atom(tone),
              attributes: %{tone: tone},
              slots: [tone_label(tone)]
            }
          end
      },
      %Variation{
        id: :spec_sheet,
        description: "In situ: an instance spec row",
        slots: [
          """
          <div class="flex flex-wrap gap-2">
            <.badge>2 CPU</.badge>
            <.badge>2 GB RAM</.badge>
            <.badge>10 GB storage</.badge>
            <.badge tone="primary">$9.00/mo</.badge>
          </div>
          """
        ]
      }
    ]
  end

  defp tone_label("primary"), do: "$9/mo"
  defp tone_label("success"), do: "verified"
  defp tone_label("warning"), do: "expiring"
  defp tone_label("danger"), do: "past due"
  defp tone_label("neutral"), do: "Databases"
end
