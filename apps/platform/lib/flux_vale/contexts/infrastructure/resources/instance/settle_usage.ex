defmodule FluxVale.Infrastructure.Instance.SettleUsage do
  @moduledoc """
  The settle core (#121, ADR-0005 Am. 1 / ADR-0028): accrues the
  instance's flat rate over elapsed time against the org wallet —
  running seconds inside the tick at `monthly_cents`, the rest at
  `stopped_monthly_cents`. A month is the average Gregorian month
  (2_629_746 s) so annual billing stays calendar-neutral.

  Two callers share it: the `:settle_usage` trigger (PerformSettle,
  every 15 min) and — since #493 — the resize action, which settles the
  open interval at the in-force rate BEFORE flipping allocation/pricing,
  so no hour straddles two prices. The cursor advance
  (`storage_metering_since` → now) is the shared idempotency arbiter: a
  retried settle or a double-settled resize re-computes an empty
  interval and posts nothing.

  Two streams over one cursor: `storage_metering_since` marks the last
  committed settle and advances to `now` on every tick. The running
  stream is the instance's unbilled running time — the
  `unbilled_running_usec` carry (folded at each stop transition, so
  stop/start churn inside a tick never drops an interval) plus the open
  interval's overlap with the tick. The remainder of the tick bills at
  the stopped rate. Sub-cent fractions pool in the wallet's per-wallet
  carryover (#120's no-dust rule); a zero-amount tick posts no ledger
  row.

  Prices: the creation-time snapshot (`grandfathered_*`) until
  `grandfathered_until` lapses, then the live `Size` row by the
  snapshotted `size_id` — or, for a custom allocation (#186, no size),
  the live anchor formula from the instance's own allocation —
  resolved by `Pricing.settlement_rates/2`, the one resolver the
  runway projection prices through too (#153). An unpriced instance
  (no size AND no formula snapshot — pre-#121 drift) accrues nothing
  and keeps its anchors: forgiven time is visible as a warning, never
  silent.

  The whole settle — wallet advisory lock, fresh `FOR UPDATE` instance
  read, the micro-cent debit, the anchor advance — shares one
  transaction: an Oban retry recomputes an empty interval and posts
  nothing. That is the idempotency; the debit stays keyless per #120's
  contract (the anchors are the arbiter). The resize's call nests: the
  inner `Repo.transaction` runs inline on the caller's connection, so a
  rollback fails the WHOLE outer transaction — practical atomicity: a
  later failure rolls the settle back with it.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.Proration
  alias FluxVale.Billing.Wallet
  alias FluxVale.Billing.WalletLock
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing
  alias FluxVale.Repo

  require Ash.Query
  require Logger

  # Time is integer microseconds end to end; the month constant and the
  # rate division live in FluxVale.Billing.Proration.

  @doc """
  Settles `record`'s open interval at the in-force rate, now. Returns
  `{:ok, settled_instance}` or `{:error, reason}` — anchors advanced on
  the billed arms; the never-ran and unpriced no-op arms return the
  record untouched (still the caller's success signal).
  """
  @spec settle_now(Instance.t()) :: {:ok, Instance.t()} | {:error, term()}
  def settle_now(%Instance{} = record) do
    # Explicit transaction: the lock, the debit, and the anchor advance
    # commit together or not at all (nested calls run inline on the
    # caller's connection — a rollback fails the whole outer
    # transaction, which is the atomicity the resize rides).
    result =
      Repo.transaction(fn ->
        org = %Organization{id: record.organization_id}

        with {:ok, wallet} <- Billing.ensure_wallet(org),
             :ok <- lock_wallet(wallet),
             {:ok, fresh} <- fresh_instance(record) do
          settle_fresh(fresh, wallet)
        else
          # defensive: wallet provisioning / locking / the row re-read
          # only fail on a DB failure — nothing committed, the Oban
          # retry re-enters cleanly
          # coveralls-ignore-start
          {:error, reason} ->
            Repo.rollback(reason)
            # coveralls-ignore-stop
        end
      end)

    case result do
      {:ok, instance} ->
        {:ok, instance}

      # defensive: rollback only fires from the arms below — a settle
      # failure is an Oban retry, never a lost interval
      # coveralls-ignore-start
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # The v1 settle discipline (ported through #120): lock the wallet
  # FIRST — concurrent posters (another instance's settle in the same
  # org) serialize here, and each reads the other's committed state.
  defp lock_wallet(%Wallet{} = wallet) do
    WalletLock.acquire(wallet)
    :ok
  end

  # Re-read under the wallet lock, row-locked against a concurrent
  # status transition (transitions never take the wallet lock, so no
  # cycle): the anchors read are the anchors that bill.
  defp fresh_instance(%Instance{} = record) do
    result =
      Instance
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(id == ^record.id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one(authorize?: false)

    case result do
      {:ok, instance} when not is_nil(instance) ->
        {:ok, instance}

      # Torn down between the action's read and this one — nothing to
      # settle; returning the record ends the job cleanly (no retry).
      # Concurrency-only, not sequential-test reachable.
      # coveralls-ignore-start
      {:ok, nil} ->
        {:ok, record}

      # coveralls-ignore-stop

      # defensive: a read failure must fail the settle rather than risk
      # a double-bill; not simulatable under the sandbox
      # coveralls-ignore-start
      {:error, reason} ->
        Repo.rollback(reason)
        # coveralls-ignore-stop
    end
  end

  defp settle_fresh(%Instance{} = fresh, %Wallet{} = wallet) do
    now = DateTime.utc_now()

    cond do
      is_nil(fresh.storage_metering_since) ->
        # Never ran (the trigger's where filters these; a direct drive
        # no-ops too): nothing accrued, and arming the storage cursor
        # here would bill a PVC that doesn't exist.
        fresh

      # Unpriced = no size AND no formula snapshot (pre-#121 drift or
      # a hand-built half-snapshot); custom allocations (#186) carry
      # the full grandfathered_* triple with a nil size. The formula
      # snapshot is the cents + clock PAIR — a sizeless row missing
      # either half is unpriced too (pricing.ex's unpriced?, mirrored
      # here as the pre-filter).
      match?(%{size_id: nil, grandfathered_until: nil}, fresh) or
          match?(%{size_id: nil, grandfathered_monthly_cents: nil}, fresh) ->
        # Unpriced (pre-#121 drift): never guess — the time is forgiven
        # loudly, the anchors stay so the gap stays visible.
        Logger.warning(
          "Instance #{fresh.id} skipped settlement: no pricing snapshot (size_id is nil)"
        )

        fresh

      true ->
        settle_priced(fresh, wallet, now)
    end
  end

  defp settle_priced(%Instance{} = fresh, %Wallet{} = wallet, now) do
    case price(fresh, now) do
      # coveralls-ignore-start - unreachable: settle_priced's guard
      # above filters every unpriced shape (nil size with a nil clock
      # or nil cents) before price/2 runs; the resolver's {:ok, nil}
      # arm exists for callers without the pre-filter
      {:ok, nil} ->
        fresh

      # coveralls-ignore-stop

      # defensive plumbing for the resolver's read-failure arm — fail the
      # settle, never bill a guess
      # coveralls-ignore-start
      {:error, reason} ->
        Repo.rollback(reason)

      # coveralls-ignore-stop

      {:ok, rates} ->
        cursor = fresh.storage_metering_since
        total_usecs = Proration.usecs_between(cursor, now)
        running_usecs = running_usecs(fresh, cursor, now)
        stopped_usecs = max(total_usecs - running_usecs, 0)

        micros = accrue(rates, running_usecs, stopped_usecs)

        with :ok <- post_debit(wallet, micros),
             {:ok, updated} <- advance_anchors(fresh, now) do
          updated
        else
          # defensive: the debit and the anchor write share this
          # transaction — a failure rolls back both; DB failure only,
          # not sequential-test reachable
          # coveralls-ignore-start
          {:error, reason} ->
            Repo.rollback(reason)
            # coveralls-ignore-stop
        end
    end
  end

  # The one canonical resolver lives on the Pricing domain (#153 — the
  # runway projection prices through it too): the creation-time snapshot
  # inside the grace, the live Size row after, {:ok, nil} = unpriced.
  defp price(%Instance{} = instance, now) do
    Pricing.settlement_rates(instance, now)
  end

  # The unbilled running time inside this tick: the stop-transition
  # carry (each stop folds its interval in; a settle zeroes it) plus
  # the open interval's overlap — bounded below by the cursor, above by
  # now. running_since is set exactly while :running (MaintainAnchors
  # owns the pairing), so the open overlap is zero when stopped.
  defp running_usecs(%Instance{} = instance, cursor, now) do
    instance.unbilled_running_usec + open_usecs(instance.running_since, cursor, now)
  end

  defp open_usecs(nil, _cursor, _now), do: 0

  defp open_usecs(started, cursor, now) do
    bounded = max_datetime(started, cursor)
    Proration.usecs_between(bounded, now)
  end

  # Integer micro-cents, floored — the sub-µ¢ residue is orders of
  # magnitude below the per-wallet carryover's pooling granularity.
  # This settle's contract: prorate the running and stopped shares
  # exactly, ADD them, then floor once. (The gateway settle floors
  # each rate; the two contracts are deliberate, see Proration.)
  defp accrue(rates, running_usecs, stopped_usecs) do
    running = Proration.prorate_decimal(rates.running, running_usecs)
    stopped = Proration.prorate_decimal(rates.stopped, stopped_usecs)

    running
    |> Decimal.add(stopped)
    |> Decimal.round(0, :floor)
    |> Decimal.to_integer()
  end

  # Zero accrued (fresh tick, retry after commit, or a fully-clamped
  # interval): no ledger row — the anchors still advance.
  defp post_debit(_wallet, micros) when micros <= 0, do: :ok

  defp post_debit(%Wallet{} = wallet, micros) do
    # Joins the settle transaction (runs inline on its connection — a
    # rollback fails the whole transaction); the advisory xact lock
    # is reentrant for this transaction, so DebitWallet's own lock is a
    # no-op pass-through.
    case Billing.debit_wallet(wallet, micros) do
      {:ok, _entry_or_accrued} ->
        :ok

      # defensive: posting failure = DB failure — rollback keeps the
      # anchors put so the retry re-bills nothing
      # coveralls-ignore-start
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  # The cursor advances on every committed settle — the retry arbiter —
  # and the unbilled carry zeroes with it: everything pending billed.
  # running_since is not settlement's to write (MaintainAnchors owns
  # it; it is nil unless the instance is running).
  defp advance_anchors(%Instance{} = fresh, now) do
    result =
      fresh
      |> Ash.Changeset.for_update(:settle_anchors, %{
        storage_metering_since: now,
        unbilled_running_usec: 0
      })
      |> Ash.update(authorize?: false, return_notifications?: true)

    case result do
      {:ok, instance, _notifications} ->
        {:ok, instance}

      # defensive: DB write failure, not simulatable under the sandbox
      # coveralls-ignore-start
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp max_datetime(a, b) do
    if DateTime.compare(a, b) == :gt, do: a, else: b
  end
end
