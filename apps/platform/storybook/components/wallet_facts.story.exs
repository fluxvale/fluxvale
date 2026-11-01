defmodule FluxValeWeb.Storybook.Components.WalletFacts do
  @moduledoc """
  Wallet-facts stories — the billing band's in-band facts pair (S9,
  the S4/S6 eyebrow posture). The projection is
  `Billing.compute_runway/1`; the variations pin the runway formatter's
  headline arms (months, no-burn, depleted) and the signed balance (a
  minus only ever appears for an overdrawn wallet).
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.BillingComponents.wallet_facts/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :healthy,
        description: "A credit balance with months of runway ($1/h burn)",
        attributes: %{facts: facts(9_975, 9_975, 10_000)}
      },
      %Variation{
        id: :no_burn,
        description: "An untouched wallet — the infinite runway reads itself",
        attributes: %{facts: facts(0, :infinity, 0)}
      },
      %Variation{
        id: :depleted,
        description: "Overdrawn — Depleted, and the balance carries the minus",
        attributes: %{facts: facts(-10_000, 0.0, 10_000)}
      }
    ]
  end

  # Storybook has no database; the projection struct is hand-built the
  # same way the backup-run row stories build theirs.
  defp facts(balance_cents, runway_hours, burn_micro_cents_per_hour) do
    %FluxVale.Billing.Operations.ComputeRunway{
      balance_cents: balance_cents,
      runway_hours: runway_hours,
      burn_micro_cents_per_hour: burn_micro_cents_per_hour
    }
  end
end
