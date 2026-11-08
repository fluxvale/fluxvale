defmodule FluxVale.Infrastructure.PocketIdCustody do
  @moduledoc """
  The org's held PocketID admin API key — custody, not possession
  (#597 §4.3, the SetAccessApiToken discipline): the key lives in a
  cluster Secret the platform owns, this row carries only the
  Secret's NAME (`api_key_secret_ref`), and no user surface reads
  the value back (the read seam is internal, `use_pocket_id_key`).

  One row per (organization, PocketID instance) — the identity
  `unique_per_instance`. A re-paste upserts in place: Secret first
  (SSA), row second (the recovery property, SetAccessApiToken's
  order).

  `verified_at` is the last successful live verification against the
  PocketID's own API (paste-time); `expires_at` is the best-effort
  display nicety (nil = managed in Pocket ID).

  Writes are the operations' (Set/Use/RevokePocketIdKey) — the owner
  gate is the operation's, the SetAccessApiToken stance: this key is
  full admin over the org's identity provider, so pasting it is the
  owner's call alone, enforced with the ActorIsOrganizationOwner
  predicate before any cluster write. The row-write funnels below run
  `authorize?: false` (the ops' own authorization already happened).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Accounts.Organization
  alias FluxVale.Infrastructure.Instance

  postgres do
    table("pocket_id_custodies")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job.
    migration_defaults(id: "nil")

    custom_indexes do
      # The org's custody lookups (the detection read, #597 S3).
      index([:organization_id])
    end

    references do
      # Restrict, not cascade (the AccessGateway stance): a cascade
      # would drop the row while the key's Secret keeps living in the
      # access namespace with no row left for any sweep to find. Org
      # deletion is not a supported flow yet.
      reference(:organization, on_delete: :restrict)

      # CASCADE, deliberately — the opposite of the org's restrict: the
      # instance teardown hard-deletes the row, and a restrict here
      # would wedge it (Oban retry loop, a :deleting instance with no
      # owner way out) whenever a PocketID is destroyed while custody
      # exists. Custody dies with its subject (the snapshot stance);
      # the access-namespace Secret is a known residue until #597 S5's
      # destroy-time best-effort cleanup (the D6 family) — a key for a
      # destroyed PocketID commands nothing.
      reference(:instance, on_delete: :delete)
    end
  end

  policies do
    policy action_type(:read) do
      description("Members read their org's custody state (the card)")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    # System-only funnels, the set_api_token_ref stance: the owner
    # gate lives in the operations (ActorIsOrganizationOwner against
    # the instance's org, before any cluster write), so these actions
    # are the ops' private writes — every caller runs authorize?:
    # false with that comment in place.
    policy action_type([:create, :update, :destroy]) do
      description("System-only: the custody operations own the writes (authorize?: false)")
      forbid_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    # The Secret's NAME in the access namespace — never the key. The
    # naming rule is the store operation's (it owns the write).
    attribute :api_key_secret_ref, :string do
      allow_nil?(false)
      public?(false)
    end

    # Last successful live verification (paste-time). The honest
    # "verified" stamp the card shows.
    attribute :verified_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(false)
    end

    # Best-effort display (#597 S2 nicety): the correlated key's
    # expiry, nil when ambiguous or unknown — "managed in Pocket ID".
    attribute :expires_at, :utc_datetime_usec do
      public?(false)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :organization, Organization do
      allow_nil?(false)
      public?(false)
    end

    # The PocketID instance whose admin key the platform holds.
    belongs_to :instance, Instance do
      allow_nil?(false)
      public?(false)
    end
  end

  actions do
    defaults([])

    read :read do
      description("The members' read (the card and the detection seam).")
      primary?(true)
    end

    read :get_by_instance do
      description("The instance's custody row, if any (one per identity).")
      get?(true)
      argument(:instance_id, :uuid, allow_nil?: false)
      filter(expr(instance_id == ^arg(:instance_id)))
    end

    read :for_organization do
      description("Every custody row the org holds (the detection read, #597 S3).")
      argument(:organization_id, :uuid, allow_nil?: false)
      filter(expr(organization_id == ^arg(:organization_id)))
    end

    # The store op's funnel: Secret first, row second. Runs
    # authorize?: false — the op's owner gate already passed.
    create :record do
      description("System-only: record the custody after the Secret landed.")
      accept([:organization_id, :instance_id, :api_key_secret_ref, :verified_at, :expires_at])
    end

    # The re-paste funnel (a replace writes the new Secret, then this).
    update :record_replacement do
      description("System-only: a verified re-paste — new ref, new stamps.")
      accept([:api_key_secret_ref, :verified_at, :expires_at])
      require_atomic?(false)
    end

    # The revoke op's funnel, after the Secret is gone.
    destroy :revoke do
      description("System-only: drop the custody row (the Secret is deleted first).")
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:get_by_instance, args: [:instance_id])
    define(:for_organization, args: [:organization_id])
    define(:record)
    define(:record_replacement)
    define(:revoke)
  end

  identities do
    identity(:unique_per_instance, [:organization_id, :instance_id])
  end
end
