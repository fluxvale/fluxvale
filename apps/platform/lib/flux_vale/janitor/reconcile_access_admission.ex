defmodule FluxVale.Janitor.ReconcileAccessAdmission do
  @moduledoc """
  The access edge's admission pass (ADR-0040 Am. 6), every minute via
  `Oban.Plugins.Cron` (config.exs) on its own serial queue — the
  one-minute bound must not wait behind the janitor queue's other
  passes. Plumbing only — the business logic lives on
  `FluxVale.Infrastructure.reconcile_access_admission/1` (the
  VerifyAccessDomains shape).
  """

  use Oban.Worker, queue: :access_admission, max_attempts: 3

  alias FluxVale.Infrastructure

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    Infrastructure.reconcile_access_admission()
  end
end
