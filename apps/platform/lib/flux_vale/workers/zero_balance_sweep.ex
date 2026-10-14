defmodule FluxVale.Workers.ZeroBalanceSweep do
  @moduledoc """
  Hourly Oban job walking the zero-balance ladder (#124): one
  `Billing.sweep_zero_balance/1` pass per wallet. Plumbing only — the
  ladder's decisions live on the operation (v1's janitor shape).

  Wallets sweep in isolation: one bad wallet is logged and skipped, not
  allowed to block every later wallet's warnings and stops — the job
  still fails after the loop so Oban retries the hour.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  alias FluxVale.Billing
  alias FluxVale.Billing.Wallet

  require Logger

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    # System read: the ladder walks every wallet there is.
    wallets = Ash.read!(Wallet, authorize?: false)

    failures =
      Enum.flat_map(wallets, fn wallet ->
        case safe_sweep(wallet) do
          :ok ->
            []

          {:error, reason} ->
            Logger.error("Zero-balance sweep failed for wallet #{wallet.id}: #{inspect(reason)}")

            [wallet.id]
        end
      end)

    case failures do
      [] ->
        :ok

      _failed ->
        {:error, "zero-balance sweep failed for #{length(failures)} wallet(s)"}
    end
  end

  # A crash in one wallet's pass must not eat the rest of the fleet.
  defp safe_sweep(wallet) do
    case Billing.sweep_zero_balance(wallet) do
      {:ok, _summary} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end
end
