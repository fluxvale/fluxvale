defmodule FluxVale.Workers.RechargeSweep do
  @moduledoc """
  Hourly Oban job for the auto-recharge reminder sweep (#829 L2): one
  `Billing.sweep_auto_recharge/0` pass over every org armed in
  `:reminder` mode. Plumbing only — the sweep's decisions and its
  per-org isolation live on the operation; a failed pass fails this job
  so Oban retries the hour.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  alias FluxVale.Billing

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    case Billing.sweep_auto_recharge() do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
