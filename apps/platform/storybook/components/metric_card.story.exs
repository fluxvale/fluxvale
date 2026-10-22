defmodule FluxValeWeb.Storybook.Components.MetricCard do
  @moduledoc """
  Metric-card stories (#205): the dashboard's single-value cards —
  balance and runway, plus the shape later widgets reuse.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.metric_card/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :balance,
        description: "Balance — the signed-in home's money card",
        attributes: %{
          label: "Balance",
          value: "$3.00",
          hint: "Credits never expire."
        }
      },
      %Variation{
        id: :runway,
        description: "Runway — finite burn",
        attributes: %{
          label: "Runway",
          value: "≈ 2 months",
          hint: "at $4.10/mo current burn"
        }
      },
      %Variation{
        id: :runway_infinite,
        description: "Runway — nothing deployed, nothing burning",
        attributes: %{
          label: "Runway",
          value: "No active burn",
          hint: "Your first deploy starts the meter."
        }
      }
    ]
  end
end
