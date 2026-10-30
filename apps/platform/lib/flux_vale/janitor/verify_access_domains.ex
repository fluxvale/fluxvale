defmodule FluxVale.Janitor.VerifyAccessDomains do
  @moduledoc """
  The verify-by-issuance pass for access domains (ADR-0040 S1), every
  15 minutes via `Oban.Plugins.Cron` (config.exs). Plumbing only — the
  business logic lives on
  `FluxVale.Infrastructure.verify_access_domains/1` (the PruneExpiredTokens
  shape).
  """

  use Oban.Worker, queue: :janitor, max_attempts: 3

  alias FluxVale.Infrastructure

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    Infrastructure.verify_access_domains(authorize?: false)
  end
end
