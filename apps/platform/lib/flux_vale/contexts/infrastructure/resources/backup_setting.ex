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
  `destroy` is the "stop backing up entirely" row delete, and holds the
  same persistence stance: the namespace Secret stays, so nothing
  re-provisions a repo behind the user's back.

  A row without its namespace Secret (only reachable through admin
  tooling — the platform is the Secret's only writer) fails its first
  run loudly: the Job's `secretRef` blocks the pod. A proper
  `Operations.ConfigureBackups` save heals it. The sweep never invents
  credentials.
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
      description(
        "Members create their org's instance backup settings — with a wallet that has paid once (every row is born enabled, so a never-paid org has no business creating one)"
      )

      forbid_unless(relates_to_actor_via([:instance, :organization, :members]))
      forbid_unless(FluxVale.Checks.ActorOrgHasPaid)
      authorize_if(FluxVale.Checks.ActorOrgHasPaid)
    end

    policy action_type(:update) do
      description("Members change their org's instance backup settings")
      authorize_if(relates_to_actor_via([:instance, :organization, :members]))
    end

    # Every update needs membership; everything EXCEPT a pause to false
    # additionally needs a wallet that has paid once. The panel's
    # pause/resume switch is deliberately a PLAIN `:update` (pausing
    # must never touch K8s), so the policy is what carries the gate —
    # the pause escape is scoped to FROM true (an edit of an
    # already-paused row, a re-enable, and an edit that stays enabled
    # all answer the paid check; a crafted save omitting `enabled`
    # never escapes). The member policy above composes as the AND.
    policy action_type(:update) do
      description(
        "Every update needs membership; everything except a pause to false additionally needs a wallet that has paid once"
      )

      authorize_if(changing_attributes(enabled: [from: true, to: false]))
      forbid_unless(relates_to_actor_via([:instance, :organization, :members]))
      forbid_unless(FluxVale.Checks.ActorOrgHasPaid)
      authorize_if(FluxVale.Checks.ActorOrgHasPaid)
    end

    policy action_type(:destroy) do
      description("Members remove their org's instance backup settings")
      authorize_if(relates_to_actor_via([:instance, :organization, :members]))
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    # The S3-compatible endpoint (R2 first) — scheme + host[:port] and
    # nothing else. The fence is deliberate: credentials must never ride
    # the endpoint (a `user:password@` userinfo would persist a secret in
    # this row), and restic parses the first path segment of a repository
    # URL as the BUCKET — a path here would silently select the wrong
    # repo (or double the bucket). `max_length` is a DNS host's bound.
    attribute :endpoint, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 253)
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

    # The UI's "stop backing up entirely": a plain row delete with no
    # cluster state. The namespace Secret persists (same rationale as
    # disable — the credential is the repo's identity, and nothing
    # invents a new one behind the user's back). Teardown's cascade
    # reaches the same row when the Instance goes.
    destroy :destroy do
      description("Removes the instance's backup settings row — no cluster state.")
      primary?(true)
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
    define(:destroy)
    define(:get_by_instance, args: [:instance_id])
  end

  identities do
    identity(:unique_instance, [:instance_id])
  end

  validations do
    # Scheme + host[:port] ONLY — `https://account.r2.cloudflarestorage.com`,
    # `http://minio:9000`, and a bracketed IPv6 literal pass; `ftp://host`,
    # a bare host, a userinfo (`user:password@`), a non-empty path, or a
    # query/fragment do not. The path exclusion is load-bearing (restic
    # reads the first path segment as the bucket) and so is the userinfo
    # exclusion (the credential would persist in this row). A trailing
    # slash is legal input; ConfigureBackups trims it.
    validate(
      match(
        :endpoint,
        ~r"\Ahttps?://(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(?::\d{1,5})?/?\z"
      ),
      message: "must be an http:// or https:// URL with a host and no path"
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
