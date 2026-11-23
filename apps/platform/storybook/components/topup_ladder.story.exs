defmodule FluxValeWeb.Storybook.Components.TopupLadder do
  @moduledoc """
  Top-up ladder stories — the fixed quick-pick amounts (#888): a fresh
  row with nothing pressed, a rung pressed, and a custom amount above
  the ladder (nothing pressed; the custom amount lives in the field
  beside the row).
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.BillingComponents.topup_ladder/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :none, description: "Fresh: no rung pressed", attributes: attrs(nil)},
      %Variation{id: :rung, description: "$10 pressed", attributes: attrs(10)},
      %Variation{
        id: :custom,
        description: "A custom amount above the ladder: nothing pressed",
        attributes: attrs(25)
      }
    ]
  end

  defp attrs(selected) do
    %{
      id: "story-topup-amount",
      rungs: FluxVale.Billing.topup_ladder_dollars(),
      selected: selected,
      event: "pick-amount",
      label: "Quick amounts"
    }
  end
end
