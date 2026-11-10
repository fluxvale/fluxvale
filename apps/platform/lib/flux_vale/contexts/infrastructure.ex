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

  # AshJsonApi.Domain (#360): the resource-level json_api blocks ride
  # the domain through AshJsonApiRouter — routes are contract
  # (ADR-0019 §1).
  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain, AshJsonApi.Domain, AshPaperTrail.Domain]

  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Operations.ApproveStorageRequest
  alias FluxVale.Infrastructure.Operations.AttachInstance
  alias FluxVale.Infrastructure.Operations.ClaimAccessDomain
  alias FluxVale.Infrastructure.Operations.ConfigureBackups
  alias FluxVale.Infrastructure.Operations.ConnectPocketId
  alias FluxVale.Infrastructure.Operations.DetachInstance
  alias FluxVale.Infrastructure.Operations.ObserveAccessGateway
  alias FluxVale.Infrastructure.Operations.ProbePocketIdSetup
  alias FluxVale.Infrastructure.Operations.ReadBackupCredential
  alias FluxVale.Infrastructure.Operations.ReadFileAccessCredential
  alias FluxVale.Infrastructure.Operations.RegisterAccessDomain
  alias FluxVale.Infrastructure.Operations.RejectStorageRequest
  alias FluxVale.Infrastructure.Operations.RemoveAccessDomain
  alias FluxVale.Infrastructure.Operations.ResizePreview
  alias FluxVale.Infrastructure.Operations.RestoreInstanceBackup
  alias FluxVale.Infrastructure.Operations.RestoreServingEdge
  alias FluxVale.Infrastructure.Operations.RetryStorageRequest
  alias FluxVale.Infrastructure.Operations.RevokePocketIdKey
  alias FluxVale.Infrastructure.Operations.RunInstanceBackup
  alias FluxVale.Infrastructure.Operations.SetAccessApiToken
  alias FluxVale.Infrastructure.Operations.SetPocketIdKey
  alias FluxVale.Infrastructure.Operations.StorageExpansion
  alias FluxVale.Infrastructure.Operations.SweepBackups
  alias FluxVale.Infrastructure.Operations.SweepIdleInstances
  alias FluxVale.Infrastructure.Operations.SweepStrandedInstances
  alias FluxVale.Infrastructure.Operations.UnclaimAccessDomain
  alias FluxVale.Infrastructure.Operations.UsePocketIdKey
  alias FluxVale.Infrastructure.Operations.VerifyAccessDomains
  alias FluxVale.Infrastructure.Operations.WakeInstance

  admin do
    show?(true)

    # #250 (ADR-0046 D5): the raw storage-request table stays out of the
    # generic AshAdmin surface — its state machine only advances through
    # the apply (an AshAdmin retry would run `:retry_apply` without the
    # volume patch and strand the row approved). The operator queue at
    # /admin/storage-requests is its surface (S5). AshAdmin 1.x hides
    # resources at the domain level (`show_resources`); there is no
    # per-resource `show?`.
    show_resources([
      FluxVale.Infrastructure.Cluster,
      FluxVale.Infrastructure.Instance,
      FluxVale.Infrastructure.InstanceAllocationSnapshot,
      FluxVale.Infrastructure.BackupSetting,
      FluxVale.Infrastructure.BackupRun,
      FluxVale.Infrastructure.AccessGateway,
      FluxVale.Infrastructure.AccessRoute,
      FluxVale.Infrastructure.AccessDomain,
      FluxVale.Infrastructure.InstanceHostname,
      FluxVale.Infrastructure.PocketIdCustody,
      FluxVale.Infrastructure.PocketIdCustodyEvent
    ])
  end

  # The paper-trail seam (#645, ADR-0048): versioned resources' Version
  # modules join the domain here so codegen migrates them and reads see
  # them. The console registry excludes them by name — the audit trail
  # surfaces in its own section, not as raw tables.
  paper_trail do
    include_versions?(true)
  end

  resources do
    resource(FluxVale.Infrastructure.Cluster)
    resource(FluxVale.Infrastructure.Instance)
    resource(FluxVale.Infrastructure.InstanceAllocationSnapshot)
    resource(FluxVale.Infrastructure.BackupSetting)
    resource(FluxVale.Infrastructure.BackupRun)
    resource(FluxVale.Infrastructure.AccessGateway)
    resource(FluxVale.Infrastructure.AccessRoute)
    resource(FluxVale.Infrastructure.AccessDomain)
    resource(FluxVale.Infrastructure.InstanceHostname)
    resource(FluxVale.Infrastructure.PocketIdCustody)
    resource(FluxVale.Infrastructure.PocketIdCustodyEvent)
    resource(FluxVale.Infrastructure.PocketIdWiring)
    resource(FluxVale.Infrastructure.StorageRequest)
  end

  defdelegate sweep_stranded_instances(), to: SweepStrandedInstances, as: :call

  # #203 (ADR-0036): the idle sweep — sleeps visitor-less :running
  # instances (the sweep worker's entry).
  defdelegate sweep_idle_instances(), to: SweepIdleInstances, as: :call

  # #268 (ADR-0039): the private-access pair — attach/detach an instance
  # to the org's gateway, and the observed-state read the panel's badge
  # (and the billing arm) ride on.
  defdelegate attach_instance(gateway, instance, opts \\ []),
    to: AttachInstance,
    as: :call

  defdelegate detach_instance(gateway, instance, opts \\ []),
    to: DetachInstance,
    as: :call

  defdelegate observe_access_gateway(gateway), to: ObserveAccessGateway, as: :call

  # ADR-0040 S1: the custom-access-domain trio — register (row + the
  # wildcard Certificate, one transaction), the verify-by-issuance
  # observation pass, and removal. The pass runs authorize?-free by
  # construction; register/remove carry the caller's actor/authorize?
  # (ownership enforced inside).
  defdelegate register_access_domain(params, opts \\ []), to: RegisterAccessDomain, as: :call

  defdelegate verify_access_domains(opts \\ []), to: VerifyAccessDomains, as: :call

  defdelegate remove_access_domain(domain, opts \\ []), to: RemoveAccessDomain, as: :call

  # ADR-0040 S3: the tailnet-claiming seam — store the API token (the
  # §5 intake; the form is a later slice), claim a verified domain on
  # the gateway's tailnet, and the mirror. All three carry the caller's
  # actor/authorize? (membership enforced by the authorized reads
  # inside).
  defdelegate set_access_api_token(gateway, token, opts \\ []),
    to: SetAccessApiToken,
    as: :call

  defdelegate claim_access_domain(gateway, domain, opts \\ []),
    to: ClaimAccessDomain,
    as: :call

  defdelegate unclaim_access_domain(gateway, domain, opts \\ []),
    to: UnclaimAccessDomain,
    as: :call

  # #597 S2 (§4.3): the PocketID admin-key custody trio — store
  # (live-verified paste, Secret first then row), the audited key-use
  # seam S4/S5 consume, and revoke. All three carry the caller's
  # actor/authorize? (ownership enforced inside, the
  # set_access_api_token stance).
  defdelegate set_pocket_id_key(instance, api_key, opts \\ []),
    to: SetPocketIdKey,
    as: :call

  defdelegate use_pocket_id_key(custody, purpose, opts \\ []),
    to: UsePocketIdKey,
    as: :call

  defdelegate revoke_pocket_id_key(instance, opts \\ []),
    to: RevokePocketIdKey,
    as: :call

  # Opt-out (#268): the async teardown entry. The action flips
  # :destroying and enqueues the trigger; the resource owns both.
  defdelegate delete_access_gateway(id, opts \\ []),
    to: FluxVale.Infrastructure.AccessGateway,
    as: :delete

  # #493: the resize panel's two reads — the preview (what a resize
  # WOULD snapshot, the action's own pricing choice) and the storage
  # -expansion capability (the panel's storage lock; probe errors ride
  # the same honest lock as a real no).
  defdelegate resize_preview(instance, allocation), to: ResizePreview, as: :call

  defdelegate storage_expansion_capable?(instance), to: StorageExpansion, as: :capable?

  # #250 (ADR-0046): the storage-request workflow's operator seam — the
  # approve decision + apply, the rejection with member-visible
  # feedback, and the apply retry. All three carry the actor; the
  # request's own policies are the operator gate.
  defdelegate approve_storage_request(actor, request_id),
    to: ApproveStorageRequest,
    as: :call

  defdelegate reject_storage_request(actor, request_id, feedback),
    to: RejectStorageRequest,
    as: :call

  defdelegate retry_storage_request(actor, request_id),
    to: RetryStorageRequest,
    as: :call

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

  # #482: the BackupSetting JSON:API routes' save converges the cluster
  # with the row through the same entrypoint the panel's save uses —
  # the `backup-config` Secret (blank/absent request secret keeps the
  # stored password/key; the repo URL recomputes from the changeset's
  # coordinates) plus the backup margin quota. The caller must have
  # authorized ownership already: this performs cluster writes. `opts`
  # carry `fresh_secret: :optional` — the routes' deliberate
  # permissive-fresh difference from the panel's strict
  # `:secret_access_key_required` first-save rule.
  defdelegate apply_backup_cluster_state(instance, changeset, params, opts \\ []),
    to: ConfigureBackups,
    as: :apply_cluster_state

  # The UI's "stop backing up entirely": a plain row delete (the
  # resource's `:destroy`, member-policied like `:update`) — no cluster
  # state, and the namespace Secret persists so re-configuring reuses
  # the same restic repo.
  defdelegate remove_backup_settings(setting, opts \\ []),
    to: BackupSetting,
    as: :destroy

  # #222 (ADR-0037 §4): the panel's repo-password reveal — a live read of
  # the namespace's `backup-config` Secret, the credential's only home.
  defdelegate read_backup_credential(instance),
    to: ReadBackupCredential,
    as: :call

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

  # #597 §4.1: the mid-setup probe — asks a Pocket ID instance whether
  # its first-boot admin is still unclaimed. Read-only, best-effort: a
  # failure is an answer (:unreachable), never an error the caller must
  # handle — the wizard's offer card degrades on it, nothing breaks.
  defdelegate probe_pocketid_setup(instance), to: ProbePocketIdSetup, as: :call

  # #597 S4 (§4.5): the wiring operation — mints the PocketID client
  # with the audited held key, merges the recipe's env onto the
  # instance, records the wiring row. The wizard's submit and the API's
  # connect-pocketid verb both ride this one seam. Fail-soft by
  # construction (D3): every {:error, reason} leaves the instance
  # deployable, never blocks a deploy.
  defdelegate connect_pocket_id(instance, pocket_id_instance_id, opts \\ []),
    to: ConnectPocketId,
    as: :call
end
