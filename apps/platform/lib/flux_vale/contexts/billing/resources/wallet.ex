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
  platform admin from the admin wallets surface's confirmed flip
  (the AshAdmin edit form keeps its emergency checkbox).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource, AshJsonApi.Resource, AshPaperTrail.Resource]

  alias FluxVale.Billing.LedgerEntry

  # #360 (ADR-0019 §1): the wallet's wire contract — read-only by
  # design (the issue's scope table: no wallet writes over the API).
  # The balance aggregate rides the default fields; carryover and the
  # ladder markers are private system state.
  json_api do
    type("wallet")

    routes do
      # wallet:read — the balance aggregate rides along; timestamps are
      # private attributes.
      get(:get_by_organization,
        route: "/organizations/:organization_id/wallet",
        default_fields: [:id, :organization_id, :balance, :paywall_waived]
      )

      # wallet:read — the billing page's projection.
      route(:get, "organizations/:organization_id/wallet/runway", :runway)
    end
  end

  policies do
    # The blanket authority (#644, ADR-0047): platform admins see and do
    # everything — but never through the machine API (the second
    # condition), so PAT callers fall through to the policies below
    # with today's semantics. The blanket subsumes this resource's
    # read-policy admin arm (#140) for non-PAT callers; the arm stays
    # for PAT callers, whose behavior is byte-for-byte today's.
    bypass [FluxVale.Checks.ActorIsPlatformAdmin, FluxVale.Checks.CallOutsideMachineApi] do
      description("Platform admins see and do everything (#644)")
      authorize_if(always())
    end

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
      description(
        "System-only: wallet provisioning (authorize?: false; platform admins ride the #644 bypass, ADR-0047 D4)"
      )

      forbid_if(always())
    end

    # By action NAME, not action_type (mirrors ledger_entry's :create
    # forbid): :set_waiver is the admin exception above, and scoping
    # this forbid by name is what keeps it off that action. The
    # wallet's only other updates are the two system writes — they stay
    # actor-forbidden for every actor the policies see; a platform
    # admin outside the machine API passes them through the #644
    # bypass instead (ADR-0047's D4), never through this policy.
    policy action([:set_carryover, :set_ladder_state]) do
      description(
        "System-only: carryover + ladder writes (authorize?: false; platform admins ride the #644 bypass, ADR-0047 D4)"
      )

      forbid_if(always())
    end

    # #360: the runway read over the wire — the :delete posture. The
    # member-or-admin read policy bites inside (the authorized
    # get_by_organization), so the projection answers to the same
    # membership fence as the wallet itself.
    policy action(:runway) do
      description(
        "Membership/admin is enforced by the authorized get_by_organization read inside the action"
      )

      authorize_if(actor_present())
    end
  end

  # The admin surface (#140): reads for wallet discovery (the goodwill
  # credit) plus the ONE admin write — the paywall waiver flip below,
  # rendered by AshAdmin as the edit form's checkbox. Everything else
  # stays off the mount deliberately (ADR-0027 Am. 1): AshAdmin's
  # authorizing toggle defaults OFF, so actions through the mount run
  # authorize?: false — a trusted-operator superuser surface must not
  # offer provisioning/carryover/ladder forms at all. On every direct
  # (non-mount) path the policies below forbid those writes to every
  # actor the policies see — a platform admin outside the machine API
  # passes them through the #644 bypass (ADR-0047's D4), pinned in
  # WalletTest.
  admin do
    create_actions([])
    update_actions([:set_waiver])
    destroy_actions([])
    # The operator table: org-first (the way an operator looks for a
    # wallet), the paywall waiver, and the ladder's decision state.
    # :balance is the live sum aggregate; the full field set stays on
    # the record page.
    table_columns([:organization, :balance, :paywall_waived, :negative_since])
  end

  postgres do
    table("billing_wallets")
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
    # Written only by :set_waiver (platform admin — via the admin
    # wallets surface's confirmed flip or the AshAdmin edit form).
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

    # #360: the billing UI's runway figure over the wire. The domain
    # seam (never the operation direct) computes the projection; the
    # action returns the three-key map (the op's struct has no JSON
    # encoder — the map is also the explicit wire contract):
    # balance_cents (whole cents), burn_micro_cents_per_hour (µ¢/h),
    # runway_hours (float, or the atom name "infinity" when the org
    # burns nothing).
    action :runway, :map do
      description("The wallet's projected runway — balance ÷ burn rate.")

      argument(:organization_id, :uuid, allow_nil?: false, public?: true)

      run(fn input, %{actor: actor, authorize?: authorize?} ->
        case get_by_organization(input.arguments.organization_id,
               actor: actor,
               authorize?: authorize?
             ) do
          {:ok, wallet} ->
            with {:ok, runway} <- FluxVale.Billing.compute_runway(wallet) do
              {:ok,
               %{
                 balance_cents: runway.balance_cents,
                 burn_micro_cents_per_hour: runway.burn_micro_cents_per_hour,
                 runway_hours: runway.runway_hours
               }}
            end

          {:error, _reason} = error ->
            error
        end
      end)
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
    # The balance IS the ledger — never a column (product.md). Public
    # since #360: the wallet's headline wire field (and AshAdmin's
    # table already showed it).
    sum(:balance, :entries, :amount, default: 0, public?: true)
  end
end
