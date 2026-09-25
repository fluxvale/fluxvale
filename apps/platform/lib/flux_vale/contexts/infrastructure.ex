defmodule FluxVale.Infrastructure do
  @moduledoc """
  Infrastructure: the clusters FluxVale deploys onto and the Instances
  that run on them — Cluster (#72), Instance + its Oban triggers (#73,
  ADR-0005). Admin-only surface for Cluster (ADR-0027/ADR-0030);
  Instances are user-owned (policies scope to the owner). Internal
  callers (seeds, the deploy flow #74) read placement with
  `authorize?: false` — global config, not actor-scoped data.
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource FluxVale.Infrastructure.Cluster
    resource FluxVale.Infrastructure.Instance
  end
end
