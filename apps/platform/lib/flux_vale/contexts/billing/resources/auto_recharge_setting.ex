defmodule FluxVale.Billing.AutoRechargeSetting do
  @moduledoc """
  The org's auto-recharge preference (#829, decision G) — one row per
  org (`unique_org`), the shared setting both lanes read. `mode` is
  `:off | :reminder | :auto`: the reminder lane emails the org a
  one-click, amount-prefilled top-up link when the wallet dips below
  `threshold_cents` (the L2 sweep); `:auto` arms the staged off-session
  charge lane — its own explicit owner consent, never implied by a
  reminder opt-in.

  `:auto` is STAGED: `FluxVale.Billing.auto_recharge_charge_mode?/0`
  (the platform gate, default false) keeps every bit of it inert until
  the Polar Pro upgrade (activation slice S6) — the AutoArmGate
  validation rejects arming writes, and no other action sets the mode
  to `:auto`.
  Everything else on the row (`daily_charge_cap`, `failure_strikes`,
  the buyer evidence) is inert data the owner may already set.

  `threshold_cents` and `amount_cents` follow the top-up ladder (#888,
  `FluxVale.Billing.topup_amount_valid?/1` — the rule the wizard and
  StartTopup enforce): a saved write can never store an amount a
  top-up would refuse. `AmountsOnTopupLadder` judges what a write
  carries, so a row that predates the ladder keeps its stored values
  until the owner edits them; `AutoArmGate` refuses to arm such a row.

  Writes are owner-role only (`:set` — recurring spend consent is not
  "money in"; the wizard's any-member stance does not carry, decision
  C); members read. Row provisioning, the reminder marker
  (`last_reminded_at`), and the charge lane's sweep state (attempt
  outcome, disable, method status) are system writes
  (`authorize?: false`).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource, AshPaperTrail.Resource]

  alias FluxVale.Billing.AutoRechargeSetting.AmountsOnTopupLadder
  alias FluxVale.Billing.AutoRechargeSetting.AutoArmGate
  alias FluxVale.Billing.Types.AutoRechargeDisabledReason
  alias FluxVale.Billing.Types.AutoRechargeMode
  alias FluxVale.Billing.Types.PaymentMethodStatus

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

    policy action(:record_attempt_outcome) do
      description(
        "System-only: the charge sweep's strike counter (authorize?: false; platform admins ride the #644 bypass, ADR-0047 D4)"
      )

      forbid_if(always())
    end

    policy action(:record_no_method_notice) do
      description(
        "System-only: the no-method notice marker, D3's two-pass rule (authorize?: false; platform admins ride the #644 bypass, ADR-0047 D4)"
      )

      forbid_if(always())
    end

    policy action(:disable_with_reason) do
      description(
        "System-only: strikes / no-method auto-disable (authorize?: false; platform admins ride the #644 bypass, ADR-0047 D4)"
      )

      forbid_if(always())
    end

    policy action(:set_method_status) do
      description(
        "System-only: the saved-method state (authorize?: false; platform admins ride the #644 bypass, ADR-0047 D4)"
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
    # threshold → the reminder fires, pre-filling the amount. Both
    # follow the top-up ladder (#888) — AmountsOnTopupLadder on :set.
    # The constraint below is subsumed by it (the lowest rung is 500)
    # and stays only as the type-level backstop (a constraints min
    # needs a compile-time int).
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

    # ── Staged charge lane (S2) — inert behind the config gate ──

    # The charge dials (decision D2): at most `daily_charge_cap` auto
    # charges per rolling 24h; `failure_strikes` consecutive declines
    # auto-disable the lane (decision F).
    attribute :daily_charge_cap, :integer do
      allow_nil?(false)
      default(2)
      constraints(min: 1, max: 6)
      public?(true)
    end

    attribute :failure_strikes, :integer do
      allow_nil?(false)
      default(3)
      constraints(min: 2, max: 5)
      public?(true)
    end

    # The sweep's strike counter (decision F): incremented on a
    # decline, reset on a success. Private system state.
    attribute :consecutive_failures, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(false)
    end

    # Why an armed lane was disarmed (decisions D3/F) — nil while the
    # lane has never been disabled with a reason.
    attribute :disabled_reason, AutoRechargeDisabledReason do
      public?(false)
    end

    # D3's persisted notice marker: set when the no-method notice
    # fires, still nil on the next pass disables (notice-then-disable);
    # a disable and a success each clear it.
    attribute :no_method_notified_at, :utc_datetime_usec do
      public?(false)
    end

    # The latest charge attempt (decision F's strike window reads it).
    attribute :last_attempt_at, :utc_datetime_usec do
      public?(false)
    end

    # The provider-side references (decision B — Polar only): the
    # customer this org maps to, and whether a method is saved on it.
    # The provider vaults the instrument; we store provider-scoped
    # references only.
    attribute :provider_customer_id, :string do
      public?(false)
    end

    attribute :payment_method_status, PaymentMethodStatus do
      allow_nil?(false)
      default(:none)
      public?(false)
    end

    # Buyer evidence for the later charge (decision C): copies from the
    # org's last completed top-up as the editable default — the RATE
    # always resolves fresh at charge time (#260, never a copied rate).
    # sensitive?: the audit trail (#645, ADR-0048) redacts buyer
    # evidence (the Topup posture) — the version rows carry REDACTED,
    # never the values.
    attribute :billing_country, :string do
      public?(false)
      sensitive?(true)
    end

    # US state code; nil is country-wide (everywhere but the US).
    attribute :billing_state, :string do
      public?(false)
      sensitive?(true)
    end

    attribute :vat_number, :string do
      public?(false)
      sensitive?(true)
    end

    attribute :customer_type, FluxVale.Billing.Types.CustomerType do
      allow_nil?(false)
      default(:consumer)
      public?(false)
      sensitive?(true)
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

      accept([
        :mode,
        :threshold_cents,
        :amount_cents,
        :daily_charge_cap,
        :failure_strikes,
        :billing_country,
        :billing_state,
        :vat_number,
        :customer_type
      ])

      # A stale tab's save must WRITE the mode it showed. Two Ash
      # mechanics conspire against a plain write here: a change equal
      # to the in-memory record is dropped BEFORE changes run (so the
      # check reads the raw params — fetch_change is already empty),
      # and the persist delta is computed against changeset.data — the
      # STALE struct — so even a forced attribute write equal to that
      # stale data is skipped (the returned record claims the new mode
      # while the row keeps the old one). atomic_update is the escape
      # hatch: an explicit SET that ignores the stale-data delta,
      # making every form save last-writer-wins, visibly — loaded-off +
      # another tab's reminder opt-in + submit-off writes off. The raw
      # value re-casts through the attribute's own type first (atomics
      # carry literals; an uncast string must never slip past the
      # enum), and a cast-refused value (a crafted :bogus) just falls
      # through — the normal cast pipeline already flags it. The nil
      # arm is S2's evidence writes, which omit mode — they must not
      # grow a forced write. (Chosen over a handler-side reload +
      # conflict report — one change here vs a fresh read and a new
      # flash path on two surfaces.)
      change(fn changeset, _context ->
        raw_mode = Map.get(changeset.params, :mode) || Map.get(changeset.params, "mode")

        case raw_mode do
          nil ->
            changeset

          raw_mode ->
            case Ash.Type.cast_input(AutoRechargeMode, raw_mode, []) do
              {:ok, mode} -> Ash.Changeset.atomic_update(changeset, :mode, mode)
              _cast_refused -> changeset
            end
        end
      end)

      # The ladder is app config, not a compile-time int — the
      # constraint DSL cannot carry it (see the validation module).
      validate({AmountsOnTopupLadder, []})

      # The staged lane's gate (AutoArmGate): a validation, not a
      # policy — the gate is platform state, not actor identity.
      validate({AutoArmGate, []})

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

    update :record_attempt_outcome do
      description("""
      System write of the charge lane's strike counter and attempt
      marker (the S4 sweep): stores consecutive_failures as given
      (when it counts a decline and when a success resets it to 0 is
      the caller's contract, not this action's) and last_attempt_at,
      nil clears.
      """)

      accept([:consecutive_failures, :last_attempt_at])
      require_atomic?(false)
    end

    update :record_no_method_notice do
      description("""
      System write of the no-method notice marker (the charge sweep's
      D3 two-pass rule): when the org was last mailed about a missing
      saved method, nil clears (a success or a disable re-arms the
      two-pass cycle fresh). The charge sweep's only seam for this
      attribute — no S2 action accepts it.
      """)

      accept([:no_method_notified_at])
      require_atomic?(false)
    end

    update :disable_with_reason do
      description("""
      System write of a disarmed lane (decisions D3/F): the reason is
      recorded, the mode returns to :off, the strikes counter resets
      to 0 (the episode ends at disable — a re-arm starts clean), and
      the no-method notice marker clears (a re-arm starts D3's
      two-pass cycle fresh).
      """)

      accept([:disabled_reason])
      change(set_attribute(:mode, :off))
      change(set_attribute(:consecutive_failures, 0))
      change(set_attribute(:no_method_notified_at, nil))
      require_atomic?(false)
    end

    update :set_method_status do
      description("""
      System write of the saved-method state (the save-method flow's
      return leg): payment_method_status plus the provider's customer
      id (decision B — Polar vaults the instrument, we store the
      reference).
      """)

      accept([:payment_method_status, :provider_customer_id])
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
