defmodule FluxVale.Infrastructure do
  @moduledoc """
  Infrastructure: the clusters FluxVale deploys onto and the Instances
  that run on them — Cluster (#72), Instance + its Oban triggers (#73,
  ADR-0005), the stranded-instance sweeper (#154). Admin-only surface
  for Cluster (ADR-0027/ADR-0030); Instances belong to the actor's
  organization (policies scope to org membership, #119). Internal
  callers (seeds, the deploy flow #74) read placement with
  `authorize?: false` — global config, not actor-scoped data.
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain]

  alias FluxVale.Infrastructure.Operations.ReadFileAccessCredential
  alias FluxVale.Infrastructure.Operations.SweepStrandedInstances

  admin do
    show?(true)
  end

  resources do
    resource(FluxVale.Infrastructure.Cluster)
    resource(FluxVale.Infrastructure.Instance)
  end

  defdelegate sweep_stranded_instances(), to: SweepStrandedInstances, as: :call

  # #190's reveal path — the instance page reads the WebDAV credential
  # from the cluster on demand; the Secret is its only home (ADR-0035).
  defdelegate read_file_access_credential(instance),
    to: ReadFileAccessCredential,
    as: :call
end
