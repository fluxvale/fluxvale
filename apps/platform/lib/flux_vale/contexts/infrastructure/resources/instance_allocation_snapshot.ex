defmodule FluxVale.Infrastructure.InstanceAllocationSnapshot do
  @moduledoc """
  The append-only allocation/pricing audit trail (#493): one row per
  allocation *era* of an instance — the cpu/memory/storage it ran at,
  the size and cents that priced it, and when the era began and ended.

  The instance row remains the live read path for settlement and the
  runway projection; these rows are history. Rows are never edited — a
  resize supersedes the open row (`superseded_at` set) and appends the
  new era, so a resize's rate change can be audited after the fact.

  System-only for every non-admin: rows are minted by their writers'
  transactions (instance create, #493's resize) with `authorize?: false`.
  The one exception is the console's platform-admin bypass (#595 slice
  5), and the console exposes this resource read-only.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing.Size

  postgres do
    table("instance_allocation_snapshots")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job.
    migration_defaults(id: "nil")

    custom_indexes do
      # Era lookups (the supersede/append cycle) scan by instance.
      index([:instance_id])

      # The one-open-era invariant's teeth (the backup_runs stance): the
      # supersede-then-append cycle keeps it, the index is atomic — a
      # racing resize can never leave two open eras per instance.
      index([:instance_id],
        name: "instance_allocation_snapshots_one_open_per_instance",
        unique: true,
        where: "superseded_at IS NULL"
      )
    end

    references do
      # The trail exists for its instance — teardown takes it with it
      # (the InstanceHostname stance).
      reference(:instance, on_delete: :delete)
    end
  end

  policies do
    # Platform admins see and do everything (#644); the console's
    # Infrastructure slice (#595 slice 5) exposes this resource
    # read-only. Machine-API callers stay on the system-only forbid
    # below.
    bypass [FluxVale.Checks.ActorIsPlatformAdmin, FluxVale.Checks.CallOutsideMachineApi] do
      description(
        "Platform admins see and do everything (#644); the console exposes this resource read-only (#595 slice 5)"
      )

      authorize_if(always())
    end

    # System-only (the settle_anchors posture): every caller is a
    # system writer or a test asserting through the audit trail, both
    # `authorize?: false`.
    policy action_type(:read) do
      description("System-only: the audit trail reads system-side (authorize?: false)")
      forbid_if(always())
    end

    policy action_type([:create, :update]) do
      description("System-only: the create/resize paths own the writes (authorize?: false)")
      forbid_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    # The era's allocation — the instance row's own constraint bounds
    # (the same hard floors, ADR-0028's allocation table).
    attribute :cpu_cores, :decimal do
      constraints(greater_than: 0, max: 64)
    end

    attribute :memory_mb, :integer do
      constraints(min: 1, max: 65_536)
    end

    attribute :storage_gb, :integer do
      # 0 stays legal — config-only apps (the instance's own stance).
      constraints(min: 0, max: 10_240)
    end

    attribute :monthly_cents, :integer do
      # An unpriced era records nulls — billing never guesses.
      constraints(min: 0)
    end

    attribute :stopped_monthly_cents, :integer do
      constraints(min: 0)
    end

    # When this era began: create-time `created_at` for the first era,
    # the resize instant for every later one.
    attribute :effective_from, :utc_datetime_usec do
      allow_nil?(false)
    end

    # nil = the era still in force (the one open row per instance —
    # the partial unique index in the migration).
    attribute :superseded_at, :utc_datetime_usec do
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :instance, Instance do
      allow_nil?(false)
    end

    # Nullable — mirrors the instance row: a custom (sizeless) era has
    # no size.
    belongs_to :size, Size do
    end
  end

  actions do
    read :read do
      description(
        "Audit read: platform admins through the console bypass; every other caller is a system reader (authorize?: false)."
      )

      primary?(true)
      pagination(offset?: true, required?: false)
    end

    read :in_force do
      description("The instance's open era — the one row with superseded_at nil.")
      argument(:instance_id, :uuid, allow_nil?: false)

      filter(expr(instance_id == ^arg(:instance_id) and is_nil(superseded_at)))
    end

    create :record do
      description("System-only: append one era row (riding its writer's transaction).")

      accept([
        :instance_id,
        :cpu_cores,
        :memory_mb,
        :storage_gb,
        :size_id,
        :monthly_cents,
        :stopped_monthly_cents,
        :effective_from
      ])
    end

    update :supersede do
      description("System-only: close the era — superseded_at is the close stamp.")
      accept([:superseded_at])
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:record)
    define(:supersede)
    define(:in_force, args: [:instance_id])
  end
end
