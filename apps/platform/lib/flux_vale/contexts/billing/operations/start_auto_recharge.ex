defmodule FluxVale.Billing.Operations.StartAutoRecharge do
  @moduledoc """
  The staged auto-recharge charge attempt (#829 S3, decision A — the
  attempt IS a top-up): builds the `:auto` Topup row, creates the
  provider's DRAFT order for the gross, persists the order id, then
  fires the synchronous charge.

  STAGED: the only caller is S4's gated sweep arm. Before any row or
  network call this operation checks three things, refusing on each:

  - the platform gate (`FluxVale.Billing.auto_recharge_charge_mode?/0`,
    default false) — `{:error, :charge_mode_off}`; defense in depth,
    so a future caller cannot charge with the lane off;
  - the owner's CONSENT (decision G) — `setting.mode` must be `:auto`,
    else `{:error, :setting_not_armed}`: an org that asked for
    reminders must never be silently charged the day the gate flips;
  - the PAIRING — `setting.organization_id` must equal `org.id`, else
    `{:error, :setting_org_mismatch}`: a mismatched pair would charge
    one org's saved method and credit another's wallet.

  ## Caller contract (S4's sweep)

  The sweep has ALREADY taken `WalletLock` and re-read the balance
  before calling — this operation takes NO lock and re-reads NO
  balance. Nesting the advisory lock would serialize against the
  caller's own hold; the ledger's idempotency keys remain the double
  credit guard.

  ## The steps

  1. The row: origin `:auto`, net `setting.amount_cents`, the tax
     freshly quoted (`FluxVale.Billing.Tax.quote/2`) over the setting's
     buyer evidence — the RATE always resolves from the table at
     charge time (#260, never a copied rate; reverse charge zeroes it)
     — persisted `:pending` with NO buyer_email (the org pays; there
     is no buyer inbox). The insert is one Ash action — its own
     transaction; no network call ever joins a row transaction.
  2. AFTER the row commits: `create_draft_charge` (gross = net + tax,
     reference = the row's id, customer = the setting's stored
     `provider_customer_id`). Failure (`{:error, :draft_failed, topup}`)
     leaves the row `:pending` with NO order id, and the sweep's stale
     arm (S4) fails the row safely. Honesty about that leg: a
     transport timeout may have left a draft on Polar's side — if one
     exists, nobody ever finalizes it (finalize is the only charge
     trigger and requires our credentials); Polar's own draft
     lifecycle owns it.
  3. The returned order id rides the row via the EXISTING
     `attach_checkout` action — BEFORE any finalize — so the webhook
     and the sweep's reconciliation both key on it. An attach failure
     (DB hiccup, `{:error, :attach_failed, topup}`) leaves the row
     `:pending` WITHOUT the id; nothing was finalized, so nothing can
     have charged — reconciliation may safely fail it.
  4. `finalize_charge` on the order id — attempted exactly once,
     never re-driven (decision E):
     - `{:ok, %{status: :completed}}` → the credit is NOT posted here:
       the webhook (order.paid) or the sweep's reconciliation posts it
       through the unchanged `CompleteTopup` seam — its gross guard
       applies unchanged (the order's `subtotal_amount` must equal the
       gross we sent). The strike counter resets
       (`:record_attempt_outcome`, failures 0, attempt stamped) as its
       own single atomic write; `{:ok, :completed, topup}`.
     - `{:ok, %{status: :failed, failure_reason: reason}}` → an
       ANSWERED decline: the row is marked failed — terminal-once, the
       status filter rides the UPDATE's WHERE (CompleteTopup's house
       shape; a racer that settled the row mid-flight loses) — AND the
       strike increment, in ONE transaction: both or neither (a crash
       between the writes must not leave an uncounted failure);
       `{:ok, :failed, topup, reason}`. If the racer already settled
       it, nothing is flipped or counted:
       `{:ok, :already_terminal, topup}`.
     - `{:error, :network_error | :api_error}` → outcome UNKNOWN: the
       row stays `:pending` WITH its order id, only `last_attempt_at`
       is recorded, and the sweep's stale arm (S4) reconciles via a
       provider ORDER fetch — S4 adds that seam (`fetch_payment`
       serves checkout ids only; an order id would 404 there). A
       finalize that may have succeeded is answered by that fetch
       before anything new fires; `{:error, :unknown, topup}`.

  ## Outcome mails

  `TopupOutcomeMail` is deliberately NOT called: it is a structural
  no-op for auto rows (it guards `buyer_email`, which auto rows never
  set). The user-facing signals are the balance change, the billing
  page, Polar's own buyer confirmation on success, and S4's disable
  notices.

  System operation, `authorize?: false` — like every gateway-outcome
  write, the inputs are system facts, not actor intents.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.AutoRechargeSetting
  alias FluxVale.Billing.Tax
  alias FluxVale.Billing.Topup

  require Ash.Query

  @currency "USD"

  @type outcome ::
          {:ok, :completed, Topup.t()}
          | {:ok, :failed, Topup.t(), String.t() | nil}
          | {:ok, :already_terminal, Topup.t()}
          | {:error, :charge_mode_off}
          | {:error, :setting_not_armed}
          | {:error, :setting_org_mismatch}
          | {:error, :draft_failed, Topup.t()}
          | {:error, :attach_failed, Topup.t()}
          | {:error, :unknown, Topup.t()}
          | {:error, term()}

  @spec call(Organization.t(), AutoRechargeSetting.t(), keyword()) :: outcome()
  def call(%Organization{} = org, %AutoRechargeSetting{} = setting, opts \\ []) do
    # Gate, consent, pairing — in one check, before any row or network
    # call (see the moduledoc). The gate is defense in depth for the
    # lane; the consent is decision G's promise (a reminder opt-in is
    # never a charge consent); the pairing keeps the charge and the
    # credit on the same org.
    cond do
      not Billing.auto_recharge_charge_mode?() -> {:error, :charge_mode_off}
      setting.mode != :auto -> {:error, :setting_not_armed}
      setting.organization_id != org.id -> {:error, :setting_org_mismatch}
      true -> charge(org, setting, opts)
    end
  end

  defp charge(org, setting, opts) do
    with {:ok, topup} <- create_row(org, setting) do
      provider = Application.fetch_env!(:flux_vale, :payments_provider)

      request = %{
        # The gateway charges the gross — net credit + VAT (#138).
        amount_cents: topup.amount_cents + topup.tax_cents,
        currency: @currency,
        reference: topup.id
      }

      # The row's stored customer reference is authoritative: a caller
      # cannot repoint the charge at another provider customer.
      provider_opts =
        opts
        |> Keyword.get(:provider_opts, [])
        |> Keyword.put(:customer_id, setting.provider_customer_id)

      result = provider.create_draft_charge(request, provider_opts)

      case result do
        {:ok, %{order_id: order_id}} -> attach_then_finalize(topup, setting, order_id, opts)
        {:error, _reason} -> {:error, :draft_failed, topup}
      end
    end
  end

  # One Ash action — its own transaction, committing before any HTTP:
  # a network call never joins a row transaction (the plan's rule,
  # the suspend_gateways discipline).
  defp create_row(org, setting) do
    buyer_evidence = evidence(setting)
    tax = Tax.quote(buyer_evidence, setting.amount_cents)

    Topup.create(
      %{
        organization_id: org.id,
        amount_cents: setting.amount_cents,
        origin: :auto,
        billing_country: setting.billing_country,
        billing_state: setting.billing_state,
        customer_type: setting.customer_type,
        vat_number: setting.vat_number,
        tax_rate_bp: tax.rate_bp,
        tax_cents: tax.tax_cents,
        reverse_charge?: tax.reverse_charge?
      },
      authorize?: false
    )
  end

  defp evidence(setting) do
    %{
      billing_country: setting.billing_country,
      billing_state: setting.billing_state,
      customer_type: setting.customer_type,
      vat_number: setting.vat_number
    }
  end

  # The order id persists BEFORE the charge trigger (decision E) — the
  # webhook and reconciliation both key on it. An attach failure means
  # the id is lost: nothing was finalized, so reconciliation may
  # safely fail the pending row.
  defp attach_then_finalize(topup, setting, order_id, opts) do
    case Topup.attach_checkout(topup, %{payment_request_id: order_id}, authorize?: false) do
      {:ok, attached} -> finalize(attached, setting, order_id, opts)
      {:error, _reason} -> {:error, :attach_failed, topup}
    end
  end

  # The synchronous charge — exactly once, never re-driven (decision
  # E); the unknown arms belong to the sweep's stale-pending
  # reconciliation.
  defp finalize(topup, setting, order_id, opts) do
    provider = Application.fetch_env!(:flux_vale, :payments_provider)

    result =
      provider.finalize_charge(order_id, Keyword.get(opts, :provider_opts, []))

    case result do
      {:ok, %{status: :completed}} ->
        record_success(setting)
        {:ok, :completed, topup}

      {:ok, %{status: :failed, failure_reason: reason}} ->
        decline_outcome(topup, setting, reason)

      {:error, _reason} ->
        record_attempt(setting)
        {:error, :unknown, topup}
    end
  end

  # The strike counter resets as its own single system write, atomic
  # on its own — the row is terminal-pending (its credit arrives via
  # the webhook), not part of this write.
  defp record_success(setting) do
    case record_outcome(setting, consecutive_failures: 0, last_attempt_at: DateTime.utc_now()) do
      {:ok, _counted} -> :ok
      # Defensive: a DB failure after a COMPLETED charge — the charge
      # stands and the credit lands via the webhook; the stale counter
      # self-corrects on the next pass.
      # coveralls-ignore-next-line
      {:error, reason} -> {:error, reason}
    end
  end

  # The crash-between-writes guard (the plan pins it): the failed row
  # and the strike increment commit or neither — inside one
  # transaction a raise rolls both back. Notifications ride
  # `return_notifications?` (Ash cannot dispatch from inside a
  # caller-owned transaction) and go out after the commit.
  defp decline_outcome(topup, setting, reason) do
    outcome =
      FluxVale.Repo.transaction(fn ->
        settle_decline(mark_failed_once(topup), setting, topup)
      end)

    case outcome do
      {:ok, {:marked, failed, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, :failed, failed, reason}

      {:ok, {:settled, topup}} ->
        {:ok, :already_terminal, Topup.get_by_id!(topup.id, authorize?: false)}

      {:error, db_reason} ->
        {:error, db_reason}
    end
  end

  # The three bulk outcomes inside the decline transaction: marked
  # (strike counts, still in-transaction), settled (a racer won —
  # nothing to flip or count), or a DB error (rollback).
  defp settle_decline(
         %Ash.BulkResult{status: :success, records: [failed], notifications: notifications},
         setting,
         _topup
       ) do
    case count_strike(setting) do
      {:ok, _counted} ->
        {:marked, failed, notifications}

      # Defensive: a setting-write DB failure rolls the decline
      # transaction back — no failed row without its strike. (The
      # setting action's failure is not deterministically forceable —
      # the write is `Ash.update` on the sweep's changeset — so this
      # arm rides the exclusion.)
      # coveralls-ignore-start
      {:error, db_reason} ->
        FluxVale.Repo.rollback(db_reason)
        # coveralls-ignore-stop
    end
  end

  defp settle_decline(%Ash.BulkResult{status: :success, records: []}, _setting, topup) do
    {:settled, topup}
  end

  defp settle_decline(%Ash.BulkResult{status: :error, errors: errors}, _setting, _topup) do
    FluxVale.Repo.rollback(errors)
  end

  # Terminal-once (CompleteTopup's mark_completed house shape): the
  # status filter rides the UPDATE's WHERE, so an out-of-order racer
  # (a webhook that settled the row mid-flight) loses (zero rows)
  # instead of flipping an already-terminal row.
  defp mark_failed_once(topup) do
    query = Ash.Query.filter(Topup, id == ^topup.id and status == :pending)

    Ash.bulk_update(query, :mark_failed, %{},
      authorize?: false,
      return_records?: true,
      return_notifications?: true,
      notify?: false
    )
  end

  # The strike increment inside the decline transaction: the plain
  # write, the raw outcome — the rollback policy lives with the caller
  # (settle_decline), so a failure here leaves the row unmarked (both
  # or neither).
  defp count_strike(setting) do
    record_outcome(setting,
      consecutive_failures: setting.consecutive_failures + 1,
      last_attempt_at: DateTime.utc_now()
    )
  end

  # Unknown outcome: only the attempt marker moves — the strike
  # counter counts ANSWERED failures, never unknown ones (an unknown
  # may still reconcile to success).
  defp record_attempt(setting) do
    case record_outcome(setting, last_attempt_at: DateTime.utc_now()) do
      {:ok, _counted} -> :ok
      # Defensive: a DB failure after an unknown-outcome charge — the
      # pending row (already committed) is what reconciliation keys
      # on; the missing marker only blurs the 24h window until the
      # next pass stamps it.
      # coveralls-ignore-next-line
      {:error, reason} -> {:error, reason}
    end
  end

  # The sweep seam's system write (`authorize?: false`, actor-forbidden
  # by policy): consecutive_failures stores AS GIVEN — what resets it
  # and what counts a strike is this operation's caller contract.
  defp record_outcome(setting, fields) do
    setting
    |> Ash.Changeset.for_update(:record_attempt_outcome, Map.new(fields))
    |> Ash.update(authorize?: false)
  end
end
