defmodule FluxVale.Infrastructure.PocketIdCustodyEvent do
  @moduledoc """
  The custody audit trail (#597 S2, the D1 amendment — first-class,
  not an afterthought): one append-only row per custody operation
  (`:stored` / `:replaced` / `:revoked`) and per USE of the held key
  (`:used`, with a `purpose`), org-attributed — the platform's own
  record beside PocketID's internal audit log.

  Why a new resource and not `FluxVale.Api.AuditEvent`: that table is
  token-scoped by construction (`personal_access_token_id` is
  required — "a row kind with no token does not exist yet", its own
  moduledoc), and its retention rides the machine-API janitor. Key
  custody is an org-level fact with its own lifecycle, so this
  follows the closest org-level pattern instead — the
  InstanceAllocationSnapshot stance: append-only system-written rows
  in the Infrastructure context. No update action, no
  `update_timestamp` — history is not editable, and the missing
  column makes that a schema guarantee (the Api.AuditEvent
  construction).

  The append is guarded (`RecordCustodyEvent` — a failed write logs,
  never fails the audited operation). Reads are member-facing: the
  org's audit surface (a later slice renders it).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Accounts.Organization
  alias FluxVale.Infrastructure.Instance

  postgres do
    table("pocket_id_custody_events")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job.
    migration_defaults(id: "nil")

    custom_indexes do
      # THE access pattern: an instance's custody history, newest
      # first (the audit surface's query).
      index([:instance_id, :created_at])

      # The org-wide scan (every PocketID's events in one list).
      index([:organization_id, :created_at])
    end

    references do
      # The trail exists for its org — teardown takes it along (the
      # RequestWindow posture: no orphaned history outliving the
      # subject it describes).
      reference(:organization, on_delete: :delete)

      # The PocketID instance's lifecycle owns its history: destroy
      # cascades the events (they describe that instance's custody).
      reference(:instance, on_delete: :delete)
    end
  end

  policies do
    policy action_type(:read) do
      description("Members read their org's custody audit trail")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    # System-only append, the Api.AuditEvent posture: the guarded
    # writer (RecordCustodyEvent) is the one seam, running
    # authorize?: false with the comment in place.
    policy action_type(:create) do
      description("System-only: the guarded append owns the writes (authorize?: false)")
      forbid_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    # Atoms in, atoms out (the AuditKind shape), stored as text.
    attribute :kind, FluxVale.Infrastructure.Types.CustodyEventKind do
      allow_nil?(false)
      public?(false)
    end

    # :used rows only — what the key was used FOR ("verification",
    # "client_mint", …). nil on custody-state rows (the kind is the
    # whole story there).
    attribute :purpose, :string do
      public?(false)
      constraints(max_length: 100)
    end

    # WHO acted — the operating user, a denormalized snapshot
    # (deliberately not a relationship: the row must not entangle the
    # actor's own account lifecycle). nil on no-actor system paths.
    attribute :actor_id, :uuid do
      public?(false)
    end

    create_timestamp(:created_at)
  end

  relationships do
    belongs_to :organization, Organization do
      allow_nil?(false)
      public?(false)
    end

    # The PocketID instance the custody was about — stable across
    # replaces and outliving the custody row itself (a revoke event
    # must survive the custody row's deletion, which is why this is
    # NOT a custody reference).
    belongs_to :instance, Instance do
      allow_nil?(false)
      public?(false)
    end
  end

  actions do
    defaults([])

    read :read do
      description("The members' audit read (a later slice's surface).")
      primary?(true)
    end

    read :for_instance do
      description("One instance's custody history, newest first.")
      argument(:instance_id, :uuid, allow_nil?: false)
      filter(expr(instance_id == ^arg(:instance_id)))
      prepare(build(sort: [created_at: :desc]))
    end

    # The guarded append's funnel — never called with an actor.
    create :record do
      description("System-only: append one custody audit row.")
      accept([:organization_id, :instance_id, :kind, :purpose, :actor_id])
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:for_instance, args: [:instance_id])
    define(:record)
  end
end
