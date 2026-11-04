defmodule FluxVale.Janitor.PruneDeviceCodes do
  @moduledoc """
  Daily Oban job sweeping dead device-flow rows (#362 T3).

  Scheduled at 03:45 UTC via `Oban.Plugins.Cron` (config.exs) — off
  the 03:00 token prune, the 03:15 window sweep and the 03:30 audit
  sweep (queue concurrency is 1; the stagger keeps the quartet from
  bunching behind one lock). Plumbing only — the business logic lives
  on `FluxVale.Identity.prune_device_codes/1` (PruneRequestWindows'
  shape).
  """

  use Oban.Worker, queue: :janitor, max_attempts: 3

  alias FluxVale.Identity

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    Identity.prune_device_codes(authorize?: false)
  end
end
