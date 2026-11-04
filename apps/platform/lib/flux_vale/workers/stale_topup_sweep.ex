defmodule FluxVale.Workers.StaleTopupSweep do
  @moduledoc """
  Hourly Oban job expiring stale pending top-ups (#364): one
  `Billing.expire_stale_topups/0` pass. Plumbing only — the policy
  (TTL, terminal-once) lives on the operation (v1's janitor shape).

  The pass is one bulk statement, so there is nothing to isolate per
  row — a crash fails the job and Oban retries it whole.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  alias FluxVale.Billing
  alias FluxVale.Billing.TopupOutcomeMail

  require Logger

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    case safe_sweep() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Stale top-up sweep failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp safe_sweep do
    case Billing.expire_stale_topups() do
      # The expired rows are the sweep's fresh transitions — the
      # not-completed outcome mail rides each (#377). A mail failure
      # logs inside the mail layer and never fails the hour's job.
      {:ok, expired} ->
        Enum.each(expired, &TopupOutcomeMail.deliver_not_completed/1)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end
end
