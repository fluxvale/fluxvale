defmodule FluxValeWeb.Storybook.Components.BalanceHeader do
  @moduledoc """
  Balance-header stories — the billing surfaces' headline number (#276).
  The amount is integer cents; the variations pin the signed rendering
  (a minus only ever appears for an overdrawn wallet).
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.BillingComponents.balance_header/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :positive,
        description: "A credit balance (9_975¢)",
        attributes: %{balance: 9_975}
      },
      %Variation{
        id: :zero,
        description: "An untouched wallet",
        attributes: %{balance: 0}
      },
      %Variation{
        id: :negative,
        description: "Overdrawn — the minus sign renders",
        attributes: %{balance: -10_000}
      }
    ]
  end
end
