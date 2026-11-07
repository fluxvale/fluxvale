defmodule FluxVale.Accounts.Organization do
  @moduledoc """
  Organization — the ownership entity for platform resources (#119,
  ADR-0030): instances attach to it (the entitlement boundary), wallets
  attach to it (the billing boundary, M5), and it is the abuse boundary
  for per-org entitlements (welcome credits, #122).

  Every user gets a personal org at signup (JIT, creator = owner — see
  `FluxVale.Accounts.provision_personal_org/1`). Which org IS a user's
  personal one is an explicit fact, not a derivation (#408): an org is
  that user's account-surface org exactly when `personal_owner_id`
  names them — provisioning stamps it at signup, null marks the team
  orgs the user-created-orgs flow produces (`create_with_owner`), and
  `unique_personal_owner` keeps one marked org per user. `slug` is the
  unique address (`[a-z0-9-]`, GitHub-style) — stable until an owner
  renames it in settings: the old slug is released immediately and no
  redirect is created. `name` is display-only and carries no uniqueness
  — two orgs may be named alike, the slug cannot.

  Deliberately no AshAdmin domain mount (no support flow needs it yet);
  the JSON:API surface is one identity-adjacent route — the actor's own
  orgs (GET /api/v1/organizations, #362 T6a) — nothing org-scoped.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    # AshAdmin.Resource is for the DISPLAY contract only (see the admin
    # block below) — the Accounts domain stays out of the /admin mount
    # (the config.exs domain opt-in governs what shows; this extension
    # only teaches the resource how to render when referenced).
    # AshJsonApi.Resource serves the one route below (#362 T6a).
    extensions: [AshAdmin.Resource, AshJsonApi.Resource]

  alias FluxVale.Accounts.Membership

  require Ash.Query

  # #362 T6a: the one org route — the actor's own orgs for the CLI's
  # discovery (`wallet balance` needs an org id; the API had none).
  # Identity-adjacent like /me: the switcher's fields (id, slug, name)
  # and nothing org-internal.
  json_api do
    type("organization")

    routes do
      index(:list_for_actor,
        route: "/organizations",
        default_fields: [:id, :slug, :name]
      )
    end
  end

  policies do
    policy action_type(:read) do
      description("Members read their organizations")
      authorize_if(relates_to_actor_via(:members))
    end

    # System-only by policy (the JIT provisioning writer runs
    # authorize?: false). Narrowed to action(:create), NOT
    # action_type(:create): the type-wide form also matches
    # :create_with_owner, and a forbid_if that matches in any
    # applicable policy vetoes everything — the actor path could never
    # be granted. The actor-reachable creation flow is
    # :create_with_owner below — signed-in actors below the owned-org
    # cap (#408).
    policy action(:create) do
      description(
        "System-only: JIT provisioning (authorize?: false). Actor-driven creation is :create_with_owner — signed-in actors below the owned-org cap, members as owner in-transaction (#408)."
      )

      forbid_if(always())
    end

    # The actor path (#408): any signed-in user below the cap creates a
    # team org, its owner membership written inside the action's
    # transaction. The COMPOSITION is the load-bearing part:
    # forbid_unless forbids a missing actor outright, and a present
    # actor passes only if the cap check authorizes — over-cap falls
    # off the end into the default forbidden. Two authorize_ifs would
    # be OR (the first true wins) and let an over-cap user through on
    # the actor-present check; the order of THESE two checks, by
    # contrast, is not load-bearing (both orders decide alike).
    policy action(:create_with_owner) do
      description("Signed-in actors below the org-creation cap create team orgs (#408)")
      forbid_unless(actor_present())
      authorize_if(FluxVale.Checks.ActorBelowOrgCreateCap)
    end

    # Destroying an organization is the owner's call. Member-level
    # destroy was safe only while every membership was :owner; invites
    # write :member rows and set_role can demote, so the owner gate is
    # the contract. System callers pass authorize?: false and are
    # unaffected.
    policy action(:destroy) do
      description("Owners destroy their organizations")
      authorize_if(FluxVale.Checks.ActorIsOrganizationOwner)
    end

    # The first rename flow (#276): owners set the display name and the
    # URL slug — GitHub-parity renaming, the owner's explicit choice.
    policy action(:update) do
      description("Owners update their organization (display name and slug)")
      authorize_if(FluxVale.Checks.ActorIsOrganizationOwner)
    end
  end

  admin do
    # How an Organization renders wherever it appears as a relationship
    # (the wallet/gateway/instance admin tables): the name a human can
    # search, not the raw UUID.
    relationship_display_fields([:name])
  end

  postgres do
    table("organizations")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")
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

    # The personal-org marker (#408): which user (if any) this org is the
    # account-surface org for. Private — an internal discriminator;
    # nothing wire-facing rides it. Null marks a team org.
    #
    # Deliberately no FK to users: the two writers keep the marker
    # honest by construction (provisioning members and marks in one
    # transaction; the backfill derives it from memberships), and a
    # stray marker just degrades the read to :none. Revisit trigger:
    # the first writer outside provisioning.
    attribute :personal_owner_id, :uuid do
      public?(false)
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
      primary?(true)
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
      primary?(true)

      # personal_owner_id rides accept for the one system writer
      # (provisioning stamps it, #408) — the policy forbids every actor,
      # and no update accepts it, so the marker is a create-time fact.
      # It rides accept ONLY while :create stays system-only: the
      # actor-reachable creation flow (:create_with_owner) never takes
      # the marker from input — markers are stamped server-side by
      # provisioning alone. User-created orgs simply don't pass it: null
      # marks a team org.
      accept([:name, :slug, :personal_owner_id])
    end

    # User-created orgs (#408): the actor's org, with their owner
    # membership written inside this action's transaction. Not primary —
    # the JIT :create above stays provisioning's untouched path. The
    # action's own policy is the gate for the nested membership write
    # (authorize?: false there — the provisioning posture: the check IS
    # the authorization), and the Membership create policy stays
    # forbid-all for every other actor path (the self-grant gap
    # closure).
    create :create_with_owner do
      accept([:name, :slug])

      # Create-time slug discipline for the actor path (#408): a 39-char
      # cap (the JIT :create above stays deliberately lenient —
      # collision probes may exceed it) and the reservation list, on top
      # of the shared format validation and the unique_slug identity.
      # Action-scoped, not the global validations block: `on:` there
      # matches action TYPES only, so only this block can scope by name.
      validate(string_length(:slug, max: 39),
        message: "must be at most 39 characters"
      )

      validate(FluxVale.Accounts.Organization.ReservedSlug)

      # The name cap binds the actor path's initial write; the
      # update-side cap above is the rename flow's.
      validate(string_length(:name, max: 100),
        message: "must be at most 100 characters"
      )

      # The actor is read at run time, not changeset-build time: the
      # change registers a before_action hook and takes the actor from
      # the changeset's context there — a changeset built before the
      # actor existed (`for_create/4` first, `Ash.create(..., actor:)`
      # second) still carries it when the hook runs. Callers cannot name
      # members: the list is hardcoded to the one actor.
      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          private = Map.get(changeset.context, :private, %{})
          actor = Map.get(private, :actor)

          Ash.Changeset.manage_relationship(changeset, :members, [actor],
            type: :append,
            authorize?: false
          )
        end)
      end)
    end

    # Renaming — either field — frees the old slug immediately: no
    # redirects and no slug reservations ship with this flow. The
    # reserved-slug gate binds the creation flow only (#408) — renaming
    # to a currently reserved slug stays allowed too, not just past
    # later-added ones (the accepted asymmetry; ReservedSlug's moduledoc
    # carries the full claim; revisit trigger: the invite flow, when org
    # slugs become shareable).
    #
    # require_atomic? false: the stale-form guard below is a function
    # change, which Ash cannot run atomically — the trade the destroy
    # action already makes. A rename is a single-row, owner-initiated
    # write; failing loudly on a moved row is worth more than batch
    # atomicity.
    update :update do
      primary?(true)
      require_atomic?(false)
      accept([:name, :slug])

      # Stale-form guard: the write is filtered on the slug the caller
      # loaded, so a view mounted before a rename fails with StaleRecord
      # instead of silently writing the old address back (the
      # observe_access_gateway idiom; Instance's optimistic_lock(:version)
      # is the same contract with a counter).
      #
      # Known bypass, deliberately accepted: atomic_update/force_change
      # mutations ride past this filter AND the length caps below — and
      # under require_atomic?(false) they are not in
      # changeset.attributes (which is also why `where: changing`
      # correctly skips them). Unreachable today: no bulk/crafted callers
      # on Organization, and Accounts is not an AshAdmin domain. A future
      # caller needing those shapes must re-check this filter and the
      # caps with it.
      change(fn changeset, _context ->
        case Map.get(changeset.data, :slug) do
          # Dead in practice, kept so a slug-less shape can never add a
          # nil filter: require_atomic?(false) keeps bulk :atomic
          # strategies out entirely, and every changeset that does run
          # (record + streamed bulk) carries the loaded row.
          # coveralls-ignore-next-line
          nil -> changeset
          loaded_slug -> Ash.Changeset.filter(changeset, slug: loaded_slug)
        end
      end)
    end

    read :get_by_id do
      description("Get an organization by id")
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :get_by_slug do
      description("Get an organization by slug")
      get?(true)
      argument(:slug, :string, allow_nil?: false)
      filter(expr(slug == ^arg(:slug)))
    end

    # The actor-scoped collection read (#362 T6a): Instance.list_for_actor's
    # shape — a resource read with the membership filter baked in (the
    # operation OrganizationsForUser rides Membership rows for the switcher's
    # org+role pairs; the wire route needs bare orgs, so the filter lives at
    # the resource). Membership IS the policy: the read policy's
    # relates_to_actor_via(:members) composes with the filter.
    read :list_for_actor do
      description("The actor's own organizations (the org switcher's read)")
      filter(expr(exists(memberships, user_id == ^actor(:id))))
    end
  end

  code_interface do
    domain(FluxVale.Accounts)

    define(:create)
    define(:update)
    define(:get_by_id, args: [:id])
    define(:get_by_slug, args: [:slug])
    define(:list_for_actor)
  end

  identities do
    identity(:unique_slug, [:slug])

    # One marked org per user. Postgres unique indexes treat NULLs as
    # distinct, so the team orgs (null marker) never conflict — only two
    # orgs naming the same personal owner do.
    identity(:unique_personal_owner, [:personal_owner_id])
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

    # These caps bind the RENAME flow only — the JIT create stays
    # lenient, and the actor path (:create_with_owner) carries its own
    # create-time caps in the action block. JIT create slugs start from
    # the username (#285) — ≤39 chars from
    # DeriveUsername, though a collision probe's suffix can push past
    # that ("-2" on a 39-char base is 41) and the create permits it.
    # The update-only scoping survives from the round-2 P1 incident:
    # when the slug was the sanitized email local part, an
    # attribute-level cap turned a 40-char local part into a
    # retry-proof signup outage (the code burns before the provisioning
    # failure surfaces). Legacy rows with longer slugs keep saving:
    # `where: changing` skips untouched fields.
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
