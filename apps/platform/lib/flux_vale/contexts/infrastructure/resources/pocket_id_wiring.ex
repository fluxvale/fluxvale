defmodule FluxVale.Infrastructure.PocketIdWiring do
  @moduledoc """
  The durable record that an instance's sign-in is wired to a PocketID
  (#597 S4): which PocketID instance served it, which client (and
  which of the client's secrets) the platform minted there, when. The
  row IS the wiring — the env merge it describes rides the instance's
  `env_vars`, and S5's card/rotation/disconnect read this to know what
  exists.

  One ACTIVE wiring per app instance (the `unique_per_instance`
  identity): a re-wire replaces — the operation destroys the old row
  before the new one lands, so the row never lies about which client
  is live. Best-effort deletion of the replaced client in PocketID is
  S5's (D6's orphan posture in the meantime: harmless, visible in
  PocketID's own admin, named `FluxVale · …`).

  `pocket_id_instance_id` is deliberately NOT a foreign key
  (the PocketIdCustodyEvent actor_id stance): a wiring must SURVIVE
  its PocketID's destruction to render §6's "Pocket ID gone — clear
  wiring" card state, and any FK action (cascade, restrict) either
  destroys that state silently or wedges the PocketID's teardown
  (custody's on_delete rationale, inverted). The id resolves at read
  time; no row means gone.

  Posture follows PocketIdCustody exactly: members read (the S5
  card), the system operation funnels every write (`authorize?:
  false` — the op's own authorization already decided). Immutable by
  construction except ONE carve-out: `rotate_secret` (S5) moves
  `pocket_id_secret_id` to the new secret after the workload carries
  it — a field describing the live secret, not the wiring's history
  (which PocketID, which client, when — those stay write-once).
  `wired_at` is the create timestamp (a re-wire writes a fresh row),
  no `update_timestamp` — history with an edit button is not history.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource, AshPaperTrail.Resource]

  alias FluxVale.Infrastructure.Instance

  json_api do
    # No routes of its own: the one wire surface is the Instance's
    # `connect-pocketid` generic action (the run_backup shape), which
    # renders the returned row through this type. The rendered set is
    # the public attributes — ids only: PocketID's client id and
    # secret id are identifiers, not credentials (the secret VALUE
    # exists once, in the instance's env_vars, and is never stored
    # here).
    type("pocket_id_wiring")
  end

  policies do
    bypass [FluxVale.Checks.ActorIsPlatformAdmin, FluxVale.Checks.CallOutsideMachineApi] do
      description("Platform admins see and do everything (#644)")
      authorize_if(always())
    end

    policy action_type(:read) do
      description("Members read their org's instance wiring (the S5 card)")
      authorize_if(relates_to_actor_via([:instance, :organization, :members]))
    end

    # System-only funnels (the PocketIdCustody stance): the wiring
    # operation owns the writes; callers run authorize?: false with
    # that comment in place.
    policy action_type([:create, :update, :destroy]) do
      description("System-only: the wiring operation owns the writes (authorize?: false)")
      forbid_if(always())
    end
  end

  postgres do
    table("pocket_id_wirings")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job.
    migration_defaults(id: "nil")

    # No custom index: the identity's unique index on [:instance_id]
    # already serves the one query that exists (the instance's single
    # wiring) — a second, plain index on the identical column list
    # would be pure write amplification.

    references do
      # CASCADE, the custody stance: the wiring dies with its subject
      # app instance — teardown hard-deletes the row alongside. The
      # PocketID-side client becomes S5's best-effort cleanup (D6).
      reference(:instance, on_delete: :delete)
    end
  end

  # The audit trail (#645, ADR-0048): the complete config posture —
  # the mixin line is mandatory (read policy, indexes, actor label);
  # version_attachments attach the Policy authorizer. The wiring row's
  # only sensitive-adjacent value is the PocketID secret ID (an id,
  # never the value — that lives in env alone), so redaction posture
  # follows the set, not a column.
  paper_trail do
    primary_key_type(:uuid_v7)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    store_action_inputs?(true)
    sensitive_attributes(:redact)
    ignore_attributes([:created_at, :updated_at])
    reference_source?(false)
    create_version_on_destroy?(true)
    operation_id_field(:operation_id)
    mixin({FluxVale.PaperTrail.VersionMixin, :version_resource, []})
    version_extensions(authorizers: [Ash.Policy.Authorizer])

    belongs_to_actor(:user, FluxVale.Identity.User,
      domain: FluxVale.Identity,
      on_delete: :nilify
    )
  end

  attributes do
    uuid_v7_primary_key(:id)

    # PocketID's own client id (its UUID string) — what S5's
    # rotate/disconnect and the delete-time cleanup address.
    attribute :pocket_id_client_id, :string do
      allow_nil?(false)
      public?(true)
    end

    # PocketID's id for the created secret — S5's rotation creates a
    # second secret then deletes this one by id (§2's zero-downtime
    # sequence). An identifier, never the secret's value.
    attribute :pocket_id_secret_id, :string do
      allow_nil?(false)
      public?(true)
    end

    # The PocketID instance that served the wiring — a plain uuid with
    # no FK, deliberately (the moduledoc's gone-state rationale).
    attribute :pocket_id_instance_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    # When the client was minted and the env merged. The create
    # timestamp itself, named for the event (immutable row — a
    # re-wire writes a new row with a fresh wired_at).
    create_timestamp(:wired_at) do
      public?(true)
    end
  end

  relationships do
    # The app instance whose sign-in this wires. The org fence rides
    # it (the read policy's path).
    belongs_to :instance, Instance do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([])

    read :read do
      description("The members' read (the S5 card's source).")
      primary?(true)
    end

    read :get_by_instance do
      description("The instance's active wiring, if any (the identity's one-row shape).")
      get?(true)
      argument(:instance_id, :uuid, allow_nil?: false)
      filter(expr(instance_id == ^arg(:instance_id)))
    end

    # The wiring op's funnel, after the client landed in PocketID.
    create :record do
      description("System-only: record a completed wiring.")
      accept([:instance_id, :pocket_id_instance_id, :pocket_id_client_id, :pocket_id_secret_id])
    end

    # Rotation's durable record (#597 S5): the row's secret_id moves
    # to the new secret AFTER the workload carries it. System-only —
    # the rotation operation is the only caller.
    update :rotate_secret do
      description("System-only: the rotation's new secret id.")
      accept([:pocket_id_secret_id])
    end

    # The re-wire's funnel: the old row goes before the new one lands
    # (the identity holds one active wiring). The old PocketID
    # client's best-effort delete is S5's.
    destroy :replace do
      description("System-only: a re-wire replaces the active wiring row.")
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:get_by_instance, args: [:instance_id])
    define(:record)
    define(:replace)
  end

  identities do
    # One ACTIVE wiring per app instance — the re-wire-replaces rule,
    # made a schema guarantee (a second concurrent wiring cannot
    # commit).
    identity(:unique_per_instance, [:instance_id])
  end
end
