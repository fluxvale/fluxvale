defmodule FluxVale.Api.AuditEvent do
  @moduledoc """
  Append-only audit rows for the machine API (#360 slice 5): one
  `request` row per PAT-authenticated `/api/v1` call, one `mint` /
  `revoke` row per token lifecycle event — enough to answer "what did
  this token do", never the token value (rows reference the token by
  id alone; `token_hash` never crosses into this table).

  System-only rows, RequestWindow's posture: no actor-facing surface
  (the empty policies block = default forbid; operator reads ride
  `read :by_token` with `authorize?: false` — the SQL/IEx stance),
  no JSON:API routes (not a machine-API resource), no AshAdmin
  (ADR-0027 §3 stance).

  Append-only by construction: no update action, no
  `update_timestamp` — history is not editable, and the missing
  column makes that a schema guarantee, not a convention.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Api,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("api_audit_events")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    # Derivative of the token, RequestWindow's on_delete posture:
    # teardown of the user takes the tokens and their audit rows along
    # — no orphaned history outliving the subject it describes.
    references do
      reference(:personal_access_token, on_delete: :delete)
    end

    custom_indexes do
      # THE access pattern: filter by token, order by created_at ("what
      # did this token do").
      index([:personal_access_token_id, :created_at])
    end
  end

  # Deliberately empty (RequestWindow's posture): with the Policy
  # authorizer attached, a policy-less action is forbidden to every
  # actor. Only the system calls (the boundary plug, the mint/revoke
  # operations, the janitor — all `authorize?: false` with comments
  # in place) touch this table.
  policies do
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)

    # Atoms in, atoms out (the ledger types' shape), stored as text;
    # off-enum kinds are refused at the changeset — the seam the
    # guard test exercises.
    attribute :kind, FluxVale.Api.Types.AuditKind do
      allow_nil?(false)
      public?(false)
    end

    # Request rows only — mints and revokes have no HTTP shape.
    attribute :method, :string do
      public?(false)
    end

    # Path ONLY, never the query string: query strings can carry
    # tokens-in-URL accidents, and the API's contract never authes
    # via query anyway. Structural, not filtered — the plug writes
    # `conn.path_info`, which cannot contain one.
    attribute :path, :string do
      public?(false)
      constraints(max_length: 2048)
    end

    attribute :status_code, :integer do
      public?(false)
    end

    # WHO performed a mint/revoke — the operating user, which differs
    # from the token's owner exactly when an admin acts on someone
    # else's token. nil on request rows (the token reference already
    # pins the acting user) and on no-actor operator paths. A
    # denormalized snapshot, deliberately not a relationship: the
    # row must not entangle the operator's own account lifecycle.
    attribute :actor_id, :uuid do
      public?(false)
    end
  end

  relationships do
    # Every S1 row is about a token — request rows attribute a call,
    # mint/revoke rows name the subject. Required, never nullable; a
    # row kind with no token does not exist yet.
    belongs_to :personal_access_token, FluxVale.Identity.PersonalAccessToken do
      allow_nil?(false)
      public?(false)
    end
  end

  actions do
    defaults([])

    create :record do
      description("System write — one append-only audit row")
      accept([:kind, :personal_access_token_id, :method, :path, :status_code, :actor_id])
    end

    read :by_token do
      description("A token's rows — the operator's what-did-this-token-do query")
      argument(:token_id, :uuid, allow_nil?: false)
      filter(expr(personal_access_token_id == ^arg(:token_id)))
    end

    read :stale do
      description("Rows older than the cutoff — the janitor prune feed")
      argument(:cutoff, :utc_datetime, allow_nil?: false)
      filter(expr(created_at < ^arg(:cutoff)))
    end

    destroy :expunge_stale do
      description("Janitor sweep past the retention horizon — system call only")
    end
  end
end
