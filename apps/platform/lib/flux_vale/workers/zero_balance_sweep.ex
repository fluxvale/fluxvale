defmodule FluxVale.Workers.ZeroBalanceSweep do
  @moduledoc """
  Hourly Oban job walking the zero-balance ladder (#124): one
  `Billing.sweep_zero_balance/1` pass per wallet. Plumbing only — the
  ladder's decisions live on the operation (v1's janitor shape).

  A wallet's failure fails the job (Oban retries the hour); passes are
  per-wallet transactions, so committed wallets stay committed.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  alias FluxVale.Billing
  alias FluxVale.Billing.Wallet

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    # System read: the ladder walks every wallet there is.
    wallets = Ash.read!(Wallet, authorize?: false)

    Enum.each(wallets, fn wallet ->
      {:ok, _summary} = Billing.sweep_zero_balance(wallet)
    end)

    :ok
  end
end
