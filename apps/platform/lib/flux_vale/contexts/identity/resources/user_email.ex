defmodule FluxVale.Identity.UserEmail do
  @moduledoc """
  One of a user's email addresses (identity lane #285): `verified_at` nil
  means a pending claim, `is_primary` marks the account's main address.

  Since T3 this table IS the account's identity: sign-in resolves
  through it (`User.get_by_email`), the session/token gates read it, and
  every create stamps a verified-primary row (the mirror — `users.email`
  stays as a frozen column for old pods during rolling deploys).

  An address belongs to at most one account at a time
  (`unique_address`), and a user keeps at most one primary (the partial
  index — a plain unique `[:user_id]` would cap the whole table at one
  row per user).

  Deliberately no JSON:API surface and no AshAdmin (same stance as the
  rest of Identity, ADR-0027 §3).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Identity.UserEmail.EnforceEmailCap
  alias FluxVale.Identity.UserEmail.RemoveGuard
  alias FluxVale.Identity.UserEmail.SetPrimary

  # Defined before the section that consumes it; EnforceEmailCap reads it
  # via max_emails_per_user/0 so the cap and its enforcement can't drift.
  @max_emails_per_user 5

  # The address format rule — one source: the validation below and the
  # code-send gate (RequestAuthCode, via valid_address?/1) both read it.
  @address_format ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  postgres do
    table("user_emails")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    custom_indexes do
      # At most one primary per user — the partial index is the arbiter
      # (races included, as a plain unique constraint would be).
      index([:user_id], unique: true, where: "is_primary")
    end
  end

  policies do
    # No AshAuthenticationInteraction bypass: no AshAuthentication strategy
    # touches this resource (User/AuthCode/Token are the strategy
    # surfaces), and the future identity operations run actions with
    # authorize?: false — never the interaction context.

    # Same stance as User's :me: always() is honest because the action's
    # actor filter already constrains the result to the caller's rows —
    # it cannot leak another user's addresses.
    policy action(:mine) do
      description("Users read their own email rows")
      authorize_if(always())
    end

    policy action(:read) do
      description("Platform admins read all user emails")
      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
    end

    # Writes: the changeset's user_id must be the actor's id — a user may
    # only add to, or touch, their own rows. Admins manage all rows.
    # NOTE: applicable policies AND together (the docs' "all applicable
    # policies must pass"), so the admin grant lives inside each write
    # policy — a separate admin policy would still require the owner
    # expression to pass on someone else's row.
    policy action_type(:create) do
      description("Users add emails to their own account")
      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
      authorize_if(expr(user_id == ^actor(:id)))
    end

    # Verification is proven by holding a verified auth code, not by
    # being the row's owner — an owner stamping verified_at themselves
    # would hollow out every guard that reads it (set_primary, remove).
    # The identity operation calls this with authorize?: false (internal
    # path, same posture as the seeds); admins keep a management path.
    policy action(:mark_verified) do
      description("Platform admins stamp verification")
      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
    end

    policy action(:set_primary) do
      description("Users promote their own email rows")
      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
      authorize_if(expr(user_id == ^actor(:id)))
    end

    # Internal-only: SetPrimary's sibling demotion runs authorize?: false.
    # Owner-reachable unset_primary could demote the account's ONLY
    # primary — and nothing else on the resource preserves at-least-one
    # (the partial index is at-most-one).
    policy action(:unset_primary) do
      description("Platform admins — :unset_primary is SetPrimary's internal step")
      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
    end

    policy action_type(:destroy) do
      description("Users remove their own email rows")
      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
      authorize_if(expr(user_id == ^actor(:id)))
    end
  end

  attributes do
    # ADR-0032: UUIDv7 — explicit default required (the built-in still
    # generates v4)
    uuid_primary_key(:id, type: :uuid_v7, default: &Ash.UUIDv7.generate/0)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :address, :ci_string do
      allow_nil?(false)
      public?(false)
    end

    # nil = pending claim; stamped by :mark_verified (the identity
    # operation holding a verified auth code — VerifyEmail, T3)
    attribute(:verified_at, :utc_datetime)

    attribute :is_primary, :boolean do
      allow_nil?(false)
      default(false)
    end
  end

  relationships do
    belongs_to :user, FluxVale.Identity.User do
      allow_nil?(false)
      public?(false)
    end
  end

  actions do
    # Plain read: admins only under the policies below (owners go through
    # :mine; the change modules count via authorize?: false, which needs a
    # primary read action).
    defaults([:read])

    # The cap invariant is checked in EnforceEmailCap (change modules run
    # inside the create transaction — a plain validation cannot query).
    create :add do
      description("Attach a new, pending email address to the user")
      accept([:address])
      argument(:user, :map, allow_nil?: false)
      change(manage_relationship(:user, type: :append_and_remove))
      change(EnforceEmailCap)
    end

    read :mine do
      description("The actor's own email rows")
      filter(expr(user_id == ^actor(:id)))
    end

    update :mark_verified do
      description(
        "Stamp verified_at — invoked only by identity operations holding a verified auth code"
      )

      accept([])
      change(set_attribute(:verified_at, &DateTime.utc_now/0))
    end

    # require_atomic? false: SetPrimary reads and updates the sibling rows
    # in the same transaction — a function change Ash cannot run
    # atomically (the trade Organization's update makes).
    update :set_primary do
      description("Make this the user's primary address (unsets the others)")
      require_atomic?(false)
      accept([])
      change(SetPrimary)
    end

    # require_atomic? false: RemoveGuard may refuse based on sibling rows
    # (last verified) — same trade as set_primary above.
    destroy :remove do
      description("Remove a non-primary address (a verified one only when others remain)")
      require_atomic?(false)
      accept([])
      change(RemoveGuard)
    end

    # Internal counterpart to :set_primary, called by SetPrimary on the
    # sibling rows inside the same transaction (authorize?: false — the
    # entry action's policy already gated the caller). Internal-only by
    # policy: owner-reachable demotion could leave a zero-primary user.
    update :unset_primary do
      description("Demote this address (internal — SetPrimary's sibling step)")
      accept([])
      change(set_attribute(:is_primary, false))
    end
  end

  code_interface do
    domain(FluxVale.Identity)

    define(:add, args: [:address])
    define(:mine)
    define(:mark_verified)
    define(:set_primary)
    define(:remove)
  end

  identities do
    # An address belongs to at most one account at a time; removing a row
    # frees it for the next claimant.
    identity(:unique_address, [:address])
  end

  validations do
    # `where: changing` scopes the check to addresses actually being set
    # (create always sets one) — the Organization.update posture.
    validate(match(:address, @address_format),
      on: [:create, :update],
      where: changing(:address),
      message: "must be a valid email address"
    )
  end

  @doc "The address format rule (shared with the code-send gate — see RequestAuthCode)"
  @spec valid_address?(String.t() | Ash.CiString.t()) :: boolean()
  def valid_address?(address) do
    address
    |> to_string()
    |> String.match?(@address_format)
  end

  @doc "The per-user email cap (see EnforceEmailCap)"
  @spec max_emails_per_user() :: pos_integer()
  def max_emails_per_user, do: @max_emails_per_user
end
