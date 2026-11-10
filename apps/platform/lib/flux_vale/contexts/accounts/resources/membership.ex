defmodule FluxVale.Accounts.Membership do
  @moduledoc """
  Join resource linking a User to an Organization with a role — the access
  model policies resolve against (#119, ADR-0030). A user appears at most
  once per organization (`unique_user_per_org`).

  Creation is system-only (the JIT signup provisioning runs
  `authorize?: false`), and two other sanctioned system writers exist:
  Organization's `:create_with_owner` writes the creator's owner
  membership in-transaction (its own policy is the gate), and
  invitations join through the token path (`MembershipInvite`'s accept
  transaction, slice 4 of #408) — neither rides this resource's create,
  so `forbid_if always()` still closes the self-grant gap: no caller
  can make themselves (or anyone) an owner here.

  The actor-facing lifecycle (slice 5 of #408) is three NAMED actions:
  owners set roles (`:set_role`) and remove members (`:remove_member`),
  a membership's own user leaves (`:leave`) — all guarded by
  LastOwnerGuard so an organization always keeps at least one owner.
  Ownership transfer composes: promote the successor, then demote or
  remove the old owner. The DEFAULT destroy stays system-only (org
  teardown).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Accounts.Membership.LastOwnerGuard

  postgres do
    table("memberships")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    # The composite unique_user_per_org index leads on organization_id, so
    # user_id-only lookups ("which orgs does this actor belong to?", used
    # by the Organization read policy and instance org resolution) need
    # their own index.
    custom_indexes do
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

    # An actor may read memberships for organizations they belong to.
    policy action_type(:read) do
      description("Members read their org's memberships")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    policy action_type(:create) do
      description("System-only: signup provisioning (authorize?: false)")
      forbid_if(always())
    end

    # By action NAME, not action_type (the wallet's :set_waiver
    # composition): the two lifecycle destroys below are the named
    # exceptions, and scoping this forbid to the DEFAULT destroy keeps
    # the scopes from overlapping — Ash composes applicable policies
    # with AND, so a policy that does not apply cannot veto. Org
    # teardown stays system-only.
    policy action(:destroy) do
      description("System-only: org teardown (authorize?: false)")
      forbid_if(always())
    end

    # The member lifecycle (slice 5 of #408): granting and revoking
    # standing is the owner's call (the ActorOwnsInviteOrg posture for
    # grant-shaped writes); leaving is the row's own user only.
    policy action(:set_role) do
      description("Owners set roles on their org's memberships")
      authorize_if(FluxVale.Checks.ActorOwnsMembershipOrg)
    end

    policy action(:remove_member) do
      description("Owners remove members from their org")
      authorize_if(FluxVale.Checks.ActorOwnsMembershipOrg)
    end

    policy action(:leave) do
      description("A membership's own user leaves — self only")
      authorize_if(relates_to_actor_via(:user))
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :role, FluxVale.Accounts.Types.MembershipRole do
      allow_nil?(false)
      default(:owner)
      public?(true)
    end
  end

  relationships do
    belongs_to :organization, FluxVale.Accounts.Organization do
      allow_nil?(false)
      public?(true)
    end

    belongs_to :user, FluxVale.Identity.User do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:role, :organization_id, :user_id])
    end

    # Member lifecycle (slice 5 of #408). All three run the record path
    # (`require_atomic?(false)`, the :revoke posture): the guard's
    # before_action needs the record transaction, and a raced write's
    # zero-row filter answers StaleRecord — the honest refusal —
    # instead of the atomic path's silent {:ok}.
    update :set_role do
      description("An owner sets the membership's org role (promote to owner, demote to member)")

      accept([:role])

      # LAST-OWNER GUARD: demoting the org's only owner is refused.
      change(LastOwnerGuard)

      require_atomic?(false)
    end

    destroy :remove_member do
      description("An owner removes a member from the org")

      # Removing YOURSELF is the :leave path — the actions stay
      # distinct (clearer policy, clearer copy). The filter rides the
      # DELETE's WHERE: a self-removal matches nothing and answers
      # StaleRecord instead of deleting the caller.
      change(filter(expr(user_id != ^actor(:id))))

      # LAST-OWNER GUARD: removing the org's only owner is refused.
      change(LastOwnerGuard)

      require_atomic?(false)
    end

    destroy :leave do
      description("The membership's own user leaves the org (an owner rides the same guard)")

      # LAST-OWNER GUARD: leaving as the org's only owner is refused.
      change(LastOwnerGuard)

      require_atomic?(false)
    end
  end

  code_interface do
    domain(FluxVale.Accounts)

    define(:create)
    define(:read)
    define(:destroy)
    define(:set_role)
    define(:remove_member)
    define(:leave)
  end

  identities do
    identity(:unique_user_per_org, [:organization_id, :user_id])
  end

  calculations do
    # The roster's email column (#276): User reads are :me/platform-admin
    # only, so co-member emails cannot ride a `:user` load. This calc
    # joins the email into the membership read — the org's membership read
    # policy is the gate (any member of the org may read the roster's
    # emails, including through the domain); the LiveView's owner gate is
    # UI-only, not the column's protection.
    #
    # #285 T4, #287: the column shows the member's PRIMARY address,
    # straight from user_emails — the mirror-era fallback died with the
    # column (a nil primary is data drift now, rendered as nil).
    calculate(
      :user_email,
      :string,
      expr(user.primary_email)
    )
  end
end
