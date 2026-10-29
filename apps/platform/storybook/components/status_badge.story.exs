defmodule FluxValeWeb.Storybook.Components.StatusBadge do
  @moduledoc """
  Status badge stories — one per state-machine state, pulsing dot on
  the in-motion ones. Both machines the component serves: the
  Instance's and the AccessGateway's (ADR-0039).
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.status_badge/1
  def render_source, do: :function

  def variations do
    [
      %VariationGroup{
        id: :states,
        description:
          "All lifecycle states (deploying/starting/deleting pulse; sleeping is #203's resting state; lost is the #196 anomaly)",
        variations:
          for status <-
                [
                  :pending,
                  :deploying,
                  :starting,
                  :running,
                  :sleeping,
                  :stopped,
                  :error,
                  :deleting,
                  :lost
                ] do
            %Variation{id: status, attributes: %{status: status}}
          end
      },
      %VariationGroup{
        id: :gateway_states,
        description:
          "AccessGateway states (ADR-0039): connecting/removing pulse; needs_attention is the owner's to fix; suspended is the ladder's resting neutral",
        variations:
          for status <-
                [:provisioning, :active, :needs_attention, :suspended, :destroying] do
            %Variation{id: status, attributes: %{status: status}}
          end
      }
    ]
  end
end
