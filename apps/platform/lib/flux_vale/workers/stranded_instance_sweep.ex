defmodule FluxVale.Workers.StrandedInstanceSweep do
  @moduledoc """
  Hourly Oban job sweeping stranded instances to a terminal state
  (#154): one `Infrastructure.sweep_stranded_instances/0` pass.
  Plumbing only — the arms' decisions live on the operation (the
  ZeroBalanceSweep shape).
  """

  use Oban.Worker, queue: :janitor, max_attempts: 3

  alias FluxVale.Infrastructure

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    # System pass, actorless: reads and status writes run authorize?:
    # false inside the operation; the trigger re-enqueues ride the
    # AshOban interaction bypass (the lifecycle posture, see Instance's
    # policies).
    case Infrastructure.sweep_stranded_instances() do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
