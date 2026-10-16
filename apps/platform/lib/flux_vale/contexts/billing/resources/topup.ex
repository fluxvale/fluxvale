defmodule FluxVale.Billing.Topup do
  @moduledoc """
  One wallet top-up intent (M6, ADR-0029): the org, the whole-dollar
  amount, and the gateway's identifiers once a checkout exists.

  Prepaid credits are a single-purpose voucher — VAT is collected at
  top-up, added on top of the credit value (#138, ADR-0029 Am. 3 gate 2):
  `amount_cents` is the NET credit value, `tax_cents` is the VAT on it,
  and the gateway is charged the GROSS (`amount_cents + tax_cents`) while
  the wallet credit posts the NET. The rate rides `tax_rate_bp` (integer
  basis points, 20% = 2000) snapshotted at checkout time — effective
  dating means a later row never rewrites a charge.

  `payment_request_id` is HitPay's payment request (the webhook matches
  on it); `payment_id` is the charge that succeeded — the ledger credit's
  idempotency key (`hitpay:<payment_id>`) so a replayed webhook or the
  Confirmation step's reconciliation can never double-credit.

  The buyer-evidence fields (`billing_country`, `billing_state`,
  `customer_type`, `vat_number`, `ip_country`, `reverse_charge?`,
  `ip_matches_billing?`) persist ADR-0029 Am. 3 gate 2's checkout
  capture so gate 3's per-country return is a query, not a
  reconstruction. The billing address is the sole rate-deciding proof;
  the IP match is a recorded signal, never a verification.

  Actors read their org's top-ups; every write is a system operation
  (`authorize?: false`) — rows are created by the checkout flow and
  transitioned only by verified gateway outcomes.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Accounts.Organization

  postgres do
    table "billing_topups"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults id: "nil"
  end

  policies do
    policy action_type(:read) do
      description "Members read their org's top-ups"
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    policy action_type([:create, :update]) do
      description "System-only: checkout flow and verified gateway outcomes (authorize?: false)"
      forbid_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :amount_cents, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(true)
    end

    # VAT on the net (single-purpose voucher: VAT at top-up). The gateway
    # is charged the gross — net + this — the wallet credit posts the net.
    attribute :tax_cents, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(true)
    end

    attribute :status, FluxVale.Billing.Types.TopupStatus do
      allow_nil?(false)
      default(:pending)
      public?(true)
    end

    # Set when the gateway checkout is created; the webhook's join key.
    attribute :payment_request_id, :string do
      public?(true)
    end

    # The succeeded charge — the idempotency key's payload.
    attribute :payment_id, :string do
      public?(true)
    end

    # Buyer details as sent to the gateway (receipt/dunning surface).
    attribute :buyer_email, :string do
      public?(true)
    end

    attribute :buyer_name, :string do
      public?(true)
    end

    # Gate-3 schema commitment (ADR-0029 Am. 3): persisted from day one,
    # populated by the checkout tax layer (#138).
    attribute :billing_country, :string do
      public?(true)
    end

    # US state code; nil is country-wide (everywhere but the US).
    attribute :billing_state, :string do
      public?(true)
    end

    attribute :customer_type, FluxVale.Billing.Types.CustomerType do
      allow_nil?(false)
      default(:consumer)
      public?(true)
    end

    # The B2B reverse-charge proof — format-checked at capture; real
    # VIES validation is a launch-gate item (ADR-0029 Am. 3).
    attribute :vat_number, :string do
      public?(true)
    end

    # Second location signal (record-only) — the edge geo header at
    # checkout.
    attribute :ip_country, :string do
      public?(true)
    end

    attribute :reverse_charge?, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    # The second location signal (record-only — the billing address is
    # the sole rate-deciding proof): whether the edge-reported IP
    # country matched the billing country exactly.
    attribute :ip_matches_billing?, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :tax_rate_bp, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0, max: 10_000)
      public?(true)
    end
  end

  relationships do
    belongs_to :organization, Organization do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :organization_id,
        :amount_cents,
        :tax_cents,
        :buyer_email,
        :buyer_name,
        :billing_country,
        :billing_state,
        :customer_type,
        :vat_number,
        :ip_country,
        :reverse_charge?,
        :ip_matches_billing?,
        :tax_rate_bp
      ])
    end

    # The gateway answered with a payment request id — the top-up now has
    # a checkout the webhook can report against.
    update :attach_checkout do
      description "System: record the gateway's payment request id (StartTopup)."
      accept([:payment_request_id])
    end

    update :mark_completed do
      description """
      System: a verified payment succeeded (CompleteTopup). Callers
      guard the transition (status-filtered bulk update) — terminal
      states flip exactly once.
      """

      accept([:payment_id, :payment_request_id])
      change(set_attribute(:status, :completed))
    end

    update :mark_failed do
      description "System: checkout creation failed or the payment request failed (same terminal-once guard)."
      accept([])
      change(set_attribute(:status, :failed))
    end

    read :get_by_id do
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      # Keyed lookups (Confirmation step, reconciliation) — the policy
      # still gates the read to org members.
      filter(expr(id == ^arg(:id)))
    end
  end

  code_interface do
    domain FluxVale.Billing

    define(:create)
    define(:attach_checkout)
    define(:mark_completed)
    define(:mark_failed)
    define(:get_by_id, args: [:id])
  end

  identities do
    # One gateway payment request per top-up; nil (no checkout yet) rows
    # stay distinct by Postgres NULL semantics.
    identity(:unique_payment_request, [:payment_request_id])
  end
end
