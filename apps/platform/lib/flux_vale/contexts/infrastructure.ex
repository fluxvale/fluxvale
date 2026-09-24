defmodule FluxVale.Infrastructure do
  @moduledoc """
  Infrastructure: the clusters FluxVale deploys onto — Cluster (#72), the
  home Instance lands in next (#73, ADR-0005 vocabulary). Admin-only
  surface (ADR-0027/ADR-0030); internal callers (seeds, the deploy flow
  #74) read placement with `authorize?: false` — global config, not
  actor-scoped data.
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource FluxVale.Infrastructure.Cluster
  end
end
