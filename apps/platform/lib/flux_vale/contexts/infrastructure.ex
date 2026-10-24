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

  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Operations.ConfigureBackups
  alias FluxVale.Infrastructure.Operations.ReadFileAccessCredential
  alias FluxVale.Infrastructure.Operations.RestoreInstanceBackup
  alias FluxVale.Infrastructure.Operations.RestoreServingEdge
  alias FluxVale.Infrastructure.Operations.RunInstanceBackup
  alias FluxVale.Infrastructure.Operations.SweepBackups
  alias FluxVale.Infrastructure.Operations.SweepIdleInstances
  alias FluxVale.Infrastructure.Operations.SweepStrandedInstances
  alias FluxVale.Infrastructure.Operations.WakeInstance

  admin do
    show?(true)
  end

  resources do
    resource(FluxVale.Infrastructure.Cluster)
    resource(FluxVale.Infrastructure.Instance)
    resource(FluxVale.Infrastructure.BackupSetting)
    resource(FluxVale.Infrastructure.BackupRun)
  end

  defdelegate sweep_stranded_instances(), to: SweepStrandedInstances, as: :call

  # #203 (ADR-0036): the idle sweep — sleeps visitor-less :running
  # instances (the sweep worker's entry).
  defdelegate sweep_idle_instances(), to: SweepIdleInstances, as: :call

  # #203: the anonymous edge's wake and restore — the wake endpoint's
  # entries (the funded gate and the route flip live on the ops).
  defdelegate wake_instance(instance), to: WakeInstance, as: :call
  defdelegate restore_serving_edge(instance), to: RestoreServingEdge, as: :call

  # #190's reveal path — the instance page reads the WebDAV credential
  # from the cluster on demand; the Secret is its only home (ADR-0035).
  defdelegate read_file_access_credential(instance),
    to: ReadFileAccessCredential,
    as: :call

  # #222 (ADR-0037): saving the backup destination — composes the repo
  # URL, get-or-creates the namespace's `backup-config` Secret, widens
  # the quota, then upserts the setting row.
  defdelegate configure_backups(instance, params, opts \\ []),
    to: ConfigureBackups,
    as: :call

  # The UI's "stop backing up entirely": a plain row delete (the
  # resource's `:destroy`, member-policied like `:update`) — no cluster
  # state, and the namespace Secret persists so re-configuring reuses
  # the same restic repo.
  defdelegate remove_backup_settings(setting, opts \\ []),
    to: BackupSetting,
    as: :destroy

  # #222 (ADR-0037 §3): one backup run — the manual "Back up now" and the
  # sweep's due pass share this one operation; only the kind differs.
  defdelegate run_instance_backup(instance, kind),
    to: RunInstanceBackup,
    as: :call

  # #222 (ADR-0037 §3): the backup sweep's due + watch passes, every five
  # minutes (`Workers.BackupSweep`). `now` is a parameter — the worker
  # reads the clock, tests pass fixed instants.
  defdelegate sweep_backups(now), to: SweepBackups, as: :call

  # #222 (ADR-0037 §5): restores the instance's newest successful snapshot
  # back over its own volume — the sweep's watch pass finalizes it. `opts`
  # carry the caller's `actor:` (ownership is enforced before any cluster
  # write); the sweep's recovery arm calls it actorless.
  defdelegate restore_instance_backup(instance, opts \\ []),
    to: RestoreInstanceBackup,
    as: :call
end
