defmodule FluxVale.Identity.PersonalAccessToken do
  @moduledoc """
  A scoped personal access token for the machine API (#360, ADR-0019
  Am. 1).

  The stored row is the token's *metadata*: an opaque single-part
  value (`fvpat_…`) is shown once at mint and only its SHA-256 hash
  is persisted — a DB leak reveals nothing reusable, and no
  long-lived signed credential exists to outlive a key compromise.
  `revoked_at` is the instant sever (the auth lookup refuses revoked
  rows); `expires_at` bounds the worst case at one year.

  Deliberately no JSON:API surface (a token is not a machine-API
  resource) and no AshAdmin (same stance as the rest of Identity,
  ADR-0027 §3). Mint/revoke ride the `FluxVale.Identity` operations.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Identity.PersonalAccessToken.ScopesCatalog
  alias FluxVale.Identity.PersonalAccessToken.SetRevokedAt

  postgres do
    table("personal_access_tokens")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    # on_delete :delete follows the BackupSetting precedent: the row
    # is pure derivative credential for the user — teardown of the
    # account takes its tokens along (no FK failure, no orphan a
    # lookup could never resolve).
    references do
      reference(:user, on_delete: :delete)
    end
  end

  policies do
    # The AND-together rule (UserEmail's posture): the admin grant
    # lives INSIDE each policy — a separate admin policy would still
    # require the owner expression on someone else's row.

    policy action_type(:create) do
      description("Users mint PATs for themselves; platform admins for anyone")
      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action_type(:read) do
      description("Platform admins or the token's owner read PAT rows")
      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action(:revoke) do
      description("Platform admins or the token's owner revoke a PAT")
      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
      authorize_if(expr(user_id == ^actor(:id)))
    end

    # :touch_last_used gets NO policy — default forbid. It is a system
    # write from the auth path (authorize?: false, comment there);
    # no actor-facing surface may stamp last-used.
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 100)
    end

    # SHA-256 hex digest of the raw value — the only form ever stored
    # or logged (ADR-0019 Am. 1). Sensitive so it never renders in
    # error output.
    attribute :token_hash, :string do
      allow_nil?(false)
      public?(false)
      sensitive?(true)
    end

    attribute :scopes, {:array, :string} do
      allow_nil?(false)
      default([])
      public?(true)
    end

    attribute(:last_used_at, :utc_datetime)

    # nil = live. The auth lookup refuses rows with a stamp — instant
    # sever, no janitor involved.
    attribute(:revoked_at, :utc_datetime)

    attribute :expires_at, :utc_datetime do
      allow_nil?(false)
      public?(true)
    end
  end

  relationships do
    belongs_to :user, FluxVale.Identity.User do
      allow_nil?(false)
      public?(false)
    end
  end

  actions do
    # Plain read is policy-gated to owner/admin (same stance as
    # UserEmail) and gives updates the primary read Ash's atomic
    # upgrade path requires.
    defaults([:read])

    create :create do
      primary?(true)
      accept([:name, :scopes, :expires_at, :user_id])

      # The digest rides a private argument and is force-set by the
      # builtin change (MirrorSignupEmail's posture): `accept` stays
      # the caller input surface — token_hash is never an attribute
      # input, only the system's digest of the generated value.
      argument(:token_hash, :string, allow_nil?: false, sensitive?: true, public?: false)
      change(set_attribute(:token_hash, arg(:token_hash)))

      # The catalog guard rejects off-catalog or duplicate scopes at
      # the resource, so no caller can bypass the mint operation's own
      # validation.
      validate(ScopesCatalog, where: changing(:scopes))
    end

    read :get do
      description("Fetch a PAT by id — owner or platform admin per policy")
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :get_by_token_hash do
      description("Resolve a PAT by token hash — the auth-path system lookup")
      get?(true)
      argument(:token_hash, :string, allow_nil?: false, sensitive?: true)
      filter(expr(token_hash == ^arg(:token_hash)))
    end

    read :list_for_user do
      description("A user's PAT rows — owner or platform admin per policy")
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(user_id == ^arg(:user_id)))
    end

    update :revoke do
      description("Revoke the token — idempotent: a second call keeps the original stamp")
      accept([])
      # SetRevokedAt reads the row's current state (idempotence) — a
      # plain change Ash cannot run atomically (set_primary's trade).
      require_atomic?(false)
      change(SetRevokedAt)
    end

    update :touch_last_used do
      description("Stamp last_used_at — system write from the auth path")
      accept([])
      change(set_attribute(:last_used_at, &DateTime.utc_now/0))
    end
  end

  code_interface do
    domain(FluxVale.Identity)

    define(:get, args: [:id])
    define(:get_by_token_hash, args: [:token_hash])
    define(:list_for_user, args: [:user_id])
    define(:revoke)
    define(:touch_last_used)
  end

  identities do
    # The auth lookup resolves by hash — unique by construction (a
    # collision would need a SHA-256 break).
    identity(:unique_token_hash, [:token_hash])
  end

  @doc """
  SHA-256 hex digest of a raw token value — the only thing ever
  stored. Lives here because both the mint operation and the auth
  lookup need the identical digest; the resource owns `token_hash`.
  """
  @spec token_hash(String.t()) :: String.t()
  def token_hash(raw) do
    :sha256
    |> :crypto.hash(raw)
    |> Base.encode16(case: :lower)
  end
end
