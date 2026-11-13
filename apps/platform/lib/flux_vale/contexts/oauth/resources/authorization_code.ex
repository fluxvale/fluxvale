defmodule FluxVale.OAuth.AuthorizationCode do
  @moduledoc """
  One authorization code (#766): 60 seconds, single use, bound to the
  client, the exact redirect URI, the PKCE challenge, the granted
  scopes, and the RFC 8707 resource.

  Only the SHA-256 hash is stored — the raw code crosses the wire once
  in the redirect and is never recoverable from the row. The consume
  action pins `consumed_at IS NULL` into the UPDATE, so a reused code
  loses the race and answers `invalid_grant`; the family id stamped at
  consume lets a detected reuse revoke the tokens that code produced.

  System-only rows (the RequestWindow posture): empty policies, no
  actor surface, the authorization-server operations call
  `authorize?: false`.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.OAuth,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.OAuth.AuthorizationCode.RequireUnconsumed

  postgres do
    table("oauth_authorization_codes")
    repo(FluxVale.Repo)

    migration_defaults(id: "nil")

    references do
      reference(:user, on_delete: :delete)
      reference(:client, on_delete: :delete)
    end
  end

  policies do
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)

    attribute :code_hash, :string do
      allow_nil?(false)
      public?(false)
      sensitive?(true)
      constraints(max_length: 64)
    end

    attribute :redirect_uri, :string do
      allow_nil?(false)
      public?(false)
      constraints(max_length: 2048)
    end

    attribute :scopes, {:array, :string} do
      allow_nil?(false)
      default([])
      public?(false)
    end

    attribute :resource, :string do
      allow_nil?(false)
      public?(false)
      constraints(max_length: 2048)
    end

    attribute :code_challenge, :string do
      allow_nil?(false)
      public?(false)
      constraints(max_length: 128)
    end

    attribute :code_challenge_method, :string do
      allow_nil?(false)
      default("S256")
      public?(false)
      constraints(match: ~r/\AS256\z/)
    end

    attribute :expires_at, :utc_datetime do
      allow_nil?(false)
      public?(false)
    end

    attribute :consumed_at, :utc_datetime do
      public?(false)
    end

    # Stamped at consume so a detected reuse can revoke everything the
    # code produced.
    attribute :token_family_id, :uuid do
      public?(false)
    end
  end

  relationships do
    belongs_to :client, FluxVale.OAuth.Client do
      allow_nil?(false)
      public?(false)
    end

    belongs_to :user, FluxVale.Identity.User do
      allow_nil?(false)
      public?(false)
    end
  end

  actions do
    defaults([])

    create :issue do
      description("System write — one 60-second authorization code")

      accept([
        :code_hash,
        :redirect_uri,
        :scopes,
        :resource,
        :code_challenge,
        :code_challenge_method,
        :expires_at,
        :client_id,
        :user_id
      ])

      validate(FluxVale.Identity.PersonalAccessToken.ScopesCatalog, where: changing(:scopes))
    end

    read :get_by_code_hash do
      description("Resolve a code by its hash — the token endpoint's system lookup")
      get?(true)
      argument(:code_hash, :string, allow_nil?: false, sensitive?: true)
      filter(expr(code_hash == ^arg(:code_hash)))
    end

    read :stale do
      description("Codes past the cutoff — the janitor prune feed")
      argument(:cutoff, :utc_datetime, allow_nil?: false)
      filter(expr(expires_at < ^arg(:cutoff)))
    end

    update :consume do
      description("Single-use consume — stamps consumed_at and the token family")
      accept([])
      argument(:token_family_id, :uuid, allow_nil?: false, public?: false)
      require_atomic?(false)
      change(RequireUnconsumed)
      change(set_attribute(:consumed_at, &DateTime.utc_now/0))
      change(set_attribute(:token_family_id, arg(:token_family_id)))
    end

    destroy :expunge_stale do
      description("Janitor sweep past the retention horizon — system call only")
    end
  end

  code_interface do
    domain(FluxVale.OAuth)

    define(:issue)
    define(:get_by_code_hash, args: [:code_hash])
  end

  identities do
    identity(:unique_code_hash, [:code_hash])
  end
end
