defmodule FluxVale.Billing.LedgerEntry do
  @moduledoc """
  One append-only row of a wallet's ledger (v1's CreditTransaction,
  renamed — "ledger" is the ADR-0028/ADR-0029 term).

  Each posting carries a signed `amount` in **whole US cents** (credit
  positive, debit negative — `SignMatchesType` plus a DB check constraint
  enforce the pairing), a `reason` naming the funding dimension, and an
  optional `idempotency_key` unique per wallet so a retried post (payment
  webhook, settlement retry) cannot double-count.

  A reversal (refund) is a compensating entry, never a row mutation:
  `reverses_id` names the entry it offsets, and the partial unique index
  on that column makes a double reversal impossible at the database —
  ADR-0029's accepted refund obligation.

  Append-only means only `:read`/`:create` exist — no update, no destroy,
  and no `updated_at` (rows never change). Actors may read their org's
  entries; posting is a system operation (`authorize?: false`, the
  operations under `FluxVale.Billing`).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Billing.LedgerEntry.SignMatchesType
  alias FluxVale.Billing.Types.EntryReason
  alias FluxVale.Billing.Types.EntryType
  alias FluxVale.Billing.Wallet

  postgres do
    table "billing_ledger_entries"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults id: "nil"

    # Database-level mirror of SignMatchesType: the signed amount must
    # agree with the type even if a row is written outside Ash (direct
    # SQL). Defense-in-depth for the financial ledger's core invariant.
    check_constraints do
      check_constraint :amount, "amount_sign_matches_type",
        check: "(type = 'credit' AND amount > 0) OR (type = 'debit' AND amount < 0)",
        message: "sign must match type"
    end
  end

  policies do
    policy action_type(:read) do
      description "Members read their org's ledger"
      authorize_if(relates_to_actor_via([:wallet, :organization, :members]))
    end

    policy action_type(:create) do
      description "System-only: the posting machinery (authorize?: false)"
      forbid_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)

    attribute :amount, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :type, EntryType do
      allow_nil?(false)
      public?(true)
    end

    attribute :reason, EntryReason do
      allow_nil?(false)
      public?(true)
    end

    attribute :idempotency_key, :string do
      public?(true)
    end

    attribute :reverses_id, :uuid do
      public?(true)
    end
  end

  relationships do
    belongs_to :wallet, Wallet do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary? true
      accept([:wallet_id, :amount, :type, :reason, :idempotency_key, :reverses_id])
    end
  end

  code_interface do
    domain FluxVale.Billing

    define(:create)
    define(:read)
  end

  identities do
    # NULL keys stay distinct (Postgres default) — keyless one-off posts
    # (welcome grants) are legal; keyed posts are idempotent per wallet.
    identity(:unique_idempotency, [:wallet_id, :idempotency_key])
  end

  validations do
    validate({SignMatchesType, []}, on: :create)
  end
end
