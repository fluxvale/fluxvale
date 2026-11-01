defmodule FluxVale.Billing.Wallet do
  @moduledoc """
  A prepaid credit balance owned by an Organization (#120) — one wallet
  per org (`unique_org`); the org is the billing boundary (#119).

  The balance is not a stored column — a live `sum` aggregate over the
  wallet's `LedgerEntry` rows, so it can never drift from the append-only
  ledger. `carryover` is the one stored number besides the ids: the
  wallet-pooled fractional remainder from flat-rate accrual, in integer
  **micro-cents** (µ¢ = 10⁻⁶ USD; 1¢ = 10_000 µ¢). Ledger rows only ever
  carry whole cents — accrual fractions pool here between settlements
  instead of forming per-instance rounding dust (#121's no-dust rule;
  ADR-0028).

  Reads go to org members (and platform admins over AshAdmin, #140 —
  support needs to find the wallet behind a goodwill credit); creation
  and carryover/ladder writes are system operations (`authorize?:
  false` — the posting machinery). The one actor-facing write is
  `:set_waiver` — the paywall waiver (see the attribute), flipped by a
  platform admin from the /admin edit form.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  alias FluxVale.Billing.LedgerEntry

  # The admin surface (#140): reads for wallet discovery (the goodwill
  # credit) plus the ONE admin write — the paywall waiver flip below,
  # rendered by AshAdmin as the edit form's checkbox. Provisioning and
  # carryover/ladder writes stay the posting machinery's, actor-forbidden
  # by policy; an admin form for them could only fail, so none is
  # offered.
  admin do
    create_actions([])
    update_actions([:set_waiver])
    destroy_actions([])
  end

  policies do
    # One read policy, two ways in (Ash composes applicable policies
    # with AND — a separate admin policy would still leave the member
    # filter applying to admins): members via the org, platform admins
    # for the AshAdmin support surface (#140 — finding the wallet
    # behind a goodwill credit).
    policy action_type(:read) do
      description("Members read their org's wallet; platform admins read any (#140)")
      authorize_if(relates_to_actor_via([:organization, :members]))
      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
    end

    # The waiver flip (paywall waiver): the one actor-facing update.
    # Composed like ledger_entry's goodwill exception — this policy
    # scopes to :set_waiver BY NAME, and the system-write policy below
    # scopes to the system actions by name, so the scopes never overlap
    # (Ash composes applicable policies with AND): a non-admin on
    # :set_waiver matches no policy at all and falls to Ash's
    # forbid-by-default, while the system writes stay actor-forbidden
    # even for admins.
    policy [FluxVale.Checks.ActorIsPlatformAdmin, action(:set_waiver)] do
      description("Platform admins flip the paywall waiver — the /admin edit form's checkbox")

      authorize_if(always())
    end

    policy action_type(:create) do
      description("System-only: wallet provisioning (authorize?: false)")
      forbid_if(always())
    end

    # By action NAME, not action_type (mirrors ledger_entry's :create
    # forbid): :set_waiver is the admin exception above, and scoping
    # this forbid by name is what keeps it off that action. The
    # wallet's only other updates are the two system writes — both stay
    # actor-forbidden, admins included.
    policy action([:set_carryover, :set_ladder_state]) do
      description("System-only: carryover + ladder writes (authorize?: false)")
      forbid_if(always())
    end
  end

  postgres do
    table("billing_wallets")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    # Pooled fractional accrual remainder — see the moduledoc for the unit.
    # Never actor-writable (the update policy forbids), only the posting
    # machinery under the per-wallet advisory lock touches it.
    attribute :carryover, :integer do
      allow_nil?(false)
      default(0)
      public?(false)
    end

    # The zero-balance ladder's persisted decision state (#124), all
    # sweep-written under the advisory lock (the update policy forbids
    # actors). `negative_since` is the destroy clock's anchor: set when
    # the sweep first sees balance < 0, cleared at ≥ 0 — destroy is
    # `negative_since + 30d`. The warning markers make each email
    # once-per-episode; cleared with the clock on recovery.
    attribute :low_balance_warned_at, :utc_datetime_usec do
      public?(false)
    end

    attribute :negative_since, :utc_datetime_usec do
      public?(false)
    end

    attribute :destroy_t7_warned_at, :utc_datetime_usec do
      public?(false)
    end

    attribute :destroy_t1_warned_at, :utc_datetime_usec do
      public?(false)
    end

    # The paywall waiver — the operator's designated-org switch, NOT
    # money. It satisfies ONLY the "has paid $1+ once" gate
    # (ActorOrgHasPaid ORs it with the ledger's :purchase rows), so
    # testers/friends/demos can enable private access and backups
    # without ever topping up. Balance>0 spend checks are never waived
    # and no ledger row ever moves: no rows, no balance change, nothing
    # spendable. Has-paid for revenue purposes stays DERIVED ledger
    # truth — deliberately NOT mirrored into a column, so a waived org
    # can never be counted as a payer by a conversion/revenue query.
    # Written only by :set_waiver (platform admin, the /admin edit
    # form).
    attribute :paywall_waived, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end
  end

  relationships do
    belongs_to :organization, FluxVale.Accounts.Organization do
      allow_nil?(false)
      public?(true)
    end

    has_many :entries, LedgerEntry do
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:organization_id])
    end

    update :set_carryover do
      description("System write of the pooled accrual remainder (DebitWallet, under the lock).")
      accept([])
      require_atomic?(false)
    end

    update :set_ladder_state do
      description("""
      System write of the zero-balance ladder's markers (#124): the
      runway-warning and destroy-clock timestamps, nil clears. The sweep
      owns every write, under the advisory lock.
      """)

      accept([
        :low_balance_warned_at,
        :negative_since,
        :destroy_t7_warned_at,
        :destroy_t1_warned_at
      ])

      require_atomic?(false)
    end

    # The /admin edit-form flip (AshAdmin renders this action's form —
    # `admin do update_actions` above): the ONLY actor-writable
    # attribute on the wallet, and the only actor-facing update. The
    # attribute carries the contract (see its comment).
    update :set_waiver do
      description(
        "Flip the paywall waiver — platform-admin-only, the /admin edit form's checkbox"
      )

      accept([:paywall_waived])
      require_atomic?(false)
    end

    read :get_by_organization do
      description("Get an org's wallet")
      get?(true)
      argument(:organization_id, :uuid, allow_nil?: false)
      filter(expr(organization_id == ^arg(:organization_id)))
    end
  end

  code_interface do
    domain(FluxVale.Billing)

    define(:create)
    define(:get_by_organization, args: [:organization_id])
    define(:set_waiver)
  end

  identities do
    identity(:unique_org, [:organization_id])
  end

  aggregates do
    # The balance IS the ledger — never a column (product.md).
    sum(:balance, :entries, :amount, default: 0)
  end
end
