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

  Derived mints (#772) carry their parent's id in `metadata`: the
  auth path rides that chain, the create action enforces a per-user
  live-token cap, and revocation cascades to the minted subtree.

  Deliberately no JSON:API surface (a token is not a machine-API
  resource) and no AshAdmin (same stance as the rest of Identity,
  ADR-0027 §3). Mint/revoke ride the `FluxVale.Identity` operations.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Identity,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Identity.PersonalAccessToken.EnforceDerivedTokenCap
  alias FluxVale.Identity.PersonalAccessToken.ScopesCatalog
  alias FluxVale.Identity.PersonalAccessToken.SetRevokedAt

  require Ash.Query

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
      # #766: deleting a registered client takes its token rows along
      # (the derivative-credential posture; no orphan can resolve).
      reference(:oauth_client, on_delete: :delete)
    end

    custom_indexes do
      # The connection-family read (settings Disconnect, refresh reuse)
      # filters and orders on the family.
      index([:token_family_id])
      index([:oauth_client_id])

      # The panel's list and the derived-token cap count both filter
      # by user (#772) — the FK carries no index by itself.
      index([:user_id])
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
    # Decision two (ADR-0048): the auth path stamps last_used_at on
    # every authenticated PAT request — machine-cadence churn, the
    # Post counters stance. ignore_attributes filters the diff, but
    # 0.8.1's write trigger is the changeset's changed? flag, so the
    # touch action is silenced by name too.
    ignore_attributes([:created_at, :updated_at, :last_used_at])
    ignore_actions([:touch_last_used])
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

    # Mint provenance (#362 T3, OQ #9): who/what the token was minted
    # for — the device flow stamps client_id, grant_type, the granted
    # scopes (self-describing provenance; the column above is the
    # enforcement half) and minted_via. System-written at mint only:
    # no update action accepts it, so it never drifts from mint time.
    # No JSON:API surface exposes it (not a machine-API resource; the
    # AshAdmin stance covers Identity wholesale, ADR-0027 §3).
    attribute :metadata, :map do
      allow_nil?(false)
      default(%{})
      public?(false)
    end

    attribute(:last_used_at, :utc_datetime)

    # nil = live. The auth lookup refuses rows with a stamp — instant
    # sever, no janitor involved.
    attribute(:revoked_at, :utc_datetime)

    attribute :expires_at, :utc_datetime do
      allow_nil?(false)
      public?(true)
    end

    # #766: the row's credential class. PATs keep the :pat default
    # (every existing row and every existing caller is unchanged);
    # OAuth access/refresh rows are minted only by the authorization
    # server's create_oauth action.
    attribute :kind, FluxVale.Identity.PersonalAccessToken.Kind do
      allow_nil?(false)
      default(:pat)
      public?(false)
    end

    # The OAuth binding: which registered client a token pair belongs
    # to, the RFC 8707 resource it was issued for, and the rotation
    # family shared by an access/refresh pair. All nil on PATs.
    attribute :resource, :string do
      public?(false)
      constraints(max_length: 2048)
    end

    attribute :token_family_id, :uuid do
      public?(false)
    end
  end

  relationships do
    belongs_to :user, FluxVale.Identity.User do
      allow_nil?(false)
      public?(false)
    end

    belongs_to :oauth_client, FluxVale.OAuth.Client do
      allow_nil?(true)
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
      # builtin change (SignupEmailRow's posture): `accept` stays
      # the caller input surface — token_hash is never an attribute
      # input, only the system's digest of the generated value.
      argument(:token_hash, :string, allow_nil?: false, sensitive?: true, public?: false)
      change(set_attribute(:token_hash, arg(:token_hash)))

      # Mint provenance rides the same shape (#362): a private
      # argument the mint operation sets, never an accepted input —
      # no caller surface can stamp a row's provenance directly. The
      # default keeps an omitted argument at the attribute's empty-map
      # default (a plain arg() reference is always truthy — the `||`
      # fallback would be dead and a bare nil write would trip the
      # attribute's allow_nil?).
      argument(:metadata, :map, allow_nil?: false, default: %{}, public?: false)
      change(set_attribute(:metadata, arg(:metadata)))

      # The catalog guard rejects off-catalog or duplicate scopes at
      # the resource, so no caller can bypass the mint operation's own
      # validation.
      validate(ScopesCatalog, where: changing(:scopes))

      # The derived-token cap (#772) rides the resource too: a caller
      # that bypasses the mint operation still cannot outrun it.
      change(EnforceDerivedTokenCap)
    end

    # #766: the authorization server's mint — the same table and the
    # same hash/scopes/expiry machinery, plus the OAuth binding. A
    # dedicated action keeps the PAT create surface untouched and makes
    # the kind/ client / resource / family fields system-only (private
    # arguments, never accepted from a caller).
    create :create_oauth do
      description("System write — one OAuth access or refresh token row")
      accept([:name, :scopes, :expires_at, :user_id])

      argument(:token_hash, :string, allow_nil?: false, sensitive?: true, public?: false)
      argument(:kind, :atom, allow_nil?: false, public?: false)
      argument(:oauth_client_id, :uuid, allow_nil?: false, public?: false)
      argument(:resource, :string, allow_nil?: false, public?: false)
      argument(:token_family_id, :uuid, allow_nil?: false, public?: false)
      argument(:metadata, :map, allow_nil?: false, default: %{}, public?: false)

      change(set_attribute(:token_hash, arg(:token_hash)))
      change(set_attribute(:kind, arg(:kind)))
      change(set_attribute(:oauth_client_id, arg(:oauth_client_id)))
      change(set_attribute(:resource, arg(:resource)))
      change(set_attribute(:token_family_id, arg(:token_family_id)))
      change(set_attribute(:metadata, arg(:metadata)))

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
      filter(expr(user_id == ^arg(:user_id) and kind == :pat))
    end

    # #766: the settings page's Connected apps section reads OAuth
    # token rows separately — the API tokens panel must keep showing
    # PATs only, and vice versa.
    read :list_oauth_tokens do
      description("A user's OAuth token rows — owner or platform admin per policy")
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(user_id == ^arg(:user_id) and kind in [:oauth_access, :oauth_refresh]))
    end

    read :list_oauth_family do
      description("One OAuth connection family — owner or platform admin per policy")
      argument(:user_id, :uuid, allow_nil?: false)
      argument(:token_family_id, :uuid, allow_nil?: false)
      filter(expr(user_id == ^arg(:user_id) and token_family_id == ^arg(:token_family_id)))
    end

    update :revoke do
      description("Revoke the token — idempotent: a second call keeps the original stamp")
      accept([])
      # SetRevokedAt reads the row's current state (idempotence) — a
      # plain change Ash cannot run atomically (set_primary's trade).
      require_atomic?(false)
      change(SetRevokedAt)
    end

    # #766: rotation's conditional sever. Unlike :revoke (idempotent by
    # contract), this one only wins while the row is live — a stale
    # refusal is the refresh-reuse signal.
    update :revoke_if_live do
      description("Revoke only a live token — the OAuth refresh rotation's race guard")
      accept([])
      require_atomic?(false)
      change(FluxVale.Identity.PersonalAccessToken.RequireLive)
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
    define(:list_oauth_tokens, args: [:user_id])
    define(:list_oauth_family, args: [:user_id, :token_family_id])
    define(:revoke)
    define(:revoke_if_live)
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

  @doc """
  Count of a user's live minted tokens (#772) — the derived-token
  cap's SQL count. System read: the cap guard has already resolved
  the user, and the count is an invariant, not an authorization
  question.
  """
  @spec count_live_derived!(String.t(), DateTime.t()) :: non_neg_integer()
  def count_live_derived!(user_id, now) do
    __MODULE__
    |> Ash.Query.filter(
      user_id == ^user_id and is_nil(revoked_at) and expires_at > ^now and
        fragment("(?->>'minted_parent_id') IS NOT NULL", metadata)
    )
    |> Ash.count!(authorize?: false)
  end

  @doc """
  A user's live tokens minted from `parent_id` (#772) — the revoke
  cascade's read. System read: revoking the parent already passed
  policy; severing the subtree it minted is the consequence.
  """
  @spec live_derived_children!(String.t(), String.t(), DateTime.t()) :: [t()]
  def live_derived_children!(user_id, parent_id, now) do
    __MODULE__
    |> Ash.Query.filter(
      user_id == ^user_id and is_nil(revoked_at) and expires_at > ^now and
        fragment("(?->>'minted_parent_id') = ?", metadata, ^parent_id)
    )
    |> Ash.read!(authorize?: false)
  end
end
