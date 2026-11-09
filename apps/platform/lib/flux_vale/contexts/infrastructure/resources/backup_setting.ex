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
    extensions: [AshJsonApi.Resource, AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Infrastructure.BackupSetting.ApplyClusterState

  # #360 (ADR-0019 §1): the backups settings family's wire contract.
  # The row holds no secrets by design (its moduledoc) — every field
  # here is the settings UI's own surface.
  json_api do
    type("backup_setting")

    routes do
      # backups:read
      get(:get_by_instance,
        route: "/instances/:instance_id/backup-setting",
        default_fields: [
          :id,
          :instance_id,
          :endpoint,
          :bucket,
          :prefix,
          :access_key_id,
          :retention_keep,
          :enabled
        ]
      )

      # backups:write — instance_id rides the path; the bucket
      # coordinates ride the attributes. The routes' save action is the
      # panel-equivalent write (:save — converges the cluster with the
      # row, #482); the generic :create below stays the operation's and
      # the bootstrap paths' plain row write.
      post(:save,
        route: "/instances/:instance_id/backup-setting",
        default_fields: [
          :id,
          :instance_id,
          :endpoint,
          :bucket,
          :prefix,
          :access_key_id,
          :retention_keep,
          :enabled
        ]
      )

      # backups:write — the panel-equivalent save (see :save above).
      patch(:save_settings,
        route: "/backup-settings/:id",
        default_fields: [
          :id,
          :instance_id,
          :endpoint,
          :bucket,
          :prefix,
          :access_key_id,
          :retention_keep,
          :enabled
        ]
      )

      # backups:write — the "stop backing up entirely" row delete.
      delete(:destroy, route: "/backup-settings/:id")
    end
  end

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

  # The audit trail (#645, ADR-0048): the plan's one complete config
  # posture — the mixin line is mandatory (it carries the read policy,
  # the indexes, the actor label). version_extensions attaches the
  # Policy authorizer that policy rides on. Rationale lives in the
  # ADR, not here.
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

  policies do
    # The blanket authority (#644, ADR-0047): platform admins see and do
    # everything — but never through the machine API (the second
    # condition), so PAT callers fall through to the policies below
    # with today's semantics.
    bypass [FluxVale.Checks.ActorIsPlatformAdmin, FluxVale.Checks.CallOutsideMachineApi] do
      description("Platform admins see and do everything (#644)")
      authorize_if(always())
    end

    policy action_type(:read) do
      description("Members read their org's instance backup settings")
      authorize_if(relates_to_actor_via([:instance, :organization, :members]))
    end

    policy action_type(:create) do
      description(
        "Members create their org's instance backup settings — with a wallet that has paid once. The action accepts :enabled (defaulting it true), so an unpaid org must not mint a settings row at all — create is gated outright"
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

    # #360: instance_id arrives as an ARGUMENT so the JSON:API route can
    # feed it from the PATH (`/instances/:instance_id/backup-setting` —
    # path params feed arguments by name). The change copies it onto the
    # attribute, so ConfigureBackups' attribute-shaped params land the
    # same row (the ActorOrgHasPaid gate already reads both shapes).
    # PLAIN row write — no cluster state: the operation's write_row and
    # the bootstrap paths (test preconditions, seeds) land here; the
    # routes' cluster-converging save is :save below.
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

      argument(:instance_id, :uuid, allow_nil?: false, public?: true)

      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :instance_id,
          Ash.Changeset.get_argument(changeset, :instance_id)
        )
      end)
    end

    # PLAIN row write — the panel's pause/resume switch is deliberately
    # this action (pausing must never touch K8s), and so is the
    # operation's merged row write; the routes' converge path is :save.
    update :update do
      require_atomic?(false)

      accept([:endpoint, :bucket, :prefix, :access_key_id, :retention_keep, :enabled])
    end

    # #482: the JSON:API routes' save — the panel-equivalent write.
    # Same shape as the generic pair plus the write-only secret, with
    # ApplyClusterState converging the cluster on EVERY routed save:
    # the Secret is re-applied (blank/absent keeps the stored
    # credential; the repo URL recomputes from the saved coordinates)
    # and the margin quota re-applies. The secret is never an
    # attribute, so it cannot land on the row or render in any
    # response.
    create :save do
      accept([
        :endpoint,
        :bucket,
        :prefix,
        :access_key_id,
        :retention_keep,
        :enabled,
        :instance_id
      ])

      argument(:instance_id, :uuid, allow_nil?: false, public?: true)

      # Write-only (#482): applied to the namespace Secret through the
      # operation's one entrypoint; absent/blank keeps the stored
      # credential.
      argument(:secret_access_key, :string,
        allow_nil?: true,
        public?: true,
        sensitive?: true
      )

      # Same path-feeds-argument copy as the generic :create above.
      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :instance_id,
          Ash.Changeset.get_argument(changeset, :instance_id)
        )
      end)

      change(ApplyClusterState)
    end

    update :save_settings do
      description("A settings save — endpoint/bucket/prefix/keys/retention/enabled.")
      require_atomic?(false)

      accept([:endpoint, :bucket, :prefix, :access_key_id, :retention_keep, :enabled])

      # Write-only (#482), same contract as the :save create —
      # absent/blank keeps the stored credential while the saved
      # coordinates recompute the repo URL.
      argument(:secret_access_key, :string,
        allow_nil?: true,
        public?: true,
        sensitive?: true
      )

      change(ApplyClusterState)
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
