defmodule FluxVale.Accounts.Membership do
  @moduledoc """
  Join resource linking a User to an Organization with a role — the access
  model policies resolve against (#119, ADR-0030). A user appears at most
  once per organization (`unique_user_per_org`).

  Creation and destruction are system operations only (the JIT signup
  provisioning runs `authorize?: false`); actor-driven invitations and
  removals arrive with team features. Until then `forbid_if always()`
  closes the self-grant gap: no caller can make themselves (or anyone)
  an owner.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "memberships"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults id: "nil"

    # The composite unique_user_per_org index leads on organization_id, so
    # user_id-only lookups ("which orgs does this actor belong to?", used
    # by the Organization read policy and instance org resolution) need
    # their own index.
    custom_indexes do
      index [:user_id]
    end
  end

  policies do
    # An actor may read memberships for organizations they belong to.
    policy action_type(:read) do
      description "Members read their org's memberships"
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    policy action_type(:create) do
      description "System-only: signup provisioning (authorize?: false)"
      forbid_if(always())
    end

    policy action_type(:destroy) do
      description "System-only: org teardown (authorize?: false)"
      forbid_if(always())
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
      primary? true
      accept([:role, :organization_id, :user_id])
    end
  end

  code_interface do
    domain FluxVale.Accounts

    define(:create)
    define(:read)
    define(:destroy)
  end

  identities do
    identity(:unique_user_per_org, [:organization_id, :user_id])
  end
end
