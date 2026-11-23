defmodule FluxVale.Janitor.PruneDeviceGrants do
  @moduledoc """
  Daily Oban job sweeping expired OAuth device grants (#886), the
  PruneOAuthCodes plumbing shape — the business logic lives on
  `FluxVale.OAuth.prune_device_grants/1`.
  """

  use Oban.Worker, queue: :janitor, max_attempts: 3

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    FluxVale.OAuth.prune_device_grants(authorize?: false)
  end
end
