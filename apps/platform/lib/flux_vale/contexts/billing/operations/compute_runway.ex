defmodule FluxVale.Billing.Operations.ComputeRunway do
  @moduledoc """
  Projected runway for a wallet (#124): balance ÷ burn rate.

  Burn rate = the sum of the org's live rates, priced through the ONE
  resolver (`Pricing.settlement_rates/2` — the same one `settle_usage`
  bills by, #153): `:running` instances accrue the running rate,
  deployed-and-`:stopped` instances the storage-only rate (ADR-0028
  §2), everything else accrues nothing yet. Unpriced rows (no size AND
  no formula snapshot — pre-#121 drift or a hand-built half-snapshot)
  burn nothing, matching settle's forgiveness; a sizeless custom
  allocation burns at the live formula rate (#186); a
  resolver read failure fails the projection rather than under-burning
  silently. No instances → `:infinity` runway, no warning ever.

  The divisor is the average Gregorian month (2_629_746 s — #121's
  calendar-neutral constant, the one settle prorates by, pinned
  together by the agreement tests): a flat monthly rate divided across
  its own billing month.
  """

  alias FluxVale.Billing.Operations.ReadBalance
  alias FluxVale.Billing.Wallet
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing

  @seconds_per_month 2_629_746
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
    now = DateTime.utc_now()

    with {:ok, balance} <- ReadBalance.call(wallet, authorize?: false),
         instances = org_instances(wallet.organization_id),
         {:ok, burn} <- burn_micro_per_hour(instances, now) do
      runway = runway_hours(balance, burn)

      {:ok,
       %__MODULE__{
         balance_cents: balance,
         burn_micro_cents_per_hour: burn,
         runway_hours: runway
       }}
    end
  end

  defp org_instances(organization_id) do
    Instance
    |> Ash.Query.for_read(:list_for_organization, %{organization_id: organization_id},
      authorize?: false
    )
    |> Ash.read!()
  end

  defp burn_micro_per_hour(instances, now) do
    Enum.reduce_while(instances, {:ok, 0}, fn instance, {:ok, acc} ->
      accumulate(instance, acc, now)
    end)
  end

  defp accumulate(instance, acc, now) do
    case Pricing.settlement_rates(instance, now) do
      {:ok, nil} ->
        {:cont, {:ok, acc}}

      {:ok, rates} ->
        monthly = monthly_rate(instance, rates)
        {:cont, {:ok, acc + hourly_micro(monthly)}}

      # defensive: a resolver read failure is data corruption (the FK
      # has no ON DELETE) — fail the projection, never under-burn
      # silently; not simulatable without dropping the constraint
      # coveralls-ignore-start
      {:error, _reason} = error ->
        {:halt, error}
        # coveralls-ignore-stop
    end
  end

  defp monthly_rate(%Instance{status: :running}, rates), do: rates.running
  defp monthly_rate(%Instance{status: :stopped}, rates), do: rates.stopped

  # #203: a sleeping instance burns the storage-only rate — the same
  # stopped-rate accrual settlement runs on its anchors.
  defp monthly_rate(%Instance{status: :sleeping}, rates), do: rates.stopped

  # #222: a restoring instance is scaled to 0 with its volume still
  # mounted — settlement bills it at the stopped rate for the whole
  # restore (PerformSettle's running stream is closed by the leave-:running
  # transition), so the projection must price the same stream or the
  # wallet bleeds while the runway says infinity.
  defp monthly_rate(%Instance{status: :restoring}, rates), do: rates.stopped

  # pending/deploying/starting haven't started accruing; :error holds no
  # running meter (its anchors stopped at the transition); :deleting is
  # on the way out; :lost parks every anchor (#196) — zero burn.
  defp monthly_rate(_instance, _rates), do: 0

  defp hourly_micro(monthly_cents) do
    div(monthly_cents * @micro_per_cent * 3600, @seconds_per_month)
  end

  defp runway_hours(_balance, 0), do: :infinity

  defp runway_hours(balance_cents, burn_micro) do
    balance_micro = balance_cents * @micro_per_cent
    balance_micro / burn_micro
  end
end
