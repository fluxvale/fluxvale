defmodule FluxVale.Billing.AutoRechargeSetting do
  @moduledoc """
  The org's auto-recharge preference (#829, decision G) — one row per
  org (`unique_org`), the shared setting both lanes read. At launch,
  `mode` is `:off | :reminder`: the reminder lane emails the org a
  one-click, amount-prefilled top-up link when the wallet dips below
  `threshold_cents` (the L2 sweep). The staged off-session charge lane
  joins THIS row in S2 (`:auto`) — arming it is its own explicit owner
  consent, never implied by a reminder opt-in.

  `amount_cents` clears the wallet top-up floor from app config
  (`FluxVale.Billing.min_topup_cents/0` — the StartTopup gate), so a
  saved amount that could never charge is refused at write time.

  Writes are owner-role only (`:set` — recurring spend consent is not
  "money in"; the wizard's any-member stance does not carry, decision
  C); members read. Row provisioning and the reminder marker
  (`last_reminded_at`) are system writes (`authorize?: false`).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource, AshPaperTrail.Resource]

  alias FluxVale.Billing.AutoRechargeSetting.AmountMeetsTopupFloor
  alias FluxVale.Billing.Types.AutoRechargeMode

  # The admin posture (#829): read-only — the owner-role write is the
  # billing page's owner form, not an operator's; AshAdmin's
  # authorizing toggle defaults OFF (ADR-0027 Am. 1), so no write form
  # mounts at all. The table is the operator's at-a-glance: whose
  # preference, in what state.
  admin do
    create_actions([])
    update_actions([])
    destroy_actions([])
    table_columns([:organization, :mode, :threshold_cents, :amount_cents, :last_reminded_at])
  end

  policies do
    # The blanket authority (#644, ADR-0047): platform admins see and do
    # everything — but never through the machine API (the second
    # condition), so PAT callers fall through to the policies below.
    bypass [FluxVale.Checks.ActorIsPlatformAdmin, FluxVale.Checks.CallOutsideMachineApi] do
      description("Platform admins see and do everything (#644)")
      authorize_if(always())
    end

    # One read policy: members via the org (the billing page's card,
    # L3). Admins ride the #644 bypass above — no second arm, or the
    # composition would demand both (the wallet's discipline).
    policy action_type(:read) do
      description("Members read their org's setting (#829 G)")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    # The owner-role write (decision C: recurring spend consent is not
    # "money in"). Scoped by action NAME so the system-write forbid
    # below never composes into it (Ash composes applicable policies
    # with AND). The ActorIsOrganizationOwner changeset head (#760)
    # reads the org id off this row — one membership query, one
    # ownership notion (the access_gateway :set_api_token shape).
    policy action(:set) do
      description("Owner-role members set the auto-recharge preference (#829 C)")
      forbid_unless(FluxVale.Checks.ActorIsOrganizationOwner)
      authorize_if(FluxVale.Checks.ActorIsOrganizationOwner)
    end

    # By action NAME, not action_type (mirrors wallet's system-write
    # forbids): :record_reminder is the L2 sweep's marker write —
    # actor-forbidden for every actor the policies see; a platform
    # admin outside the machine API passes through the #644 bypass
    # instead (ADR-0047's D4), never through this policy.
    policy action(:record_reminder) do
      description(
        "System-only: the reminder sweep's marker (authorize?: false; platform admins ride the #644 bypass, ADR-0047 D4)"
      )

      forbid_if(always())
    end

    policy action_type(:create) do
      description(
        "System-only: setting provisioning (authorize?: false; platform admins ride the #644 bypass, ADR-0047 D4)"
      )

      forbid_if(always())
    end
  end

  postgres do
    table("billing_auto_recharge_settings")
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

    # The consent switch (decision G): :off ships as the default so the
    # row can exist inertly; :reminder arms the launch lane.
    attribute :mode, AutoRechargeMode do
      allow_nil?(false)
      default(:off)
      public?(true)
    end

    # The reminder dials (decision D): the balance dips below the
    # threshold → the reminder fires, pre-filling the amount. The
    # amount's REAL floor is app config — AmountMeetsTopupFloor on
    # :set (a constraints min needs a compile-time int).
    attribute :threshold_cents, :integer do
      allow_nil?(false)
      default(500)
      constraints(min: 100)
      public?(true)
    end

    attribute :amount_cents, :integer do
      allow_nil?(false)
      default(2_500)
      public?(true)
    end

    # The episode marker (the ladder-warning shape): set when the
    # reminder fires, nil (or > 24h old) re-arms it, recovery clears
    # it. The sweep owns every write — private system state.
    attribute :last_reminded_at, :utc_datetime_usec do
      public?(false)
    end
  end

  relationships do
    belongs_to :organization, FluxVale.Accounts.Organization do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:organization_id])
    end

    update :set do
      description("Owner-role write of the preference (the billing page's owner form, L3).")
      accept([:mode, :threshold_cents, :amount_cents])

      # The floor is app config, not a compile-time int — the
      # constraint DSL cannot carry it (see the validation module).
      validate({AmountMeetsTopupFloor, []})

      require_atomic?(false)
    end

    update :record_reminder do
      description("""
      System write of the reminder marker (the L2 sweep): when the org
      was last reminded, nil clears (episode re-arm).
      """)

      accept([:last_reminded_at])
      require_atomic?(false)
    end

    read :get_by_organization do
      description("Get an org's auto-recharge setting")
      get?(true)
      argument(:organization_id, :uuid, allow_nil?: false)
      filter(expr(organization_id == ^arg(:organization_id)))
    end
  end

  code_interface do
    domain(FluxVale.Billing)

    define(:create)
    define(:get_by_organization, args: [:organization_id])
    define(:set)
  end

  identities do
    identity(:unique_org, [:organization_id])
  end
end
