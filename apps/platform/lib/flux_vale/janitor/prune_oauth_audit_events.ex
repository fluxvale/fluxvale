defmodule FluxVale.Janitor.PruneOAuthAuditEvents do
  @moduledoc """
  Daily Oban job sweeping OAuth audit rows past their 90-day horizon
  (#766), the PruneAuditEvents plumbing shape.
  """

  use Oban.Worker, queue: :janitor, max_attempts: 3

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    FluxVale.OAuth.prune_audit_events(authorize?: false)
  end
end
