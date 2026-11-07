defmodule FluxVale.Infrastructure.AccessGateway.PerformSettle do
  @moduledoc """
  Gateway-existence accrual (ADR-0039 §5): prorates the gateway's
  monthly rate over the open interval against the org wallet — the
  instance `perform_settle` discipline, without the storage term.

  The discipline, unchanged from #121:

  - **wallet advisory lock first**, so concurrent posters (this gateway
    and the org's instances settle on the same 15-minute tick)
    serialize and each reads the other's committed state;
  - **fresh `FOR UPDATE` re-read** of the gateway, so the anchors that
    bill are the anchors that committed (a racing suspend parks them,
    and the settle must see the park);
  - **prorate in integer micro-cents** over the average Gregorian month
    (2_629_746 s — `Billing.Month`, the one definition the settles
    and the runway share);
  - **keyless debit** — the anchor is the retry arbiter, so a committed
    settle that advances `metering_since` can never recompute the same
    interval. No idempotency key, no new posting surface;
  - **anchor advance in the same transaction**, so a crash mid-settle
    re-bills nothing.

  Accrual arms: `:active` only. The trigger's `where` includes
  `:needs_attention` deliberately (a row that just lost its key still
  has time to bill up to the moment it did), so this module's own
  re-check is what stops the accrual — a settling row must never bill a
  gateway that is not giving the owner reachability.

  A **nil** `metering_since` arms the cursor without posting: the first
  tick after create (or after a resume) opens the window, it does not
  bill from the epoch. This mirrors the instance's never-ran arm.

  Attribution rides `subject: "access-gateway:<id>"` on the ledger row
  (ADR-0039 §5) so a reader can tell a gateway debit from instance
  usage without a second `EntryReason`.
  """

  use Ash.Resource.Change

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.Month
  alias FluxVale.Billing.Wallet
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Repo

  require Ash.Query

  @micros_per_cent Decimal.new(10_000)

  # The shared constant (FluxVale.Billing.Month) as a Decimal — bound
  # through a function, not a module attribute, so the constant module
  # carries no compile-order dependency on this resource.
  defp month_useconds, do: Decimal.new(Month.useconds())

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      settle(record)
    end)
  end

  # Leaving :active: bill the interval actually served, then close the
  # window. Parking without billing would drop served time; leaving it
  # open would bill the whole unobserved gap in arrears on recovery.
  defp park_anchor(%AccessGateway{metering_since: nil} = fresh), do: {:ok, fresh}

  defp park_anchor(%AccessGateway{} = fresh) do
    with {:ok, wallet} <- ensure_wallet(fresh),
         :ok <- settle_interval(fresh, wallet) do
      advance(fresh, nil)
    end
  end

  defp ensure_wallet(%AccessGateway{organization_id: org_id}) do
    Billing.ensure_wallet(%Organization{id: org_id})
  end

  # The interval ends at the TRANSITION, not at this tick. A row that went
  # :needs_attention at T has `needs_attention_since = T`, but settlement
  # may not run until up to 15 minutes later — billing to `now()` would
  # charge that gap, in which the gateway gave the owner no reachability.
  defp settle_interval(%AccessGateway{} = fresh, %Wallet{} = wallet) do
    usecs = usecs_between(fresh.metering_since, interval_end(fresh))
    micros = prorate(fresh.monthly_cents, usecs)
    post_debit(wallet, fresh, micros)
  end

  # Reached only from `park_anchor/1` (a row leaving `:active`), so the
  # transition instant is what bounds the interval. A `:needs_attention`
  # row carries the instant it stopped serving; a row parked for any other
  # reason has none, and `now()` is then the honest end (it was serving
  # until this tick).
  defp interval_end(%AccessGateway{needs_attention_since: since}) when not is_nil(since),
    do: since

  defp interval_end(%AccessGateway{}), do: DateTime.utc_now()

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (wallet lock + anchor writes)
  def atomic?, do: false

  defp settle(%AccessGateway{} = record) do
    result =
      Repo.transaction(fn ->
        org = %Organization{id: record.organization_id}

        with {:ok, wallet} <- Billing.ensure_wallet(org),
             :ok <- lock_wallet(wallet),
             {:ok, fresh} <- fresh_gateway(record),
             {:ok, updated} <- settle_fresh(fresh, wallet) do
          updated
        else
          # coveralls-ignore-start - defensive: wallet provisioning /
          # locking / the re-read only fail on a DB failure; nothing
          # committed, the Oban retry re-enters cleanly
          {:error, reason} ->
            Repo.rollback(reason)
            # coveralls-ignore-stop
        end
      end)

    case result do
      {:ok, gateway} ->
        {:ok, gateway}

      # coveralls-ignore-start - defensive: rollback only fires from the
      # arms above; a settle failure is an Oban retry, never a lost interval
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  defp lock_wallet(%Wallet{} = wallet) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [wallet.id])
    :ok
  end

  defp fresh_gateway(%AccessGateway{} = record) do
    result =
      AccessGateway
      |> Ash.Query.filter(id == ^record.id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one(authorize?: false)

    case result do
      # coveralls-ignore-start - race only: the row torn down between the
      # trigger's read and this one. Sequential tests cannot interleave it.
      {:ok, nil} ->
        {:ok, record}

      # coveralls-ignore-stop

      {:ok, gateway} ->
        {:ok, gateway}

      # coveralls-ignore-start - defensive: not simulatable under the sandbox
      {:error, reason} ->
        Repo.rollback(reason)
        # coveralls-ignore-stop
    end
  end

  defp settle_fresh(%AccessGateway{state: state} = fresh, _wallet)
       when state != :active do
    # Not giving the owner reachability → not billing, and the window
    # closes here: an anchor left open would bill the entire gap on the
    # first settle after a recovery (Suspend parks it for the same
    # reason; the two arms must agree).
    park_anchor(fresh)
  end

  defp settle_fresh(%AccessGateway{metering_since: nil} = fresh, _wallet) do
    # First tick (or first after resume): open the window, bill nothing
    # from the epoch.
    advance(fresh, DateTime.utc_now())
  end

  defp settle_fresh(%AccessGateway{} = fresh, %Wallet{} = wallet) do
    now = DateTime.utc_now()
    usecs = usecs_between(fresh.metering_since, now)
    micros = prorate(fresh.monthly_cents, usecs)

    with :ok <- post_debit(wallet, fresh, micros),
         {:ok, updated} <- advance(fresh, now) do
      {:ok, updated}
    else
      # coveralls-ignore-start - defensive: debit + anchor share this
      # transaction; failure rolls back both (DB failure only)
      {:error, reason} ->
        Repo.rollback(reason)
        # coveralls-ignore-stop
    end
  end

  defp usecs_between(from, to), do: max(DateTime.diff(to, from, :microsecond), 0)

  # Integer micro-cents, floored — the same rounding as the instance
  # settle's prorate. The floored sub-µ¢ fraction is discarded (too small
  # for the ledger's unit); only the wallet's sub-CENT carryover pools.
  defp prorate(cents, usecs) do
    cents
    |> Decimal.new()
    |> Decimal.mult(@micros_per_cent)
    |> Decimal.mult(usecs)
    |> Decimal.div(month_useconds())
    |> Decimal.round(0, :floor)
    |> Decimal.to_integer()
  end

  # Zero accrued: no ledger row (the instance settle's stance). The
  # anchor still advances.
  defp post_debit(_wallet, _gateway, micros) when micros <= 0, do: :ok

  defp post_debit(%Wallet{} = wallet, %AccessGateway{} = gateway, micros) do
    # The `fields` map rides PostEntry onto the ledger row: the subject
    # is the gateway's attribution marker (ADR-0039 §5). `reason:
    # :usage` keeps one consumption dimension (#120's reconcilability).
    case Billing.debit_wallet(wallet, micros,
           reason: :usage,
           fields: %{subject: "access-gateway:#{gateway.id}"}
         ) do
      {:ok, _entry_or_accrued} ->
        :ok

      # coveralls-ignore-start - defensive: posting failure = DB failure
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp advance(%AccessGateway{} = fresh, now) do
    result =
      fresh
      |> Ash.Changeset.for_update(:settle_anchors, %{metering_since: now}, authorize?: false)
      |> Ash.update(authorize?: false, return_notifications?: true)

    case result do
      {:ok, gateway, _notifications} ->
        {:ok, gateway}

      # coveralls-ignore-start - defensive: DB write failure
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end
end
