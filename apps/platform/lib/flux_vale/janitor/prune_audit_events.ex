defmodule FluxVale.Janitor.PruneAuditEvents do
  @moduledoc """
  Daily Oban job sweeping API audit events past their retention
  horizon (#360 slice 5).

  Scheduled at 03:30 UTC via `Oban.Plugins.Cron` (config.exs) — off
  the 03:00 token prune and the 03:15 request-window sweep (queue
  concurrency is 1; the stagger keeps the trio from bunching behind
  one lock). Plumbing only — the business logic lives on
  `FluxVale.Api.prune_audit_events/1` (PruneRequestWindows' shape).
  """

  use Oban.Worker, queue: :janitor, max_attempts: 3

  alias FluxVale.Api

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    Api.prune_audit_events(authorize?: false)
  end
end
