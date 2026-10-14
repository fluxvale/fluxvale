defmodule FluxVale.Billing.Operations.ComputeRunway do
  @moduledoc """
  Projected runway for a wallet (#124): balance ÷ burn rate.

  Burn rate = the sum of the org's live rates (the pricing table's
  #127 mapping, the same one accrual will settle against — one helper
  to reconcile when #121 lands): `:running` instances accrue
  `recommended_size.monthly_cents`, deployed-and-`:stopped` instances
  accrue `stopped_monthly_cents` (ADR-0028 §2 — the storage-only fee),
  everything else accrues nothing yet. No instances → `:infinity`
  runway, no warning ever.

  A 30-day month (720h) is the divisor — a flat monthly rate divided
  across its own billing month; calendar-month drift is sub-1% noise
  next to the 24h threshold it feeds.
  """

  alias FluxVale.Billing.Operations.ReadBalance
  alias FluxVale.Billing.Wallet
  alias FluxVale.Infrastructure.Instance

  @hours_per_month 24 * 30
  @micro_per_cent 10_000

  @enforce_keys [:balance_cents, :burn_micro_cents_per_hour, :runway_hours]
  defstruct [:balance_cents, :burn_micro_cents_per_hour, :runway_hours]

  @type t :: %__MODULE__{
          balance_cents: integer(),
          burn_micro_cents_per_hour: non_neg_integer(),
          runway_hours: float() | :infinity
        }

  @spec call(Wallet.t()) :: {:ok, t()} | {:error, term()}
  def call(%Wallet{} = wallet) do
    with {:ok, balance} <- ReadBalance.call(wallet, authorize?: false) do
      instances =
        Instance
        |> Ash.Query.for_read(:list_for_organization, %{organization_id: wallet.organization_id},
          authorize?: false
        )
        |> Ash.Query.load(app_version: :recommended_size)
        |> Ash.read!()

      burn = burn_micro_per_hour(instances)
      runway = runway_hours(balance, burn)

      {:ok,
       %__MODULE__{
         balance_cents: balance,
         burn_micro_cents_per_hour: burn,
         runway_hours: runway
       }}
    end
  end

  defp burn_micro_per_hour(instances) do
    Enum.reduce(instances, 0, &rate_micro_per_hour/2)
  end

  defp rate_micro_per_hour(%Instance{status: :running} = instance, acc) do
    acc + monthly_to_micro(instance.app_version.recommended_size.monthly_cents)
  end

  defp rate_micro_per_hour(%Instance{status: :stopped} = instance, acc) do
    acc + monthly_to_micro(instance.app_version.recommended_size.stopped_monthly_cents)
  end

  # pending/deploying/starting haven't started accruing; :error holds no
  # running meter (its anchors stopped at the transition); :deleting is
  # on the way out.
  defp rate_micro_per_hour(_instance, acc), do: acc

  defp monthly_to_micro(monthly_cents) do
    div(monthly_cents * @micro_per_cent, @hours_per_month)
  end

  defp runway_hours(_balance, 0), do: :infinity

  defp runway_hours(balance_cents, burn_micro) do
    balance_micro = balance_cents * @micro_per_cent
    balance_micro / burn_micro
  end
end
