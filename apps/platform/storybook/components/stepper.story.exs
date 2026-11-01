defmodule FluxValeWeb.Storybook.Components.Stepper do
  @moduledoc """
  Stepper stories — wizard progress (#178 wave 2). The working-register
  treatment (mono uppercase labels, amber `--focus` current chip and
  traveled rail, hairline rail) is the component's own since S8.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.stepper/1
  def render_source, do: :function
  def layout, do: :one_column

  @steps [
    {"details", "Billing details"},
    {"amount", "Amount"},
    {"payment", "Payment"},
    {"confirmation", "Confirmation"}
  ]

  def variations do
    [
      %Variation{
        id: :first_step,
        description: "At the first step",
        attributes: %{steps: @steps, current: 0}
      },
      %Variation{
        id: :mid_flow,
        description: "Mid-flow (the top-up at payment)",
        attributes: %{steps: @steps, current: 2}
      },
      %Variation{
        id: :with_testids,
        description: "With testid prefix (emits topup-step-* for the tests)",
        attributes: %{steps: @steps, current: 1, testid_prefix: "topup"}
      }
    ]
  end
end
