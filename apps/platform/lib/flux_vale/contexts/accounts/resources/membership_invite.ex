defmodule FluxVale.Accounts.MembershipInvite do
  @moduledoc """
  An organization's outstanding invitation (slice 4 of #408): the owner
  invites by email, the invitee accepts through a token-link landing
  page. Grant-shaped like Membership — `role` is the single enum axis
  (the Stripe-model owner ruling) — but this flow writes `:member`
  only: promotion arrives in slice 5 as an enum-value update on the
  SAME membership rows, and no owner path exists on this resource
  (the attribute is not accepted on :create).

  The stored row is the token's metadata: the raw token (32 url-safe
  bytes) exists only in the emailed link; the row carries its SHA-256
  hash alone (`token_hash/1`, the PersonalAccessToken posture). The
  token IS the invitee-side credential — the accept/decline writes run
  system-side (`authorize?: false`, the actions get no policy), and the
  identity fence is AcceptInvite's verified-primary-email match.

  One OPEN invite per (org, email): the partial unique index below is
  the race arbiter (an Ash identity cannot express the partial
  predicate); the invite seam's pre-check gives the friendly duplicate
  answer (the unique_slug posture). Accepted and revoked rows are
  history — the predicate frees the address for a re-invite.

  Deliberately no JSON:API surface (v1 stance) and no AshAdmin (the
  Accounts domain stays out of the /admin mount).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Accounts.MembershipInvite.AcceptMembership
  alias FluxVale.Accounts.MembershipInvite.SetRevokedAt
  alias FluxVale.Accounts.Organization
  alias FluxVale.Accounts.Types.MembershipRole

  # The invitation window — the mail copy reads ttl_days/0 so the
  # sentence and the row can never drift (the AuthCode TTL posture).
  @ttl_days 7

  postgres do
    table("membership_invites")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    custom_indexes do
      # One OPEN invite per (org, email) — the partial predicate is why
      # this is a custom index and not an Ash identity. citext equality
      # folds case, so "Alice@x.com" blocks "alice@x.com" at the index
      # exactly as the seam's pre-check does.
      index([:organization_id, :email],
        unique: true,
        where: "accepted_at IS NULL AND revoked_at IS NULL",
        name: "membership_invites_open_org_email"
      )
    end

    # The invite is a derivative credential of its org (the token only
    # means anything with the org around) — org teardown takes invites
    # along, no FK failure and no orphan a token lookup could never
    # resolve (the PersonalAccessToken reference posture).
    references do
      reference(:organization, on_delete: :delete)
    end
  end

  policies do
    # Same shape as Membership's read: members of the invite's org see
    # the org's invites (the pending list rides it).
    policy action_type(:read) do
      description("Org members read their organization's invites")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    # Inviting and revoking are the owner's call — mere members read
    # the roster, they do not grant access (the
    # ActorIsOrganizationOwner stance).
    policy action([:create, :revoke]) do
      description("Owners invite to and revoke invitations for their org")
      authorize_if(FluxVale.Checks.ActorOwnsInviteOrg)
    end

    policy action_type(:destroy) do
      description("Owners destroy the invite rows of their org")
      authorize_if(FluxVale.Checks.ActorOwnsInviteOrg)
    end

    # :accept and :decline get NO policy — default forbid for every
    # actor path (the PAT :touch_last_used posture). They are system
    # writes from the token path (authorize?: false from the
    # operations): the token is the bearer credential, the email match
    # is the identity fence.
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    # The invited address — compared case-folded at accept (citext
    # equality) against the invitee's VERIFIED PRIMARY email.
    attribute :email, :ci_string do
      allow_nil?(false)
      public?(true)
    end

    # The single enum axis on grant-shaped rows (the owner ruling).
    # This flow writes :member only and the attribute is never
    # accepted: the default is the only value any caller can produce.
    attribute :role, MembershipRole do
      allow_nil?(false)
      default(:member)
      public?(true)
    end

    # SHA-256 hex digest of the raw token — the only form ever stored
    # (the PersonalAccessToken stance). Sensitive so it never renders
    # in error output.
    attribute :token_hash, :string do
      allow_nil?(false)
      public?(false)
      sensitive?(true)
    end

    attribute :expires_at, :utc_datetime do
      allow_nil?(false)
      default(&__MODULE__.default_expires_at/0)
    end

    attribute(:accepted_at, :utc_datetime)
    attribute(:revoked_at, :utc_datetime)
  end

  relationships do
    belongs_to :organization, Organization do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      # organization_id and email only: role stays the :member default,
      # expires_at the window default, token_hash rides the private
      # argument (the MintPat posture) — no caller surface can mint an
      # owner grant or an arbitrary credential shape.
      accept([:organization_id, :email])

      argument(:token_hash, :string, allow_nil?: false, sensitive?: true, public?: false)
      change(set_attribute(:token_hash, arg(:token_hash)))
    end

    read :get_by_token_hash do
      description("Resolve an invite by token hash — the invitee token path")
      get?(true)

      argument(:token_hash, :string, allow_nil?: false, sensitive?: true)
      filter(expr(token_hash == ^arg(:token_hash)))

      # The token seam's single read feeds both the accept page's state
      # rendering and the accept/decline decisions: state and org ride
      # along so callers never re-derive them.
      prepare(fn query, _context -> Ash.Query.load(query, [:state, :organization]) end)
    end

    update :revoke do
      description("Revoke the invitation — idempotent: a second call keeps the original stamp")
      accept([])

      # SetRevokedAt reads the row's current state (idempotence) — a
      # plain change Ash cannot run atomically (the PAT revoke trade).
      require_atomic?(false)
      change(SetRevokedAt)
    end

    update :accept do
      description(
        "Accept the invitation — stamps accepted_at and joins the org in one transaction"
      )

      accept([])

      # The invitee's user id, resolved by AcceptInvite's email fence —
      # the action never takes membership identity from a caller
      # surface beyond the system operation (the token_hash argument
      # posture).
      argument(:user_id, :uuid, allow_nil?: false, public?: false)

      # Single-fire, single-open: the filter rides the UPDATE's WHERE
      # (the supersede_pending posture), so a second accept — or one
      # racing a revoke or expiry — matches nothing and refuses instead
      # of double-joining. The identity fence already ran in the
      # operation; this is the race arbiter.
      change(filter(expr(is_nil(accepted_at) and is_nil(revoked_at) and expires_at > now())))

      change(set_attribute(:accepted_at, &DateTime.utc_now/0))

      require_atomic?(false)
      change(AcceptMembership)
    end

    update :decline do
      description("Decline the invitation — revokes it from the invitee token path")
      accept([])

      # The same open-gate the accept filter carries: a decline can
      # only retire an invite nothing has happened to yet.
      change(filter(expr(is_nil(accepted_at) and is_nil(revoked_at) and expires_at > now())))

      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end
  end

  code_interface do
    domain(FluxVale.Accounts)

    define(:create)
    define(:get_by_token_hash, args: [:token_hash])
    define(:revoke)
    define(:decline)
    # :accept has no code interface — its user_id argument is private
    # (the system operation's fence-resolved value), and the interface's
    # input surface cannot carry private arguments (the MintPat shape:
    # for_update + set_argument).
  end

  calculations do
    # The accept page's whole state axis — one definition so the page,
    # the accept seam, and the decline seam cannot drift (order matters:
    # accepted wins over a later revoke, revoked wins over expiry).
    #
    # The `if` is Ash.Query.Function.If inside the expr DSL — not
    # Elixir's macro; the parenthesised call is the DSL's required
    # shape, so the readability check is disabled for these lines
    # (the Membership.user_email posture).
    #
    # credo:disable-for-lines:16 Credo.Check.Readability.ParenthesesInCondition
    calculate(
      :state,
      :atom,
      expr(
        if(
          is_nil(accepted_at),
          if(
            is_nil(revoked_at),
            if(expires_at > now(), :open, :expired),
            :revoked
          ),
          :accepted
        )
      )
    )
  end

  @doc "The invitation window in days — the mail copy reads it (see the @ttl_days comment)"
  @spec ttl_days() :: pos_integer()
  def ttl_days, do: @ttl_days

  @doc "The window's default stamp: the TTL days from now"
  @spec default_expires_at() :: DateTime.t()
  def default_expires_at do
    DateTime.add(DateTime.utc_now(), @ttl_days * 24 * 60 * 60, :second)
  end

  @doc """
  SHA-256 hex digest of a raw token value — the only thing ever stored.
  Lives here because the minting operation and the token lookup need
  the identical digest; the resource owns `token_hash` (the
  PersonalAccessToken posture).
  """
  @spec token_hash(String.t()) :: String.t()
  def token_hash(raw) do
    :sha256
    |> :crypto.hash(raw)
    |> Base.encode16(case: :lower)
  end
end
