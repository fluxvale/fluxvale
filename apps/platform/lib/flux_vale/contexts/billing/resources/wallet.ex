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

  Reads go to org members; creation and carryover writes are system
  operations (`authorize?: false` — the posting machinery).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Billing.LedgerEntry

  postgres do
    table "billing_wallets"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults id: "nil"
  end

  policies do
    policy action_type(:read) do
      description "Members read their org's wallet"
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    policy action_type(:create) do
      description "System-only: wallet provisioning (authorize?: false)"
      forbid_if(always())
    end

    policy action_type(:update) do
      description "System-only: accrual carryover writes (authorize?: false)"
      forbid_if(always())
    end
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
      primary? true
      accept([:organization_id])
    end

    update :set_carryover do
      description "System write of the pooled accrual remainder (DebitWallet, under the lock)."
      accept([])
      require_atomic?(false)
    end

    update :set_ladder_state do
      description """
      System write of the zero-balance ladder's markers (#124): the
      runway-warning and destroy-clock timestamps, nil clears. The sweep
      owns every write, under the advisory lock.
      """

      accept([
        :low_balance_warned_at,
        :negative_since,
        :destroy_t7_warned_at,
        :destroy_t1_warned_at
      ])

      require_atomic?(false)
    end

    read :get_by_organization do
      description "Get an org's wallet"
      get?(true)
      argument(:organization_id, :uuid, allow_nil?: false)
      filter(expr(organization_id == ^arg(:organization_id)))
    end
  end

  code_interface do
    domain FluxVale.Billing

    define(:create)
    define(:get_by_organization, args: [:organization_id])
  end

  identities do
    identity(:unique_org, [:organization_id])
  end

  aggregates do
    # The balance IS the ledger — never a column (product.md).
    sum(:balance, :entries, :amount, default: 0)
  end
end
