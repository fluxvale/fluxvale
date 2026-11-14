defmodule FluxVale.Janitor.PruneOAuthCodes do
  @moduledoc """
  Daily Oban job sweeping expired OAuth authorization codes (#766),
  the PruneAuditEvents plumbing shape — the business logic lives on
  `FluxVale.OAuth.prune_codes/1`.
  """

  use Oban.Worker, queue: :janitor, max_attempts: 3

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    FluxVale.OAuth.prune_codes(authorize?: false)
  end
end
