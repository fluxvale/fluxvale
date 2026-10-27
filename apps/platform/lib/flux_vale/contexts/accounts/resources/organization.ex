defmodule FluxVale.Accounts.Organization do
  @moduledoc """
  Organization — the ownership entity for platform resources (#119,
  ADR-0030): instances attach to it (the entitlement boundary), wallets
  attach to it (the billing boundary, M5), and it is the abuse boundary
  for per-org entitlements (welcome credits, #122).

  Every user gets a personal org at signup (JIT, creator = owner — see
  `FluxVale.Accounts.provision_personal_org/1`). `slug` is the unique
  address (`[a-z0-9-]`, GitHub-style) — stable until an owner renames it
  in settings: the old slug is released immediately and no redirect is
  created. `name` is display-only and carries no uniqueness — two orgs
  may be named alike, the slug cannot.

  Deliberately no JSON:API surface (v1 stance — backend model until a
  consumer needs one) and no AshAdmin (no support flow needs it yet).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Accounts.Membership

  require Ash.Query

  postgres do
    table "organizations"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults id: "nil"
  end

  policies do
    policy action_type(:read) do
      description "Members read their organizations"
      authorize_if(relates_to_actor_via(:members))
    end

    policy action_type(:create) do
      description "System-only: JIT provisioning (authorize?: false). Actor-driven creation waits for the team-features flow that members the creator in the same transaction — without it, a created org is unreadable even by its creator."
      forbid_if(always())
    end

    # Team features will gate destroy on the :owner role; today every
    # membership is :owner (provisioning only creates owners), so
    # member-level authorization is safe. Revisit trigger: the first
    # :member membership.
    policy action_type(:destroy) do
      description "Members destroy their organizations"
      authorize_if(relates_to_actor_via(:members))
    end

    # The first rename flow (#276): owners set the display name and the
    # URL slug — GitHub-parity renaming, the owner's explicit choice.
    policy action(:update) do
      description "Owners update their organization (display name and slug)"
      authorize_if(FluxVale.Checks.ActorIsOrganizationOwner)
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :slug, :string do
      allow_nil?(false)
      public?(true)
    end
  end

  relationships do
    has_many :memberships, Membership do
      public?(true)
    end

    many_to_many :members, FluxVale.Identity.User do
      through(Membership)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    # Membership rows have no delete cascade and their destroy policy is
    # system-only, so the default destroy would FK-fail. Empty-org teardown
    # clears them first (system op — the destroy policy already gated the
    # caller). Instances and the wallet also FK the org: teardown of THOSE
    # is #124's design — destroying a non-empty org still fails loudly.
    destroy :destroy do
      primary? true
      require_atomic?(false)

      change(fn changeset, _context ->
        org_id = changeset.data.id

        Ash.Changeset.before_action(changeset, fn changeset ->
          Membership
          |> Ash.Query.for_read(:read, %{})
          |> Ash.Query.filter(organization_id == ^org_id)
          |> Ash.read!(authorize?: false)
          |> Enum.each(&Ash.destroy!(&1, authorize?: false))

          changeset
        end)
      end)
    end

    create :create do
      primary? true
      accept([:name, :slug])
    end

    # Renaming — either field — frees the old slug immediately: no
    # redirects and no slug reservations ship with this flow. Revisit
    # trigger: org creation or any public org surface.
    #
    # require_atomic? false: the stale-form guard below is a function
    # change, which Ash cannot run atomically — the trade the destroy
    # action already makes. A rename is a single-row, owner-initiated
    # write; failing loudly on a moved row is worth more than batch
    # atomicity.
    update :update do
      primary? true
      require_atomic?(false)
      accept([:name, :slug])

      # Stale-form guard: the write is filtered on the slug the caller
      # loaded, so a view mounted before a rename fails with StaleRecord
      # instead of silently writing the old address back (the
      # observe_access_gateway idiom; Instance's optimistic_lock(:version)
      # is the same contract with a counter). No original row (query-bulk
      # updates) → no slug to lock on — the guard can't apply there, and
      # nothing in the system bulk-updates orgs.
      change(fn changeset, _context ->
        case Map.get(changeset.data, :slug) do
          # Dead in practice, kept so a slug-less shape can never add a
          # nil filter: bulk :atomic strategies are rejected before any
          # change runs (function changes implement no atomic/3), and
          # streamed/record changesets always carry the loaded row.
          # coveralls-ignore-next-line
          nil -> changeset
          loaded_slug -> Ash.Changeset.filter(changeset, slug: loaded_slug)
        end
      end)
    end

    read :get_by_id do
      description "Get an organization by id"
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :get_by_slug do
      description "Get an organization by slug"
      get?(true)
      argument(:slug, :string, allow_nil?: false)
      filter(expr(slug == ^arg(:slug)))
    end
  end

  code_interface do
    domain FluxVale.Accounts

    define(:create)
    define(:update)
    define(:get_by_id, args: [:id])
    define(:get_by_slug, args: [:slug])
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  validations do
    # on: :update rides with the rename flow (#276) — the rename path
    # must not ship unvalidated. `where: changing` scopes it to slugs
    # actually being set (create always sets one), which is also what
    # keeps the update atomic — the engine can't re-check an untouched
    # attribute. `unique_slug` stays the uniqueness arbiter; unchanged
    # attributes skip it, so a same-slug save (a name-only edit) never
    # self-conflicts.
    validate(match(:slug, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/),
      on: [:create, :update],
      where: changing(:slug),
      message: "must contain only lowercase alphanumeric characters and hyphens"
    )

    # The length caps bind the RENAME flow only — never the create. The
    # slug is the sanitized email local part at signup, and a 64-char RFC
    # local part is legal; capping the attribute turned a 40-char local
    # part into a retry-proof signup outage (the code burns before the
    # provisioning failure surfaces). Legacy rows with longer slugs keep
    # saving: `where: changing` skips untouched fields.
    validate(string_length(:slug, max: 39),
      on: :update,
      where: changing(:slug),
      message: "must be at most 39 characters"
    )

    validate(string_length(:name, max: 100),
      on: :update,
      where: changing(:name),
      message: "must be at most 100 characters"
    )
  end
end
