defmodule FluxVale.OAuth.AuditEvent do
  @moduledoc """
  Append-only audit rows for the authorization server (#766): client
  registration, the consent decision, code issuance, token issuance
  and refresh, refresh-reuse detection, and revocation.

  Token-bound request/mint/revoke rows stay in
  `FluxVale.Api.AuditEvent` — an OAuth access token is a token row
  like any other. This table carries the events that happen before a
  token exists (or that span a whole connection family).

  System-only rows (the RequestWindow posture): empty policies, no
  actor surface, the guarded write seam
  (`FluxVale.OAuth.record_audit_event/1`) swallows a failed insert.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.OAuth,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("oauth_audit_events")
    repo(FluxVale.Repo)

    migration_defaults(id: "nil")

    # The audit trail outlives a deleted client; the id snapshot is
    # enough to answer "which client".
    references do
      reference(:oauth_client, on_delete: :nilify)
    end

    custom_indexes do
      index([:oauth_client_id, :created_at])
      index([:token_family_id, :created_at])
      index([:created_at])
    end
  end

  policies do
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)

    attribute :kind, FluxVale.OAuth.AuditKind do
      allow_nil?(false)
      public?(false)
    end

    attribute :actor_id, :uuid do
      public?(false)
    end

    attribute :token_family_id, :uuid do
      public?(false)
    end

    attribute :resource, :string do
      public?(false)
      constraints(max_length: 2048)
    end

    attribute :metadata, :map do
      allow_nil?(false)
      default(%{})
      public?(false)
    end
  end

  relationships do
    belongs_to :oauth_client, FluxVale.OAuth.Client do
      allow_nil?(true)
      public?(false)
    end
  end

  actions do
    defaults([])

    create :record do
      description("System write — one append-only OAuth audit row")

      accept([
        :kind,
        :oauth_client_id,
        :actor_id,
        :token_family_id,
        :resource,
        :metadata
      ])
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
