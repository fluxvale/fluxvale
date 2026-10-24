defmodule FluxVale.Workers.BackupSweep do
  @moduledoc """
  The backup sweep's cron entry (#222, ADR-0037 §3): a
  `Infrastructure.sweep_backups/1` pass every five minutes, offset off
  the top (`6-59/5`) so it never lands with the reconciler's minute tick
  or the other sweeps' slots.

  Plumbing only — the due and watch decisions live on the operation (the
  sibling sweeps' shape). The clock is read here and passed in, so the
  operation's arithmetic stays a pure function of its arguments.
  """

  use Oban.Worker, queue: :backups, max_attempts: 3

  alias FluxVale.Infrastructure

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    # System pass, actorless: the reads and the finalize writes run
    # authorize?: false inside the operation (the lifecycle posture).
    case Infrastructure.sweep_backups(DateTime.utc_now()) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
