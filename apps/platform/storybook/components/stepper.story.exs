defmodule FluxValeWeb.Storybook.Components.Stepper do
  @moduledoc """
  Stepper stories — wizard progress (#178 wave 2). The working-register
  treatment (mono uppercase labels, amber `--focus` current chip,
  hairline rail, check-marked done discs) is the component's own since
  S8. The fourth variation sits the stepper on the deploy wizard's
  sunken band — the one surface where plain `--success` failed AA and
  `--success-deep` on done labels earns its keep.
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
      },
      %Variation{
        id: :on_sunken_band,
        description:
          "On the deploy wizard's sunken band — the surface that earned --success-deep on done labels (plain --success is 4.28:1 there; hostile-348 F4/F11)",
        attributes: %{steps: @steps, current: 2},
        template: """
        <div class="rounded-panel border border-line bg-panel-sunken p-6">
          <.psb-variation/>
        </div>
        """
      }
    ]
  end
end
