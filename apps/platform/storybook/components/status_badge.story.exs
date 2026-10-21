defmodule FluxValeWeb.Storybook.Components.StatusBadge do
  @moduledoc """
  Status badge stories — one per instance state-machine state, pulsing
  dot on the in-motion ones.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.status_badge/1
  def render_source, do: :function

  def variations do
    [
      %VariationGroup{
        id: :states,
        description:
          "All lifecycle states (deploying/starting/deleting pulse; lost is the #196 anomaly)",
        variations:
          for status <-
                [:pending, :deploying, :starting, :running, :stopped, :error, :deleting, :lost] do
            %Variation{id: status, attributes: %{status: status}}
          end
      }
    ]
  end
end
