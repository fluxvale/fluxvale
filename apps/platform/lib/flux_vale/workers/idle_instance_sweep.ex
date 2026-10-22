defmodule FluxVale.Workers.IdleInstanceSweep do
  @moduledoc """
  Scale-to-zero sweep (#203, ADR-0036): a
  `Infrastructure.sweep_idle_instances/0` pass every 5 minutes — the
  1-hour idle promise rounds to at most a threshold + one cadence.
  Plumbing only — the sleep decision lives on the operation (the
  sibling sweeps' shape).
  """

  use Oban.Worker, queue: :janitor, max_attempts: 3

  alias FluxVale.Infrastructure

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    # System pass, actorless: reads and the :sleep action run
    # authorize?: false inside the operation (the lifecycle posture,
    # see Instance's policies).
    case Infrastructure.sweep_idle_instances() do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
