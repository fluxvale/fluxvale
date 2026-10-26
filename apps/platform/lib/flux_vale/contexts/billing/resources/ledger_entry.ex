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

  Charge credits (reason `:purchase`) also persist the checkout tax
  layer's facts — `billing_country`, `billing_state` (US), the
  `applied_rate` in basis points, the collected `tax_cents`, and the
  B2B `reverse_charge?` marker — and `ReverseEntry` copies them onto
  the compensating refund debit, so the quarterly per-country tax
  summary (ADR-0029 Am. 3 gate 3) sums what was collected, net of
  reversals, without re-deriving anything. Every other posting keeps
  these null, and all history before the fields landed (M6, #139)
  stays null: the ledger is append-only, no backfill.

  Append-only means only `:read`/`:create` exist — no update, no destroy,
  and no `updated_at` (rows never change). Actors may read their org's
  entries; posting is a system operation (`authorize?: false`, the
  operations under `FluxVale.Billing`) — the one actor-facing exception
  is `:grant_goodwill` (#140): a platform-admin goodwill credit that
  posts through the same `GrantCredits` seam, never around it.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  alias FluxVale.Billing.LedgerEntry.SignMatchesType
  alias FluxVale.Billing.Types.EntryReason
  alias FluxVale.Billing.Types.EntryType
  alias FluxVale.Billing.Wallet

  # The admin surface (#140, ADR-0027 §3): goodwill creates + ledger
  # reads only — the system :create is the posting machinery's, never a
  # form (it's actor-forbidden regardless; hiding it keeps the admin UI
  # from offering a button that can only fail).
  admin do
    create_actions([:grant_goodwill])
  end

  policies do
    # Ash composes applicable policies with AND — the scopes below
    # never overlap. Reads: members OR platform admins (the AshAdmin
    # support surface, #140) inside ONE policy, or the member filter
    # would apply to admins too. Creates: the system :create (by name)
    # is actor-forbidden; :grant_goodwill is the admin-only exception.
    policy [FluxVale.Checks.ActorIsPlatformAdmin, action(:grant_goodwill)] do
      description(
        "Platform admins post goodwill credits (#140) — the refund policy's only override path"
      )

      authorize_if(always())
    end

    policy action_type(:read) do
      description("Members read their org's ledger; platform admins read it all (#140)")
      authorize_if(relates_to_actor_via([:wallet, :organization, :members]))
      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
    end

    policy action(:create) do
      description("System-only: the posting machinery (authorize?: false)")
      forbid_if(always())
    end
  end

  postgres do
    table("billing_ledger_entries")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    # One reversal per original entry — the double-refund backstop behind
    # ReverseEntry's guard. Partial: keyless posts carry NULL reverses_id
    # and stay distinct. Under codegen's drift check via custom_indexes.
    custom_indexes do
      index([:reverses_id], unique: true, where: "reverses_id IS NOT NULL")

      # The tax summary's range scan groups by country over a period —
      # partial on the rows that carry tax facts (gate 3).
      index([:billing_country, :created_at], where: "billing_country IS NOT NULL")
    end

    # Database-level mirror of SignMatchesType: the signed amount must
    # agree with the type even if a row is written outside Ash (direct
    # SQL). Defense-in-depth for the financial ledger's core invariant.
    check_constraints do
      check_constraint(:amount, "amount_sign_matches_type",
        check: "(type = 'credit' AND amount > 0) OR (type = 'debit' AND amount < 0)",
        message: "sign must match type"
      )
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

    # The charge-side tax facts (gate 3, ADR-0029 Am. 3) — purchase
    # credits and, copied by ReverseEntry, their refund debits. The rate
    # mirrors Topup.tax_rate_bp's basis points; tax_cents is the VAT
    # collected on the charge (a magnitude — the summary signs it by
    # entry type). History keeps null tax_cents/rate/country.
    attribute :billing_country, :string do
      public?(true)
    end

    attribute :billing_state, :string do
      public?(true)
    end

    attribute :applied_rate, :integer do
      constraints(min: 0, max: 10_000)
      public?(true)
    end

    attribute :tax_cents, :integer do
      constraints(min: 0)
      public?(true)
    end

    # B2B reverse charge (customer self-accounts) — kept apart from
    # untaxed consumer rows in the summary so OSS consumer nets are
    # never inflated. Mirrors Topup.reverse_charge?'s shape.
    attribute :reverse_charge?, :boolean do
      allow_nil?(false)
      default(false)
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
      primary?(true)

      # Action-local: the sign invariant guards the POSTING changeset
      # (amount/type set here). The goodwill create below never carries
      # them — its row posts through the operation, which lands here
      # (#140).
      validate({SignMatchesType, []})

      accept([
        :wallet_id,
        :amount,
        :type,
        :reason,
        :idempotency_key,
        :reverses_id,
        :billing_country,
        :billing_state,
        :applied_rate,
        :tax_cents,
        :reverse_charge?
      ])
    end

    # #140: the refund policy's only override path — a platform admin
    # posting a goodwill credit through the SAME GrantCredits seam the
    # welcome grant rides (reason :adjustment keeps the ledger
    # reconcilable). AshAdmin renders this as the ledger's create form;
    # the system :create above stays actor-forbidden by policy and is
    # hidden from the admin surface (`create_actions` below).
    #
    # Keyless by deliberation: GrantCredits' contract puts once-only on
    # the caller, and an admin form submit can retry (double-click,
    # back-button) — the guard is the operator reviewing the posted row
    # plus ReverseEntry, the compensating unwind for exactly this class
    # of mistake. A form-supplied idempotency key would add friction
    # without deduping (each submit mints its own). Revisit trigger: a
    # first report of a doubled goodwill grant.
    create :grant_goodwill do
      description(
        "Post a goodwill credit to a wallet (#140) — admin-only, lands as an :adjustment credit"
      )

      argument(:wallet_id, :uuid, allow_nil?: false)
      argument(:amount_cents, :integer, allow_nil?: false, constraints: [min: 1])

      accept([])

      # Manual create: the row the action "creates" is posted by the
      # existing GrantCredits operation — same seam as the welcome
      # grant, never a second posting path.
      manual(fn changeset, _context ->
        wallet = %Wallet{id: Ash.Changeset.get_argument(changeset, :wallet_id)}

        FluxVale.Billing.grant_credits(
          wallet,
          Ash.Changeset.get_argument(changeset, :amount_cents),
          reason: :adjustment
        )
      end)
    end

    # #123's history surface: keyset-paginated (newest first) — the
    # ledger is append-only, so a cursor survives inserts landing between
    # pages; an offset window would skip or repeat rows. The caller owns
    # the sort (created_at desc + id desc tiebreak in the LiveView).
    read :list_for_wallet do
      description("The wallet's entries, keyset-paginated (#123)")
      argument(:wallet_id, :uuid, allow_nil?: false)
      filter(expr(wallet_id == ^arg(:wallet_id)))

      pagination(keyset?: true, required?: true, default_limit: 25)
    end

    # ADR-0029 Am. 3 gate 3: the quarterly per-country tax summary's
    # source rows — the period's tax-bearing entries: purchase credits
    # and the compensating debits that reverse them. Reversals are
    # matched by `reverses_id`, not reason — ReverseEntry accepts a
    # reason override while still copying the original's tax facts, and
    # a reversal under any other name must still net out of the return.
    # Rows without a persisted country or rate can't be attributed to a
    # return. Half-open [from, to): a boundary row lands in exactly one
    # period.
    read :tax_bearing_entries do
      description(
        "Tax-bearing entries (charge credits and the debits reversing them) in a date range — the tax summary's source."
      )

      argument(:from, :utc_datetime, allow_nil?: false)
      argument(:to, :utc_datetime, allow_nil?: false)

      filter(
        expr(
          ((type == :credit and reason == :purchase) or
             (type == :debit and not is_nil(reverses_id))) and
            not is_nil(billing_country) and not is_nil(applied_rate) and
            created_at >= ^arg(:from) and created_at < ^arg(:to)
        )
      )
    end
  end

  code_interface do
    domain(FluxVale.Billing)

    define(:create)
    define(:read)
    define(:list_for_wallet, args: [:wallet_id])
    define(:grant_goodwill, args: [:wallet_id, :amount_cents])
  end

  identities do
    # NULL keys stay distinct (Postgres default) — keyless one-off posts
    # (welcome grants) are legal; keyed posts are idempotent per wallet.
    identity(:unique_idempotency, [:wallet_id, :idempotency_key])
  end
end
