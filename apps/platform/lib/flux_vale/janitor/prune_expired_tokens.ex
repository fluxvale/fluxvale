defmodule FluxVale.Janitor.PruneExpiredTokens do
  @moduledoc """
  Daily Oban job pruning expired rows from the `tokens` table.

  Scheduled at 03:00 UTC via `Oban.Plugins.Cron` (config.exs). Plumbing
  only — the business logic lives on
  `FluxVale.Identity.prune_expired_tokens/1` (v1's shape, ported — #23).
  """

  use Oban.Worker, queue: :janitor, max_attempts: 3

  alias FluxVale.Identity

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    Identity.prune_expired_tokens(authorize?: false)
  end
end
