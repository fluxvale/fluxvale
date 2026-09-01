defmodule FluxValeWeb.HealthJSON do
  @moduledoc """
  JSON for `/health` and `/health/ready` — `{status, version}`, where
  `version` is the build SHA the deploy pipeline polls for
  (docs/deployment.md).
  """

  def show(%{status: status}) do
    %{status: status, version: FluxVale.Build.version()}
  end
end
