defmodule FluxVale.Infrastructure.BackupSetting do
  @moduledoc """
  An Instance's backup destination — one settings row per instance
  (`unique_instance`), written by `Operations.ConfigureBackups` (#222,
  ADR-0037).

  The row holds the bucket coordinates and nothing secret: endpoint,
  bucket, prefix, the access key **id** (an identifier — it
  authenticates nothing without its secret), retention, and the enabled
  switch. The S3 secret key and the restic repo password live only in
  the namespace's `backup-config` Secret (ADR-0035's stance, extended
  by ADR-0037 §4) and are never columns here.

  Deselecting `enabled` is a plain update, not an operation: disabling
  changes one attribute and no cluster state — the Secret and the quota
  margin deliberately persist so re-enabling reuses the same restic
  repo (a rotated repo password would orphan every existing snapshot).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("backup_settings")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    # The row is pure configuration for the instance: teardown's hard
    # delete of the Instance takes it along (no FK failure, no orphan).
    references do
      reference(:instance, on_delete: :delete)
    end
  end

  policies do
    policy action_type(:read) do
      description("Members read their org's instance backup settings")
      authorize_if(relates_to_actor_via([:instance, :organization, :members]))
    end

    policy action_type(:create) do
      description("Members configure their org's instance backups")
      authorize_if(relates_to_actor_via([:instance, :organization, :members]))
    end

    policy action_type(:update) do
      description("Members change their org's instance backup settings")
      authorize_if(relates_to_actor_via([:instance, :organization, :members]))
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    # The S3-compatible endpoint (R2 first) — scheme + host, optional
    # path for gateway-style deployments. Composed into
    # RESTIC_REPOSITORY by ConfigureBackups; a trailing slash is legal
    # input and trimmed there.
    attribute :endpoint, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :bucket, :string do
      allow_nil?(false)
      public?(true)
    end

    # Optional key prefix inside the bucket — dot-separated paths, no
    # leading/trailing slash (the composer adds the separator).
    attribute :prefix, :string do
      public?(true)
    end

    # An identifier, not a credential: it names the key the secret pairs
    # with and gives the settings UI an honest masked label. The secret
    # itself is namespace-Secret-only (ADR-0037 §4).
    attribute :access_key_id, :string do
      allow_nil?(false)
      public?(true)
    end

    # restic `forget --keep-last N`; 2 is the floor where snapshots
    # carry history, 30 the point where the bucket belongs to the user's
    # provider bill, not us.
    attribute :retention_keep, :integer do
      allow_nil?(false)
      default(7)
      public?(true)
      constraints(min: 2, max: 30)
    end

    attribute :enabled, :boolean do
      allow_nil?(false)
      default(true)
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

      accept([
        :endpoint,
        :bucket,
        :prefix,
        :access_key_id,
        :retention_keep,
        :enabled,
        :instance_id
      ])
    end

    update :update do
      description("A settings save — endpoint/bucket/prefix/keys/retention/enabled.")
      require_atomic?(false)

      accept([:endpoint, :bucket, :prefix, :access_key_id, :retention_keep, :enabled])
    end

    read :get_by_instance do
      description("The instance's settings row (at most one — `unique_instance`).")
      get?(true)
      argument(:instance_id, :uuid, allow_nil?: false)
      filter(expr(instance_id == ^arg(:instance_id)))
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:create)
    define(:update)
    define(:get_by_instance, args: [:instance_id])
  end

  identities do
    identity(:unique_instance, [:instance_id])
  end

  validations do
    # Scheme + host, optional path: `https://account.r2.cloudflarestorage.com`
    # passes, `ftp://host` and a bare host do not. No whitespace or
    # query/fragment — none of them are addressable in a restic repo URL.
    validate(match(:endpoint, ~r"\Ahttps?://[^/\s?#]+(?:/[^\s?#]*)*\z"),
      message: "must be an http:// or https:// URL with a host"
    )

    # S3 bucket naming: 3–63 chars, lowercase alphanumerics, dots and
    # hyphens, starting and ending alphanumeric.
    validate(match(:bucket, ~r"\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z"),
      message:
        "must be 3-63 lowercase letters, numbers, dots or hyphens, starting and ending with a letter or number"
    )

    # Optional; when present, slash-separated path segments with no
    # leading or trailing slash (the composer owns the separators) and no
    # `.`/`..` segment — each segment must carry an alphanumeric, so a
    # traversal can never address outside the bucket prefix.
    validate(
      match(
        :prefix,
        ~r"\A[A-Za-z0-9._-]*[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9._-]*[A-Za-z0-9][A-Za-z0-9._-]*)*\z"
      ),
      message: "must be path segments with no leading or trailing slash"
    )
  end
end
