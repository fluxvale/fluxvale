defmodule FluxVale.Janitor.PruneRequestWindows do
  @moduledoc """
  Daily Oban job sweeping stale rows from the API rate-limit windows
  (#360 slice 3).

  Scheduled at 03:15 UTC via `Oban.Plugins.Cron` (config.exs) — off
  the 03:00 token prune. Plumbing only — the business logic lives on
  `FluxVale.Api.prune_request_windows/1` (PruneExpiredTokens' shape).
  """

  use Oban.Worker, queue: :janitor, max_attempts: 3

  alias FluxVale.Api

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    Api.prune_request_windows(authorize?: false)
  end
end
