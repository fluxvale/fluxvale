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
  the JSON:API surface is the org switcher and the org lifecycle
  (#362 T6a, #770, #784): list, create, read by id or slug, rename the
  display name, and the empty-org teardown — never an org-internal
  field.
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
    extensions: [AshAdmin.Resource, AshJsonApi.Resource, AshPaperTrail.Resource]

  alias FluxVale.Accounts.Membership
  alias FluxVale.Infrastructure.AccessDomain

  require Ash.Query

  # The org's wire surface (#362 T6a, #770, #784): the switcher's
  # fields (id, slug, name) and nothing org-internal. Scope is the
  # billing-boundary gate (`organizations:read`/`:write`, scopes.ex);
  # membership and ownership stay the policies underneath.
  json_api do
    type("organization")

    routes do
      # organizations:read
      index(:list_for_actor,
        route: "/organizations",
        default_fields: [:id, :slug, :name]
      )

      # organizations:write — the actor path (#408): any signed-in user
      # below the org cap, the reserved-slug gate, the actor as owner in
      # the same transaction.
      post(:create_with_owner,
        route: "/organizations",
        default_fields: [:id, :slug, :name]
      )

      # organizations:read — the provider's refresh (by id) and its
      # import by slug. Declared before the :id route: the extra
      # segment keeps the two unambiguous.
      get(:get_by_slug,
        route: "/organizations/by-slug/:slug",
        default_fields: [:id, :slug, :name]
      )

      # organizations:read
      get(:get_by_id, route: "/organizations/:id", default_fields: [:id, :slug, :name])

      # organizations:write — the wire rename is NAME-ONLY (:update_name;
      # the panel's :update also moves the slug). Terraform's slug is
      # therefore create-only by API contract, not a provider invention.
      patch(:update_name, route: "/organizations/:id", default_fields: [:id, :slug, :name])

      # organizations:write — the empty-org teardown (owner policy +
      # EmptyOrgGuard). Generic-action route: the flat body matches its
      # OpenAPI schema (the destroy route's spec is bodiless in
      # ash_json_api 1.7.1 while the controller sends the row).
      route(:delete, "organizations/:id", :destroy_via_api)
    end
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

    policy action_type(:read) do
      description("Members read their organizations")
      authorize_if(relates_to_actor_via(:members))
    end

    # The admin_lookup gate (#501): platform-admin-only, scoped by
    # action NAME so it never composes with the member read policy
    # above (Ash composes applicable policies with AND — a read action
    # would match both). Non-admins match no applicable policy and fall
    # to Ash's forbid-by-default.
    policy [FluxVale.Checks.ActorIsPlatformAdmin, action(:admin_lookup)] do
      description("Platform admins look up orgs for the admin surfaces (#501)")

      authorize_if(always())
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

    # #784: the machine API's rename is name-only — slug changes stay
    # the panel's :update flow, so the wire can never release an
    # address out from under a Terraform-managed org.
    policy action(:update_name) do
      description("Owners rename their organization's display name")
      authorize_if(FluxVale.Checks.ActorIsOrganizationOwner)
    end

    # #784: the wire DELETE wrapper. Membership-gated here; the inner
    # :destroy action re-checks ownership and runs EmptyOrgGuard.
    policy action(:destroy_via_api) do
      description("Signed-in members reach the teardown; :destroy is the owner gate")
      authorize_if(actor_present())
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

    # The empty-org teardown (#784): EmptyOrgGuard refuses a personal
    # org or one that still owns content or billing history, with the
    # platform's plain words. What survives the guard is deletable:
    # membership rows (no delete cascade, system-only destroy policy),
    # membership invites and custody events (DB cascade), and the org's
    # derived :platform access-domain row (no cluster state; re-minted
    # on the next instance create). Custom domains were refused above
    # because their Certificates need the removal operation. Everything
    # runs in the destroy's transaction — a failure rolls the whole
    # teardown back.
    destroy :destroy do
      primary?(true)
      require_atomic?(false)

      change(FluxVale.Accounts.Organization.EmptyOrgGuard)

      change(fn changeset, _context ->
        org_id = changeset.data.id

        Ash.Changeset.before_action(changeset, fn changeset ->
          purge_platform_domains(org_id)
          clear_memberships(org_id)

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

      # A change, not a validation: this path accepts a late actor
      # (for_create before Ash.create), so the gate reads the actor at
      # run time and exempts platform admins for brand surfaces outside
      # the machine API (#754; ReservedSlug carries the split).
      change(FluxVale.Accounts.Organization.ReservedSlug)

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
      change(FluxVale.Accounts.Organization.StaleFormGuard)
    end

    # The wire's rename (#784): display name only — the panel's :update
    # keeps the slug arm. The shared stale-form guard keeps the stream
    # authorization path (see its moduledoc).
    update :update_name do
      require_atomic?(false)
      accept([:name])
      change(FluxVale.Accounts.Organization.StaleFormGuard)
    end

    # The wire's teardown (#784): the generic-action wrapper exists so
    # DELETE's rendered body matches its OpenAPI schema. The authorized
    # read is the visibility fence (a non-member gets NotFound), and
    # the inner destroy owns the owner policy and EmptyOrgGuard.
    action :destroy_via_api, :struct do
      description("Delete an empty organization")
      argument(:id, :uuid, allow_nil?: false, public?: true)
      constraints(instance_of: __MODULE__)

      run(fn input, %{actor: actor, authorize?: authorize?, source_context: context} ->
        with {:ok, org} <-
               get_by_id(input.arguments.id,
                 actor: actor,
                 authorize?: authorize?,
                 context: context
               ),
             :ok <-
               Ash.destroy(org,
                 actor: actor,
                 authorize?: authorize?,
                 context: context
               ) do
          {:ok, org}
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

    # The admin surfaces' org lookup (#501, the wallets lane) — the
    # FLAGGED seam. The read policy above is members-only, so a
    # platform-admin actor cannot render an org's name off a wallet
    # (the load lands nil, the get reads NotFound), yet the admin
    # wallet table's contract is org-first (#140's operator table).
    # Every other admin-facing resource carries an ActorIsPlatformAdmin
    # arm; Organization predates the admin lane and never needed one.
    # This generic action adds that one path WITHOUT touching the
    # member read policy: scoped by action name (Ash composes
    # applicable policies with AND, so :read never widens), admin-only
    # by policy, and it returns only the switcher's public fields
    # (#362 T6a posture: id, slug, name — nothing org-internal). The
    # inner read is system machinery, hard-coded `authorize?: false`
    # behind this action's own scoped policy — NOT Wallet :runway's
    # posture (runway forwards the caller's authorize? into its inner
    # read, whose membership policy does the refusing; here the gate
    # is this action's policy alone). Same safety — the policy is the
    # only door — different posture, stated precisely. Revisit
    # trigger: the first admin surface that needs more than these
    # three fields, at which point this grows the explicit field list
    # rather than leaking structs.
    action :admin_lookup, {:array, :map} do
      description("Platform-admin org lookup for the admin surfaces (#501)")

      argument(:ids, {:array, :uuid},
        allow_nil?: false,
        # The wallet page asks for at most a cap-plus-one of ids; 200
        # refuses absurd asks without hurting any caller. Deliberately
        # PUBLIC: Ash.ActionInput.for_action only feeds public
        # arguments, and the in-repo callers ride that code interface.
        # No wire route reaches this action (the JSON:API routes are
        # list/create/read/rename/destroy), so there is nothing to lock
        # out today — if a route is ever authored for this action,
        # re-check this argument's exposure first.
        constraints: [min_length: 1, max_length: 200]
      )

      run(fn input, _context ->
        # __MODULE__ — inside the resource's own run fn the bare alias
        # is not yet resolvable as a resource for Ash.Query.
        orgs =
          __MODULE__
          |> Ash.Query.filter(expr(id in ^input.arguments.ids))
          |> Ash.read!(authorize?: false)

        {:ok, Enum.map(orgs, &%{id: &1.id, name: &1.name, slug: &1.slug})}
      end)
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

  # The org's derived platform-domain row is the one access-domain kind
  # deletable here: no Certificate, no cluster state, re-minted by
  # MintDefaultHostname. Custom rows were refused by the guard because
  # their removal owns the Certificate teardown. System posture — the
  # destroy policy already gated the caller.
  defp purge_platform_domains(org_id) do
    AccessDomain
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(organization_id == ^org_id and kind == :platform)
    |> Ash.read!(authorize?: false)
    |> Enum.each(&AccessDomain.purge!(&1, authorize?: false))
  end

  defp clear_memberships(org_id) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(organization_id == ^org_id)
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))
  end
end
