defmodule FluxVale.Infrastructure.BackupRun do
  @moduledoc """
  One backup attempt for an Instance (#222, ADR-0037 §3) — the history
  row the backups panel reads and the sweep's watch pass finalizes.

  A run is created by `Operations.RunInstanceBackup` in `:pending`, moved
  to `:running` once its k8s Job is applied, and closed by
  `Operations.SweepBackups` from the Job's termination message:
  `:succeeded` carries restic's snapshot id and byte counts, `:failed`
  carries a sanitized `error_summary` (≤500, never a credential).

  **A failed run never touches `Instance.status`** — backup health and app
  health are separate axes (ADR-0037's consequences). The panel shows the
  failure; the app keeps running.

  **Restores share the row** (#222, ADR-0037 §5): `kind: :restore` is the
  same shape, created by `Operations.RestoreInstanceBackup` and finalized
  by the same sweep. Two restore-specific fields ride along —
  `restored_from` (the pre-restore status the instance goes back to) and
  `bytes_restored` — and a failed restore *does* flip the instance to
  `:error` with `:restore_failed`, because unlike a backup it owns the
  instance while it runs.

  Rows are system-written: members read them (org-scoped through the
  instance), and every write is `authorize?: false` from the operations —
  the same posture as the instance lifecycle's trigger actions.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  alias FluxVale.Infrastructure.BackupRun.OutcomeMarkers

  postgres do
    table("backup_runs")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    # The run is the instance's history: teardown's hard delete takes it
    # along (no FK failure, no orphan).
    references do
      reference(:instance, on_delete: :delete)
    end

    # The watch pass reads active runs every sweep and the panel reads one
    # instance's history newest-first. The PARTIAL unique index is the
    # one-active-run invariant's teeth (ADR-0037 §3): the guard check is
    # advisory, the index is atomic — a sweep racing a manual click makes
    # the loser's insert fail, so two Jobs can never share an instance.
    custom_indexes do
      index([:status])
      index([:instance_id, :started_at])

      index([:instance_id],
        name: "backup_runs_one_active_per_instance_index",
        unique: true,
        where: "status IN ('pending', 'running')"
      )
    end
  end

  policies do
    policy action_type(:read) do
      description("Members read their org's instance backup runs")
      authorize_if(relates_to_actor_via([:instance, :organization, :members]))
    end

    policy action_type([:create, :update]) do
      description("System-only: the run operation and the sweep (authorize?: false)")
      forbid_if(always())
    end
  end

  pub_sub do
    module(Phoenix.PubSub)
    name(FluxVale.PubSub)

    # #222: a run's writes land on the INSTANCE's topic
    # (`instances:<instance_id>`) — the one the instance page already
    # subscribes to. A backup's outcome never touches `Instance.status`
    # (ADR-0037's consequences: app health and backup health are separate
    # axes), so without this the panel would show a run as running until
    # the next page load.
    publish(:create, ["instances", :instance_id])
    publish(:update, ["instances", :instance_id])
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute :kind, FluxVale.Infrastructure.Types.BackupRunKind do
      allow_nil?(false)
      public?(true)
    end

    attribute :status, FluxVale.Infrastructure.Types.BackupRunStatus do
      allow_nil?(false)
      default(:pending)
      public?(true)
    end

    # restic's snapshot id (64 hex chars) — nil until a run succeeds.
    attribute :snapshot_id, :string do
      public?(true)
    end

    # From restic's `summary` event: total bytes read, bytes added to the
    # repo. nil until a run succeeds.
    attribute :bytes_processed, :integer do
      public?(true)
      constraints(min: 0)
    end

    attribute :bytes_added, :integer do
      public?(true)
      constraints(min: 0)
    end

    # From the restore script's summary event (#222, ADR-0037 §5): bytes
    # written back. nil on backup runs.
    attribute :bytes_restored, :integer do
      public?(true)
      constraints(min: 0)
    end

    # The user-facing reason, sanitized by the sweep — restic's exit code
    # plus its last stderr line, truncated. Never env values.
    attribute :error_summary, :string do
      public?(true)
      constraints(max_length: 500)
    end

    # #222 (ADR-0037 §5): a :restore run's pre-restore status — where the
    # instance goes back to when the restore succeeds. Stored, not
    # recomputed: the sweep finalizes minutes later, by which time the
    # Deployment is scaled to 0 and `:stopped` and `:sleeping` are
    # indistinguishable from the cluster's side. nil on backup runs.
    attribute :restored_from, FluxVale.Infrastructure.Types.InstanceStatus do
      public?(true)
    end

    # Set at create (the run's clock starts then, not at the Job's first
    # pod); nil while it runs.
    attribute :started_at, :utc_datetime do
      allow_nil?(false)
      public?(true)
    end

    attribute :finished_at, :utc_datetime do
      public?(true)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :instance, FluxVale.Infrastructure.Instance do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:instance_id, :kind, :status, :started_at, :restored_from])
    end

    update :update do
      description("The sweep's finalize (and the operation's :running flip).")
      require_atomic?(false)

      accept([
        :status,
        :snapshot_id,
        :bytes_processed,
        :bytes_added,
        :bytes_restored,
        :error_summary,
        :finished_at
      ])

      # Both finalize writers (RunInstanceBackup.fail_now/2 and
      # SweepBackups.finalize_row/2) ride this one action — the outcome
      # metric mounts here so neither operation knows about metrics.
      change(OutcomeMarkers)
    end

    read :recent_for_instance do
      description("One instance's run history, newest first.")
      argument(:instance_id, :uuid, allow_nil?: false)

      argument(:limit, :integer,
        allow_nil?: false,
        default: 20,
        constraints: [min: 1, max: 100]
      )

      filter(expr(instance_id == ^arg(:instance_id)))
      prepare(build(sort: [started_at: :desc, id: :desc]))

      prepare(fn query, _context ->
        limit = Ash.Query.get_argument(query, :limit)
        Ash.Query.limit(query, limit)
      end)
    end

    # The watch pass's input: everything the platform still owns an
    # outcome for. System read (authorize?: false) — no member needs a
    # fleet-wide list.
    read :active do
      description("Runs awaiting an outcome — the sweep's watch pass input.")
      filter(expr(status in [:pending, :running]))
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:create)
    define(:update)
    define(:recent_for_instance, args: [:instance_id, :limit])
    define(:active)
  end
end
